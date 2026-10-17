-- STEP 06 | Fast, set-based, conservative entity resolution.
-- No recursive closure and no procedural row-by-row loops.
-- Policy: SSN-anchored grouping; SSN-less records may attach only to ONE SSN
-- via a Step 05 accepted pair. Other records remain singletons.
-- Component-wide identifier conflicts cause the WHOLE proposed group to split.
-- Trade-off: conservative false negatives, especially among SSN-less records.
\set ON_ERROR_STOP on
\timing on
BEGIN;
SET LOCAL statement_timeout = '120s';

DROP TABLE IF EXISTS a1.group_merge_audit;
DROP TABLE IF EXISTS a1.person_record_map;

-- Materialize the source keys, identifiers and grouping attributes.
CREATE TEMP TABLE _nodes ON COMMIT DROP AS
SELECT source_record_key, source_system, ssn_clean, dob_clean,
       mrn_clean,
       CASE WHEN patient_id_status = 'PRESENT' THEN patient_id_clean END AS trusted_patient_id
FROM a1.stg_patient_records;
CREATE UNIQUE INDEX ON _nodes(source_record_key);
CREATE INDEX ON _nodes(ssn_clean) WHERE ssn_clean IS NOT NULL;
ANALYZE _nodes;

-- Assign SSN-bearing records their direct SSN anchor.  An SSN by itself
-- is NOT sufficient: group-level conflicts are checked before acceptance.
CREATE TEMP TABLE _assignment ON COMMIT DROP AS
SELECT source_record_key, ssn_clean::text AS anchor, 'SSN'::text AS assignment_reason
FROM _nodes
WHERE ssn_clean IS NOT NULL;
CREATE UNIQUE INDEX ON _assignment(source_record_key);
CREATE INDEX ON _assignment(anchor);

-- SSN-less records may attach if their accepted edges point to precisely ONE
-- SSN anchor. No circular traversals and no inferred multi-hop attachments.
CREATE TEMP TABLE _attachment_candidates ON COMMIT DROP AS
SELECT missing.source_record_key AS source_record_key,
       known.ssn_clean::text AS anchor
FROM a1.patient_matches m
JOIN _nodes a ON a.source_record_key = m.left_key
JOIN _nodes b ON b.source_record_key = m.right_key
CROSS JOIN LATERAL (
  SELECT CASE WHEN a.ssn_clean IS NULL THEN a.source_record_key
              WHEN b.ssn_clean IS NULL THEN b.source_record_key END AS source_record_key
) missing
CROSS JOIN LATERAL (
  SELECT CASE WHEN a.ssn_clean IS NOT NULL THEN a.ssn_clean
              WHEN b.ssn_clean IS NOT NULL THEN b.ssn_clean END AS ssn_clean
) known
WHERE missing.source_record_key IS NOT NULL AND known.ssn_clean IS NOT NULL;
CREATE INDEX ON _attachment_candidates(source_record_key);

INSERT INTO _assignment(source_record_key, anchor, assignment_reason)
SELECT source_record_key, MIN(anchor), 'UNIQUE_SSN_NEIGHBOR'
FROM _attachment_candidates
GROUP BY source_record_key
HAVING COUNT(DISTINCT anchor) = 1;

-- Validate candidate groups against the same hard-constraint policy as
-- the previous script (DOB, SSN and local identifiers by source).
CREATE TEMP TABLE _group_conflicts ON COMMIT DROP AS
WITH glob AS (
  SELECT a.anchor,
         COUNT(DISTINCT n.ssn_clean) > 1 AS bad_ssn,
         COUNT(DISTINCT n.dob_clean) > 1 AS bad_dob
  FROM _assignment a JOIN _nodes n USING(source_record_key)
  GROUP BY a.anchor
), loc AS (
  SELECT anchor, BOOL_OR(mrn_n > 1) AS bad_mrn,
         BOOL_OR(pid_n > 1) AS bad_patient_id
  FROM (
    SELECT a.anchor, n.source_system,
           COUNT(DISTINCT n.mrn_clean) AS mrn_n,
           COUNT(DISTINCT n.trusted_patient_id) AS pid_n
    FROM _assignment a JOIN _nodes n USING(source_record_key)
    GROUP BY a.anchor, n.source_system
  ) q GROUP BY anchor
)
SELECT glob.anchor, bad_ssn, bad_dob, bad_mrn, bad_patient_id,
       (bad_ssn OR bad_dob OR bad_mrn OR bad_patient_id) AS unsafe
FROM glob JOIN loc USING(anchor);
CREATE UNIQUE INDEX ON _group_conflicts(anchor);

-- Unsafe anchors split into singletons; unattached nodes are singletons too.
CREATE TABLE a1.person_record_map AS
WITH effective AS (
    SELECT n.source_record_key,
           CASE WHEN g.unsafe IS FALSE
                THEN 'SSN:' || a.anchor
                ELSE 'ROW:' || n.source_record_key END AS group_key
    FROM _nodes n
    LEFT JOIN _assignment a USING(source_record_key)
    LEFT JOIN _group_conflicts g USING(anchor)
), keyed AS (
    SELECT group_key,
           'P' || LPAD(ROW_NUMBER() OVER (ORDER BY group_key)::text, 7, '0') AS person_key
    FROM (SELECT DISTINCT group_key FROM effective) q
)
SELECT e.source_record_key, k.person_key
FROM effective e JOIN keyed k USING(group_key);
ALTER TABLE a1.person_record_map ADD PRIMARY KEY(source_record_key);
CREATE INDEX ON a1.person_record_map(person_key);

-- Audit each *accepted pair* by whether its endpoints landed together.
CREATE TABLE a1.group_merge_audit AS
SELECT m.left_key, m.right_key, m.decision_reason AS match_rule,
       CASE WHEN l.person_key = r.person_key THEN 'MERGED' ELSE 'NOT_MERGED' END AS action,
       CASE WHEN l.person_key = r.person_key THEN 'SAME_SAFE_SSN_ANCHOR'
            ELSE 'CONSERVATIVE_SSN_ANCHOR_POLICY' END AS reason
FROM a1.patient_matches m
JOIN a1.person_record_map l ON l.source_record_key = m.left_key
JOIN a1.person_record_map r ON r.source_record_key = m.right_key;
ALTER TABLE a1.group_merge_audit ADD PRIMARY KEY(left_key,right_key);

DO $checks$
BEGIN
    IF (SELECT COUNT(*) FROM a1.person_record_map) <> (SELECT COUNT(*) FROM a1.stg_patient_records)
       OR EXISTS (SELECT 1 FROM a1.stg_patient_records s
                  LEFT JOIN a1.person_record_map p USING(source_record_key)
                  WHERE p.source_record_key IS NULL)
       THEN RAISE EXCEPTION 'Step 06 coverage failure'; END IF;
    IF (SELECT COUNT(*) FROM a1.group_merge_audit) <> (SELECT COUNT(*) FROM a1.patient_matches)
       THEN RAISE EXCEPTION 'Step 06 incomplete pair audit'; END IF;
    IF EXISTS (
      SELECT 1 FROM a1.person_record_map p JOIN _nodes n USING(source_record_key)
      GROUP BY p.person_key
      HAVING COUNT(DISTINCT n.ssn_clean)>1 OR COUNT(DISTINCT n.dob_clean)>1
    ) OR EXISTS (
      SELECT 1 FROM a1.person_record_map p JOIN _nodes n USING(source_record_key)
      GROUP BY p.person_key,n.source_system
      HAVING COUNT(DISTINCT n.mrn_clean)>1 OR COUNT(DISTINCT n.trusted_patient_id)>1
    ) THEN RAISE EXCEPTION 'Step 06 hard identifier conflict'; END IF;
END $checks$;
COMMIT;

\echo 'STEP 06 | Reconciliation'
SELECT (SELECT COUNT(*) FROM a1.stg_patient_records) AS input_records,
       (SELECT COUNT(*) FROM a1.person_record_map) AS mapped_records,
       (SELECT COUNT(DISTINCT person_key) FROM a1.person_record_map) AS person_groups;
\echo 'STEP 06 | Pair-level audit'
SELECT action, reason, COUNT(*) AS pairs
FROM a1.group_merge_audit GROUP BY 1,2 ORDER BY 1,2;
\echo 'STEP 06 | Group sizes'
SELECT n_records, COUNT(*) AS persons FROM (
  SELECT person_key, COUNT(*) AS n_records FROM a1.person_record_map GROUP BY 1
) x GROUP BY n_records ORDER BY n_records;
\echo 'NOTE: This SSN-anchored policy is intentionally conservative. No-SSN-only groups are not consolidated.'
