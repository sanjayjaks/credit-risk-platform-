-- =====================================================================
-- 11_powerbi_views.sql
-- Reporting views on top of the star schema.
-- Power BI can import the star tables directly (recommended: DIM_* + FACT_*
-- with relationships) and/or these pre-aggregated views for quick visuals.
-- =====================================================================

-- Portfolio trend: one row per month-end (answers "how has the portfolio changed over time?")
CREATE OR REPLACE VIEW vw_portfolio_monthly AS
SELECT d.calendar_date                                     AS snapshot_date,
       d.year_month,
       d.financial_year,
       SUM(f.loan_count)                                   AS active_loans,
       SUM(f.principal_amount)                             AS principal_on_book,
       SUM(f.outstanding_balance)                          AS outstanding_balance,
       SUM(f.overdue_amount)                               AS overdue_amount,
       SUM(f.default_flag)                                 AS defaulted_loans,
       ROUND(100 * SUM(f.default_flag) / NULLIF(SUM(f.loan_count), 0), 2)            AS default_rate_pct,
       -- PAR30 = share of the outstanding book that is more than 30 days past due
       ROUND(100 * SUM(CASE WHEN f.days_past_due > 30 THEN f.outstanding_balance ELSE 0 END)
                 / NULLIF(SUM(f.outstanding_balance), 0), 2)                        AS par30_pct
FROM   fact_loan_performance f
JOIN   dim_date d ON d.date_key = f.snapshot_date_key
GROUP  BY d.calendar_date, d.year_month, d.financial_year;

-- Latest snapshot by branch and loan type
CREATE OR REPLACE VIEW vw_portfolio_latest_by_branch AS
SELECT b.branch_name, b.city, t.loan_type_name,
       SUM(f.loan_count)          AS loans,
       SUM(f.principal_amount)    AS principal_disbursed,
       SUM(f.outstanding_balance) AS outstanding_balance,
       SUM(f.overdue_amount)      AS overdue_amount,
       SUM(f.default_flag)        AS defaulted_loans
FROM   fact_loan_performance f
JOIN   dim_branch b    ON b.branch_key = f.branch_key
JOIN   dim_loan_type t ON t.loan_type_key = f.loan_type_key
WHERE  f.snapshot_date_key = (SELECT MAX(snapshot_date_key) FROM fact_loan_performance)
GROUP  BY b.branch_name, b.city, t.loan_type_name;

-- Latest snapshot by customer segment (risk category x income band x employment)
CREATE OR REPLACE VIEW vw_risk_segments_latest AS
SELECT c.risk_category, c.income_band, c.employment_status,
       COUNT(DISTINCT c.customer_id)  AS customers,
       SUM(f.loan_count)              AS loans,
       SUM(f.outstanding_balance)     AS outstanding_balance,
       SUM(f.overdue_amount)          AS overdue_amount,
       ROUND(100 * SUM(f.overdue_amount) / NULLIF(SUM(f.outstanding_balance), 0), 2) AS overdue_to_outstanding_pct
FROM   fact_loan_performance f
JOIN   dim_customer c ON c.customer_key = f.customer_key
WHERE  f.snapshot_date_key = (SELECT MAX(snapshot_date_key) FROM fact_loan_performance)
GROUP  BY c.risk_category, c.income_band, c.employment_status;

-- Monthly collections (answers "what is the monthly repayment trend?")
CREATE OR REPLACE VIEW vw_collections_monthly AS
SELECT d.year_month,
       d.financial_year,
       SUM(p.payment_count)        AS payments_received,
       SUM(p.payment_amount)       AS amount_collected,
       SUM(p.principal_component)  AS principal_collected,
       SUM(p.interest_component)   AS interest_collected,
       SUM(p.late_payment_flag)    AS late_payments,
       ROUND(100 * (1 - SUM(p.late_payment_flag) / NULLIF(SUM(p.payment_count), 0)), 2) AS on_time_pct
FROM   fact_payments p
JOIN   dim_date d ON d.date_key = p.payment_date_key
GROUP  BY d.year_month, d.financial_year;
