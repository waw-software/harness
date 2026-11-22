#!/usr/bin/env bash
# session-start.sh: SessionStart hook of the waw plugin.
#
# 1. Keeps $WAW_HOME/plugin a link to this plugin version (CLAUDE_PLUGIN_ROOT moves
#    on every update): the status line goes through it.
# 2. Refreshes the rules /configure installed (<config>/rules/waw/*.md, copies: Claude
#    Code does not load a rule that is a link) from this plugin version. They are read at
#    session start; whether before or after this hook is not guaranteed, so a changed rule may
#    take one more session.
# 3. Tells the session, in a few lines, what is set: the worker models and routes and the
#    review providers, or that /configure has not run yet.
# Never fails the session: any problem ends in a short note or in nothing.
set -u
root=${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
config_dir=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
home=${WAW_HOME:-$config_dir/waw}
mkdir -p "$home" 2>/dev/null || exit 0
if [ "$(readlink "$home/plugin" 2>/dev/null)" != "$root" ]; then
  ln -sfn "$root" "$home/plugin" 2>/dev/null || true
fi

# context <text>: the hook's answer, as additional context for the session.
context() {
  if command -v jq >/dev/null 2>&1; then
    jq -nc --arg c "$1" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $c}}'
  fi
  exit 0
}

if ! command -v jq >/dev/null 2>&1; then
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"waw: jq is not installed; the scripts of this setup need it (brew install jq)."}}\n'
  exit 0
fi

if [ ! -f "$home/config" ]; then
  context "waw plugin: installed, not configured yet ($home/config is missing). Before any /ship, /auto-pilot or /brainstorm, tell the developer to run /configure (it checks what is installed, picks the worker models and their routes, installs the commander rules)."
fi

models=$(WAW_HOME=$home "$root/scripts/agent.sh" models --tsv 2>/dev/null |
  awk -F'\t' '{ printf "%s%s: %s via %s", (n++ ? "; " : ""), $1, ($2 == "" ? "(no model)" : $2), $3 }')
review=$(WAW_HOME=$home "$root/scripts/attack.sh" --check-config 2>/dev/null |
  awk '/ model=/ { p = $1; m = $0; sub(/^[^ ]+ model=/, "", m); sub(/ (decide|dir)=.*$/, "", m)
    printf "%s%s%s", (n++ ? " -> " : ""), p, (m == "" ? "" : " (" m ")") }')
refreshed=""
for f in "$config_dir"/rules/waw/*.md; do
  [ -e "$f" ] || [ -L "$f" ] || continue
  src=$root/rules/${f##*/}
  [ -f "$src" ] || continue
  if [ -L "$f" ] || ! cmp -s "$src" "$f"; then
    rm -f "$f" && cp "$src" "$f" 2>/dev/null && refreshed="$refreshed ${f##*/}"
  fi
done
msg="waw: workers ${models:-(no models: run /configure)}. Code review and /auto-pilot decisions (attack.sh): ${review:-(not configured: run /configure)}."
[ -z "$refreshed" ] || msg="$msg Rules updated from the new plugin version:$refreshed (they apply fully from the next session)."
context "$msg"
