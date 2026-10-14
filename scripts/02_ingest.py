"""Load Clinic EHR CSV and Billing XLSX into PostgreSQL (raw, lossless layer).

Run from project root: python scripts/02_ingest.py
Reruns replace the raw snapshot transactionally; no deduplication happens here.
"""
import json
import logging
import os
from pathlib import Path

import pandas as pd
import psycopg
from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parents[1]
INPUT_DIR = ROOT / "data" / "input"
SCHEMA_PATH = ROOT / "scripts" / "sql" / "01_create_tables.sql"

# Explicit mappings reflect the actual headers provided for each file.
SOURCE_CONFIG = {
    "clinic_ehr": {
        "path": INPUT_DIR / "Clinic_EHR_Export.csv",
        "expected_rows": 65056,
        "columns": {
            "record_id": "Record ID",
            "first_name": "First Name",
            "middle_name": "Middle Name",
            "last_name": "Last Name",
            "suffix": "Suffix",
            "dob": "Date of Birth",
            "ssn": "SSN",
            "mrn": "MRN",
            "patient_id": "Patient ID",
            "address": "Address",
            "city": "City",
            "state": "State",
            "zip": "Zip",
            "phone": "Phone",
            "email": "Email",
        },
    },
    "billing_system": {
        "path": INPUT_DIR / "Billing_System_Export.xlsx",
        "expected_rows": 34944,
        "columns": {
            "record_id": "REC_NO",
            "first_name": "PAT_FNAME",
            "middle_name": "PAT_MI",
            "last_name": "PAT_LNAME",
            "suffix": None,  # Billing file has no suffix column.
            "dob": "DOB",
            "ssn": "SOC_SEC_NUM",
            "mrn": "MED_REC_NUM",
            "patient_id": "PATIENT_NUMBER",
            "address": "ADDR1",
            "city": "CITY",
            "state": "ST",
            "zip": "ZIP",
            "phone": "PHONE",
            "email": "EMAIL",
        },
    },
}

FIELDS = (
    "record_id", "first_name", "middle_name", "last_name", "suffix", "dob",
    "ssn", "mrn", "patient_id", "address", "city", "state", "zip",
    "phone", "email",
)


def read_source(path: Path) -> pd.DataFrame:
    if not path.is_file():
        raise FileNotFoundError(f"Missing source file: {path}")
    if path.suffix.lower() == ".csv":
        df = pd.read_csv(path, dtype=str, keep_default_na=False, encoding="utf-8-sig")
    elif path.suffix.lower() == ".xlsx":
        df = pd.read_excel(path, dtype=str, keep_default_na=False, engine="openpyxl")
    else:
        raise ValueError(f"Unsupported file format: {path.suffix}")
    # Trim header whitespace without changing actual field names.
    df.columns = [str(c).strip() for c in df.columns]
    if len(df.columns) != len(set(df.columns)):
        raise ValueError(f"Duplicate column headers in {path.name}")
    return df


def validate_columns(df: pd.DataFrame, config: dict, source: str) -> None:
    required = [col for col in config["columns"].values() if col is not None]
    missing = [col for col in required if col not in df.columns]
    if missing:
        raise ValueError(
            f"{source}: missing columns {missing}; found headers: {list(df.columns)}"
        )
    logging.info("%s: headers=%s", source, list(df.columns))
    logging.info("%s: target-to-source mapping=%s", source, config["columns"])


def clean_empty(value):
    """Only turn an empty cell into NULL; do not normalize identity values yet."""
    if pd.isna(value):
        return None
    text = str(value)
    return None if text.strip() == "" else text


def iter_source_rows(df: pd.DataFrame, source: str, columns: dict):
    # Row 1 contains headers in both files; first data record is row 2.
    for row_number, raw_values in enumerate(df.itertuples(index=False, name=None), start=2):
        raw = dict(zip(df.columns, raw_values))
        values = [clean_empty(raw[columns[field]]) if columns[field] else None
                  for field in FIELDS]
        payload = {column: clean_empty(value) for column, value in raw.items()}
        yield (
            f"{source}:{row_number}", source, row_number, *values,
            json.dumps(payload, ensure_ascii=False),
        )


def main():
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    load_dotenv(ROOT / ".env")

    prepared = {}
    for source, config in SOURCE_CONFIG.items():
        frame = read_source(config["path"])
        validate_columns(frame, config, source)
        actual_rows = len(frame)
        logging.info("%s: %s rows read", source, actual_rows)
        if actual_rows != config["expected_rows"]:
            raise ValueError(
                f"{source}: expected {config['expected_rows']} rows, got {actual_rows}"
            )
        prepared[source] = frame

    if not os.getenv("DB_PASSWORD"):
        raise ValueError("Missing DB_PASSWORD in .env")

    connection_kwargs = {
        "host": os.getenv("DB_HOST", "localhost"),
        "port": os.getenv("DB_PORT", "5432"),
        "dbname": os.getenv("DB_NAME", "a1_patient_db"),
        "user": os.getenv("DB_USER", "a1_user"),
        "password": os.environ["DB_PASSWORD"],
    }
    copy_columns = ("source_record_key", "source_system", "source_row_number", *FIELDS, "raw_payload")
    copy_sql = f"COPY a1.raw_patient_records ({', '.join(copy_columns)}) FROM STDIN"

    # psycopg transaction ensures an error rolls back TRUNCATE and COPY together.
    with psycopg.connect(**connection_kwargs) as conn:
        with conn.transaction():
            conn.execute(SCHEMA_PATH.read_text(encoding="utf-8"))
            conn.execute("TRUNCATE a1.raw_patient_records")
            with conn.cursor() as cur:
                with cur.copy(copy_sql) as copy:
                    for source, frame in prepared.items():
                        for record in iter_source_rows(frame, source, SOURCE_CONFIG[source]["columns"]):
                            copy.write_row(record)

            rows = conn.execute(
                "SELECT source_system, COUNT(*), COUNT(DISTINCT source_record_key) "
                "FROM a1.raw_patient_records GROUP BY source_system ORDER BY source_system"
            ).fetchall()
            observed = {source: count for source, count, _ in rows}
            for source, config in SOURCE_CONFIG.items():
                expected = config["expected_rows"]
                if observed.get(source) != expected:
                    raise RuntimeError(f"{source}: DB count {observed.get(source)} != {expected}")
            if any(count != unique for _, count, unique in rows):
                raise RuntimeError("Source record key uniqueness check failed")
            logging.info("Verified database counts: %s", rows)
            logging.info("SUCCESS: %s raw records loaded, no deduplication", sum(observed.values()))


if __name__ == "__main__":
    main()
