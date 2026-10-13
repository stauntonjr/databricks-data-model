-- Databricks notebook source
-- MAGIC %md
-- MAGIC # Validation
-- MAGIC
-- MAGIC Run after schema, sample data, and reporting objects. These ten assertions check the synthetic fixtures, keys, references, order completion, date windows, and sales results.
-- MAGIC
-- MAGIC A successful assert_true returns NULL; a failed assertion stops the job.
-- MAGIC The expected sales totals and order states below belong to the synthetic records in `02_sample_data.sql`. If those records change intentionally, review their expected results too. The window tests use fixed dates so they remain reproducible.

-- COMMAND ----------
SET TIME ZONE 'UTC';

-- COMMAND ----------
-- Run against the complete fixture set, not an arbitrary production dataset.
-- The checks assert selected examples and invariants; they are not exhaustive proofs.
-- Invalid function arguments are rejected by the functions but are not invoked here,
-- because their expected errors would stop this success-path validation job.
-- CHECK 1: calendar months and 30-day windows are different business definitions.
-- January must reach December of the previous year. A calendar February spans
-- 29 days in 2024 and 28 in 2025; neither should be approximated as 30 days.
-- The rolling cases instead subtract exactly 30 days, including across New Year
-- and leap day. LATERAL evaluates the function for each supplied test case.
-- Expect five returned rows and five matching start/end pairs.
WITH cases(window_kind, as_of_date, expected_start, expected_end) AS (
  VALUES
    ('last_calendar_month', DATE'2027-01-15', DATE'2026-12-01', DATE'2027-01-01'),
    ('last_calendar_month', DATE'2024-03-01', DATE'2024-02-01', DATE'2024-03-01'),
    ('last_calendar_month', DATE'2025-03-31', DATE'2025-02-01', DATE'2025-03-01'),
    ('previous_30_days', DATE'2027-01-15', DATE'2026-12-16', DATE'2027-01-15'),
    ('previous_30_days', DATE'2024-03-01', DATE'2024-01-31', DATE'2024-03-01')
)
SELECT assert_true(count(*) = 5 AND count_if(
  b.window_start = CAST(c.expected_start AS TIMESTAMP_NTZ)
  AND b.window_end = CAST(c.expected_end AS TIMESTAMP_NTZ)
) = 5, 'Incorrect reporting-window boundaries') AS window_check
FROM cases c,
LATERAL workspace.interview_orders.reporting_window(c.window_kind, c.as_of_date) b;

-- COMMAND ----------
-- CHECK 2: protect the inclusive-start / exclusive-end filtering convention.
-- For this window, Dec 16 at midnight is included, Jan 15 at midnight is not.
-- Events 2 and 3 must survive; event 1 is too early and event 4 is at the end.
-- This avoids counting midnight twice in adjacent windows. This checks the
-- window function plus the predicate shown here; sales totals below separately
-- exercise filtering inside the reporting functions.
WITH events(event_id, occurred_at) AS (
  VALUES (1, TIMESTAMP_NTZ'2026-12-15 23:59:59'),
    (2, TIMESTAMP_NTZ'2026-12-16 00:00:00'),
    (3, TIMESTAMP_NTZ'2027-01-14 23:59:59'),
    (4, TIMESTAMP_NTZ'2027-01-15 00:00:00')
)
SELECT assert_true(count(*) = 2 AND count_if(event_id IN (2, 3)) = 2,
  'Reporting window must be start-inclusive and end-exclusive') AS window_edges_check
FROM events e
CROSS JOIN workspace.interview_orders.reporting_window('previous_30_days', DATE'2027-01-15') b
WHERE e.occurred_at >= b.window_start AND e.occurred_at < b.window_end;

-- COMMAND ----------
-- CHECK 3: the rolling sales function must use the selected window and sum units.
-- Anchor on day four so the same fixture expectations hold after months of
-- 28, 29, 30, or 31 days: include orders 104, 109, 106; exclude old order 107.
-- Muffins total 4 delivered + 1 pending + 100 delivered = 105 units.
-- Order 105's 100 cancelled muffins must not count. Exactly one winner is expected.
-- This also distinguishes rolling results from the last-calendar-month winners.
SELECT assert_true(count(*) = 1 AND count_if(product_id = 3 AND units_sold = 105) = 1,
  'Expected muffin to lead rolling sales at 105 units') AS rolling_sales_check
FROM workspace.interview_orders.most_sold_products(
  'previous_30_days', date_add(trunc(current_date(), 'MM'), 3)
);

-- COMMAND ----------
-- CHECK 4: delivered units exclude pending units even when their orders qualify.
-- In the same rolling window, muffins total 4 (order 104) + 100 (order 106) = 104.
-- Order 109's one pending muffin explains the difference from the 105 sold units.
-- Including pending/cancelled lines or applying the wrong window changes this result.
SELECT assert_true(count(*) = 1 AND count_if(product_id = 3 AND units_delivered = 104) = 1,
  'Expected muffin to lead rolling deliveries at 104 units') AS rolling_delivery_check
FROM workspace.interview_orders.most_delivered_products(
  'previous_30_days', date_add(trunc(current_date(), 'MM'), 3)
);

-- COMMAND ----------
-- CHECK 5: sum quantities, exclude cancelled lines, and return every first-place tie.
-- Last month's sourdough: 3 (101) + 4 (102) + 3 (103) = 10 units.
-- Last month's croissants: 2 (101) + 3 (102) + 5 (104) = 10 units.
-- Both product IDs must appear. LIMIT 1 would lose a tie; COUNT(*) would count
-- lines instead of units. The 100-muffin lines in orders 105 (cancelled),
-- 106 (this month), and 107 (before last month) expose missing filters.
SELECT assert_true(
  count(*) = 2 AND count_if(product_id IN (1, 2) AND units_sold = 10) = 2,
  'Expected sourdough and croissant tied at 10 units'
) AS sales_check
FROM workspace.interview_orders.most_sold_last_month;

-- COMMAND ----------
-- CHECK 6: delivery reporting must filter delivered_at rather than ordered_at.
-- Order 107 was placed one second before last month but delivered exactly at
-- its start: those 100 muffins count here, alongside order 104's 4 muffins.
-- Order 106's delivery is this month and order 105 was cancelled, so neither counts.
-- Expect muffin alone at 104 units; using the order-date filter would lose order 107.
SELECT assert_true(
  count(*) = 1 AND count_if(product_id = 3 AND units_delivered = 104) = 1,
  'Expected muffin to lead delivered units at 104'
) AS delivery_check
FROM workspace.interview_orders.most_delivered_last_month;

-- COMMAND ----------
-- CHECK 7: verify CASE precedence and representative combinations of line states.
-- 101/104/106/107: all delivered -> Completed. 103/110: delivered + cancelled -> Completed.
-- 105: all cancelled -> Cancelled, not Completed. 108: no items -> Pending,
-- not Completed merely because delivered_count and item_count are both zero.
-- 109: all pending -> Pending. 111: pending + cancelled -> Pending.
-- 102: shipped + pending, and 112: shipped + cancelled -> InProgress.
-- The FULL OUTER JOIN exposes missing/extra order IDs as well as wrong statuses.
-- Only Completed orders may have completed_at. Expect zero violating rows.
WITH expected(order_id, order_status) AS (
  VALUES (101, 'Completed'), (102, 'InProgress'), (103, 'Completed'),
    (104, 'Completed'), (105, 'Cancelled'), (106, 'Completed'),
    (107, 'Completed'), (108, 'Pending'), (109, 'Pending'),
    (110, 'Completed'), (111, 'Pending'), (112, 'InProgress')
)
SELECT assert_true(count(*) = 0, 'Order status mismatch') AS status_check
FROM expected e FULL OUTER JOIN workspace.interview_orders.order_status a
  ON e.order_id = a.order_id
WHERE e.order_id IS NULL OR a.order_id IS NULL OR e.order_status <> a.order_status
  OR (a.order_status = 'Completed' AND a.completed_at IS NULL)
  OR (a.order_status <> 'Completed' AND a.completed_at IS NOT NULL);

-- COMMAND ----------
-- CHECK 8: completion is the final resolving event, which is not always a delivery.
-- For 103, delivery is at +1 second but cancellation at +2: completion must be +2.
-- For 110, cancellation is at +1 but delivery at +2: completion must also be +2.
-- Delivery-only orders finish at +1, even though their cancellation timestamp is NULL.
-- This catches using only delivery time, only cancellation time, or the earlier event.
-- LEFT JOIN exposes missing orders; null-safe equality (<=>) makes an absent
-- completion timestamp fail rather than disappear under SQL's NULL comparison rules.
WITH expected(order_id, seconds_after_order) AS (
  VALUES (101, 1), (103, 2), (104, 1), (106, 1), (107, 1), (110, 2)
)
SELECT assert_true(count(*) = 0, 'Incorrect completion timestamp') AS completion_time_check
FROM expected e
LEFT JOIN workspace.interview_orders.order_status a ON a.order_id = e.order_id
WHERE a.order_id IS NULL
  OR NOT (a.completed_at <=> timestampadd(SECOND, e.seconds_after_order, a.ordered_at));

-- COMMAND ----------
-- CHECK 9: declared primary keys describe the model but do not enforce uniqueness.
-- Duplicate customer/product/order IDs can multiply join results and inflate totals.
-- A line is unique by (order_id, line_number); a product may occur on multiple lines.
-- Each GROUP BY returns only duplicate keys; UNION ALL combines those violations.
-- Expect no duplicate groups in any table. Key NULLs are separately blocked by NOT NULL.
WITH duplicates AS (
  SELECT 'customers' AS entity FROM workspace.interview_orders.customers
    GROUP BY customer_id HAVING count(*) > 1
  UNION ALL SELECT 'products' FROM workspace.interview_orders.products
    GROUP BY product_id HAVING count(*) > 1
  UNION ALL SELECT 'orders' FROM workspace.interview_orders.orders
    GROUP BY order_id HAVING count(*) > 1
  UNION ALL SELECT 'order_items' FROM workspace.interview_orders.order_items
    GROUP BY order_id, line_number HAVING count(*) > 1
)
SELECT assert_true(count(*) = 0, 'Duplicate primary key') AS key_check FROM duplicates;

-- COMMAND ----------
-- CHECK 10: reject orphan references and impossible event timing or prices.
-- Foreign keys are informational too. LEFT ANTI JOIN returns rows whose parent
-- does not exist: an order without a customer, or an item without an order/product.
-- Inner joins then check that deliveries/cancellations never precede order placement.
-- NULL event times are appropriate for other states; the valid_item table constraint
-- separately enforces that Delivered/Cancelled lines have their respective timestamps.
-- The final branch checks the product's current price; valid_item already checks
-- the item's purchase price. UNION ALL collects violations; expect zero rows overall.
WITH violations AS (
  SELECT 'customer reference' AS reason FROM workspace.interview_orders.orders o
  LEFT ANTI JOIN workspace.interview_orders.customers c ON c.customer_id = o.customer_id
  UNION ALL
  SELECT 'order reference' FROM workspace.interview_orders.order_items i
  LEFT ANTI JOIN workspace.interview_orders.orders o ON o.order_id = i.order_id
  UNION ALL
  SELECT 'product reference' FROM workspace.interview_orders.order_items i
  LEFT ANTI JOIN workspace.interview_orders.products p ON p.product_id = i.product_id
  UNION ALL
  SELECT 'delivery before order' FROM workspace.interview_orders.order_items i
  JOIN workspace.interview_orders.orders o ON o.order_id = i.order_id
  WHERE i.delivered_at < o.ordered_at
  UNION ALL
  SELECT 'cancellation before order' FROM workspace.interview_orders.order_items i
  JOIN workspace.interview_orders.orders o ON o.order_id = i.order_id
  WHERE i.cancelled_at < o.ordered_at
  UNION ALL
  SELECT 'negative product price' FROM workspace.interview_orders.products
  WHERE current_unit_price < 0
)
SELECT assert_true(count(*) = 0, 'Invalid reference, price, or chronology') AS integrity_check
FROM violations;
