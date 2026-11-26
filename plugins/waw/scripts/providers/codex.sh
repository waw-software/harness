#!/usr/bin/env bash
# providers/codex.sh: OpenAI Codex CLI adapter. Usage: codex.sh <input-file>.
# Environment: ATTACK_MODEL (optional, empty = CLI default), ATTACK_EFFORT (optional),
# ATTACK_PROGRESS (optional path: the line "first-output" is appended once, at the first model
# content or tool event: an item.started or item.completed whose item is not an error; startup
# and diagnostic lines do not count).
# Prompt on stdin, read-only sandbox, no session files; the answer is the last message.
set -euo pipefail
[ $# -eq 1 ] && [ -r "$1" ] || { echo "usage: codex.sh <input-file>" >&2; exit 2; }
command -v codex >/dev/null 2>&1 || { echo "codex.sh: codex not found on PATH" >&2; exit 4; }
tmp=$(mktemp -d "${TMPDIR:-/tmp}/waw.gpt.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
args=(exec --sandbox read-only --ephemeral --ignore-user-config --ignore-rules
  --skip-git-repo-check --color never --json --output-last-message "$tmp/answer")
[ -z "${ATTACK_MODEL:-}" ] || args+=(--model "$ATTACK_MODEL")
if [ -n "${ATTACK_EFFORT:-}" ]; then
  [[ $ATTACK_EFFORT =~ ^[a-z]+$ ]] || { echo "codex.sh: bad EFFORT '$ATTACK_EFFORT'" >&2; exit 4; }
  args+=(-c "model_reasoning_effort=\"$ATTACK_EFFORT\"")
fi
args+=(-)
# -R with fromjson?: the stream is also the log, with the lines codex writes on stderr.
progress='fromjson? | select(type == "object")
  | select((.type == "item.started" or .type == "item.completed") and (.item.type != "error"))
  | "P"'
rc=0
codex "${args[@]}" <"$1" 2>&1 | tee "$tmp/stream" | jq -R --unbuffered -r "$progress" 2>/dev/null |
  {
    if IFS= read -r _ && [ -n "${ATTACK_PROGRESS:-}" ]; then echo first-output >>"$ATTACK_PROGRESS"; fi
    cat >/dev/null
  } || rc=${PIPESTATUS[0]}
[ "$rc" = 0 ] || { cat "$tmp/stream" >&2; exit 4; }
grep -q '[^[:space:]]' "$tmp/answer" 2>/dev/null || { cat "$tmp/stream" >&2; echo "codex.sh: empty answer" >&2; exit 4; }
cat "$tmp/answer"
