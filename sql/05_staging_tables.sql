-- =====================================================================
-- 05_staging_tables.sql
-- LAYER 2: STAGING + ETL CONTROL TABLES
-- Staging = a "waiting room" for raw data from CSV files / APIs.
-- Every raw column is VARCHAR2 on purpose: bad data such as 'abc' in an
-- amount column must still LAND here, so the ETL can catch it and log it,
-- instead of the file load crashing.
-- Staging tables have NO foreign keys to operational tables.
-- =====================================================================

-- ---------------------------------------------------------------------
-- ETL_BATCH: one row per ETL run (the "run register")
-- Statuses: RUNNING, SUCCESS, COMPLETED_WITH_ERRORS, FAILED
-- ---------------------------------------------------------------------
CREATE TABLE etl_batch (
    batch_id            NUMBER GENERATED ALWAYS AS IDENTITY,
    source_name         VARCHAR2(100) NOT NULL,           -- e.g. 'CSV_FILES' or 'LOAN_API'
    batch_start_time    TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
    batch_end_time      TIMESTAMP,
    batch_status        VARCHAR2(25) DEFAULT 'RUNNING' NOT NULL,
    total_records       NUMBER DEFAULT 0 NOT NULL,
    successful_records  NUMBER DEFAULT 0 NOT NULL,
    rejected_records    NUMBER DEFAULT 0 NOT NULL,
    error_message       VARCHAR2(4000),
    CONSTRAINT pk_etl_batch     PRIMARY KEY (batch_id),
    CONSTRAINT ck_batch_status  CHECK (batch_status IN ('RUNNING','SUCCESS','COMPLETED_WITH_ERRORS','FAILED')),
    CONSTRAINT ck_batch_counts  CHECK (successful_records + rejected_records <= total_records)
);

-- ---------------------------------------------------------------------
-- STG_CUSTOMERS  (columns match data/customers.csv)
-- record_status: NEW (just loaded) -> LOADED (went to OLTP) | REJECTED
-- batch_id is NULL until an ETL run "claims" the row.
-- ---------------------------------------------------------------------
CREATE TABLE stg_customers (
    staging_customer_id  NUMBER GENERATED ALWAYS AS IDENTITY,
    batch_id             NUMBER,
    source_customer_id   VARCHAR2(100),
    first_name           VARCHAR2(200),
    last_name            VARCHAR2(200),
    date_of_birth        VARCHAR2(50),
    gender               VARCHAR2(20),
    email                VARCHAR2(200),
    phone                VARCHAR2(50),
    city                 VARCHAR2(100),
    state                VARCHAR2(100),
    annual_income        VARCHAR2(50),
    employment_status    VARCHAR2(50),
    credit_score         VARCHAR2(50),
    source_created_at    VARCHAR2(50),
    record_status        VARCHAR2(10) DEFAULT 'NEW' NOT NULL,
    loaded_at            TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
    CONSTRAINT pk_stg_customers PRIMARY KEY (staging_customer_id),
    CONSTRAINT fk_stgc_batch    FOREIGN KEY (batch_id) REFERENCES etl_batch(batch_id),
    CONSTRAINT ck_stgc_status   CHECK (record_status IN ('NEW','LOADED','REJECTED'))
);

-- ---------------------------------------------------------------------
-- STG_LOANS  (columns match data/loans.csv)
-- ---------------------------------------------------------------------
CREATE TABLE stg_loans (
    staging_loan_id     NUMBER GENERATED ALWAYS AS IDENTITY,
    batch_id            NUMBER,
    source_loan_id      VARCHAR2(100),
    source_customer_id  VARCHAR2(100),
    source_branch_id    VARCHAR2(100),
    loan_type_name      VARCHAR2(100),
    principal_amount    VARCHAR2(50),
    interest_rate       VARCHAR2(50),
    tenure_months       VARCHAR2(50),
    disbursement_date   VARCHAR2(50),
    loan_status         VARCHAR2(50),
    record_status       VARCHAR2(10) DEFAULT 'NEW' NOT NULL,
    loaded_at           TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
    CONSTRAINT pk_stg_loans   PRIMARY KEY (staging_loan_id),
    CONSTRAINT fk_stgl_batch  FOREIGN KEY (batch_id) REFERENCES etl_batch(batch_id),
    CONSTRAINT ck_stgl_status CHECK (record_status IN ('NEW','LOADED','REJECTED'))
);

-- ---------------------------------------------------------------------
-- STG_PAYMENTS  (columns match data/payments.csv)
-- payment_date empty => the instalment was missed
-- ---------------------------------------------------------------------
CREATE TABLE stg_payments (
    staging_payment_id  NUMBER GENERATED ALWAYS AS IDENTITY,
    batch_id            NUMBER,
    source_payment_id   VARCHAR2(100),
    source_loan_id      VARCHAR2(100),
    payment_date        VARCHAR2(50),
    due_date            VARCHAR2(50),
    payment_amount      VARCHAR2(50),
    payment_status      VARCHAR2(50),
    payment_method      VARCHAR2(50),
    record_status       VARCHAR2(10) DEFAULT 'NEW' NOT NULL,
    loaded_at           TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
    CONSTRAINT pk_stg_payments PRIMARY KEY (staging_payment_id),
    CONSTRAINT fk_stgp_batch   FOREIGN KEY (batch_id) REFERENCES etl_batch(batch_id),
    CONSTRAINT ck_stgp_status  CHECK (record_status IN ('NEW','LOADED','REJECTED'))
);

-- ---------------------------------------------------------------------
-- ETL_REJECTED_RECORD: every bad row and WHY it was rejected
-- raw_record keeps a copy of the original values for investigation
-- ---------------------------------------------------------------------
CREATE TABLE etl_rejected_record (
    rejection_id      NUMBER GENERATED ALWAYS AS IDENTITY,
    batch_id          NUMBER NOT NULL,
    source_table      VARCHAR2(30)  NOT NULL,
    source_record_id  VARCHAR2(100),
    rejection_reason  VARCHAR2(400) NOT NULL,
    raw_record        VARCHAR2(4000),
    rejected_at       TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
    CONSTRAINT pk_etl_rejected_record PRIMARY KEY (rejection_id),
    CONSTRAINT fk_rej_batch FOREIGN KEY (batch_id) REFERENCES etl_batch(batch_id)
);

-- ---------------------------------------------------------------------
-- ETL_LOG: step-by-step log of every run (INFO / WARN / ERROR)
-- (added to the original design: needed so errors can be investigated)
-- ---------------------------------------------------------------------
CREATE TABLE etl_log (
    log_id     NUMBER GENERATED ALWAYS AS IDENTITY,
    batch_id   NUMBER,
    log_time   TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
    log_level  VARCHAR2(5) DEFAULT 'INFO' NOT NULL,
    step_name  VARCHAR2(60),
    message    VARCHAR2(4000),
    CONSTRAINT pk_etl_log    PRIMARY KEY (log_id),
    CONSTRAINT fk_log_batch  FOREIGN KEY (batch_id) REFERENCES etl_batch(batch_id),
    CONSTRAINT ck_log_level  CHECK (log_level IN ('INFO','WARN','ERROR'))
);

CREATE INDEX ix_stgc_batch_status ON stg_customers (batch_id, record_status);
CREATE INDEX ix_stgl_batch_status ON stg_loans     (batch_id, record_status);
CREATE INDEX ix_stgp_batch_status ON stg_payments  (batch_id, record_status);
CREATE INDEX ix_rej_batch         ON etl_rejected_record (batch_id);
CREATE INDEX ix_log_batch         ON etl_log (batch_id);
