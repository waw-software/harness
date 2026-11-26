#!/usr/bin/env bash
# tests/ledger-run.test.sh — agent.sh's run records in the ledger: run-start and run, and the
# cost of one run from its own result usage.
# Sourced by tests/run.sh into a fresh subshell. The claude sentinel is replaced by
# tests/fixtures/fake-claude-usage.sh: real agent.sh runs, no model.
set -u

AGENT=$SETUP_UNDER_TEST/agent.sh
STAGE=$SETUP_UNDER_TEST/stage.sh
ROOT=$TEST_ROOT/ledger-run
LEDGER=$AGENT_STATE_DIR/ledger.jsonl
REPO=$ROOT/myrepo
OUT=$REPO/.ship/s1/agents
export AGENT_WORKER_ENV="TEST_ROOT FAKE_CLAUDE_USAGE_MODE FAKE_USAGE_JSON FAKE_TOTAL_COST"
export AGENT_PRICES=$TEST_ROOT/prices.tsv
printf 'test-investigator-model\t1\t2\t0.1\t1.25\t2\n' >"$AGENT_PRICES"
cp "$TESTS_DIR/fixtures/fake-claude-usage.sh" "$TEST_ROOT/bin/claude"
chmod 755 "$TEST_ROOT/bin/claude"
mkdir -p "$ROOT"
git init -q "$REPO" || fail "git init"
printf 'a ledger test\n' >"$ROOT/brief.md"

run_agent() { # run_agent <name> [agent.sh run args...]
  local n=$1; shift
  bash "$AGENT" run --role investigator --brief "$ROOT/brief.md" --out "$OUT" --cwd "$REPO" \
    --name "$n" --quiet "$@" >"$ROOT/$n.log" 2>"$ROOT/$n.err"
}
# record <kind> <name> <jq filter>: of the one ledger record of that kind and name
record() {
  local all
  all=$(jq -c --arg k "$1" --arg n "$2" 'select(.kind == $k and .name == $n)' "$LEDGER")
  assert_eq "$(printf '%s\n' "$all" | grep -c .)" 1 "$1 records of $2" >&2
  printf '%s' "$all" | jq -r "$3"
}
assert_record() { # assert_record <kind> <name> <jq condition>
  [ "$(record "$1" "$2" "$3")" = true ] ||
    fail "$1 record of $2 does not satisfy: $3 -- $(jq -c --arg n "$2" 'select(.name == $n)' "$LEDGER")"
}
starts() { wc -l <"$TEST_ROOT/usage-starts" 2>/dev/null | tr -d ' '; }

case_run_records() {
  CLAUDE_CODE_SESSION_ID=commander-1 run_agent inv-r || fail "inv-r: $(cat "$ROOT/inv-r.err")"
  assert_eq "$(record run-start inv-r .run_id)" "$(record run inv-r .run_id)" "one run_id"
  assert_record run-start inv-r '.v == 1 and (.run_id | length) > 0 and .task == "s1" and .project == "myrepo"
    and .role == "investigator" and .model == "test-investigator-model" and .route == "nexos"
    and .runner == "claude" and .resumed == false and .commander_session == "commander-1"
    and (.cwd | endswith("/myrepo")) and (.run_dir | endswith("/.ship/s1/agents"))'
  assert_record run inv-r '.task == "s1" and .project == "myrepo" and .status == "ok"
    and .turns == 1 and .steers == 0 and .segments == 1 and .results == 1
    and .cost_incomplete == false and .cost_basis == "tokens" and (.seconds | type) == "number"
    and (.end | type) == "string" and .tokens.uncached_in == 10 and .tokens.out == 5'
}

case_resume_not_cumulative() {
  FAKE_USAGE_JSON='{"input_tokens":1000,"output_tokens":100}' FAKE_TOTAL_COST=0.40 \
    run_agent inv-1 || fail "inv-1"
  local s
  s=$(record run inv-1 .session)
  FAKE_USAGE_JSON='{"input_tokens":500,"output_tokens":50}' FAKE_TOTAL_COST=0.49 \
    run_agent inv-1-fix1 --resume "$s" || fail "inv-1-fix1"
  assert_record run inv-1-fix1 '((.cost_usd - 0.0006) | fabs) < 1e-12 and .cost_cc == 0.49
    and .resumed == true'
  assert_eq "$(record run inv-1-fix1 .session)" "$s" "same session"
  assert_eq "$(awk -F'\t' '$2 == "inv-1-fix1" { print $11 }' "$OUT/runs.tsv")" 0.49 "runs.tsv cost"
}

case_three_resumes() {
  FAKE_USAGE_JSON='{"input_tokens":100,"output_tokens":10}' FAKE_TOTAL_COST=0.1 \
    run_agent inv-3 || fail "inv-3"
  local s i
  s=$(record run inv-3 .session)
  for i in 1 2 3; do
    FAKE_USAGE_JSON="{\"input_tokens\":${i}000,\"output_tokens\":${i}00}" FAKE_TOTAL_COST=$i \
      run_agent "inv-3-fix$i" --resume "$s" || fail "inv-3-fix$i"
  done
  for i in 1 2 3; do
    # i * (1000 * 1 + 100 * 2) / 1e6
    assert_record run "inv-3-fix$i" "((.cost_usd - $i * 0.0012) | fabs) < 1e-12 and .cost_cc == $i"
  done
}

case_cache_tiers() {
  FAKE_USAGE_JSON='{"input_tokens":10,"cache_read_input_tokens":1000,"cache_creation_input_tokens":300,"cache_creation":{"ephemeral_5m_input_tokens":100,"ephemeral_1h_input_tokens":200},"output_tokens":5}' \
    run_agent inv-c || fail "inv-c"
  assert_record run inv-c '.tokens == {uncached_in: 10, cache_read: 1000, cache_write: 300,
      cache_write_5m: 100, cache_write_1h: 200, out: 5}
    and ((.cost_usd - (10*1 + 1000*0.1 + 100*1.25 + 200*2 + 5*2) / 1000000) | fabs) < 1e-12'
}

case_steer_interrupted_segment() {
  : >"$TEST_ROOT/usage-starts"
  FAKE_CLAUDE_USAGE_MODE=first-hangs FAKE_USAGE_JSON='{"input_tokens":70,"output_tokens":7}' \
    run_agent inv-s &
  local pid=$! n=0
  while [ "$(starts)" != 1 ]; do
    n=$((n + 1)); [ "$n" -le 250 ] || fail "inv-s never started: $(cat "$ROOT/inv-s.err")"
    sleep 0.1
  done
  bash "$AGENT" steer inv-s 'go on' >/dev/null || fail "steer"
  assert_exit 0 wait "$pid"
  assert_record run inv-s '.status == "ok" and .segments == 2 and .results == 1 and .steers == 1
    and .cost_incomplete == true and .tokens.uncached_in == 70 and .tokens.out == 7'
}

case_concurrent_runs_and_marks() {
  local i pids=''
  for i in 1 2 3; do run_agent "inv-p$i" & pids="$pids $!"; done
  for i in 1 2 3 4 5 6 7 8 9 10; do
    bash "$STAGE" "mark-$i" --session S --task t >"$ROOT/mark-$i.log" 2>&1 &
    pids="$pids $!"
  done
  for i in $pids; do assert_exit 0 wait "$i"; done
  jq -e . "$LEDGER" >/dev/null || fail "a ledger line does not parse"
  assert_eq "$(jq -s 'length' "$LEDGER")" "$(wc -l <"$LEDGER" | tr -d ' ')" "one record per line"
  assert_eq "$(jq -c 'select(.kind == "run" and (.name | startswith("inv-p")))' "$LEDGER" | grep -c .)" \
    3 "run records"
  assert_eq "$(jq -c 'select(.kind == "stage" and .session == "S")' "$LEDGER" | grep -c .)" \
    10 "stage records"
}

case_run_records
case_resume_not_cumulative
case_three_resumes
case_cache_tiers
case_steer_interrupted_segment
case_concurrent_runs_and_marks
