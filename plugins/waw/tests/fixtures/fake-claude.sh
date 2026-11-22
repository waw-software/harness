#!/usr/bin/env bash
# tests/fixtures/fake-claude.sh — stands in for the claude CLI in agent.sh tests.
# A test copies this over the $TEST_ROOT/bin/claude sentinel; agent.sh then execs it.
# Records every start (worker name and argv) under $TEST_ROOT, and behaves by
# FAKE_CLAUDE_MODE:
#   ok (default)  one assistant step, then a schema result, exit 0
#   barrier       hold until FAKE_CLAUDE_BARRIER exists (bounded), then report
#   no-result     exit 0 without any result line (the run reports 4)
#   hang          sleep until killed (TERM/INT), never reports
set -u
trap 'exit 143' TERM INT
if [ -n "${TEST_ROOT:-}" ]; then
  # one line per start: the schema in the argv holds newlines, so flatten them
  printf '%s\t%s\n' "${AGENT_NAME:-none}" "$(printf '%s' "$*" | tr '\t\n' '  ')" \
    >>"$TEST_ROOT/claude-starts.log"
  { echo "=== ${AGENT_NAME:-none}"; printf '%s\n' "$@"; } >>"$TEST_ROOT/claude-args.log"
  # the environment this start received, keyed by worker name
  env >"$TEST_ROOT/claude-env-${AGENT_NAME:-none}.log"
fi

result() {
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"fake claude step"}]}}'
  printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"usage":{"input_tokens":10,"output_tokens":5},"total_cost_usd":0,"structured_output":{"status":"done","summary":"fake worker report"}}'
}

case ${FAKE_CLAUDE_MODE:-ok} in
  no-result) exit 0 ;;
  hang)
    sleep 300 & wait "$!"
    ;;
  barrier)
    n=0
    while [ ! -e "${FAKE_CLAUDE_BARRIER:-/nonexistent}" ] && [ "$n" -lt 1200 ]; do
      sleep 0.1; n=$((n + 1))
    done
    result
    ;;
  *) result ;;
esac
exit 0
