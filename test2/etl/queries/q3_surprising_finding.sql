-- ============================================================
-- Part 2 · Q3: Surprising findings
--
-- Finding A — what looked like a data gap turned out to be the freemium model:
--
--   Initial observation: 53% of all events (1,633 / 3,080) are timestamped
--   BEFORE the user's CRM install_date, with a consistent ~45-day gap.
--   This affects 423 users across every event type — including 'install',
--   'signup_complete', and 'subscription_started'. First instinct: data error.
--
--   On investigation: the gap is too consistent and too wide to be noise.
--   The same ~45-day pattern appears across all event types and all channels.
--   A data entry error would be random; this is systematic.
--
--   Root cause: the app is freemium. Users install and use the app for free
--   for ~45 days on average before creating a CRM account. The CRM records
--   that signup moment as install_date — not the actual first app open.
--   Free-tier activity leaves no CRM footprint until the user signs up.
--
--   This also explains Q2: 166 users completed workouts with no signup_complete
--   event, and 21 subscribed with no signup event. They were not missing data —
--   they were freemium users who paid before or without ever signing up.
--
--   Implication: install_date is the CRM entry date, not the app install date.
--   Any time-to-convert or attribution analysis must use the first event
--   timestamp from fact_events, not install_date from dim_user.
--
--   Confirm with data producer: is install_date populated at signup completion?
--
-- Finding B — subscription dates are nearly empty, and the two data sources
--   barely overlap:
--   97.3% of subscription records have NULL start_date and end_date (3/110 have start_date).
--   Three-way split (post-pipeline counts, confirmed):
--     92 users  in subscriptions table only — no subscription_started event
--      8 users  in both (clean overlap)
--     40 users  fired subscription_started event but have no subscriptions row
--   Total unique subscribed users: 92 + 8 + 40 = 140 across both sources;
--   only 8 are verified by both.
--
-- Run with: psql takehome_db -f etl/queries/q3_surprising_finding.sql
-- ============================================================

-- ── FINDING A: events before CRM install_date ─────────────────────────────

-- A1. Scale: how many events predate the user's CRM install_date?
SELECT
    COUNT(*)                                                                            AS total_events,
    COUNT(CASE WHEN e.event_timestamp < u.install_date THEN 1 END)                     AS events_before_install,
    ROUND(100.0 * COUNT(CASE WHEN e.event_timestamp < u.install_date THEN 1 END)
          / COUNT(*), 1)                                                                AS pct_before_install,
    COUNT(DISTINCT CASE WHEN e.event_timestamp < u.install_date THEN e.user_id END)    AS affected_users
FROM build_pulsefit.events e
JOIN build_pulsefit.users  u USING (user_id)
WHERE u.install_date IS NOT NULL;

-- A2. Breakdown by event type: gap is ~45 days across every event type,
--     including 'install' and 'signup_complete' — confirming this is a
--     systematic timestamp definition mismatch, not a data entry error.
SELECT
    e.event_name,
    COUNT(*)                                                                               AS events_before_install,
    ROUND(AVG(EXTRACT(EPOCH FROM (u.install_date - e.event_timestamp)) / 86400), 1)       AS avg_days_before_install,
    MAX(EXTRACT(EPOCH FROM (u.install_date - e.event_timestamp)) / 86400)::INT            AS max_days_before_install
FROM build_pulsefit.events e
JOIN build_pulsefit.users  u USING (user_id)
WHERE e.event_timestamp < u.install_date
  AND u.install_date    IS NOT NULL
GROUP BY e.event_name
ORDER BY events_before_install DESC;

-- ── FINDING B: subscription dates missing ────────────────────────────────────

-- B1. How complete is the subscriptions raw data?
SELECT
    'subscriptions coverage'                        AS finding,
    COUNT(*)                                        AS total_subscriptions,
    COUNT(start_date)                               AS has_start_date,
    COUNT(end_date)                                 AS has_end_date,
    ROUND(100.0 * COUNT(start_date) / COUNT(*), 1) AS start_date_pct,
    ROUND(100.0 * COUNT(end_date)   / COUNT(*), 1) AS end_date_pct
FROM build_pulsefit.subscriptions;

-- B2. Events fill the gap: subscription_started events with timestamps
SELECT
    'event-derived subscription starts'             AS finding,
    COUNT(DISTINCT user_id)                         AS users_with_sub_event,
    MIN(event_timestamp)                            AS earliest_sub,
    MAX(event_timestamp)                            AS latest_sub
FROM build_pulsefit.events
WHERE event_name = 'subscription_started';

-- B3. Cross-reference: three-way split between subscriptions table and event stream.
--   in_subscriptions_only  = known subscribers with no start event (dark conversions)
--   in_both                = users with both a table row and an event (the clean overlap)
--   in_events_only         = users who fired the event but have no subscriptions row
SELECT
    COUNT(DISTINCT s.user_id) FILTER (WHERE e.user_id IS NULL)     AS in_subscriptions_only,
    COUNT(DISTINCT s.user_id) FILTER (WHERE e.user_id IS NOT NULL) AS in_both,
    COUNT(DISTINCT e.user_id) FILTER (WHERE s.user_id IS NULL)     AS in_events_only
FROM build_pulsefit.subscriptions s
FULL OUTER JOIN (
    SELECT DISTINCT user_id
    FROM build_pulsefit.events
    WHERE event_name = 'subscription_started'
) e USING (user_id);

-- B4. Implication: event-derived subscription timing per channel
--    (subscription_started events joined through dim_user for channel attribution)
SELECT
    c.channel_name,
    COUNT(DISTINCT e.user_id)       AS subscribers,
    MIN(e.event_timestamp)::DATE    AS first_sub_date,
    MAX(e.event_timestamp)::DATE    AS last_sub_date
FROM star_pulsefit.fact_events      e
JOIN star_pulsefit.dim_user         u USING (user_id)
JOIN star_pulsefit.dim_channel      c ON c.channel_id = u.channel_id
WHERE e.event_name = 'subscription_started'
GROUP BY c.channel_name
ORDER BY subscribers DESC;
