-- =====================================================================
-- 12_run_pipeline.sql
-- Runs the whole data flow end-to-end and shows what happened at each step.
-- Run this AFTER scripts 02-11. In APEX SQL Workshop > SQL Scripts, run it
-- as a script; in SQL Developer press F5 (Run Script).
-- The sample data cut-off is 31-Oct-2026, so snapshots run up to that date.
-- =====================================================================
SET SERVEROUTPUT ON;

-- ---------------------------------------------------------------------
-- STEP A. First warehouse load (from the 40 sample customers / 37 loans)
--         This creates version 1 of every customer in DIM_CUSTOMER.
-- ---------------------------------------------------------------------
BEGIN
    pkg_dw.run_dw_load(DATE '2026-10-31');
END;
/

SELECT 'dim_customer' AS tbl, COUNT(*) AS row_count FROM dim_customer UNION ALL
SELECT 'fact_loan_performance', COUNT(*) FROM fact_loan_performance UNION ALL
SELECT 'fact_payments',         COUNT(*) FROM fact_payments;

-- ---------------------------------------------------------------------
-- STEP B. ETL run: staging (the CSV rows from script 06) -> operational
-- ---------------------------------------------------------------------
DECLARE
    v_batch_id NUMBER;
BEGIN
    v_batch_id := pkg_etl.run_etl('CSV_FILES');
    DBMS_OUTPUT.PUT_LINE('ETL finished, batch_id = ' || v_batch_id);
END;
/

-- What happened in the run?
SELECT batch_id, source_name, batch_status, total_records, successful_records, rejected_records,
       batch_end_time - batch_start_time AS duration
FROM   etl_batch ORDER BY batch_id DESC;

-- Why were rows rejected?
SELECT source_table, source_record_id, rejection_reason
FROM   etl_rejected_record ORDER BY rejection_id;

-- Step-by-step log
SELECT log_time, log_level, step_name, message FROM etl_log ORDER BY log_id;

-- Staging rows now carry a status
SELECT 'customers' AS stg, record_status, COUNT(*) FROM stg_customers GROUP BY record_status UNION ALL
SELECT 'loans',            record_status, COUNT(*) FROM stg_loans     GROUP BY record_status UNION ALL
SELECT 'payments',         record_status, COUNT(*) FROM stg_payments  GROUP BY record_status;

-- ---------------------------------------------------------------------
-- STEP C. Refresh the warehouse with the newly loaded data
--         Customer 1005 changed city + employment + risk -> SCD Type 2
-- ---------------------------------------------------------------------
BEGIN
    pkg_dw.run_dw_load(DATE '2026-10-31');
END;
/

-- SCD Type 2 in action: two versions of the same customer
SELECT customer_key, customer_id, customer_name, city, employment_status, risk_category,
       effective_start_date, effective_end_date, is_current
FROM   dim_customer
WHERE  customer_id = 1005
ORDER  BY effective_start_date;

-- Historical facts still point at the OLD version (Pune, LOW risk) because
-- those snapshots were taken before the change:
SELECT f.snapshot_date_key, c.customer_key, c.city, c.risk_category, f.outstanding_balance
FROM   fact_loan_performance f
JOIN   dim_customer c ON c.customer_key = f.customer_key
WHERE  c.customer_id = 1005
ORDER  BY f.snapshot_date_key DESC
FETCH FIRST 3 ROWS ONLY;

-- ---------------------------------------------------------------------
-- OPTIONAL. Schedule ETL + warehouse load every night at 01:00.
-- (In APEX you can use App Builder > Shared Components > Automations instead.)
-- ---------------------------------------------------------------------
-- BEGIN
--     DBMS_SCHEDULER.CREATE_JOB(
--         job_name        => 'NIGHTLY_CREDIT_RISK_LOAD',
--         job_type        => 'PLSQL_BLOCK',
--         job_action      => 'BEGIN pkg_etl.run_etl_job(''CSV_FILES''); pkg_dw.run_dw_load; END;',
--         repeat_interval => 'FREQ=DAILY;BYHOUR=1;BYMINUTE=0',
--         enabled         => TRUE);
-- END;
-- /
