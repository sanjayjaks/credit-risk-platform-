# Credit Risk Intelligence & Analytics Platform (Oracle)

A prototype data platform for a **fictional** lender: operational database (OLTP), staging + ETL,
star-schema data warehouse, role-based access for an Oracle APEX app, and Power BI reporting views.
All data is invented. Risk categories are illustrative rules, not a validated credit model.

## Folder layout

| Path | What it is |
|---|---|
| `sql/01_drop_all.sql` | Removes everything (for a clean re-install) |
| `sql/02_oltp_tables.sql` | Operational tables, constraints, indexes, triggers |
| `sql/03_oltp_sample_data.sql` | 5 branches, 5 loan types, 40 customers, 60 applications, 37 loans, 431 instalments |
| `sql/04_loan_package.sql` | `PKG_LOAN` – approve / reject / disburse / record instalment |
| `sql/05_staging_tables.sql` | Staging tables + ETL_BATCH, ETL_REJECTED_RECORD, ETL_LOG |
| `sql/06_staging_sample_data.sql` | The CSV rows as INSERTs (includes deliberately bad rows) |
| `sql/07_etl_package.sql` | `PKG_ETL` – validate, reject, load staging → OLTP |
| `sql/08_dw_tables.sql` | Star schema: DIM_DATE, DIM_CUSTOMER (SCD2), DIM_BRANCH, DIM_LOAN_TYPE, 2 facts |
| `sql/09_dw_load_package.sql` | `PKG_DW` – loads dimensions and facts from OLTP |
| `sql/10_app_security.sql` | APP_USER / APP_ROLE / APP_USER_ROLE + `PKG_SECURITY` |
| `sql/11_powerbi_views.sql` | Aggregated reporting views |
| `sql/12_run_pipeline.sql` | Runs DW load → ETL → DW reload and shows results |
| `sql/13_business_queries.sql` | The 14 business questions |
| `data/*.csv` | Incoming source files for the ETL demo |
| `generator/*.py` | Python that generated the sample data + an independent check script |

## How to install (free Oracle APEX workspace, ~10 minutes)

1. Get a free workspace at **apex.oracle.com** (or use Oracle Live SQL, or a local Oracle 19c/21c/23ai).
2. SQL Workshop → SQL Scripts → Upload each file, then Run, **in number order 02 → 13**
   (run `01_drop_all.sql` first only when re-installing).
3. Optional: instead of script 06, load `data/*.csv` with SQL Workshop → Utilities → Data Workshop
   → Load Data into STG_CUSTOMERS / STG_LOANS / STG_PAYMENTS (column names match the CSV headers).

SQL Developer users: open a script and press F5 (Run Script).

## What you should see

| Check | Expected |
|---|---|
| Customers / applications (before ETL) | 40 / 60 |
| Approval rate (approved ÷ decided) | 37 ÷ 53 = **69.81 %** |
| Loans / total disbursed (before ETL) | 37 / ₹3,98,00,000 |
| Loan status | 33 ACTIVE, 1 CLOSED, 3 DEFAULTED |
| ETL batch 1 | 26 records → 12 loaded, 14 rejected → `COMPLETED_WITH_ERRORS` |
| After ETL | 44 customers, 40 loans |
| DIM_CUSTOMER after 2nd DW load | 45 rows (customer 1005 has 2 versions) |
| FACT_PAYMENTS | 392 rows before ETL, 395 after |
| FACT_LOAN_PERFORMANCE | 482 rows before ETL, 489 after |
| 31-Oct-2026 snapshot (before ETL) | 36 loans, 3 in default → **8.33 %** default rate |
| High-risk customers (score < 650) | 12 |

## Run order of the data flow

```
CSV files ─► STG_* tables ─► PKG_ETL (validate) ─► OLTP tables ─► PKG_DW ─► DIM_* / FACT_* ─► Power BI
                                  └─► ETL_REJECTED_RECORD + ETL_LOG          OLTP ─► APEX app
```
