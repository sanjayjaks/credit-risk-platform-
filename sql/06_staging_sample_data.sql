-- =====================================================================
-- 06_staging_sample_data.sql
-- Simulates loading the three CSV files (data/*.csv) into staging.
-- In APEX you can instead upload the CSVs with SQL Workshop > Utilities >
-- Data Workshop > Load Data into STG_CUSTOMERS / STG_LOANS / STG_PAYMENTS.
-- Rows arrive with batch_id NULL and record_status 'NEW'.
-- Several rows are deliberately invalid (see comments in the CSV generator).
-- =====================================================================
SET DEFINE OFF;

-- STG_CUSTOMERS
INSERT INTO stg_customers (source_customer_id, first_name, last_name, date_of_birth, gender, email, phone, city, state, annual_income, employment_status, credit_score, source_created_at) VALUES ('CRM-1041', 'Farhan', 'Qureshi', '1991-04-12', 'M', 'farhan.qureshi@example.com', '9812345601', 'Jaipur', 'Rajasthan', '900000', 'SALARIED', '781', '2026-08-28 10:15:00');
INSERT INTO stg_customers (source_customer_id, first_name, last_name, date_of_birth, gender, email, phone, city, state, annual_income, employment_status, credit_score, source_created_at) VALUES ('CRM-1042', 'Ritika', 'Sood', '1994-09-30', 'F', 'ritika.sood@example.com', '9812345602', 'Mumbai', 'Maharashtra', '1400000', 'SALARIED', '712', '2026-08-29 11:00:00');
INSERT INTO stg_customers (source_customer_id, first_name, last_name, date_of_birth, gender, email, phone, city, state, annual_income, employment_status, credit_score, source_created_at) VALUES ('CRM-1043', 'Gaurav', 'Pillai', '1986-01-17', 'M', 'gaurav.pillai@example.com', '9812345603', 'Bengaluru', 'Karnataka', '3200000', 'BUSINESS_OWNER', '745', '2026-08-01 09:30:00');
INSERT INTO stg_customers (source_customer_id, first_name, last_name, date_of_birth, gender, email, phone, city, state, annual_income, employment_status, credit_score, source_created_at) VALUES ('CRM-1044', 'Jasleen', 'Kaur', '1998-06-05', 'F', 'jasleen.kaur@example.com', '9812345604', 'New Delhi', 'Delhi', '650000', 'SALARIED', '668', '2026-09-02 16:45:00');
INSERT INTO stg_customers (source_customer_id, first_name, last_name, date_of_birth, gender, email, phone, city, state, annual_income, employment_status, credit_score, source_created_at) VALUES ('CRM-1005', 'Kabir', 'Gupta', '1975-11-14', 'M', 'kabir.gupta1005@example.com', '9739830322', 'Mumbai', 'Maharashtra', '2900000', 'SALARIED', '690', '2026-09-05 12:00:00');
INSERT INTO stg_customers (source_customer_id, first_name, last_name, date_of_birth, gender, email, phone, city, state, annual_income, employment_status, credit_score, source_created_at) VALUES ('CRM-1045', 'Ayesha', 'Khan', '1990-03-03', 'F', 'ayesha.khan@example.com', '9812345605', 'Pune', 'Maharashtra', '800000', 'SALARIED', '950', '2026-09-03 10:00:00');
INSERT INTO stg_customers (source_customer_id, first_name, last_name, date_of_birth, gender, email, phone, city, state, annual_income, employment_status, credit_score, source_created_at) VALUES ('CRM-1046', 'Mohit', 'Arora', '1989-12-12', 'M', NULL, '9812345606', 'Jaipur', 'Rajasthan', '700000', 'SALARIED', '701', '2026-09-03 10:05:00');
INSERT INTO stg_customers (source_customer_id, first_name, last_name, date_of_birth, gender, email, phone, city, state, annual_income, employment_status, credit_score, source_created_at) VALUES ('CRM-1047', 'Preeti', 'Bose', '1993-07-21', 'F', 'preeti.bose@example.com', '9812345607', 'Mumbai', 'Maharashtra', 'abc', 'SALARIED', '720', '2026-09-03 10:10:00');
INSERT INTO stg_customers (source_customer_id, first_name, last_name, date_of_birth, gender, email, phone, city, state, annual_income, employment_status, credit_score, source_created_at) VALUES ('CRM-1041', 'Farhan', 'Qureshi', '1991-04-12', 'M', 'farhan.q@example.com', '9812345601', 'Jaipur', 'Rajasthan', '900000', 'SALARIED', '781', '2026-09-04 10:15:00');
INSERT INTO stg_customers (source_customer_id, first_name, last_name, date_of_birth, gender, email, phone, city, state, annual_income, employment_status, credit_score, source_created_at) VALUES ('CRM-1048', 'Sahil', 'Mittal', '1990-02-31', 'M', 'sahil.mittal@example.com', '9812345608', 'Gurugram', 'Haryana', '1100000', 'SALARIED', '733', '2026-09-04 11:00:00');
INSERT INTO stg_customers (source_customer_id, first_name, last_name, date_of_birth, gender, email, phone, city, state, annual_income, employment_status, credit_score, source_created_at) VALUES ('CRM-1049', 'Ankit', 'Rana', '1992-08-08', 'M', 'aarav.agarwal1001@example.com', '9812345609', 'Udaipur', 'Rajasthan', '600000', 'SALARIED', '700', '2026-09-04 12:00:00');

-- STG_LOANS
INSERT INTO stg_loans (source_loan_id, source_customer_id, source_branch_id, loan_type_name, principal_amount, interest_rate, tenure_months, disbursement_date, loan_status) VALUES ('LMS-6001', 'CRM-1041', 'BR001', 'Personal Loan', '300000', '13.50', '24', '2026-09-10', 'ACTIVE');
INSERT INTO stg_loans (source_loan_id, source_customer_id, source_branch_id, loan_type_name, principal_amount, interest_rate, tenure_months, disbursement_date, loan_status) VALUES ('LMS-6002', 'CRM-1042', 'BR003', 'Auto Loan', '600000', '9.50', '60', '2026-09-15', 'ACTIVE');
INSERT INTO stg_loans (source_loan_id, source_customer_id, source_branch_id, loan_type_name, principal_amount, interest_rate, tenure_months, disbursement_date, loan_status) VALUES ('LMS-6003', 'CRM-1043', 'BR004', 'Home Loan', '3500000', '8.75', '240', '2026-08-20', 'ACTIVE');
INSERT INTO stg_loans (source_loan_id, source_customer_id, source_branch_id, loan_type_name, principal_amount, interest_rate, tenure_months, disbursement_date, loan_status) VALUES ('LMS-6004', 'CRM-1044', 'BR002', 'Gold Loan', '200000', '11.00', '12', '2026-09-12', 'ACTIVE');
INSERT INTO stg_loans (source_loan_id, source_customer_id, source_branch_id, loan_type_name, principal_amount, interest_rate, tenure_months, disbursement_date, loan_status) VALUES ('LMS-6005', 'CRM-1045', 'BR005', 'Personal Loan', '200000', '13.50', '24', '2026-09-12', 'ACTIVE');
INSERT INTO stg_loans (source_loan_id, source_customer_id, source_branch_id, loan_type_name, principal_amount, interest_rate, tenure_months, disbursement_date, loan_status) VALUES ('LMS-6006', 'CRM-1042', 'BR009', 'Personal Loan', '150000', '13.50', '12', '2026-09-18', 'ACTIVE');
INSERT INTO stg_loans (source_loan_id, source_customer_id, source_branch_id, loan_type_name, principal_amount, interest_rate, tenure_months, disbursement_date, loan_status) VALUES ('LMS-6007', 'CRM-1043', 'BR005', 'Personal Loan', '-50000', '13.50', '12', '2026-09-18', 'ACTIVE');
INSERT INTO stg_loans (source_loan_id, source_customer_id, source_branch_id, loan_type_name, principal_amount, interest_rate, tenure_months, disbursement_date, loan_status) VALUES ('LMS-6008', 'CRM-1044', 'BR002', 'Personal Loan', '5000000', '13.50', '36', '2026-09-18', 'ACTIVE');

-- STG_PAYMENTS
INSERT INTO stg_payments (source_payment_id, source_loan_id, payment_date, due_date, payment_amount, payment_status, payment_method) VALUES ('PAY-900001', 'LMS-6001', '2026-10-08', '2026-10-10', '14333.1', 'PAID', 'UPI');
INSERT INTO stg_payments (source_payment_id, source_loan_id, payment_date, due_date, payment_amount, payment_status, payment_method) VALUES ('PAY-900002', 'LMS-6002', '2026-10-20', '2026-10-15', '12601.12', 'PAID', 'NACH');
INSERT INTO stg_payments (source_payment_id, source_loan_id, payment_date, due_date, payment_amount, payment_status, payment_method) VALUES ('PAY-900003', 'LMS-6003', '2026-09-19', '2026-09-20', '30929.87', 'PAID', 'NET_BANKING');
INSERT INTO stg_payments (source_payment_id, source_loan_id, payment_date, due_date, payment_amount, payment_status, payment_method) VALUES ('PAY-900004', 'LMS-6003', NULL, '2026-10-20', '0', 'MISSED', NULL);
INSERT INTO stg_payments (source_payment_id, source_loan_id, payment_date, due_date, payment_amount, payment_status, payment_method) VALUES ('PAY-900005', 'LMS-9999', '2026-10-11', '2026-10-10', '5000', 'PAID', 'UPI');
INSERT INTO stg_payments (source_payment_id, source_loan_id, payment_date, due_date, payment_amount, payment_status, payment_method) VALUES ('PAY-900006', 'LMS-6001', '2026-10-09', '2026-10-10', '-100', 'PAID', 'UPI');
INSERT INTO stg_payments (source_payment_id, source_loan_id, payment_date, due_date, payment_amount, payment_status, payment_method) VALUES ('PAY-900001', 'LMS-6001', '2026-10-08', '2026-10-10', '14333.1', 'PAID', 'UPI');

COMMIT;
