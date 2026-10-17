-- Step 04: Normalize patient data for candidate matching.
-- PostgreSQL. Raw source values remain untouched in a1.raw_patient_records.
-- Rerunnable: replaces the staging table within a transaction.
BEGIN;

CREATE SCHEMA IF NOT EXISTS a1;

-- Parse explicitly recognized US DOB formats. Invalid dates become NULL.
-- Two-digit year rule (exercise convention): 00..26 => 2000..2026; 27..99 => 1927..1999.
-- This cutoff is an assumption that should be stated in NOTES.docx.
CREATE OR REPLACE FUNCTION a1.try_parse_dob(raw_value text)
RETURNS date LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    s text := btrim(raw_value);
    y int;
    m int;
    d int;
    parsed date;
    parts text[];
BEGIN
    IF s IS NULL OR s = '' THEN RETURN NULL; END IF;
    IF s ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN
        y := substring(s,1,4)::int;
        m := substring(s,6,2)::int;
        d := substring(s,9,2)::int;
    ELSIF s ~ '^[0-9]{1,2}/[0-9]{1,2}/[0-9]{4}$' THEN
        parts := string_to_array(s, '/');
        m := parts[1]::int; d := parts[2]::int; y := parts[3]::int;
    ELSIF s ~ '^[0-9]{1,2}/[0-9]{1,2}/[0-9]{2}$' THEN
        parts := string_to_array(s, '/');
        m := parts[1]::int; d := parts[2]::int; y := parts[3]::int;
        y := CASE WHEN y <= 26 THEN 2000 + y ELSE 1900 + y END;
    ELSE
        RETURN NULL;
    END IF;
    IF y < 1900 OR y > 2026 OR m NOT BETWEEN 1 AND 12 OR d NOT BETWEEN 1 AND 31 THEN
        RETURN NULL;
    END IF;
    BEGIN
        parsed := make_date(y, m, d);
    EXCEPTION WHEN datetime_field_overflow THEN
        RETURN NULL;
    END;
    IF parsed > DATE '2026-10-14' THEN RETURN NULL; END IF;
    RETURN parsed;
END;
$$;

DROP TABLE IF EXISTS a1.stg_patient_records;

CREATE TABLE a1.stg_patient_records AS
WITH trimmed AS (
  SELECT r.*,
    NULLIF(btrim(r.first_name), '') AS first_name_trim,
    NULLIF(btrim(r.middle_name), '') AS middle_name_trim,
    NULLIF(btrim(r.last_name), '') AS last_name_trim,
    NULLIF(btrim(r.suffix), '') AS suffix_trim,
    NULLIF(btrim(r.dob), '') AS dob_trim,
    NULLIF(btrim(r.ssn), '') AS ssn_trim,
    NULLIF(btrim(r.mrn), '') AS mrn_trim,
    NULLIF(btrim(r.patient_id), '') AS patient_id_trim,
    NULLIF(btrim(r.address), '') AS address_trim,
    NULLIF(btrim(r.city), '') AS city_trim,
    NULLIF(btrim(r.state), '') AS state_trim,
    NULLIF(btrim(r.zip), '') AS zip_trim,
    NULLIF(btrim(r.phone), '') AS phone_trim,
    NULLIF(btrim(r.email), '') AS email_trim
  FROM a1.raw_patient_records AS r
), standardized AS (
  SELECT t.*,
    a1.try_parse_dob(dob_trim) AS parsed_dob,
    regexp_replace(coalesce(ssn_trim,''), '[^0-9]', '', 'g') AS ssn_digits,
    regexp_replace(coalesce(phone_trim,''), '[^0-9]', '', 'g') AS phone_digits
  FROM trimmed AS t
)
SELECT
  source_record_key,
  source_system,
  record_id,
  upper(regexp_replace(first_name_trim, '[[:space:]]+', ' ', 'g')) AS first_name_clean,
  upper(regexp_replace(middle_name_trim, '[[:space:]]+', ' ', 'g')) AS middle_name_clean,
  upper(regexp_replace(last_name_trim, '[[:space:]]+', ' ', 'g')) AS last_name_clean,
  upper(regexp_replace(suffix_trim, '[[:space:]]+', ' ', 'g')) AS suffix_clean,
  parsed_dob AS dob_clean,
  CASE
    WHEN dob_trim IS NULL THEN 'MISSING'
    WHEN parsed_dob IS NULL THEN 'INVALID_OR_UNSUPPORTED'
    ELSE 'VALID'
  END AS dob_status,
  CASE WHEN ssn_trim IS NOT NULL AND length(ssn_digits) = 9
       THEN ssn_digits ELSE NULL END AS ssn_clean,
  CASE
    WHEN ssn_trim IS NULL THEN 'MISSING'
    WHEN length(ssn_digits) = 9 THEN 'FORMAT_VALID'
    ELSE 'INVALID_FORMAT'
  END AS ssn_status,
  mrn_trim AS mrn_clean,
  -- Deliberately preserve scientific notation as the original string.
  -- Never round, expand, or cast this identity field to numeric.
  patient_id_trim AS patient_id_clean,
  CASE
    WHEN patient_id_trim IS NULL THEN 'MISSING'
    WHEN patient_id_trim ~* '^[+-]?[0-9]+(\.[0-9]+)?[e][+-]?[0-9]+$'
      THEN 'SCIENTIFIC_NOTATION'
    ELSE 'PRESENT'
  END AS patient_id_status,
  upper(regexp_replace(address_trim, '[[:space:]]+', ' ', 'g')) AS address_clean,
  upper(regexp_replace(city_trim, '[[:space:]]+', ' ', 'g')) AS city_clean,
  upper(state_trim) AS state_clean,
  zip_trim AS zip_clean,
  CASE WHEN length(phone_digits) = 10 THEN phone_digits
       WHEN length(phone_digits) = 11 AND left(phone_digits, 1) = '1' THEN right(phone_digits, 10)
       ELSE NULL END AS phone_clean,
  CASE WHEN phone_trim IS NULL THEN 'MISSING'
       WHEN length(phone_digits) = 10 OR (length(phone_digits) = 11 AND left(phone_digits, 1) = '1') THEN 'FORMAT_VALID'
       ELSE 'INVALID_FORMAT' END AS phone_status,
  lower(email_trim) AS email_clean
FROM standardized;

ALTER TABLE a1.stg_patient_records ADD PRIMARY KEY (source_record_key);
CREATE INDEX idx_a1_stg_ssn ON a1.stg_patient_records (ssn_clean) WHERE ssn_clean IS NOT NULL;
CREATE INDEX idx_a1_stg_mrn ON a1.stg_patient_records (source_system, mrn_clean) WHERE mrn_clean IS NOT NULL;
CREATE INDEX idx_a1_stg_patient_id ON a1.stg_patient_records (source_system, patient_id_clean) WHERE patient_id_clean IS NOT NULL;
CREATE INDEX idx_a1_stg_demographics ON a1.stg_patient_records (last_name_clean, first_name_clean, dob_clean);

DO $$
DECLARE raw_n bigint; stage_n bigint; missing_n bigint;
BEGIN
  SELECT count(*) INTO raw_n FROM a1.raw_patient_records;
  SELECT count(*) INTO stage_n FROM a1.stg_patient_records;
  SELECT count(*) INTO missing_n
    FROM a1.raw_patient_records r
    LEFT JOIN a1.stg_patient_records s USING (source_record_key)
    WHERE s.source_record_key IS NULL;
  IF raw_n <> stage_n OR missing_n <> 0 THEN
    RAISE EXCEPTION 'Stage reconciliation failed: raw %, stage %, missing %', raw_n, stage_n, missing_n;
  END IF;
END $$;
COMMIT;

\echo 'STEP 04 | Per-source row counts'
SELECT source_system, count(*) AS n FROM a1.stg_patient_records GROUP BY 1 ORDER BY 1;
\echo 'STEP 04 | Quality flags'
SELECT source_system, 'dob' AS field, dob_status AS status, count(*) AS n FROM a1.stg_patient_records GROUP BY 1,2,3
UNION ALL
SELECT source_system, 'ssn', ssn_status, count(*) FROM a1.stg_patient_records GROUP BY 1,2,3
UNION ALL
SELECT source_system, 'patient_id', patient_id_status, count(*) FROM a1.stg_patient_records GROUP BY 1,2,3
UNION ALL
SELECT source_system, 'phone', phone_status, count(*) FROM a1.stg_patient_records GROUP BY 1,2,3
ORDER BY 1,2,3;
\echo 'STEP 04 | Patient IDs in scientific notation (counts only)'
SELECT source_system, count(*) AS scientific_notation_count
FROM a1.stg_patient_records WHERE patient_id_status='SCIENTIFIC_NOTATION'
GROUP BY source_system ORDER BY source_system;
