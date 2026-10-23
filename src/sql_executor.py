"""
sql_executor.py — executes a SQL file against the database.
Single responsibility: open file, run, commit, return status.
"""

import os
import re


def _extract_tables(sql: str) -> list[str]:
    return re.findall(r"CREATE TABLE(?:\s+IF NOT EXISTS)?\s+([\w.]+)", sql, re.IGNORECASE)


def run(conn, sql_path: str) -> dict:
    """
    Executes a SQL file as a single atomic transaction.
    If any statement fails the entire file is rolled back — no partial state is left behind.
    """
    name   = os.path.basename(sql_path)
    result = {"step": f"run:{name}", "file": sql_path, "status": None, "tables_created": [], "error": None}
    try:
        with open(sql_path) as f:
            sql = f.read()

        tables = _extract_tables(sql)
        result["tables_created"] = tables

        conn.rollback()       # clear any open read-only transaction from prior validators
        conn.autocommit = False
        with conn.cursor() as cur:
            cur.execute(sql)
        conn.commit()
        result["status"] = "ok"
        print(f"[OK] {name} executed — tables: {', '.join(tables) if tables else 'none detected'}")
    except FileNotFoundError:
        result["status"] = "failed"
        result["error"]  = f"file not found: {sql_path}"
        conn.rollback()
        print(f"[FAIL] {name}: {result['error']}")
    except Exception as e:
        result["status"] = "failed"
        result["error"]  = str(e).split("\n")[0]
        conn.rollback()  # entire file rolled back — no partial state
        print(f"[FAIL] {name}: {result['error']}")
    return result
