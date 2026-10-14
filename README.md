# A1 patient record consolidation

## Input
- `data/input/Clinic_EHR_Export.csv` (65,056 rows)
- `data/input/Billing_System_Export.xlsx` (34,944 rows)

The input files are intentionally excluded from Git.

## Raw ingestion

```bash
source .venv_a1/bin/activate
pip install -r requirements.txt
cp .env.example .env  # if not done; configure password
python scripts/02_ingest.py
```

Uses the explicit header mappings in `scripts/02_ingest.py`. Input cells are loaded as strings, with empty cells represented as NULL. Source DOB formats differ and are deliberately retained as supplied (normalization belongs to a later stage). Data is loaded into `a1.raw_patient_records`, alongside JSONB raw source content. Reloads replace the snapshot in a transaction.

```sql
SELECT source_system, COUNT(*) FROM a1.raw_patient_records GROUP BY 1;
SELECT COUNT(*) FROM a1.raw_patient_records;
```
