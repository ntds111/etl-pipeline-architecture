"""
validators/build_checks.py — all validation for the build_pulsefit layer.

  check_build()      dq_log counts + rejected reason breakdown
  referential_integrity_raw_to_build()  referential integrity: raw → build
  acceptance_build() layer acceptance tests before promoting to star
"""

from .utils import log, run_check

KNOWN_CHANNELS = (
    "facebook", "google_ads", "tiktok",
    "apple_search_ads", "organic", "referral",
)


def check_build(conn) -> dict:
    result = {"step": "check_build", "status": None, "tables": {}, "errors": []}

    with conn.cursor() as cur:
        cur.execute("""
            SELECT table_name, raw_count, built_count, rejected_count
            FROM build_pulsefit.dq_log ORDER BY table_name
        """)
        dq_rows = cur.fetchall()

    if not dq_rows:
        result["status"] = "failed"
        result["errors"].append("dq_log is empty — build may not have run")
        log("[FAIL] check_build: dq_log empty")
        return result

    for table_name, raw_count, built_count, rejected_count in dq_rows:
        entry = {
            "raw_count":        raw_count,
            "built_count":      built_count,
            "rejected_count":   rejected_count,
            "rejected_reasons": {},
        }
        if built_count == 0 and raw_count > 0:
            result["errors"].append(f"{table_name}: 0 rows built from {raw_count} raw")

        try:
            with conn.cursor() as cur:
                cur.execute(f"""
                    SELECT rejection_reason, COUNT(*) FROM build_pulsefit.{table_name}_rejected
                    GROUP BY rejection_reason ORDER BY 2 DESC
                """)
                entry["rejected_reasons"] = {r: c for r, c in cur.fetchall()}
        except Exception as e:
            conn.rollback()
            log(f"  [WARN] could not read {table_name}_rejected: {e}")

        result["tables"][table_name] = entry
        log(
            f"  {table_name}: raw={raw_count}  built={built_count}  rejected={rejected_count}"
            + (f"  → {entry['rejected_reasons']}" if rejected_count > 0 else "")
        )

    result["status"] = "failed" if result["errors"] else "ok"
    log(f"[{result['status'].upper()}] check_build complete")
    return result


def referential_integrity_raw_to_build(conn) -> dict:
    result = {"step": "referential_integrity_raw_to_build", "status": None, "checks": [], "errors": []}

    # Warnings: orphans in raw are expected — the build SQL routes them to _rejected tables.
    # Events orphans split into cascade_rejection (user in CRM, rejected from build)
    # and no_crm_user (freemium churner, never created an account).
    # These are informational only and do not cause an abort.
    warnings = [
        (
            "raw_events: cascade_rejection (user in CRM but rejected from build)",
            """SELECT COUNT(*) FROM raw_pulsefit.raw_events r
               WHERE r.user_id NOT IN (SELECT user_id FROM build_pulsefit.users)
                 AND r.user_id IN     (SELECT user_id FROM raw_pulsefit.raw_users)""",
        ),
        (
            "raw_events: no_crm_user (freemium churner — expected, not a data error)",
            """SELECT COUNT(*) FROM raw_pulsefit.raw_events r
               WHERE r.user_id NOT IN (SELECT user_id FROM build_pulsefit.users)
                 AND r.user_id NOT IN (SELECT user_id FROM raw_pulsefit.raw_users)""",
        ),
        (
            "raw_subscriptions: orphan user_ids (expected — captured in subscriptions_rejected)",
            """SELECT COUNT(*) FROM raw_pulsefit.raw_subscriptions
               WHERE user_id NOT IN (SELECT user_id FROM build_pulsefit.users)
                  OR user_id IS NULL""",
        ),
    ]
    for label, query in warnings:
        with conn.cursor() as cur:
            cur.execute(query)
            count = cur.fetchone()[0]
        log(f"  {'[WARN]' if count > 0 else '[OK]'} {label}: {count}")
        result["checks"].append({"check": label, "count": count, "status": "warning" if count > 0 else "ok"})

    # Hard checks: orphans that slipped into the build layer without being rejected.
    # These are real integrity breaches and cause an abort.
    hard_checks = [
        (
            "build.events: user_id not in build.users (integrity breach)",
            """SELECT COUNT(*) FROM build_pulsefit.events
               WHERE user_id NOT IN (SELECT user_id FROM build_pulsefit.users)""",
        ),
        (
            "build.subscriptions: user_id not in build.users (integrity breach)",
            """SELECT COUNT(*) FROM build_pulsefit.subscriptions
               WHERE user_id NOT IN (SELECT user_id FROM build_pulsefit.users)""",
        ),
    ]
    for label, query in hard_checks:
        status, count = run_check(conn, label, query)
        result["checks"].append({"check": label, "count": count, "status": status})
        if status == "failed":
            result["errors"].append(f"{label}: {count} violations")

    result["status"] = "failed" if result["errors"] else "ok"
    log(f"[{result['status'].upper()}] referential_integrity_raw_to_build complete")
    return result


def acceptance_build(conn) -> dict:
    result = {"step": "acceptance_build", "status": None, "checks": [], "errors": []}

    known_ch = ", ".join(f"'{c}'" for c in KNOWN_CHANNELS)

    checks = [
        # Uniqueness
        ("build.users: duplicate user_id",
         "SELECT COUNT(*) FROM (SELECT user_id FROM build_pulsefit.users GROUP BY user_id HAVING COUNT(*) > 1) t"),
        ("build.events: duplicate event_id",
         "SELECT COUNT(*) FROM (SELECT event_id FROM build_pulsefit.events GROUP BY event_id HAVING COUNT(*) > 1) t"),
        ("build.ad_spend: duplicate raw_ad_spend_id",
         "SELECT COUNT(*) FROM (SELECT raw_ad_spend_id FROM build_pulsefit.ad_spend GROUP BY raw_ad_spend_id HAVING COUNT(*) > 1) t"),
        ("build.subscriptions: duplicate subscription_id",
         "SELECT COUNT(*) FROM (SELECT subscription_id FROM build_pulsefit.subscriptions GROUP BY subscription_id HAVING COUNT(*) > 1) t"),
        # Null key fields
        ("build.users: null user_id",
         "SELECT COUNT(*) FROM build_pulsefit.users WHERE user_id IS NULL"),
        ("build.events: null event_id",
         "SELECT COUNT(*) FROM build_pulsefit.events WHERE event_id IS NULL"),
        ("build.events: null user_id",
         "SELECT COUNT(*) FROM build_pulsefit.events WHERE user_id IS NULL"),
        ("build.events: null event_timestamp",
         "SELECT COUNT(*) FROM build_pulsefit.events WHERE event_timestamp IS NULL"),
        # Channel resolution — unrecognized raw values already map to NULL in build_pulsefit.sql
        # (CASE ELSE NULL). NULL channel → NULL channel_id in star, reported as a warning there.
        # Hard check: non-null value that somehow bypassed the CASE mapping (should never happen)
        ("build.users: non-null channel not in known list (mapping bypass)",
         f"SELECT COUNT(*) FROM build_pulsefit.users WHERE channel IS NOT NULL AND channel NOT IN ({known_ch})"),
        # Date spine coverage — dim_date is dynamic so flag anything outside the full build range
        ("build.events: dates outside full build date range",
         """SELECT COUNT(*) FROM build_pulsefit.events
            WHERE event_timestamp::DATE < LEAST(
                (SELECT MIN(install_date::DATE)    FROM build_pulsefit.users         WHERE install_date    IS NOT NULL),
                (SELECT MIN(event_timestamp::DATE) FROM build_pulsefit.events        WHERE event_timestamp IS NOT NULL),
                (SELECT MIN(date)                  FROM build_pulsefit.ad_spend       WHERE date            IS NOT NULL),
                (SELECT MIN(start_date)            FROM build_pulsefit.subscriptions  WHERE start_date      IS NOT NULL)
            )
            OR event_timestamp::DATE > GREATEST(
                (SELECT MAX(install_date::DATE)    FROM build_pulsefit.users         WHERE install_date    IS NOT NULL),
                (SELECT MAX(event_timestamp::DATE) FROM build_pulsefit.events        WHERE event_timestamp IS NOT NULL),
                (SELECT MAX(date)                  FROM build_pulsefit.ad_spend       WHERE date            IS NOT NULL),
                (SELECT MAX(end_date)              FROM build_pulsefit.subscriptions  WHERE end_date        IS NOT NULL)
            )"""),
        # Reject rate thresholds
        ("build.users: reject rate > 30%",
         """SELECT CASE WHEN raw_count = 0 THEN 0
                 WHEN rejected_count * 100.0 / raw_count > 30 THEN 1 ELSE 0 END
            FROM build_pulsefit.dq_log WHERE table_name = 'users'"""),
        ("build.events: reject rate > 20%",
         """SELECT CASE WHEN raw_count = 0 THEN 0
                 WHEN rejected_count * 100.0 / raw_count > 20 THEN 1 ELSE 0 END
            FROM build_pulsefit.dq_log WHERE table_name = 'events'"""),
    ]

    for label, query in checks:
        status, count = run_check(conn, label, query)
        result["checks"].append({"check": label, "count": count, "status": status})
        if status == "failed":
            result["errors"].append(f"{label}: {count}")

    result["status"] = "failed" if result["errors"] else "ok"
    log(f"[{result['status'].upper()}] acceptance_build complete")
    return result
