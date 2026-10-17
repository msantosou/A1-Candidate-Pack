-- STEP 08 | Independent, fail-closed reconciliation and identifier checks.
-- Only final groups are tested; this does not establish identity accuracy.
\set ON_ERROR_STOP on
BEGIN;
DROP TABLE IF EXISTS a1.validation_results;
CREATE TABLE a1.validation_results (
  check_name TEXT PRIMARY KEY,
  observed_count BIGINT NOT NULL,
  expected_count BIGINT NOT NULL,
  passed BOOLEAN NOT NULL
);

WITH metrics AS (
  SELECT 'raw_record_count' AS check_name,
         COUNT(*) AS observed_count, 100000::bigint AS expected_count
  FROM a1.raw_patient_records
  UNION ALL
  SELECT 'staging_vs_raw',
         ABS((SELECT COUNT(*) FROM a1.stg_patient_records) -
             (SELECT COUNT(*) FROM a1.raw_patient_records)), 0
  UNION ALL
  SELECT 'mapping_vs_raw',
         ABS((SELECT COUNT(*) FROM a1.person_record_map) -
             (SELECT COUNT(*) FROM a1.raw_patient_records)), 0
  UNION ALL
  SELECT 'missing_source_assignments', COUNT(*), 0
  FROM a1.raw_patient_records r
  LEFT JOIN a1.person_record_map p USING (source_record_key)
  WHERE p.source_record_key IS NULL
  UNION ALL
  SELECT 'extraneous_source_assignments', COUNT(*), 0
  FROM a1.person_record_map p
  LEFT JOIN a1.raw_patient_records r USING (source_record_key)
  WHERE r.source_record_key IS NULL
  UNION ALL
  SELECT 'multiple_person_assignments', COUNT(*), 0
  FROM (
    SELECT source_record_key FROM a1.person_record_map
    GROUP BY source_record_key HAVING COUNT(*) <> 1
  ) duplicates
  UNION ALL
  SELECT 'missing_person_rows', COUNT(*), 0
  FROM (SELECT DISTINCT person_key FROM a1.person_record_map) m
  LEFT JOIN a1.persons p USING (person_key)
  WHERE p.person_key IS NULL
  UNION ALL
  SELECT 'unexpected_person_rows', COUNT(*), 0
  FROM a1.persons p
  LEFT JOIN (SELECT DISTINCT person_key FROM a1.person_record_map) m USING (person_key)
  WHERE m.person_key IS NULL
  UNION ALL
  SELECT 'person_rows_vs_distinct_groups',
         ABS((SELECT COUNT(*) FROM a1.persons) -
             (SELECT COUNT(DISTINCT person_key) FROM a1.person_record_map)), 0
  UNION ALL
  SELECT 'represented_record_count_vs_raw',
         ABS((SELECT COALESCE(SUM(record_count),0) FROM a1.persons) -
             (SELECT COUNT(*) FROM a1.raw_patient_records)), 0
  UNION ALL
  SELECT 'incorrect_person_record_count', COUNT(*), 0
  FROM a1.persons p
  JOIN (SELECT person_key, COUNT(*) AS n FROM a1.person_record_map GROUP BY person_key) x USING (person_key)
  WHERE p.record_count <> x.n
  UNION ALL
  SELECT 'missing_or_empty_record_ids', COUNT(*), 0
  FROM a1.persons WHERE NULLIF(BTRIM(record_ids), '') IS NULL
  UNION ALL
  SELECT 'conflicting_ssn_or_dob_groups', COUNT(*), 0
  FROM (
    SELECT p.person_key
    FROM a1.person_record_map p
    JOIN a1.stg_patient_records s USING (source_record_key)
    GROUP BY p.person_key
    HAVING COUNT(DISTINCT s.ssn_clean) > 1
        OR COUNT(DISTINCT s.dob_clean) > 1
  ) conflicts
  UNION ALL
  SELECT 'conflicting_local_identifiers', COUNT(*), 0
  FROM (
    SELECT p.person_key, s.source_system
    FROM a1.person_record_map p
    JOIN a1.stg_patient_records s USING (source_record_key)
    GROUP BY p.person_key, s.source_system
    HAVING COUNT(DISTINCT s.mrn_clean) > 1
       OR COUNT(DISTINCT s.patient_id_clean) FILTER (WHERE s.patient_id_status='PRESENT') > 1
  ) conflicts
  UNION ALL
  SELECT 'unaccounted_step05_pairs',
         ABS((SELECT COUNT(*) FROM a1.patient_matches) -
             (SELECT COUNT(*) FROM a1.group_merge_audit)), 0
)
INSERT INTO a1.validation_results(check_name, observed_count, expected_count, passed)
SELECT check_name, observed_count, expected_count, observed_count = expected_count
FROM metrics;

DO $check$
DECLARE failed text;
BEGIN
  SELECT STRING_AGG(check_name || '=' || observed_count, '; ' ORDER BY check_name)
  INTO failed FROM a1.validation_results WHERE NOT passed;
  IF failed IS NOT NULL THEN
     RAISE EXCEPTION 'Step 08 validation failed: %', failed;
  END IF;
END $check$;
COMMIT;

\echo 'STEP 08 | Validation results'
SELECT check_name, observed_count, expected_count, passed
FROM a1.validation_results ORDER BY check_name;
\echo 'STEP 08 | Matching coverage (diagnostic; not a pass/fail identity-accuracy metric)'
SELECT COUNT(*) AS accepted_step05_pairs,
       COUNT(*) FILTER (WHERE action='MERGED') AS retained_pairs,
       COUNT(*) FILTER (WHERE action='NOT_MERGED') AS unmerged_pairs
FROM a1.group_merge_audit;
