-- ============================================================
-- Part 2 · Q1: Blended cost per paid-acquisition install
-- Reporting currency: USD
-- Run with: psql calimoto_data -f etl/queries/q1_cac_per_channel.sql
-- ============================================================

SELECT
    c.channel_name,
    c.platform_type,
    SUM(a.spend_usd)                                                    AS total_spend_usd,
    SUM(a.installs)                                                     AS total_installs,
    ROUND(
        SUM(a.spend_usd) / NULLIF(SUM(a.installs), 0),
        2
    )                                                                   AS cost_per_install_usd,
    RANK() OVER (
        ORDER BY SUM(a.spend_usd) / NULLIF(SUM(a.installs), 0)
    )                                                                   AS rank_cheapest_to_most_expensive
FROM star_pulsefit.fact_ad_spend  a
JOIN star_pulsefit.dim_channel    c USING (channel_id)
WHERE c.is_paid  = TRUE
  AND a.installs > 0
GROUP BY c.channel_id, c.channel_name, c.platform_type
ORDER BY cost_per_install_usd;
