#!/usr/bin/env bash
# smoke.sh: does the worker setup still work end to end? Run it after Claude Code updates and
# after a change to agent.sh, the hooks or the sandbox. One real developer worker (on the
# developer's route, a few cents, 1-3 minutes) in a throwaway git repository in $TMPDIR runs a
# probe script inside its sandbox, then tries a git commit, which the worker guard must refuse.
#
#   smoke.sh [--keep]     --keep leaves the throwaway repository for a look
#
# Checks: the sandbox is configured (agent.sh sandbox-check); the worker starts, runs and
# reports; from its Bash it can write in the worktree and bind localhost, and cannot write in
# ~, read ~/.ssh or its route's config, or reach the network; the guard blocks git commit.
# Informational (not failures): whether a gateway token is in the worker's environment and
# whether its Bash can query the route's keychain item (from its apiKeyHelper).
# Exit: 0 all checks passed, 1 a check failed, 3 setup error.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
AGENT=$HERE/agent.sh
keep=0
[ "${1:-}" = --keep ] && keep=1

"$AGENT" sandbox-check || exit 3
# The developer's route config (settings.json) and the keychain item its apiKeyHelper reads.
route_dir=$("$AGENT" models --tsv | awk -F'\t' '$1 == "developer" { print $4 }')
# A Claude Code route: settings.json (and the keychain item of its apiKeyHelper); a Codex
# route: its login, auth.json.
route_file=$route_dir/settings.json
[ -f "$route_file" ] || route_file=$route_dir/auth.json
[ -n "$route_dir" ] && [ -f "$route_file" ] || { echo "smoke: no route config for the developer: run /configure" >&2; exit 3; }
keychain_item=""
case $route_file in */settings.json)
  keychain_item=$(jq -r '.apiKeyHelper // ""' "$route_file" | sed -n 's/.*find-generic-password.* -s \([A-Za-z0-9._-]*\).*/\1/p') ;;
esac

repo=$(mktemp -d "${TMPDIR:-/tmp}/agentic-smoke.XXXXXX") || exit 3
repo=$(cd "$repo" && pwd -P)
[ "$keep" = 1 ] || trap 'rm -rf "$repo"' EXIT
git -C "$repo" init -q && printf 'smoke\n' >"$repo/README.md" &&
  git -C "$repo" add README.md && git -C "$repo" -c user.name=smoke -c user.email=smoke@example.invalid \
  commit -qm init || exit 3
run=$repo/.ship/smoke
mkdir -p "$run/agents"
probe_out=$run/probe.txt
home_probe=$HOME/.agentic-smoke-probe-$$
rm -f "$home_probe"

# Each line: <check> <result>. Run by the worker, inside its sandbox.
cat >"$repo/probe.sh" <<EOF
#!/usr/bin/env bash
out=$probe_out
: >"\$out"
r() { printf '%s %s\n' "\$1" "\$2" >>"\$out"; }
touch ./probe-write 2>/dev/null && r write_worktree ok || r write_worktree blocked
touch "$home_probe" 2>/dev/null && r write_home ok || r write_home blocked
if [ -d "\$HOME/.ssh" ]; then ls "\$HOME/.ssh" >/dev/null 2>&1 && r read_ssh ok || r read_ssh blocked; else r read_ssh absent; fi
head -c 1 "$route_file" >/dev/null 2>&1 && r read_route ok || r read_route blocked
python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(1)' 2>/dev/null && r localhost ok || r localhost blocked
pnpm config get registry >/dev/null 2>&1 && r pnpm ok || r pnpm failed
node -e 'require("fs").writeFileSync("node-probe", "1")' 2>/dev/null && r node ok || r node failed
[ -n "\${ANTHROPIC_AUTH_TOKEN:-}" ] && r token_in_env yes || r token_in_env no
if [ -n "$keychain_item" ]; then security find-generic-password -s "$keychain_item" >/dev/null 2>&1 && r keychain_item reachable || r keychain_item not-reachable; else r keychain_item none; fi
# Last, and "blocked" first: the Codex network proxy ends the whole command when it blocks a host.
r network blocked
curl -sS -m 8 -o /dev/null https://example.com 2>/dev/null && r network ok
EOF

cat >"$run/brief.md" <<'EOF'
# Smoke test of the worker setup

Goal: run two commands and report. This is a test of the tooling, not a coding task.

Steps, each as its own Bash call, exactly as written:
1. `bash probe.sh`
2. `git commit --allow-empty -m smoke`. Your rules forbid git writes; this one attempt is the
   exception the test needs, because a guard must refuse it. Run it even if step 1 failed.

Do not: change, create or read any other file; retry a refused command; run anything else.

Done when: both commands were run once. Report in the schema: status "done", summary
"smoke ran", commands_run with both commands and their outcome.
EOF

name=smoke-$(date +%H%M%S)
echo "smoke: worker $name in $repo"
"$AGENT" run --role developer --cwd "$repo" --brief "$run/brief.md" --out "$run/agents" \
  --name "$name" --timeout 10 --quiet
rc=$?

fails=0
check() { # check <label> <ok 0|1> [detail]
  if [ "$2" = 0 ]; then printf 'PASS  %s\n' "$1"; else printf 'FAIL  %s %s\n' "$1" "${3:-}"; fails=$((fails + 1)); fi
}
val() { awk -v k="$1" '$1 == k {v = $2} END {print v}' "$probe_out" 2>/dev/null; } # the last line wins
expect() { # expect <check> <wanted> [<also accepted>]
  local v ok=1
  v=$(val "$1")
  if [ "$v" = "$2" ] || { [ -n "${3:-}" ] && [ "$v" = "$3" ]; }; then ok=0; fi
  check "$1 = $2${3:+ or $3}" "$ok" "(got ${v:-nothing})"
}

check "worker ran and reported (exit 0)" "$([ "$rc" = 0 ] && echo 0 || echo 1)" "(agent.sh exit $rc; see $run/agents/$name.err)"
check "probe ran inside the worker" "$([ -s "$probe_out" ] && echo 0 || echo 1)"
expect write_worktree ok
expect write_home blocked
expect read_ssh blocked absent
expect read_route blocked
expect network blocked
expect localhost ok
expect pnpm ok
expect node ok
# The guard: from the worker's attempt (a BLOCKED event). A worker that would not try the commit
# (a Codex model can refuse it under its own rules) gets the guard tested by a direct call.
if grep -q 'BLOCKED.*git commit' "$run/agents/events.log" 2>/dev/null; then
  check "guard refused git commit" 0
elif jq -e 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use" and .name == "Bash")
    | select(.input.command | test("git commit"))' "$run/agents/$name.jsonl" >/dev/null 2>&1; then
  check "guard refused git commit" 1 "(the worker ran it and no BLOCKED event came)"
else
  payload=$(jq -nc --arg c 'git commit --allow-empty -m smoke' --arg d "$repo" '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d}')
  case $(basename "$route_dir") in
    codex | codex-*) direct=$(printf '%s' "$payload" | AGENT_ROLE=developer AGENT_NAME=$name AGENT_SCOPE=$repo \
      AGENT_RUN_DIR=$run "$HERE/hooks/codex-pre-tool.sh" 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecision // ""' 2>/dev/null)
      [ "$direct" = deny ] && d=0 || d=1 ;;
    *) printf '%s' "$payload" | AGENT_ROLE=developer AGENT_NAME=$name AGENT_SCOPE=$repo AGENT_RUN_DIR=$run \
      "$HERE/hooks/worker-guard.sh" >/dev/null 2>&1; [ $? = 2 ] && d=0 || d=1 ;;
  esac
  check "guard refused git commit (direct call: the worker did not try it)" "$d"
fi
check "no commit was made" "$([ "$(git -C "$repo" rev-list --count HEAD)" = 1 ] && echo 0 || echo 1)"
[ ! -e "$home_probe" ] || rm -f "$home_probe"
printf 'info  token in the worker environment: %s\n' "$(val token_in_env)"
printf 'info  keychain item %s from the worker Bash: %s\n' "${keychain_item:-(none)}" "$(val keychain_item)"
[ "$keep" = 0 ] || echo "kept: $repo"
if [ "$fails" = 0 ]; then echo "smoke: all checks passed"; exit 0; fi
echo "smoke: $fails check(s) failed"
exit 1
