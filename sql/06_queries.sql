-- Databricks notebook source
-- MAGIC %md
-- MAGIC # Interview queries
-- MAGIC
-- MAGIC **Read-only:** run these cells to inspect the model and compare reporting windows without resetting data. Requires the setup job to have completed.
-- MAGIC
-- MAGIC Run the bundled customer_orders job to rebuild and validate everything. Source notebooks are in sql/; the job definition is in resources/customer_orders.job.yml.
-- MAGIC
-- MAGIC **Reporting windows:** `last_calendar_month` is the preceding full calendar month. `previous_30_days` is the 30 complete UTC days before `as_of_date`, excluding that date. Both use an inclusive start and exclusive end. Pass `current_date()` for today or a fixed date for reproducible analysis. The date controls the reporting window, not historical cancellation state.

-- COMMAND ----------
SET TIME ZONE 'UTC';

-- COMMAND ----------
-- One row per header, including empty orders; only Completed orders have a completion time.
SELECT * FROM workspace.interview_orders.order_status ORDER BY order_id;

-- COMMAND ----------
-- Fixtures produce sourdough and croissant tied at 10 ordered units each.
-- ORDER BY controls display order only; the view already retains every first-place tie.
SELECT * FROM workspace.interview_orders.most_sold_last_month ORDER BY product_id;

-- COMMAND ----------
-- Rolling results vary with today relative to the month-anchored sample records.
-- Compare with the calendar-month result to see how the window changes inclusion.
SELECT * FROM workspace.interview_orders.most_sold_previous_30 ORDER BY product_id;

-- COMMAND ----------
-- Fixtures produce 104 delivered muffins, including an order placed before last month.
SELECT * FROM workspace.interview_orders.most_delivered_last_month ORDER BY product_id;

-- COMMAND ----------
-- Use the same rolling window with delivery timestamps and Delivered lines only.
SELECT * FROM workspace.interview_orders.most_delivered_previous_30 ORDER BY product_id;
