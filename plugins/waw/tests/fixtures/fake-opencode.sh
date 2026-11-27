#!/usr/bin/env bash
# fixtures/fake-opencode.sh: a fake opencode CLI. Tests copy it to $TEST_ROOT/bin/opencode.
# Each call appends its argv as one line to $TEST_ROOT/opencode-args.log.
# FAKE_OPENCODE_MODE: ok (default), invalid, variant, fail, hang, stubborn, held.
# stubborn writes its child's pid to FAKE_OPENCODE_CHILD_PID_FILE
# (default $TEST_ROOT/opencode-child.pid); held waits for FAKE_OPENCODE_RELEASE.
set -u
all="$*"
printf '%s\n' "${all//$'\n'/ }" >>"$TEST_ROOT/opencode-args.log"
model=''
while [ $# -gt 0 ]; do
  case $1 in
    --model) model=${2:-}; shift ;;
  esac
  shift
done

ok_row() { printf '| blocker | a.txt:1 | fake finding | fix it |\n'; }

case ${FAKE_OPENCODE_MODE:-ok} in
  ok) ok_row ;;
  invalid) printf 'all fine pid %s\n' "$$" ;;
  variant)
    case $model in
      *'#'*) printf 'Error: Variant unavailable for %s: %s\n' "${model%%#*}" "${model#*#}" >&2; exit 1 ;;
    esac
    ok_row ;;
  fail) printf 'Error: rate limited\n' >&2; exit 1 ;;
  hang)
    trap 'exit 143' TERM
    sleep 300 &
    wait ;;
  stubborn)
    trap '' TERM
    sh -c 'trap "" TERM; sleep 300' &
    printf '%s\n' "$!" >"${FAKE_OPENCODE_CHILD_PID_FILE:-$TEST_ROOT/opencode-child.pid}"
    wait ;;
  held)
    ok_row
    n=0
    while [ ! -e "${FAKE_OPENCODE_RELEASE:-}" ] && [ "$n" -lt 300 ]; do
      sleep 0.1; n=$((n + 1))
    done ;;
  *) printf 'fake-opencode: unknown mode %s\n' "$FAKE_OPENCODE_MODE" >&2; exit 2 ;;
esac
exit 0
