#!/usr/bin/env bash
# tests/codex-runner.test.sh — workers on route codex (agent.sh with tests/fixtures/fake-codex.sh),
# the Codex PreToolUse hook (hooks/codex-pre-tool.sh) and the project-rule policy
# (codex-policy.mjs). Sourced by tests/run.sh.
set -u
AGENT=$SETUP_UNDER_TEST/agent.sh
HOOK=$SETUP_UNDER_TEST/hooks/codex-pre-tool.sh
ARGS=$TEST_ROOT/codex-args.log
cp "$TESTS_DIR/fixtures/fake-codex.sh" "$TEST_ROOT/bin/codex"
chmod 755 "$TEST_ROOT/bin/codex"
CX=$HOME/.claude/waw/workers/codex
mkdir -p "$CX"
printf '{"tokens":"fake"}\n' >"$CX/auth.json"
mkdir -p "$HOME/.agents/skills/mine"
printf -- '---\nname: mine\ndescription: the developer'"'"'s own\n---\n' >"$HOME/.agents/skills/mine/SKILL.md"
{ cat "$WAW_CONFIG"; echo 'AGENT_DEVELOPER_ROUTE="codex"'; echo 'AGENT_TESTER_ROUTE="codex"'; } >"$TEST_ROOT/config.codex"
export WAW_CONFIG=$TEST_ROOT/config.codex
WT=$TEST_ROOT/wt
mkdir -p "$WT/src"
git -C "$WT" init -q
printf 'Do the slice.\n' >"$TEST_ROOT/brief.md"
OUT=$WT/.ship/t/agents

# 1. a developer on codex: report, session, stream in Claude Code's form, args, env, home files
line=$(OPENAI_API_KEY=sk-leak bash "$AGENT" run --role developer --brief "$TEST_ROOT/brief.md" --out "$OUT" --cwd "$WT" --name dev-a --quiet) ||
  fail "codex developer run failed: $line $(cat "$OUT/dev-a.err" 2>/dev/null)"
assert_contains "$line" "dev-a ok turns=2" "final line"
assert_contains "$line" "session=0199aaaa-bbbb-7ccc-8ddd-eeeeffff0001" "the Codex thread id is the session"
assert_eq "$(jq -c . "$OUT/dev-a.result.json")" '{"status":"done","summary":"fake codex report","files_changed":[],"commands_run":[{"command":"pnpm test","result":"pass"}],"out_of_scope_needs":[],"concerns":[]}' "report without the strict nulls"
assert_eq "$(tail -n 1 "$OUT/runs.tsv" | cut -f4-11 | tr '\t' ' ')" "developer test-developer-model ok 2 $(tail -n 1 "$OUT/runs.tsv" | cut -f8) 1000 50 sub" "runs.tsv"
assert_eq "$(tail -n 1 "$OUT/runs.tsv" | cut -f12-14 | tr '\t' ' ')" "200 800 0" "token split"
steps=$(bash "$AGENT" log "$OUT/dev-a.jsonl")
assert_contains "$steps" "Bash pnpm test" "log shows the command, unwrapped"
assert_contains "$steps" "Edit src/a.ts" "log shows the edit"
args=$(cat "$ARGS")
assert_contains "$args" "--output-schema" "strict schema passed"
jq -e '.additionalProperties == false and (.required | index("blocker"))' "$OUT/dev-a.schema.json" >/dev/null || fail "schema is not strict"
assert_contains "$args" "developer_instructions=" "role prompt passed"
assert_contains "$args" "permissions.worker.filesystem=" "sandbox passed"
assert_contains "$args" '"~/.ssh" = "deny"' "secrets denied to reads"
assert_contains "$args" "\"$OUT\" = \"write\"" "run dir writable"
assert_contains "$args" "\"AGENT_NAME\" = \"dev-a\"" "the shell gets AGENT_NAME for ask.sh"
assert_contains "$args" "You run as a Codex session" "the Codex note is in the role prompt"
assert_contains "$args" "CODEX_HOME=$CX" "CODEX_HOME is the route dir"
assert_contains "$args" "skills.config=[{ \"path\" = \"$HOME/.agents/skills/mine/SKILL.md\", \"enabled\" = false }]" "the developer's own skills are off"
assert_contains "$args" '"~/.agents/skills" = "deny"' "and not readable from the shell"
assert_contains "$args" "OPENAI_API_KEY=unset" "no key from the commander's env"
assert_contains "$args" "CLAUDE_CONFIG_DIR=unset" "no Claude config dir"
assert_contains "$args" "Do the slice." "brief on stdin"
grep -q '^default_permissions = "worker"' "$CX/config.toml" || fail "config.toml not written"
grep -A1 '^\[skills.bundled\]' "$CX/config.toml" | grep -q '^enabled = false' || fail "config.toml lets Codex's bundled skills in"
jq -e --arg h "$HOOK" '.hooks.PreToolUse[0].hooks[0].command == $h' "$CX/hooks.json" >/dev/null || fail "hooks.json lacks the hook"
report=$(bash "$AGENT" report "$OUT")
assert_contains "$report" "sub" "report marks the subscription"

# 2. resume continues the Codex thread
: >"$ARGS"
bash "$AGENT" run --role developer --brief "$TEST_ROOT/brief.md" --out "$OUT" --cwd "$WT" --name dev-a-fix1 \
  --resume 0199aaaa-bbbb-7ccc-8ddd-eeeeffff0001 --quiet >/dev/null || fail "resume run failed"
grep -qx resume "$ARGS" || fail "resume not used: $(head -5 "$ARGS")"

# 3. a failed Codex turn: exit 4 with the reason
rc=0
FAKE_CODEX_MODE=fail bash "$AGENT" run --role developer --brief "$TEST_ROOT/brief.md" --out "$OUT" --cwd "$WT" --name dev-b --quiet >/dev/null 2>&1 || rc=$?
assert_eq "$rc" 4 "failed turn exit"
assert_contains "$(cat "$OUT/dev-b.result.json")" "error" "failed turn result"

# 4. stop a running Codex worker
FAKE_CODEX_MODE=hang bash "$AGENT" run --role developer --brief "$TEST_ROOT/brief.md" --out "$OUT" --cwd "$WT" --name dev-c --quiet >"$TEST_ROOT/c.out" 2>&1 &
p=$!
n=0; until bash "$AGENT" ps | grep -q dev-c || [ $n -gt 100 ]; do sleep 0.1; n=$((n + 1)); done
sleep 1
bash "$AGENT" stop dev-c >/dev/null
rc=0; wait "$p" || rc=$?
assert_eq "$rc" 6 "stopped exit"

# 5. not logged in
mv "$CX/auth.json" "$CX/auth.json.off"
rc=0; msg=$(bash "$AGENT" run --role developer --brief "$TEST_ROOT/brief.md" --out "$OUT" --cwd "$WT" --name dev-d --quiet 2>&1) || rc=$?
assert_eq "$rc" 3 "no login exit"
assert_contains "$msg" "codex login" "no login message"
mv "$CX/auth.json.off" "$CX/auth.json"

# 6. a project rule Codex cannot follow: the role moves to its fallback route (Claude)
cp "$TESTS_DIR/fixtures/fake-claude.sh" "$TEST_ROOT/bin/claude"; chmod 755 "$TEST_ROOT/bin/claude"
mkdir -p "$HOME/.claude/waw/workers/anthropic" "$WT/.claude"
printf '{}\n' >"$HOME/.claude/waw/workers/anthropic/settings.json"
printf '{"permissions":{"deny":["Frobnicate(x)"]}}\n' >"$WT/.claude/settings.json"
msg=$(bash "$AGENT" run --role developer --brief "$TEST_ROOT/brief.md" --out "$OUT" --cwd "$WT" --name dev-e --quiet 2>&1) || fail "fallback run failed: $msg"
assert_contains "$msg" "runs on route anthropic (sonnet) instead" "fallback note"
grep -q '^dev-e' "$TEST_ROOT/claude-starts.log" || fail "fallback did not start Claude"
rm -f "$TEST_ROOT/claude-starts.log" "$TEST_ROOT/claude-args.log"
printf '#!/bin/sh\nprintf "%%s\\n" "claude $*" >> "%s/audit/claude.log"\nexit 127\n' "$TEST_ROOT" >"$TEST_ROOT/bin/claude"
rm -f "$WT/.claude/settings.json"

# 7. the hook: guards, policy, BLOCKED events, approvals
EV=$TEST_ROOT/hook-events.log
mkdir -p "$WT/.claude" "$TEST_ROOT/run"
printf '{"permissions":{"deny":["Bash(rm -rf:*)","Edit(secrets/**)"],"ask":["Edit(package.json)"]}}\n' >"$WT/.claude/settings.json"
hk() { local o
  o=$(jq -nc --arg t "$1" --arg c "$2" --arg d "$WT" '{tool_name: $t, tool_input: {command: $c}, cwd: $d}' |
    AGENT_ROLE=developer AGENT_NAME=dev-h AGENT_SCOPE=$WT AGENT_RUN_DIR=$TEST_ROOT/run AGENT_EVENTS=$EV "$HOOK")
  if [ -z "$o" ]; then echo allow; else printf '%s' "$o" | jq -r '.hookSpecificOutput.permissionDecision'; fi; }
assert_eq "$(hk Bash 'pnpm test')" "allow" "plain command"
assert_eq "$(hk Bash 'git commit -m x')" "deny" "git commit"
assert_eq "$(hk Bash 'git push origin main')" "deny" "push to main"
assert_eq "$(hk Bash 'ls && rm -rf dist')" "deny" "project deny rule"
assert_eq "$(hk apply_patch $'*** Begin Patch\n*** Update File: src/a.ts\n@@\n+x\n*** End Patch')" "allow" "edit in scope"
assert_eq "$(hk apply_patch $'*** Begin Patch\n*** Add File: ../outside.txt\n+x\n*** End Patch')" "deny" "edit outside scope"
assert_eq "$(hk apply_patch $'*** Begin Patch\n*** Add File: secrets/k\n+x\n*** End Patch')" "deny" "project deny on a path"
assert_eq "$(grep -c ' BLOCKED dev-h: ' "$EV")" 5 "one BLOCKED event per block"
# an ask rule: the commander approves
( AGENT_APPROVAL_WAIT=20 hk apply_patch $'*** Begin Patch\n*** Update File: package.json\n@@\n+x\n*** End Patch' >"$TEST_ROOT/ask.out" ) &
hp=$!
n=0; until [ -f "$TEST_ROOT/run/dev-h.approvals/a1.request.json" ] || [ $n -gt 100 ]; do sleep 0.1; n=$((n + 1)); done
grep -q 'APPROVAL dev-h: a1: Edit package.json' "$EV" || fail "no APPROVAL event"
printf '{"behavior":"allow","message":"ok"}\n' >"$TEST_ROOT/run/dev-h.approvals/a1.decision.json"
wait "$hp"
assert_eq "$(cat "$TEST_ROOT/ask.out")" "allow" "approved edit passes"
# granted by the brief: no question
assert_eq "$(AGENT_GRANTS=package.json hk apply_patch $'*** Begin Patch\n*** Update File: package.json\n@@\n+y\n*** End Patch')" "allow" "granted file"
