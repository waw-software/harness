#!/usr/bin/env bash
# tests/slots.test.sh — H1a: the atomic worker-slot store, slots.py.
# Sourced by tests/run.sh into a fresh subshell: TEST_ROOT, SETUP_UNDER_TEST and
# the runner helpers (fail, assert_eq, assert_contains, assert_exit) exist here.
# Six cases over real slots.py with real `sleep` owners and standard ps; no
# agentic script and no other tool is invoked.
set -u

SLOTS=$SETUP_UNDER_TEST/slots.py
ROOT=$TEST_ROOT/slots-cases
mkdir -p "$ROOT"
OWNERS='' OWNER_PID=''

sp() { python3 -I "$SLOTS" "$@"; }
start_owner() { sleep 30 & OWNER_PID=$!; OWNERS="$OWNERS $OWNER_PID"; }
kill_owners() { [ -n "$OWNERS" ] && kill $OWNERS 2>/dev/null; wait 2>/dev/null; OWNERS=''; return 0; }
until_within() { # until_within <seconds> <command...>: retry a command for a while
  local n=0 max=$(($1 * 10)); shift
  while ! "$@"; do
    n=$((n + 1)); [ "$n" -le "$max" ] || return 1
    sleep 0.1
  done
}
lstart_of() { LC_ALL=C ps -p "$1" -o lstart= | awk '{$1=$1};1'; }
comm_of() { LC_ALL=C ps -p "$1" -o comm=; }
holders_of() { python3 -I -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["holders"]))' "$1/slots.json"; }
json_field() { python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1/slots.json" "$2"; }
seed() { # seed <dir> <lease> <owner_pid> <owner_start> <owner_comm> <child_pid-or-null> <child_start> <child_comm>
  mkdir -p "$1"
  cat >"$1/slots.json" <<EOF
{"version": 1, "capacity": 5, "holders": [{"lease": "$2", "owner_pid": $3,
  "owner_start": "$4", "owner_comm": "$5", "name": "seeded",
  "child_pid": $6, "child_start": "$7", "child_comm": "$8"}]}
EOF
}
LEASE_0=00000000-0000-0000-0000-000000000000

case_default_five_atomic_admissions() {
  local sd=$ROOT/c1 out=$ROOT/c1; mkdir -p "$out"
  local i l1 all owners=() pids=() waiter
  for i in 1 2 3 4 5 6; do start_owner; owners+=("$OWNER_PID"); done
  for i in 1 2 3 4 5; do
    sp acquire --state-dir "$sd" --max-workers 5 --wait-seconds 20 --owner-pid "${owners[$((i - 1))]}" \
      --name "dev-$i" --stop-file "$out/never.stop" >"$out/lease-$i" 2>"$out/err-$i" &
    pids+=($!)
  done
  for i in 1 2 3 4 5; do assert_exit 0 wait "${pids[$((i - 1))]}"; done
  all=''
  for i in 1 2 3 4 5; do
    assert_contains "$(cat "$out/lease-$i")" 'lease ' "admission $i"
    all="$all $(cut -d' ' -f2 "$out/lease-$i")"
  done
  assert_eq "$(printf '%s\n' $all | sort -u | wc -l | tr -d ' ')" "5" "five distinct leases"
  assert_eq "$(sp count --state-dir "$sd")" "5" "count is five"
  sp acquire --state-dir "$sd" --max-workers 5 --wait-seconds 30 --owner-pid "${owners[5]}" \
    --name dev-6 --stop-file "$out/never.stop" >"$out/lease-6" 2>"$out/err-6" &
  waiter=$!
  until_within 5 test -s "$out/err-6" || fail "sixth acquire never announced the wait"
  assert_eq "$(cat "$out/err-6")" "[dev-6] waiting for a worker slot (5/5)" "one waiting line"
  sleep 0.7 # three retries later the line is still there exactly once
  assert_eq "$(cat "$out/err-6")" "[dev-6] waiting for a worker slot (5/5)" "no repeated waiting line"
  assert_eq "$(sp count --state-dir "$sd")" "5" "the waiter holds no slot"
  l1=$(cut -d' ' -f2 "$out/lease-1")
  assert_exit 0 sp release --state-dir "$sd" --lease "$l1" --owner-pid "${owners[0]}"
  assert_exit 0 wait "$waiter"
  assert_contains "$(cat "$out/lease-6")" 'lease ' "sixth admitted after a release"
  all="$all $(cut -d' ' -f2 "$out/lease-6")"
  assert_eq "$(printf '%s\n' $all | sort -u | wc -l | tr -d ' ')" "6" "all leases distinct"
  assert_eq "$(sp count --state-dir "$sd")" "5" "count stays at five"
  kill_owners
}

case_wait_deadline_and_zero_wait() {
  local sd=$ROOT/c2 out=$ROOT/c2; mkdir -p "$out"
  local o1 o2 o3 msg rc
  start_owner; o1=$OWNER_PID
  assert_contains "$(sp acquire --state-dir "$sd" --max-workers 1 --wait-seconds 10 \
    --owner-pid "$o1" --name dev-1 --stop-file "$out/never.stop")" 'lease '
  assert_eq "$(sp count --state-dir "$sd")" "1"
  start_owner; o2=$OWNER_PID
  msg=$(sp acquire --state-dir "$sd" --max-workers 1 --wait-seconds 1 \
    --owner-pid "$o2" --name dev-2 --stop-file "$out/never.stop" 2>"$out/e2"); rc=$?
  assert_eq "$rc" "7" "deadline exits 7"
  assert_eq "$msg" '' "no lease on timeout"
  assert_eq "$(head -n1 "$out/e2")" "[dev-2] waiting for a worker slot (1/1)" "waiting line first"
  assert_eq "$(tail -n1 "$out/e2")" "agent.sh: dev-2 timed out waiting for a worker slot after 1s"
  start_owner; o3=$OWNER_PID
  msg=$(sp acquire --state-dir "$sd" --max-workers 1 --wait-seconds 0 \
    --owner-pid "$o3" --name dev-3 --stop-file "$out/never.stop" 2>"$out/e3"); rc=$?
  assert_eq "$rc" "7" "zero wait exits 7"
  assert_eq "$msg" '' "no lease on zero wait"
  assert_eq "$(tail -n1 "$out/e3")" "agent.sh: dev-3 timed out waiting for a worker slot after 0s"
  assert_eq "$(sp count --state-dir "$sd")" "1" "neither attempt created a lease"
  kill_owners
}

case_stop_while_waiting() {
  local sd=$ROOT/c3 out=$ROOT/c3 stop; mkdir -p "$out"
  stop=$out/dev-2.stop
  start_owner
  assert_contains "$(sp acquire --state-dir "$sd" --max-workers 1 --wait-seconds 10 \
    --owner-pid "$OWNER_PID" --name dev-1 --stop-file "$out/never.stop")" 'lease '
  start_owner
  sp acquire --state-dir "$sd" --max-workers 1 --wait-seconds 20 \
    --owner-pid "$OWNER_PID" --name dev-2 --stop-file "$stop" >"$out/lease-2" 2>"$out/err-2" &
  local waiter=$!
  until_within 5 test -s "$out/err-2" || fail "never started waiting"
  touch "$stop"
  assert_exit 6 wait "$waiter"
  assert_eq "$(cat "$out/lease-2")" '' "stop consumes no slot"
  assert_eq "$(sp count --state-dir "$sd")" "1" "no slot was consumed"
  kill_owners
}

case_pid_reuse_and_orphan_child() {
  local sd=$ROOT/c4 dstart dcomm
  # a live pid whose seeded start time is wrong is reclaimed, not signalled
  start_owner; local p=$OWNER_PID
  seed "$sd" lease-4a "$p" "Wed Dec 25 00:00:00 2002" "$(comm_of "$p")" null '' ''
  assert_eq "$(sp count --state-dir "$sd")" "0" "wrong start time is reclaimed"
  assert_exit 0 kill -0 "$p"
  # a live pid with the real start time but a different comm is reclaimed too
  seed "$sd" lease-4b "$p" "$(lstart_of "$p")" no-such-command null '' ''
  assert_eq "$(sp count --state-dir "$sd")" "0" "wrong comm is reclaimed"
  assert_exit 0 kill -0 "$p"
  # a dead owner with a live bound child keeps the slot until the child exits
  start_owner; local dead=$OWNER_PID
  dstart=$(lstart_of "$dead"); dcomm=$(comm_of "$dead")
  kill "$dead"; wait "$dead" 2>/dev/null
  start_owner; local child=$OWNER_PID
  seed "$sd" lease-4c "$dead" "$dstart" "$dcomm" "$child" "$(lstart_of "$child")" "$(comm_of "$child")"
  assert_eq "$(sp count --state-dir "$sd")" "1" "live bound child keeps the reservation"
  assert_exit 0 kill -0 "$child"
  kill "$child"; wait "$child" 2>/dev/null
  assert_eq "$(sp count --state-dir "$sd")" "0" "freed once the child exits"
  # a dead owner without a child is reclaimed outright
  seed "$sd" lease-4d "$dead" "$dstart" "$dcomm" null '' ''
  assert_eq "$(sp count --state-dir "$sd")" "0" "dead owner without child is reclaimed"
  kill_owners
}

case_release_is_owned_and_idempotent() {
  local sd=$ROOT/c5
  start_owner; local o1=$OWNER_PID
  start_owner; local o2=$OWNER_PID
  start_owner; local c1=$OWNER_PID
  local l1 l2
  l1=$(sp acquire --state-dir "$sd" --max-workers 2 --wait-seconds 10 \
    --owner-pid "$o1" --name dev-1 --stop-file "$sd/never.stop"); l1=${l1#lease }
  l2=$(sp acquire --state-dir "$sd" --max-workers 2 --wait-seconds 10 \
    --owner-pid "$o2" --name dev-2 --stop-file "$sd/never.stop"); l2=${l2#lease }
  assert_eq "$(sp count --state-dir "$sd")" "2"
  assert_exit 3 sp release --state-dir "$sd" --lease "$l1" --owner-pid "$o2"
  assert_eq "$(sp count --state-dir "$sd")" "2" "wrong owner removed nothing"
  assert_exit 0 sp release --state-dir "$sd" --lease "$LEASE_0" --owner-pid "$o1"
  assert_eq "$(sp count --state-dir "$sd")" "2" "unknown lease removed nothing"
  assert_exit 3 sp bind --state-dir "$sd" --lease "$LEASE_0" --owner-pid "$o1" --child-pid "$c1"
  assert_exit 3 sp bind --state-dir "$sd" --lease "$l2" --owner-pid "$o1" --child-pid "$c1"
  assert_exit 0 sp bind --state-dir "$sd" --lease "$l1" --owner-pid "$o1" --child-pid "$c1"
  assert_exit 3 sp release --state-dir "$sd" --lease "$l1" --owner-pid "$o1"
  assert_eq "$(sp count --state-dir "$sd")" "2" "live bound child refuses release"
  kill "$c1"; wait "$c1" 2>/dev/null
  assert_exit 0 sp release --state-dir "$sd" --lease "$l1" --owner-pid "$o1"
  assert_exit 0 sp release --state-dir "$sd" --lease "$l1" --owner-pid "$o1"
  assert_eq "$(sp count --state-dir "$sd")" "1" "repeated matching release succeeds"
  assert_exit 0 sp release --state-dir "$sd" --lease "$l2" --owner-pid "$o2"
  assert_eq "$(sp count --state-dir "$sd")" "0"
  kill_owners
}

case_invalid_or_conflicting_capacity_fails_closed() {
  local sd=$ROOT/c6 never=$ROOT/c6/never.stop before
  mkdir -p "$ROOT/c6"
  assert_exit 2 sp acquire --state-dir "$sd" --max-workers 0 --wait-seconds 1 --owner-pid $$ --name x --stop-file "$never"
  assert_exit 2 sp acquire --state-dir "$sd" --max-workers -1 --wait-seconds 1 --owner-pid $$ --name x --stop-file "$never"
  assert_exit 2 sp acquire --state-dir "$sd" --max-workers abc --wait-seconds 1 --owner-pid $$ --name x --stop-file "$never"
  assert_exit 2 sp acquire --state-dir "$sd" --max-workers 2 --wait-seconds -1 --owner-pid $$ --name x --stop-file "$never"
  assert_exit 2 sp acquire --state-dir "$sd" --max-workers 2 --wait-seconds 1 --owner-pid 0 --name x --stop-file "$never"
  assert_exit 2 sp acquire --state-dir rel-dir --max-workers 2 --wait-seconds 1 --owner-pid $$ --name x --stop-file "$never"
  assert_exit 2 sp acquire --state-dir "$sd" --max-workers 2 --wait-seconds 1 --owner-pid $$ --stop-file "$never"
  [ ! -e "$sd/slots.json" ] || fail "invalid arguments must not create a ledger"
  start_owner; local o1=$OWNER_PID
  local l1; l1=$(sp acquire --state-dir "$sd" --max-workers 5 --wait-seconds 5 \
    --owner-pid "$o1" --name dev-1 --stop-file "$never")
  start_owner; local o2=$OWNER_PID
  assert_exit 3 sp acquire --state-dir "$sd" --max-workers 3 --wait-seconds 0 \
    --owner-pid "$o2" --name dev-2 --stop-file "$never"
  assert_eq "$(holders_of "$sd")" "1" "conflicting limit preserved the holder"
  assert_eq "$(json_field "$sd" capacity)" "5" "capacity preserved"
  assert_exit 0 sp release --state-dir "$sd" --lease "${l1#lease }" --owner-pid "$o1"
  l2=$(sp acquire --state-dir "$sd" --max-workers 3 --wait-seconds 5 \
    --owner-pid "$o2" --name dev-2 --stop-file "$never")
  assert_contains "$l2" 'lease ' "limit may change with no live holder"
  assert_exit 0 sp release --state-dir "$sd" --lease "${l2#lease }" --owner-pid "$o2"
  printf 'not json at all\n' >"$sd/slots.json"
  before=$(cat "$sd/slots.json")
  assert_exit 3 sp acquire --state-dir "$sd" --max-workers 3 --wait-seconds 0 \
    --owner-pid "$o2" --name dev-3 --stop-file "$never"
  assert_exit 3 sp count --state-dir "$sd"
  assert_eq "$(cat "$sd/slots.json")" "$before" "malformed ledger is never reset"
  kill_owners
}

case_default_five_atomic_admissions
case_wait_deadline_and_zero_wait
case_stop_while_waiting
case_pid_reuse_and_orphan_child
case_release_is_owned_and_idempotent
case_invalid_or_conflicting_capacity_fails_closed
printf 'slots.test.sh: all six cases passed\n'
