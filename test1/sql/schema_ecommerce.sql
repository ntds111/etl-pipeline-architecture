-- ============================================================
-- Part 1: SQL Foundations schema (ecommerce)
-- Run with: psql calimoto_data -f test1/sql/schema_ecommerce.sql
-- ============================================================

CREATE SCHEMA IF NOT EXISTS ecommerce;

DROP TABLE IF EXISTS ecommerce.order_items;
DROP TABLE IF EXISTS ecommerce.orders;
DROP TABLE IF EXISTS ecommerce.customers;

CREATE TABLE ecommerce.customers (
    customer_id   TEXT PRIMARY KEY,
    customer_name TEXT NOT NULL,
    signup_date   DATE,
    country       TEXT
);

CREATE TABLE ecommerce.orders (
    order_id    TEXT PRIMARY KEY,
    customer_id TEXT NOT NULL REFERENCES ecommerce.customers(customer_id),
    order_date  DATE,
    status      TEXT
);

CREATE INDEX idx_orders_customer_id ON ecommerce.orders(customer_id);

CREATE TABLE ecommerce.order_items (
    order_item_id TEXT PRIMARY KEY,
    order_id      TEXT NOT NULL REFERENCES ecommerce.orders(order_id),
    product_sku   TEXT,
    product_name  TEXT,
    quantity      INTEGER        NOT NULL CHECK (quantity > 0),
    unit_price    NUMERIC(10,2)  NOT NULL CHECK (unit_price > 0)
);

CREATE INDEX idx_order_items_order_id ON ecommerce.order_items(order_id);
