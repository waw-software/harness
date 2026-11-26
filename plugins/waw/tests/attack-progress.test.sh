#!/usr/bin/env bash
# tests/attack-progress.test.sh — the claude, route and codex review adapters mark
# $ATTACK_PROGRESS on the first model content event, not on startup or diagnostic lines, and
# print only the final answer. Sourced by tests/run.sh (TEST_ROOT, SETUP_UNDER_TEST, fail,
# assert_eq, assert_contains).
set -u
set -m # each background adapter gets its own process group, so it is killed with its children

PROVIDERS_DIR=$SETUP_UNDER_TEST/providers
FIXTURES=$TESTS_DIR/fixtures

cp "$FIXTURES/fake-claude-print.sh" "$TEST_ROOT/bin/claude"
cp "$FIXTURES/fake-codex-exec.sh" "$TEST_ROOT/bin/codex"
chmod 755 "$TEST_ROOT/bin/claude" "$TEST_ROOT/bin/codex"
printf 'review this\n' >"$TEST_ROOT/input"

ADAPTER_PID=''
stop_adapter() {
  [ -n "$ADAPTER_PID" ] || return 0
  kill -TERM -- "-$ADAPTER_PID" 2>/dev/null
  wait "$ADAPTER_PID" 2>/dev/null
  ADAPTER_PID=''
}
trap stop_adapter EXIT

reset_case() {
  rm -f "$TEST_ROOT/p" "$TEST_ROOT/release" "$TEST_ROOT/out" "$TEST_ROOT/err" \
    "$TEST_ROOT/fake-claude-print-args.log" "$TEST_ROOT/fake-codex-exec-args.log"
}

start_adapter() { # start_adapter <adapter.sh>: in the background, with the progress file
  ATTACK_PROGRESS=$TEST_ROOT/p ATTACK_MODEL=test-model ROUTE_CONFIG_DIR=$TEST_ROOT/nexos-config \
    FAKE_RELEASE=$TEST_ROOT/release \
    "$PROVIDERS_DIR/$1" "$TEST_ROOT/input" >"$TEST_ROOT/out" 2>"$TEST_ROOT/err" &
  ADAPTER_PID=$!
}

progress_while_running() { # progress_while_running <adapter.sh>
  local n=0 rc=0
  start_adapter "$1"
  while ! grep -qx first-output "$TEST_ROOT/p" 2>/dev/null && [ "$n" -lt 50 ]; do
    sleep 0.1; n=$((n + 1))
  done
  grep -qx first-output "$TEST_ROOT/p" 2>/dev/null ||
    fail "$1: no progress mark: $(cat "$TEST_ROOT/err" "$TEST_ROOT/out")"
  kill -0 "$ADAPTER_PID" 2>/dev/null || fail "$1: the adapter ended before the release"
  : >"$TEST_ROOT/release"
  wait "$ADAPTER_PID" || rc=$?
  ADAPTER_PID=''
  assert_eq "$rc" 0 "$1 exit"
  assert_eq "$(cat "$TEST_ROOT/out")" 'No findings.' "$1 stdout"
  assert_eq "$(cat "$TEST_ROOT/p")" first-output "$1 progress file"
}

startup_only_no_progress() { # startup_only_no_progress <adapter.sh>
  start_adapter "$1"
  sleep 3
  kill -0 "$ADAPTER_PID" 2>/dev/null || fail "$1: the adapter is not running: $(cat "$TEST_ROOT/err")"
  [ ! -s "$TEST_ROOT/p" ] || fail "$1: startup lines marked progress"
  stop_adapter
}

has_arg() { # has_arg <fixture> <arg>
  grep -qx -- "$2" "$TEST_ROOT/$1-args.log" 2>/dev/null || fail "$1 was not called with $2"
}

# --- cases

case_route_progress_while_running() {
  reset_case
  export FAKE_CLAUDE_PRINT_MODE=held
  progress_while_running route.sh
  has_arg fake-claude-print --include-partial-messages
  has_arg fake-claude-print stream-json
  has_arg fake-claude-print --verbose
}

case_claude_startup_only_no_progress() {
  reset_case
  export FAKE_CLAUDE_PRINT_MODE=startup-only
  startup_only_no_progress claude.sh
  has_arg fake-claude-print --include-partial-messages
}

case_claude_error_result() {
  reset_case
  local rc=0
  FAKE_CLAUDE_PRINT_MODE=error "$PROVIDERS_DIR/claude.sh" "$TEST_ROOT/input" \
    >"$TEST_ROOT/out" 2>"$TEST_ROOT/err" || rc=$?
  assert_eq "$rc" 4 "claude.sh exit on an error result"
  assert_contains "$(cat "$TEST_ROOT/err")" 'API Error: 529' "claude.sh stderr"
  assert_eq "$(cat "$TEST_ROOT/out")" '' "claude.sh stdout"
}

case_codex_progress_while_running() {
  reset_case
  export FAKE_CODEX_EXEC_MODE=held
  progress_while_running codex.sh
  has_arg fake-codex-exec --json
}

case_codex_startup_only_no_progress() {
  reset_case
  export FAKE_CODEX_EXEC_MODE=startup-only
  startup_only_no_progress codex.sh
  has_arg fake-codex-exec --json
}

case_no_progress_env() {
  reset_case
  local adapter out rc
  export FAKE_CLAUDE_PRINT_MODE=ok FAKE_CODEX_EXEC_MODE=ok
  unset ATTACK_PROGRESS
  for adapter in claude.sh route.sh codex.sh; do
    rc=0
    out=$(ATTACK_MODEL=test-model ROUTE_CONFIG_DIR=$TEST_ROOT/nexos-config \
      "$PROVIDERS_DIR/$adapter" "$TEST_ROOT/input" 2>"$TEST_ROOT/err") || rc=$?
    assert_eq "$rc" 0 "$adapter exit: $(cat "$TEST_ROOT/err")"
    assert_eq "$out" 'No findings.' "$adapter stdout"
  done
}

case_route_progress_while_running
case_claude_startup_only_no_progress
case_claude_error_result
case_codex_progress_while_running
case_codex_startup_only_no_progress
case_no_progress_env
printf 'attack-progress.test.sh: all six cases passed\n'
