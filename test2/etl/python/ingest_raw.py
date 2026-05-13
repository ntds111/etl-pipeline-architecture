"""
ingest_raw.py — single entry point for raw layer ingestion

Steps:
  1. create_schema()  — run raw_pulsefit.sql, validate all tables and data types
  2. load_data()      — stage CSVs + JSON in _tmp tables, upsert into raw tables:
                          new rows  → inserted
                          same key, different content_hash → updated
                          same key, same content_hash (true duplicate) → skipped
                        reject invalid rows to _rejected tables
  3. save_output()    — write run summary JSON to etl/outputs/
"""

import csv
import hashlib
import json
import os
import sys
from datetime import datetime, date

import psycopg2

DB_NAME     = "calimoto_data"
BASE_DIR    = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SQL_FILE    = os.path.join(BASE_DIR, "sql", "raw_pulsefit.sql")
DATA_DIR    = os.path.join(os.path.dirname(BASE_DIR), "data")
OUTPUTS_DIR = os.path.join(BASE_DIR, "outputs")

# Expected schema: {table: {column: pg_data_type}}
EXPECTED_SCHEMA = {
    "raw_users": {
        "user_id":             "text",
        "email":               "text",
        "country_code":        "text",
        "install_date":        "text",
        "acquisition_channel": "text",
        "device_os":           "text",
        "app_version":         "text",
        "content_hash":        "text",
        "ingested_at":         "timestamp without time zone",
    },
    "raw_events": {
        "event_id":        "text",
        "user_id":         "text",
        "event_name":      "text",
        "event_timestamp": "text",
        "properties":      "text",
        "content_hash":    "text",
        "ingested_at":     "timestamp without time zone",
    },
    "raw_ad_spend": {
        "raw_ad_spend_id": "text",
        "date":            "text",
        "channel":         "text",
        "country_code":    "text",
        "campaign_name":   "text",
        "spend":           "numeric",
        "currency":        "text",
        "impressions":     "integer",
        "clicks":          "integer",
        "installs":        "integer",
        "content_hash":    "text",
        "ingested_at":     "timestamp without time zone",
    },
    "raw_subscriptions": {
        "subscription_id": "text",
        "user_id":         "text",
        "plan":            "text",
        "amount_usd":      "numeric",
        "start_date":      "date",
        "end_date":        "date",
        "status":          "text",
        "renewal_history": "jsonb",
        "content_hash":    "text",
        "ingested_at":     "timestamp without time zone",
    },
}

# CSV sources: (table, tmp_table, filename, required_fields, merge_key_fields)
CSV_SOURCES = [
    ("raw_pulsefit.raw_users",    "raw_pulsefit.raw_users_tmp",    "users.csv",    ["user_id"],            ["user_id"]),
    ("raw_pulsefit.raw_events",   "raw_pulsefit.raw_events_tmp",   "events.csv",   ["event_id", "user_id"], ["event_id"]),
    ("raw_pulsefit.raw_ad_spend", "raw_pulsefit.raw_ad_spend_tmp", "ad_spend.csv", ["date", "channel"],    ["content_hash"]),
]


# ── 1. Schema creation + validation ──────────────────────────────────────────

def create_schema(conn) -> dict:
    result = {"step": "create_schema", "status": None, "errors": [], "tables_validated": []}

    try:
        with open(SQL_FILE) as f:
            sql = f.read()
        with conn.cursor() as cur:
            cur.execute(sql)
        conn.commit()
    except FileNotFoundError:
        result["status"] = "failed"
        result["errors"].append(f"SQL file not found: {SQL_FILE}")
        return result
    except Exception as e:
        conn.rollback()
        result["status"] = "failed"
        result["errors"].append(f"Schema SQL error: {e}")
        return result

    with conn.cursor() as cur:
        for table_name, expected_cols in EXPECTED_SCHEMA.items():
            cur.execute("""
                SELECT column_name, data_type
                FROM information_schema.columns
                WHERE table_schema = 'raw_pulsefit'
                  AND table_name   = %s
                ORDER BY ordinal_position
            """, (table_name,))
            actual = {row[0]: row[1] for row in cur.fetchall()}

            if not actual:
                result["errors"].append(f"Table raw_pulsefit.{table_name} was not created")
                continue

            mismatches = []
            for col, expected_type in expected_cols.items():
                actual_type = actual.get(col)
                if actual_type is None:
                    mismatches.append(f"  column '{col}' missing")
                elif actual_type != expected_type:
                    mismatches.append(f"  column '{col}': expected {expected_type}, got {actual_type}")

            if mismatches:
                result["errors"].append(f"raw_pulsefit.{table_name} type mismatches:\n" + "\n".join(mismatches))
            else:
                result["tables_validated"].append(f"raw_pulsefit.{table_name}")

    result["status"] = "failed" if result["errors"] else "ok"
    _log(f"[{result['status'].upper()}] Schema: {len(result['tables_validated'])}/4 tables validated")
    for err in result["errors"]:
        _log(f"  ERROR: {err}")
    return result


# ── 2. Data loading ───────────────────────────────────────────────────────────

def _ensure_rejected_table(conn, schema_table: str, columns: list[tuple[str, str]]):
    """Create _rejected mirror table if it doesn't exist."""
    rejected_table = schema_table + "_rejected"
    col_defs = ",\n    ".join(f"{name} {dtype}" for name, dtype in columns)
    with conn.cursor() as cur:
        cur.execute(f"""
            CREATE TABLE IF NOT EXISTS {rejected_table} (
                {col_defs},
                rejection_reason TEXT,
                rejected_at      TIMESTAMP DEFAULT NOW()
            )
        """)
    conn.commit()


def load_csv(conn, table: str, tmp_table: str, filename: str,
             required_fields: list[str], key_fields: list[str]) -> dict:
    result = {
        "table": table,
        "tmp_table": tmp_table,
        "file": filename,
        "staged": 0,
        "inserted": 0,
        "updated": 0,
        "rejected": 0,
        "rejection_reasons": {},
    }
    filepath = os.path.join(DATA_DIR, filename)

    try:
        with open(filepath, newline="", encoding="utf-8") as f:
            reader = csv.DictReader(f)
            rows = list(reader)
            source_columns = reader.fieldnames
    except FileNotFoundError:
        result["error"] = f"File not found: {filepath}"
        _log(f"  [FAIL] {filename}: file not found")
        return result

    # Attach content_hash to every row before building column list.
    # For ad_spend, raw_ad_spend_id is the content_hash — a stable fingerprint
    # of the full row. The business key (date, channel, country_code, campaign_name)
    # drives ON CONFLICT; content_hash detects whether a correction arrived.
    if filename == "ad_spend.csv":
        for row in rows:
            content_hash           = _row_hash(row, source_columns)
            row["raw_ad_spend_id"] = content_hash
            row["content_hash"]    = content_hash
        columns = ["raw_ad_spend_id"] + source_columns + ["content_hash"]
    else:
        for row in rows:
            row["content_hash"] = _row_hash(row, source_columns)
        columns = source_columns + ["content_hash"]

    _ensure_rejected_table(conn, table, [(c, "TEXT") for c in columns])
    rejected_table = table + "_rejected"
    col_list        = ", ".join(columns)
    placeholders    = ", ".join(["%s"] * len(columns))

    _truncate_table(conn, tmp_table)

    for row in rows:
        values = [row.get(c) or None for c in columns]

        missing = [f for f in required_fields if not row.get(f)]
        if missing:
            reason = f"null_required_field: {', '.join(missing)}"
            _insert_rejected(conn, rejected_table, columns, values, reason)
            _track_reason(result, reason)
            result["rejected"] += 1
            continue

        try:
            with conn.cursor() as cur:
                cur.execute(f"INSERT INTO {tmp_table} ({col_list}) VALUES ({placeholders})", values)
            conn.commit()
            result["staged"] += 1
        except Exception as e:
            conn.rollback()
            reason = str(e).split("\n")[0]
            _insert_rejected(conn, rejected_table, columns, values, reason)
            _track_reason(result, reason)
            result["rejected"] += 1

    if result["staged"] > 0:
        merge_result = _upsert_from_tmp(conn, table, tmp_table, columns, key_fields)
        result["inserted"] = merge_result["inserted"]
        result["updated"]  = merge_result["updated"]

    _log(
        f"  [OK] {filename} → {tmp_table} → {table}: "
        f"{result['staged']} staged, {result['inserted']} inserted, "
        f"{result['updated']} updated, {result['rejected']} rejected"
    )
    return result


def load_subscriptions(conn) -> dict:
    result = {"table": "raw_pulsefit.raw_subscriptions", "file": "subscriptions.json",
              "tmp_table": "raw_pulsefit.raw_subscriptions_tmp",
              "staged": 0, "inserted": 0, "updated": 0,
              "rejected": 0, "rejection_reasons": {}}
    filepath = os.path.join(DATA_DIR, "subscriptions.json")

    try:
        with open(filepath) as f:
            data = json.load(f)
    except FileNotFoundError:
        result["error"] = f"File not found: {filepath}"
        _log(f"  [FAIL] subscriptions.json: file not found")
        return result

    columns = ["subscription_id", "user_id", "plan", "amount_usd",
               "start_date", "end_date", "status", "renewal_history", "content_hash"]
    _ensure_rejected_table(conn, "raw_pulsefit.raw_subscriptions",
                           [(c, "TEXT") for c in columns])
    _truncate_table(conn, "raw_pulsefit.raw_subscriptions_tmp")

    hash_fields = ["subscription_id", "user_id", "plan", "amount_usd",
                   "start_date", "end_date", "status", "renewal_history"]

    for row in data:
        sub_id  = row.get("subscription_id")
        user_id = row.get("user_id")

        if not sub_id or not user_id:
            missing = [f for f in ["subscription_id", "user_id"] if not row.get(f)]
            reason = f"null_required_field: {', '.join(missing)}"
            _insert_rejected(conn, "raw_pulsefit.raw_subscriptions_rejected",
                             columns, [str(row.get(c, "")) for c in columns], reason)
            _track_reason(result, reason)
            result["rejected"] += 1
            continue

        content_hash = _row_hash({k: str(row.get(k, "") or "") for k in hash_fields}, hash_fields)

        try:
            with conn.cursor() as cur:
                cur.execute("""
                    INSERT INTO raw_pulsefit.raw_subscriptions_tmp
                        (subscription_id, user_id, plan, amount_usd,
                         start_date, end_date, status, renewal_history, content_hash)
                    VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
                """, (
                    sub_id,
                    user_id,
                    row.get("plan"),
                    row.get("amount_usd"),
                    _parse_date(row.get("start_date")),
                    _parse_date(row.get("end_date")),
                    row.get("status"),
                    json.dumps(row.get("renewal_history", [])),
                    content_hash,
                ))
            conn.commit()
            result["staged"] += 1
        except Exception as e:
            conn.rollback()
            reason = str(e).split("\n")[0]
            _insert_rejected(conn, "raw_pulsefit.raw_subscriptions_rejected",
                             columns, [str(row.get(c, "")) for c in columns], reason)
            _track_reason(result, reason)
            result["rejected"] += 1

    if result["staged"] > 0:
        merge_result = _upsert_from_tmp(
            conn,
            "raw_pulsefit.raw_subscriptions",
            "raw_pulsefit.raw_subscriptions_tmp",
            columns,
            ["subscription_id"],
        )
        result["inserted"] = merge_result["inserted"]
        result["updated"]  = merge_result["updated"]

    _log(
        "  [OK] subscriptions.json → raw_subscriptions_tmp → raw_subscriptions: "
        f"{result['staged']} staged, {result['inserted']} inserted, "
        f"{result['updated']} updated, {result['rejected']} rejected"
    )
    return result


def load_data(conn) -> list[dict]:
    _log("[STEP 2] Loading data")
    results = []
    for table, tmp_table, filename, required, key_fields in CSV_SOURCES:
        results.append(load_csv(conn, table, tmp_table, filename, required, key_fields))
    results.append(load_subscriptions(conn))
    return results


# ── 3. Output ─────────────────────────────────────────────────────────────────

def save_output(schema_result: dict, load_results: list[dict]) -> str:
    os.makedirs(OUTPUTS_DIR, exist_ok=True)
    script_name = os.path.splitext(os.path.basename(__file__))[0]
    run_ts      = datetime.now().strftime("%Y%m%d_%H%M%S")
    out_file    = os.path.join(OUTPUTS_DIR, f"{script_name}_{run_ts}.json")

    summary = {
        "run_at":         datetime.now().isoformat(),
        "schema":         schema_result,
        "loads":          load_results,
        "total_inserted": sum(r.get("inserted", 0) for r in load_results),
        "total_updated":  sum(r.get("updated",  0) for r in load_results),
        "total_rejected": sum(r.get("rejected", 0) for r in load_results),
    }

    with open(out_file, "w") as f:
        json.dump(summary, f, indent=2, default=str)

    _log(f"[OUTPUT] Saved → {out_file}")
    return out_file


# ── Helpers ───────────────────────────────────────────────────────────────────

def _log(msg: str):
    print(msg)

def _track_reason(result: dict, reason: str):
    result["rejection_reasons"][reason] = result["rejection_reasons"].get(reason, 0) + 1

def _row_hash(row: dict, columns: list[str]) -> str:
    values = [str(row.get(column) or "") for column in columns]
    return hashlib.md5("\x1f".join(values).encode("utf-8")).hexdigest()

def _truncate_table(conn, table: str):
    with conn.cursor() as cur:
        cur.execute(f"TRUNCATE TABLE {table}")
    conn.commit()

def _upsert_from_tmp(conn, table: str, tmp_table: str,
                     columns: list[str], key_fields: list[str]) -> dict:
    """
    Merge staging → raw using content_hash to classify each row:
      - new key                      → INSERT
      - same key, different hash     → UPDATE (source correction)
      - same key, identical hash     → skip  (true duplicate, no-op)

    Uses PostgreSQL xmax trick to distinguish inserts from updates in RETURNING.
    """
    conflict_cols = ", ".join(key_fields)
    non_key_cols  = [c for c in columns if c not in key_fields]
    update_set    = ", ".join(f"{c} = EXCLUDED.{c}" for c in non_key_cols)
    update_set   += ", ingested_at = NOW()"
    col_list      = ", ".join(columns)

    partition_cols = ", ".join(key_fields)

    with conn.cursor() as cur:
        cur.execute(f"""
            WITH deduped AS (
                SELECT {col_list}
                FROM (
                    SELECT {col_list},
                           ROW_NUMBER() OVER (
                               PARTITION BY {partition_cols}
                               ORDER BY ingested_at DESC
                           ) AS rn
                    FROM {tmp_table}
                ) t
                WHERE rn = 1
            ),
            upserted AS (
                INSERT INTO {table} ({col_list})
                SELECT {col_list} FROM deduped
                ON CONFLICT ({conflict_cols}) DO UPDATE
                    SET {update_set}
                    WHERE {table}.content_hash IS DISTINCT FROM EXCLUDED.content_hash
                RETURNING (xmax = 0) AS is_insert
            )
            SELECT
                COUNT(*) FILTER (WHERE is_insert)      AS inserted,
                COUNT(*) FILTER (WHERE NOT is_insert)  AS updated
            FROM upserted
        """)
        row = cur.fetchone()
    conn.commit()
    return {"inserted": row[0], "updated": row[1]}

def _insert_rejected(conn, rejected_table: str, columns: list, values: list, reason: str):
    col_list     = ", ".join(columns) + ", rejection_reason"
    placeholders = ", ".join(["%s"] * (len(columns) + 1))
    existing_predicate = " AND ".join(
        f"existing.{column} IS NOT DISTINCT FROM %s" for column in columns
    )
    try:
        with conn.cursor() as cur:
            cur.execute(f"""
                INSERT INTO {rejected_table} ({col_list})
                SELECT {placeholders}
                WHERE NOT EXISTS (
                    SELECT 1
                    FROM {rejected_table} existing
                    WHERE {existing_predicate}
                      AND existing.rejection_reason IS NOT DISTINCT FROM %s
                )
            """, (
                [str(v) if v is not None else None for v in values] + [reason]
                + [str(v) if v is not None else None for v in values] + [reason]
            ))
        conn.commit()
    except Exception:
        conn.rollback()

def _parse_date(val) -> date | None:
    if not val:
        return None
    for fmt in ("%Y-%m-%d", "%d.%m.%Y", "%d/%m/%Y"):
        try:
            return datetime.strptime(val, fmt).date()
        except ValueError:
            continue
    return None


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    _log("=" * 60)
    _log("ingest_raw.py — raw layer ingestion")
    _log("=" * 60)

    conn = psycopg2.connect(dbname=DB_NAME)
    try:
        _log("[STEP 1] Creating and validating schema")
        schema_result = create_schema(conn)

        if schema_result["status"] != "ok":
            _log("[ABORT] Schema creation failed — skipping data load")
            save_output(schema_result, [])
            sys.exit(1)

        load_results = load_data(conn)

        out_file = save_output(schema_result, load_results)

        total_inserted = sum(r.get("inserted", 0) for r in load_results)
        total_updated  = sum(r.get("updated",  0) for r in load_results)
        total_rejected = sum(r.get("rejected", 0) for r in load_results)
        _log("=" * 60)
        _log(f"DONE — inserted: {total_inserted}  updated: {total_updated}  rejected: {total_rejected}")
        _log(f"       output saved: {out_file}")
        _log("=" * 60)
    finally:
        conn.close()


if __name__ == "__main__":
    main()
