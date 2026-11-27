#!/usr/bin/env bash
# tests/fixtures/fake-claude-usage.sh — stands in for the claude CLI in the agent.sh ledger
# tests. A test copies this over the $TEST_ROOT/bin/claude sentinel and names TEST_ROOT and
# the FAKE_* variables in AGENT_WORKER_ENV. Each start adds a line (the worker name) to
# $TEST_ROOT/usage-starts; <start> below is the number of lines after that.
#   FAKE_USAGE_JSON   the usage object (default {"input_tokens":10,"output_tokens":5}); give
#                     cache_creation{ephemeral_5m_input_tokens,ephemeral_1h_input_tokens}
#                     in it for the cache tiers
#   FAKE_TOTAL_COST   the result's total_cost_usd (default 0)
#   FAKE_MESSAGE_MODEL  optional: the assistant line's message.model (default: none)
# FAKE_CLAUDE_USAGE_MODE:
#   ok (default)  one assistant line (message.id m<start>, the usage), then the result
#   first-hangs   the first start hangs without a result; later starts act as ok
#   events-hang   appends a QUESTION and an APPROVAL event of this worker to $AGENT_EVENTS,
#                 prints a Bash call that worker-guard blocked, then hangs
#   events-ok     appends a QUESTION event of this worker and one of the worker
#                 other-worker to $AGENT_EVENTS, then acts as ok
set -u
trap 'exit 143' TERM INT

echo "${AGENT_NAME:-none}" >>"$TEST_ROOT/usage-starts"
start=$(wc -l <"$TEST_ROOT/usage-starts" | tr -d ' ')

usage=${FAKE_USAGE_JSON:-}
[ -n "$usage" ] || usage='{"input_tokens":10,"output_tokens":5}'

hang() { sleep 300 & wait "$!"; exit 0; }

event() { # event <type> <worker name> <text>: a line in the form of agent.sh's emit
  printf '%s %s %s: %s\n' "$(date +%H:%M:%S)" "$1" "$2" "$3" >>"$AGENT_EVENTS"
}

ok() {
  jq -nc --arg id "m$start" --argjson u "$usage" --arg m "${FAKE_MESSAGE_MODEL:-}" \
    '{type: "assistant", message: ({id: $id, content: [{type: "text", text: "fake claude step"}],
      usage: $u} + (if $m == "" then {} else {model: $m} end))}'
  jq -nc --argjson u "$usage" --argjson c "${FAKE_TOTAL_COST:-0}" \
    '{type: "result", subtype: "success", is_error: false, num_turns: 1, usage: $u,
      total_cost_usd: $c, structured_output: {status: "done", summary: "x"}}'
}

case ${FAKE_CLAUDE_USAGE_MODE:-ok} in
  ok) ok ;;
  first-hangs)
    [ "$start" -ne 1 ] || hang
    ok
    ;;
  events-hang)
    event QUESTION "$AGENT_NAME" q1
    event APPROVAL "$AGENT_NAME" a1
    printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"x"}}]}}'
    printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"blocked by worker-guard"}]}}'
    hang
    ;;
  events-ok)
    event QUESTION "$AGENT_NAME" q1
    event QUESTION other-worker q2
    ok
    ;;
  *)
    echo "fake-claude-usage.sh: unknown FAKE_CLAUDE_USAGE_MODE" >&2
    exit 2
    ;;
esac
exit 0
