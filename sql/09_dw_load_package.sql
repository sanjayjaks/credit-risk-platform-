-- =====================================================================
-- 09_dw_load_package.sql
-- PKG_DW: loads the warehouse FROM the operational tables.
--     pkg_dw.run_dw_load;                         -- snapshots up to last month-end
--     pkg_dw.run_dw_load(DATE '2026-10-31');      -- or up to a chosen date
-- Order: dimensions first (facts need their keys), then facts.
-- Facts are fully rebuilt each run (simple and safe for a prototype;
-- a production system would load only new snapshots / new payments).
-- =====================================================================

CREATE OR REPLACE PACKAGE pkg_dw AS
    -- illustrative business rules (NOT a validated credit model)
    FUNCTION risk_category (p_credit_score NUMBER)  RETURN VARCHAR2 DETERMINISTIC;
    FUNCTION income_band   (p_annual_income NUMBER) RETURN VARCHAR2 DETERMINISTIC;
    FUNCTION date_key      (p_date DATE)            RETURN NUMBER   DETERMINISTIC;

    PROCEDURE load_dim_date (p_from DATE, p_to DATE);
    PROCEDURE load_dim_branch;
    PROCEDURE load_dim_loan_type;
    PROCEDURE load_dim_customer;          -- SCD Type 2
    PROCEDURE load_fact_payments;
    PROCEDURE load_fact_loan_performance (p_as_of DATE);
    PROCEDURE run_dw_load (p_as_of DATE DEFAULT LAST_DAY(ADD_MONTHS(TRUNC(SYSDATE), -1)));
END pkg_dw;
/

CREATE OR REPLACE PACKAGE BODY pkg_dw AS

    c_open_end   CONSTANT DATE := DATE '9999-12-31';   -- "still current"
    c_first_start CONSTANT DATE := DATE '1900-01-01';  -- first version is valid for all past dates

    FUNCTION risk_category (p_credit_score NUMBER) RETURN VARCHAR2 DETERMINISTIC IS
    BEGIN
        RETURN CASE WHEN p_credit_score IS NULL THEN 'UNRATED'
                    WHEN p_credit_score >= 750  THEN 'LOW'
                    WHEN p_credit_score >= 650  THEN 'MEDIUM'
                    ELSE 'HIGH' END;
    END risk_category;

    FUNCTION income_band (p_annual_income NUMBER) RETURN VARCHAR2 DETERMINISTIC IS
    BEGIN
        RETURN CASE WHEN p_annual_income IS NULL   THEN 'Unknown'
                    WHEN p_annual_income < 500000  THEN 'Below 5 L'
                    WHEN p_annual_income < 1000000 THEN '5-10 L'
                    WHEN p_annual_income < 2500000 THEN '10-25 L'
                    ELSE '25 L+' END;
    END income_band;

    FUNCTION date_key (p_date DATE) RETURN NUMBER DETERMINISTIC IS
    BEGIN
        RETURN TO_NUMBER(TO_CHAR(p_date, 'YYYYMMDD'));
    END date_key;

    ------------------------------------------------------------------
    PROCEDURE load_dim_date (p_from DATE, p_to DATE) IS
    BEGIN
        INSERT INTO dim_date (date_key, calendar_date, day, day_name, month, month_name, year_month,
                              quarter, year, financial_year, is_month_end)
        SELECT TO_NUMBER(TO_CHAR(d, 'YYYYMMDD')),
               d,
               EXTRACT(DAY FROM d),
               TO_CHAR(d, 'Dy', 'NLS_DATE_LANGUAGE=ENGLISH'),
               EXTRACT(MONTH FROM d),
               TO_CHAR(d, 'Mon', 'NLS_DATE_LANGUAGE=ENGLISH'),
               TO_CHAR(d, 'YYYY-MM'),
               TO_NUMBER(TO_CHAR(d, 'Q')),
               EXTRACT(YEAR FROM d),
               -- Indian financial year runs 1 April - 31 March
               CASE WHEN EXTRACT(MONTH FROM d) >= 4
                    THEN 'FY' || EXTRACT(YEAR FROM d)     || '-' || SUBSTR(TO_CHAR(EXTRACT(YEAR FROM d) + 1), 3, 2)
                    ELSE 'FY' || (EXTRACT(YEAR FROM d)-1) || '-' || SUBSTR(TO_CHAR(EXTRACT(YEAR FROM d)), 3, 2)
               END,
               CASE WHEN d = LAST_DAY(d) THEN 1 ELSE 0 END
        FROM  (SELECT TRUNC(p_from) + LEVEL - 1 AS d
               FROM   dual
               CONNECT BY LEVEL <= TRUNC(p_to) - TRUNC(p_from) + 1) days
        WHERE NOT EXISTS (SELECT 1 FROM dim_date x WHERE x.calendar_date = days.d);
    END load_dim_date;

    ------------------------------------------------------------------
    -- SCD Type 1: insert new branches, overwrite changed ones
    ------------------------------------------------------------------
    PROCEDURE load_dim_branch IS
    BEGIN
        MERGE INTO dim_branch d
        USING branch b ON (d.branch_id = b.branch_id)
        WHEN MATCHED THEN UPDATE SET
            d.branch_code = b.branch_code, d.branch_name = b.branch_name, d.city = b.city, d.state = b.state
        WHEN NOT MATCHED THEN INSERT (branch_id, branch_code, branch_name, city, state)
            VALUES (b.branch_id, b.branch_code, b.branch_name, b.city, b.state);
    END load_dim_branch;

    PROCEDURE load_dim_loan_type IS
    BEGIN
        MERGE INTO dim_loan_type d
        USING loan_type t ON (d.loan_type_id = t.loan_type_id)
        WHEN MATCHED THEN UPDATE SET d.loan_type_name = t.loan_type_name, d.description = t.description
        WHEN NOT MATCHED THEN INSERT (loan_type_id, loan_type_name, description)
            VALUES (t.loan_type_id, t.loan_type_name, t.description);
    END load_dim_loan_type;

    ------------------------------------------------------------------
    -- SCD Type 2 for customers
    --   tracked (history kept): city, state, employment_status, income_band, risk_category
    --   overwritten (Type 1):   customer_name
    ------------------------------------------------------------------
    PROCEDURE load_dim_customer IS
        v_today DATE := TRUNC(SYSDATE);
    BEGIN
        -- (a) Type 1: name corrections overwrite every version
        UPDATE dim_customer d
        SET    customer_name = (SELECT c.first_name || ' ' || c.last_name FROM customer c
                                WHERE c.customer_id = d.customer_id)
        WHERE  EXISTS (SELECT 1 FROM customer c
                       WHERE c.customer_id = d.customer_id
                       AND   c.first_name || ' ' || c.last_name <> d.customer_name);

        -- (b) a change made earlier TODAY: just correct today's version in place
        --     (avoids two versions with the same start date)
        MERGE INTO dim_customer d
        USING customer c
        ON (d.customer_id = c.customer_id AND d.is_current = 1 AND d.effective_start_date = v_today)
        WHEN MATCHED THEN UPDATE SET
            d.city = c.city, d.state = c.state, d.employment_status = c.employment_status,
            d.income_band = pkg_dw.income_band(c.annual_income),
            d.risk_category = pkg_dw.risk_category(c.credit_score);

        -- (c) Type 2: close the current version when a tracked attribute changed
        --     DECODE(a, b, 0, 1) = 1 is a NULL-safe "a is different from b"
        UPDATE dim_customer d
        SET    effective_end_date = v_today - 1,
               is_current         = 0
        WHERE  d.is_current = 1
        AND    d.effective_start_date < v_today
        AND    EXISTS (
                 SELECT 1 FROM customer c
                 WHERE  c.customer_id = d.customer_id
                 AND (   DECODE(c.city, d.city, 0, 1) = 1
                      OR DECODE(c.state, d.state, 0, 1) = 1
                      OR DECODE(c.employment_status, d.employment_status, 0, 1) = 1
                      OR pkg_dw.income_band(c.annual_income)   <> d.income_band
                      OR pkg_dw.risk_category(c.credit_score)  <> d.risk_category));

        -- (d) insert a current version for every customer that has none
        --     (brand-new customers, and the ones just closed in step c)
        INSERT INTO dim_customer (customer_id, customer_name, city, state, employment_status,
                                  income_band, risk_category, effective_start_date,
                                  effective_end_date, is_current)
        SELECT c.customer_id,
               c.first_name || ' ' || c.last_name,
               c.city, c.state, c.employment_status,
               pkg_dw.income_band(c.annual_income),
               pkg_dw.risk_category(c.credit_score),
               CASE WHEN EXISTS (SELECT 1 FROM dim_customer x WHERE x.customer_id = c.customer_id)
                    THEN v_today          -- a later version
                    ELSE c_first_start    -- first version covers all history
               END,
               c_open_end,
               1
        FROM   customer c
        WHERE  NOT EXISTS (SELECT 1 FROM dim_customer x
                           WHERE x.customer_id = c.customer_id AND x.is_current = 1);
    END load_dim_customer;

    ------------------------------------------------------------------
    -- TRANSACTION FACT: one row per payment received
    -- customer_key = the customer version that was valid ON the payment date
    ------------------------------------------------------------------
    PROCEDURE load_fact_payments IS
    BEGIN
        DELETE FROM fact_payments;

        INSERT INTO fact_payments (payment_id, loan_id, customer_key, branch_key, loan_type_key,
                                   payment_date_key, due_date_key, payment_amount,
                                   principal_component, interest_component, days_late,
                                   late_payment_flag, payment_count)
        SELECT p.payment_id,
               p.loan_id,
               dc.customer_key,
               db.branch_key,
               dt.loan_type_key,
               pkg_dw.date_key(p.payment_date),
               pkg_dw.date_key(p.due_date),
               p.payment_amount,
               p.principal_component,
               p.interest_component,
               GREATEST(p.payment_date - p.due_date, 0),
               CASE WHEN p.payment_date > p.due_date THEN 1 ELSE 0 END,
               1
        FROM   payment p
        JOIN   loan l           ON l.loan_id = p.loan_id
        JOIN   dim_customer dc  ON dc.customer_id = l.customer_id
                               AND p.payment_date BETWEEN dc.effective_start_date AND dc.effective_end_date
        JOIN   dim_branch db    ON db.branch_id = l.branch_id
        JOIN   dim_loan_type dt ON dt.loan_type_id = l.loan_type_id
        WHERE  p.payment_date IS NOT NULL;            -- only money actually received
    END load_fact_payments;

    ------------------------------------------------------------------
    -- SNAPSHOT FACT: one row per loan per month-end
    -- Everything is calculated "as of" the snapshot date from dated payments.
    ------------------------------------------------------------------
    PROCEDURE load_fact_loan_performance (p_as_of DATE) IS
    BEGIN
        DELETE FROM fact_loan_performance;

        INSERT INTO fact_loan_performance (loan_id, customer_key, branch_key, loan_type_key,
                                           snapshot_date_key, disbursement_date_key, principal_amount,
                                           outstanding_balance, overdue_amount, total_paid_amount,
                                           days_past_due, dpd_bucket, default_flag, loan_count)
        WITH snapshots AS (                                   -- all month-ends in range
            SELECT calendar_date AS snap
            FROM   dim_date
            WHERE  is_month_end = 1
            AND    calendar_date BETWEEN (SELECT MIN(disbursement_date) FROM loan) AND p_as_of
        ),
        loans_on_book AS (                                    -- which loans existed at each month-end
            SELECT s.snap, l.loan_id, l.customer_id, l.branch_id, l.loan_type_id,
                   l.principal_amount, l.disbursement_date
            FROM   snapshots s
            JOIN   loan l ON l.disbursement_date <= s.snap
                         AND (l.closed_date IS NULL OR l.closed_date > s.snap)
        ),
        as_of_figures AS (                                    -- payment position at each month-end
            SELECT b.snap, b.loan_id,
                   SUM(CASE WHEN p.payment_date <= b.snap THEN p.payment_amount      ELSE 0 END) AS total_paid,
                   SUM(CASE WHEN p.payment_date <= b.snap THEN p.principal_component ELSE 0 END) AS principal_paid,
                   -- due by the snapshot but not paid by the snapshot
                   SUM(CASE WHEN p.due_date <= b.snap
                             AND (p.payment_date IS NULL OR p.payment_date > b.snap)
                            THEN p.amount_due ELSE 0 END)                                      AS overdue,
                   MIN(CASE WHEN p.due_date <= b.snap
                             AND (p.payment_date IS NULL OR p.payment_date > b.snap)
                            THEN p.due_date END)                                               AS oldest_unpaid_due
            FROM   loans_on_book b
            LEFT JOIN payment p ON p.loan_id = b.loan_id
            GROUP  BY b.snap, b.loan_id
        )
        SELECT b.loan_id,
               dc.customer_key,
               db.branch_key,
               dt.loan_type_key,
               pkg_dw.date_key(b.snap),
               pkg_dw.date_key(b.disbursement_date),
               b.principal_amount,
               GREATEST(b.principal_amount - NVL(f.principal_paid, 0), 0)         AS outstanding_balance,
               NVL(f.overdue, 0)                                                  AS overdue_amount,
               NVL(f.total_paid, 0)                                               AS total_paid_amount,
               NVL(b.snap - f.oldest_unpaid_due, 0)                               AS days_past_due,
               CASE WHEN f.oldest_unpaid_due IS NULL            THEN 'Current'
                    WHEN b.snap - f.oldest_unpaid_due <= 30     THEN '1-30'
                    WHEN b.snap - f.oldest_unpaid_due <= 60     THEN '31-60'
                    WHEN b.snap - f.oldest_unpaid_due <= 90     THEN '61-90'
                    ELSE '90+' END                                                AS dpd_bucket,
               CASE WHEN b.snap - f.oldest_unpaid_due >= 90 THEN 1 ELSE 0 END     AS default_flag,
               1
        FROM   loans_on_book b
        JOIN   as_of_figures f  ON f.loan_id = b.loan_id AND f.snap = b.snap
        JOIN   dim_customer dc  ON dc.customer_id = b.customer_id
                               AND b.snap BETWEEN dc.effective_start_date AND dc.effective_end_date
        JOIN   dim_branch db    ON db.branch_id = b.branch_id
        JOIN   dim_loan_type dt ON dt.loan_type_id = b.loan_type_id;
    END load_fact_loan_performance;

    ------------------------------------------------------------------
    PROCEDURE run_dw_load (p_as_of DATE DEFAULT LAST_DAY(ADD_MONTHS(TRUNC(SYSDATE), -1))) IS
        v_from DATE;
        v_rows NUMBER;
        v_pay_rows NUMBER;
    BEGIN
        pkg_etl.log_msg(NULL, 'DW_START', 'Warehouse load started, snapshots up to ' || TO_CHAR(p_as_of, 'YYYY-MM-DD'));

        SELECT TRUNC(LEAST(NVL(MIN(application_date), SYSDATE), SYSDATE), 'YYYY')
        INTO   v_from FROM loan_application;
        load_dim_date(v_from, ADD_MONTHS(TRUNC(SYSDATE, 'YYYY'), 24) - 1);
        load_dim_branch;
        load_dim_loan_type;
        load_dim_customer;
        load_fact_payments;
        load_fact_loan_performance(p_as_of);
        COMMIT;

        SELECT COUNT(*) INTO v_rows     FROM fact_loan_performance;
        SELECT COUNT(*) INTO v_pay_rows FROM fact_payments;
        pkg_etl.log_msg(NULL, 'DW_END', 'Warehouse load finished: ' || v_rows || ' loan snapshot rows, ' ||
                        v_pay_rows || ' payment rows');
    EXCEPTION WHEN OTHERS THEN
        ROLLBACK;
        pkg_etl.log_msg(NULL, 'DW_FATAL', SQLERRM || ' ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 'ERROR');
        RAISE;
    END run_dw_load;

END pkg_dw;
/
