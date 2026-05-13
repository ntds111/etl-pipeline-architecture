import os
import psycopg2
import csv

DB_NAME = "calimoto_data"
SQL_FILE = os.path.join(os.path.dirname(__file__), "..", "sql", "schema_ecommerce.sql")
DATA_DIR = os.path.join(os.path.dirname(__file__), "..", "data")

CSV_TABLES = [
    ("customers.csv",   "ecommerce.customers",   ["customer_id", "customer_name", "signup_date", "country"]),
    ("orders.csv",      "ecommerce.orders",      ["order_id", "customer_id", "order_date", "status"]),
    ("order_items.csv", "ecommerce.order_items", ["order_item_id", "order_id", "product_sku", "product_name", "quantity", "unit_price"]),
]


def create_schema(conn) -> bool:
    with open(SQL_FILE, "r") as f:
        sql = f.read()
    try:
        with conn.cursor() as cur:
            cur.execute(sql)
        conn.commit()
        print(f"[OK] Schema created from {os.path.basename(SQL_FILE)}")
        return True
    except Exception as e:
        conn.rollback()
        print(f"[FAIL] Schema creation failed: {e}")
        return False


def load_csv(conn, filename: str, table: str, columns: list[str]) -> bool:
    filepath = os.path.join(DATA_DIR, filename)
    try:
        with open(filepath, newline="", encoding="utf-8") as f:
            reader = csv.DictReader(f)
            rows = [tuple(row[c] or None for c in columns) for row in reader]
    except FileNotFoundError:
        print(f"[FAIL] File not found: {filepath}")
        return False

    placeholders = ", ".join(["%s"] * len(columns))
    col_list     = ", ".join(columns)
    sql          = f"INSERT INTO {table} ({col_list}) VALUES ({placeholders})"

    loaded = rejected = 0
    for row in rows:
        try:
            with conn.cursor() as cur:
                cur.execute(sql, row)
            conn.commit()
            loaded += 1
        except Exception as e:
            conn.rollback()
            rejected += 1
            print(f"  [SKIP] {filename} row {loaded + rejected}: {str(e).split(chr(10))[0]}")

    print(f"[OK] {filename} → {table}: {loaded} loaded, {rejected} rejected")
    return rejected == 0


def main():
    conn = psycopg2.connect(dbname=DB_NAME)
    try:
        ok = create_schema(conn)
        if not ok:
            print("Aborting: schema creation failed, skipping CSV loads.")
            return

        for filename, table, columns in CSV_TABLES:
            ok = load_csv(conn, filename, table, columns)
            if not ok:
                print(f"Aborting: {filename} had rejected rows — dependent tables skipped.")
                break
    finally:
        conn.close()


if __name__ == "__main__":
    main()
