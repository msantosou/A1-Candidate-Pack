CREATE SCHEMA IF NOT EXISTS a1;

CREATE TABLE IF NOT EXISTS a1.raw_patient_records (
    source_record_key TEXT PRIMARY KEY,
    source_system TEXT NOT NULL,
    source_row_number INTEGER NOT NULL,
    record_id TEXT,
    first_name TEXT,
    middle_name TEXT,
    last_name TEXT,
    suffix TEXT,
    dob TEXT,
    ssn TEXT,
    mrn TEXT,
    patient_id TEXT,
    address TEXT,
    city TEXT,
    state TEXT,
    zip TEXT,
    phone TEXT,
    email TEXT,
    raw_payload JSONB NOT NULL,
    ingested_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (source_system, source_row_number)
);

CREATE INDEX IF NOT EXISTS idx_raw_source ON a1.raw_patient_records (source_system);
CREATE INDEX IF NOT EXISTS idx_raw_record_id ON a1.raw_patient_records (source_system, record_id);
