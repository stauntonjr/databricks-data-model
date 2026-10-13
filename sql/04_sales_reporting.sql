-- Databricks notebook source
-- MAGIC %md
-- MAGIC # Sales reporting functions and views
-- MAGIC
-- MAGIC Requires the four tables. Defines reusable window and product-ranking functions plus convenience views for last month and the previous 30 complete days.
-- MAGIC
-- MAGIC **Reporting windows:** `last_calendar_month` is the preceding full calendar month. `previous_30_days` is the 30 complete UTC days before `as_of_date`, excluding that date. Both use an inclusive start and exclusive end. Pass `current_date()` for today or a fixed date for reproducible analysis. The date controls the reporting window, not historical cancellation state.
-- MAGIC
-- MAGIC **Sales definition:** units ordered during the selected reporting window (previous calendar month by default), excluding lines currently Cancelled; all first-place ties are returned. Timestamps represent UTC without time-zone conversion. Run standalone view queries in a UTC session too. Demo dates are relative to the run date; rerun all cells after the month changes. This reports current cancellation state, not historical month-end state.

-- COMMAND ----------
SET TIME ZONE 'UTC';

-- COMMAND ----------
-- Shared date-window logic. Invalid modes and NULL dates fail explicitly.
CREATE OR REPLACE FUNCTION workspace.interview_orders.reporting_window(
  window_kind STRING, as_of_date DATE
)
RETURNS TABLE (window_start TIMESTAMP_NTZ, window_end TIMESTAMP_NTZ)
COMMENT 'Reusable table-valued function returning start-inclusive/end-exclusive UTC TIMESTAMP_NTZ boundaries for last_calendar_month or previous_30_days based on as_of_date; invalid inputs raise errors. No PK, FK, NOT NULL or CHECK constraints are declared for function results.'
RETURN
SELECT
  CAST(CASE
    WHEN as_of_date IS NULL THEN raise_error('as_of_date must not be NULL')
    WHEN window_kind = 'last_calendar_month' THEN add_months(trunc(as_of_date, 'MM'), -1)
    WHEN window_kind = 'previous_30_days' THEN date_sub(as_of_date, 30)
    ELSE raise_error('window_kind must be last_calendar_month or previous_30_days')
  END AS TIMESTAMP_NTZ) AS window_start,
  CAST(CASE
    WHEN as_of_date IS NULL THEN raise_error('as_of_date must not be NULL')
    WHEN window_kind = 'last_calendar_month' THEN trunc(as_of_date, 'MM')
    WHEN window_kind = 'previous_30_days' THEN as_of_date
    ELSE raise_error('window_kind must be last_calendar_month or previous_30_days')
  END AS TIMESTAMP_NTZ) AS window_end;

-- COMMAND ----------
-- Main interview query: quantity, not line count or revenue.
-- Inclusive start / exclusive end applies to either reporting window.
-- Aggregate before ranking; DENSE_RANK preserves all first-place ties.
CREATE OR REPLACE FUNCTION workspace.interview_orders.most_sold_products(
  window_kind STRING, as_of_date DATE
)
RETURNS TABLE (product_id BIGINT, name STRING, units_sold BIGINT)
COMMENT 'Reusable table-valued function ranking products by SUM(quantity) of orders placed inside a selected date window, excluding currently cancelled lines. DENSE_RANK = 1 returns all tied leaders. Results: product_id, name, units_sold. No independently declared relational constraints.'
RETURN
WITH boundaries AS (
  SELECT * FROM workspace.interview_orders.reporting_window(window_kind, as_of_date)
), product_sales AS (
  SELECT i.product_id, sum(i.quantity) AS units_sold
  FROM workspace.interview_orders.orders o
  JOIN workspace.interview_orders.order_items i ON i.order_id = o.order_id
  CROSS JOIN boundaries b
  WHERE o.ordered_at >= b.window_start
    AND o.ordered_at < b.window_end
    AND i.line_status <> 'Cancelled'
  GROUP BY i.product_id
), ranked AS (
  SELECT *, dense_rank() OVER (ORDER BY units_sold DESC) AS sales_rank
  FROM product_sales
)
SELECT p.product_id, p.name, r.units_sold
FROM ranked r
JOIN workspace.interview_orders.products p ON p.product_id = r.product_id
WHERE r.sales_rank = 1;

-- COMMAND ----------
-- Preserve the original view for callers that always want last month.
CREATE OR REPLACE VIEW workspace.interview_orders.most_sold_last_month (
  product_id COMMENT 'Product identifier tied for most ordered units last calendar month.',
  name COMMENT 'Product display name.',
  units_sold COMMENT 'Sum of non-cancelled ordered quantities for this product last calendar month.'
) AS
SELECT * FROM workspace.interview_orders.most_sold_products('last_calendar_month', current_date());

-- COMMAND ----------
-- Rolling window: the 30 complete days before today, excluding today.
CREATE OR REPLACE VIEW workspace.interview_orders.most_sold_previous_30 (
  product_id COMMENT 'Product identifier tied for most ordered units in previous 30 complete days.',
  name COMMENT 'Product display name.',
  units_sold COMMENT 'Sum of non-cancelled ordered quantities in previous 30 complete days.'
) AS
SELECT * FROM workspace.interview_orders.most_sold_products('previous_30_days', current_date());

-- COMMAND ----------
-- Alternative business definition: units delivered in the selected window, regardless
-- of order date or whether other lines in the order have been delivered.
CREATE OR REPLACE FUNCTION workspace.interview_orders.most_delivered_products(
  window_kind STRING, as_of_date DATE
)
RETURNS TABLE (product_id BIGINT, name STRING, units_delivered BIGINT)
COMMENT 'Reusable table-valued function ranking products by SUM(quantity) where line_status is Delivered and delivered_at falls within a selected date window, irrespective of order placement. DENSE_RANK = 1 retains ties. Results: product_id, name, units_delivered. No independently declared relational constraints.'
RETURN
WITH boundaries AS (
  SELECT * FROM workspace.interview_orders.reporting_window(window_kind, as_of_date)
), product_sales AS (
  SELECT product_id, sum(quantity) AS units_delivered
  FROM workspace.interview_orders.order_items
  CROSS JOIN boundaries b
  WHERE line_status = 'Delivered'
    AND delivered_at >= b.window_start
    AND delivered_at < b.window_end
  GROUP BY product_id
), ranked AS (
  SELECT *, dense_rank() OVER (ORDER BY units_delivered DESC) AS sales_rank
  FROM product_sales
)
SELECT p.product_id, p.name, r.units_delivered
FROM ranked r
JOIN workspace.interview_orders.products p ON p.product_id = r.product_id
WHERE r.sales_rank = 1;

-- COMMAND ----------
CREATE OR REPLACE VIEW workspace.interview_orders.most_delivered_last_month (
  product_id COMMENT 'Product identifier tied for most delivered units last calendar month.',
  name COMMENT 'Product display name.',
  units_delivered COMMENT 'Sum of quantities with Delivered status and delivery timestamp last calendar month.'
) AS
SELECT * FROM workspace.interview_orders.most_delivered_products('last_calendar_month', current_date());

-- COMMAND ----------
-- Uses delivery timestamps within the same rolling 30-day window.
CREATE OR REPLACE VIEW workspace.interview_orders.most_delivered_previous_30 (
  product_id COMMENT 'Product identifier tied for most delivered units in previous 30 complete days.',
  name COMMENT 'Product display name.',
  units_delivered COMMENT 'Sum of quantities with Delivered status and delivery timestamp in previous 30 complete days.'
) AS
SELECT * FROM workspace.interview_orders.most_delivered_products('previous_30_days', current_date());

-- COMMAND ----------
-- Standard view descriptions in Catalog Explorer.
COMMENT ON TABLE workspace.interview_orders.most_sold_last_month IS '**Type:** Non-materialized SQL view. Highest-volume products by ordered units for the preceding full calendar month. **Constraints:** no declared PK, FK, NOT NULL or CHECK constraints. **Rules:** order-date window [first day of previous month, first day of current month), SUM(order_items.quantity), exclude currently Cancelled lines, DENSE_RANK = 1 preserves all ties. Returns product_id, name, units_sold. Historical month-end cancellation state is not reconstructed; assertions check boundaries and ties.';

COMMENT ON TABLE workspace.interview_orders.most_sold_previous_30 IS '**Type:** Non-materialized SQL view. Highest-volume products by ordered units over the previous 30 complete UTC days, excluding today. **Constraints:** no declared PK, FK, NOT NULL or CHECK constraints. **Rules:** ordered_at in [current_date - 30 days, current_date), SUM(quantity), exclude lines currently Cancelled, DENSE_RANK = 1 retains ties. Returns product_id, name, units_sold; current cancellation state is used.';

COMMENT ON TABLE workspace.interview_orders.most_delivered_last_month IS '**Type:** Non-materialized SQL view. Highest-volume products by delivered units in the preceding complete calendar month, independent of order placement date. **Constraints:** no declared PK, FK, NOT NULL or CHECK constraints. **Rules:** line_status = Delivered; delivered_at in [first day previous month, first day current month); SUM(quantity); DENSE_RANK = 1 returns every first-place tie. Returns product_id, name, units_delivered; SQL assertions verify delivery-date attribution.';

COMMENT ON TABLE workspace.interview_orders.most_delivered_previous_30 IS '**Type:** Non-materialized SQL view. Highest-volume products by delivered units in the preceding 30 complete UTC days, excluding today. **Constraints:** no declared PK, FK, NOT NULL or CHECK constraints. **Rules:** line_status = Delivered; delivered_at in [current_date - 30 days, current_date); SUM(quantity); DENSE_RANK = 1 preserves top ties. Returns product_id, name, units_delivered; delivery date, not order date, determines inclusion.';

