# Data Engineer Take-Home

---

## Part 1 — SQL Foundations

**Tools:** PostgreSQL 14+, Python 3.10+, psycopg2, matplotlib

Three analytical queries against a small ecommerce dataset (customers, orders, order_items).
All objects live in the `ecommerce` schema to keep Part 1 isolated from Part 2.

### Setup

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

> **Warning — run from your project root.**
> Both the Python loader and the `psql -f` commands must be run from the
> directory where you cloned this repo (e.g. `cd /your/path/to/take-home-task-data-engineering`).
> Adjust the path to match your local setup before running any commands.
> Running from a different directory causes a "file not found" error or silently
> connects without creating the schema — if `\dn` inside psql shows no schemas
> after setup, this is almost certainly the cause.

**Known data quality issues in the provided CSVs:**

| Table | Column | Issue | Affected row | Status |
|---|---|---|---|---|
| `customers` | `country` | `UK` is not a valid ISO 3166-1 alpha-2 code — corrected to `GB` | C011 Velvet Finance | Fixed in CSV |
| `orders` | `status` | 3 orders (`O1010`, `O2006`, `O2019`) are `cancelled`/`refunded` but still have line items — likely intentional for audit trail | — | Accepted |

No nulls in required fields, no duplicate PKs, no orphan FKs, no orders placed before customer signup date.

**Indexes defined in schema:**
- `idx_orders_customer_id` on `orders(customer_id)` — speeds up `orders → customers` join
- `idx_order_items_order_id` on `order_items(order_id)` — speeds up `order_items → orders` join
- PK columns are auto-indexed by PostgreSQL — no separate index needed

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

Each row carries a `content_hash` (MD5 of all source fields). Python stages each source
into a same-shape `_tmp` table, deduplicates by conflict key (keeping the latest row),
then upserts into the persistent raw table using
`ON CONFLICT ... DO UPDATE WHERE content_hash IS DISTINCT FROM EXCLUDED.content_hash`.
Three outcomes per row:

- **New key** → INSERT
- **Same key, different hash** → UPDATE (source correction)
- **Same key, same hash** → no-op (true duplicate, nothing written)

Ad spend has no source-provided primary key. `raw_ad_spend_id` is set to `content_hash`
(hash of all source columns) and the conflict key is `content_hash` itself — exact duplicate
rows are silently skipped. Multiple rows with the same campaign + date but different metric
values (corrections) are all kept in raw; the build layer picks the latest by `ingested_at`
via `ROW_NUMBER() OVER (PARTITION BY date, channel, country_code, campaign_name ORDER BY ingested_at DESC)`.

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
# — runs raw_pulsefit.sql to create/migrate schema
# — stages CSVs + JSON into _tmp tables, deduplicates, upserts into raw tables
# — saves run summary to test2/etl/outputs/ingest_raw_YYYYMMDD_HHMMSS.json

# Build clean layer and star schema
python3 test2/etl/python/pipeline.py
# — executes build_pulsefit.sql → 8-step validation → executes star_pulsefit.sql
# — aborts before star if build acceptance tests fail
# — saves run summary to test2/etl/outputs/pipeline_YYYYMMDD_HHMMSS.json
```

Raw ingestion is idempotent: each run truncates only the `_tmp` staging tables, then
upserts into the persistent raw tables. Re-running with identical data is a complete
no-op. Build and star are full-refresh layers — their SQL files drop and recreate the
derived schemas so downstream outputs can be replayed cleanly from the current raw state.

Raw conflict keys (used for ON CONFLICT upsert):
- `raw_users`: `user_id`
- `raw_events`: `event_id`
- `raw_ad_spend`: `content_hash` (MD5 of all source columns)
- `raw_subscriptions`: `subscription_id`

Build-layer DQ summary (latest run):

| Table | Raw | Built | Rejected | Rejection reasons |
|---|---|---|---|---|
| users | 500 | 500 | 0 | — |
| events | 3232 | 3102 | 130 | null_event_timestamp (78), no_crm_user (32), malformed_properties_json (20) |
| ad_spend | 161 | 154 | 6 | non_positive_spend |
| subscriptions | 110 | 110 | 0 | — |

In production, the same intermediate datasets would also be archived to S3 with a source
batch ID and load timestamp. In this local repo, the PostgreSQL raw layer is the working
copy and `test2/etl/outputs/*.json` stores run metadata.

### Analytical queries

```bash
psql takehome_db -f test2/etl/queries/q1_cac_per_channel.sql    # Q1: blended cost per install per paid channel
psql takehome_db -f test2/etl/queries/q2_funnel_conversion.sql  # Q2: funnel conversion rates per channel
psql takehome_db -f test2/etl/queries/q3_surprising_finding.sql # Q3: subscription date coverage gap
```

---

## Part 3 — Architecture

See [architecture/concept.md](architecture/concept.md) for the AWS-based automation concept
(S3 → Lambda → Airflow/MWAA → dbt on ECS Fargate → Redshift).
