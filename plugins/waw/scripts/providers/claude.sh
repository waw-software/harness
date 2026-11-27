#!/usr/bin/env bash
# providers/claude.sh: `claude -p` adapter. Usage: claude.sh <input-file>.
# Environment: ATTACK_MODEL (default sonnet), ATTACK_EFFORT (optional), ATTACK_PROGRESS
# (optional path: the line "first-output" is appended once, at the first model content or tool
# event of the stream: a content block start or delta, or an assistant message with text,
# thinking or a tool use; startup and diagnostic lines do not count).
# The prompt goes in on stdin; read-only tools only, no session file, no MCP, no settings.
# Stdout is the final answer only. A failed call, an error result or no result: exit 4.
set -euo pipefail
[ $# -eq 1 ] && [ -r "$1" ] || { echo "usage: claude.sh <input-file>" >&2; exit 2; }
command -v claude >/dev/null 2>&1 || { echo "claude.sh: claude not found on PATH" >&2; exit 4; }
tmp=$(mktemp -d "${TMPDIR:-/tmp}/waw.claude.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
args=(-p --model "${ATTACK_MODEL:-sonnet}")
[ -z "${ATTACK_EFFORT:-}" ] || args+=(--effort "$ATTACK_EFFORT")
args+=(--tools "Read,Grep,Glob" --no-session-persistence --strict-mcp-config --setting-sources "")
args+=(--output-format stream-json --verbose --include-partial-messages)
# -R with fromjson?: a line that is not JSON must not end the reading of the stream.
progress='fromjson? | select(type == "object")
  | select((.type == "stream_event" and (.event.type == "content_block_start" or .event.type == "content_block_delta"))
    or (.type == "assistant" and ([.message.content[]? | select(.type == "text" or .type == "thinking" or .type == "tool_use")] | length > 0)))
  | "P"'
rc=0
claude "${args[@]}" <"$1" | tee "$tmp/stream" | jq -R --unbuffered -r "$progress" 2>/dev/null |
  {
    if IFS= read -r _ && [ -n "${ATTACK_PROGRESS:-}" ]; then echo first-output >>"$ATTACK_PROGRESS"; fi
    cat >/dev/null
  } || rc=${PIPESTATUS[0]}
{ grep '"type":"result"' "$tmp/stream" || true; } | tail -n 1 >"$tmp/result"
if [ "$rc" = 0 ] && jq -es 'length == 1 and .[0].is_error != true and (.[0].result | type == "string")' \
  "$tmp/result" >/dev/null 2>&1; then
  jq -r '.result' "$tmp/result"
  exit 0
fi
if [ -s "$tmp/result" ]; then
  jq -r '.result // .subtype // "claude.sh: unreadable result"' "$tmp/result" >&2
elif [ "$rc" = 0 ]; then
  # after a failed call, what claude wrote on stderr stays the last line
  echo "claude.sh: no result from claude" >&2
fi
exit 4
