#!/usr/bin/env bash
# tests/fixtures/fake-codex-exec.sh — stands in for `codex exec --json` in the review adapter
# tests. A test copies this to $TEST_ROOT/bin/codex. Records its argv in
# $TEST_ROOT/fake-codex-exec-args.log. FAKE_CODEX_EXEC_MODE:
#   ok (default)  the hook-trust diagnostic, the agent message, turn.completed
#   held          as ok, but holds after the agent message until $FAKE_RELEASE exists (at most 30 s)
#   startup-only  thread.started, the diagnostic, turn.started, then sleeps until killed
set -u
trap 'exit 143' TERM INT
cat >/dev/null
[ -z "${TEST_ROOT:-}" ] || printf '%s\n' "$@" >>"$TEST_ROOT/fake-codex-exec-args.log"
mode=${FAKE_CODEX_EXEC_MODE:-ok}
answer=''
while [ $# -gt 0 ]; do
  [ "$1" != --output-last-message ] || answer=${2:-}
  shift
done

echo '{"type":"thread.started","thread_id":"0199aaaa-bbbb-7ccc-8ddd-eeeeffff0001"}'
echo '{"type":"item.completed","item":{"id":"item_0","type":"error","message":"`--dangerously-bypass-hook-trust` is enabled."}}'
echo '{"type":"turn.started"}'
if [ "$mode" = startup-only ]; then
  sleep 300 & wait "$!"
  exit 0
fi
echo '{"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"No findings."}}'
if [ "$mode" = held ]; then
  n=0
  while [ ! -e "${FAKE_RELEASE:-/nonexistent}" ] && [ "$n" -lt 300 ]; do
    sleep 0.1; n=$((n + 1))
  done
fi
[ -z "$answer" ] || printf '%s\n' 'No findings.' >"$answer"
echo '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":5}}'
exit 0
