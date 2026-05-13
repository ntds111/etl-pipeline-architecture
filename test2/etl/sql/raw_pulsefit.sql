-- ============================================================
-- Part 2: ETL raw schema (raw_pulsefit)
-- Run with: psql calimoto_data -f etl/raw_pulsefit.sql
-- ============================================================

CREATE SCHEMA IF NOT EXISTS raw_pulsefit;

-- RAW USERS
CREATE TABLE IF NOT EXISTS raw_pulsefit.raw_users (
    raw_user_pk         BIGSERIAL PRIMARY KEY,
    user_id             TEXT UNIQUE,
    email               TEXT,
    country_code        TEXT,
    install_date        TEXT,
    acquisition_channel TEXT,
    device_os           TEXT,
    app_version         TEXT,
    content_hash        TEXT,
    ingested_at         TIMESTAMP DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS raw_pulsefit.raw_users_tmp
(LIKE raw_pulsefit.raw_users INCLUDING DEFAULTS);

-- RAW EVENTS
CREATE TABLE IF NOT EXISTS raw_pulsefit.raw_events (
    raw_event_pk    BIGSERIAL PRIMARY KEY,
    event_id        TEXT UNIQUE,
    user_id         TEXT,
    event_name      TEXT,
    event_timestamp TEXT,
    properties      TEXT,
    content_hash    TEXT,
    ingested_at     TIMESTAMP DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS raw_pulsefit.raw_events_tmp
(LIKE raw_pulsefit.raw_events INCLUDING DEFAULTS);

-- RAW AD SPEND
CREATE TABLE IF NOT EXISTS raw_pulsefit.raw_ad_spend (
    raw_ad_spend_id TEXT,
    date            TEXT,
    channel         TEXT,
    country_code    TEXT,
    campaign_name   TEXT,
    spend           NUMERIC(12,2),
    currency        TEXT,
    impressions     INTEGER,
    clicks          INTEGER,
    installs        INTEGER,
    content_hash    TEXT UNIQUE,
    ingested_at     TIMESTAMP DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS raw_pulsefit.raw_ad_spend_tmp
(LIKE raw_pulsefit.raw_ad_spend INCLUDING DEFAULTS);

DELETE FROM raw_pulsefit.raw_ad_spend
WHERE raw_ad_spend_id IS NULL;

-- RAW SUBSCRIPTIONS
CREATE TABLE IF NOT EXISTS raw_pulsefit.raw_subscriptions (
    subscription_id TEXT PRIMARY KEY,
    user_id         TEXT,
    plan            TEXT,
    amount_usd      NUMERIC(10,2),
    start_date      DATE,
    end_date        DATE,
    status          TEXT,
    renewal_history JSONB,
    content_hash    TEXT,
    ingested_at     TIMESTAMP DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS raw_pulsefit.raw_subscriptions_tmp
(LIKE raw_pulsefit.raw_subscriptions INCLUDING DEFAULTS);

-- UNIQUE constraints drive ON CONFLICT upsert in ingest_raw.py:
--   raw_users        → UNIQUE(user_id)
--   raw_events       → UNIQUE(event_id)
--   raw_ad_spend     → UNIQUE(content_hash)
--   raw_subscriptions→ PRIMARY KEY(subscription_id)

-- Migrations: add new columns and constraints to pre-existing tables if needed.
ALTER TABLE raw_pulsefit.raw_users             ADD COLUMN IF NOT EXISTS raw_user_pk  BIGSERIAL;
ALTER TABLE raw_pulsefit.raw_events            ADD COLUMN IF NOT EXISTS raw_event_pk BIGSERIAL;
ALTER TABLE raw_pulsefit.raw_users             ADD COLUMN IF NOT EXISTS content_hash TEXT;
ALTER TABLE raw_pulsefit.raw_users             ADD COLUMN IF NOT EXISTS ingested_at  TIMESTAMP DEFAULT NOW();
ALTER TABLE raw_pulsefit.raw_users_tmp         ADD COLUMN IF NOT EXISTS content_hash TEXT;
ALTER TABLE raw_pulsefit.raw_users_tmp         ADD COLUMN IF NOT EXISTS ingested_at  TIMESTAMP DEFAULT NOW();
ALTER TABLE raw_pulsefit.raw_events            ADD COLUMN IF NOT EXISTS content_hash TEXT;
ALTER TABLE raw_pulsefit.raw_events            ADD COLUMN IF NOT EXISTS ingested_at  TIMESTAMP DEFAULT NOW();
ALTER TABLE raw_pulsefit.raw_events_tmp        ADD COLUMN IF NOT EXISTS content_hash TEXT;
ALTER TABLE raw_pulsefit.raw_events_tmp        ADD COLUMN IF NOT EXISTS ingested_at  TIMESTAMP DEFAULT NOW();
ALTER TABLE raw_pulsefit.raw_ad_spend          ADD COLUMN IF NOT EXISTS content_hash TEXT;
ALTER TABLE raw_pulsefit.raw_ad_spend          ADD COLUMN IF NOT EXISTS ingested_at  TIMESTAMP DEFAULT NOW();
ALTER TABLE raw_pulsefit.raw_ad_spend_tmp      ADD COLUMN IF NOT EXISTS content_hash TEXT;
ALTER TABLE raw_pulsefit.raw_ad_spend_tmp      ADD COLUMN IF NOT EXISTS ingested_at  TIMESTAMP DEFAULT NOW();
ALTER TABLE raw_pulsefit.raw_subscriptions     ADD COLUMN IF NOT EXISTS content_hash TEXT;
ALTER TABLE raw_pulsefit.raw_subscriptions     ADD COLUMN IF NOT EXISTS ingested_at  TIMESTAMP DEFAULT NOW();
ALTER TABLE raw_pulsefit.raw_subscriptions_tmp ADD COLUMN IF NOT EXISTS content_hash TEXT;
ALTER TABLE raw_pulsefit.raw_subscriptions_tmp ADD COLUMN IF NOT EXISTS ingested_at  TIMESTAMP DEFAULT NOW();

-- Deduplicate existing rows before UNIQUE indexes are created.
DELETE FROM raw_pulsefit.raw_users
WHERE raw_user_pk IS NOT NULL
  AND raw_user_pk NOT IN (
      SELECT MIN(raw_user_pk) FROM raw_pulsefit.raw_users GROUP BY user_id
  );

DELETE FROM raw_pulsefit.raw_events
WHERE raw_event_pk IS NOT NULL
  AND raw_event_pk NOT IN (
      SELECT MIN(raw_event_pk) FROM raw_pulsefit.raw_events GROUP BY event_id
  );

-- Drop old indexes (non-unique or partial) so they can be replaced with full UNIQUE versions.
DROP INDEX IF EXISTS raw_pulsefit.idx_raw_users_user_id;
DROP INDEX IF EXISTS raw_pulsefit.idx_raw_events_event_id;
DROP INDEX IF EXISTS raw_pulsefit.idx_raw_ad_spend_id;
DROP INDEX IF EXISTS raw_pulsefit.idx_raw_ad_spend_content_hash;

CREATE UNIQUE INDEX IF NOT EXISTS idx_raw_users_user_id
    ON raw_pulsefit.raw_users(user_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_raw_events_event_id
    ON raw_pulsefit.raw_events(event_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_raw_ad_spend_content_hash
    ON raw_pulsefit.raw_ad_spend(content_hash);
