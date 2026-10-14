-- STEP 05: Explainable pairwise candidate generation and conservative matching.
-- Prerequisite: 04_normalize.sql (a1.stg_patient_records).
-- No identity groups are generated here; Step 06 must perform conflict-aware grouping.
-- Run with psql -X -v ON_ERROR_STOP=1 ... -f scripts/sql/05_match_records.sql
-- Rerunnable. Does not modify raw or staging records.
\set ON_ERROR_STOP on
BEGIN;

DROP TABLE IF EXISTS a1.patient_matches;
DROP TABLE IF EXISTS a1.patient_match_candidates;

-- Candidate blocking prevents a quadratic self-join over all 100k records.
-- Scientific-notation patient IDs are included for investigation, never as proof.
CREATE TABLE a1.patient_match_candidates AS
WITH candidate_edges AS (
    -- Shared nine-digit SSN (across or within a source).
    SELECT a.source_record_key AS left_key, b.source_record_key AS right_key,
           'SAME_SSN'::text AS candidate_reason
    FROM a1.stg_patient_records a
    JOIN a1.stg_patient_records b
      ON a.ssn_clean = b.ssn_clean
     AND a.source_record_key < b.source_record_key
    WHERE a.ssn_clean IS NOT NULL

    UNION ALL
    -- MRN is scoped to its issuing source; NEVER join across sources on MRN alone.
    SELECT a.source_record_key, b.source_record_key, 'SAME_LOCAL_MRN'
    FROM a1.stg_patient_records a
    JOIN a1.stg_patient_records b
      ON a.source_system = b.source_system
     AND a.mrn_clean = b.mrn_clean
     AND a.source_record_key < b.source_record_key
    WHERE a.mrn_clean IS NOT NULL

    UNION ALL
    -- Ordinary patient IDs: matching only within the same source namespace.
    SELECT a.source_record_key, b.source_record_key, 'SAME_LOCAL_PATIENT_ID'
    FROM a1.stg_patient_records a
    JOIN a1.stg_patient_records b
      ON a.source_system = b.source_system
     AND a.patient_id_clean = b.patient_id_clean
     AND a.source_record_key < b.source_record_key
    WHERE a.patient_id_status = 'PRESENT'
      AND b.patient_id_status = 'PRESENT'

    UNION ALL
    -- Rounded scientific-notation values: review candidates only.
    SELECT a.source_record_key, b.source_record_key, 'SAME_SCIENTIFIC_PATIENT_ID'
    FROM a1.stg_patient_records a
    JOIN a1.stg_patient_records b
      ON a.source_system = b.source_system
     AND a.patient_id_clean = b.patient_id_clean
     AND a.source_record_key < b.source_record_key
    WHERE a.patient_id_status = 'SCIENTIFIC_NOTATION'
      AND b.patient_id_status = 'SCIENTIFIC_NOTATION'

    UNION ALL
    -- Exact demographics plus phone: a fall-back block, not proof by itself.
    SELECT a.source_record_key, b.source_record_key, 'NAME_DOB_PHONE'
    FROM a1.stg_patient_records a
    JOIN a1.stg_patient_records b
      ON a.first_name_clean = b.first_name_clean
     AND a.last_name_clean = b.last_name_clean
     AND a.dob_clean = b.dob_clean
     AND a.phone_clean = b.phone_clean
     AND a.source_record_key < b.source_record_key
    WHERE a.first_name_clean IS NOT NULL
      AND a.last_name_clean IS NOT NULL
      AND a.dob_clean IS NOT NULL
      AND a.phone_clean IS NOT NULL

    UNION ALL
    -- Same demographics plus email: another fall-back block.
    SELECT a.source_record_key, b.source_record_key, 'NAME_DOB_EMAIL'
    FROM a1.stg_patient_records a
    JOIN a1.stg_patient_records b
      ON a.first_name_clean = b.first_name_clean
     AND a.last_name_clean = b.last_name_clean
     AND a.dob_clean = b.dob_clean
     AND a.email_clean = b.email_clean
     AND a.source_record_key < b.source_record_key
    WHERE a.first_name_clean IS NOT NULL
      AND a.last_name_clean IS NOT NULL
      AND a.dob_clean IS NOT NULL
      AND a.email_clean IS NOT NULL
), reasons AS (
    SELECT left_key, right_key,
           array_agg(DISTINCT candidate_reason ORDER BY candidate_reason) AS candidate_reasons
    FROM candidate_edges
    GROUP BY left_key, right_key
), evaluated AS (
    SELECT r.left_key, r.right_key, r.candidate_reasons,
           a.source_system AS left_source, b.source_system AS right_source,
           (a.ssn_clean IS NOT NULL AND b.ssn_clean IS NOT NULL
            AND a.ssn_clean <> b.ssn_clean) AS ssn_conflict,
           (a.dob_clean IS NOT NULL AND b.dob_clean IS NOT NULL
            AND a.dob_clean <> b.dob_clean) AS dob_conflict,
           (a.ssn_clean IS NOT NULL AND a.ssn_clean = b.ssn_clean) AS same_ssn,
           (a.source_system = b.source_system AND a.mrn_clean IS NOT NULL
            AND a.mrn_clean = b.mrn_clean) AS same_local_mrn,
           (a.source_system = b.source_system
            AND a.patient_id_status = 'PRESENT' AND b.patient_id_status = 'PRESENT'
            AND a.patient_id_clean = b.patient_id_clean) AS same_local_patient_id,
           (a.first_name_clean IS NOT NULL AND a.first_name_clean = b.first_name_clean) AS same_first_name,
           (a.last_name_clean IS NOT NULL AND a.last_name_clean = b.last_name_clean) AS same_last_name,
           (a.dob_clean IS NOT NULL AND a.dob_clean = b.dob_clean) AS same_dob,
           (a.phone_clean IS NOT NULL AND a.phone_clean = b.phone_clean) AS same_phone,
           (a.email_clean IS NOT NULL AND a.email_clean = b.email_clean) AS same_email,
           ('SAME_SCIENTIFIC_PATIENT_ID' = ANY(r.candidate_reasons)) AS scientific_id_candidate
    FROM reasons r
    JOIN a1.stg_patient_records a ON a.source_record_key = r.left_key
    JOIN a1.stg_patient_records b ON b.source_record_key = r.right_key
)
SELECT e.*,
       CASE
          WHEN ssn_conflict THEN 'REJECT'
          WHEN dob_conflict THEN 'REVIEW'
          -- Same SSN and compatible DOB, with at least one independent demographic/contact signal.
          WHEN same_ssn AND (same_first_name OR same_last_name OR same_phone OR same_email)
            THEN 'ACCEPT_PAIR'
          -- Local identifiers must be supported by both name and DOB agreement.
          WHEN (same_local_mrn OR same_local_patient_id)
               AND same_first_name AND same_last_name AND same_dob
            THEN 'ACCEPT_PAIR'
          -- Demographics and contact info alone are not enough for automatic person merging.
          ELSE 'REVIEW'
       END AS match_decision,
       CASE
          WHEN ssn_conflict THEN 'CONFLICTING_NON_NULL_SSN'
          WHEN dob_conflict THEN 'CONFLICTING_NON_NULL_DOB'
          WHEN same_ssn AND (same_first_name OR same_last_name OR same_phone OR same_email)
            THEN 'SSN_WITH_SUPPORTING_EVIDENCE'
          WHEN (same_local_mrn OR same_local_patient_id)
               AND same_first_name AND same_last_name AND same_dob
            THEN 'LOCAL_ID_WITH_EXACT_NAME_DOB'
          WHEN scientific_id_candidate THEN 'SCIENTIFIC_ID_REQUIRES_INDEPENDENT_VERIFICATION'
          ELSE 'INSUFFICIENT_EVIDENCE'
       END AS decision_reason
FROM evaluated e;

ALTER TABLE a1.patient_match_candidates
    ADD PRIMARY KEY (left_key, right_key);
CREATE INDEX idx_a1_match_candidates_decision
    ON a1.patient_match_candidates (match_decision, decision_reason);

-- Convenience view/table for the next stage. Accepted pairs are NOT final entities:
-- transitive grouping may still introduce conflicts and must be checked at Step 06.
CREATE TABLE a1.patient_matches AS
SELECT left_key, right_key, candidate_reasons, decision_reason
FROM a1.patient_match_candidates
WHERE match_decision = 'ACCEPT_PAIR';
ALTER TABLE a1.patient_matches ADD PRIMARY KEY (left_key, right_key);

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM a1.patient_matches m
    JOIN a1.stg_patient_records a ON a.source_record_key = m.left_key
    JOIN a1.stg_patient_records b ON b.source_record_key = m.right_key
    WHERE a.ssn_clean IS NOT NULL AND b.ssn_clean IS NOT NULL
      AND a.ssn_clean <> b.ssn_clean
  ) THEN
    RAISE EXCEPTION 'Accepted pairs include conflicting SSNs';
  END IF;
END $$;
COMMIT;

\echo 'STEP 05 | Candidate/decision summary'
SELECT match_decision, decision_reason, count(*) AS candidate_pairs
FROM a1.patient_match_candidates
GROUP BY 1,2 ORDER BY 1,2;

\echo 'STEP 05 | Candidate volume and accepted pair coverage'
SELECT
 (SELECT count(*) FROM a1.patient_match_candidates) AS candidate_pairs,
 (SELECT count(*) FROM a1.patient_matches) AS accepted_pairs,
 (SELECT count(*) FROM a1.stg_patient_records) AS input_records,
 (SELECT count(*) FROM (
    SELECT left_key AS k FROM a1.patient_matches
    UNION
    SELECT right_key FROM a1.patient_matches
  ) involved) AS records_in_accepted_pairs;

\echo 'STEP 05 | Candidate rule distribution (pairs may have multiple reasons)'
SELECT reason, count(*) AS pairs
FROM a1.patient_match_candidates c
CROSS JOIN LATERAL unnest(c.candidate_reasons) AS reason
GROUP BY reason ORDER BY pairs DESC, reason;

\echo 'STEP 05 | SAFETY WARNING: do not export final persons by connected components yet.'
\echo 'Step 06 must enforce group-level conflicts and preserve all unpaired records.'
