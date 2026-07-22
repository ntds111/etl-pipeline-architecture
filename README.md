# Data Engineer Take-Home

## Part 1 — ETL Pipeline

**Tools:** PostgreSQL 14+, Python 3.10+, psycopg2

Four-source pipeline for the Pulsefit fitness app. Raw data lands in `raw_pulsefit`,
is cleaned and validated into `build_pulsefit`, then modelled into the `star_pulsefit`
star schema. Rejected rows are stored in `_rejected` tables with a `rejection_reason`.

### Setup (first time only)

```bash
# Create the database (skip if already exists)
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

## Part 2 — Architecture

See [architecture/concept.md](architecture/concept.md) for the AWS deployment concept:
EventBridge Scheduler → Step Functions → Lambda A (file fetch) → Lambda B (ETL) → Aurora Serverless v2.
