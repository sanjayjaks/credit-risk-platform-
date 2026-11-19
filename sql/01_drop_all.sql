-- =====================================================================
-- 01_drop_all.sql
-- Removes every object of this project so you can re-install cleanly.
-- Safe to run on an empty schema (missing objects are ignored).
-- Children are dropped before parents because of foreign keys.
-- =====================================================================
BEGIN
    FOR o IN (
        SELECT 'VIEW'    AS t, column_value AS n FROM TABLE(sys.odcivarchar2list(
               'VW_PORTFOLIO_MONTHLY','VW_PORTFOLIO_LATEST_BY_BRANCH','VW_RISK_SEGMENTS_LATEST','VW_COLLECTIONS_MONTHLY'))
        UNION ALL
        SELECT 'PACKAGE', column_value FROM TABLE(sys.odcivarchar2list(
               'PKG_DW','PKG_ETL','PKG_LOAN','PKG_SECURITY'))
        UNION ALL
        SELECT 'TABLE', column_value FROM TABLE(sys.odcivarchar2list(
               'FACT_LOAN_PERFORMANCE','FACT_PAYMENTS','DIM_CUSTOMER','DIM_BRANCH','DIM_LOAN_TYPE','DIM_DATE',
               'APP_USER_ROLE','APP_ROLE','APP_USER',
               'ETL_REJECTED_RECORD','ETL_LOG','STG_PAYMENTS','STG_LOANS','STG_CUSTOMERS','ETL_BATCH',
               'PAYMENT','LOAN','LOAN_APPLICATION','CUSTOMER','LOAN_TYPE','BRANCH'))
    ) LOOP
        BEGIN
            EXECUTE IMMEDIATE 'DROP ' || o.t || ' ' || o.n || CASE WHEN o.t = 'TABLE' THEN ' CASCADE CONSTRAINTS PURGE' END;
        EXCEPTION WHEN OTHERS THEN
            IF SQLCODE NOT IN (-942, -4043) THEN RAISE; END IF;   -- ignore "does not exist"
        END;
    END LOOP;
END;
/
