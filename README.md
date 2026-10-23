# Sample ETL Pipeline Architecture

A small Python + PostgreSQL reference pipeline using fitness-app sample data.
It demonstrates incremental raw ingestion, SQL-based cleaning, rejected-row
tracking, validation gates, and an analytics-ready star schema.

## Architecture

```text
CSV / JSON → raw_pulsefit → build_pulsefit → star_pulsefit → analytical SQL
                 Python       SQL + checks      SQL + checks
```

Python handles ingestion and orchestration; PostgreSQL handles transformations.
Each run writes JSON summaries to `outputs/`. The [architecture](docs/architecture.md)
describes the components and an optional AWS deployment concept.

## Quickstart

Requires Python 3.10+, a running PostgreSQL 14+ server, PostgreSQL CLI tools, and Make.
Run from the repository root using a database role that can create schemas and tables.

```bash
make setup
cp .env.example .env
set -a; . ./.env; set +a
createdb "$PGDATABASE"   # First time only; use a dedicated sample database
make run
make test
make lint
psql -v ON_ERROR_STOP=1 -f sql/queries/cost_per_install.sql
```

`make run` ingests the bundled data, then rebuilds the build and star layers.
**Do not point it at a production database:** those two schemas are dropped/rebuilt.
See the [runbook](docs/runbook.md) for connection settings and troubleshooting.

## Repository layout

```text
src/              Python ingestion, orchestration, and validators
sql/              Raw, build, and star SQL; queries/ for analytics
data/             Bundled CSV and JSON inputs
tests/            Lightweight regression tests
docs/             Architecture, runbook, design decisions, and analytics notes
```

## Extension points

- Add sources in `src/ingest_raw.py` alongside matching raw SQL definitions.
- Adjust normalization and rejection rules in `sql/build_pulsefit.sql`.
- Extend dimensions/facts in `sql/star_pulsefit.sql` and their Python validators.
- Add reporting queries under `sql/queries/`.

See [design decisions](docs/decisions.md) and the preserved
[sample analytics notes](docs/analytics.md) for context.
