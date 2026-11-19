-- =====================================================================
-- 08_dw_tables.sql
-- LAYER 3: DATA WAREHOUSE (OLAP) - STAR SCHEMA
--   Dimensions = the "who / what / where / when" you slice by
--   Facts      = the numbers you add up, at a precisely defined GRAIN
-- Every table uses a SURROGATE key (a meaningless warehouse number) as PK,
-- and keeps the operational BUSINESS key (customer_id, branch_id ...) as a
-- normal column so you can trace back to the source.
-- =====================================================================

-- ---------------------------------------------------------------------
-- DIM_DATE  (one row per calendar day)
-- date_key is YYYYMMDD (e.g. 20261031): the usual convention for date
-- dimensions - readable, sortable and still an integer key.
-- Plays several ROLES in the facts: snapshot date, disbursement date,
-- payment date, due date ("role-playing dimension").
-- ---------------------------------------------------------------------
CREATE TABLE dim_date (
    date_key        NUMBER(8)    NOT NULL,
    calendar_date   DATE         NOT NULL,
    day             NUMBER(2)    NOT NULL,
    day_name        VARCHAR2(10) NOT NULL,
    month           NUMBER(2)    NOT NULL,
    month_name      VARCHAR2(10) NOT NULL,
    year_month      VARCHAR2(7)  NOT NULL,     -- '2026-10', handy for charts
    quarter         NUMBER(1)    NOT NULL,
    year            NUMBER(4)    NOT NULL,
    financial_year  VARCHAR2(9)  NOT NULL,     -- Indian FY April-March, e.g. 'FY2026-27'
    is_month_end    NUMBER(1)    NOT NULL,
    CONSTRAINT pk_dim_date      PRIMARY KEY (date_key),
    CONSTRAINT uq_dim_date_cal  UNIQUE (calendar_date),
    CONSTRAINT ck_dim_date_me   CHECK (is_month_end IN (0,1))
);

-- ---------------------------------------------------------------------
-- DIM_CUSTOMER  (SCD TYPE 2 - keeps history)
-- When a tracked attribute changes (city, employment, income band, risk
-- category) the current row is closed (effective_end_date, is_current=0)
-- and a NEW row with a NEW customer_key is added. So one customer_id can
-- have several rows over time. Name corrections are SCD TYPE 1 (overwrite).
-- ---------------------------------------------------------------------
CREATE TABLE dim_customer (
    customer_key          NUMBER GENERATED ALWAYS AS IDENTITY,
    customer_id           NUMBER        NOT NULL,       -- business key from CUSTOMER
    customer_name         VARCHAR2(110) NOT NULL,
    city                  VARCHAR2(60),
    state                 VARCHAR2(60),
    employment_status     VARCHAR2(20),
    income_band           VARCHAR2(20)  NOT NULL,
    risk_category         VARCHAR2(10)  NOT NULL,       -- LOW / MEDIUM / HIGH / UNRATED (illustrative rule)
    effective_start_date  DATE          NOT NULL,
    effective_end_date    DATE          NOT NULL,       -- 31-12-9999 for the current version
    is_current            NUMBER(1)     NOT NULL,
    CONSTRAINT pk_dim_customer      PRIMARY KEY (customer_key),
    CONSTRAINT uq_dim_customer_ver  UNIQUE (customer_id, effective_start_date),
    CONSTRAINT ck_dim_cust_current  CHECK (is_current IN (0,1)),
    CONSTRAINT ck_dim_cust_dates    CHECK (effective_end_date >= effective_start_date),
    CONSTRAINT ck_dim_cust_risk     CHECK (risk_category IN ('LOW','MEDIUM','HIGH','UNRATED'))
);
-- at most ONE current row per customer
CREATE UNIQUE INDEX uq_dim_customer_current
    ON dim_customer (CASE WHEN is_current = 1 THEN customer_id END);

-- ---------------------------------------------------------------------
-- DIM_BRANCH and DIM_LOAN_TYPE  (SCD TYPE 1 - overwrite, no history)
-- ---------------------------------------------------------------------
CREATE TABLE dim_branch (
    branch_key   NUMBER GENERATED ALWAYS AS IDENTITY,
    branch_id    NUMBER        NOT NULL,                -- business key
    branch_code  VARCHAR2(10)  NOT NULL,
    branch_name  VARCHAR2(100) NOT NULL,
    city         VARCHAR2(60),
    state        VARCHAR2(60),
    CONSTRAINT pk_dim_branch    PRIMARY KEY (branch_key),
    CONSTRAINT uq_dim_branch_bk UNIQUE (branch_id)
);

CREATE TABLE dim_loan_type (
    loan_type_key   NUMBER GENERATED ALWAYS AS IDENTITY,
    loan_type_id    NUMBER        NOT NULL,             -- business key
    loan_type_name  VARCHAR2(50)  NOT NULL,
    description     VARCHAR2(400),
    CONSTRAINT pk_dim_loan_type    PRIMARY KEY (loan_type_key),
    CONSTRAINT uq_dim_loan_type_bk UNIQUE (loan_type_id)
);

-- ---------------------------------------------------------------------
-- FACT_LOAN_PERFORMANCE  (periodic SNAPSHOT fact)
-- GRAIN: one row per loan per month-end snapshot date.
--   "What did loan X look like on 31-Mar-2026?"
-- Balances are re-calculated AS OF each snapshot from dated payments -
-- never copied from LOAN.outstanding_balance (which is only today's value).
-- Measures are semi-additive: add them across loans/branches, but NOT
-- across snapshot dates (summing March + April balances is meaningless).
-- ---------------------------------------------------------------------
CREATE TABLE fact_loan_performance (
    loan_performance_key   NUMBER GENERATED ALWAYS AS IDENTITY,
    loan_id                NUMBER       NOT NULL,       -- degenerate dimension (business id, no dim table)
    customer_key           NUMBER       NOT NULL,
    branch_key             NUMBER       NOT NULL,
    loan_type_key          NUMBER       NOT NULL,
    snapshot_date_key      NUMBER(8)    NOT NULL,
    disbursement_date_key  NUMBER(8)    NOT NULL,
    principal_amount       NUMBER(15,2) NOT NULL,
    outstanding_balance    NUMBER(15,2) NOT NULL,
    overdue_amount         NUMBER(15,2) NOT NULL,
    total_paid_amount      NUMBER(15,2) NOT NULL,
    days_past_due          NUMBER(5)    NOT NULL,
    dpd_bucket             VARCHAR2(10) NOT NULL,       -- 'Current','1-30','31-60','61-90','90+'
    default_flag           NUMBER(1)    NOT NULL,       -- 1 when 90+ days past due (illustrative)
    loan_count             NUMBER(1) DEFAULT 1 NOT NULL,-- always 1, so SUM(loan_count) = number of loans
    CONSTRAINT pk_fact_loan_perf  PRIMARY KEY (loan_performance_key),
    CONSTRAINT uq_flp_grain       UNIQUE (loan_id, snapshot_date_key),     -- enforces the grain
    CONSTRAINT fk_flp_customer    FOREIGN KEY (customer_key)          REFERENCES dim_customer(customer_key),
    CONSTRAINT fk_flp_branch      FOREIGN KEY (branch_key)            REFERENCES dim_branch(branch_key),
    CONSTRAINT fk_flp_loan_type   FOREIGN KEY (loan_type_key)         REFERENCES dim_loan_type(loan_type_key),
    CONSTRAINT fk_flp_snap_date   FOREIGN KEY (snapshot_date_key)     REFERENCES dim_date(date_key),
    CONSTRAINT fk_flp_disb_date   FOREIGN KEY (disbursement_date_key) REFERENCES dim_date(date_key),
    CONSTRAINT ck_flp_default     CHECK (default_flag IN (0,1))
);

-- ---------------------------------------------------------------------
-- FACT_PAYMENTS  (TRANSACTION fact)
-- GRAIN: one row per payment actually received (missed instalments have
-- no money movement, so they appear as overdue in the snapshot fact instead).
-- Fully additive: you can sum payment_amount across anything.
-- ---------------------------------------------------------------------
CREATE TABLE fact_payments (
    payment_fact_key     NUMBER GENERATED ALWAYS AS IDENTITY,
    payment_id           NUMBER       NOT NULL,         -- degenerate dimension
    loan_id              NUMBER       NOT NULL,         -- degenerate dimension
    customer_key         NUMBER       NOT NULL,
    branch_key           NUMBER       NOT NULL,
    loan_type_key        NUMBER       NOT NULL,
    payment_date_key     NUMBER(8)    NOT NULL,
    due_date_key         NUMBER(8)    NOT NULL,
    payment_amount       NUMBER(15,2) NOT NULL,
    principal_component  NUMBER(15,2) NOT NULL,
    interest_component   NUMBER(15,2) NOT NULL,
    days_late            NUMBER(5)    NOT NULL,
    late_payment_flag    NUMBER(1)    NOT NULL,
    payment_count        NUMBER(1) DEFAULT 1 NOT NULL,
    CONSTRAINT pk_fact_payments  PRIMARY KEY (payment_fact_key),
    CONSTRAINT uq_fp_grain       UNIQUE (payment_id),
    CONSTRAINT fk_fp_customer    FOREIGN KEY (customer_key)     REFERENCES dim_customer(customer_key),
    CONSTRAINT fk_fp_branch      FOREIGN KEY (branch_key)       REFERENCES dim_branch(branch_key),
    CONSTRAINT fk_fp_loan_type   FOREIGN KEY (loan_type_key)    REFERENCES dim_loan_type(loan_type_key),
    CONSTRAINT fk_fp_pay_date    FOREIGN KEY (payment_date_key) REFERENCES dim_date(date_key),
    CONSTRAINT fk_fp_due_date    FOREIGN KEY (due_date_key)     REFERENCES dim_date(date_key),
    CONSTRAINT ck_fp_late        CHECK (late_payment_flag IN (0,1))
);

-- Indexes on fact foreign keys (in Enterprise Edition you would often use BITMAP indexes here)
CREATE INDEX ix_flp_customer  ON fact_loan_performance (customer_key);
CREATE INDEX ix_flp_branch    ON fact_loan_performance (branch_key);
CREATE INDEX ix_flp_loan_type ON fact_loan_performance (loan_type_key);
CREATE INDEX ix_flp_snapshot  ON fact_loan_performance (snapshot_date_key);
CREATE INDEX ix_fp_customer   ON fact_payments (customer_key);
CREATE INDEX ix_fp_branch     ON fact_payments (branch_key);
CREATE INDEX ix_fp_loan_type  ON fact_payments (loan_type_key);
CREATE INDEX ix_fp_pay_date   ON fact_payments (payment_date_key);
CREATE INDEX ix_dim_cust_bk   ON dim_customer (customer_id, effective_start_date, effective_end_date);
