# Pulsefit ETL Pipeline — Architecture

## Deployed Architecture — Serverless on AWS

![Serverless AWS architecture diagram](pipeline_architecture.png)

### Overview

The same Python pipeline, deployed to AWS Lambda and triggered on a daily schedule
by EventBridge Scheduler. Aurora Serverless v2 replaces local Postgres. Step
Functions orchestrates the two Lambda stages. No servers to manage, no cron daemons,
no persistent compute costs when idle.

### Architecture diagram

```
                    ┌─────────────────────────────────┐
                    │  EventBridge Scheduler           │
                    │  (daily cron, fixed schedule)    │
                    └──────────────┬──────────────────┘
                                   │  triggers
                                   ▼
                    ┌─────────────────────────────────┐
                    │  Step Functions                  │
                    │  (state machine, two steps)      │
                    └──────┬────────────────────┬──────┘
                           │                    │ on failure
                           │                    ▼
                           │             ┌─────────────┐
                           │             │  SQS DLQ    │  ◄── CloudWatch Alarm 1
                           │             └─────────────┘      (DLQ depth > 0)
                           │
              ┌────────────▼────────────┐
              │  Lambda A               │  ← outside VPC
              │  (file fetch + S3 upload)│
              │  Secrets Manager        │
              └────────────┬────────────┘
                           │  raw files → s3://pulsefit-data/raw/YYYYMMDD/
                           │  sentinel  → s3://pulsefit-data/run_status/YYYYMMDD.json
                           ▼
              ┌────────────────────────────┐
              │  Lambda B                  │  ← inside VPC
              │  (ingest + transform +     │
              │   validate + star + output)│
              │  Secrets Manager           │
              └────────────┬───────────────┘
                           │
              ┌────────────▼───────────────┐
              │  RDS Proxy                 │  ← mandatory for Lambda→Aurora
              └────────────┬───────────────┘
                           │
              ┌────────────▼───────────────┐
              │  Aurora Serverless v2      │
              │  (PostgreSQL-compatible)   │
              │  raw · build · star schemas│
              └────────────────────────────┘

CloudWatch Alarm 2: custom metric emitted by Lambda B on pipeline abort
→ SNS → email/Slack alert
```

### Components

#### EventBridge Scheduler

Triggers the Step Functions state machine on a daily cron. EventBridge Scheduler
(not EventBridge Rules) is used — it is the correct service for time-based invocations
and handles retries and delivery guarantees at the scheduler level.

```json
{
  "ScheduleExpression": "cron(0 6 * * ? *)",
  "Target": { "Arn": "<step-functions-state-machine-arn>" }
}
```

#### Step Functions

A two-state state machine: Lambda A → Lambda B. Step Functions manages sequencing
and surfaces execution history in the console. If either Lambda throws an unhandled
exception, Step Functions marks the execution as FAILED. An EventBridge rule watches
for Step Functions FAILED state changes and routes the event to the SQS DLQ — this
wiring is explicit configuration, not automatic.

#### Lambda A — file fetch (outside VPC)

Runs outside the VPC so it can reach external APIs and the internet.

Responsibilities:
- Check S3 sentinel (`run_status/YYYYMMDD.json`) before calling any API — skip if `status: completed`
- Call the source APIs (CRM export, analytics export, ad platform export, Stripe)
- Write raw files to S3 (`s3://pulsefit-data/raw/YYYYMMDD/`)
- Write sentinel with `status: fetched` after all files are uploaded
- Pass S3 paths to Lambda B via Step Functions output payload

Why outside VPC: Lambda inside a VPC cannot reach the internet unless a NAT Gateway
is added. NAT Gateways cost ~$32/month plus data charges. For a Lambda that only
needs to hit external APIs (no database), placing it outside the VPC avoids that cost.

#### Lambda B — ETL (inside VPC)

Runs inside the VPC so it can reach Aurora via RDS Proxy without exposing the
database publicly.

Responsibilities:
- Check S3 sentinel (`run_status/YYYYMMDD.json`) before starting — skip if `status: completed`
- Read raw files from S3
- Run ingest_raw logic (validate, load, reject routing)
- Run pipeline logic (build SQL → validate → star SQL → validate → output)
- Write output JSON to S3 (`run_logs/pipeline_YYYYMMDD_HHMMSS.json`)
- Update sentinel to `status: completed` on successful run
- Emit a CloudWatch custom metric if the abort gate fires

Why inside VPC: Aurora Serverless v2 lives in a private subnet. The only way
to reach it from Lambda without a public endpoint is to place Lambda in the
same VPC. RDS Proxy sits between Lambda B and Aurora to handle connection pooling
(Lambda can open many concurrent connections; Aurora has a hard connection limit).

#### RDS Proxy

Mandatory for Lambda→Aurora. Lambda functions scale horizontally and each instance
opens its own database connection. Without a proxy, 100 concurrent Lambda instances
would open 100 direct Aurora connections, exhausting the pool. RDS Proxy pools and
multiplexes connections, presenting a stable endpoint to Lambda and a controlled
connection count to Aurora.

#### Aurora Serverless v2

PostgreSQL-compatible. Scales ACUs (Aurora Capacity Units) up under load and down
to near-zero when idle. For a pipeline that runs once daily, this means near-zero
compute cost between runs.

The three-layer schema design (raw / build / star) is identical to the local version —
no SQL changes required. Aurora is wire-compatible with PostgreSQL, so all existing
`.sql` files and Python validators work unchanged.

#### Secrets Manager

Database credentials (host, port, user, password, dbname) are stored in Secrets
Manager. Both Lambdas retrieve them at cold start via `boto3`. No credentials in
environment variables, no credentials in code.

Optional: if the pipeline later needs to call paid APIs with rotating API keys,
those keys are added as additional secrets in the same pattern.

#### S3 — idempotency sentinel + run logs

S3 is already in the architecture for raw file storage. It handles two additional
operational concerns without adding a new service.

**Idempotency sentinel** — `s3://pulsefit-data/run_status/YYYYMMDD.json`

Lambda A writes this file with `status: "fetched"` after all raw files are uploaded.
Lambda B checks it before starting — if `status: "completed"`, skip. Lambda B updates
it to `status: "completed"` on successful finish. If EventBridge fires twice on the
same day (retry after transient failure), the second invocation reads "completed" and
exits immediately.

**Run logs** — `s3://pulsefit-data/run_logs/pipeline_YYYYMMDD_HHMMSS.json`

Lambda B writes the full pipeline output JSON to S3 on every run. Append-only,
retained indefinitely, no schema to maintain. This is the audit trail for every step:
DQ counts, rejection reasons, layer reconciliation, abort causes.

**Why S3 over DynamoDB for this:**
S3 is already in the architecture. Adding DynamoDB would be a second service to
provision, secure, and pay for, doing the same job a small JSON file in S3 already
does. The sentinel file is written once per day and read once per day — there is no
use case here that requires DynamoDB's millisecond reads or conditional writes at scale.

**Idempotency layers — what each one protects:**

| Layer | Mechanism | Protects against |
|---|---|---|
| S3 sentinel | `status: completed` check | Re-invoking Lambda B on the same day |
| SQL `ON CONFLICT` upsert | content_hash dedup | Same raw row arriving twice in raw tables |
| SQL `DROP + CREATE` | Full rebuild per run | Build/star always consistent with current raw |

The three layers are independent and protect different failure modes. None overlap.

#### Two-layer error detection

**Check 1 — infrastructure failures (silent Lambda crash, Step Functions timeout)**

An EventBridge rule catches Step Functions FAILED executions and routes them to an
SQS DLQ. A CloudWatch Alarm watches `ApproximateNumberOfMessagesVisible` on the DLQ.
Threshold: > 0. Alarm → SNS topic → email or Slack. This catches: Lambda
out-of-memory, timeout, uncaught exception, Step Functions state machine failure.

**Check 2 — data quality failures (pipeline abort gate)**

When the abort gate fires in Lambda B (steps 2–4 fail), the pipeline logs the
failure and emits a custom CloudWatch metric (`pulsefit/pipeline/abort`, value=1).
A second CloudWatch Alarm watches this metric. Threshold: >= 1 within 1 hour.
Alarm → same SNS topic.

Two separate alarms because they detect different failure modes:
- Alarm 1 = "the Lambda itself broke"
- Alarm 2 = "the Lambda ran but the data was bad"

Without Alarm 2, a pipeline abort would produce a clean Step Functions execution
(Lambda B returned without throwing) and Alarm 1 would never fire. The failure
would be silent.

### Local vs deployed

| Capability | Local | AWS |
|---|---|---|
| Scheduling | Manual | EventBridge Scheduler (daily cron) |
| Orchestration | Sequential Python calls | Step Functions state machine |
| Error alerting | None | Two-layer CloudWatch alarms + SNS |
| Credential management | Local `.env` / psql config | Secrets Manager |
| Idempotency | SQL DROP+CREATE (row level) | S3 sentinel (invocation level) + SQL ON CONFLICT (row level) + SQL DROP+CREATE (rebuild) |
| Database | Local PostgreSQL | Aurora Serverless v2 via RDS Proxy |
| Internet access | Local machine | Lambda A outside VPC |
| Database security | Local only | Lambda B inside private VPC subnet |
| Compute cost when idle | Zero (machine can be off) | Near-zero (Aurora scales to ~0 ACUs) |
| Audit trail | Terminal output + output JSON | Step Functions execution history + S3 output JSON + CloudWatch Logs |

### What was deliberately left out

| Approach | Why not |
|---|---|
| Apache Airflow (MWAA) | $400+/month minimum; overkill for a two-step daily pipeline |
| AWS Glue | Adds a Spark runtime and Glue Catalog for a pipeline that runs in plain Python/SQL |
| ECS Fargate | Persistent container cost vs. Lambda cold start is a bad trade for a once-daily job |
| Redshift | Dataset is thousands of rows; PostgreSQL is sufficient and avoids a migration |
| DynamoDB | S3 is already in the architecture and handles invocation-level idempotency via a sentinel file — no new service needed for once-daily writes and reads |
| NAT Gateway | Avoided by splitting Lambda into VPC (DB access) and non-VPC (API access) |
| EventBridge Rules | EventBridge Scheduler is the correct service for cron-triggered invocations |

### Scaling path

| Signal | Action |
|---|---|
| Aurora CPU > 70% sustained | Increase max ACU ceiling, add read replica for BI queries |
| Table sizes > 100 GB | Evaluate Redshift migration (star schema DDL transfers with minor changes) |
| Lambda B runtime > 15 min | Move ETL to ECS Fargate task (Step Functions supports ECS tasks natively) |
| Multiple pipelines sharing the same pattern | Introduce Step Functions Map state to parallelise source ingestion |

---

## Open Questions for Data Producers

1. **Subscription dates** — 105 of 108 subscriptions have NULL `start_date`; all 108 have NULL `end_date`.
   Are these available in Stripe and simply not exported, or genuinely missing?

2. **Truncated event properties** — 20 event records have JSON properties that end
   without a closing `}`. Is this an export truncation bug or a known issue in the
   analytics tool?

3. **Events before install** — 1,633 events are timestamped before the user's
   CRM `install_date`. The analytics tool appears to track from first app open
   while the CRM records install at signup completion. Which timestamp is the
   canonical install moment for attribution?
