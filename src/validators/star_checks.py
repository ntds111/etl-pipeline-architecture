"""
validators/star_checks.py — all validation for the star_pulsefit layer.

  check_star()       row counts across all star tables
  referential_integrity_build_to_star() referential integrity: build → star
  compare_layers()   count reconciliation build vs star
"""

from .utils import log, run_check

STAR_TABLES = [
    "dim_channel", "dim_date", "dim_user",
    "fact_events", "fact_ad_spend",
]


def check_star(conn) -> dict:
    result = {"step": "check_star", "status": None, "tables": {}, "errors": []}

    for table in STAR_TABLES:
        try:
            with conn.cursor() as cur:
                cur.execute(f"SELECT COUNT(*) FROM star_pulsefit.{table}")
                count = cur.fetchone()[0]
            result["tables"][table] = count
            if count == 0:
                result["errors"].append(f"star_pulsefit.{table} has 0 rows")
            log(f"  star_pulsefit.{table}: {count} rows")
        except Exception as e:
            result["errors"].append(str(e))
            result["tables"][table] = None
            log(f"  [ERROR] star_pulsefit.{table}: {e}")

    result["status"] = "failed" if result["errors"] else "ok"
    log(f"[{result['status'].upper()}] check_star complete")
    return result


def referential_integrity_build_to_star(conn) -> dict:
    result = {"step": "referential_integrity_build_to_star", "status": None, "checks": [], "errors": []}

    # Informational: null channel_id is legitimate (users with no acquisition channel).
    # Reported as a warning, not a failure.
    with conn.cursor() as cur:
        cur.execute("SELECT COUNT(*) FROM star_pulsefit.dim_user WHERE channel_id IS NULL")
        null_ch = cur.fetchone()[0]
    log(f"  {'[WARN]' if null_ch > 0 else '[OK]'} dim_user: null channel_id (users with no acquisition channel): {null_ch}")
    result["checks"].append({"check": "dim_user: null channel_id", "count": null_ch, "status": "warning" if null_ch > 0 else "ok"})

    checks = [
        ("build.users not in dim_user (users dropped during star load)",
         """SELECT COUNT(*) FROM build_pulsefit.users
            WHERE user_id NOT IN (SELECT user_id FROM star_pulsefit.dim_user)"""),
        ("build.events not in fact_events (events dropped during star load)",
         """SELECT COUNT(*) FROM build_pulsefit.events
            WHERE event_id NOT IN (SELECT event_id FROM star_pulsefit.fact_events)"""),
        ("build.ad_spend rows not in fact_ad_spend",
         """SELECT COUNT(*) FROM build_pulsefit.ad_spend a
            WHERE NOT EXISTS (
                SELECT 1 FROM star_pulsefit.fact_ad_spend f
                WHERE f.raw_ad_spend_id = a.raw_ad_spend_id
            )"""),
        ("fact_events: null channel_id",
         "SELECT COUNT(*) FROM star_pulsefit.fact_events WHERE channel_id IS NULL"),
        ("fact_events: null date_key",
         "SELECT COUNT(*) FROM star_pulsefit.fact_events WHERE date_key IS NULL"),
        # Per-table date coverage: every date used in a fact/dim must exist in dim_date
        ("users: install_date not covered by dim_date",
         """SELECT COUNT(*) FROM build_pulsefit.users
            WHERE install_date IS NOT NULL
              AND install_date::DATE NOT IN (SELECT date_key FROM star_pulsefit.dim_date)"""),
        ("events: event_timestamp not covered by dim_date",
         """SELECT COUNT(*) FROM build_pulsefit.events
            WHERE event_timestamp IS NOT NULL
              AND event_timestamp::DATE NOT IN (SELECT date_key FROM star_pulsefit.dim_date)"""),
        ("ad_spend: date not covered by dim_date",
         """SELECT COUNT(*) FROM build_pulsefit.ad_spend
            WHERE date IS NOT NULL
              AND date NOT IN (SELECT date_key FROM star_pulsefit.dim_date)"""),
        ("subscriptions: start_date not covered by dim_date",
         """SELECT COUNT(*) FROM build_pulsefit.subscriptions
            WHERE start_date IS NOT NULL
              AND start_date NOT IN (SELECT date_key FROM star_pulsefit.dim_date)"""),
        ("subscriptions: end_date not covered by dim_date",
         """SELECT COUNT(*) FROM build_pulsefit.subscriptions
            WHERE end_date IS NOT NULL
              AND end_date NOT IN (SELECT date_key FROM star_pulsefit.dim_date)"""),
    ]

    for label, query in checks:
        status, count = run_check(conn, label, query)
        result["checks"].append({"check": label, "count": count, "status": status})
        if status == "failed":
            result["errors"].append(f"{label}: {count} violations")

    result["status"] = "failed" if result["errors"] else "ok"
    log(f"[{result['status'].upper()}] referential_integrity_build_to_star complete")
    return result


def compare_layers(conn) -> dict:
    result = {"step": "compare_layers", "status": None, "comparisons": [], "errors": []}

    checks = [
        ("users → dim_user",
         "SELECT COUNT(*) FROM build_pulsefit.users",       "build_pulsefit.users row count",
         "SELECT COUNT(*) FROM star_pulsefit.dim_user",     "star_pulsefit.dim_user row count"),
        ("events → fact_events",
         "SELECT COUNT(*) FROM build_pulsefit.events",      "build_pulsefit.events row count",
         "SELECT COUNT(*) FROM star_pulsefit.fact_events",  "star_pulsefit.fact_events row count"),
        ("ad_spend → fact_ad_spend",
         "SELECT COUNT(*) FROM build_pulsefit.ad_spend",    "build_pulsefit.ad_spend row count",
         "SELECT COUNT(*) FROM star_pulsefit.fact_ad_spend","star_pulsefit.fact_ad_spend row count"),
        ("dim_channel (expect 6)",
         "SELECT 6",                                        "hardcoded expected channel count",
         "SELECT COUNT(*) FROM star_pulsefit.dim_channel",  "star_pulsefit.dim_channel row count"),
        ("dim_date spine contiguous (no gaps)",
         "SELECT MAX(date_key) - MIN(date_key) + 1 FROM star_pulsefit.dim_date", "expected days in date range (max − min + 1)",
         "SELECT COUNT(*) FROM star_pulsefit.dim_date",                           "actual rows in dim_date"),
    ]

    for label, left_q, left_label, right_q, right_label in checks:
        with conn.cursor() as cur:
            cur.execute(left_q);  left  = cur.fetchone()[0]
            cur.execute(right_q); right = cur.fetchone()[0]

        delta  = right - left
        status = "ok" if delta == 0 else "mismatch"
        result["comparisons"].append({
            "check":       label,
            "left_label":  left_label,  "left":  left,
            "right_label": right_label, "right": right,
            "delta":       delta,
            "status":      status,
        })

        if status == "mismatch":
            result["errors"].append(f"{label}: left={left} right={right} delta={delta:+d}")
            log(f"  [MISMATCH] {label}: left={left}  right={right}  delta={delta:+d}")
        else:
            log(f"  [OK] {label}: {right}")

    result["status"] = "failed" if result["errors"] else "ok"
    log(f"[{result['status'].upper()}] compare_layers complete")
    return result
