#!/usr/bin/env bash
# tests/fixtures/fake-codex.sh — stands in for the codex CLI in agent.sh tests. Records each
# start (argv, the prompt on stdin, CODEX_HOME and the key variables it sees) under $TEST_ROOT
# and prints `codex exec --json` events as codex-cli 0.167 does. FAKE_CODEX_MODE:
#   ok (default)  thread.started, a shell command, an edit, the report (with a null field), turn.completed
#   fail          thread.started, then turn.failed
#   hang          thread.started, then sleeps until killed
set -u
trap 'exit 143' TERM INT
stdin=$(cat)
if [ -n "${TEST_ROOT:-}" ]; then
  { echo "=== ${AGENT_NAME:-none}"; printf '%s\n' "$@"; echo "--- stdin"; printf '%s\n' "$stdin"
    echo "--- env"; echo "CODEX_HOME=${CODEX_HOME:-}"; echo "OPENAI_API_KEY=${OPENAI_API_KEY:-unset}"
    echo "CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR:-unset}"; echo "AGENT_ROLE=${AGENT_ROLE:-unset}"; } >>"$TEST_ROOT/codex-args.log"
fi
tid=0199aaaa-bbbb-7ccc-8ddd-eeeeffff0001
case " $* " in *" resume "*) tid=$(printf '%s\n' "$@" | awk 'p { print; exit } $0 == "resume" { p = 1 }' | grep -v '^-' || echo "$tid") ;; esac
printf '{"type":"thread.started","thread_id":"%s"}\n' "$tid"
echo '{"type":"item.completed","item":{"id":"item_0","type":"error","message":"`--dangerously-bypass-hook-trust` is enabled. Enabled hooks may run without review for this invocation."}}'
echo '{"type":"turn.started"}'
case ${FAKE_CODEX_MODE:-ok} in
  fail) echo '{"type":"turn.failed","error":{"message":"fake codex failure"}}'; exit 1 ;;
  hang) sleep 300 & wait "$!"; exit 0 ;;
esac
echo '{"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"/bin/zsh -lc '"'"'pnpm test'"'"'","status":"in_progress"}}'
echo '{"type":"item.completed","item":{"id":"item_1","type":"command_execution","command":"/bin/zsh -lc '"'"'pnpm test'"'"'","aggregated_output":"ok\n","exit_code":0,"status":"completed"}}'
echo '{"type":"item.completed","item":{"id":"item_2","type":"file_change","changes":[{"path":"'"$PWD"'/src/a.ts","kind":"update"}],"status":"completed"}}'
echo '{"type":"item.completed","item":{"id":"item_3","type":"agent_message","text":"{\"status\":\"done\",\"summary\":\"fake codex report\",\"files_changed\":[],\"commands_run\":[{\"command\":\"pnpm test\",\"result\":\"pass\",\"note\":null}],\"out_of_scope_needs\":[],\"concerns\":[],\"blocker\":null,\"tests_added\":null}"}}'
echo '{"type":"turn.completed","usage":{"input_tokens":1000,"cached_input_tokens":800,"cache_write_input_tokens":0,"output_tokens":50,"reasoning_output_tokens":0}}'
exit 0
