-- ============================================================
-- Q3: Reactivated customers — reactivation date and gap
-- Business rules assumed:
--   Revenue-generating status   : completed only (shipped excluded —
--                                 in transit orders do not confirm customer activity)
--   Active window               : last 90 days up to and including max_date
--                                 (max_date - 89 days → max_date, both endpoints inclusive)
--   Silence window              : 180 days immediately before the active window
--   Pre-gap requirement         : at least one completed order before the silence window
--   Reactivation date           : earliest completed order inside the active window
--   Gap                         : reactivation_date − last completed order before silence window
-- ============================================================
WITH params AS (
    SELECT
        MAX(order_date::DATE)                            AS max_date,
        MAX(order_date::DATE) - INTERVAL '89 days'      AS active_start,
        MAX(order_date::DATE) - INTERVAL '90 days'      AS gap_end,
        MAX(order_date::DATE) - INTERVAL '269 days'     AS gap_start
    FROM ecommerce.orders
    WHERE status = 'completed'
),
flags AS (
    SELECT
        o.customer_id,
        MAX(CASE WHEN o.order_date::DATE BETWEEN p.active_start AND p.max_date THEN 1 ELSE 0 END) AS in_active,
        MAX(CASE WHEN o.order_date::DATE BETWEEN p.gap_start    AND p.gap_end  THEN 1 ELSE 0 END) AS in_gap,
        MAX(CASE WHEN o.order_date::DATE < p.gap_start                         THEN 1 ELSE 0 END) AS pre_gap,
        MIN(CASE WHEN o.order_date::DATE BETWEEN p.active_start AND p.max_date
                 THEN o.order_date::DATE END)                                                      AS reactivation_date,
        MAX(CASE WHEN o.order_date::DATE < p.gap_start
                 THEN o.order_date::DATE END)                                                      AS last_pre_gap_order
    FROM ecommerce.orders o
    CROSS JOIN params p
    WHERE o.status = 'completed'
    GROUP BY o.customer_id
)
SELECT
    f.customer_id,
    c.customer_name,
    f.last_pre_gap_order,
    f.reactivation_date,
    (f.reactivation_date - f.last_pre_gap_order) AS reactivation_gap_days
FROM flags f
JOIN ecommerce.customers c ON c.customer_id = f.customer_id
WHERE f.in_active = 1
  AND f.in_gap    = 0
  AND f.pre_gap   = 1
ORDER BY reactivation_gap_days DESC;