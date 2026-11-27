#!/usr/bin/env bash
# tests/retro.test.sh — retro.sh over a hand-written ledger: runs per role and model, fix runs
# per slice, events, the commander's stages, the period rule. Sourced by tests/run.sh
# (TEST_ROOT, SETUP_UNDER_TEST, fail, assert_eq, assert_contains, assert_exit).
set -u

RETRO=$SETUP_UNDER_TEST/retro.sh
FX=$TEST_ROOT/retro-fx
LEDGER=$FX/ledger.jsonl
mkdir -p "$FX/ledger.d"

run_rec() { # run_rec <kind> <t> <id> <name> <role> <model> <task> [<further fields>]
  local more=${8:-}
  [ -n "$more" ] || more='{}'
  jq -nc --arg kind "$1" --arg t "$2" --arg id "$3" --arg name "$4" --arg role "$5" \
    --arg model "$6" --arg task "$7" --argjson more "$more" \
    '{v: 1, kind: $kind, t: $t, project: "proj", task: $task, run_id: $id, name: $name,
      role: $role, model: $model} + $more'
}
done_rec() { # done_rec <status> <seconds> <turns> <steers> <usd> <cost incomplete>
  printf '{"status":"%s","seconds":%s,"turns":%s,"steers":%s,"cost_usd":%s,"cost_basis":"tokens","cost_incomplete":%s,"cost_cc":99}' "$@"
}
event_rec() { # event_rec <t> <type> <task> <text>
  jq -nc --arg t "$1" --arg type "$2" --arg task "$3" --arg text "$4" \
    '{v: 1, kind: "event", t: $t, project: "proj", task: $task, run_id: "r1", name: "dev-a",
      type: $type, text: $text}'
}
mark_rec() { # mark_rec <kind> <t> <session> <task> <stage> <cost>
  jq -nc --arg kind "$1" --arg t "$2" --arg s "$3" --arg task "$4" --arg stage "$5" --argjson cost "$6" \
    '{v: 1, kind: $kind, t: $t, session: $s, project: "proj", task: $task, stage: $stage,
      reason: null, cost_usd_cum: $cost, cost_basis: "transcript"}'
}

BLOCKED_TEXT='blocked by worker-guard: git commit is not allowed for a worker, report it instead'
{
  run_rec run-start 2026-03-01T09:00:00+0000 r1 dev-a developer m1 a
  run_rec run 2026-03-01T09:10:00+0000 r1 dev-a developer m1 a "$(done_rec ok 600 10 1 1.00 false)"
  run_rec run 2026-03-10T09:05:00+0000 r2 dev-a-fix1 developer m1 a "$(done_rec ok 300 5 0 0.50 true)"
  run_rec run 2026-03-10T09:20:00+0000 r3 dev-b developer m1 b "$(done_rec failed 300 10 0 2.00 false)"
  run_rec run 2026-03-01T09:30:00+0000 r4 inv-1 investigator m2 a "$(done_rec ok 120 3 0 0.25 false)"
  run_rec run-start 2026-03-10T09:40:00+0000 r5 tst-1 tester m3 b
  event_rec 2026-03-01T09:01:00+0000 BLOCKED a "$BLOCKED_TEXT"
  event_rec 2026-03-10T09:01:00+0000 BLOCKED a "$BLOCKED_TEXT"
  event_rec 2026-03-10T09:02:00+0000 QUESTION b 'which one?'
  # session S: two tasks
  mark_rec stage 2026-03-05T10:00:00+0000 S a plan 1.00
  mark_rec wait 2026-03-05T10:10:00+0000 S a plan 1.50
  mark_rec resume 2026-03-05T10:15:00+0000 S a plan 1.50
  mark_rec stage 2026-03-05T10:20:00+0000 S a build 2.00
  mark_rec stage 2026-03-05T10:50:00+0000 S b review 5.00
  mark_rec stage 2026-03-05T11:00:00+0000 S b 'done' 5.75
  # sessions T and U: a stage across each end of March
  mark_rec stage 2026-02-28T23:00:00+0000 T c early 0
  mark_rec stage 2026-03-01T01:00:00+0000 T c 'done' 7.00
  mark_rec stage 2026-03-31T23:00:00+0000 U c late 0
  mark_rec stage 2026-04-01T01:30:00+0000 U c 'done' 0.40
} >"$LEDGER"
event_rec 2026-03-10T09:03:00+0000 STALLED b 'no step for 10 minutes' >"$FX/ledger.d/a1B2c3"

# retro <args>: the report of March, with runs of spaces squeezed
retro() { bash "$RETRO" --ledger "$LEDGER" "$@" | tr -s ' '; }
march() { retro --since 2026-03-01 --until 2026-03-31 "$@"; }
has_line() { # has_line <output> <exact line> <label>
  printf '%s\n' "$1" | grep -qxF -- "$2" || fail "$3: no line [$2] in:
$1"
}
no_row() { # no_row <output> <first word> <label>
  if printf '%s\n' "$1" | grep -q -- "^$2 "; then fail "$3: a [$2] row in:
$1"; fi
}

case_period() {
  local out
  out=$(march) || fail "retro failed"
  has_line "$out" 'developer | m1 3 1 0 1 1 25 20.0 $3.50 1' "all of March"
  has_line "$out" 'investigator | m2 1 0 0 0 0 3 2.0 $0.25 0' "investigator"
  out=$(retro --since 2026-03-10 --until 2026-03-31) || fail "retro failed"
  has_line "$out" 'developer | m1 2 1 0 1 0 15 10.0 $2.50 1' "only the later date"
  no_row "$out" investigator "the earlier date"
}

case_fix_per_slice() {
  has_line "$(march)" 'developer slices: 2, fix runs per slice: 0.5' "fix runs per slice"
}

case_events_top() {
  local out
  out=$(march) || fail "retro failed"
  has_line "$out" 'BLOCKED 2' "blocked count"
  has_line "$out" 'QUESTION 1' "question count"
  has_line "$out" 'QUESTION-TIMEOUT 0' "a type without events"
  has_line "$out" " 2x ${BLOCKED_TEXT:0:60}" "top text, cut at 60"
  assert_eq "$(printf '%s\n' "$out" | grep -c 'blocked by worker-guard')" "1" "the top text once"
}

case_two_tasks_one_session() {
  local out
  out=$(march --task a) || fail "retro failed"
  has_line "$out" 'plan 1 15m 0s 5m 0s $1.00' "plan, wait apart"
  has_line "$out" 'build 1 30m 0s - $3.00' "build ends at the next task's mark"
  no_row "$out" review "task b's stage"
  has_line "$out" 'total: $5.75 (commander $4.00, workers $1.75)' "total of task a"
  has_line "$out" 'sub runs (not in usd): 0' "sub runs"
}

case_spanning_stage() {
  local out
  out=$(march) || fail "retro failed"
  no_row "$out" early "a stage that started before the period"
  has_line "$out" 'late 1 2h 30m - $0.40' "a stage that ends after the period, whole"
  assert_contains "$out" "belongs to the period of its start mark" "the period rule"
}

case_interrupted_counted() {
  has_line "$(march)" 'tester | m3 1 0 1 0 0 0 0.0 $0.00 0' "a run-start without a run"
}

case_spill_read() {
  has_line "$(march)" 'STALLED 1' "the ledger.d record"
}

case_no_ledger() {
  assert_exit 3 bash "$RETRO" --ledger /nonexistent
}

# the last stage of a session ends at its last record, also a run it started; a sub run, a
# model without a price and a partial commander cost are marked; nothing is written
case_open_stage_and_marks() {
  local d=$TEST_ROOT/retro-fx2 out before
  mkdir -p "$d"
  {
    mark_rec stage 2026-03-05T10:00:00+0200 V a ship 1.00
    mark_rec wait 2026-03-05T10:10:00+0200 V a ship 1.20 | jq -c '.cost_basis = "partial"'
    run_rec run 2026-03-05T08:30:00+0000 s1 rev-1 reviewer m4 a \
      '{"status":"ok","seconds":60,"turns":1,"steers":0,"cost_usd":null,"cost_basis":"sub","cost_incomplete":false,"commander_session":"V"}'
    run_rec run 2026-03-05T08:00:00+0000 s2 rev-2 reviewer m5 a \
      '{"status":"ok","seconds":60,"turns":1,"steers":0,"cost_usd":null,"cost_basis":"none","cost_incomplete":false}'
  } >"$d/ledger.jsonl"
  before=$(ls -R "$d"; cksum "$d/ledger.jsonl")
  out=$(bash "$RETRO" --ledger "$d/ledger.jsonl" --since 2026-03-01 --project proj | tr -s ' ') || fail "retro failed"
  has_line "$out" 'ship 1 10m 0s 20m 0s ~$0.20' "open stage ends at the session's last record"
  has_line "$out" 'reviewer | m4 1 0 0 0 0 1 1.0 sub 0' "sub run"
  has_line "$out" 'reviewer | m5 1 0 0 0 0 1 1.0 ~$0.00 0' "unpriced run"
  has_line "$out" 'total: ~$0.20 (commander ~$0.20, workers ~$0.00)' "total marked"
  has_line "$out" 'sub runs (not in usd): 1' "sub runs counted apart"
  assert_eq "$(ls -R "$d"; cksum "$d/ledger.jsonl")" "$before" "read only"
  out=$(bash "$RETRO" --ledger "$d/ledger.jsonl" --since 2026-03-01 --project other | tr -s ' ') || fail "retro failed"
  no_row "$out" reviewer "another project"
  no_row "$out" ship "another project's stage"
}

# without --since: the 7 days that end today, or at --until
case_default_period() {
  local out today
  today=$(date +%Y-%m-%d)
  out=$(retro) || fail "retro failed"
  no_row "$out" 'developer |' "old records are outside the default period"
  assert_contains "$out" ".. $today" "default period ends today"
  out=$(retro --until 2026-03-16) || fail "retro failed"
  has_line "$out" 'retro: 2026-03-10 .. 2026-03-16' "7 days that end at --until"
  assert_exit 2 bash "$RETRO" --since yesterday
  assert_exit 2 bash "$RETRO" --task
}

case_period
case_fix_per_slice
case_events_top
case_two_tasks_one_session
case_spanning_stage
case_interrupted_counted
case_spill_read
case_no_ledger
case_open_stage_and_marks
case_default_period
printf 'retro.test.sh: all ten cases passed\n'
