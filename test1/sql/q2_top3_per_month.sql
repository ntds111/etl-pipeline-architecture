-- ============================================================
-- Q2: Top 3 customers by net revenue for each calendar month in 2026
-- Business rules assumed:
--   Revenue-generating statuses : completed only
--   Deducted statuses           : refunded, cancelled
--   Excluded from revenue       : shipped (in transit, not yet earned),
--                                 pending (not yet fulfilled)
--   Ranking                     : DENSE_RANK — ties share a position,
--                                 next position is not skipped;
--                                 a month may show more than 3 rows if tied at rank 3
--   Year filter                 : calendar year 2026 (order_date)
-- ============================================================
WITH monthly_revenue AS (
    SELECT
        c.customer_id,
        c.customer_name,
        DATE_TRUNC('month', o.order_date::DATE)        AS month_start,
        TO_CHAR(o.order_date::DATE, 'Month YYYY')      AS month_label,
        ROUND(
            SUM(CASE WHEN o.status = 'completed'                THEN oi.quantity * oi.unit_price ELSE 0 END)
          - SUM(CASE WHEN o.status IN ('refunded', 'cancelled') THEN oi.quantity * oi.unit_price ELSE 0 END)
        , 2) AS net_revenue
    FROM ecommerce.customers c
    JOIN ecommerce.orders o
        ON  o.customer_id = c.customer_id
        AND o.order_date::DATE >= '2026-01-01'
        AND o.order_date::DATE <  '2027-01-01'
    JOIN ecommerce.order_items oi
        ON  oi.order_id = o.order_id
    GROUP BY
        c.customer_id,
        c.customer_name,
        month_start,
        month_label
),
ranked AS (
    SELECT
        month_start,
        month_label,
        customer_id,
        customer_name,
        net_revenue,
        DENSE_RANK() OVER (PARTITION BY month_start ORDER BY net_revenue DESC) AS rank_in_month
    FROM monthly_revenue
)
SELECT
    month_label,
    rank_in_month,
    customer_id,
    customer_name,
    net_revenue
FROM ranked
WHERE rank_in_month <= 3
ORDER BY
    month_start,
    rank_in_month;