# Local runbook

## Setup and run

From the repository root, with Python 3.10+, Make, and PostgreSQL 14+ installed
and the database server running:

```bash
make setup
cp .env.example .env
# Edit .env to select your dedicated local database.
set -a; . ./.env; set +a
createdb "$PGDATABASE"  # Skip if this database already exists.
make run
```

`make setup` creates `.venv` and installs `requirements.txt`. `.env` is **not**
loaded automatically: export it in each new shell. No dotenv dependency is needed.

## Environment

The quickstart uses `PGDATABASE` from `.env.example`. Both Python entry points
default to `pulsefit_db` if it is unset. No other variables are required for a
local server using the current OS user's role and Unix-socket authentication.

For another connection, standard libpq settings (`PGHOST`, `PGPORT`, `PGUSER`,
`PGSSLMODE`) are honored by both psycopg2 and PostgreSQL CLI tools. Use
`~/.pgpass` (permissions `0600`) for passwords; never commit credentials.
The role needs database connection and schema/table creation privileges.

## Commands and outputs

- `make run`: ingest raw files, then build, validate, and populate the star schema.
- `.venv/bin/python src/ingest_raw.py`: run only ingestion.
- `.venv/bin/python src/pipeline.py`: rebuild/validate using existing raw data.
- `make test`: standard-library unit tests; no database required.
- `make lint`: dependency-free Python syntax check (not a style linter).
- `psql -v ON_ERROR_STOP=1 -f sql/queries/funnel_conversion.sql`: example report.

Inputs are bundled in `data/`; JSON summaries are written to `outputs/`.
Paths are resolved relative to the source location, not the shell's working directory.
Inspect summary `steps`, statuses, rejection counts, and reconciliation deltas:
a completed process alone does not guarantee every post-star check passed.

## Troubleshooting

- **Connection refused / socket missing:** start PostgreSQL and check `PGHOST`/`PGPORT`.
- **Role or database missing / authentication failed:** create a local role/database
  or export the connection settings for an existing role. Check `psql` connects
  with the same environment before retrying.
- **Missing Python dependency:** run `make setup`; the Make targets use `.venv`.
- **Missing input or SQL file:** restore the checked-in `data/` and `sql/` directories.
- **Build abort or failed validation:** inspect the latest JSON summary,
  `build_pulsefit.dq_log`, and the raw/build `_rejected` tables. Correct the source
  data or transformation rule before running again.
- **Reruns:** unchanged raw records are skipped; build/star are rebuilt. Runs are
  not globally atomic. Avoid simultaneous runs and never use a shared production
  database. To reset completely, recreate only your dedicated sample database.
