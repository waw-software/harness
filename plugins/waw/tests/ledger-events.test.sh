#!/usr/bin/env bash
# tests/ledger-events.test.sh — agent.sh's event records in the ledger: written as the events
# are emitted, so they outlive an interrupted run and its run directory.
# Sourced by tests/run.sh into a fresh subshell. The claude sentinel is replaced by
# tests/fixtures/fake-claude-usage.sh: real agent.sh runs, no model.
set -u

AGENT=$SETUP_UNDER_TEST/agent.sh
ROOT=$TEST_ROOT/ledger-events
LEDGER=$AGENT_STATE_DIR/ledger.jsonl
export AGENT_WORKER_ENV="TEST_ROOT FAKE_CLAUDE_USAGE_MODE"
cp "$TESTS_DIR/fixtures/fake-claude-usage.sh" "$TEST_ROOT/bin/claude"
chmod 755 "$TEST_ROOT/bin/claude"
mkdir -p "$ROOT/dir"
printf 'a ledger test\n' >"$ROOT/brief.md"

# count <jq condition>: the ledger records that satisfy it
count() { jq -c "select($1)" "$LEDGER" 2>/dev/null | grep -c . || true; }
three_events() {
  [ "$(count '.kind == "event" and .name == "inv-e" and .type == "QUESTION"')" -ge 1 ] &&
    [ "$(count '.kind == "event" and .name == "inv-e" and .type == "APPROVAL"')" -ge 1 ] &&
    [ "$(count '.kind == "event" and .name == "inv-e" and .type == "BLOCKED"')" -ge 1 ]
}

case_events_survive_interruption() {
  local out=$ROOT/.ship/s2/agents pid n=0 t id
  FAKE_CLAUDE_USAGE_MODE=events-hang bash "$AGENT" run --role investigator \
    --brief "$ROOT/brief.md" --out "$out" --cwd "$ROOT/dir" --name inv-e --quiet \
    >"$ROOT/inv-e.log" 2>"$ROOT/inv-e.err" &
  pid=$!
  while ! three_events; do
    n=$((n + 1))
    [ "$n" -le 150 ] || fail "no event records in 15 s: $(cat "$LEDGER" "$ROOT/inv-e.err" 2>&1)"
    sleep 0.1
  done
  kill -TERM "$pid"
  assert_exit 130 wait "$pid"
  rm -rf "$out"
  for t in QUESTION APPROVAL BLOCKED; do
    assert_eq "$(count ".kind == \"event\" and .name == \"inv-e\" and .type == \"$t\"")" 1 "$t records"
  done
  assert_eq "$(count '.kind == "run" and .name == "inv-e" and .status == "interrupted" and .cost_incomplete == true')" \
    1 "the interrupted run record"
  id=$(jq -r 'select(.kind == "run" and .name == "inv-e") | .run_id' "$LEDGER")
  [ -n "$id" ] || fail "no run_id"
  assert_eq "$(count ".name == \"inv-e\" and .run_id == \"$id\"")" 5 \
    "run-start, three events and the run under one run_id"
  assert_eq "$(count '.kind == "event" and .name == "inv-e" and .task == "s2" and .v == 1
    and (.t | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}[+-][0-9]{4}$"))')" 3 "event record fields"
}

case_events_not_duplicated() {
  local out=$ROOT/plain-out
  FAKE_CLAUDE_USAGE_MODE=events-ok bash "$AGENT" run --role investigator \
    --brief "$ROOT/brief.md" --out "$out" --cwd "$ROOT/dir" --name inv-d --quiet \
    >"$ROOT/inv-d.log" 2>"$ROOT/inv-d.err" || fail "inv-d: $(cat "$ROOT/inv-d.err")"
  assert_eq "$(count '.kind == "event" and .type == "QUESTION" and .name == "inv-d" and .text == "q1"')" \
    1 "the QUESTION record"
  assert_eq "$(count '.kind == "event" and (.name == "other-worker" or .text == "q2")')" 0 \
    "another worker's line"
  assert_eq "$(count '.kind == "run" and .name == "inv-d" and .task == "plain-out"')" 1 \
    "the task is the basename of --out"
}

case_interrupt_keeps_pending_event() {
  local out=$ROOT/pending-out pid n=0 t
  FAKE_CLAUDE_USAGE_MODE=events-hang bash "$AGENT" run --role investigator \
    --brief "$ROOT/brief.md" --out "$out" --cwd "$ROOT/dir" --name inv-q --quiet \
    >"$ROOT/inv-q.log" 2>"$ROOT/inv-q.err" &
  pid=$!
  # TERM as soon as the worker has written its events, before the follower's next look
  while ! grep -q ' APPROVAL inv-q: ' "$out/events.log" 2>/dev/null; do
    n=$((n + 1))
    [ "$n" -le 300 ] || fail "inv-q wrote no events: $(cat "$ROOT/inv-q.err" 2>&1)"
    sleep 0.05
  done
  kill -TERM "$pid"
  assert_exit 130 wait "$pid"
  # no wait here: the records are there when the wrapper has exited
  for t in QUESTION APPROVAL; do
    assert_eq "$(count ".kind == \"event\" and .name == \"inv-q\" and .type == \"$t\"")" 1 "$t records"
  done
}

case_events_survive_interruption
case_events_not_duplicated
case_interrupt_keeps_pending_event
