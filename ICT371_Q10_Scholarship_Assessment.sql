-- ICT371 Advanced Database - Question 10: Scholarship Assessment

-- ==== Setup ====
-- Run top to bottom in psql / pgAdmin (PostgreSQL 11 or later).
-- Scheduling in part (g) needs the pg_cron extension.
-- Eligibility: age 18-25 inclusive, monthly income <= K3,000, average mark >= 70.
DROP TABLE IF EXISTS decision_audit, applications, students CASCADE;

-- ==== (a) Database and seed data ====
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20) NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);

CREATE TABLE applications (
    application_id     SERIAL PRIMARY KEY,
    student_id         INTEGER NOT NULL REFERENCES students(student_id),
    age_at_application INTEGER NOT NULL CHECK (age_at_application > 0),
    monthly_income     NUMERIC(10,2) NOT NULL CHECK (monthly_income >= 0),
    average_mark       NUMERIC(5,2) NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
    submitted_on       DATE NOT NULL,
    status             VARCHAR(10) NOT NULL DEFAULT 'PENDING',
    CONSTRAINT chk_status CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);

CREATE TABLE decision_audit (
    audit_id       SERIAL PRIMARY KEY,
    application_id INTEGER NOT NULL REFERENCES applications(application_id),
    old_status     VARCHAR(10) NOT NULL,
    new_status     VARCHAR(10) NOT NULL,
    changed_at     TIMESTAMP NOT NULL DEFAULT now()
);

INSERT INTO students (student_number, full_name) VALUES
    ('S001', 'Alice Mwansa'),
    ('S002', 'Brian Phiri'),
    ('S003', 'Chanda Banda'),
    ('S004', 'Daliso Mvula');

-- Six PENDING applications across four students
INSERT INTO applications
    (student_id, age_at_application, monthly_income, average_mark, submitted_on, status)
VALUES
    (1, 20, 2000.00,  75.00, '2026-11-01', 'PENDING'),  -- qualifies
    (2, 18, 3000.00,  70.00, '2026-11-03', 'PENDING'),  -- boundary: all three limits, qualifies
    (3, 25, 2500.00,  69.99, '2026-11-05', 'PENDING'),  -- mark just below 70: rejected
    (4, 26, 1500.00,  85.00, '2026-11-08', 'PENDING'),  -- age 26: rejected
    (1, 19, 3000.01,  90.00, '2026-11-10', 'PENDING'),  -- income just above K3,000: rejected
    (2, 25, 3000.00, 100.00, '2026-11-12', 'PENDING');  -- boundary: age 25, income 3000, qualifies

-- ==== (b) Function: fn_scholarship_eligible ====
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(
    p_age INTEGER, p_income NUMERIC, p_mark NUMERIC)
RETURNS BOOLEAN AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Age, income and mark must not be NULL';
    END IF;
    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Age must be positive (got %)', p_age;
    END IF;
    IF p_income < 0 THEN
        RAISE EXCEPTION 'Income must not be negative (got %)', p_income;
    END IF;
    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Mark must be between 0 and 100 (got %)', p_mark;
    END IF;

    RETURN p_age BETWEEN 18 AND 25
       AND p_income <= 3000
       AND p_mark >= 70;
END;
$$ LANGUAGE plpgsql;

SELECT fn_scholarship_eligible(18, 3000, 70);       -- true  (all boundaries)
SELECT fn_scholarship_eligible(26, 1500, 85);       -- false (age)
-- SELECT fn_scholarship_eligible(NULL, 1500, 85);  -- error: NULL input

-- ==== (c) Procedure: pr_assess_application ====
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INTEGER)
LANGUAGE plpgsql AS $$
DECLARE
    v_app applications%ROWTYPE;
BEGIN
    SELECT * INTO v_app
    FROM applications
    WHERE application_id = p_application_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown application: %', p_application_id;
    END IF;
    IF v_app.status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % was already assessed (status %)',
                        p_application_id, v_app.status;
    END IF;

    IF fn_scholarship_eligible(v_app.age_at_application,
                               v_app.monthly_income,
                               v_app.average_mark) THEN
        UPDATE applications SET status = 'APPROVED'
        WHERE application_id = p_application_id;
    ELSE
        UPDATE applications SET status = 'REJECTED'
        WHERE application_id = p_application_id;
    END IF;
END;
$$;

-- ==== (d) Trigger: decision audit ====
CREATE OR REPLACE FUNCTION trg_fn_decision_audit() RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
    VALUES (NEW.application_id, OLD.status, NEW.status, now());
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_decision_audit
AFTER UPDATE ON applications
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)       -- unchanged status: no audit row
EXECUTE FUNCTION trg_fn_decision_audit();

-- Test: assess one application
CALL pr_assess_application(1);
SELECT application_id, status FROM applications WHERE application_id = 1;
SELECT * FROM decision_audit;                       -- PENDING -> APPROVED

-- Updating another column does not change status: no audit row
UPDATE applications SET average_mark = 75.00 WHERE application_id = 1;
SELECT COUNT(*) FROM decision_audit;                -- still 1

-- CALL pr_assess_application(1);                   -- error: already assessed
-- CALL pr_assess_application(99);                  -- error: unknown application

-- ==== (e) View: v_approved_applicants ====
-- Household income is deliberately not selected.
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT s.student_number,
       s.full_name,
       a.average_mark,
       a.status
FROM applications a
JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';

SELECT * FROM v_approved_applicants;

-- ==== (f) Index ====
-- Justification: the search filters by one status (equality) and a range of
-- submitted_on. Equality column first, range column second, lets the B-tree
-- go straight to one status and read that date range in order.
CREATE INDEX idx_applications_status_submitted
ON applications (status, submitted_on);
ANALYZE applications;

SET enable_seqscan = off;   -- demo only: tiny tables would otherwise use a seq scan
EXPLAIN
SELECT application_id, student_id, submitted_on
FROM applications
WHERE status = 'PENDING'
  AND submitted_on BETWEEN '2026-11-01' AND '2026-11-30';
RESET enable_seqscan;

-- ==== (g) Scheduled job: pr_assess_pending ====
CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql AS $$
DECLARE
    rec RECORD;
BEGIN
    -- Only PENDING rows are selected, so completed applications are never
    -- reassessed and no duplicate audit entries can appear on a rerun.
    FOR rec IN
        SELECT application_id
        FROM applications
        WHERE status = 'PENDING'
        ORDER BY application_id
    LOOP
        CALL pr_assess_application(rec.application_id);
    END LOOP;
END;
$$;

CALL pr_assess_pending();
CALL pr_assess_pending();                           -- rerun: nothing left to assess
SELECT application_id, status FROM applications ORDER BY application_id;
SELECT * FROM decision_audit ORDER BY audit_id;     -- one row per decision

-- Schedule every Monday at 08:00 (pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'assess_pending_weekly',
    '0 8 * * 1',
    $$CALL pr_assess_pending()$$
);
SELECT jobid, jobname, schedule, command FROM cron.job;
