-- ============================================================
-- Part 2: star_pulsefit — analysis-ready star schema
-- Run with: psql calimoto_data -f etl/star_pulsefit.sql
-- ============================================================

CREATE SCHEMA IF NOT EXISTS star_pulsefit;

DROP TABLE IF EXISTS star_pulsefit.fact_ad_spend    CASCADE;
DROP TABLE IF EXISTS star_pulsefit.fact_events      CASCADE;
DROP TABLE IF EXISTS star_pulsefit.dim_user         CASCADE;
DROP TABLE IF EXISTS star_pulsefit.dim_date         CASCADE;
DROP TABLE IF EXISTS star_pulsefit.dim_channel      CASCADE;

-- ── DIM CHANNEL ──────────────────────────────────────────────
-- Single source of truth for channel attributes
CREATE TABLE star_pulsefit.dim_channel (
    channel_id    TEXT PRIMARY KEY,
    channel_name  TEXT NOT NULL,
    is_paid       BOOLEAN NOT NULL,
    platform_type TEXT NOT NULL   -- social, search, video, app_store, organic, referral
);

INSERT INTO star_pulsefit.dim_channel VALUES
    ('facebook',         'Facebook / Meta',      TRUE,  'social'),
    ('google_ads',       'Google Ads',            TRUE,  'search'),
    ('tiktok',           'TikTok',                TRUE,  'video'),
    ('apple_search_ads', 'Apple Search Ads',      TRUE,  'app_store'),
    ('organic',          'Organic',               FALSE, 'organic'),
    ('referral',         'Referral Program',      FALSE, 'referral');

-- ── DIM DATE ─────────────────────────────────────────────────
-- Date spine covering full dataset range
CREATE TABLE star_pulsefit.dim_date (
    date_key    DATE PRIMARY KEY,
    year        INTEGER,
    quarter     INTEGER,
    month       INTEGER,
    month_name  TEXT,
    week        INTEGER,
    day_of_week INTEGER,
    is_weekend  BOOLEAN
);

-- Spine covers the full range of every date field across all build tables
-- so no fact row is ever silently dropped by a missing date_key FK
INSERT INTO star_pulsefit.dim_date
SELECT
    d::DATE,
    EXTRACT(YEAR    FROM d)::INTEGER,
    EXTRACT(QUARTER FROM d)::INTEGER,
    EXTRACT(MONTH   FROM d)::INTEGER,
    TRIM(TO_CHAR(d, 'Month')),
    EXTRACT(WEEK    FROM d)::INTEGER,
    EXTRACT(DOW     FROM d)::INTEGER,
    EXTRACT(DOW     FROM d) IN (0, 6)
FROM GENERATE_SERIES(
    LEAST(
        (SELECT MIN(install_date::DATE)      FROM build_pulsefit.users          WHERE install_date      IS NOT NULL),
        (SELECT MIN(event_timestamp::DATE)   FROM build_pulsefit.events         WHERE event_timestamp   IS NOT NULL),
        (SELECT MIN(date)                    FROM build_pulsefit.ad_spend        WHERE date              IS NOT NULL),
        (SELECT MIN(start_date)              FROM build_pulsefit.subscriptions   WHERE start_date        IS NOT NULL)
    ),
    GREATEST(
        (SELECT MAX(install_date::DATE)      FROM build_pulsefit.users          WHERE install_date      IS NOT NULL),
        (SELECT MAX(event_timestamp::DATE)   FROM build_pulsefit.events         WHERE event_timestamp   IS NOT NULL),
        (SELECT MAX(date)                    FROM build_pulsefit.ad_spend        WHERE date              IS NOT NULL),
        (SELECT MAX(end_date)                FROM build_pulsefit.subscriptions   WHERE end_date          IS NOT NULL)
    ),
    '1 day'
) d;

-- ── DIM USER ─────────────────────────────────────────────────
-- One row per user with FK to dim_channel
CREATE TABLE star_pulsefit.dim_user (
    user_id                TEXT PRIMARY KEY,
    email                  TEXT,
    country_code           TEXT,
    device_os              TEXT,
    app_version            TEXT,
    channel_id             TEXT REFERENCES star_pulsefit.dim_channel(channel_id),
    install_date           TIMESTAMP,
    install_date_ambiguous BOOLEAN
);

INSERT INTO star_pulsefit.dim_user
SELECT
    u.user_id,
    u.email,
    u.country_code,
    u.device_os,
    u.app_version,
    CASE WHEN u.channel IN (SELECT channel_id FROM star_pulsefit.dim_channel)
         THEN u.channel ELSE NULL END,
    u.install_date,
    u.install_date_ambiguous
FROM build_pulsefit.users u;

-- ── FACT EVENTS ──────────────────────────────────────────────
-- Lowest granularity: one row per event
-- channel_id denormalized from dim_user for query performance
CREATE TABLE star_pulsefit.fact_events (
    event_id        TEXT PRIMARY KEY,
    user_id         TEXT REFERENCES star_pulsefit.dim_user(user_id),
    channel_id      TEXT REFERENCES star_pulsefit.dim_channel(channel_id),
    date_key        DATE REFERENCES star_pulsefit.dim_date(date_key),
    event_name      TEXT,
    event_timestamp TIMESTAMP,
    properties      JSONB
);

INSERT INTO star_pulsefit.fact_events
SELECT
    e.event_id,
    e.user_id,
    u.channel_id,
    e.event_timestamp::DATE,
    e.event_name,
    e.event_timestamp,
    e.properties
FROM build_pulsefit.events e
JOIN star_pulsefit.dim_user u USING (user_id);

-- ── FACT AD SPEND ────────────────────────────────────────────
-- One row per spend record: channel / date / country / campaign
CREATE TABLE star_pulsefit.fact_ad_spend (
    raw_ad_spend_id    TEXT PRIMARY KEY,
    date_key          DATE REFERENCES star_pulsefit.dim_date(date_key),
    channel_id        TEXT REFERENCES star_pulsefit.dim_channel(channel_id),
    country_code      TEXT,
    campaign_name     TEXT,
    original_currency TEXT,
    original_spend    NUMERIC(12,2),
    spend_usd         NUMERIC(12,2),
    impressions       INTEGER,
    clicks            INTEGER,
    installs          INTEGER
);

INSERT INTO star_pulsefit.fact_ad_spend
SELECT
    a.raw_ad_spend_id,
    a.date,
    CASE WHEN a.channel IN (SELECT channel_id FROM star_pulsefit.dim_channel)
         THEN a.channel ELSE NULL END,
    a.country_code,
    a.campaign_name,
    a.original_currency,
    a.original_spend,
    a.spend_usd,
    a.impressions,
    a.clicks,
    a.installs
FROM build_pulsefit.ad_spend a;

-- ── INDEXES ──────────────────────────────────────────────────
-- FK columns on fact tables: used for every join to a dimension
CREATE INDEX ON star_pulsefit.fact_events(user_id);
CREATE INDEX ON star_pulsefit.fact_events(channel_id);
CREATE INDEX ON star_pulsefit.fact_events(date_key);
CREATE INDEX ON star_pulsefit.fact_events(event_name);      -- funnel filter

CREATE INDEX ON star_pulsefit.fact_ad_spend(date_key, channel_id);  -- composite: most queries slice on both
CREATE INDEX ON star_pulsefit.fact_ad_spend(channel_id);

CREATE INDEX ON star_pulsefit.dim_user(channel_id);         -- FK, used in joins back to dim_channel

-- ── SUMMARY ──────────────────────────────────────────────────
SELECT 'dim_channel'       AS table_name, COUNT(*) AS rows FROM star_pulsefit.dim_channel  UNION ALL
SELECT 'dim_date',                        COUNT(*)         FROM star_pulsefit.dim_date      UNION ALL
SELECT 'dim_user',                        COUNT(*)         FROM star_pulsefit.dim_user      UNION ALL
SELECT 'fact_events',                     COUNT(*)         FROM star_pulsefit.fact_events   UNION ALL
SELECT 'fact_ad_spend',                   COUNT(*)         FROM star_pulsefit.fact_ad_spend
ORDER BY table_name;
