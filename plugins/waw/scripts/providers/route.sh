#!/usr/bin/env bash
# providers/route.sh: `claude -p` under a worker route (a Claude Code config dir whose
# settings.json names the gateway: nexos.ai, OpenRouter, any Anthropic-compatible URL, or none
# for Anthropic itself). Usage: route.sh <input-file>.
# Environment: ATTACK_MODEL (required: the model id as the route names it, e.g.
# "GPT 6.1 Sol (trusted)" on nexos, "openai/gpt-6.1" on OpenRouter), ATTACK_EFFORT (optional),
# ROUTE_CONFIG_DIR (required: the route's config dir; its settings.json holds the URL and the
# key helper, so the user setting source is kept), ATTACK_PROGRESS (optional path: the line
# "first-output" is appended once, at the first model content or tool event of the stream: a
# content block start or delta, or an assistant message with text, thinking or a tool use;
# startup and diagnostic lines do not count).
# The prompt goes in on stdin; read-only tools only, no session file, no MCP.
# Stdout is the final answer only. A failed call, an error result or no result: exit 4.
set -euo pipefail
[ $# -eq 1 ] && [ -r "$1" ] || { echo "usage: route.sh <input-file>" >&2; exit 2; }
[ -n "${ATTACK_MODEL:-}" ] || { echo "route.sh: no model (set <ROUTE>_MODEL in the config)" >&2; exit 2; }
[ -n "${ROUTE_CONFIG_DIR:-}" ] && [ -f "$ROUTE_CONFIG_DIR/settings.json" ] ||
  { echo "route.sh: no route config (${ROUTE_CONFIG_DIR:-unset}/settings.json)" >&2; exit 4; }
command -v claude >/dev/null 2>&1 || { echo "route.sh: claude not found on PATH" >&2; exit 4; }
tmp=$(mktemp -d "${TMPDIR:-/tmp}/waw.route.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
args=(-p --model "$ATTACK_MODEL")
[ -z "${ATTACK_EFFORT:-}" ] || args+=(--effort "$ATTACK_EFFORT")
args+=(--tools "Read,Grep,Glob" --no-session-persistence --strict-mcp-config --setting-sources user)
args+=(--output-format stream-json --verbose --include-partial-messages)
# -R with fromjson?: a line that is not JSON must not end the reading of the stream.
progress='fromjson? | select(type == "object")
  | select((.type == "stream_event" and (.event.type == "content_block_start" or .event.type == "content_block_delta"))
    or (.type == "assistant" and ([.message.content[]? | select(.type == "text" or .type == "thinking" or .type == "tool_use")] | length > 0)))
  | "P"'
# A gateway's model ids are unknown to Claude Code, which warns about each on stderr. The
# filter is a pipe (stdout goes round it on fd 3), so it has ended when the script goes on.
{
  {
    rc=0
    CLAUDE_CONFIG_DIR="$ROUTE_CONFIG_DIR" claude "${args[@]}" <"$1" 2>&1 >&3 3>&- || rc=$?
    echo "$rc" >"$tmp/rc"
  } | { grep -v 'claude-code:unrecognized_model' >&2 3>&- || true; }
} 3>&1 | tee "$tmp/stream" | jq -R --unbuffered -r "$progress" 2>/dev/null |
  {
    if IFS= read -r _ && [ -n "${ATTACK_PROGRESS:-}" ]; then echo first-output >>"$ATTACK_PROGRESS"; fi
    cat >/dev/null
  } || true # the status of claude is in $tmp/rc; the result line is checked below
rc=$(cat "$tmp/rc")
{ grep '"type":"result"' "$tmp/stream" || true; } | tail -n 1 >"$tmp/result"
if [ "$rc" = 0 ] && jq -es 'length == 1 and .[0].is_error != true and (.[0].result | type == "string")' \
  "$tmp/result" >/dev/null 2>&1; then
  jq -r '.result' "$tmp/result"
  exit 0
fi
if [ -s "$tmp/result" ]; then
  jq -r '.result // .subtype // "route.sh: unreadable result"' "$tmp/result" >&2
elif [ "$rc" = 0 ]; then
  # after a failed call, what claude wrote on stderr stays the last line
  echo "route.sh: no result from claude" >&2
fi
exit 4
