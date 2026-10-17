-- Step 03: READ-ONLY raw patient data profiling (PostgreSQL / psql)
-- Run: psql -X -v ON_ERROR_STOP=1 -h localhost -U a1_user -d a1_patient_db \
--          -f scripts/sql/03_data_profiling.sql -o data/output/03_data_profiling.txt
-- Never edits the raw layer. This is exploration, not entity resolution.
\pset pager off
\echo '01 | TOTAL AND PER-SOURCE COUNTS'
SELECT source_system, COUNT(*) AS rows_loaded, COUNT(DISTINCT source_record_key) AS distinct_source_keys,
       COUNT(record_id) AS nonempty_record_ids, COUNT(DISTINCT record_id) AS distinct_record_ids
FROM a1.raw_patient_records GROUP BY ROLLUP(source_system)
ORDER BY source_system NULLS LAST;

\echo '02 | REQUIRED 100K RECONCILIATION'
SELECT COUNT(*) AS actual_rows, 100000 AS expected_rows,
       COUNT(*) = 100000 AS expected_count_pass,
       COUNT(*) = COUNT(DISTINCT source_record_key) AS unique_source_keys_pass
FROM a1.raw_patient_records;

\echo '03 | MISSINGNESS BY SOURCE AND FIELD (EMPTY / WHITESPACE IS MISSING)'
WITH fields AS (
  SELECT r.source_system, v.field_name, NULLIF(BTRIM(v.value), '') AS field_value
  FROM a1.raw_patient_records r
  CROSS JOIN LATERAL (VALUES
    ('record_id',r.record_id),('first_name',r.first_name),('middle_name',r.middle_name),
    ('last_name',r.last_name),('suffix',r.suffix),('dob',r.dob),('ssn',r.ssn),
    ('mrn',r.mrn),('patient_id',r.patient_id),('address',r.address),
    ('city',r.city),('state',r.state),('zip',r.zip),('phone',r.phone),('email',r.email)
  ) AS v(field_name,value)
)
SELECT source_system, field_name, COUNT(*) AS total,
       COUNT(*) FILTER (WHERE field_value IS NULL) AS missing,
       ROUND(100.0 * COUNT(*) FILTER (WHERE field_value IS NULL) / NULLIF(COUNT(*),0),2) AS pct_missing,
       COUNT(DISTINCT field_value) AS distinct_nonmissing
FROM fields GROUP BY source_system, field_name ORDER BY source_system, field_name;

\echo '04 | REPEATED RECORD IDS WITHIN THE SAME SOURCE'
SELECT source_system, record_id, COUNT(*) AS rows_with_id
FROM a1.raw_patient_records
WHERE NULLIF(BTRIM(record_id),'') IS NOT NULL
GROUP BY source_system, record_id HAVING COUNT(*) > 1
ORDER BY rows_with_id DESC, source_system, record_id LIMIT 30;

\echo '05 | EXACT DUPLICATE PATIENT ATTRIBUTES WITHIN EACH SOURCE (EXCLUDING RECORD ID)'
WITH groups AS (
  SELECT source_system, first_name, middle_name, last_name, suffix, dob, ssn, mrn,
         patient_id, address, city, state, zip, phone, email, COUNT(*) AS n
  FROM a1.raw_patient_records
  GROUP BY source_system, first_name, middle_name, last_name, suffix, dob, ssn, mrn,
           patient_id, address, city, state, zip, phone, email
  HAVING COUNT(*) > 1
)
SELECT source_system, COUNT(*) AS repeated_groups, SUM(n) AS records_in_repeated_groups,
       SUM(n - 1) AS excess_records
FROM groups GROUP BY source_system ORDER BY source_system;

\echo '06 | IDENTIFIER REUSE WITHIN SOURCE (DESCRIPTIVE, NOT AUTOMATIC CONFLICTS)'
WITH identifiers AS (
 SELECT source_system, 'ssn' AS kind, NULLIF(REGEXP_REPLACE(COALESCE(ssn,''),'[^0-9]','','g'),'') AS val FROM a1.raw_patient_records
 UNION ALL SELECT source_system, 'mrn', NULLIF(BTRIM(mrn),'') FROM a1.raw_patient_records
 UNION ALL SELECT source_system, 'patient_id', NULLIF(BTRIM(patient_id),'') FROM a1.raw_patient_records
), recurring AS (
 SELECT source_system, kind, val, COUNT(*) AS n FROM identifiers WHERE val IS NOT NULL
 GROUP BY source_system,kind,val HAVING COUNT(*) > 1
)
SELECT source_system, kind, COUNT(*) AS reused_values, SUM(n) AS associated_records,
       MAX(n) AS max_records_per_value
FROM recurring GROUP BY source_system,kind ORDER BY source_system,kind;

\echo '07 | DATE FORMAT INVENTORY (NOT DATE VALIDITY)'
SELECT source_system,
 CASE WHEN dob IS NULL OR BTRIM(dob) = '' THEN 'missing'
      WHEN dob ~ '^\d{4}-\d{2}-\d{2}$' THEN 'yyyy-mm-dd'
      WHEN dob ~ '^\d{1,2}/\d{1,2}/\d{4}$' THEN 'mm/dd/yyyy_or_dd/mm/yyyy'
      ELSE 'other' END AS format,
 COUNT(*) AS n
FROM a1.raw_patient_records GROUP BY 1,2 ORDER BY 1,2;

\echo '08 | SSN FORMAT INVENTORY (FORMAT ONLY, NOT SSA-VALIDITY)'
WITH s AS (SELECT source_system, NULLIF(BTRIM(ssn),'') AS raw_ssn,
 REGEXP_REPLACE(COALESCE(ssn,''),'[^0-9]','','g') AS ssn_digits
 FROM a1.raw_patient_records)
SELECT source_system,
 CASE WHEN raw_ssn IS NULL THEN 'missing'
      WHEN raw_ssn ~ '^[0-9]{3}-[0-9]{2}-[0-9]{4}$' THEN 'hyphenated_9_digits'
      WHEN raw_ssn ~ '^[0-9]{9}$' THEN 'plain_9_digits'
      WHEN LENGTH(ssn_digits) = 9 THEN '9_digits_with_other_formatting'
      ELSE 'invalid_digit_count' END AS ssn_shape, COUNT(*) AS n
FROM s GROUP BY 1,2 ORDER BY 1,2;

\echo '09 | CROSS-SOURCE SSN OVERLAP (CANDIDATES, NOT CONFIRMED MATCHES)'
WITH source_ssns AS (
 SELECT source_system, REGEXP_REPLACE(ssn,'[^0-9]','','g') AS digits
 FROM a1.raw_patient_records WHERE NULLIF(BTRIM(ssn),'') IS NOT NULL
), valid_ssns AS (
 SELECT DISTINCT source_system,digits FROM source_ssns WHERE LENGTH(digits) = 9
)
SELECT COUNT(*) AS distinct_ssns_present_in_both_sources
FROM (SELECT digits FROM valid_ssns GROUP BY digits HAVING COUNT(DISTINCT source_system) = 2) x;

\echo '10 | SAME SOURCE + IDENTIFIER WITH DIFFERENT NONEMPTY SSNs (REVIEW CANDIDATES)'
WITH r AS (
 SELECT source_system, 'mrn' AS id_type, NULLIF(BTRIM(mrn),'') AS id_value,
        NULLIF(REGEXP_REPLACE(COALESCE(ssn,''),'[^0-9]','','g'),'') AS ssn_digits
 FROM a1.raw_patient_records
 UNION ALL
 SELECT source_system, 'patient_id', NULLIF(BTRIM(patient_id),''),
        NULLIF(REGEXP_REPLACE(COALESCE(ssn,''),'[^0-9]','','g'),'')
 FROM a1.raw_patient_records
)
SELECT source_system,id_type,COUNT(*) AS potentially_conflicting_identifier_values
FROM (
 SELECT source_system,id_type,id_value
 FROM r WHERE id_value IS NOT NULL AND LENGTH(ssn_digits) = 9
 GROUP BY source_system,id_type,id_value HAVING COUNT(DISTINCT ssn_digits) > 1
) conflicts GROUP BY source_system,id_type ORDER BY source_system,id_type;

\echo '11 | IDENTICAL NAME + DOB WITH CONFLICTING NONEMPTY SSNs (REVIEW CANDIDATES)'
-- Compare only within each source here because DOB formats differ across sources.
WITH names AS (
 SELECT source_system, UPPER(BTRIM(first_name)) AS fn,
        UPPER(BTRIM(last_name)) AS ln, BTRIM(dob) AS birth_date,
        REGEXP_REPLACE(COALESCE(ssn,''),'[^0-9]','','g') AS ssn_digits
 FROM a1.raw_patient_records
), groups AS (
 SELECT source_system,fn,ln,birth_date,COUNT(*) AS n
 FROM names WHERE fn <> '' AND ln <> '' AND birth_date <> '' AND LENGTH(ssn_digits)=9
 GROUP BY 1,2,3,4 HAVING COUNT(DISTINCT ssn_digits)>1
)
SELECT source_system,COUNT(*) AS potentially_ambiguous_groups,SUM(n) AS rows_in_groups
FROM groups GROUP BY source_system ORDER BY source_system;

\echo '12 | RAW PAYLOAD FIELD KEYS (CHECK UNEXPECTED INPUT COLUMNS)'
SELECT source_system, k.key AS original_field, COUNT(*) AS rows_with_field
FROM a1.raw_patient_records r
CROSS JOIN LATERAL jsonb_object_keys(r.raw_payload) AS k(key)
GROUP BY 1,2 ORDER BY 1,2;
