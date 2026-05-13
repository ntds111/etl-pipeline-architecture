# Data Engineer Take-Home

## Part 1 — SQL Foundations

**Tools:** PostgreSQL 14+, Python 3.10+, psycopg2, matplotlib

Three analytical queries against a small ecommerce dataset (customers, orders, order_items).
All objects live in the `ecommerce` schema to keep Part 1 isolated from Part 2.

### Setup

Run all commands from the repo root.

```bash
# Create the database (skip if already exists)
createdb takehome_db 2>/dev/null || true

# Option A — Python loader (recommended): creates schema + loads all CSVs in one step
pip install -r requirements.txt
python3 test1/python/load_ecommerce.py

# Option B — manual psql
psql takehome_db -f test1/sql/schema_ecommerce.sql
psql takehome_db -c "\copy ecommerce.customers   FROM 'test1/data/customers.csv'   CSV HEADER"
psql takehome_db -c "\copy ecommerce.orders       FROM 'test1/data/orders.csv'       CSV HEADER"
psql takehome_db -c "\copy ecommerce.order_items  FROM 'test1/data/order_items.csv'  CSV HEADER"
```

**Known data quality issues in the provided CSVs:**

| Table | Column | Issue | Affected row | Status |
|---|---|---|---|---|
| `customers` | `country` | `UK` is not a valid ISO 3166-1 alpha-2 code — corrected to `GB` | C011 Velvet Finance | Fixed in CSV |
| `orders` | `status` | 3 orders (`O1010`, `O2006`, `O2019`) are `cancelled`/`refunded` but still have line items — likely intentional for audit trail | — | Accepted |

No nulls in required fields, no duplicate PKs, no orphan FKs, no orders placed before customer signup date.

### Run queries

```bash
psql takehome_db -f test1/sql/q1_revenue_per_customer.sql  # total revenue per customer
psql takehome_db -f test1/sql/q2_top3_per_month.sql        # top 3 customers by revenue per month
psql takehome_db -f test1/sql/q3_reactivated_customers.sql # customers reactivated after 90-day gap
```

---

## Part 2 — ETL Pipeline

**Tools:** PostgreSQL 14+, Python 3.10+, psycopg2

Four-source pipeline for the Pulsefit fitness app. Raw data lands in `raw_pulsefit`,
is cleaned and validated into `build_pulsefit`, then modelled into the `star_pulsefit`
star schema. Rejected rows are stored in `_rejected` tables with a `rejection_reason`.

### Setup (first time only)

```bash
# Create the database (skip if already exists or if you ran Part 1 setup)
createdb takehome_db 2>/dev/null || true

python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

### Run pipeline

```bash
source .venv/bin/activate

# Stage and upsert raw data (also creates/migrates raw schema on first run)
python3 test2/etl/python/ingest_raw.py

# Build clean layer and star schema
python3 test2/etl/python/pipeline.py
```

Build-layer DQ summary (latest run):

| Table | Raw | Built | Rejected | Rejection reasons |
|---|---|---|---|---|
| users | 500 | 500 | 0 | — |
| events | 3232 | 3102 | 130 | null_event_timestamp (78), no_crm_user (32), malformed_properties_json (20) |
| ad_spend | 161 | 154 | 6 | non_positive_spend |
| subscriptions | 110 | 110 | 0 | — |

### Analytical queries

```bash
psql takehome_db -f test2/etl/queries/q1_cac_per_channel.sql    # Q1: blended cost per install per paid channel
psql takehome_db -f test2/etl/queries/q2_funnel_conversion.sql  # Q2: funnel conversion rates per channel
psql takehome_db -f test2/etl/queries/q3_surprising_finding.sql # Q3: subscription date coverage gap
```

---

## Part 3 — Architecture

See [architecture/concept.md](architecture/concept.md) for the AWS deployment concept:
EventBridge Scheduler → Step Functions → Lambda A (file fetch) → Lambda B (ETL) → Aurora Serverless v2.
