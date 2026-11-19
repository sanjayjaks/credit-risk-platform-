-- =====================================================================
-- 04_loan_package.sql
-- PKG_LOAN: the business logic of the operational system.
-- Both the APEX app (a loan officer clicking "Approve") and the ETL
-- (loading files) call these procedures, so the rules live in ONE place.
-- =====================================================================

CREATE OR REPLACE PACKAGE pkg_loan AS

    -- Standard EMI formula:  EMI = P * r * (1+r)^n / ((1+r)^n - 1),  r = annual% / 12 / 100
    FUNCTION calc_emi (p_principal NUMBER, p_annual_rate NUMBER, p_months NUMBER) RETURN NUMBER;

    PROCEDURE approve_application (p_application_id NUMBER,
                                   p_approved_date  DATE DEFAULT TRUNC(SYSDATE));

    PROCEDURE reject_application  (p_application_id NUMBER,
                                   p_reason         VARCHAR2);

    -- Creates the LOAN row for an APPROVED application. Returns the new loan_id.
    FUNCTION disburse_loan (p_application_id    NUMBER,
                            p_disbursement_date DATE     DEFAULT TRUNC(SYSDATE),
                            p_source_loan_ref   VARCHAR2 DEFAULT NULL,
                            p_interest_rate     NUMBER   DEFAULT NULL) RETURN NUMBER;  -- NULL = product rate

    -- Records the next instalment of a loan.
    -- p_payment_date NULL  => instalment MISSED (nothing received)
    -- payment on/before due date => ON_TIME, after => LATE
    FUNCTION record_installment (p_loan_id        NUMBER,
                                 p_due_date       DATE,
                                 p_payment_date   DATE,
                                 p_amount         NUMBER,
                                 p_method         VARCHAR2 DEFAULT NULL,
                                 p_reference      VARCHAR2 DEFAULT NULL) RETURN NUMBER;

    -- Marks loans with 3+ consecutive latest missed instalments as DEFAULTED
    -- (illustrative rule, roughly "90 days past due").
    PROCEDURE refresh_loan_status;

END pkg_loan;
/

CREATE OR REPLACE PACKAGE BODY pkg_loan AS

    FUNCTION calc_emi (p_principal NUMBER, p_annual_rate NUMBER, p_months NUMBER) RETURN NUMBER IS
        r NUMBER := p_annual_rate / 1200;
    BEGIN
        IF r = 0 THEN
            RETURN ROUND(p_principal / p_months, 2);
        END IF;
        RETURN ROUND(p_principal * r * POWER(1 + r, p_months) / (POWER(1 + r, p_months) - 1), 2);
    END calc_emi;

    ------------------------------------------------------------------
    PROCEDURE approve_application (p_application_id NUMBER,
                                   p_approved_date  DATE DEFAULT TRUNC(SYSDATE)) IS
    BEGIN
        UPDATE loan_application
        SET    application_status = 'APPROVED',
               approved_date      = p_approved_date,
               rejection_reason   = NULL
        WHERE  application_id     = p_application_id
        AND    application_status IN ('PENDING','UNDER_REVIEW');

        IF SQL%ROWCOUNT = 0 THEN
            RAISE_APPLICATION_ERROR(-20010,
                'Application ' || p_application_id || ' not found or already decided');
        END IF;
    END approve_application;

    ------------------------------------------------------------------
    PROCEDURE reject_application (p_application_id NUMBER, p_reason VARCHAR2) IS
    BEGIN
        IF p_reason IS NULL THEN
            RAISE_APPLICATION_ERROR(-20011, 'A rejection reason is required');
        END IF;

        UPDATE loan_application
        SET    application_status = 'REJECTED',
               rejection_reason   = p_reason
        WHERE  application_id     = p_application_id
        AND    application_status IN ('PENDING','UNDER_REVIEW');

        IF SQL%ROWCOUNT = 0 THEN
            RAISE_APPLICATION_ERROR(-20012,
                'Application ' || p_application_id || ' not found or already decided');
        END IF;
    END reject_application;

    ------------------------------------------------------------------
    FUNCTION disburse_loan (p_application_id    NUMBER,
                            p_disbursement_date DATE     DEFAULT TRUNC(SYSDATE),
                            p_source_loan_ref   VARCHAR2 DEFAULT NULL,
                            p_interest_rate     NUMBER   DEFAULT NULL) RETURN NUMBER IS
        v_app     loan_application%ROWTYPE;
        v_rate    loan_type.interest_rate%TYPE;
        v_loan_id loan.loan_id%TYPE;
    BEGIN
        SELECT * INTO v_app FROM loan_application WHERE application_id = p_application_id;
        SELECT interest_rate INTO v_rate FROM loan_type WHERE loan_type_id = v_app.loan_type_id;
        v_rate := NVL(p_interest_rate, v_rate);

        -- (trigger TRG_LOAN_REQUIRES_APPROVAL re-checks that the application is APPROVED)
        INSERT INTO loan (source_loan_ref, application_id, customer_id, branch_id, loan_type_id,
                          principal_amount, interest_rate, tenure_months, emi_amount,
                          disbursement_date, maturity_date, outstanding_balance, loan_status)
        VALUES (p_source_loan_ref, v_app.application_id, v_app.customer_id, v_app.branch_id,
                v_app.loan_type_id, v_app.requested_amount, v_rate, v_app.requested_tenure_months,
                calc_emi(v_app.requested_amount, v_rate, v_app.requested_tenure_months),
                p_disbursement_date, ADD_MONTHS(p_disbursement_date, v_app.requested_tenure_months),
                v_app.requested_amount, 'ACTIVE')
        RETURNING loan_id INTO v_loan_id;

        RETURN v_loan_id;
    END disburse_loan;

    ------------------------------------------------------------------
    FUNCTION record_installment (p_loan_id        NUMBER,
                                 p_due_date       DATE,
                                 p_payment_date   DATE,
                                 p_amount         NUMBER,
                                 p_method         VARCHAR2 DEFAULT NULL,
                                 p_reference      VARCHAR2 DEFAULT NULL) RETURN NUMBER IS
        v_loan        loan%ROWTYPE;
        v_next_no     NUMBER;
        v_interest    NUMBER;
        v_principal   NUMBER;   -- principal part of this instalment
        v_amount_due  NUMBER;   -- scheduled instalment (principal + interest)
        v_status      VARCHAR2(10);
        v_paid        NUMBER;
        v_payment_id  NUMBER;
    BEGIN
        SELECT * INTO v_loan FROM loan WHERE loan_id = p_loan_id FOR UPDATE;

        IF v_loan.loan_status = 'CLOSED' THEN
            RAISE_APPLICATION_ERROR(-20020, 'Loan ' || p_loan_id || ' is already closed');
        END IF;

        SELECT NVL(MAX(installment_no), 0) + 1 INTO v_next_no
        FROM   payment WHERE loan_id = p_loan_id;

        -- interest for the month is charged on the current outstanding balance
        v_interest  := ROUND(v_loan.outstanding_balance * v_loan.interest_rate / 1200, 2);
        v_principal := LEAST(GREATEST(v_loan.emi_amount - v_interest, 0), v_loan.outstanding_balance);
        v_amount_due := v_principal + v_interest;

        IF p_payment_date IS NULL THEN
            v_status := 'MISSED';
            v_paid   := 0;
        ELSE
            IF NVL(p_amount, 0) <= 0 THEN
                RAISE_APPLICATION_ERROR(-20021, 'Payment amount must be positive');
            END IF;
            v_status := CASE WHEN p_payment_date <= p_due_date THEN 'ON_TIME' ELSE 'LATE' END;
            v_paid   := p_amount;
            -- principal actually repaid = what was paid minus the interest, capped by the balance
            v_principal := LEAST(GREATEST(p_amount - v_interest, 0), v_loan.outstanding_balance);
        END IF;

        INSERT INTO payment (loan_id, installment_no, due_date, amount_due, payment_date,
                             payment_amount, principal_component, interest_component,
                             payment_status, payment_method, transaction_reference)
        VALUES (p_loan_id, v_next_no, p_due_date, v_amount_due, p_payment_date,
                v_paid, v_principal, v_interest, v_status,
                CASE WHEN p_payment_date IS NOT NULL THEN p_method END,
                p_reference)
        RETURNING payment_id INTO v_payment_id;

        -- only money actually received reduces the balance
        IF v_status <> 'MISSED' THEN
            UPDATE loan
            SET    outstanding_balance = outstanding_balance - v_principal,
                   loan_status = CASE WHEN outstanding_balance - v_principal <= 0 THEN 'CLOSED' ELSE loan_status END,
                   closed_date = CASE WHEN outstanding_balance - v_principal <= 0 THEN p_payment_date END
            WHERE  loan_id = p_loan_id;
        END IF;

        RETURN v_payment_id;
    END record_installment;

    ------------------------------------------------------------------
    PROCEDURE refresh_loan_status IS
    BEGIN
        -- trailing_missed = number of MISSED instalments after the last paid one
        MERGE INTO loan l
        USING (
            SELECT p.loan_id,
                   COUNT(CASE WHEN p.payment_status = 'MISSED'
                               AND p.installment_no > NVL(lp.last_paid_no, 0) THEN 1 END) AS trailing_missed
            FROM   payment p
            LEFT JOIN (SELECT loan_id, MAX(installment_no) AS last_paid_no
                       FROM   payment WHERE payment_status <> 'MISSED'
                       GROUP BY loan_id) lp
                   ON lp.loan_id = p.loan_id
            GROUP BY p.loan_id
        ) s
        ON (l.loan_id = s.loan_id)
        WHEN MATCHED THEN UPDATE
            SET l.loan_status = CASE WHEN s.trailing_missed >= 3 THEN 'DEFAULTED' ELSE 'ACTIVE' END
            WHERE l.loan_status <> 'CLOSED'
            AND   l.loan_status <> CASE WHEN s.trailing_missed >= 3 THEN 'DEFAULTED' ELSE 'ACTIVE' END;
    END refresh_loan_status;

END pkg_loan;
/
