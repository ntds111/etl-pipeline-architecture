"""
validators/utils.py — shared helpers for all validator modules.
"""


def log(msg: str):
    print(msg)


def run_check(conn, label: str, query: str, expect_zero: bool = True) -> tuple[str, int]:
    with conn.cursor() as cur:
        cur.execute(query)
        count = cur.fetchone()[0]
    status = "ok" if (count == 0) == expect_zero else "failed"
    icon   = "[OK]" if status == "ok" else "[FAIL]"
    log(f"  {icon} {label}: {count}")
    return status, count
