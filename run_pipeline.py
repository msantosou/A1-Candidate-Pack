#!/usr/bin/env python3
"""Run the A1 patient entity-resolution pipeline end to end.

Usage:
    python run_pipeline.py
    python run_pipeline.py --from-step 4
    python run_pipeline.py --skip-profiling

Step 01 DDL is executed within Step 02 ingestion, which applies the schema.
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone

from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parent
SCRIPTS = ROOT / 'scripts'
SQL = SCRIPTS / 'sql'
OUTPUT = ROOT / 'data' / 'output'
STEPS = {
    2: ('Ingest raw source datasets (includes Step 01 DDL)', [sys.executable, str(SCRIPTS / '02_ingest.py')], None),
    3: ('Read-only source profiling', ['psql', '-X', '-v', 'ON_ERROR_STOP=1', '-f', str(SQL / '03_data_profiling.sql')], '03_data_profiling.txt'),
    4: ('Normalize attributes', ['psql', '-X', '-v', 'ON_ERROR_STOP=1', '-f', str(SQL / '04_normalize.sql')], '04_normalization_report.txt'),
    5: ('Generate and evaluate candidate pairs', ['psql', '-X', '-v', 'ON_ERROR_STOP=1', '-f', str(SQL / '05_match_records.sql')], '05_matching_report.txt'),
    6: ('Resolve person groups (conservative SSN anchor)', ['psql', '-X', '-v', 'ON_ERROR_STOP=1', '-f', str(SQL / '06_resolve_entities.sql')], '06_grouping_report.txt'),
    7: ('Consolidate persons', ['psql', '-X', '-v', 'ON_ERROR_STOP=1', '-f', str(SQL / '07_consolidate.sql')], '07_consolidation_report.txt'),
    8: ('Run mandatory quality gates', ['psql', '-X', '-v', 'ON_ERROR_STOP=1', '-f', str(SQL / '08_validate.sql')], '08_validation_report.txt'),
    9: ('Export validated persons.csv', [sys.executable, str(SCRIPTS / '09_export.py')], None),
}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--from-step', type=int, default=2, choices=range(2, 10), metavar='2..9',
                        help='Restart at a chosen step; requires earlier output tables')
    parser.add_argument('--skip-profiling', action='store_true', help='Skip read-only Step 03 for a faster repeat run')
    args = parser.parse_args()
    load_dotenv(ROOT / '.env')
    password = os.getenv('DB_PASSWORD')
    if not password:
        parser.error('DB_PASSWORD is missing. Configure your local .env file.')
    if shutil.which('psql') is None:
        parser.error('psql not found: install PostgreSQL client utilities.')
    OUTPUT.mkdir(parents=True, exist_ok=True)
    db_env = os.environ.copy()
    db_env['PGHOST'] = os.getenv('DB_HOST', 'localhost')
    db_env['PGPORT'] = os.getenv('DB_PORT', '5432')
    db_env['PGDATABASE'] = os.getenv('DB_NAME', 'a1_patient_db')
    db_env['PGUSER'] = os.getenv('DB_USER', 'a1_user')
    db_env['PGPASSWORD'] = password
    # Never expose the DB password in command line arguments or logs.
    to_run = [(n, *STEPS[n]) for n in range(args.from_step, 10)
              if not (args.skip_profiling and n == 3)]
    started = time.perf_counter()
    print(f'Started {datetime.now(timezone.utc).isoformat(timespec="seconds")}', flush=True)
    print('Database:', db_env['PGHOST'], db_env['PGPORT'], db_env['PGDATABASE'], flush=True)
    for number, label, command, report in to_run:
        for item in command:
            if item.endswith(('.sql', '.py')) and not Path(item).is_file():
                parser.error(f'Missing script: {item}')
        print(f'\n[{number:02d}/09] {label}', flush=True)
        step_start = time.perf_counter()
        # psql writes result tables to a report; errors are sent to stderr.
        # Printing psql errors immediately makes failures diagnosable.
        if report:
            report_path = OUTPUT / report
            with report_path.open('w', encoding='utf-8') as destination:
                result = subprocess.run(command, cwd=ROOT, env=db_env, stdout=destination,
                                        stderr=subprocess.PIPE, text=True, check=False)
            if result.stderr.strip():
                print(result.stderr.strip(), file=sys.stderr, flush=True)
            print(f'Report: {report_path}', flush=True)
        else:
            result = subprocess.run(command, cwd=ROOT, env=db_env, check=False)
        elapsed = time.perf_counter() - step_start
        if result.returncode:
            print(f'FAILED at Step {number:02d} (exit {result.returncode}; {elapsed:.1f}s).',
                  file=sys.stderr, flush=True)
            print('Downstream steps were NOT executed.', file=sys.stderr, flush=True)
            return result.returncode
        print(f'PASS in {elapsed:.1f}s', flush=True)
    print(f'\nPIPELINE SUCCESS in {time.perf_counter()-started:.1f}s', flush=True)
    print(f'CSV: {OUTPUT / "persons.csv"}', flush=True)
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print('\nInterrupted; remaining steps were not run.', file=sys.stderr)
        raise SystemExit(130)
