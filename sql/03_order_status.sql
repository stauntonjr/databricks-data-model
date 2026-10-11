-- Databricks notebook source
-- MAGIC %md
-- MAGIC # Order status
-- MAGIC
-- MAGIC Requires the four tables. Defines one derived status and completion timestamp per order.
-- MAGIC
-- MAGIC **Rules:** an order is Completed when at least one line is Delivered and every other line is Delivered or Cancelled. Completion occurs at the final delivery or cancellation, whichever is later. All-cancelled orders are Cancelled. Empty orders, and orders whose remaining active lines are all Pending, are Pending. Other combinations are InProgress. Each line has one status for its full quantity; split shipments and status history are outside this exercise.

-- COMMAND ----------
SET TIME ZONE 'UTC';

-- COMMAND ----------
CREATE OR REPLACE VIEW workspace.interview_orders.order_status AS
WITH item_summary AS (
  SELECT
    o.order_id,
    o.customer_id,
    o.ordered_at,
    count(i.line_number) AS item_count,
    count_if(i.line_status = 'Delivered') AS delivered_count,
    count_if(i.line_status = 'Cancelled') AS cancelled_count,
    count_if(i.line_status = 'Pending') AS pending_count,
    max(i.delivered_at) AS last_delivered_at,
    max(i.cancelled_at) AS last_cancelled_at
  FROM workspace.interview_orders.orders o
  LEFT JOIN workspace.interview_orders.order_items i ON i.order_id = o.order_id
  GROUP BY o.order_id, o.customer_id, o.ordered_at
)
SELECT
  order_id,
  customer_id,
  ordered_at,
  item_count,
  CASE
    -- Check empty orders first: zero delivered/cancelled lines must not count as completion.
    WHEN item_count = 0 THEN 'Pending'
    -- Check all-cancelled orders before the mixed delivered/cancelled completion rule.
    WHEN cancelled_count = item_count THEN 'Cancelled'
    -- Every line is resolved; the preceding checks ensure at least one was delivered.
    WHEN delivered_count + cancelled_count = item_count THEN 'Completed'
    -- Ignore cancelled lines: all remaining active lines are still pending.
    WHEN pending_count + cancelled_count = item_count THEN 'Pending'
    -- A shipment is in transit, or some lines are delivered while others remain pending.
    ELSE 'InProgress'
  END AS order_status,
  CASE
    -- Only completed orders get a timestamp; empty and all-cancelled orders stay NULL.
    WHEN delivered_count > 0 AND delivered_count + cancelled_count = item_count
      -- The final resolving event may be a delivery or a later cancellation.
      -- GREATEST ignores NULL, so delivery-only orders use their last delivery time.
      THEN greatest(last_delivered_at, last_cancelled_at)
    -- With no ELSE, unfinished orders also return NULL.
  END AS completed_at
FROM item_summary;
