#!/usr/bin/env bash
# providers/claude.sh: `claude -p` adapter. Usage: claude.sh <input-file>.
# Environment: ATTACK_MODEL (default sonnet), ATTACK_EFFORT (optional).
# The prompt goes in on stdin; read-only tools only, no session file, no MCP, no settings.
set -euo pipefail
[ $# -eq 1 ] && [ -r "$1" ] || { echo "usage: claude.sh <input-file>" >&2; exit 2; }
command -v claude >/dev/null 2>&1 || { echo "claude.sh: claude not found on PATH" >&2; exit 4; }
args=(-p --model "${ATTACK_MODEL:-sonnet}")
[ -z "${ATTACK_EFFORT:-}" ] || args+=(--effort "$ATTACK_EFFORT")
args+=(--tools "Read,Grep,Glob" --no-session-persistence --strict-mcp-config --setting-sources "")
claude "${args[@]}" <"$1"
