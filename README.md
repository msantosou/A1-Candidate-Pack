# A1 Candidate Pack — Patient Record Deduplication

A reproducible **Python + PostgreSQL** approach to patient identity resolution for the Assessment First take-home exercise. The two supplied datasets are synthetic. This repository preserves every input row, prepares normalized identifiers, evaluates explainable candidate matches, builds conservative person groups, validates them, and exports `persons.csv`.

**Important scope limitation:** The current Step 06 uses conservative SSN-anchored grouping, not general conflict-aware graph optimization. Some accepted pairs remain separated (last observed: **3,772**). Passing validation confirms structural and identifier-policy consistency, **not** perfect deduplication precision/recall. These numbers are from a previous run; rerun the pipeline to confirm your current output.

## Inputs and outputs

| File | Format | Expected input rows | Role |
|---|---|---:|---|
| `data/input/Clinic_EHR_Export.csv` | CSV | 65,056 | Clinic patient export |
| `data/input/Billing_System_Export.xlsx` | Excel | 34,944 | Billing-system export |
| **Total** | | **100,000** | All rows retained |

Input file names are case-sensitive on Linux. Source files are excluded from Git. The pipeline exports **`data/output/persons.csv`**, plus step-specific diagnostic reports. Generated output is also excluded from Git; deliver it to the assessor separately.

The output columns, in order, are:

`person_key, record_ids, first_name, middle_name, last_name, suffix, dob, ssn, mrn, patient_id, address, city, state, zip, phone, email, record_count`

For a person with multiple distinct values, the output joins values using ` | `. `record_ids` lists source Record IDs, and `record_count` counts *source rows*, not distinct attribute values. Valid DOBs use `YYYY-MM-DD`; valid SSNs are formatted `###-##-####`.

## Requirements and setup (Ubuntu)

- Python 3.10+ and `python3-venv`
- PostgreSQL server and `psql` command-line client
- A PostgreSQL database and a user that can create schema/tables in it

```bash
cd /home/datalab/projects/A1-Candidate-Pack
python3 -m venv .venv_a1
source .venv_a1/bin/activate
python -m pip install -r requirements.txt
```

Example PostgreSQL initial provisioning (run only if needed):

```bash
sudo -u postgres psql -c "CREATE USER a1_user WITH PASSWORD 'CHOOSE_A_LOCAL_PASSWORD';"
sudo -u postgres psql -c "CREATE DATABASE a1_patient_db OWNER a1_user;"
```

Configure credentials (do not commit `.env`):

```bash
cp .env.example .env
# Edit .env and set DB_PASSWORD to your local database password.
psql -h localhost -U a1_user -d a1_patient_db -c 'SELECT current_database();'
```

Place the original datasets in `data/input/`, **without converting them in a spreadsheet editor** (to avoid identifier precision loss).

## Run the entire pipeline

```bash
source .venv_a1/bin/activate
python run_pipeline.py
```

The runner reads `.env`, invokes Python using the current interpreter, invokes `psql` with `ON_ERROR_STOP=1`, saves each SQL report into `data/output/`, prints stage timings, and **stops at the first failure**. It does not log your database password.

For iterative development (only when earlier tables already exist and are current):

```bash
python run_pipeline.py --from-step 4
python run_pipeline.py --skip-profiling
python run_pipeline.py --from-step 7
```

**Step 01 is executed automatically by the Step 02 ingestion script:** `02_ingest.py` reads the schema file `01_create_tables.sql`, loads the two sources and checks counts. Do not execute Step 01 again unless you need a separate schema inspection.

## Pipeline stages

| Step | File | Logic and output |
|---|---|---|
| 01 | `scripts/sql/01_create_tables.sql` | Defines `a1.raw_patient_records`; applied by ingestion |
| 02 | `scripts/02_ingest.py` | Maps CSV/XLSX columns; loads 100k unchanged source rows, plus original `raw_payload` JSONB; technical source keys |
| 03 | `scripts/sql/03_data_profiling.sql` | Read-only count, nullness, duplicate, identifier-format, cross-source overlap and ambiguity diagnostics |
| 04 | `scripts/sql/04_normalize.sql` | Creates `a1.stg_patient_records` with standardized names, DOB, SSN, phone and status flags; raw remains untouched |
| 05 | `scripts/sql/05_match_records.sql` | Creates `a1.patient_match_candidates` and provisionally accepted `a1.patient_matches` |
| 06 | `scripts/sql/06_resolve_entities.sql` | Conservative, set-based SSN anchor plus uniquely attached missing-SSN records; outputs `a1.person_record_map` and `a1.group_merge_audit` |
| 07 | `scripts/sql/07_consolidate.sql` | Creates `a1.persons`; aggregates record IDs and all distinct nonempty attribute values |
| 08 | `scripts/sql/08_validate.sql` | Writes 15 checks to `a1.validation_results`, raises on failure |
| 09 | `scripts/09_export.py` | Requires the validation table to pass; copies ordered `a1.persons` to `data/output/persons.csv` and checks totals |

The scripts replace derived staging/match/output tables on rerun. Run from Step 02 after changing raw inputs, or run from an intermediate step only if upstream tables are still valid. The SQL scripts are transactional where they mutate persisted tables.

## Source mapping

| Standard attribute | Clinic EHR CSV | Billing XLSX |
|---|---|---|
| record_id | `Record ID` | `REC_NO` |
| first_name | `First Name` | `PAT_FNAME` |
| middle_name | `Middle Name` | `PAT_MI` |
| last_name | `Last Name` | `PAT_LNAME` |
| suffix | `Suffix` | *not present* |
| dob | `Date of Birth` | `DOB` |
| ssn | `SSN` | `SOC_SEC_NUM` |
| mrn | `MRN` | `MED_REC_NUM` |
| patient_id | `Patient ID` | `PATIENT_NUMBER` |
| address | `Address` | `ADDR1` |
| city / state / zip | `City` / `State` / `Zip` | `CITY` / `ST` / `ZIP` |
| phone / email | `Phone` / `Email` | `PHONE` / `EMAIL` |

The `source_record_key` combines the source label and physical source row number; the provided `record_id` is retained as a separate business attribute. The raw layer does not delete duplicates.

## Identity and quality assumptions

1. **Identifier scope:** SSN is a strong candidate identifier when present and well-formatted; MRN and Patient ID belong to their local source namespaces, not globally across both systems.
2. **Hard group checks:** Conflicting nonnull SSNs, conflicting nonnull normalized DOBs, and differing ordinary MRN/Patient ID within the same source are treated as incompatible for consolidation. This is an intentionally conservative exercise policy, not a claim about universal EHR semantics.
3. **Scientific notation:** Clinic Patient IDs such as `1.12949E+11` are preserved verbatim, flagged as `SCIENTIFIC_NOTATION`, and not trusted as authoritative identifiers. Do not expand rounded notation and assume the original digits are recoverable.
4. **Dates:** Accepted DOB input styles include `YYYY-MM-DD`, US `M/D/YYYY`, and US `M/D/YY`. Two-digit years are interpreted using **00–26 => 2000–2026; 27–99 => 1927–1999**. This cutoff is an explicit assumption requiring client confirmation.
5. **Contacts and names:** Names are uppercased/trimmed for comparison; formatted phones and emails may support candidate identification, but do not prove identity alone. Missing values are not treated as conflicts.
6. **Consolidation:** Distinct nonempty source values are retained with ` | ` rather than selecting a preferred/freshest source. There is no source-authority or modification-timestamp guarantee.
7. **Current algorithm limitation:** Step 06 uses set-based **SSN-anchored** grouping. It does **not** consolidate groups formed solely by SSN-less records and may conservatively split an entire unsafe anchor. This improves conflict avoidance at the expense of missed merges.
8. **No ground truth:** Matching pair retention is *not* a precision, recall or accuracy measure; the real number of unique people cannot be verified from the supplied counts alone.

## Prior observed diagnostics (not guaranteed current output)

| Milestone | Previously observed result |
|---|---:|
| Raw rows / normalized rows | 100,000 / 100,000 |
| EHR DOBs with short-year formats identified at profiling | 4,107 |
| Clinic Patient IDs in scientific notation | 1,737 |
| Candidate pairs / provisionally accepted pairs | 61,949 / 44,750 |
| Pair decisions: reject / review | 6 / 17,193 |
| Grouped unique persons | 70,998 |
| Provisional pairs retained in same group | 40,978 |
| Provisional pairs not consolidated | 3,772 |
| Single-record groups | 53,183 |

These counts come from existing profiling and grouping reports; do not present them as results of a fresh execution until the full runner has finished successfully.

## Validation and troubleshooting

```bash
cat data/output/08_validation_report.txt
psql -h localhost -U a1_user -d a1_patient_db -c \
  'SELECT COUNT(*) AS persons, SUM(record_count) AS source_records FROM a1.persons;'
```

Step 08 enforces reconciliation and identifier checks and **fails the pipeline** if a check is violated. Step 09 performs export count checks. These guarantee structural consistency under the declared rules, not every true patient relationship.

If execution fails, inspect the last stage report and its stderr output; correct the issue and rerun from that stage only if the upstream state is valid. To protect source data, `.gitignore` excludes `.env`, `data/input/*`, and `data/output/*`.

## Deliverables and reviewer discussion

Submit `persons.csv`, all numbered source scripts (including `run_pipeline.py`), and the **one-page `NOTES.docx`**. The README explains reproducibility. The follow-up discussion should address identifier scope, precision risks from scientific notation, the explicit DOB cutoff, why Step 06 favors conservative merges, and the lack of labeled truth data. Avoid claiming that every duplicate was resolved.

For local GitHub synchronization:

```bash
git add run_pipeline.py README.md NOTES.docx scripts/ requirements.txt .env.example .gitignore
git commit -m 'feat: orchestrate and document patient identity resolution pipeline'
git push origin main
```

Review `git status` before committing. The output CSV is intentionally excluded from Git; provide it through the requested take-home delivery channel.
