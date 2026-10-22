#!/usr/bin/env bash
# Full database test cycle against a local PostgreSQL (never a Supabase project):
#   fresh DB -> Supabase shim -> all migrations up -> all rollbacks down (reverse) ->
#   all migrations up again -> dev seed -> SQL tests -> concurrency test
# Usage: PGCONN="-h localhost -p 5432 -U postgres" scripts/test-db.sh
set -euo pipefail
cd "$(dirname "$0")/.."

BASE="${PGCONN:--h /var/lib/pgtest -p 54329 -U postgres}"
DB=erp_test
PSQL="psql $BASE -v ON_ERROR_STOP=1 -q -o /dev/null"

$PSQL -d postgres -c "drop database if exists $DB with (force)" -c "create database $DB" 2>/dev/null
$PSQL -d $DB -f supabase/tests/local_supabase_shim.sql

for f in supabase/migrations/*.sql; do $PSQL -d $DB -f "$f"; echo "up    $(basename "$f")"; done
for f in $(ls supabase/rollbacks/*.down.sql | sort -r); do $PSQL -d $DB -f "$f" 2>/dev/null; echo "down  $(basename "$f")"; done

LEFT=$(psql $BASE -d $DB -At -c "select count(*) from pg_tables where schemaname = 'public'")
[[ "$LEFT" == "0" ]] || { echo "FAIL: $LEFT tables left after rollback"; exit 1; }
echo "PASS: rollbacks leave an empty public schema"

for f in supabase/migrations/*.sql; do $PSQL -d $DB -f "$f"; echo "up    $(basename "$f")"; done

for f in $(ls supabase/seed/*.sql | sort); do $PSQL -d $DB -f "$f"; echo "seed  $(basename "$f")"; done

for f in supabase/tests/*.test.sql; do
  psql $BASE -d $DB -q -f "$f" 2>&1 | grep -E 'PASS|FAIL|ERROR|ALL TESTS' | sed 's/^.*NOTICE:  //'
  psql $BASE -d $DB -q -f "$f" >/dev/null 2>&1 || { echo "FAIL in $f"; exit 1; }
done

PGCONN="$BASE -d $DB" scripts/test-numbering-concurrency.sh
PGCONN="$BASE -d $DB" scripts/test-stock-concurrency.sh
