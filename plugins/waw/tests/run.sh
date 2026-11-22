#!/usr/bin/env bash
# tests/run.sh — isolated test entry point for the waw staging copy.
#
#   bash tests/run.sh [<name>.test.sh ...]
#
# Without arguments every tests/*.test.sh in this directory runs, sorted; none
# found: exit 2. Arguments must be basenames of files in this directory. Each
# test is sourced into a fresh subshell with a private TEST_ROOT: its own HOME,
# config, state, worktrees, git pinned to local files, and a PATH whose
# sentinel claude/glab/gh/orca/pnpm/npm/yarn records any call in an audit
# marker and fails — the runner fails the test on markers even where the code
# under test swallowed the nonzero exit. Test helpers: fail, assert_eq,
# assert_contains, assert_exit. Output: "PASS <basename>" or "FAIL <basename>"
# per test and a final count. Exit 0 all passed, 1 a test failed, 2 invalid
# arguments. Before removing a TEST_ROOT its process group is signalled and
# waited for.
set -u
set -m
unset CDPATH

TESTS_DIR=$(cd "$(dirname "$0")" && pwd -P) || exit 2
SETUP_UNDER_TEST=$(cd "$TESTS_DIR/../scripts" && pwd -P) || exit 2
ORIG_PATH=$PATH

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "${3:-value}: expected [$2], got [$1]"; }
assert_contains() { case $1 in *"$2"*) ;; *) fail "${3:-string}: [$1] lacks [$2]";; esac; }
assert_exit() { # assert_exit <expected-rc> <command...>
  local want=$1 rc=0; shift
  "$@" || rc=$?
  [ "$rc" -eq "$want" ] || fail "exit: expected $want, got $rc from: $*"
}

selected=()
if [ $# -eq 0 ]; then
  set -- "$TESTS_DIR"/*.test.sh
  [ -e "${1:-}" ] || { printf 'run.sh: no *.test.sh in %s\n' "$TESTS_DIR" >&2; exit 2; }
  for f in "$@"; do selected+=("$(basename "$f")"); done
else
  for a in "$@"; do
    case $a in */*) printf 'run.sh: not a basename: %s\n' "$a" >&2; exit 2;; esac
    [ -f "$TESTS_DIR/$a" ] || { printf 'run.sh: no such test: %s\n' "$a" >&2; exit 2; }
    selected+=("$a")
  done
fi

CUR_ROOT='' CUR_TPID=''
cleanup_test() { # signal the test's process group, wait bounded, remove its root
  local pgid=$1 root=$2 n=0
  if [ -n "$pgid" ]; then
    kill -TERM -- "-$pgid" 2>/dev/null
    while [ "$n" -lt 50 ] && kill -0 -- "-$pgid" 2>/dev/null; do
      sleep 0.1; n=$((n + 1))
    done
    kill -KILL -- "-$pgid" 2>/dev/null
  fi
  [ -n "$root" ] && rm -rf "$root"
  return 0
}
trap 'cleanup_test "$CUR_TPID" "$CUR_ROOT"; CUR_ROOT=' EXIT

require_under() { # the isolation paths must really sit under the test root
  case $1 in "$TEST_ROOT"|"$TEST_ROOT"/*) ;; *)
    printf 'run.sh: %s is not under TEST_ROOT (%s)\n' "$1" "$TEST_ROOT" >&2; exit 2;; esac
}

run_one() {
  local t=$1 rc s th ts tc tw tn
  TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/waw-test.XXXXXXXX") || return 2
  TEST_ROOT=$(cd "$TEST_ROOT" && pwd -P) || return 2
  chmod 700 "$TEST_ROOT"
  CUR_ROOT=$TEST_ROOT
  mkdir -p "$TEST_ROOT/home" "$TEST_ROOT/state" "$TEST_ROOT/worktrees" \
    "$TEST_ROOT/bin" "$TEST_ROOT/audit" "$TEST_ROOT/nexos-config"
  for s in claude glab gh orca pnpm npm yarn; do
    cat >"$TEST_ROOT/bin/$s" <<EOF
#!/bin/sh
printf '%s\n' "$s \$*" >> "$TEST_ROOT/audit/$s.log"
exit 127
EOF
    chmod 755 "$TEST_ROOT/bin/$s"
  done
  printf '{}\n' >"$TEST_ROOT/nexos-config/settings.json"
  cat >"$TEST_ROOT/config" <<EOF
NEXOS_CONFIG_DIR="$TEST_ROOT/nexos-config"
AGENT_INVESTIGATOR_MODEL="test-investigator-model"
AGENT_DEVELOPER_MODEL="test-developer-model"
AGENT_REVIEWER_MODEL="test-reviewer-model"
AGENT_TESTER_MODEL="test-tester-model"
EOF
  th=$TEST_ROOT/home ts=$TEST_ROOT/state tc=$TEST_ROOT/config
  tw=$TEST_ROOT/worktrees tn=$TEST_ROOT/nexos-config
  require_under "$th"; require_under "$ts"; require_under "$tc"
  require_under "$tw"; require_under "$tn"
  (
    export HOME=$th AGENT_STATE_DIR=$ts WAW_CONFIG=$tc AGENTIC_WORKTREES=$tw \
      AGENT_PUSH_GUARD=$SETUP_UNDER_TEST/hooks/guard-push.sh NEXOS_CONFIG_DIR=$tn \
      TEST_ROOT=$TEST_ROOT SETUP_UNDER_TEST=$SETUP_UNDER_TEST
    export PATH="$TEST_ROOT/bin:$ORIG_PATH" GIT_CONFIG_NOSYSTEM=1 \
      GIT_CONFIG_GLOBAL=$TEST_ROOT/gitconfig GIT_TERMINAL_PROMPT=0 GIT_ALLOW_PROTOCOL=file \
      GIT_AUTHOR_NAME=waw-test GIT_AUTHOR_EMAIL=test@example.invalid \
      GIT_COMMITTER_NAME=waw-test GIT_COMMITTER_EMAIL=test@example.invalid
    unset AGENT_ROLE AGENT_NAME AGENT_SCOPE AGENT_RUN_DIR AGENT_EVENTS AGENT_ALLOW_INSTALL \
      AGENT_GRANTS AGENT_SANDBOX AGENT_PRICES AGENT_STALL_SECONDS AGENT_MAX_WORKERS AGENT_SLOT_WAIT_SECONDS \
      AGENT_TEST_PAUSE_AFTER_ACQUIRE AGENT_TEST_PAUSE_AFTER_GATE AGENT_TEST_PAUSE_BEFORE_GATE \
      AGENT_INVESTIGATOR_MODEL AGENT_DEVELOPER_MODEL AGENT_REVIEWER_MODEL AGENT_TESTER_MODEL \
      CLAUDE_CONFIG_DIR WAW_HOME
    cd "$TEST_ROOT" || exit 2
    . "$TESTS_DIR/$t"
  ) >"$TEST_ROOT/test.log" 2>&1 &
  CUR_TPID=$!
  wait "$CUR_TPID" 2>/dev/null
  rc=$?
  if [ -n "$(ls -A "$TEST_ROOT/audit" 2>/dev/null)" ]; then
    printf 'run.sh: unexpected sentinel call in %s:\n' "$t" >&2
    cat "$TEST_ROOT"/audit/*.log >&2
    rc=1
  fi
  [ "$rc" -ne 0 ] && sed 's/^/  | /' "$TEST_ROOT/test.log" >&2
  cleanup_test "$CUR_TPID" "$TEST_ROOT"
  CUR_ROOT=''; CUR_TPID=''
  return $rc
}

pass=0 failed=0
for t in "${selected[@]}"; do
  if run_one "$t"; then
    printf 'PASS %s\n' "$t"; pass=$((pass + 1))
  else
    printf 'FAIL %s\n' "$t"; failed=$((failed + 1))
  fi
done
printf 'tests: %d passed, %d failed\n' "$pass" "$failed"
[ "$failed" -eq 0 ] && exit 0
exit 1
