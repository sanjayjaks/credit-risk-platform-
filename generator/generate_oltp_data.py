"""
Generates FICTIONAL sample data for the operational (OLTP) database.
Output: ../sql/03_oltp_sample_data.sql  (plain INSERT statements for Oracle)

Story behind the data
- 5 branches, 5 loan types, 40 customers (all invented)
- 60 loan applications (Jan 2025 - Oct 2026): approved / rejected / pending
- Every approved application becomes a disbursed LOAN
- Every loan has one PAYMENT row per monthly instalment that has fallen due
  up to the data cut-off date (31-Oct-2026)
- Payment behaviour depends on credit score, so the risk analytics have
  something meaningful to find (low scores -> late / missed / defaults)
"""
import random, datetime as dt, json, os
from dateutil.relativedelta import relativedelta

random.seed(42)
CUTOFF = dt.date(2026, 10, 31)
OUT = os.path.join(os.path.dirname(__file__), "..", "sql", "03_oltp_sample_data.sql")

branches = [
    (1, "BR001", "Jaipur Main Branch", "Jaipur", "Rajasthan", "Kavita Sharma"),
    (2, "BR002", "Delhi Connaught Place", "New Delhi", "Delhi", "Rohan Mehta"),
    (3, "BR003", "Mumbai Andheri", "Mumbai", "Maharashtra", "Sneha Kulkarni"),
    (4, "BR004", "Bengaluru Koramangala", "Bengaluru", "Karnataka", "Arjun Rao"),
    (5, "BR005", "Pune Shivajinagar", "Pune", "Maharashtra", "Meera Joshi"),
]
# id, name, description, rate, min, max, max_tenure
loan_types = [
    (1, "Personal Loan", "Unsecured loan for personal needs", 13.50, 50000, 1500000, 60),
    (2, "Home Loan", "Secured loan to buy or build a house", 8.75, 500000, 10000000, 240),
    (3, "Auto Loan", "Loan to purchase a car or two-wheeler", 9.50, 100000, 2500000, 84),
    (4, "Education Loan", "Loan for higher-education fees", 10.25, 100000, 4000000, 120),
    (5, "Business Loan", "Working-capital loan for small businesses", 14.00, 200000, 5000000, 60),
]
LT = {t[0]: t for t in loan_types}

first = ["Aarav","Vivaan","Aditya","Ishaan","Kabir","Riya","Ananya","Diya","Saanvi","Myra",
         "Rahul","Neha","Karan","Pooja","Vikram","Sana","Arnav","Tanvi","Dev","Nisha",
         "Yash","Kriti","Manav","Simran","Harsh","Aditi","Nikhil","Ira","Rohit","Megha",
         "Varun","Shreya","Kunal","Pallavi","Siddharth","Zoya","Akash","Bhavna","Tarun","Lavanya"]
last = ["Agarwal","Bansal","Chopra","Desai","Gupta","Iyer","Jain","Kapoor","Khanna","Malhotra",
        "Nair","Patel","Reddy","Saxena","Singh","Trivedi","Verma","Yadav","Bhatt","Menon"]
cities = [("Jaipur","Rajasthan"),("New Delhi","Delhi"),("Mumbai","Maharashtra"),
          ("Bengaluru","Karnataka"),("Pune","Maharashtra"),("Udaipur","Rajasthan"),("Gurugram","Haryana")]
emp_status = ["SALARIED","SALARIED","SALARIED","SELF_EMPLOYED","SELF_EMPLOYED","BUSINESS_OWNER","STUDENT","RETIRED"]

def q(v):
    if v is None: return "NULL"
    if isinstance(v, dt.datetime): return f"TIMESTAMP '{v:%Y-%m-%d %H:%M:%S}'"
    if isinstance(v, dt.date): return f"DATE '{v:%Y-%m-%d}'"
    if isinstance(v, (int, float)): return f"{v}"
    return "'" + str(v).replace("'", "''") + "'"

def ins(table, cols, vals):
    return f"INSERT INTO {table} ({', '.join(cols)}) VALUES ({', '.join(q(v) for v in vals)});"

# ---------------- customers ----------------
customers = []
score_pool = ([random.randint(760, 850) for _ in range(13)] + [random.randint(650, 749) for _ in range(15)]
              + [random.randint(560, 649) for _ in range(12)])
random.shuffle(score_pool)
for i in range(40):
    cid = 1001 + i
    fn, ln = first[i], last[i % 20]
    city, state = cities[i % len(cities)]
    emp = emp_status[i % len(emp_status)]
    income = {"SALARIED": random.randint(4, 30), "SELF_EMPLOYED": random.randint(5, 35),
              "BUSINESS_OWNER": random.randint(8, 60), "STUDENT": random.randint(1, 3),
              "RETIRED": random.randint(3, 10)}[emp] * 100000
    dob = dt.date(random.randint(1965, 2003), random.randint(1, 12), random.randint(1, 28))
    since = dt.date(random.randint(2018, 2024), random.randint(1, 12), random.randint(1, 28))
    customers.append(dict(customer_id=cid, source_customer_ref=f"CRM-{cid}", first_name=fn, last_name=ln,
        date_of_birth=dob, gender=random.choice(["M", "F"]) if fn not in ("Riya","Ananya","Diya","Saanvi","Myra","Neha","Pooja","Sana","Tanvi","Nisha","Kriti","Simran","Aditi","Ira","Megha","Shreya","Pallavi","Zoya","Bhavna","Lavanya") else "F",
        email=f"{fn.lower()}.{ln.lower()}{cid}@example.com", phone=f"9{random.randint(100000000, 999999999)}",
        address=f"{random.randint(1, 250)}, Sample Nagar", city=city, state=state, annual_income=income,
        employment_status=emp, credit_score=score_pool[i], customer_since=since))
# fix gender for male names
for c in customers:
    if c["first_name"] in ("Aarav","Vivaan","Aditya","Ishaan","Kabir","Rahul","Karan","Vikram","Arnav","Dev","Yash","Manav","Harsh","Nikhil","Rohit","Varun","Kunal","Siddharth","Akash","Tarun"):
        c["gender"] = "M"
CUST = {c["customer_id"]: c for c in customers}

def emi(p, rate, n):
    r = rate / 1200
    return round(p * r * (1 + r) ** n / ((1 + r) ** n - 1), 2)

# ---------------- applications ----------------
apps = []
app_id = 1
start = dt.date(2025, 1, 6)
for k in range(60):
    c = customers[k % 40] if k < 40 else customers[random.randint(0, 39)]
    lt = random.choices([1, 2, 3, 4, 5], weights=[35, 15, 25, 10, 15])[0]
    t = LT[lt]
    if k < 52:
        adate = start + dt.timedelta(days=int(k * 11.5))  # spread Jan-2025 .. Aug-2026
    else:
        adate = dt.date(2026, 9, 1) + dt.timedelta(days=(k - 52) * 7)
    adate = adate.replace(day=min(adate.day, 26))
    if lt == 2:
        amt = random.choice([2500000, 3500000, 4500000, 6000000])
        ten = random.choice([180, 240])
    elif lt == 4:
        amt = random.choice([400000, 800000, 1200000]); ten = random.choice([60, 84, 120])
    elif lt == 3:
        amt = random.choice([300000, 600000, 900000]); ten = random.choice([36, 48, 60])
    elif lt == 5:
        amt = random.choice([500000, 1000000, 2000000]); ten = random.choice([24, 36, 48])
    else:
        amt = random.choice([100000, 200000, 300000, 500000]); ten = random.choice([12, 24, 36])
    status, reason, appr = "APPROVED", None, None
    if c["credit_score"] < 580:
        status, reason = "REJECTED", "Credit score below policy minimum (580)"
    elif emi(amt, t[3], ten) * 12 > 0.6 * c["annual_income"]:
        status, reason = "REJECTED", "Instalment too high for declared income"
    elif adate >= dt.date(2026, 9, 1) and k >= 56:
        status = "PENDING"
    elif adate >= dt.date(2026, 9, 1):
        status = "UNDER_REVIEW"
    if status == "APPROVED":
        appr = adate + dt.timedelta(days=random.randint(2, 6))
    branch = random.randint(1, 5)
    apps.append(dict(application_id=app_id, customer_id=c["customer_id"], branch_id=branch, loan_type_id=lt,
                     application_date=adate, requested_amount=amt, requested_tenure_months=ten,
                     application_status=status, rejection_reason=reason, approved_date=appr))
    app_id += 1

# ---------------- loans + payments ----------------
loans, payments = [], []
loan_id, pay_id = 1, 1
defaulters_left = 3
methods = ["UPI", "NACH", "NACH", "NET_BANKING", "CHEQUE", "CASH"]
for a in apps:
    if a["application_status"] != "APPROVED":
        continue
    t = LT[a["loan_type_id"]]
    c = CUST[a["customer_id"]]
    disb = a["approved_date"] + dt.timedelta(days=2)
    if disb.day > 28:  # keep instalment day valid in every month: roll to the 1st of next month
        disb = (disb.replace(day=1) + relativedelta(months=1))
    P, rate, n = a["requested_amount"], t[3], a["requested_tenure_months"]
    E = emi(P, rate, n)
    score = c["credit_score"]
    will_default = score < 650 and defaulters_left > 0 and disb < dt.date(2025, 12, 1)
    if will_default:
        defaulters_left -= 1
    bal = P
    rows = []
    for k in range(1, n + 1):
        due = disb + relativedelta(months=k)
        if due > CUTOFF:
            break
        interest = round(bal * rate / 1200, 2)
        principal = round(min(E - interest, bal), 2)
        amount_due = round(principal + interest, 2)
        # behaviour
        if will_default and k > 6:
            status = "MISSED"
        elif score >= 750:
            status = "ON_TIME"
        elif score >= 650:
            status = "LATE" if random.random() < 0.15 else "ON_TIME"
        else:
            r = random.random()
            status = "ON_TIME" if r < 0.68 else ("LATE" if r < 0.90 else "MISSED")
            # an old missed instalment would have been chased and collected late;
            # only recent ones (last ~2 months) are still unpaid
            if status == "MISSED" and due < CUTOFF - dt.timedelta(days=60):
                status = "VERY_LATE"
        if status == "VERY_LATE":
            status, pdate = "LATE", due + dt.timedelta(days=random.randint(30, 55))
            if pdate > CUTOFF:
                status, pdate = "MISSED", None
        elif status == "ON_TIME":
            pdate = due - dt.timedelta(days=random.randint(0, 3))
        elif status == "LATE":
            pdate = due + dt.timedelta(days=random.randint(5, 40) if score < 650 else random.randint(3, 20))
            if pdate > CUTOFF:
                status, pdate = "MISSED", None
        else:
            pdate = None
        paid = amount_due if pdate else 0
        if pdate:
            bal = round(bal - principal, 2)
        rows.append(dict(payment_id=pay_id, loan_id=loan_id, installment_no=k, due_date=due, amount_due=amount_due,
                         payment_date=pdate, payment_amount=paid, principal_component=principal,
                         interest_component=interest, payment_status=status,
                         payment_method=random.choice(methods) if pdate else None,
                         transaction_reference=f"PAY-{pay_id:06d}" if pdate else None))
        pay_id += 1
    # loan status
    trailing_missed = 0
    for r in reversed(rows):
        if r["payment_status"] == "MISSED": trailing_missed += 1
        else: break
    closed = None
    if bal <= 0.01 and len(rows) == n:
        lstatus = "CLOSED"; closed = max(r["payment_date"] for r in rows)
    elif trailing_missed >= 3:
        lstatus = "DEFAULTED"
    else:
        lstatus = "ACTIVE"
    loans.append(dict(loan_id=loan_id, source_loan_ref=f"LMS-{5000 + loan_id}", application_id=a["application_id"],
                      customer_id=a["customer_id"], branch_id=a["branch_id"], loan_type_id=a["loan_type_id"],
                      principal_amount=P, interest_rate=rate, tenure_months=n, emi_amount=E,
                      disbursement_date=disb, maturity_date=disb + relativedelta(months=n),
                      outstanding_balance=0 if lstatus == "CLOSED" else max(bal, 0), loan_status=lstatus, closed_date=closed))
    payments.extend(rows)
    loan_id += 1

# ---------------- write SQL ----------------
L = []
L.append("-- =====================================================================")
L.append("-- 03_oltp_sample_data.sql  |  FICTIONAL sample data (generated)")
L.append("-- Generated by generator/generate_oltp_data.py - do not edit by hand.")
L.append(f"-- {len(customers)} customers, {len(apps)} applications, {len(loans)} loans, {len(payments)} payment rows")
L.append("-- Data cut-off date: 31-Oct-2026. All names, emails and phones are invented.")
L.append("-- =====================================================================")
L.append("SET DEFINE OFF;\n")
L.append("-- BRANCH")
for b in branches:
    L.append(ins("branch", ["branch_id","branch_code","branch_name","city","state","branch_manager"], b))
L.append("\n-- LOAN_TYPE")
for t in loan_types:
    L.append(ins("loan_type", ["loan_type_id","loan_type_name","description","interest_rate","minimum_amount","maximum_amount","maximum_tenure_months"], t))
L.append("\n-- CUSTOMER")
ccols = ["customer_id","source_customer_ref","first_name","last_name","date_of_birth","gender","email","phone","address","city","state","annual_income","employment_status","credit_score","customer_since"]
for c in customers:
    L.append(ins("customer", ccols, [c[k] for k in ccols]))
L.append("\n-- LOAN_APPLICATION")
acols = ["application_id","customer_id","branch_id","loan_type_id","application_date","requested_amount","requested_tenure_months","application_status","rejection_reason","approved_date"]
for a in apps:
    L.append(ins("loan_application", acols, [a[k] for k in acols]))
L.append("\n-- LOAN  (trigger TRG_LOAN_REQUIRES_APPROVAL checks each application is APPROVED)")
lcols = ["loan_id","source_loan_ref","application_id","customer_id","branch_id","loan_type_id","principal_amount","interest_rate","tenure_months","emi_amount","disbursement_date","maturity_date","outstanding_balance","loan_status","closed_date"]
for l in loans:
    L.append(ins("loan", lcols, [l[k] for k in lcols]))
L.append("\n-- PAYMENT  (one row per instalment that has fallen due)")
pcols = ["payment_id","loan_id","installment_no","due_date","amount_due","payment_date","payment_amount","principal_component","interest_component","payment_status","payment_method","transaction_reference"]
for p in payments:
    L.append(ins("payment", pcols, [p[k] for k in pcols]))
L.append("""
COMMIT;

-- Move identity counters past the IDs inserted above, so new rows get fresh IDs
ALTER TABLE customer         MODIFY customer_id    GENERATED BY DEFAULT AS IDENTITY (START WITH LIMIT VALUE);
ALTER TABLE branch           MODIFY branch_id      GENERATED BY DEFAULT AS IDENTITY (START WITH LIMIT VALUE);
ALTER TABLE loan_type        MODIFY loan_type_id   GENERATED BY DEFAULT AS IDENTITY (START WITH LIMIT VALUE);
ALTER TABLE loan_application MODIFY application_id GENERATED BY DEFAULT AS IDENTITY (START WITH LIMIT VALUE);
ALTER TABLE loan             MODIFY loan_id        GENERATED BY DEFAULT AS IDENTITY (START WITH LIMIT VALUE);
ALTER TABLE payment          MODIFY payment_id     GENERATED BY DEFAULT AS IDENTITY (START WITH LIMIT VALUE);
""")
with open(OUT, "w") as f:
    f.write("\n".join(L))

# summary for sanity checks
summary = dict(
    customers=len(customers), applications=len(apps),
    app_status={s: sum(a["application_status"] == s for a in apps) for s in ["APPROVED","REJECTED","PENDING","UNDER_REVIEW"]},
    loans=len(loans),
    loan_status={s: sum(l["loan_status"] == s for l in loans) for s in ["ACTIVE","CLOSED","DEFAULTED"]},
    payments=len(payments),
    pay_status={s: sum(p["payment_status"] == s for p in payments) for s in ["ON_TIME","LATE","MISSED"]},
    total_disbursed=sum(l["principal_amount"] for l in loans),
    outstanding=round(sum(l["outstanding_balance"] for l in loans), 2),
    collected=round(sum(p["payment_amount"] for p in payments), 2),
    high_risk_customers=sum(c["credit_score"] < 650 for c in customers),
)
summary["approval_rate_pct"] = round(100 * summary["app_status"]["APPROVED"] / (summary["app_status"]["APPROVED"] + summary["app_status"]["REJECTED"]), 2)
json.dump(summary, open(os.path.join(os.path.dirname(__file__), "expected_numbers.json"), "w"), indent=2, default=str)
print(json.dumps(summary, indent=2, default=str))
for l in loans:
    if l["loan_status"] != "ACTIVE": print(l["loan_id"], l["loan_status"], l["customer_id"], CUST[l["customer_id"]]["credit_score"])
