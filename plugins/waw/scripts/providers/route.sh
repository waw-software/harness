#!/usr/bin/env bash
# providers/route.sh: `claude -p` under a worker route (a Claude Code config dir whose
# settings.json names the gateway: nexos.ai, OpenRouter, any Anthropic-compatible URL, or none
# for Anthropic itself). Usage: route.sh <input-file>.
# Environment: ATTACK_MODEL (required: the model id as the route names it, e.g.
# "GPT 6.1 Sol (trusted)" on nexos, "openai/gpt-6.1" on OpenRouter), ATTACK_EFFORT (optional),
# ROUTE_CONFIG_DIR (required: the route's config dir; its settings.json holds the URL and the
# key helper, so the user setting source is kept).
# The prompt goes in on stdin; read-only tools only, no session file, no MCP.
set -euo pipefail
[ $# -eq 1 ] && [ -r "$1" ] || { echo "usage: route.sh <input-file>" >&2; exit 2; }
[ -n "${ATTACK_MODEL:-}" ] || { echo "route.sh: no model (set <ROUTE>_MODEL in the config)" >&2; exit 2; }
[ -n "${ROUTE_CONFIG_DIR:-}" ] && [ -f "$ROUTE_CONFIG_DIR/settings.json" ] ||
  { echo "route.sh: no route config (${ROUTE_CONFIG_DIR:-unset}/settings.json)" >&2; exit 4; }
command -v claude >/dev/null 2>&1 || { echo "route.sh: claude not found on PATH" >&2; exit 4; }
args=(-p --model "$ATTACK_MODEL")
[ -z "${ATTACK_EFFORT:-}" ] || args+=(--effort "$ATTACK_EFFORT")
args+=(--tools "Read,Grep,Glob" --no-session-persistence --strict-mcp-config --setting-sources user)
# A gateway's model ids are unknown to Claude Code, which warns about each on stderr.
CLAUDE_CONFIG_DIR="$ROUTE_CONFIG_DIR" claude "${args[@]}" <"$1" \
  2> >(grep -v 'claude-code:unrecognized_model' >&2)
