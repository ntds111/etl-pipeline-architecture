"""
pipeline.py — orchestrates the build + star ETL pipeline.

Steps:
  1.  run build SQL
  2.  check build (dq_log + rejected reasons)
  3.  referential integrity: raw → build          [abort if failed]
  4.  layer acceptance tests: build before star   [abort if failed]
  5.  run star SQL
  6.  check star (row counts)
  7.  referential integrity: build → star
  8.  cross-layer count reconciliation
"""

import os
import sys

import psycopg2

import sql_executor
import output
from validators.build_checks import check_build, referential_integrity_raw_to_build, acceptance_build
from validators.star_checks  import check_star,  referential_integrity_build_to_star, compare_layers

DB_NAME     = "calimoto_data"
BASE_DIR    = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD_SQL   = os.path.join(BASE_DIR, "sql", "build_pulsefit.sql")
STAR_SQL    = os.path.join(BASE_DIR, "sql", "star_pulsefit.sql")
OUTPUTS_DIR = os.path.join(BASE_DIR, "outputs")
SCRIPT_NAME = os.path.splitext(os.path.basename(__file__))[0]


def main():
    print("=" * 60)
    print("pipeline.py — build + star layer execution")
    print("=" * 60)

    conn      = psycopg2.connect(dbname=DB_NAME)
    collected = []

    def abort(reason: str):
        print(f"[ABORT] {reason}")
        output.save(collected, OUTPUTS_DIR, SCRIPT_NAME)
        conn.close()
        sys.exit(1)

    try:
        print("\n[STEP 1] Running build layer")
        r = sql_executor.run(conn, BUILD_SQL); collected.append(r)
        if r["status"] != "ok": abort("Build SQL failed")

        print("\n[STEP 2] Checking build layer (dq_log + rejected)")
        r = check_build(conn); collected.append(r)
        if r["status"] != "ok": abort("Build check failed")

        print("\n[STEP 3] Referential integrity: raw → build")
        r = referential_integrity_raw_to_build(conn); collected.append(r)
        if r["status"] != "ok": abort("RI raw→build violations found")

        print("\n[STEP 4] Layer acceptance tests: build before star")
        r = acceptance_build(conn); collected.append(r)
        if r["status"] != "ok": abort("Build acceptance tests failed — not safe to promote to star")

        print("\n[STEP 5] Running star layer")
        r = sql_executor.run(conn, STAR_SQL); collected.append(r)
        if r["status"] != "ok": abort("Star SQL failed")

        print("\n[STEP 6] Checking star layer (row counts)")
        r = check_star(conn); collected.append(r)

        print("\n[STEP 7] Referential integrity: build → star")
        r = referential_integrity_build_to_star(conn); collected.append(r)

        print("\n[STEP 8] Cross-layer count reconciliation")
        r = compare_layers(conn); collected.append(r)

        out_file = output.save(collected, OUTPUTS_DIR, SCRIPT_NAME)

        print("\n" + "=" * 60)
        print("DONE")
        for step in collected:
            print(f"  {step['step']:<35} {step['status']}")
        print(f"\n  output → {out_file}")
        print("=" * 60)

    finally:
        conn.close()


if __name__ == "__main__":
    main()
