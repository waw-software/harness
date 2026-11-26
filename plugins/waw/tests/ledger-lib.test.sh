#!/usr/bin/env bash
# tests/ledger-lib.test.sh — scripts/lib/ledger.sh: record check, locked append, the stale
# and the held lock, the home chain and price_any. Sourced by tests/run.sh (TEST_ROOT,
# SETUP_UNDER_TEST, AGENT_STATE_DIR, fail, assert_eq, assert_contains).
set -u

LIB=$SETUP_UNDER_TEST/lib/ledger.sh
[ -r "$LIB" ] || fail "no $LIB"
. "$LIB"

LEDGER=$AGENT_STATE_DIR/ledger.jsonl
LOCK=$AGENT_STATE_DIR/ledger.lock.d
NOW=2026-01-02T03:04:05+0000

reset_state() { rm -rf "$AGENT_STATE_DIR"; mkdir -p "$AGENT_STATE_DIR"; }
lines_of() { if [ -f "$1" ]; then wc -l <"$1" | tr -d ' '; else echo 0; fi; }

case_append_shape() {
  reset_state
  ledger_append "{\"v\": 1,
    \"kind\": \"test\", \"t\": \"$NOW\"}" || fail "append of a valid record returned $?"
  assert_eq "$(lines_of "$LEDGER")" 1 "one line"
  assert_eq "$(jq -r .kind "$LEDGER")" test "the line is the record"
  local bad rc
  for bad in "{\"kind\":\"test\",\"t\":\"$NOW\"}" 'not json' '[1]' ''; do
    rc=0
    ledger_append "$bad" 2>"$TEST_ROOT/bad.err" || rc=$?
    assert_eq "$rc" 0 "return of an invalid record [$bad]"
    assert_contains "$(cat "$TEST_ROOT/bad.err")" "ledger" "warning for [$bad]"
  done
  assert_eq "$(lines_of "$LEDGER")" 1 "invalid records write nothing"
}

case_concurrent_writers() {
  reset_state
  local i pad
  pad=$(printf '%020000d' 0)
  for i in $(seq 1 30); do
    ledger_append "{\"v\":1,\"kind\":\"test\",\"t\":\"$NOW\",\"id\":$i,\"pad\":\"$pad\"}" &
  done
  wait
  assert_eq "$(jq -c . "$LEDGER" | wc -l | tr -d ' ')" 30 "parsed records"
  assert_eq "$(lines_of "$LEDGER")" 30 "lines"
  while IFS= read -r i; do
    printf '%s\n' "$i" | jq -e '.pad | length == 20000' >/dev/null || fail "a torn line"
  done <"$LEDGER"
  assert_eq "$(jq -s -c 'map(.id) | sort' "$LEDGER")" "$(jq -nc '[range(1; 31)]')" "ids"
  assert_eq "$(ls -A "$AGENT_STATE_DIR/ledger.d" 2>/dev/null)" "" "no spill files"
}

case_stale_lock() {
  reset_state
  mkdir "$LOCK"
  local old
  old=$(date -v-60S +%Y%m%d%H%M.%S 2>/dev/null) || old=$(date -d '60 seconds ago' +%Y%m%d%H%M.%S)
  touch -t "$old" "$LOCK"
  ledger_append "{\"v\":1,\"kind\":\"test\",\"t\":\"$NOW\"}"
  assert_eq "$(lines_of "$LEDGER")" 1 "appended past a stale lock"
  [ ! -e "$LOCK" ] || fail "the lock dir is still there"
}

case_held_lock_spills() {
  reset_state
  mkdir "$LOCK"
  local rc=0 spill
  LEDGER_LOCK_TRIES=3 ledger_append "{\"v\":1,\"kind\":\"test\",\"t\":\"$NOW\",\"id\":7}" \
    2>"$TEST_ROOT/spill.err" || rc=$?
  assert_eq "$rc" 0 "return with a held lock"
  assert_eq "$(lines_of "$LEDGER")" 0 "nothing in the ledger"
  set -- "$AGENT_STATE_DIR"/ledger.d/*
  [ $# -eq 1 ] && [ -f "$1" ] || fail "expected one spill file, got: $*"
  spill=$1
  assert_eq "$(jq -r .id "$spill")" 7 "the spilled record"
  assert_contains "$(cat "$TEST_ROOT/spill.err")" "ledger" "warning on stderr"
  [ -d "$LOCK" ] || fail "another writer's fresh lock was removed"
}

case_home_chain() {
  assert_eq "$(unset AGENT_STATE_DIR WAW_HOME; CLAUDE_CONFIG_DIR=$TEST_ROOT/cc ledger_file)" \
    "$TEST_ROOT/cc/waw/state/ledger.jsonl" "from CLAUDE_CONFIG_DIR"
  assert_eq "$(unset AGENT_STATE_DIR WAW_HOME CLAUDE_CONFIG_DIR CLAUDE_HOME; ledger_file)" \
    "$HOME/.claude/waw/state/ledger.jsonl" "from HOME"
  assert_eq "$(unset AGENT_STATE_DIR; WAW_HOME=$TEST_ROOT//wh ledger_file)" \
    "$TEST_ROOT/wh/state/ledger.jsonl" "from WAW_HOME, // collapsed"
  assert_eq "$(CLAUDE_CONFIG_DIR=$TEST_ROOT/cc; AGENT_STATE_DIR=$TEST_ROOT/sd ledger_file)" \
    "$TEST_ROOT/sd/ledger.jsonl" "AGENT_STATE_DIR wins"
}

case_price_any() {
  : >"$TEST_ROOT/empty-prices.tsv"
  local AGENT_PRICES=$TEST_ROOT/empty-prices.tsv
  assert_eq "$(price_any claude-opus-5-5)" "4 20 0.2 5 8" "opus from the defaults"
  assert_eq "$(price_any claude-sonnet-5-5)" "2 10 0.1 2.5 4" "sonnet"
  assert_eq "$(price_any claude-haiku-5-5)" "0.1 0.5 0.01 0.125 0.2" "haiku"
  assert_eq "$(price_any claude-fable-5-2)" "8 40 0.2 10 16" "fable"
  assert_eq "$(price_any no-such-model)" "" "unknown model"
  printf '# p\nclaude-opus-5-5\t1\t2\t0.1\t\nMy Model (x)\t3\t4\t0.5\t6\t7\n' >"$AGENT_PRICES"
  assert_eq "$(price_any claude-opus-5-5)" "1 2 0.1 1 2" "own file first; empty cw and cw1h"
  assert_eq "$(price_any 'My Model (x)')" "3 4 0.5 6 7" "six columns, spaces in the name"
}

case_project() {
  local repo=$TEST_ROOT/proj-x
  git init -q "$repo"
  git -C "$repo" commit -q --allow-empty -m init
  git -C "$repo" worktree add -q "$TEST_ROOT/wt-y" -b wt-y
  assert_eq "$(ledger_project "$repo")" proj-x "main checkout"
  assert_eq "$(ledger_project "$TEST_ROOT/wt-y")" proj-x "a worktree"
  mkdir -p "$TEST_ROOT/plain-z"
  assert_eq "$(GIT_CEILING_DIRECTORIES=$TEST_ROOT ledger_project "$TEST_ROOT/plain-z")" plain-z \
    "not a repository"
}

case_append_shape
case_concurrent_writers
case_stale_lock
case_held_lock_spills
case_home_chain
case_price_any
case_project
printf 'ledger-lib.test.sh: all seven cases passed\n'
