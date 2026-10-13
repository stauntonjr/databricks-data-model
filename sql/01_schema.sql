-- Databricks notebook source
-- MAGIC %md
-- MAGIC # Schema and constraints
-- MAGIC
-- MAGIC Creates the dedicated schema, four Delta tables, and item constraints. Run the bundle job for the full workflow.
-- MAGIC Table and column comments are defined at creation; `IF NOT EXISTS` leaves existing tables and their comments unchanged.
-- MAGIC
-- MAGIC **Model:** Customers 1 → many Orders; Orders 1 → many Order items; Products 1 → many Order items. A line is identified by `(order_id, line_number)`; the same product may appear on multiple lines. `unit_price` captures the price at purchase, independently of the current product price.
-- MAGIC
-- MAGIC **Logical architecture:** synthetic records → four managed Delta tables in Unity Catalog → order-status and sales views → SQL results. Primary/foreign keys describe relationships but are not enforced by Databricks; executable checks below validate uniqueness and references.

-- COMMAND ----------
SET TIME ZONE 'UTC';

-- COMMAND ----------
-- Creation-time metadata does not refresh an existing schema description.
-- Fully qualified names keep every object in the dedicated demo schema.
CREATE SCHEMA IF NOT EXISTS workspace.interview_orders
COMMENT 'interview_orders — Schema Description

The interview_orders schema contains a relational customer order management and sales reporting model implemented using Databricks Delta Lake and governed through Unity Catalog. It demonstrates entity-relationship modeling, referential integrity, item-level fulfillment tracking, derived order status, temporal analytics, and SQL-based data quality validation.

Data Model

The schema consists of four managed Delta tables representing the core business entities:
- customers — Customer master records, uniquely identified by customer_id.
- products — Product catalog containing product identifiers, names, categories, and current unit prices.
- orders — Order headers associating customers with orders and recording order placement timestamps.
- order_items — Individual order lines associating orders with products, quantities, purchase-time unit prices, fulfillment statuses, and delivery or cancellation timestamps.
Relationships follow a normalized one-to-many model: each customer can place multiple orders, each order can contain multiple line items, and each product can appear on multiple order lines. Order items use a composite primary key (order_id, line_number), allowing the same product to appear on multiple lines within an order.
Purchase-time prices are stored independently of current product prices to preserve transaction values when catalog prices change.
Primary and foreign key relationships are declared in Unity Catalog as informational constraints. Because Databricks does not enforce these relationships, additional SQL validation checks verify key uniqueness and referential integrity. Enforced NOT NULL and CHECK constraints protect item-level data quality.

Order Fulfillment and Status Management

Fulfillment is tracked at the individual order-line level using four statuses:
- Pending: Item has not shipped.
- Shipped: Item is in transit.
- Delivered: Item has been delivered, with a recorded delivery timestamp.
- Cancelled: Item has been cancelled, with a recorded cancellation timestamp.
The order_status view dynamically derives order-level fulfillment status from its constituent line items:
- Pending: No items exist, or at least one item is pending and every other item is pending or cancelled.
- InProgress: At least one item has shipped or been delivered while other active items remain unresolved.
- Completed: At least one item has been delivered and all remaining items are either delivered or cancelled.
- Cancelled: At least one line item exists and all line items have been cancelled.
For completed orders, completed_at represents the latest delivery or cancellation event required to resolve the order.
This derived approach avoids storing redundant order-level status and ensures consistency between order headers and their line items.
Modeling assumption: An order containing both delivered and cancelled items may be considered completed once every line is resolved. Partial-quantity fulfillment, returns, and historical status transitions are outside the current model.

Sales Analytics and Reporting

The schema provides reusable SQL table-valued functions and convenience views supporting product sales analysis across two reporting periods:
- Last calendar month: The entire preceding calendar month.
- Previous 30 days: The 30 complete days preceding the reporting date.
Primary reporting objects include:
- reporting_window — Generates start-inclusive, end-exclusive reporting boundaries.
- most_sold_products — Ranks products by total ordered quantity, excluding currently cancelled lines.
- most_delivered_products — Ranks products by quantities actually delivered during the selected period.
- most_sold_last_month and most_sold_previous_30 — Convenience views for ordered-unit rankings.
- most_delivered_last_month and most_delivered_previous_30 — Convenience views for delivered-unit rankings.
Product rankings aggregate quantities rather than counting order lines and use DENSE_RANK() to preserve ties for the highest-selling product.
The distinction between ordered units and delivered units illustrates how business definitions, event timestamps, cancellations, and reporting windows affect analytical results.
Sales reporting reflects current cancellation status rather than historical status as of the end of the reporting period.

Data Quality and Validation

The implementation includes ten executable SQL assertions covering:
- Primary key uniqueness and foreign key references.
- Valid order-item quantities, prices, and fulfillment statuses.
- Consistency between fulfillment statuses and event timestamps.
- Order-level status derivation and completion timestamps.
- Calendar-month and rolling-window date boundaries.
- Correct inclusion and exclusion of boundary timestamps.
- Quantity aggregation, cancelled-item exclusion, and sales-ranking ties.
- Differences between order-date-based sales and delivery-date-based reporting.
- Chronological consistency between order placement and fulfillment events.
Validation failures raise SQL errors and halt the execution workflow.

Databricks Architecture and Execution

All four entities are stored as Unity Catalog-managed Delta tables, providing ACID transactional storage, schema enforcement, and integration with Databricks SQL.
A Databricks Asset Bundle defines a six-stage workflow:
1. Create schema and tables.
2. Load synthetic sample data.
3. Create the order-status view.
4. Create sales-reporting functions and views.
5. Execute data-quality assertions.
6. Display reporting results.
The sample dataset includes representative fulfillment combinations, cancelled quantities, empty orders, tied product rankings, and temporal boundary cases. Date-relative sample records support repeatable demonstrations of reporting behavior.
The implementation uses Databricks SQL and a SQL warehouse for processing, with source code maintained in Git and deployment configuration managed through a Databricks Asset Bundle.

Purpose and Scope

This schema is a self-contained demonstration of relational data modeling and analytical processing on the Databricks Lakehouse Platform. It illustrates how normalized operational entities can be represented in Delta Lake, governed through Unity Catalog, validated using SQL, and exposed through reusable analytical functions and views.
The architecture intentionally prioritizes data-model correctness, explainable business logic, reproducible test data, and query transparency over production-scale ingestion complexity.
Catalog: workspace
Schema: interview_orders
Storage format: Delta Lake
Primary workload: Customer order fulfillment and product sales analytics
Data classification: Synthetic demonstration data';

-- COMMAND ----------
-- Create referenced parent tables before the order headers and lines.
-- IF NOT EXISTS preserves existing data; it is not a schema migration mechanism.
CREATE TABLE IF NOT EXISTS workspace.interview_orders.customers (
  customer_id BIGINT NOT NULL COMMENT 'Unique customer identifier; informational primary key; NOT NULL.',
  name STRING NOT NULL COMMENT 'Customer display name; NOT NULL.',
  CONSTRAINT customers_pk PRIMARY KEY (customer_id)
) USING DELTA
COMMENT '**Type:** Managed Delta table. Customer master records; each customer can place many orders. **Columns:** customer_id, name. **Constraints:** informational PRIMARY KEY (customer_id); enforced NOT NULL on customer_id and name; no foreign key or CHECK constraints. SQL validation checks customer_id uniqueness; orders.customer_id is validated against this table. Unity Catalog primary keys are not enforced.';

-- COMMAND ----------
CREATE TABLE IF NOT EXISTS workspace.interview_orders.products (
  product_id BIGINT NOT NULL COMMENT 'Unique product identifier; informational primary key; NOT NULL.',
  name STRING NOT NULL COMMENT 'Product display name; NOT NULL.',
  category STRING NOT NULL COMMENT 'Product grouping for classification and reporting; NOT NULL.',
  current_unit_price DECIMAL(10,2) NOT NULL COMMENT 'Current catalog unit price in currency units; DECIMAL(10,2), NOT NULL; nonnegative value checked by validation SQL.',
  CONSTRAINT products_pk PRIMARY KEY (product_id)
) USING DELTA
COMMENT '**Type:** Managed Delta table. Product catalog containing product_id, name, category and current_unit_price. Purchase-time pricing is independently captured in order_items.unit_price. **Constraints:** informational PRIMARY KEY (product_id); enforced NOT NULL on all four columns; no foreign key or CHECK constraints. SQL validation checks uniqueness and nonnegative current_unit_price and verifies references from order_items.';

-- COMMAND ----------
-- Store header facts once per order; derive fulfillment from lines in order_status.
-- TIMESTAMP_NTZ stores wall-clock values; UTC is a convention, not an embedded zone.
CREATE TABLE IF NOT EXISTS workspace.interview_orders.orders (
  order_id BIGINT NOT NULL COMMENT 'Unique order identifier; informational primary key; NOT NULL.',
  customer_id BIGINT NOT NULL COMMENT 'Customer placing this order; informational foreign key to customers.customer_id; NOT NULL.',
  ordered_at TIMESTAMP_NTZ NOT NULL COMMENT 'Order placement timestamp, TIMESTAMP_NTZ using UTC convention; used in ordered-unit reporting; NOT NULL.',
  CONSTRAINT orders_pk PRIMARY KEY (order_id),
  CONSTRAINT orders_customer_fk FOREIGN KEY (customer_id)
    REFERENCES workspace.interview_orders.customers (customer_id)
) USING DELTA
COMMENT '**Type:** Managed Delta table. Order headers with order_id, customer_id and ordered_at (TIMESTAMP_NTZ; UTC convention). Each customer has many orders; line items track products and fulfillment. **Constraints:** informational PRIMARY KEY (order_id), informational FOREIGN KEY (customer_id) REFERENCES customers(customer_id), enforced NOT NULL on all three columns; no CHECK constraints. SQL validation checks uniqueness and customer references; order-level status is derived in the order_status view.';

-- COMMAND ----------
-- Grain: one product line within one order, identified by order_id + line_number.
-- Repeated product IDs are allowed; quantity and status apply to the whole line.
-- Purchase-time unit_price remains independent of later catalog price changes.
CREATE TABLE IF NOT EXISTS workspace.interview_orders.order_items (
  order_id BIGINT NOT NULL COMMENT 'Parent order identifier; part of informational composite primary key and foreign key to orders; NOT NULL.',
  line_number INT NOT NULL COMMENT 'Positive line number within an order; part of informational composite primary key; NOT NULL and CHECK > 0.',
  product_id BIGINT NOT NULL COMMENT 'Ordered product; informational foreign key to products.product_id; NOT NULL.',
  quantity INT NOT NULL COMMENT 'Units on this line; positive integer enforced by CHECK; NOT NULL.',
  unit_price DECIMAL(10,2) NOT NULL COMMENT 'Price per unit at purchase, retained independently from current product price; DECIMAL(10,2), nonnegative; NOT NULL.',
  line_status STRING NOT NULL COMMENT 'Current whole-line fulfillment state: Pending, Shipped, Delivered or Cancelled; CHECK-restricted; NOT NULL.',
  delivered_at TIMESTAMP_NTZ COMMENT 'Delivery event timestamp in UTC convention; required exactly when line_status = Delivered, otherwise NULL.',
  cancelled_at TIMESTAMP_NTZ COMMENT 'Cancellation event timestamp in UTC convention; required exactly when line_status = Cancelled, otherwise NULL.',
  CONSTRAINT order_items_pk PRIMARY KEY (order_id, line_number),
  CONSTRAINT items_order_fk FOREIGN KEY (order_id)
    REFERENCES workspace.interview_orders.orders (order_id),
  CONSTRAINT items_product_fk FOREIGN KEY (product_id)
    REFERENCES workspace.interview_orders.products (product_id)
) USING DELTA
COMMENT '**Type:** Managed Delta table. Order lines joining orders to products, with quantity, purchase-time unit_price, line_status and delivery/cancellation timestamps; one status applies to each full line quantity. **Constraints:** informational composite PRIMARY KEY (order_id, line_number); informational FOREIGN KEY (order_id) REFERENCES orders and FOREIGN KEY (product_id) REFERENCES products; enforced NOT NULL on order_id, line_number, product_id, quantity, unit_price, line_status. Enforced CHECK valid_item requires positive line_number and quantity, nonnegative price, status in Pending/Shipped/Delivered/Cancelled, delivered_at exactly for Delivered and cancelled_at exactly for Cancelled. Additional SQL assertions validate uniqueness, references and event chronology.';

-- COMMAND ----------
-- Makes constraint setup rerunnable on this dedicated demo table.
-- DROP and ADD are separate statements, so this is not an atomic constraint update.
-- Adding the check validates existing rows too; invalid old data can stop setup.
-- Cross-table references and event chronology are checked in 05_validation.sql.
ALTER TABLE workspace.interview_orders.order_items
DROP CONSTRAINT IF EXISTS valid_item;

-- COMMAND ----------
-- Enforces positive line numbers and quantities, nonnegative prices, and allowed statuses.
-- Delivery and cancellation timestamps must be present exactly for their matching status
-- and NULL otherwise, keeping each line's fulfillment state consistent.
ALTER TABLE workspace.interview_orders.order_items ADD CONSTRAINT valid_item CHECK (
  line_number > 0 AND quantity > 0 AND unit_price >= 0
  AND line_status IN ('Pending', 'Shipped', 'Delivered', 'Cancelled')
  AND ((line_status = 'Delivered' AND delivered_at IS NOT NULL)
    OR (line_status <> 'Delivered' AND delivered_at IS NULL))
  AND ((line_status = 'Cancelled' AND cancelled_at IS NOT NULL)
    OR (line_status <> 'Cancelled' AND cancelled_at IS NULL))
);
