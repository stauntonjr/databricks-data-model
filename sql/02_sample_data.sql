-- Databricks notebook source
-- MAGIC %md
-- MAGIC # Synthetic sample data
-- MAGIC
-- MAGIC **Resets the synthetic rows** in `workspace.interview_orders`. Requires `01_schema.sql`.
-- MAGIC
-- MAGIC Dates are relative to the run date. Rerun the full job after the month changes.

-- COMMAND ----------
SET TIME ZONE 'UTC';

-- COMMAND ----------
-- Replace each table independently so reruns do not append duplicate fixtures.
-- The four writes are not one transaction; run the full job to restore a coherent set.
INSERT OVERWRITE workspace.interview_orders.customers VALUES
  (1, 'Alex Chen'), (2, 'Sam Rivera'), (3, 'Morgan Patel');

-- COMMAND ----------
-- Catalog prices deliberately differ from the historical prices on order lines.
INSERT OVERWRITE workspace.interview_orders.products VALUES
  (1, 'Sourdough loaf', 'Bread', 7.50),
  (2, 'Butter croissant', 'Pastry', 4.50),
  (3, 'Blueberry muffin', 'Pastry', 3.75);

-- COMMAND ----------
-- Offsets are measured from the first day of a month:
-- month_offset = -1 means last month; 0 means this month.
-- day_offset is zero-based. Add seconds last to place records exactly on either
-- side of midnight without depending on the number of days in the month.
-- These are analytical fixtures, not a simulation of real delivery durations.
INSERT OVERWRITE workspace.interview_orders.orders (order_id, customer_id, ordered_at)
WITH sample_orders(order_id, customer_id, month_offset, day_offset, second_offset) AS (
  VALUES
    (101, 1, -1,  0,  0),  -- Exactly at the start of last month
    (102, 2, -1,  5,  0),
    (103, 1,  0,  0, -1),  -- Last second of last month
    (104, 3, -1, 10,  0),
    (105, 2, -1, 12,  0),
    (106, 1,  0,  0,  0),  -- Exactly at the start of this month
    (107, 3, -1,  0, -1),  -- One second before last month
    (108, 2, -1, 15,  0),
    (109, 3, -1, 13,  0),
    (110, 1,  0,  0, 10),
    (111, 2,  0,  0, 20),
    (112, 3,  0,  0, 30)
)
SELECT
  order_id,
  customer_id,
  timestampadd(SECOND, second_offset,
    timestampadd(DAY, day_offset,
      CAST(add_months(trunc(current_date(), 'MM'), month_offset) AS TIMESTAMP_NTZ)
    )
  ) AS ordered_at
FROM sample_orders;

-- COMMAND ----------
-- 108 intentionally has no lines, exercising the empty-order LEFT JOIN case.
-- 103 and 110 resolve through delivery plus cancellation, in opposite time orders.
-- 111 and 112 combine cancellation with Pending and Shipped respectively.
-- The 100-unit muffin lines expose missing cancellation/date filters; the smaller
-- bread and pastry quantities create the last-month tie checked in validation.
-- Positional insertion follows the column order declared in 01_schema.sql.
INSERT OVERWRITE workspace.interview_orders.order_items
WITH lines(order_id, line_number, product_id, quantity, unit_price, line_status) AS (
  VALUES
    (101, 1, 1, 3, 7.00, 'Delivered'),
    (101, 2, 2, 2, 4.00, 'Delivered'),
    (102, 1, 1, 4, 7.00, 'Shipped'),
    (102, 2, 2, 3, 4.00, 'Pending'),
    (103, 1, 1, 3, 7.00, 'Delivered'),
    (103, 2, 2, 5, 4.00, 'Cancelled'),
    (104, 1, 2, 5, 4.00, 'Delivered'),
    (104, 2, 3, 4, 3.50, 'Delivered'),
    (105, 1, 3, 100, 3.50, 'Cancelled'),
    (106, 1, 3, 100, 3.50, 'Delivered'),
    (107, 1, 3, 100, 3.50, 'Delivered'),
    (109, 1, 3, 1, 3.50, 'Pending'),
    (110, 1, 1, 2, 7.00, 'Delivered'),
    (110, 2, 2, 3, 4.00, 'Cancelled'),
    (111, 1, 1, 2, 7.00, 'Pending'),
    (111, 2, 2, 3, 4.00, 'Cancelled'),
    (112, 1, 1, 2, 7.00, 'Shipped'),
    (112, 2, 2, 3, 4.00, 'Cancelled')
)
-- Derive events from each header so all fulfillment events occur after placement.
-- Missing ELSE branches produce NULL timestamps for nonmatching statuses.
-- For 107, +1 second crosses into last month; for 103 it crosses into this month,
-- deliberately making delivery-window membership differ from order-window membership.
SELECT l.*,
  CASE WHEN l.line_status = 'Delivered' THEN
    CASE WHEN l.order_id = 110 THEN o.ordered_at + INTERVAL 2 SECONDS
      ELSE o.ordered_at + INTERVAL 1 SECOND END
  END AS delivered_at,
  CASE WHEN l.line_status = 'Cancelled' THEN
    CASE WHEN l.order_id = 110 THEN o.ordered_at + INTERVAL 1 SECOND
      ELSE o.ordered_at + INTERVAL 2 SECONDS END
  END AS cancelled_at
FROM lines l JOIN workspace.interview_orders.orders o USING (order_id);
