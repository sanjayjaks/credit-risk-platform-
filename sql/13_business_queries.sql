-- =====================================================================
-- 13_business_queries.sql
-- The 14 business questions. Each query says which layer it uses:
--   [OLTP] = current state, straight from the operational tables
--   [DW]   = history / trends, from the star schema
-- Techniques used: JOINs, GROUP BY, CTEs (WITH), CASE, date functions,
-- window functions (RANK, LAG, SUM OVER, ROW_NUMBER).
-- =====================================================================

-- Q1. How many customers are registered?                                  [OLTP]
SELECT COUNT(*) AS registered_customers FROM customer;

-- Q2. How many loan applications have been submitted (and in what status)? [OLTP]
SELECT application_status, COUNT(*) AS applications,
       SUM(COUNT(*)) OVER () AS total_applications            -- window total on every row
FROM   loan_application
GROUP  BY application_status
ORDER  BY applications DESC;

-- Q3. What is the overall loan approval rate?                             [OLTP]
--     Only DECIDED applications count (pending ones have no outcome yet).
SELECT COUNT(CASE WHEN application_status = 'APPROVED' THEN 1 END) AS approved,
       COUNT(CASE WHEN application_status = 'REJECTED' THEN 1 END) AS rejected,
       ROUND(100 * COUNT(CASE WHEN application_status = 'APPROVED' THEN 1 END)
             / NULLIF(COUNT(CASE WHEN application_status IN ('APPROVED','REJECTED') THEN 1 END), 0), 2)
             AS approval_rate_pct
FROM   loan_application;

-- Q4. What is the total loan amount disbursed?                            [OLTP]
SELECT COUNT(*) AS loans_disbursed, SUM(principal_amount) AS total_disbursed
FROM   loan;

-- Q5. What is the current outstanding loan balance?                       [OLTP]
SELECT loan_status, COUNT(*) AS loans, SUM(outstanding_balance) AS outstanding
FROM   loan
GROUP  BY ROLLUP (loan_status)                 -- ROLLUP adds a grand-total row (loan_status NULL)
ORDER  BY loan_status;

-- Q6. Which branches have the highest loan disbursement?                  [OLTP]
SELECT b.branch_name, b.city,
       COUNT(l.loan_id)        AS loans,
       SUM(l.principal_amount) AS disbursed,
       RANK() OVER (ORDER BY SUM(l.principal_amount) DESC) AS disbursement_rank
FROM   branch b
LEFT JOIN loan l ON l.branch_id = b.branch_id
GROUP  BY b.branch_name, b.city
ORDER  BY disbursement_rank;

-- Q7. Which loan categories have the highest demand?                      [OLTP]
--     Demand = applications (not just approvals).
SELECT t.loan_type_name,
       COUNT(a.application_id)                                        AS applications,
       COUNT(CASE WHEN a.application_status = 'APPROVED' THEN 1 END)  AS approved,
       SUM(a.requested_amount)                                        AS amount_requested,
       ROUND(100 * RATIO_TO_REPORT(COUNT(a.application_id)) OVER (), 1) AS share_of_demand_pct
FROM   loan_type t
LEFT JOIN loan_application a ON a.loan_type_id = t.loan_type_id
GROUP  BY t.loan_type_name
ORDER  BY applications DESC;

-- Q8. How much repayment has been collected?                              [OLTP]
SELECT SUM(payment_amount)      AS total_collected,
       SUM(CASE WHEN payment_status <> 'MISSED' THEN principal_component END) AS principal_collected,
       SUM(CASE WHEN payment_status <> 'MISSED' THEN interest_component  END) AS interest_collected
FROM   payment;

-- Q9. Which loans have overdue payments (as of today)?                    [OLTP]
WITH overdue AS (
    SELECT loan_id,
           COUNT(*)        AS missed_instalments,
           SUM(amount_due) AS overdue_amount,
           MIN(due_date)   AS oldest_missed_due
    FROM   payment
    WHERE  payment_status = 'MISSED'
    GROUP  BY loan_id
)
SELECT l.loan_id, c.first_name || ' ' || c.last_name AS customer, t.loan_type_name, b.branch_name,
       o.missed_instalments, o.overdue_amount,
       TRUNC(SYSDATE) - o.oldest_missed_due AS days_past_due,
       l.loan_status
FROM   overdue o
JOIN   loan l      ON l.loan_id = o.loan_id
JOIN   customer c  ON c.customer_id = l.customer_id
JOIN   loan_type t ON t.loan_type_id = l.loan_type_id
JOIN   branch b    ON b.branch_id = l.branch_id
ORDER  BY days_past_due DESC;

-- Q10. How many customers are classified as high risk?                    [DW]
--      (illustrative rule: credit score < 650 = HIGH, 650-749 = MEDIUM, 750+ = LOW)
SELECT risk_category, COUNT(*) AS customers
FROM   dim_customer
WHERE  is_current = 1                          -- only the latest version of each customer
GROUP  BY risk_category
ORDER  BY CASE risk_category WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 WHEN 'LOW' THEN 3 ELSE 4 END;

-- Q11. What is the monthly repayment trend?                               [DW]
SELECT year_month, payments_received, amount_collected, on_time_pct,
       amount_collected - LAG(amount_collected) OVER (ORDER BY year_month) AS change_vs_prev_month,
       SUM(amount_collected) OVER (ORDER BY year_month)                    AS cumulative_collected
FROM   vw_collections_monthly
ORDER  BY year_month;

-- Q12. What is the default rate? (latest month-end, and the trend)        [DW]
SELECT year_month, active_loans, defaulted_loans, default_rate_pct, par30_pct
FROM   vw_portfolio_monthly
ORDER  BY snapshot_date;

-- Q13. Which customer segments have higher overdue amounts?               [DW]
--      Latest snapshot; the customer version that was valid at that date.
WITH latest AS (
    SELECT MAX(snapshot_date_key) AS k FROM fact_loan_performance
)
SELECT c.risk_category, c.income_band,
       SUM(f.loan_count)          AS loans,
       SUM(f.outstanding_balance) AS outstanding,
       SUM(f.overdue_amount)      AS overdue,
       ROUND(100 * SUM(f.overdue_amount) / NULLIF(SUM(f.outstanding_balance), 0), 2) AS overdue_pct,
       DENSE_RANK() OVER (ORDER BY SUM(f.overdue_amount) DESC) AS overdue_rank
FROM   fact_loan_performance f
JOIN   latest                ON f.snapshot_date_key = latest.k
JOIN   dim_customer c        ON c.customer_key = f.customer_key
GROUP  BY c.risk_category, c.income_band
ORDER  BY overdue DESC;

-- Q14. How has the loan portfolio changed over time?                      [DW]
SELECT year_month, financial_year, active_loans, outstanding_balance, overdue_amount,
       outstanding_balance - LAG(outstanding_balance) OVER (ORDER BY snapshot_date) AS mom_change,
       ROUND(100 * (outstanding_balance / NULLIF(LAG(outstanding_balance, 12) OVER (ORDER BY snapshot_date), 0) - 1), 1)
             AS yoy_growth_pct
FROM   vw_portfolio_monthly
ORDER  BY snapshot_date;

-- BONUS. Top 3 riskiest loans per branch at the latest snapshot (ROW_NUMBER per group)
WITH ranked AS (
    SELECT b.branch_name, f.loan_id, f.days_past_due, f.overdue_amount,
           ROW_NUMBER() OVER (PARTITION BY b.branch_name ORDER BY f.days_past_due DESC, f.overdue_amount DESC) AS rn
    FROM   fact_loan_performance f
    JOIN   dim_branch b ON b.branch_key = f.branch_key
    WHERE  f.snapshot_date_key = (SELECT MAX(snapshot_date_key) FROM fact_loan_performance)
    AND    f.days_past_due > 0
)
SELECT branch_name, loan_id, days_past_due, overdue_amount
FROM   ranked WHERE rn <= 3
ORDER  BY branch_name, rn;
