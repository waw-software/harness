#!/usr/bin/env bash
# tests/fixtures/fake-claude-print.sh — stands in for `claude -p --output-format stream-json`
# in the review adapter tests. A test copies this over the $TEST_ROOT/bin/claude sentinel.
# Records its argv in $TEST_ROOT/fake-claude-print-args.log. FAKE_CLAUDE_PRINT_MODE:
#   ok (default)  startup events, one content delta, the assistant text, the result
#   held          as ok, but holds after the delta until $FAKE_RELEASE exists (at most 30 s)
#   startup-only  startup events and no model content, then sleeps until killed
#   error         init, then a result with is_error
set -u
trap 'exit 143' TERM INT
cat >/dev/null
[ -z "${TEST_ROOT:-}" ] || printf '%s\n' "$@" >>"$TEST_ROOT/fake-claude-print-args.log"
mode=${FAKE_CLAUDE_PRINT_MODE:-ok}

echo '{"type":"system","subtype":"init","session_id":"fake-print-session"}'
if [ "$mode" = error ]; then
  echo '{"type":"result","subtype":"success","is_error":true,"result":"API Error: 529"}'
  exit 1
fi
echo '{"type":"system","subtype":"api_retry","attempt":1}'
if [ "$mode" = startup-only ]; then
  echo '{"type":"rate_limit_event","rate_limit_info":{"status":"allowed"}}'
  echo '{"type":"stream_event","event":{"type":"message_start","message":{"content":[]}}}'
  sleep 300 & wait "$!"
  exit 0
fi
echo '{"type":"stream_event","event":{"type":"message_start","message":{"content":[]}}}'
echo '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"No "}}}'
if [ "$mode" = held ]; then
  n=0
  while [ ! -e "${FAKE_RELEASE:-/nonexistent}" ] && [ "$n" -lt 300 ]; do
    sleep 0.1; n=$((n + 1))
  done
fi
echo '{"type":"assistant","message":{"content":[{"type":"text","text":"No findings."}]}}'
echo '{"type":"result","subtype":"success","is_error":false,"result":"No findings."}'
exit 0
