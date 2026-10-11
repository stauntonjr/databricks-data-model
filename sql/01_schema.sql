-- Databricks notebook source
-- MAGIC %md
-- MAGIC # Schema and constraints
-- MAGIC
-- MAGIC Creates the dedicated schema, four Delta tables, and item constraints. Run the bundle job for the full workflow.
-- MAGIC
-- MAGIC **Model:** Customers 1 → many Orders; Orders 1 → many Order items; Products 1 → many Order items. A line is identified by `(order_id, line_number)`; the same product may appear on multiple lines. `unit_price` captures the price at purchase, independently of the current product price.
-- MAGIC
-- MAGIC **Logical architecture:** synthetic records → four managed Delta tables in Unity Catalog → order-status and sales views → SQL results. Primary/foreign keys describe relationships but are not enforced by Databricks; executable checks below validate uniqueness and references.

-- COMMAND ----------
SET TIME ZONE 'UTC';

-- COMMAND ----------
CREATE SCHEMA IF NOT EXISTS workspace.interview_orders
COMMENT 'Synthetic customer-order interview exercise';

-- COMMAND ----------
CREATE TABLE IF NOT EXISTS workspace.interview_orders.customers (
  customer_id BIGINT NOT NULL,
  name STRING NOT NULL,
  CONSTRAINT customers_pk PRIMARY KEY (customer_id)
) USING DELTA;

-- COMMAND ----------
CREATE TABLE IF NOT EXISTS workspace.interview_orders.products (
  product_id BIGINT NOT NULL,
  name STRING NOT NULL,
  category STRING NOT NULL,
  current_unit_price DECIMAL(10,2) NOT NULL,
  CONSTRAINT products_pk PRIMARY KEY (product_id)
) USING DELTA;

-- COMMAND ----------
CREATE TABLE IF NOT EXISTS workspace.interview_orders.orders (
  order_id BIGINT NOT NULL,
  customer_id BIGINT NOT NULL,
  ordered_at TIMESTAMP_NTZ NOT NULL,
  CONSTRAINT orders_pk PRIMARY KEY (order_id),
  CONSTRAINT orders_customer_fk FOREIGN KEY (customer_id)
    REFERENCES workspace.interview_orders.customers (customer_id)
) USING DELTA;

-- COMMAND ----------
CREATE TABLE IF NOT EXISTS workspace.interview_orders.order_items (
  order_id BIGINT NOT NULL,
  line_number INT NOT NULL,
  product_id BIGINT NOT NULL,
  quantity INT NOT NULL,
  unit_price DECIMAL(10,2) NOT NULL,
  line_status STRING NOT NULL,
  delivered_at TIMESTAMP_NTZ,
  cancelled_at TIMESTAMP_NTZ,
  CONSTRAINT order_items_pk PRIMARY KEY (order_id, line_number),
  CONSTRAINT items_order_fk FOREIGN KEY (order_id)
    REFERENCES workspace.interview_orders.orders (order_id),
  CONSTRAINT items_product_fk FOREIGN KEY (product_id)
    REFERENCES workspace.interview_orders.products (product_id)
) USING DELTA;

-- COMMAND ----------
-- Makes constraint setup rerunnable on this dedicated demo table.
ALTER TABLE workspace.interview_orders.order_items
DROP CONSTRAINT IF EXISTS valid_item;

-- COMMAND ----------
ALTER TABLE workspace.interview_orders.order_items ADD CONSTRAINT valid_item CHECK (
  line_number > 0 AND quantity > 0 AND unit_price >= 0
  AND line_status IN ('Pending', 'Shipped', 'Delivered', 'Cancelled')
  AND ((line_status = 'Delivered' AND delivered_at IS NOT NULL)
    OR (line_status <> 'Delivered' AND delivered_at IS NULL))
  AND ((line_status = 'Cancelled' AND cancelled_at IS NOT NULL)
    OR (line_status <> 'Cancelled' AND cancelled_at IS NULL))
);
