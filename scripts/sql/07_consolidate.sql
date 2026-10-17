-- STEP 07 | Consolidate mapped source records into the required person schema.
-- Requires: a1.raw_patient_records, a1.stg_patient_records, a1.person_record_map.
-- Preserves distinct nonempty source values, with consistent DOB and SSN display.
-- Original records remain unchanged. Rerunnable.
\set ON_ERROR_STOP on
BEGIN;
DROP TABLE IF EXISTS a1.persons;

-- First compute record identifiers and true source-record counts per group.
CREATE TEMP TABLE _person_counts ON COMMIT DROP AS
SELECT p.person_key,
       STRING_AGG(r.record_id, ' | ' ORDER BY r.source_system, r.record_id, r.source_record_key) AS record_ids,
       COUNT(*)::integer AS record_count
FROM a1.person_record_map p
JOIN a1.raw_patient_records r USING (source_record_key)
GROUP BY p.person_key;

-- Unpivot fields once and aggregate DISTINCT nonempty displayed values.
-- Names/contact fields retain original meaningful differences; SSN/DOB get the
-- presentation format required by the challenge, but fallback raw text is kept
-- when normalization was not possible.
CREATE TEMP TABLE _person_attributes ON COMMIT DROP AS
WITH flat AS (
  SELECT p.person_key, f.field, NULLIF(BTRIM(f.value), '') AS value
  FROM a1.person_record_map p
  JOIN a1.raw_patient_records r USING (source_record_key)
  JOIN a1.stg_patient_records s USING (source_record_key)
  CROSS JOIN LATERAL (VALUES
     ('first_name', r.first_name),
     ('middle_name', r.middle_name),
     ('last_name', r.last_name),
     ('suffix', r.suffix),
     ('dob', CASE WHEN s.dob_clean IS NOT NULL THEN TO_CHAR(s.dob_clean, 'YYYY-MM-DD') ELSE r.dob END),
     ('ssn', CASE WHEN s.ssn_clean IS NOT NULL THEN
          SUBSTRING(s.ssn_clean FROM 1 FOR 3) || '-' ||
          SUBSTRING(s.ssn_clean FROM 4 FOR 2) || '-' ||
          SUBSTRING(s.ssn_clean FROM 6 FOR 4) ELSE r.ssn END),
     ('mrn', r.mrn),
     ('patient_id', r.patient_id),
     ('address', r.address),
     ('city', r.city),
     ('state', r.state),
     ('zip', r.zip),
     ('phone', r.phone),
     ('email', r.email)
  ) AS f(field, value)
), aggregated AS (
  SELECT person_key, field,
         STRING_AGG(DISTINCT value, ' | ' ORDER BY value) AS values_joined
  FROM flat
  WHERE value IS NOT NULL
  GROUP BY person_key, field
)
SELECT person_key,
       MAX(values_joined) FILTER (WHERE field='first_name') AS first_name,
       MAX(values_joined) FILTER (WHERE field='middle_name') AS middle_name,
       MAX(values_joined) FILTER (WHERE field='last_name') AS last_name,
       MAX(values_joined) FILTER (WHERE field='suffix') AS suffix,
       MAX(values_joined) FILTER (WHERE field='dob') AS dob,
       MAX(values_joined) FILTER (WHERE field='ssn') AS ssn,
       MAX(values_joined) FILTER (WHERE field='mrn') AS mrn,
       MAX(values_joined) FILTER (WHERE field='patient_id') AS patient_id,
       MAX(values_joined) FILTER (WHERE field='address') AS address,
       MAX(values_joined) FILTER (WHERE field='city') AS city,
       MAX(values_joined) FILTER (WHERE field='state') AS state,
       MAX(values_joined) FILTER (WHERE field='zip') AS zip,
       MAX(values_joined) FILTER (WHERE field='phone') AS phone,
       MAX(values_joined) FILTER (WHERE field='email') AS email
FROM aggregated
GROUP BY person_key;

CREATE TABLE a1.persons AS
SELECT c.person_key, c.record_ids,
       a.first_name, a.middle_name, a.last_name, a.suffix, a.dob,
       a.ssn, a.mrn, a.patient_id, a.address, a.city, a.state,
       a.zip, a.phone, a.email, c.record_count
FROM _person_counts c
LEFT JOIN _person_attributes a USING (person_key);
ALTER TABLE a1.persons ADD PRIMARY KEY (person_key);

DO $check$
BEGIN
  IF (SELECT COUNT(*) FROM a1.persons) <> (SELECT COUNT(DISTINCT person_key) FROM a1.person_record_map)
    THEN RAISE EXCEPTION 'Step 07 failed: wrong number of person rows'; END IF;
  IF (SELECT COALESCE(SUM(record_count),0) FROM a1.persons) <> (SELECT COUNT(*) FROM a1.raw_patient_records)
    THEN RAISE EXCEPTION 'Step 07 failed: source records not reconciled'; END IF;
  IF EXISTS (SELECT 1 FROM a1.persons WHERE record_ids IS NULL OR record_count < 1)
    THEN RAISE EXCEPTION 'Step 07 failed: missing record IDs or invalid count'; END IF;
END $check$;
COMMIT;

\echo 'STEP 07 | Consolidation summary'
SELECT COUNT(*) AS persons, SUM(record_count) AS represented_records,
       COUNT(*) FILTER (WHERE record_count > 1) AS multi_record_persons,
       MAX(record_count) AS max_group_size
FROM a1.persons;
