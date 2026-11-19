"""
Builds the incoming "source system" files for the ETL demo:
  data/customers.csv, data/loans.csv, data/payments.csv
and the matching SQL file sql/06_staging_sample_data.sql (same rows as INSERTs,
for when you can't upload CSVs). Several rows are deliberately BAD so the
ETL has something to reject. All data is fictional.
"""
import csv, os

HERE = os.path.dirname(__file__)
DATA = os.path.join(HERE, "..", "data")
SQL = os.path.join(HERE, "..", "sql", "06_staging_sample_data.sql")

def emi(p, rate, n):
    r = rate / 1200
    return round(p * r * (1 + r) ** n / ((1 + r) ** n - 1), 2)

cust_cols = ["source_customer_id","first_name","last_name","date_of_birth","gender","email","phone",
             "city","state","annual_income","employment_status","credit_score","source_created_at"]
customers = [
    # valid new customers
    ["CRM-1041","Farhan","Qureshi","1991-04-12","M","farhan.qureshi@example.com","9812345601","Jaipur","Rajasthan","900000","SALARIED","781","2026-08-28 10:15:00"],
    ["CRM-1042","Ritika","Sood","1994-09-30","F","ritika.sood@example.com","9812345602","Mumbai","Maharashtra","1400000","SALARIED","712","2026-08-29 11:00:00"],
    ["CRM-1043","Gaurav","Pillai","1986-01-17","M","gaurav.pillai@example.com","9812345603","Bengaluru","Karnataka","3200000","BUSINESS_OWNER","745","2026-08-01 09:30:00"],
    ["CRM-1044","Jasleen","Kaur","1998-06-05","F","jasleen.kaur@example.com","9812345604","New Delhi","Delhi","650000","SALARIED","668","2026-09-02 16:45:00"],
    # EXISTING customer whose details changed -> UPDATE in OLTP, new SCD2 version in warehouse
    ["CRM-1005","Kabir","Gupta","1975-11-14","M","kabir.gupta1005@example.com","9739830322","Mumbai","Maharashtra","2900000","SALARIED","690","2026-09-05 12:00:00"],
    # BAD rows
    ["CRM-1045","Ayesha","Khan","1990-03-03","F","ayesha.khan@example.com","9812345605","Pune","Maharashtra","800000","SALARIED","950","2026-09-03 10:00:00"],   # score > 900
    ["CRM-1046","Mohit","Arora","1989-12-12","M","","9812345606","Jaipur","Rajasthan","700000","SALARIED","701","2026-09-03 10:05:00"],                              # missing email
    ["CRM-1047","Preeti","Bose","1993-07-21","F","preeti.bose@example.com","9812345607","Mumbai","Maharashtra","abc","SALARIED","720","2026-09-03 10:10:00"],           # income not a number
    ["CRM-1041","Farhan","Qureshi","1991-04-12","M","farhan.q@example.com","9812345601","Jaipur","Rajasthan","900000","SALARIED","781","2026-09-04 10:15:00"],         # duplicate source id in same file
    ["CRM-1048","Sahil","Mittal","1990-02-31","M","sahil.mittal@example.com","9812345608","Gurugram","Haryana","1100000","SALARIED","733","2026-09-04 11:00:00"],       # impossible date
    ["CRM-1049","Ankit","Rana","1992-08-08","M","aarav.agarwal1001@example.com","9812345609","Udaipur","Rajasthan","600000","SALARIED","700","2026-09-04 12:00:00"],   # email belongs to another customer
]

loan_cols = ["source_loan_id","source_customer_id","source_branch_id","loan_type_name","principal_amount",
             "interest_rate","tenure_months","disbursement_date","loan_status"]
loans = [
    ["LMS-6001","CRM-1041","BR001","Personal Loan","300000","13.50","24","2026-09-10","ACTIVE"],
    ["LMS-6002","CRM-1042","BR003","Auto Loan","600000","9.50","60","2026-09-15","ACTIVE"],
    ["LMS-6003","CRM-1043","BR004","Home Loan","3500000","8.75","240","2026-08-20","ACTIVE"],
    # BAD rows
    ["LMS-6004","CRM-1044","BR002","Gold Loan","200000","11.00","12","2026-09-12","ACTIVE"],        # unknown loan type
    ["LMS-6005","CRM-1045","BR005","Personal Loan","200000","13.50","24","2026-09-12","ACTIVE"],    # customer was rejected / unknown
    ["LMS-6006","CRM-1042","BR009","Personal Loan","150000","13.50","12","2026-09-18","ACTIVE"],    # unknown branch
    ["LMS-6007","CRM-1043","BR005","Personal Loan","-50000","13.50","12","2026-09-18","ACTIVE"],    # negative amount
    ["LMS-6008","CRM-1044","BR002","Personal Loan","5000000","13.50","36","2026-09-18","ACTIVE"],   # above product maximum (15 L)
]

e1, e2, e3 = emi(300000, 13.5, 24), emi(600000, 9.5, 60), emi(3500000, 8.75, 240)
pay_cols = ["source_payment_id","source_loan_id","payment_date","due_date","payment_amount","payment_status","payment_method"]
payments = [
    ["PAY-900001","LMS-6001","2026-10-08","2026-10-10",f"{e1}","PAID","UPI"],
    ["PAY-900002","LMS-6002","2026-10-20","2026-10-15",f"{e2}","PAID","NACH"],          # paid 5 days late
    ["PAY-900003","LMS-6003","2026-09-19","2026-09-20",f"{e3}","PAID","NET_BANKING"],
    ["PAY-900004","LMS-6003","","2026-10-20","0","MISSED",""],                           # missed instalment
    # BAD rows
    ["PAY-900005","LMS-9999","2026-10-11","2026-10-10","5000","PAID","UPI"],             # unknown loan
    ["PAY-900006","LMS-6001","2026-10-09","2026-10-10","-100","PAID","UPI"],             # negative amount
    ["PAY-900001","LMS-6001","2026-10-08","2026-10-10",f"{e1}","PAID","UPI"],            # duplicate payment id
]

def write_csv(name, cols, rows):
    with open(os.path.join(DATA, name), "w", newline="") as f:
        w = csv.writer(f); w.writerow(cols); w.writerows(rows)

def q(v):
    return "NULL" if v == "" else "'" + v.replace("'", "''") + "'"

os.makedirs(DATA, exist_ok=True)
write_csv("customers.csv", cust_cols, customers)
write_csv("loans.csv", loan_cols, loans)
write_csv("payments.csv", pay_cols, payments)

L = ["-- =====================================================================",
     "-- 06_staging_sample_data.sql",
     "-- Simulates loading the three CSV files (data/*.csv) into staging.",
     "-- In APEX you can instead upload the CSVs with SQL Workshop > Utilities >",
     "-- Data Workshop > Load Data into STG_CUSTOMERS / STG_LOANS / STG_PAYMENTS.",
     "-- Rows arrive with batch_id NULL and record_status 'NEW'.",
     "-- Several rows are deliberately invalid (see comments in the CSV generator).",
     "-- =====================================================================",
     "SET DEFINE OFF;", ""]
for table, cols, rows in [("stg_customers", cust_cols, customers), ("stg_loans", loan_cols, loans),
                          ("stg_payments", pay_cols, payments)]:
    L.append(f"-- {table.upper()}")
    for r in rows:
        L.append(f"INSERT INTO {table} ({', '.join(cols)}) VALUES ({', '.join(q(v) for v in r)});")
    L.append("")
L.append("COMMIT;")
open(SQL, "w").write("\n".join(L) + "\n")
print("EMIs:", e1, e2, e3)
