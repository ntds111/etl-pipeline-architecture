-- ============================================================
-- Funnel conversion per channel
-- registered CRM users → workout_started → workout_completed → subscription_started
--
-- POPULATION: dim_user (~500 CRM-registered users). This is NOT app installs.
-- True app installs (10,428 paid total) are in fact_ad_spend.installs (ad-platform
-- reported). CRM users are people who created an account — in freemium, that
-- happens ~45 days after first app open. The two populations cannot be mixed.
--
-- signup_to_workout_pct intentionally omitted: the app is freemium — users
-- can work out and subscribe without completing a formal signup. 166 users
-- worked out with no signup event; 21 subscribed with no signup event.
-- Enforcing signup as a required step would drop real paying customers.
--
-- ATTRIBUTION: single-touch from CRM channel field. Cannot account for users
-- who saw ads from multiple channels before converting. Whether this materially
-- affects rankings is unknown with available data.
--
-- COHORT CAVEAT: all-time aggregate Jan–Mar 2025. Users who joined in March
-- have had fewer weeks to convert than January cohorts. Channels that ramped
-- spend later will appear artificially worse. Cohort-level analysis is possible
-- with event timestamps but not included here.
--
-- Run with: psql -d pulsefit_db -f sql/queries/funnel_conversion.sql
-- ============================================================

WITH funnel AS (
    SELECT
        u.channel_id,
        COUNT(DISTINCT u.user_id)                                                           AS crm_users,
        COUNT(DISTINCT CASE WHEN e.event_name = 'signup_complete'      THEN u.user_id END) AS signups,
        COUNT(DISTINCT CASE WHEN e.event_name = 'workout_started'      THEN u.user_id END) AS workouts_started,
        COUNT(DISTINCT CASE WHEN e.event_name = 'workout_completed'    THEN u.user_id END) AS workouts_completed,
        COUNT(DISTINCT CASE WHEN e.event_name = 'subscription_started' THEN u.user_id END) AS subscriptions
    FROM star_pulsefit.dim_user    u
    LEFT JOIN star_pulsefit.fact_events e USING (user_id)
    GROUP BY u.channel_id
),
-- CPI: ad-platform spend ÷ ad-platform installs (different population to funnel)
cpi AS (
    SELECT channel_id,
        ROUND(SUM(spend_usd) / NULLIF(SUM(installs), 0), 2) AS cost_per_install_usd
    FROM star_pulsefit.fact_ad_spend
    GROUP BY channel_id
),
-- Median thresholds — more robust than mean, one outlier won't shift the flag
median_cpi AS (
    SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY cost_per_install_usd) AS val
    FROM cpi
),
median_conv AS (
    -- paid channels only: organic/referral have no CPI so the flag comparison is meaningless for them
    SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (
        ORDER BY ROUND(100.0 * f.subscriptions / NULLIF(f.crm_users, 0), 1)
    ) AS val
    FROM funnel f
    JOIN star_pulsefit.dim_channel c USING (channel_id)
    WHERE c.is_paid = TRUE
)
SELECT
    c.channel_name,
    c.is_paid,
    f.crm_users,
    f.signups,
    f.workouts_started,
    f.workouts_completed,
    f.subscriptions,

    -- Step rates (signup_to_workout_pct excluded — see header note)
    ROUND(100.0 * f.signups              / NULLIF(f.crm_users,           0), 1) AS crm_to_signup_pct,
    ROUND(100.0 * f.workouts_started     / NULLIF(f.crm_users,           0), 1) AS crm_to_workout_started_pct,
    ROUND(100.0 * f.workouts_completed   / NULLIF(f.workouts_started,    0), 1) AS started_to_completed_pct,
    ROUND(100.0 * f.subscriptions        / NULLIF(f.workouts_completed,  0), 1) AS workout_to_sub_pct,

    -- End-to-end: CRM user → subscription (primary metric)
    ROUND(100.0 * f.subscriptions / NULLIF(f.crm_users,         0), 1) AS overall_conversion_pct,

    -- CPI: ad-platform spend ÷ ad-platform installs (NULL for organic/referral)
    -- WARNING: cannot be multiplied by conversion_pct — different denominators
    cpi.cost_per_install_usd,

    -- Flag: below-median CPI AND below-median conversion
    -- Uses median (not mean) so one outlier channel doesn't shift the threshold
    CASE
        WHEN cpi.cost_per_install_usd IS NOT NULL
         AND cpi.cost_per_install_usd < mc.val
         AND ROUND(100.0 * f.subscriptions / NULLIF(f.crm_users,   0), 1) < mv.val
        THEN 'cheap CAC, poor conversion'
        ELSE NULL
    END AS flag

FROM funnel f
JOIN  star_pulsefit.dim_channel c USING (channel_id)
LEFT JOIN cpi                     USING (channel_id)
CROSS JOIN median_cpi mc
CROSS JOIN median_conv mv
ORDER BY overall_conversion_pct DESC NULLS LAST;
