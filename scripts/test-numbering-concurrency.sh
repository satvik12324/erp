#!/usr/bin/env bash
# Two concurrent transactions draw from the same series. Session A holds its number for 3s,
# then rolls back; session B must wait, then receive the number A gave back (no gap, no duplicate).
set -euo pipefail
PSQL="psql ${PGCONN:--h /var/lib/pgtest -p 54329 -U postgres -d erp_test} -At -q"
RANGE="(select id from public.number_ranges where code='PO')"
$PSQL -c "begin; select 'A:'||private.next_number($RANGE); select pg_sleep(3); rollback;" > /tmp/numA.txt &
sleep 0.5
START=$(date +%s.%N)
$PSQL -c "begin; select 'B:'||private.next_number($RANGE); commit;" > /tmp/numB.txt
END=$(date +%s.%N)
wait
A=$(grep '^A:' /tmp/numA.txt); B=$(grep '^B:' /tmp/numB.txt)
WAITED=$(echo "$END - $START" | bc)
echo "$A (rolled back) / $B (committed) / B waited ${WAITED}s"
[[ "${A#A:}" == "${B#B:}" ]] && (( $(echo "$WAITED > 2" | bc) )) && echo "PASS: concurrent caller queued and reused the rolled-back number" || { echo FAIL; exit 1; }
# next call must continue after B
N=$($PSQL -c "select private.next_number($RANGE)")
echo "next: $N"
