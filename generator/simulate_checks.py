"""
Independent check of the warehouse logic: re-parses the generated INSERTs,
simulates the ETL outcome, and recomputes the 31-Oct-2026 snapshot the same
way PKG_DW does. Prints the numbers you should see after running 12_run_pipeline.sql.
"""
import re, datetime as dt, csv, os
HERE = os.path.dirname(__file__)
sql = open(os.path.join(HERE, "..", "sql", "03_oltp_sample_data.sql")).read()

def rows(table):
    out = []
    for m in re.finditer(rf"INSERT INTO {table} \((.*?)\) VALUES \((.*)\);", sql):
        cols = [c.strip() for c in m.group(1).split(",")]
        vals = re.findall(r"DATE '([\d-]+)'|'((?:[^']|'')*)'|(NULL)|(-?[\d.]+)", m.group(2))
        parsed = []
        for d, s, n, num in vals:
            if d: parsed.append(dt.date.fromisoformat(d))
            elif n: parsed.append(None)
            elif num: parsed.append(float(num))
            else: parsed.append(s)
        assert len(parsed) == len(cols), (table, m.group(0)[:120])
        out.append(dict(zip(cols, parsed)))
    return out

loans, pays, custs, apps = rows("loan"), rows("payment"), rows("customer"), rows("loan_application")
print("parsed:", len(custs), "customers", len(apps), "apps", len(loans), "loans", len(pays), "payments")

# integrity checks mirroring the CHECK constraints
for p in pays:
    if p["payment_status"] == "MISSED": assert p["payment_date"] is None and p["payment_amount"] == 0
    elif p["payment_status"] == "ON_TIME": assert p["payment_date"] <= p["due_date"]
    else: assert p["payment_date"] > p["due_date"]
appmap = {a["application_id"]: a for a in apps}
for l in loans:
    a = appmap[l["application_id"]]
    assert a["application_status"] == "APPROVED" and l["disbursement_date"] >= a["approved_date"]
    assert 0 <= l["outstanding_balance"] <= l["principal_amount"]
    assert (l["loan_status"] == "CLOSED") == (l["closed_date"] is not None)
print("constraint checks passed")

snap = dt.date(2026, 10, 31)
def snapshot(snap):
    res = []
    for l in loans:
        if l["disbursement_date"] > snap or (l["closed_date"] and l["closed_date"] <= snap): continue
        lp = [p for p in pays if p["loan_id"] == l["loan_id"]]
        unpaid = [p for p in lp if p["due_date"] <= snap and (p["payment_date"] is None or p["payment_date"] > snap)]
        oldest = min((p["due_date"] for p in unpaid), default=None)
        dpd = (snap - oldest).days if oldest else 0
        res.append(dict(out=l["principal_amount"] - sum(p["principal_component"] for p in lp if p["payment_date"] and p["payment_date"] <= snap),
                        overdue=sum(p["amount_due"] for p in unpaid), dpd=dpd, default=dpd >= 90))
    return res
s = snapshot(snap)
print(f"Snapshot {snap}: loans={len(s)} outstanding={sum(r['out'] for r in s):,.2f} overdue={sum(r['overdue'] for r in s):,.2f} defaulted={sum(r['default'] for r in s)} default_rate={100*sum(r['default'] for r in s)/len(s):.2f}%")
months = 0
d = dt.date(2025, 1, 31)
first = min(l["disbursement_date"] for l in loans)
cnt = 0
from dateutil.relativedelta import relativedelta
m = dt.date(first.year, first.month, 1) + relativedelta(months=1) - dt.timedelta(days=1)
while m <= snap:
    cnt += len(snapshot(m)); m = (m + dt.timedelta(days=1)) + relativedelta(months=1) - dt.timedelta(days=1)
print("fact_loan_performance rows (before ETL):", cnt)
print("fact_payments rows (before ETL):", sum(1 for p in pays if p["payment_date"]))
