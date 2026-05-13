-- ============================================================
-- Q1: Total revenue per customer, descending
-- Business rules assumed:
--   Revenue-generating statuses : completed only
--   Deducted statuses           : refunded, cancelled
--   Excluded from revenue       : shipped (in transit, not yet earned),
--                                 pending (not yet fulfilled)
--   Customer scope              : all customers, including zero-revenue
-- ============================================================
SELECT
    c.customer_id,
    c.customer_name,
    SUM(CASE WHEN o.status = 'completed'  THEN oi.quantity * oi.unit_price ELSE 0 END) AS completed_amount,
    SUM(CASE WHEN o.status = 'shipped'    THEN oi.quantity * oi.unit_price ELSE 0 END) AS shipped_amount,
    SUM(CASE WHEN o.status = 'refunded'   THEN oi.quantity * oi.unit_price ELSE 0 END) AS refunded_amount,
    SUM(CASE WHEN o.status = 'cancelled'  THEN oi.quantity * oi.unit_price ELSE 0 END) AS cancelled_amount,
    ROUND(
        SUM(CASE WHEN o.status = 'completed'                THEN oi.quantity * oi.unit_price ELSE 0 END)
      - SUM(CASE WHEN o.status IN ('refunded', 'cancelled') THEN oi.quantity * oi.unit_price ELSE 0 END)
    , 2) AS net_revenue
FROM ecommerce.customers c
LEFT JOIN ecommerce.orders o
    ON o.customer_id = c.customer_id
LEFT JOIN ecommerce.order_items oi
    ON oi.order_id = o.order_id
GROUP BY
    c.customer_id,
    c.customer_name
ORDER BY
    net_revenue DESC;