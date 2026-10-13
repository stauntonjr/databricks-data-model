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

-- COMMAND ----------
-- Managed table descriptions for Unity Catalog Catalog Explorer.
COMMENT ON TABLE workspace.interview_orders.customers IS '**Type:** Managed Delta table. Customer master records; each customer can place many orders. **Columns:** customer_id, name. **Constraints:** informational PRIMARY KEY (customer_id); enforced NOT NULL on customer_id and name; no foreign key or CHECK constraints. SQL validation checks customer_id uniqueness; orders.customer_id is validated against this table. Unity Catalog primary keys are not enforced.';

COMMENT ON TABLE workspace.interview_orders.products IS '**Type:** Managed Delta table. Product catalog containing product_id, name, category and current_unit_price. Purchase-time pricing is independently captured in order_items.unit_price. **Constraints:** informational PRIMARY KEY (product_id); enforced NOT NULL on all four columns; no foreign key or CHECK constraints. SQL validation checks uniqueness and nonnegative current_unit_price and verifies references from order_items.';

COMMENT ON TABLE workspace.interview_orders.orders IS '**Type:** Managed Delta table. Order headers with order_id, customer_id and ordered_at (TIMESTAMP_NTZ; UTC convention). Each customer has many orders; line items track products and fulfillment. **Constraints:** informational PRIMARY KEY (order_id), informational FOREIGN KEY (customer_id) REFERENCES customers(customer_id), enforced NOT NULL on all three columns; no CHECK constraints. SQL validation checks uniqueness and customer references; order-level status is derived in the order_status view.';

COMMENT ON TABLE workspace.interview_orders.order_items IS '**Type:** Managed Delta table. Order lines joining orders to products, with quantity, purchase-time unit_price, line_status and delivery/cancellation timestamps; one status applies to each full line quantity. **Constraints:** informational composite PRIMARY KEY (order_id, line_number); informational FOREIGN KEY (order_id) REFERENCES orders and FOREIGN KEY (product_id) REFERENCES products; enforced NOT NULL on order_id, line_number, product_id, quantity, unit_price, line_status. Enforced CHECK valid_item requires positive line_number and quantity, nonnegative price, status in Pending/Shipped/Delivered/Cancelled, delivered_at exactly for Delivered and cancelled_at exactly for Cancelled. Additional SQL assertions validate uniqueness, references and event chronology.';


-- COMMAND ----------
-- Column metadata; rerunnable for existing managed Delta tables.
ALTER TABLE workspace.interview_orders.customers ALTER COLUMN customer_id COMMENT 'Unique customer identifier; informational primary key; NOT NULL.';
ALTER TABLE workspace.interview_orders.customers ALTER COLUMN name COMMENT 'Customer display name; NOT NULL.';
ALTER TABLE workspace.interview_orders.products ALTER COLUMN product_id COMMENT 'Unique product identifier; informational primary key; NOT NULL.';
ALTER TABLE workspace.interview_orders.products ALTER COLUMN name COMMENT 'Product display name; NOT NULL.';
ALTER TABLE workspace.interview_orders.products ALTER COLUMN category COMMENT 'Product grouping for classification and reporting; NOT NULL.';
ALTER TABLE workspace.interview_orders.products ALTER COLUMN current_unit_price COMMENT 'Current catalog unit price in currency units; DECIMAL(10,2), NOT NULL; nonnegative value checked by validation SQL.';
ALTER TABLE workspace.interview_orders.orders ALTER COLUMN order_id COMMENT 'Unique order identifier; informational primary key; NOT NULL.';
ALTER TABLE workspace.interview_orders.orders ALTER COLUMN customer_id COMMENT 'Customer placing this order; informational foreign key to customers.customer_id; NOT NULL.';
ALTER TABLE workspace.interview_orders.orders ALTER COLUMN ordered_at COMMENT 'Order placement timestamp, TIMESTAMP_NTZ using UTC convention; used in ordered-unit reporting; NOT NULL.';
ALTER TABLE workspace.interview_orders.order_items ALTER COLUMN order_id COMMENT 'Parent order identifier; part of informational composite primary key and foreign key to orders; NOT NULL.';
ALTER TABLE workspace.interview_orders.order_items ALTER COLUMN line_number COMMENT 'Positive line number within an order; part of informational composite primary key; NOT NULL and CHECK > 0.';
ALTER TABLE workspace.interview_orders.order_items ALTER COLUMN product_id COMMENT 'Ordered product; informational foreign key to products.product_id; NOT NULL.';
ALTER TABLE workspace.interview_orders.order_items ALTER COLUMN quantity COMMENT 'Units on this line; positive integer enforced by CHECK; NOT NULL.';
ALTER TABLE workspace.interview_orders.order_items ALTER COLUMN unit_price COMMENT 'Price per unit at purchase, retained independently from current product price; DECIMAL(10,2), nonnegative; NOT NULL.';
ALTER TABLE workspace.interview_orders.order_items ALTER COLUMN line_status COMMENT 'Current whole-line fulfillment state: Pending, Shipped, Delivered or Cancelled; CHECK-restricted; NOT NULL.';
ALTER TABLE workspace.interview_orders.order_items ALTER COLUMN delivered_at COMMENT 'Delivery event timestamp in UTC convention; required exactly when line_status = Delivered, otherwise NULL.';
ALTER TABLE workspace.interview_orders.order_items ALTER COLUMN cancelled_at COMMENT 'Cancellation event timestamp in UTC convention; required exactly when line_status = Cancelled, otherwise NULL.';
