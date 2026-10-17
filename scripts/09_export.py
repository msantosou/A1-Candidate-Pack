"""Step 09: Export validated a1.persons to the required persons.csv.

Run from project root: python scripts/09_export.py
Requires .env with DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD.
"""
import csv
import os
from pathlib import Path
import tempfile

import psycopg
from dotenv import load_dotenv

PROJECT_ROOT = Path(__file__).resolve().parents[1]
OUTPUT = PROJECT_ROOT / 'data' / 'output' / 'persons.csv'
COLUMNS = (
    'person_key', 'record_ids', 'first_name', 'middle_name', 'last_name',
    'suffix', 'dob', 'ssn', 'mrn', 'patient_id', 'address', 'city', 'state',
    'zip', 'phone', 'email', 'record_count'
)


def main() -> None:
    load_dotenv(PROJECT_ROOT / '.env')
    params = dict(
        host=os.getenv('DB_HOST', 'localhost'),
        port=os.getenv('DB_PORT', '5432'),
        dbname=os.getenv('DB_NAME', 'a1_patient_db'),
        user=os.getenv('DB_USER', 'a1_user'),
        password=os.getenv('DB_PASSWORD'),
    )
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    temp_path = None
    try:
        with psycopg.connect(**params) as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT to_regclass('a1.validation_results')")
                if cur.fetchone()[0] is None:
                    raise RuntimeError('Run Step 08 before exporting.')
                cur.execute('SELECT COUNT(*), COUNT(*) FILTER (WHERE NOT passed) FROM a1.validation_results')
                total_tests, failed_tests = cur.fetchone()
                if total_tests != 15 or failed_tests:
                    raise RuntimeError(f'Validation state is incomplete or failed: {total_tests} checks, {failed_tests} failures')
                # Re-run critical checks to avoid exporting a changed/stale mapping.
                cur.execute('''
                    SELECT
                      (SELECT COUNT(*) FROM a1.raw_patient_records),
                      (SELECT COUNT(*) FROM a1.person_record_map),
                      (SELECT COALESCE(SUM(record_count),0) FROM a1.persons),
                      (SELECT COUNT(*) FROM a1.persons)
                ''')
                raw_count, map_count, represented_count, person_count = cur.fetchone()
                if (raw_count, map_count, represented_count) != (100000, 100000, 100000):
                    raise RuntimeError('Raw/mapping/person counts no longer reconcile; rerun Steps 07 and 08.')
                quoted = ', '.join('"' + column + '"' for column in COLUMNS)
                statement = (
                    f'COPY (SELECT {quoted} FROM a1.persons ORDER BY person_key) '
                    'TO STDOUT WITH (FORMAT CSV, HEADER TRUE, FORCE_QUOTE *)'
                )
                with tempfile.NamedTemporaryFile(mode='wb', dir=OUTPUT.parent,
                                                 prefix='.persons_', suffix='.csv',
                                                 delete=False) as f:
                    temp_path = Path(f.name)
                    with cur.copy(statement) as copy:
                        while chunk := copy.read():
                            f.write(chunk)
        exported = 0
        summed_records = 0
        with temp_path.open(newline='', encoding='utf-8') as f:
            reader = csv.DictReader(f)
            if reader.fieldnames != list(COLUMNS):
                raise RuntimeError(f'Unexpected CSV columns: {reader.fieldnames}')
            for row in reader:
                exported += 1
                summed_records += int(row['record_count'])
        if exported != person_count or summed_records != 100000:
            raise RuntimeError('Exported CSV does not reconcile with person table.')
        os.replace(temp_path, OUTPUT)
        temp_path = None
        print(f'PASS | {exported:,} persons; {summed_records:,} source records | {OUTPUT}')
    finally:
        if temp_path is not None:
            temp_path.unlink(missing_ok=True)


if __name__ == '__main__':
    main()
