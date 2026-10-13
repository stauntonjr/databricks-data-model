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
CREATE OR REPLACE VIEW workspace.interview_orders.most_sold_last_month AS
SELECT * FROM workspace.interview_orders.most_sold_products('last_calendar_month', current_date());

-- COMMAND ----------
-- Rolling window: the 30 complete days before today, excluding today.
CREATE OR REPLACE VIEW workspace.interview_orders.most_sold_previous_30 AS
SELECT * FROM workspace.interview_orders.most_sold_products('previous_30_days', current_date());

-- COMMAND ----------
-- Alternative business definition: units delivered in the selected window, regardless
-- of order date or whether other lines in the order have been delivered.
CREATE OR REPLACE FUNCTION workspace.interview_orders.most_delivered_products(
  window_kind STRING, as_of_date DATE
)
RETURNS TABLE (product_id BIGINT, name STRING, units_delivered BIGINT)
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
CREATE OR REPLACE VIEW workspace.interview_orders.most_delivered_last_month AS
SELECT * FROM workspace.interview_orders.most_delivered_products('last_calendar_month', current_date());

-- COMMAND ----------
-- Uses delivery timestamps within the same rolling 30-day window.
CREATE OR REPLACE VIEW workspace.interview_orders.most_delivered_previous_30 AS
SELECT * FROM workspace.interview_orders.most_delivered_products('previous_30_days', current_date());
