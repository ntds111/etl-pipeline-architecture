-- ============================================================
-- Cleaned + typed build_pulsefit layer built from raw_pulsefit
-- Run with: psql -d pulsefit_db -f sql/build_pulsefit.sql
-- FX rates (static, period approximation): EUR=1.08, GBP=1.27
--
-- DATA QUALITY CHECKS AND NORMALIZATIONS APPLIED
-- ─────────────────────────────────────────────
-- USERS
--   Duplicates        : DISTINCT ON (user_id) ORDER BY LOWER(email); extras → users_rejected (duplicate_user_id)
--   NULL user_id      : → users_rejected (null_user_id)
--   NULL/bad date     : install_date set to NULL; user kept (not rejected)
--                       two known subscribers (u_00444, u_00466) have null install_date — dropping
--                       them would silently remove paying customers from every downstream metric
--   install_date fmt  : DD.MM.YYYY, YYYY-MM-DD, YYYY-MM-DD HH:MM:SS parsed directly;
--                       DD/MM or MM/DD ambiguous → resolved by country_code:
--                       US / CA / USA → MM/DD/YYYY, else DD/MM/YYYY
--   country_code      : USA → US, UK → GB, blank → NULL, else UPPER(TRIM)
--   email             : LOWER() normalized
--   acquisition_channel: 20 raw variants → 7 canonical values
--                        (facebook, google_ads, tiktok, apple_search_ads, organic, referral);
--                        unrecognized → NULL
--   device_os         : case-folded ios/iOS → iOS, android/Android → Android
--   install_date_ambiguous flag: TRUE when slash date with both parts ≤ 12
--                        (country heuristic applied, flag kept for audit)
--
-- EVENTS
--   Exact row dupes   : prevented at raw layer — UNIQUE(event_id) + ON CONFLICT DO NOTHING in ingest
--   NULL timestamp    : → events_rejected (null_event_timestamp)
--   Orphan user_id    : in CRM but rejected from build → events_rejected (cascade_rejection)
--                       not in CRM at all (freemium churner) → events_rejected (no_crm_user)
--   event_id conflict : same id, different field values → events_rejected (event_id_conflict)
--   Malformed JSON    : properties not valid JSONB → events_rejected (malformed_properties_json)
--
-- AD SPEND
--   Negative/zero spend : → ad_spend_rejected (non_positive_spend)
--   NULL/bad date       : → ad_spend_rejected (unparseable_date)
--   date formats        : ISO+time (time stripped), YYYY-MM-DD, DD.MM.YYYY parsed directly;
--                         DD/MM or MM/DD ambiguous → resolved by country_code:
--                         US / CA / USA → MM/DD/YYYY, else DD/MM/YYYY
--   country_code        : USA → US, UK → GB, blank → NULL, else UPPER(TRIM)
--   channel             : 15 raw variants → 7 canonical values (same mapping as users);
--                         unrecognized → NULL
--   Currency FX         : spend_usd = spend × (USD 1.00 | EUR 1.08 | GBP 1.27)
--   Dedup               : raw conflict key = content_hash (full row fingerprint);
--                         build picks latest ingested row per
--                         (date, channel, country_code, campaign_name) via ROW_NUMBER DESC
--
-- SUBSCRIPTIONS
--   NULL subscription_id : → subscriptions_rejected (null_subscription_id)
--   NULL user_id         : → subscriptions_rejected (null_user_id)
--   Unknown user_id      : not in build.users → subscriptions_rejected (no_matching_user)
--   DD.MM.YYYY dates     : parsed by _parse_date() in ingest_raw.py before reaching raw layer
-- ============================================================

CREATE SCHEMA IF NOT EXISTS build_pulsefit;

CREATE OR REPLACE FUNCTION build_pulsefit.try_parse_jsonb(input_text TEXT)
RETURNS JSONB
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF input_text IS NULL OR TRIM(input_text) = '' THEN
        RETURN NULL;
    END IF;

    RETURN input_text::JSONB;
EXCEPTION WHEN others THEN
    RETURN NULL;
END;
$$;

DROP TABLE IF EXISTS build_pulsefit.dq_log;
DROP TABLE IF EXISTS build_pulsefit.users_rejected;
DROP TABLE IF EXISTS build_pulsefit.events_rejected;
DROP TABLE IF EXISTS build_pulsefit.ad_spend_rejected;
DROP TABLE IF EXISTS build_pulsefit.subscriptions_rejected;
DROP TABLE IF EXISTS build_pulsefit.subscriptions;
DROP TABLE IF EXISTS build_pulsefit.events;
DROP TABLE IF EXISTS build_pulsefit.ad_spend;
DROP TABLE IF EXISTS build_pulsefit.users;

-- ── DQ LOG ───────────────────────────────────────────────────
CREATE TABLE build_pulsefit.dq_log (
    table_name       TEXT,
    raw_count        INTEGER,
    built_count      INTEGER,
    rejected_count   INTEGER,
    run_at           TIMESTAMP DEFAULT NOW()
);

-- ── USERS ────────────────────────────────────────────────────
CREATE TABLE build_pulsefit.users (
    user_id                 TEXT,
    email                   TEXT,
    country_code            TEXT,
    install_date            TIMESTAMP,
    install_date_ambiguous  BOOLEAN,
    channel                 TEXT,
    device_os               TEXT,
    app_version             TEXT
);

INSERT INTO build_pulsefit.users
SELECT DISTINCT ON (user_id)
    user_id,
    LOWER(email),
    CASE
        WHEN TRIM(country_code) = ''     THEN NULL
        WHEN UPPER(country_code) = 'USA' THEN 'US'
        WHEN UPPER(country_code) = 'UK'  THEN 'GB'
        ELSE UPPER(TRIM(country_code))
    END,
    CASE
        WHEN install_date ~ '^\d{2}\.\d{2}\.\d{4}$'                  THEN TO_DATE(install_date, 'DD.MM.YYYY')::TIMESTAMP
        WHEN install_date ~ '^\d{2}/\d{2}/\d{4}$' AND SPLIT_PART(install_date,'/',1)::INT > 12
                                                                       THEN TO_DATE(install_date, 'DD/MM/YYYY')::TIMESTAMP
        WHEN install_date ~ '^\d{2}/\d{2}/\d{4}$' AND SPLIT_PART(install_date,'/',2)::INT > 12
                                                                       THEN TO_DATE(install_date, 'MM/DD/YYYY')::TIMESTAMP
        WHEN install_date ~ '^\d{2}/\d{2}/\d{4}$'
            THEN CASE
                -- ambiguous (both parts ≤ 12): derive format from country code
                WHEN UPPER(TRIM(country_code)) IN ('US','CA','USA')
                     THEN TO_DATE(install_date, 'MM/DD/YYYY')::TIMESTAMP
                ELSE TO_DATE(install_date, 'DD/MM/YYYY')::TIMESTAMP
            END
        WHEN install_date ~ '^\d{4}-\d{2}-\d{2}$'                    THEN install_date::TIMESTAMP
        WHEN install_date ~ '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$' THEN install_date::TIMESTAMP
    END,
    -- ambiguous: slash date where both parts <= 12, resolved by country heuristic
    CASE WHEN install_date ~ '^\d{2}/\d{2}/\d{4}$'
          AND SPLIT_PART(install_date,'/',1)::INT <= 12
          AND SPLIT_PART(install_date,'/',2)::INT <= 12
         THEN TRUE ELSE FALSE
    END,
    CASE LOWER(TRIM(acquisition_channel))
        WHEN 'fb'               THEN 'facebook'
        WHEN 'facebook'         THEN 'facebook'
        WHEN 'meta'             THEN 'facebook'
        WHEN 'facebook_ads'     THEN 'facebook'
        WHEN 'google ads'       THEN 'google_ads'
        WHEN 'googleads'        THEN 'google_ads'
        WHEN 'google'           THEN 'google_ads'
        WHEN 'google_ads'       THEN 'google_ads'
        WHEN 'tiktok'           THEN 'tiktok'
        WHEN 'tiktok_ads'       THEN 'tiktok'
        WHEN 'asa'              THEN 'apple_search_ads'
        WHEN 'apple search ads' THEN 'apple_search_ads'
        WHEN 'apple_search'     THEN 'apple_search_ads'
        WHEN 'organic'          THEN 'organic'
        WHEN 'referral'         THEN 'referral'
        WHEN 'referral_program' THEN 'referral'
        ELSE NULL
    END,
    CASE LOWER(device_os)
        WHEN 'ios'     THEN 'iOS'
        WHEN 'android' THEN 'Android'
        ELSE device_os
    END,
    app_version
FROM raw_pulsefit.raw_users
WHERE user_id IS NOT NULL
ORDER BY user_id, LOWER(email);

CREATE TABLE build_pulsefit.users_rejected (
    user_id          TEXT,
    email            TEXT,
    country_code     TEXT,
    install_date     TEXT,
    channel          TEXT,
    device_os        TEXT,
    app_version      TEXT,
    rejection_reason TEXT
);

INSERT INTO build_pulsefit.users_rejected
-- null user_id: no key, cannot reference this row from any other table
SELECT
    user_id,
    email,
    country_code,
    install_date,
    acquisition_channel AS channel,
    device_os,
    app_version,
    'null_user_id'
FROM raw_pulsefit.raw_users
WHERE user_id IS NULL
UNION ALL
-- duplicate user_ids: extra copies beyond the one kept by the DISTINCT ON ordering above
SELECT
    user_id,
    email,
    country_code,
    install_date,
    acquisition_channel AS channel,
    device_os,
    app_version,
    'duplicate_user_id'
FROM (
    SELECT
        r.*,
        ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY LOWER(email), raw_user_pk) AS duplicate_rank
    FROM raw_pulsefit.raw_users r
    WHERE user_id IS NOT NULL
) ranked
WHERE duplicate_rank > 1;

INSERT INTO build_pulsefit.dq_log (table_name, raw_count, built_count, rejected_count)
SELECT 'users',
    (SELECT COUNT(*) FROM raw_pulsefit.raw_users),
    (SELECT COUNT(*) FROM build_pulsefit.users),
    (SELECT COUNT(*) FROM build_pulsefit.users_rejected);

-- ── EVENTS ───────────────────────────────────────────────────
CREATE TABLE build_pulsefit.events (
    event_id        TEXT,
    user_id         TEXT,
    event_name      TEXT,
    event_timestamp TIMESTAMP,
    properties      JSONB
);

-- Duplicates: only keep if ALL columns are identical (true copy)
-- Conflicts (same event_id, different data) go to rejected with reason 'event_id_conflict'
INSERT INTO build_pulsefit.events
SELECT DISTINCT
    event_id,
    user_id,
    event_name,
    NULLIF(TRIM(event_timestamp), '')::TIMESTAMP,
    build_pulsefit.try_parse_jsonb(properties)
FROM raw_pulsefit.raw_events
WHERE event_id NOT IN (
    SELECT event_id FROM raw_pulsefit.raw_events
    GROUP BY event_id
    HAVING COUNT(DISTINCT user_id) > 1
        OR COUNT(DISTINCT event_name) > 1
        OR COUNT(DISTINCT event_timestamp) > 1
        OR COUNT(DISTINCT properties) > 1
)
  AND user_id IN (SELECT user_id FROM build_pulsefit.users)
  AND NULLIF(TRIM(event_timestamp), '') IS NOT NULL
  AND (NULLIF(TRIM(properties), '') IS NULL OR build_pulsefit.try_parse_jsonb(properties) IS NOT NULL);

CREATE TABLE build_pulsefit.events_rejected (
    event_id         TEXT,
    user_id          TEXT,
    event_name       TEXT,
    event_timestamp  TEXT,
    properties       TEXT,
    rejection_reason TEXT
);

INSERT INTO build_pulsefit.events_rejected
-- null timestamp
SELECT r.event_id, r.user_id, r.event_name, r.event_timestamp, r.properties, 'null_event_timestamp'
FROM raw_pulsefit.raw_events r
WHERE NULLIF(TRIM(r.event_timestamp), '') IS NULL
  AND r.user_id IN (SELECT user_id FROM build_pulsefit.users)
UNION ALL
-- cascade_rejection: user_id in CRM raw_users but rejected from build.users
SELECT r.event_id, r.user_id, r.event_name, r.event_timestamp, r.properties, 'cascade_rejection'
FROM raw_pulsefit.raw_events r
WHERE r.user_id NOT IN (SELECT user_id FROM build_pulsefit.users)
  AND r.user_id IN     (SELECT user_id FROM raw_pulsefit.raw_users)
UNION ALL
-- no_crm_user: user_id not in CRM at all — freemium churner who never created an account
SELECT r.event_id, r.user_id, r.event_name, r.event_timestamp, r.properties, 'no_crm_user'
FROM raw_pulsefit.raw_events r
WHERE r.user_id NOT IN (SELECT user_id FROM build_pulsefit.users)
  AND r.user_id NOT IN (SELECT user_id FROM raw_pulsefit.raw_users)
UNION ALL
-- malformed JSON properties
SELECT r.event_id, r.user_id, r.event_name, r.event_timestamp, r.properties, 'malformed_properties_json'
FROM raw_pulsefit.raw_events r
WHERE NULLIF(TRIM(r.properties), '') IS NOT NULL
  AND build_pulsefit.try_parse_jsonb(r.properties) IS NULL
  AND r.user_id IN (SELECT user_id FROM build_pulsefit.users)
  AND NULLIF(TRIM(r.event_timestamp), '') IS NOT NULL
UNION ALL
-- event_id conflicts (same id, different column values)
-- restricted to known users: orphan-user rows are already owned by no_matching_user
SELECT r.event_id, r.user_id, r.event_name, r.event_timestamp, r.properties, 'event_id_conflict'
FROM raw_pulsefit.raw_events r
WHERE r.event_id IN (
    SELECT event_id FROM raw_pulsefit.raw_events
    GROUP BY event_id
    HAVING COUNT(DISTINCT user_id) > 1
        OR COUNT(DISTINCT event_name) > 1
        OR COUNT(DISTINCT event_timestamp) > 1
        OR COUNT(DISTINCT properties) > 1
)
  AND r.user_id IN (SELECT user_id FROM build_pulsefit.users)
;

INSERT INTO build_pulsefit.dq_log (table_name, raw_count, built_count, rejected_count)
SELECT 'events',
    (SELECT COUNT(*) FROM raw_pulsefit.raw_events),
    (SELECT COUNT(*) FROM build_pulsefit.events),
    (SELECT COUNT(*) FROM build_pulsefit.events_rejected);

-- ── AD SPEND ─────────────────────────────────────────────────
CREATE TABLE build_pulsefit.ad_spend (
    raw_ad_spend_id    TEXT,
    date              DATE,
    channel           TEXT,
    country_code      TEXT,
    campaign_name     TEXT,
    original_currency TEXT,
    original_spend    NUMERIC(12,2),
    spend_usd         NUMERIC(12,2),
    impressions       INTEGER,
    clicks            INTEGER,
    installs          INTEGER
);

-- Raw may contain multiple rows per (date, channel, country_code, campaign_name)
-- when a source sends corrections with different metric values.
-- ROW_NUMBER picks the latest ingested version; rejected rows are excluded by the WHERE.
INSERT INTO build_pulsefit.ad_spend
SELECT
    raw_ad_spend_id,
    parsed_date,
    parsed_channel,
    parsed_country_code,
    campaign_name,
    currency,
    spend,
    ROUND(spend * CASE currency
        WHEN 'USD' THEN 1.00
        WHEN 'EUR' THEN 1.08
        WHEN 'GBP' THEN 1.27
        ELSE 1.00
    END, 2),
    impressions,
    clicks,
    installs
FROM (
    SELECT
        raw_ad_spend_id,
        CASE
            WHEN date ~ '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$' THEN date::TIMESTAMP::DATE
            WHEN date ~ '^\d{4}-\d{2}-\d{2}$'                     THEN date::DATE
            WHEN date ~ '^\d{2}\.\d{2}\.\d{4}$'                   THEN TO_DATE(date, 'DD.MM.YYYY')
            WHEN date ~ '^\d{2}/\d{2}/\d{4}$' AND SPLIT_PART(date,'/',1)::INT > 12
                                                                   THEN TO_DATE(date, 'DD/MM/YYYY')
            WHEN date ~ '^\d{2}/\d{2}/\d{4}$' AND SPLIT_PART(date,'/',2)::INT > 12
                                                                   THEN TO_DATE(date, 'MM/DD/YYYY')
            WHEN date ~ '^\d{2}/\d{2}/\d{4}$'
                THEN CASE
                    WHEN UPPER(country_code) IN ('US','CA','USA')
                         THEN TO_DATE(date, 'MM/DD/YYYY')
                    ELSE TO_DATE(date, 'DD/MM/YYYY')
                END
        END AS parsed_date,
        CASE LOWER(TRIM(channel))
            WHEN 'fb'               THEN 'facebook'
            WHEN 'facebook'         THEN 'facebook'
            WHEN 'meta'             THEN 'facebook'
            WHEN 'facebook_ads'     THEN 'facebook'
            WHEN 'google ads'       THEN 'google_ads'
            WHEN 'googleads'        THEN 'google_ads'
            WHEN 'google'           THEN 'google_ads'
            WHEN 'google_ads'       THEN 'google_ads'
            WHEN 'tiktok'           THEN 'tiktok'
            WHEN 'tiktok_ads'       THEN 'tiktok'
            WHEN 'asa'              THEN 'apple_search_ads'
            WHEN 'apple search ads' THEN 'apple_search_ads'
            WHEN 'apple_search'     THEN 'apple_search_ads'
            WHEN 'organic'          THEN 'organic'
            WHEN 'referral'         THEN 'referral'
            WHEN 'referral_program' THEN 'referral'
            ELSE NULL
        END AS parsed_channel,
        CASE
            WHEN TRIM(country_code) = ''     THEN NULL
            WHEN UPPER(country_code) = 'USA' THEN 'US'
            WHEN UPPER(country_code) = 'UK'  THEN 'GB'
            ELSE UPPER(TRIM(country_code))
        END AS parsed_country_code,
        campaign_name,
        currency,
        spend,
        impressions,
        clicks,
        installs,
        ingested_at,
        ROW_NUMBER() OVER (
            PARTITION BY
                CASE
                    WHEN date ~ '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$' THEN date::TIMESTAMP::DATE
                    WHEN date ~ '^\d{4}-\d{2}-\d{2}$'                     THEN date::DATE
                    WHEN date ~ '^\d{2}\.\d{2}\.\d{4}$'                   THEN TO_DATE(date, 'DD.MM.YYYY')
                    WHEN date ~ '^\d{2}/\d{2}/\d{4}$' AND SPLIT_PART(date,'/',1)::INT > 12
                                                                           THEN TO_DATE(date, 'DD/MM/YYYY')
                    WHEN date ~ '^\d{2}/\d{2}/\d{4}$' AND SPLIT_PART(date,'/',2)::INT > 12
                                                                           THEN TO_DATE(date, 'MM/DD/YYYY')
                    WHEN date ~ '^\d{2}/\d{2}/\d{4}$'
                        THEN CASE WHEN UPPER(country_code) IN ('US','CA','USA')
                                  THEN TO_DATE(date, 'MM/DD/YYYY')
                                  ELSE TO_DATE(date, 'DD/MM/YYYY') END
                END,
                LOWER(TRIM(channel)),
                UPPER(TRIM(country_code)),
                campaign_name
            ORDER BY ingested_at DESC
        ) AS row_num
    FROM raw_pulsefit.raw_ad_spend
    WHERE date IS NOT NULL AND TRIM(date) != ''
      AND (
          date ~ '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$'
          OR date ~ '^\d{4}-\d{2}-\d{2}$'
          OR date ~ '^\d{2}\.\d{2}\.\d{4}$'
          OR date ~ '^\d{2}/\d{2}/\d{4}$'
      )
      AND spend > 0
) ranked
WHERE row_num = 1;

CREATE TABLE build_pulsefit.ad_spend_rejected (
    raw_ad_spend_id    TEXT,
    date              TEXT,
    channel           TEXT,
    country_code      TEXT,
    campaign_name     TEXT,
    spend             NUMERIC(12,2),
    currency          TEXT,
    impressions       INTEGER,
    clicks            INTEGER,
    installs          INTEGER,
    rejection_reason  TEXT
);

INSERT INTO build_pulsefit.ad_spend_rejected
SELECT
    raw_ad_spend_id,
    date,
    channel,
    country_code,
    campaign_name,
    spend,
    currency,
    impressions,
    clicks,
    installs,
    'unparseable_date: ' || date
FROM raw_pulsefit.raw_ad_spend
WHERE date IS NULL
   OR TRIM(date) = ''
   OR NOT (
      date ~ '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$'
      OR date ~ '^\d{4}-\d{2}-\d{2}$'
      OR date ~ '^\d{2}\.\d{2}\.\d{4}$'
      OR date ~ '^\d{2}/\d{2}/\d{4}$'
   )
UNION ALL
SELECT
    raw_ad_spend_id,
    date,
    channel,
    country_code,
    campaign_name,
    spend,
    currency,
    impressions,
    clicks,
    installs,
    'non_positive_spend'
FROM raw_pulsefit.raw_ad_spend
WHERE spend <= 0
  AND date IS NOT NULL AND TRIM(date) != ''
  AND (
      date ~ '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$'
      OR date ~ '^\d{4}-\d{2}-\d{2}$'
      OR date ~ '^\d{2}\.\d{2}\.\d{4}$'
      OR date ~ '^\d{2}/\d{2}/\d{4}$'
  );

INSERT INTO build_pulsefit.dq_log (table_name, raw_count, built_count, rejected_count)
SELECT 'ad_spend',
    (SELECT COUNT(*) FROM raw_pulsefit.raw_ad_spend),
    (SELECT COUNT(*) FROM build_pulsefit.ad_spend),
    (SELECT COUNT(*) FROM build_pulsefit.ad_spend_rejected);

-- ── SUBSCRIPTIONS ────────────────────────────────────────────
CREATE TABLE build_pulsefit.subscriptions (
    subscription_id TEXT,
    user_id         TEXT,
    plan            TEXT,
    amount_usd      NUMERIC(10,2),
    start_date      DATE,
    end_date        DATE,
    status          TEXT,
    renewal_history JSONB
);

INSERT INTO build_pulsefit.subscriptions
SELECT
    subscription_id, user_id, plan, amount_usd,
    start_date, end_date, status, renewal_history
FROM raw_pulsefit.raw_subscriptions
WHERE subscription_id IS NOT NULL
  AND user_id IS NOT NULL
  AND user_id IN (SELECT user_id FROM build_pulsefit.users);

CREATE TABLE build_pulsefit.subscriptions_rejected (
    subscription_id TEXT,
    user_id         TEXT,
    plan            TEXT,
    amount_usd      NUMERIC(10,2),
    start_date      DATE,
    end_date        DATE,
    status          TEXT,
    renewal_history JSONB,
    rejection_reason TEXT
);

INSERT INTO build_pulsefit.subscriptions_rejected
SELECT subscription_id, user_id, plan, amount_usd, start_date, end_date, status, renewal_history, 'null_subscription_id'
FROM raw_pulsefit.raw_subscriptions
WHERE subscription_id IS NULL
UNION ALL
SELECT subscription_id, user_id, plan, amount_usd, start_date, end_date, status, renewal_history, 'null_user_id'
FROM raw_pulsefit.raw_subscriptions
WHERE subscription_id IS NOT NULL
  AND user_id IS NULL
UNION ALL
SELECT subscription_id, user_id, plan, amount_usd, start_date, end_date, status, renewal_history, 'no_matching_user'
FROM raw_pulsefit.raw_subscriptions
WHERE subscription_id IS NOT NULL
  AND user_id IS NOT NULL
  AND user_id NOT IN (SELECT user_id FROM build_pulsefit.users);

INSERT INTO build_pulsefit.dq_log (table_name, raw_count, built_count, rejected_count)
SELECT 'subscriptions',
    (SELECT COUNT(*) FROM raw_pulsefit.raw_subscriptions),
    (SELECT COUNT(*) FROM build_pulsefit.subscriptions),
    (SELECT COUNT(*) FROM build_pulsefit.subscriptions_rejected);

-- ── DQ SUMMARY ───────────────────────────────────────────────
SELECT table_name, raw_count, built_count, rejected_count FROM build_pulsefit.dq_log ORDER BY table_name;
