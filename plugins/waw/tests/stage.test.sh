#!/usr/bin/env bash
# tests/stage.test.sh — scripts/stage.sh: the commander's cost from the transcript, the
# wait and resume marks, --task, and the ledger records. Sourced by tests/run.sh (TEST_ROOT,
# SETUP_UNDER_TEST, fail, assert_eq, assert_contains, assert_exit).
set -u

STAGE=$SETUP_UNDER_TEST/stage.sh
export CLAUDE_CONFIG_DIR=$TEST_ROOT/cc
# the state dir comes from the home chain here, as it does for the status line
unset AGENT_STATE_DIR CLAUDE_CODE_SESSION_ID

STATE=$CLAUDE_CONFIG_DIR/waw/state
LEDGER=$STATE/ledger.jsonl
TRANSCRIPT=$CLAUDE_CONFIG_DIR/projects/p/S1.jsonl
T0=1767323040 # 2026-01-02T03:04:00Z

iso() { jq -rn --argjson t "$1" '$t | todate | sub("Z$"; ".123Z")'; }

# msg <id> <epoch> [model] [usage json]: one assistant line of the transcript
msg() {
  local usage=${4:-}
  [ -n "$usage" ] || usage='{"input_tokens":1000,"output_tokens":100}'
  jq -cn --arg id "$1" --arg ts "$(iso "$2")" --arg m "${3:-claude-opus-5-5}" --argjson u "$usage" \
    '{type: "assistant", timestamp: $ts, uuid: ("u-" + $id), message: {id: $id, model: $m, usage: $u}}'
}

reset() {
  rm -rf "$CLAUDE_CONFIG_DIR"
  mkdir -p "$STATE" "$(dirname "$TRANSCRIPT")"
  {
    msg m1 $((T0 + 10))
    msg m1 $((T0 + 11))
    msg m2 $((T0 + 430))
  } >"$TRANSCRIPT"
}

# mark_line <t> <stage> [task]
mark_line() { printf '%s\t%s\t\t\t%s\n' "$1" "$2" "${3:-}" >>"$STATE/stages-S1.tsv"; }

# row <report> <first column>: the line of that row, its spaces squeezed
row() { printf '%s\n' "$1" | awk -v s="$2" '$1 == s { $1 = $1; print }'; }

ledger_q() { jq -s -c "$1" "$LEDGER"; }

case_snapshot_conflict() {
  reset
  printf '{"cost":{"total_cost_usd":9.99,"total_duration_ms":7200000,"total_api_duration_ms":65000}}\n' \
    >"$STATE/cost-S1.json"
  local out
  out=$("$STAGE" report --session S1) || fail "report: $?"
  assert_contains "$(row "$out" session)" '$0.01' "session cost"
  case $out in *9.99*) fail "the snapshot cost is in the report: $out" ;; esac
  assert_contains "$(row "$out" session)" '1m 5s' "model time from the snapshot"
  assert_contains "$(row "$out" session)" '6m 59s' "time from the transcript, not the snapshot"
  "$STAGE" plan --session S1 || fail "mark: $?"
  assert_eq "$(ledger_q 'map(.cost_usd_cum)')" '[0.012]' "cost_usd_cum"
  assert_eq "$(ledger_q 'map(.cost_basis)')" '["transcript"]' "cost_basis"
  assert_eq "$(awk -F'\t' '{print $2, $3, $4}' "$STATE/stages-S1.tsv")" 'plan 0.012 65000' "marks line"
}

case_cache_tiers() {
  reset
  {
    msg c1 $((T0 + 10)) claude-opus-5-5 '{"input_tokens":0,"output_tokens":0,
      "cache_read_input_tokens":1000000,"cache_creation_input_tokens":2000000,
      "cache_creation":{"ephemeral_5m_input_tokens":1000000,"ephemeral_1h_input_tokens":1000000}}'
    msg c2 $((T0 + 20)) claude-opus-5-5 '{"cache_creation_input_tokens":1000000}'
  } >"$TRANSCRIPT"
  "$STAGE" plan --session S1 || fail "mark: $?"
  # 0.2 read + 5 (5m) + 8 (1h), then 5 with no tiers
  assert_eq "$(ledger_q '.[0].cost_usd_cum')" '18.2' "cache prices"
}

case_unpriced_model() {
  reset
  msg x1 $((T0 + 20)) no-such-model >>"$TRANSCRIPT"
  msg x2 $((T0 + 21)) '<synthetic>' '{"input_tokens":0,"output_tokens":0}' >>"$TRANSCRIPT"
  "$STAGE" plan --session S1 || fail "mark: $?"
  assert_eq "$(ledger_q '.[0] | [.cost_usd_cum, .cost_basis]')" '[0.012,"partial"]' "partial"
  assert_contains "$(row "$("$STAGE" report --session S1)" session)" '~$0.01' "approximate cost"
  reset
  msg x2 $((T0 + 21)) '<synthetic>' '{"input_tokens":0,"output_tokens":0}' >>"$TRANSCRIPT"
  "$STAGE" plan --session S1 || fail "mark: $?"
  assert_eq "$(ledger_q '.[0].cost_basis')" '"transcript"' "an entry without tokens needs no price"
}

case_no_transcript() {
  reset
  rm "$TRANSCRIPT"
  "$STAGE" plan --session S1 || fail "mark: $?"
  assert_eq "$(ledger_q '.[0] | [.cost_usd_cum, .cost_basis]')" '[null,"none"]' "no transcript"
  local out
  out=$("$STAGE" report --session S1) || fail "report: $?"
  assert_eq "$(row "$out" session | awk '{print $(NF - 1)}')" '-' "unknown cost"
}

case_wait_not_work() {
  reset
  mark_line "$T0" plan
  mark_line $((T0 + 60)) @wait
  mark_line $((T0 + 360)) @resume
  mark_line $((T0 + 420)) build
  mark_line $((T0 + 480)) done
  local out
  out=$("$STAGE" report --session S1) || fail "report: $?"
  assert_eq "$(row "$out" STAGE)" 'STAGE TIME WAIT MODEL COST OUTPUT' "header"
  assert_eq "$(row "$out" plan)" 'plan 2m 0s 5m 0s - $0.01 100' "plan"
  assert_eq "$(row "$out" build)" 'build 1m 0s - - $0.01 100' "build"
  # the messages span 419 s (m1's last entry to m2), 300 of them waiting
  assert_eq "$(row "$out" session)" 'session 1m 59s 5m 0s - $0.01 200' "session"
  case $out in *@wait* | *@resume*) fail "a wait mark is a row: $out" ;; esac
  assert_contains "$out" "priced from the transcript" "footer on the cost"
  assert_contains "$out" "excludes marked waits" "footer on the time"
}

case_task_inherited() {
  reset
  "$STAGE" plan --task a --session S1 || fail "mark: $?"
  "$STAGE" build --session S1 || fail "mark: $?"
  assert_eq "$(ledger_q 'map(.task)')" '["a","a"]' "inherited task"
  assert_eq "$(awk -F'\t' '{print $5}' "$STATE/stages-S1.tsv" | tr '\n' ' ')" 'a a ' "marks task"
}

case_two_tasks_report() {
  reset
  {
    msg a1 $((T0 + 10))
    msg a2 $((T0 + 70))
    msg b1 $((T0 + 130)) claude-opus-5-5 '{"input_tokens":1000000,"output_tokens":0}'
  } >"$TRANSCRIPT"
  mark_line "$T0" plan a
  mark_line $((T0 + 60)) build a
  mark_line $((T0 + 120)) plan b
  mark_line $((T0 + 180)) done b
  local out
  out=$("$STAGE" report --task a --session S1) || fail "report: $?"
  assert_eq "$(printf '%s\n' "$out" | awk '$1 == "plan" || $1 == "build" {print $1}' | tr '\n' ' ')" \
    'plan build ' "rows of task a"
  assert_eq "$(row "$out" session)" 'session 2m 0s - - $0.01 200' "totals of task a"
  out=$("$STAGE" report --session S1 --task b) || fail "report: $?"
  assert_eq "$(row "$out" session)" 'session 1m 0s - - $4.00 0' "totals of task b"
}

case_ledger_records() {
  reset
  "$STAGE" plan --task t1 --session S1 || fail "plan: $?"
  "$STAGE" wait ask --task t1 --session S1 || fail "wait: $?"
  "$STAGE" resume --session S1 --task t1 || fail "resume: $?"
  assert_eq "$(ledger_q 'map(.kind)')" '["stage","wait","resume"]' "kinds"
  assert_eq "$(ledger_q 'map(.reason)')" '[null,"ask",null]' "reasons"
  assert_eq "$(ledger_q 'map(.stage)')" '["plan","plan","plan"]' "stages"
  assert_eq "$(ledger_q 'all(.v == 1 and .session == "S1" and .task == "t1" and (.t | type == "string") and (.project | type == "string"))')" \
    true "common fields"
  assert_eq "$(awk -F'\t' '{print $2}' "$STATE/stages-S1.tsv" | tr '\n' ' ')" 'plan @wait @resume ' "marks"
  CLAUDE_CODE_SESSION_ID=S1 "$STAGE" wait --task t1 || fail "wait without a reason: $?"
  assert_eq "$(ledger_q '.[-1] | [.kind, .reason]')" '["wait",null]' "no reason"
}

case_state_dir_override() {
  reset
  AGENT_STATE_DIR=$TEST_ROOT/other "$STAGE" plan --session S1 || fail "mark: $?"
  [ -f "$TEST_ROOT/other/stages-S1.tsv" ] || fail "no marks under AGENT_STATE_DIR"
  [ -f "$TEST_ROOT/other/ledger.jsonl" ] || fail "no ledger under AGENT_STATE_DIR"
}

case_usage_errors() {
  reset
  assert_exit 2 "$STAGE" wait 'Bad!' --session S1
  assert_exit 2 "$STAGE" plan --task UPPER --session S1
  assert_exit 2 "$STAGE" plan --task --session S1
  assert_exit 2 "$STAGE" plan extra --session S1
  assert_exit 2 "$STAGE" resume ask --session S1
  assert_exit 2 "$STAGE" @wait --session S1
  [ ! -e "$STATE/stages-S1.tsv" ] || fail "a refused call wrote a mark"
}

case_snapshot_conflict
case_cache_tiers
case_unpriced_model
case_no_transcript
case_wait_not_work
case_task_inherited
case_two_tasks_report
case_ledger_records
case_state_dir_override
case_usage_errors
printf 'stage.test.sh: all cases passed\n'
