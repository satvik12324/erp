#!/usr/bin/env bash
# Two sessions each try to issue 30 of the 50 KG cumin at the same time.
# The stock row lock must serialize them: one posts, the other is refused. Stock never goes below zero.
set -euo pipefail
PSQL="psql ${PGCONN:--h /var/lib/pgtest -p 54329 -U postgres -d erp_test} -At -q"
SETUP="select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000a',false);"
mk() { $PSQL -c "$SETUP" -c "select tests.new_doc('SPICE','GI')" | tail -1; }
A=$(mk); B=$(mk)
$PSQL -c "$SETUP" -c "select tests.add_line('$A',10,'RAW001',30,'KG'); select tests.add_line('$B',10,'RAW001',30,'KG');" >/dev/null
$PSQL -c "$SETUP" -c "begin; select public.post_inventory_document('$A'); select pg_sleep(2); commit;" >/tmp/stA.txt 2>&1 &
sleep 0.5
$PSQL -c "$SETUP" -c "select public.post_inventory_document('$B');" >/tmp/stB.txt 2>&1 || true
wait
OH=$($PSQL -c "select tests.oh('RAW001','RM')")
echo "A: $(grep -E 'GI/|ERROR' /tmp/stA.txt | head -1)"
echo "B: $(grep -E 'GI/|ERROR' /tmp/stB.txt | head -1)"
echo "on hand after: $OH"
grep -q 'Insufficient stock' /tmp/stB.txt && [[ "$OH" == "20.000000" ]] && echo "PASS: concurrent issues serialized, second refused, no negative stock" || { echo FAIL; exit 1; }
