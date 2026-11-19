-- =====================================================================
-- 07_etl_package.sql
-- PKG_ETL: moves data  STAGING  ->  OPERATIONAL (OLTP)
--
-- One call does the whole run:
--     v_batch := pkg_etl.run_etl('CSV_FILES');
--
-- Steps inside a run
--   1. Create an ETL_BATCH row (status RUNNING)
--   2. "Claim" all NEW staging rows by stamping them with this batch_id
--   3. For each staging row: validate -> REJECT (log reason) or LOAD (insert/update OLTP)
--      Order matters: customers first, then loans (need customers), then payments (need loans)
--   4. Refresh loan statuses (DEFAULTED rule)
--   5. Write totals + final status to ETL_BATCH
-- Every step writes to ETL_LOG. Logging uses an AUTONOMOUS TRANSACTION so the
-- log survives even if the run fails and is rolled back.
-- =====================================================================

CREATE OR REPLACE PACKAGE pkg_etl AS
    -- returns the new batch_id
    FUNCTION  run_etl (p_source_name VARCHAR2 DEFAULT 'CSV_FILES') RETURN NUMBER;
    -- same thing as a procedure, handy for an APEX Automation / DBMS_SCHEDULER job
    PROCEDURE run_etl_job (p_source_name VARCHAR2 DEFAULT 'CSV_FILES');

    -- helpers, public so you can test them:  SELECT pkg_etl.to_num('12.5') FROM dual;
    FUNCTION to_num  (p_text VARCHAR2) RETURN NUMBER;   -- NULL if not a valid number
    FUNCTION to_dt   (p_text VARCHAR2) RETURN DATE;     -- NULL if not a valid YYYY-MM-DD date
    PROCEDURE log_msg (p_batch_id NUMBER, p_step VARCHAR2, p_message VARCHAR2, p_level VARCHAR2 DEFAULT 'INFO');
END pkg_etl;
/

CREATE OR REPLACE PACKAGE BODY pkg_etl AS

    -- counters for the current run
    g_total     NUMBER;
    g_success   NUMBER;
    g_rejected  NUMBER;

    ------------------------------------------------------------------
    -- Helpers
    ------------------------------------------------------------------
    FUNCTION to_num (p_text VARCHAR2) RETURN NUMBER IS
    BEGIN
        RETURN TO_NUMBER(TRIM(p_text));
    EXCEPTION WHEN OTHERS THEN
        RETURN NULL;
    END to_num;

    FUNCTION to_dt (p_text VARCHAR2) RETURN DATE IS
    BEGIN
        RETURN TO_DATE(TRIM(p_text), 'FXYYYY-MM-DD');     -- FX = format must match exactly
    EXCEPTION WHEN OTHERS THEN
        RETURN NULL;                                      -- e.g. '1990-02-31' or '12/05/2026'
    END to_dt;

    PROCEDURE log_msg (p_batch_id NUMBER, p_step VARCHAR2, p_message VARCHAR2,
                       p_level VARCHAR2 DEFAULT 'INFO') IS
        PRAGMA AUTONOMOUS_TRANSACTION;                    -- commits independently of the ETL
    BEGIN
        INSERT INTO etl_log (batch_id, log_level, step_name, message)
        VALUES (p_batch_id, p_level, p_step, SUBSTR(p_message, 1, 4000));
        COMMIT;
    END log_msg;

    -- adds a reason to the list of problems found for one row
    PROCEDURE add_reason (p_reasons IN OUT VARCHAR2, p_reason VARCHAR2) IS
    BEGIN
        p_reasons := CASE WHEN p_reasons IS NULL THEN p_reason ELSE p_reasons || '; ' || p_reason END;
    END add_reason;

    PROCEDURE reject (p_batch_id NUMBER, p_table VARCHAR2, p_record_id VARCHAR2,
                      p_reason VARCHAR2, p_raw VARCHAR2) IS
    BEGIN
        INSERT INTO etl_rejected_record (batch_id, source_table, source_record_id, rejection_reason, raw_record)
        VALUES (p_batch_id, p_table, p_record_id, SUBSTR(p_reason, 1, 400), SUBSTR(p_raw, 1, 4000));
        g_rejected := g_rejected + 1;
    END reject;

    ------------------------------------------------------------------
    -- CUSTOMERS
    ------------------------------------------------------------------
    PROCEDURE process_customers (p_batch_id NUMBER) IS
        v_reasons  VARCHAR2(4000);
        v_income   NUMBER;
        v_score    NUMBER;
        v_dob      DATE;
        v_gender   VARCHAR2(1);
        v_emp      VARCHAR2(50);
        v_cnt      NUMBER;
        v_raw      VARCHAR2(4000);
    BEGIN
        FOR r IN (
            SELECT s.*,
                   ROW_NUMBER() OVER (PARTITION BY UPPER(TRIM(s.source_customer_id))
                                      ORDER BY s.staging_customer_id) AS dup_rank
            FROM   stg_customers s
            WHERE  s.batch_id = p_batch_id AND s.record_status = 'NEW'
            ORDER  BY s.staging_customer_id
        ) LOOP
            g_total   := g_total + 1;
            v_reasons := NULL;
            v_raw := 'id=' || r.source_customer_id || '|name=' || r.first_name || ' ' || r.last_name ||
                     '|email=' || r.email || '|income=' || r.annual_income || '|score=' || r.credit_score ||
                     '|dob=' || r.date_of_birth;

            -- 1. mandatory fields
            IF TRIM(r.source_customer_id) IS NULL THEN add_reason(v_reasons, 'Missing source_customer_id'); END IF;
            IF TRIM(r.first_name) IS NULL OR TRIM(r.last_name) IS NULL THEN add_reason(v_reasons, 'Missing name'); END IF;
            IF TRIM(r.email) IS NULL THEN
                add_reason(v_reasons, 'Missing email');
            ELSIF NOT REGEXP_LIKE(TRIM(r.email), '^[^@ ]+@[^@ ]+\.[^@ ]+$') THEN
                add_reason(v_reasons, 'Invalid email format');
            ELSE
                -- email must not belong to a DIFFERENT customer (email is UNIQUE in CUSTOMER)
                SELECT COUNT(*) INTO v_cnt FROM customer
                WHERE  LOWER(email) = LOWER(TRIM(r.email))
                AND    NVL(source_customer_ref, '~') <> TRIM(r.source_customer_id);
                IF v_cnt > 0 THEN add_reason(v_reasons, 'Email already used by another customer'); END IF;
            END IF;

            -- 2. duplicates inside this file
            IF r.dup_rank > 1 THEN add_reason(v_reasons, 'Duplicate source_customer_id in this batch'); END IF;

            -- 3. invalid numbers / dates / codes
            v_income := to_num(r.annual_income);
            IF r.annual_income IS NOT NULL AND (v_income IS NULL OR v_income < 0) THEN
                add_reason(v_reasons, 'Invalid annual_income: ' || r.annual_income);
            END IF;

            v_score := to_num(r.credit_score);
            IF r.credit_score IS NOT NULL AND (v_score IS NULL OR v_score NOT BETWEEN 300 AND 900
                                               OR v_score <> TRUNC(v_score)) THEN
                add_reason(v_reasons, 'Credit score must be a whole number 300-900, got ' || r.credit_score);
            END IF;

            v_dob := to_dt(r.date_of_birth);
            IF r.date_of_birth IS NOT NULL AND (v_dob IS NULL OR v_dob > ADD_MONTHS(TRUNC(SYSDATE), -12 * 18)) THEN
                add_reason(v_reasons, 'Invalid date_of_birth (must be YYYY-MM-DD, age 18+): ' || r.date_of_birth);
            END IF;

            v_gender := CASE UPPER(SUBSTR(TRIM(r.gender), 1, 1)) WHEN 'M' THEN 'M' WHEN 'F' THEN 'F' WHEN 'O' THEN 'O' END;
            IF r.gender IS NOT NULL AND v_gender IS NULL THEN add_reason(v_reasons, 'Invalid gender'); END IF;

            v_emp := UPPER(REPLACE(TRIM(r.employment_status), ' ', '_'));
            IF v_emp IS NOT NULL AND v_emp NOT IN
               ('SALARIED','SELF_EMPLOYED','BUSINESS_OWNER','STUDENT','RETIRED','UNEMPLOYED') THEN
                add_reason(v_reasons, 'Unknown employment_status: ' || r.employment_status);
            END IF;

            -- 4. reject or load
            IF v_reasons IS NOT NULL THEN
                reject(p_batch_id, 'STG_CUSTOMERS', r.source_customer_id, v_reasons, v_raw);
                UPDATE stg_customers SET record_status = 'REJECTED' WHERE staging_customer_id = r.staging_customer_id;
            ELSE
                BEGIN
                    -- MERGE = "update if the customer exists, insert if new" (an UPSERT)
                    MERGE INTO customer c
                    USING (SELECT TRIM(r.source_customer_id) AS ref FROM dual) s
                    ON (c.source_customer_ref = s.ref)
                    WHEN MATCHED THEN UPDATE SET
                        c.first_name = INITCAP(TRIM(r.first_name)),
                        c.last_name  = INITCAP(TRIM(r.last_name)),
                        c.date_of_birth = NVL(v_dob, c.date_of_birth),
                        c.gender     = NVL(v_gender, c.gender),
                        c.email      = LOWER(TRIM(r.email)),
                        c.phone      = NVL(TRIM(r.phone), c.phone),
                        c.city       = NVL(INITCAP(TRIM(r.city)), c.city),
                        c.state      = NVL(INITCAP(TRIM(r.state)), c.state),
                        c.annual_income     = NVL(v_income, c.annual_income),
                        c.employment_status = NVL(v_emp, c.employment_status),
                        c.credit_score      = NVL(v_score, c.credit_score)
                    WHEN NOT MATCHED THEN INSERT
                        (source_customer_ref, first_name, last_name, date_of_birth, gender, email, phone,
                         city, state, annual_income, employment_status, credit_score, customer_since)
                    VALUES
                        (s.ref, INITCAP(TRIM(r.first_name)), INITCAP(TRIM(r.last_name)), v_dob, v_gender,
                         LOWER(TRIM(r.email)), TRIM(r.phone), INITCAP(TRIM(r.city)), INITCAP(TRIM(r.state)),
                         v_income, v_emp, v_score,
                         NVL(TRUNC(TO_DATE(SUBSTR(r.source_created_at, 1, 10) DEFAULT NULL ON CONVERSION ERROR,
                                           'YYYY-MM-DD')), TRUNC(SYSDATE)));

                    UPDATE stg_customers SET record_status = 'LOADED' WHERE staging_customer_id = r.staging_customer_id;
                    g_success := g_success + 1;
                EXCEPTION WHEN OTHERS THEN
                    -- a database rule we did not anticipate: reject this row, keep going
                    reject(p_batch_id, 'STG_CUSTOMERS', r.source_customer_id, 'Database error: ' || SQLERRM, v_raw);
                    UPDATE stg_customers SET record_status = 'REJECTED' WHERE staging_customer_id = r.staging_customer_id;
                END;
            END IF;
        END LOOP;
    END process_customers;

    ------------------------------------------------------------------
    -- LOANS
    ------------------------------------------------------------------
    PROCEDURE process_loans (p_batch_id NUMBER) IS
        v_reasons   VARCHAR2(4000);
        v_cust_id   NUMBER;
        v_branch_id NUMBER;
        v_type      loan_type%ROWTYPE;
        v_no_type   loan_type%ROWTYPE;      -- always empty, used to reset v_type
        v_amount    NUMBER;
        v_rate      NUMBER;
        v_tenure    NUMBER;
        v_disb      DATE;
        v_cnt       NUMBER;
        v_app_id    NUMBER;
        v_loan_id   NUMBER;
        v_raw       VARCHAR2(4000);
    BEGIN
        FOR r IN (
            SELECT s.*,
                   ROW_NUMBER() OVER (PARTITION BY UPPER(TRIM(s.source_loan_id))
                                      ORDER BY s.staging_loan_id) AS dup_rank
            FROM   stg_loans s
            WHERE  s.batch_id = p_batch_id AND s.record_status = 'NEW'
            ORDER  BY s.staging_loan_id
        ) LOOP
            g_total   := g_total + 1;
            v_reasons := NULL;
            v_cust_id := NULL; v_branch_id := NULL; v_type := v_no_type;
            v_raw := 'loan=' || r.source_loan_id || '|cust=' || r.source_customer_id || '|branch=' ||
                     r.source_branch_id || '|type=' || r.loan_type_name || '|amount=' || r.principal_amount ||
                     '|rate=' || r.interest_rate || '|tenure=' || r.tenure_months || '|disb=' || r.disbursement_date;

            IF TRIM(r.source_loan_id) IS NULL THEN add_reason(v_reasons, 'Missing source_loan_id'); END IF;
            IF r.dup_rank > 1 THEN add_reason(v_reasons, 'Duplicate source_loan_id in this batch'); END IF;

            SELECT COUNT(*) INTO v_cnt FROM loan WHERE source_loan_ref = TRIM(r.source_loan_id);
            IF v_cnt > 0 THEN add_reason(v_reasons, 'Loan already loaded earlier'); END IF;

            -- look up the operational IDs that match the source system's IDs
            BEGIN
                SELECT customer_id INTO v_cust_id FROM customer WHERE source_customer_ref = TRIM(r.source_customer_id);
            EXCEPTION WHEN NO_DATA_FOUND THEN add_reason(v_reasons, 'Unknown customer ' || r.source_customer_id);
            END;
            BEGIN
                SELECT branch_id INTO v_branch_id FROM branch WHERE branch_code = UPPER(TRIM(r.source_branch_id));
            EXCEPTION WHEN NO_DATA_FOUND THEN add_reason(v_reasons, 'Unknown branch ' || r.source_branch_id);
            END;
            BEGIN
                SELECT * INTO v_type FROM loan_type WHERE UPPER(loan_type_name) = UPPER(TRIM(r.loan_type_name));
            EXCEPTION WHEN NO_DATA_FOUND THEN add_reason(v_reasons, 'Unknown loan type ' || r.loan_type_name);
            END;

            v_amount := to_num(r.principal_amount);
            IF v_amount IS NULL OR v_amount <= 0 THEN
                add_reason(v_reasons, 'Invalid principal_amount: ' || r.principal_amount);
            ELSIF v_type.loan_type_id IS NOT NULL
                  AND v_amount NOT BETWEEN v_type.minimum_amount AND v_type.maximum_amount THEN
                add_reason(v_reasons, 'Amount outside product limits (' || v_type.minimum_amount ||
                                      ' - ' || v_type.maximum_amount || ')');
            END IF;

            v_rate := to_num(r.interest_rate);
            IF v_rate IS NULL OR v_rate <= 0 OR v_rate > 50 THEN
                add_reason(v_reasons, 'Invalid interest_rate: ' || r.interest_rate);
            END IF;

            v_tenure := to_num(r.tenure_months);
            IF v_tenure IS NULL OR v_tenure <= 0 OR v_tenure <> TRUNC(v_tenure) THEN
                add_reason(v_reasons, 'Invalid tenure_months: ' || r.tenure_months);
            ELSIF v_type.loan_type_id IS NOT NULL AND v_tenure > v_type.maximum_tenure_months THEN
                add_reason(v_reasons, 'Tenure above product maximum of ' || v_type.maximum_tenure_months);
            END IF;

            v_disb := to_dt(r.disbursement_date);
            IF v_disb IS NULL OR v_disb > TRUNC(SYSDATE) THEN
                add_reason(v_reasons, 'Invalid or future disbursement_date: ' || r.disbursement_date);
            END IF;

            IF NVL(UPPER(TRIM(r.loan_status)), 'ACTIVE') <> 'ACTIVE' THEN
                add_reason(v_reasons, 'New loans must arrive with status ACTIVE');
            END IF;

            IF v_reasons IS NOT NULL THEN
                reject(p_batch_id, 'STG_LOANS', r.source_loan_id, v_reasons, v_raw);
                UPDATE stg_loans SET record_status = 'REJECTED' WHERE staging_loan_id = r.staging_loan_id;
            ELSE
                BEGIN
                    -- Business rule: every loan comes from an APPROVED application.
                    -- Loans from an external system were approved there, so we record
                    -- that approved application here first, then disburse through PKG_LOAN.
                    INSERT INTO loan_application (customer_id, branch_id, loan_type_id, application_date,
                                                  requested_amount, requested_tenure_months,
                                                  application_status, approved_date)
                    VALUES (v_cust_id, v_branch_id, v_type.loan_type_id, v_disb,
                            v_amount, v_tenure, 'APPROVED', v_disb)
                    RETURNING application_id INTO v_app_id;

                    v_loan_id := pkg_loan.disburse_loan(v_app_id, v_disb, TRIM(r.source_loan_id), v_rate);

                    UPDATE stg_loans SET record_status = 'LOADED' WHERE staging_loan_id = r.staging_loan_id;
                    g_success := g_success + 1;
                EXCEPTION WHEN OTHERS THEN
                    reject(p_batch_id, 'STG_LOANS', r.source_loan_id, 'Database error: ' || SQLERRM, v_raw);
                    UPDATE stg_loans SET record_status = 'REJECTED' WHERE staging_loan_id = r.staging_loan_id;
                END;
            END IF;
        END LOOP;
    END process_loans;

    ------------------------------------------------------------------
    -- PAYMENTS
    ------------------------------------------------------------------
    PROCEDURE process_payments (p_batch_id NUMBER) IS
        v_reasons  VARCHAR2(4000);
        v_loan     loan%ROWTYPE;
        v_no_loan  loan%ROWTYPE;            -- always empty, used to reset v_loan
        v_due      DATE;
        v_paid_on  DATE;
        v_amount   NUMBER;
        v_status   VARCHAR2(20);
        v_method   VARCHAR2(20);
        v_cnt      NUMBER;
        v_pay_id   NUMBER;
        v_raw      VARCHAR2(4000);
    BEGIN
        FOR r IN (
            SELECT s.*,
                   ROW_NUMBER() OVER (PARTITION BY UPPER(TRIM(s.source_payment_id))
                                      ORDER BY s.staging_payment_id) AS dup_rank
            FROM   stg_payments s
            WHERE  s.batch_id = p_batch_id AND s.record_status = 'NEW'
            ORDER  BY s.source_loan_id, s.due_date, s.staging_payment_id   -- instalments in order
        ) LOOP
            g_total   := g_total + 1;
            v_reasons := NULL;
            v_loan    := v_no_loan;
            v_raw := 'payment=' || r.source_payment_id || '|loan=' || r.source_loan_id || '|paid_on=' ||
                     r.payment_date || '|due=' || r.due_date || '|amount=' || r.payment_amount ||
                     '|status=' || r.payment_status;

            IF TRIM(r.source_payment_id) IS NULL THEN add_reason(v_reasons, 'Missing source_payment_id'); END IF;
            IF r.dup_rank > 1 THEN add_reason(v_reasons, 'Duplicate source_payment_id in this batch'); END IF;

            SELECT COUNT(*) INTO v_cnt FROM payment WHERE transaction_reference = TRIM(r.source_payment_id);
            IF v_cnt > 0 THEN add_reason(v_reasons, 'Payment already loaded earlier'); END IF;

            BEGIN
                SELECT * INTO v_loan FROM loan WHERE source_loan_ref = TRIM(r.source_loan_id);
                IF v_loan.loan_status = 'CLOSED' THEN add_reason(v_reasons, 'Loan is already closed'); END IF;
            EXCEPTION WHEN NO_DATA_FOUND THEN add_reason(v_reasons, 'Unknown loan ' || r.source_loan_id);
            END;

            v_due := to_dt(r.due_date);
            IF v_due IS NULL THEN
                add_reason(v_reasons, 'Invalid due_date: ' || r.due_date);
            ELSIF v_loan.loan_id IS NOT NULL AND v_due <= v_loan.disbursement_date THEN
                add_reason(v_reasons, 'Due date is before the loan was disbursed');
            END IF;

            v_status := UPPER(TRIM(r.payment_status));
            IF v_status = 'MISSED' OR TRIM(r.payment_date) IS NULL THEN
                v_paid_on := NULL;                                -- nothing received
                v_amount  := 0;
            ELSE
                v_paid_on := to_dt(r.payment_date);
                v_amount  := to_num(r.payment_amount);
                IF v_paid_on IS NULL OR v_paid_on > TRUNC(SYSDATE) THEN
                    add_reason(v_reasons, 'Invalid or future payment_date: ' || r.payment_date);
                END IF;
                IF v_amount IS NULL OR v_amount <= 0 THEN
                    add_reason(v_reasons, 'Invalid payment_amount: ' || r.payment_amount);
                END IF;
            END IF;
            IF v_status NOT IN ('PAID','MISSED','ON_TIME','LATE') OR v_status IS NULL THEN
                add_reason(v_reasons, 'Unknown payment_status: ' || r.payment_status);
            END IF;

            v_method := UPPER(TRIM(r.payment_method));
            IF v_method NOT IN ('UPI','NACH','NET_BANKING','CHEQUE','CASH') THEN
                v_method := NULL;     -- unknown method is not fatal; keep the payment
            END IF;

            IF v_reasons IS NOT NULL THEN
                reject(p_batch_id, 'STG_PAYMENTS', r.source_payment_id, v_reasons, v_raw);
                UPDATE stg_payments SET record_status = 'REJECTED' WHERE staging_payment_id = r.staging_payment_id;
            ELSE
                BEGIN
                    -- PKG_LOAN decides ON_TIME / LATE / MISSED and reduces the balance
                    v_pay_id := pkg_loan.record_installment(v_loan.loan_id, v_due, v_paid_on, v_amount,
                                                            v_method, TRIM(r.source_payment_id));
                    UPDATE stg_payments SET record_status = 'LOADED' WHERE staging_payment_id = r.staging_payment_id;
                    g_success := g_success + 1;
                EXCEPTION WHEN OTHERS THEN
                    reject(p_batch_id, 'STG_PAYMENTS', r.source_payment_id, 'Database error: ' || SQLERRM, v_raw);
                    UPDATE stg_payments SET record_status = 'REJECTED' WHERE staging_payment_id = r.staging_payment_id;
                END;
            END IF;
        END LOOP;
    END process_payments;

    ------------------------------------------------------------------
    -- Batch failure handler (autonomous so it survives the rollback)
    ------------------------------------------------------------------
    PROCEDURE mark_failed (p_batch_id NUMBER, p_error VARCHAR2) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        UPDATE etl_batch
        SET    batch_status = 'FAILED', batch_end_time = SYSTIMESTAMP,
               error_message = SUBSTR(p_error, 1, 4000)
        WHERE  batch_id = p_batch_id;
        COMMIT;
    END mark_failed;

    ------------------------------------------------------------------
    -- MAIN ENTRY POINT
    ------------------------------------------------------------------
    FUNCTION run_etl (p_source_name VARCHAR2 DEFAULT 'CSV_FILES') RETURN NUMBER IS
        v_batch_id NUMBER;
        v_claimed  NUMBER := 0;
    BEGIN
        EXECUTE IMMEDIATE 'ALTER SESSION SET NLS_NUMERIC_CHARACTERS = ''.,''';   -- '13.50' means 13.5
        g_total := 0; g_success := 0; g_rejected := 0;

        -- Step 1: register the batch (committed straight away so it is visible even if the run fails)
        INSERT INTO etl_batch (source_name) VALUES (p_source_name) RETURNING batch_id INTO v_batch_id;
        COMMIT;
        log_msg(v_batch_id, 'START', 'ETL run started for source ' || p_source_name);

        -- Step 2: claim NEW rows that are not yet part of any batch
        UPDATE stg_customers SET batch_id = v_batch_id WHERE batch_id IS NULL AND record_status = 'NEW';
        v_claimed := v_claimed + SQL%ROWCOUNT;
        UPDATE stg_loans     SET batch_id = v_batch_id WHERE batch_id IS NULL AND record_status = 'NEW';
        v_claimed := v_claimed + SQL%ROWCOUNT;
        UPDATE stg_payments  SET batch_id = v_batch_id WHERE batch_id IS NULL AND record_status = 'NEW';
        v_claimed := v_claimed + SQL%ROWCOUNT;
        log_msg(v_batch_id, 'CLAIM', v_claimed || ' staging rows claimed');

        -- Step 3: validate + load, parents before children
        process_customers(v_batch_id);
        log_msg(v_batch_id, 'CUSTOMERS', 'done: ' || g_success || ' loaded, ' || g_rejected || ' rejected so far');
        process_loans(v_batch_id);
        log_msg(v_batch_id, 'LOANS', 'done: ' || g_success || ' loaded, ' || g_rejected || ' rejected so far');
        process_payments(v_batch_id);
        log_msg(v_batch_id, 'PAYMENTS', 'done: ' || g_success || ' loaded, ' || g_rejected || ' rejected so far');

        -- Step 4: business status refresh
        pkg_loan.refresh_loan_status;

        -- Step 5: close the batch
        UPDATE etl_batch
        SET    batch_end_time     = SYSTIMESTAMP,
               total_records      = g_total,
               successful_records = g_success,
               rejected_records   = g_rejected,
               batch_status       = CASE WHEN g_rejected = 0 THEN 'SUCCESS' ELSE 'COMPLETED_WITH_ERRORS' END
        WHERE  batch_id = v_batch_id;
        COMMIT;

        log_msg(v_batch_id, 'END', 'Total ' || g_total || ', loaded ' || g_success || ', rejected ' || g_rejected,
                CASE WHEN g_rejected > 0 THEN 'WARN' ELSE 'INFO' END);
        RETURN v_batch_id;

    EXCEPTION WHEN OTHERS THEN
        ROLLBACK;                                             -- undo the half-finished run
        log_msg(v_batch_id, 'FATAL', SQLERRM || ' ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 'ERROR');
        mark_failed(v_batch_id, SQLERRM);
        RAISE;
    END run_etl;

    PROCEDURE run_etl_job (p_source_name VARCHAR2 DEFAULT 'CSV_FILES') IS
        v_dummy NUMBER;
    BEGIN
        v_dummy := run_etl(p_source_name);
    END run_etl_job;

END pkg_etl;
/
