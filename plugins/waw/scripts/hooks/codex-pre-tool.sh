#!/usr/bin/env bash
# codex-pre-tool.sh: the PreToolUse hook of Codex workers (route codex: agent.sh writes it into
# the route's hooks.json, matcher Bash and apply_patch). It runs the guards the Claude Code
# workers have, on the Codex call:
#   Bash         worker-guard.sh, guard-push.sh, then codex-policy.mjs (the project's rules)
#   apply_patch  worker-guard.sh once per file of the patch (as an Edit, or a Write for an added
#                file), then codex-policy.mjs (deny and ask rules, approvals by the commander)
# A block is answered in the form Codex takes (hookSpecificOutput.permissionDecision "deny",
# with the guard's reason), and written as a BLOCKED event to AGENT_EVENTS: Codex reports a
# blocked call only on its stderr, so agent.sh would not see it. Exit 0 always (a broken
# guard allows, as the guards themselves do). Portable to macOS /bin/bash 3.2.
set -u
here=$(cd "$(dirname "$0")" && pwd -P)
command -v jq >/dev/null 2>&1 || exit 0
input=$(cat)
tool=$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null) || exit 0

deny() { # deny <what> <reason>
  local why
  why=$(printf '%s' "$2" | tr '\n' ' ' | cut -c1-600)
  if [ -n "${AGENT_EVENTS:-}" ]; then
    printf '%s BLOCKED %s: %s -> %s\n' "$(date +%H:%M:%S)" "${AGENT_NAME:-worker}" "$1" "$why" >>"$AGENT_EVENTS" 2>/dev/null || true
  fi
  jq -nc --arg r "$why" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
}

# check <what> <payload> <command...>: run one guard; on its exit 2, deny with its stderr.
check() {
  local what=$1 payload=$2 err rc=0
  shift 2
  err=$(printf '%s' "$payload" | "$@" 2>&1 >/dev/null) || rc=$?
  [ "$rc" != 2 ] || deny "$what" "${err:-blocked by $(basename "$1")}"
}

node_bin=$(command -v node || true)
case $tool in
  Bash)
    what="Bash $(printf '%s' "$input" | jq -r '.tool_input.command // ""' | tr '\n' ' ' | cut -c1-120)"
    check "$what" "$input" "$here/worker-guard.sh"
    check "$what" "$input" "${AGENT_PUSH_GUARD:-$here/guard-push.sh}"
    [ -z "$node_bin" ] || check "$what" "$input" "$node_bin" "$here/../codex-policy.mjs" hook
    ;;
  apply_patch)
    cwd=$(printf '%s' "$input" | jq -r '.cwd // ""')
    [ -n "$cwd" ] || cwd=${AGENT_SCOPE:-$PWD}
    while IFS=$'\t' read -r kind file; do
      [ -n "$file" ] || continue
      case $file in /*) ;; *) file=$cwd/$file ;; esac
      t=Edit
      [ "$kind" != Add ] || t=Write
      payload=$(jq -nc --arg t "$t" --arg f "$file" --arg c "$cwd" '{tool_name: $t, tool_input: {file_path: $f}, cwd: $c}')
      check "$t $file" "$payload" "$here/worker-guard.sh"
    done < <(printf '%s' "$input" | jq -r '.tool_input.command // .tool_input.patch // ""' |
      sed -nE 's/^\*\*\* (Add|Update|Delete) File: (.*)$/\1	\2/p; s/^\*\*\* Move to: (.*)$/Add	\1/p')
    [ -z "$node_bin" ] || check "apply_patch" "$input" "$node_bin" "$here/../codex-policy.mjs" hook
    ;;
esac
exit 0
