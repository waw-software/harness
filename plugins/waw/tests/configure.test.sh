#!/usr/bin/env bash
# tests/configure.test.sh: configure.sh apply writes the config, the worker routes, the rule
# links and the settings that agent.sh and attack.sh then read; bad choices write nothing.
# Sourced by tests/run.sh into a fresh subshell (TEST_ROOT, SETUP_UNDER_TEST, helpers).
# No network: the choices name no OpenRouter prices. No claude call: apply makes none.
set -u

CONF=$SETUP_UNDER_TEST/configure.sh
ROOT=$TEST_ROOT/configure-cases
CFG=$ROOT/cfg
mkdir -p "$CFG"
unset WAW_CONFIG
export CLAUDE_CONFIG_DIR=$CFG
H=$CFG/waw

choices() { # choices <file> <jira true|false>
  cat >"$1" <<EOF
{
  "routes": {
    "openrouter": { "type": "openrouter", "keychain": "openrouter" },
    "anthropic": { "type": "anthropic" },
    "gw": { "type": "custom", "url": "https://gw.example.invalid/anthropic", "keychain": "gw-key" }
  },
  "workers": {
    "investigator": { "model": "openai/gpt-6.2-sol", "route": "openrouter" },
    "developer": { "model": "claude-sonnet-5-5", "route": "anthropic" },
    "reviewer": { "model": "GPT 6.1 Sol (trusted)", "route": "gw" },
    "tester": { "model": "openai/gpt-6.2-sol", "route": "openrouter" }
  },
  "review": { "providers": [ { "provider": "codex", "model": "gpt-6.2-sol", "decide_model": "gpt-6.2-astra" },
                             { "provider": "openrouter", "model": "openai/gpt-6.2-sol" } ], "effort": "high" },
  "modules": { "decisions": true, "jira-tickets": $2 },
  "settings": { "statusline": true, "permissions": true, "no_attribution": true, "model": "claude-opus-5-5", "effort": "high" }
}
EOF
}

case_apply() {
  printf '{"theme": "dark", "permissions": {"allow": ["Read", "Bash(agent.sh:*)"]}}\n' >"$CFG/settings.json"
  choices "$ROOT/c1.json" true
  assert_exit 0 bash "$CONF" apply "$ROOT/c1.json"
  assert_contains "$(cat "$H/config")" 'AGENT_REVIEWER_MODEL="GPT 6.1 Sol (trusted)"' "model with spaces kept"
  assert_contains "$(cat "$H/config")" 'PROVIDERS="codex openrouter"' "provider order"
  assert_contains "$(cat "$H/config")" 'CODEX_DECIDE_MODEL="gpt-6.2-astra"' "decide model"
  assert_eq "$(jq -r '.env.ANTHROPIC_BASE_URL' "$H/workers/openrouter/settings.json")" "https://openrouter.ai/api" "openrouter url"
  assert_eq "$(jq -r '.apiKeyHelper' "$H/workers/gw/settings.json")" "/usr/bin/security find-generic-password -s gw-key -w" "key helper"
  assert_eq "$(jq -r '.env.ANTHROPIC_DEFAULT_HAIKU_MODEL' "$H/workers/gw/settings.json")" "GPT 6.1 Sol (trusted)" "route default model"
  assert_eq "$(jq -r '.env // "none"' "$H/workers/anthropic/settings.json")" "none" "anthropic route has no endpoint"
  assert_eq "$(stat -f %Lp "$H/workers/gw/settings.json" 2>/dev/null || stat -c %a "$H/workers/gw/settings.json")" "600" "route settings private"
  for r in commander git-delivery decisions jira-tickets; do
    [ -f "$CFG/rules/waw/$r.md" ] && [ ! -L "$CFG/rules/waw/$r.md" ] || fail "rule $r not copied"
    cmp -s "$CFG/rules/waw/$r.md" "$SETUP_UNDER_TEST/../rules/$r.md" || fail "rule $r differs"
  done
  assert_eq "$(jq -r '.theme' "$CFG/settings.json")" "dark" "other settings kept"
  assert_eq "$(jq -r '.permissions.allow | map(select(. == "Bash(agent.sh:*)")) | length' "$CFG/settings.json")" "1" "permissions not doubled"
  assert_eq "$(jq -r '.permissions.allow | index("Read") != null' "$CFG/settings.json")" "true" "own permissions kept"
  assert_eq "$(jq -r '.attribution.commit' "$CFG/settings.json")" "" "attribution off"
  assert_contains "$(jq -r '.statusLine.command' "$CFG/settings.json")" "waw/plugin/statusline.sh" "status line"
  [ -f "$(ls -d "$H"/backups/*/ | head -n 1)/${CFG#"$HOME"/}/settings.json" ] || fail "settings backed up"
  # The scripts read what apply wrote.
  local m
  m=$(bash "$SETUP_UNDER_TEST/agent.sh" models --tsv)
  assert_contains "$m" "developer	claude-sonnet-5-5	anthropic	$H/workers/anthropic" "agent.sh route"
  assert_contains "$m" "reviewer	GPT 6.1 Sol (trusted)	gw	$H/workers/gw" "agent.sh model with spaces"
  m=$(bash "$SETUP_UNDER_TEST/attack.sh" --check-config)
  assert_contains "$m" "codex model=gpt-6.2-sol decide=gpt-6.2-astra" "attack.sh codex"
  assert_contains "$m" "openrouter model=openai/gpt-6.2-sol decide=openai/gpt-6.2-sol dir=$H/workers/openrouter" "attack.sh route"
  # The worker sandbox denies reading the route secrets.
  m=$(bash "$SETUP_UNDER_TEST/agent.sh" sandbox-check)
  assert_contains "$m" "sandbox ok" "sandbox-check"
}

case_module_off_and_idempotent() {
  choices "$ROOT/c2.json" false
  assert_exit 0 bash "$CONF" apply "$ROOT/c2.json"
  assert_exit 0 bash "$CONF" apply "$ROOT/c2.json"
  [ ! -e "$CFG/rules/waw/jira-tickets.md" ] || fail "module off: rule removed"
  # The session-start hook brings a stale copy back to the plugin's version.
  printf 'stale\n' >"$CFG/rules/waw/commander.md"
  CLAUDE_PLUGIN_ROOT=$SETUP_UNDER_TEST/.. bash "$SETUP_UNDER_TEST/../hooks/session-start.sh" >"$ROOT/hook.json"
  cmp -s "$CFG/rules/waw/commander.md" "$SETUP_UNDER_TEST/../rules/commander.md" || fail "hook refreshed the rule"
  assert_contains "$(jq -r .hookSpecificOutput.additionalContext "$ROOT/hook.json")" "commander.md" "hook says it refreshed"
  assert_eq "$(jq -r '.permissions.allow | length' "$CFG/settings.json")" "9" "8 script rules + Read, no duplicates"
  assert_eq "$(jq -r '.permissions.allow | map(select(. == "Bash(retro.sh:*)")) | length' "$CFG/settings.json")" "1" "retro.sh allowed once"
}

case_bad_choices_write_nothing() {
  local before
  before=$(cat "$H/config")
  jq '.routes["Bad Name"] = {type: "nexos", keychain: "x"}' "$ROOT/c2.json" >"$ROOT/bad1.json"
  assert_exit 2 bash "$CONF" apply "$ROOT/bad1.json"
  jq '.workers.developer.model = "x\"; rm -rf /"' "$ROOT/c2.json" >"$ROOT/bad2.json"
  assert_exit 2 bash "$CONF" apply "$ROOT/bad2.json"
  jq '.routes.gw.url = "http://plain.example.invalid"' "$ROOT/c2.json" >"$ROOT/bad3.json"
  assert_exit 2 bash "$CONF" apply "$ROOT/bad3.json"
  jq '.review.providers = []' "$ROOT/c2.json" >"$ROOT/bad4.json"
  assert_exit 2 bash "$CONF" apply "$ROOT/bad4.json"
  jq '.review.providers += [.review.providers[0]]' "$ROOT/c2.json" >"$ROOT/bad5.json"
  assert_exit 2 bash "$CONF" apply "$ROOT/bad5.json"
  assert_contains "$(bash "$CONF" apply "$ROOT/bad5.json" 2>&1 || true)" "named more than once" "duplicate provider refused"
  assert_eq "$(cat "$H/config")" "$before" "config unchanged after refused choices"
}

case_codex_route() {
  choices "$ROOT/cx.json" false
  jq '.routes.codex = {type: "codex"}
      | .workers.tester = {model: "gpt-6.2-sol", route: "codex", effort: "medium", fallback_route: "anthropic", fallback_model: "claude-sonnet-5-5"}' \
    "$ROOT/cx.json" >"$ROOT/cx2.json"
  assert_exit 0 bash "$CONF" apply "$ROOT/cx2.json"
  [ -d "$H/workers/codex" ] || fail "codex route dir not made"
  [ ! -f "$H/workers/codex/settings.json" ] || fail "a codex route has no settings.json"
  assert_contains "$(cat "$H/config")" 'AGENT_TESTER_ROUTE="codex"' "tester on codex"
  assert_contains "$(cat "$H/config")" 'AGENT_TESTER_EFFORT="medium"' "effort"
  assert_contains "$(cat "$H/config")" 'AGENT_TESTER_FALLBACK_MODEL="claude-sonnet-5-5"' "fallback model"
  assert_eq "$(WAW_CONFIG=$H/config CLAUDE_CONFIG_DIR=$CFG bash "$SETUP_UNDER_TEST/agent.sh" models --tsv | awk -F'\t' '$1 == "tester" { print $3 " " $4 }')" "codex $H/workers/codex" "agent.sh sees the route"
  jq '.routes["codex-x"] = {type: "nexos", keychain: "k"}' "$ROOT/cx2.json" >"$ROOT/bad5.json"
  assert_exit 2 bash "$CONF" apply "$ROOT/bad5.json"
  jq '.routes.mycodex = {type: "codex"}' "$ROOT/cx2.json" >"$ROOT/bad6.json"
  assert_exit 2 bash "$CONF" apply "$ROOT/bad6.json"
  jq '.workers.tester.fallback_route = "codex"' "$ROOT/cx2.json" >"$ROOT/bad7.json"
  assert_exit 2 bash "$CONF" apply "$ROOT/bad7.json"
}

# A route's login is found whatever the dir's spelling: Claude Code keys it on the exact path,
# and detect walks "$H/workers/*/" (with the slash). The fake claude is logged in only for
# the dir spelled without one, as the real one behaves.
case_login_path() {
  local b=$ROOT/login-bin x out
  mkdir -p "$b" "$H/workers/anthropic"
  [ -f "$H/workers/anthropic/settings.json" ] || printf '{}\n' >"$H/workers/anthropic/settings.json"
  # Quiet stand-ins for what detect and check ask (the runner's sentinels fail on any call).
  for x in gh glab orca pnpm npm yarn codex opencode security; do printf '#!/bin/sh\nexit 1\n' >"$b/$x"; done
  cat >"$b/claude" <<EOF
#!/bin/sh
if [ "\$1 \$2" = "auth status" ]; then
  [ "\${CLAUDE_CONFIG_DIR:-}" = "$H/workers/anthropic" ] && echo '{"loggedIn":true,"authMethod":"claude.ai"}' || echo '{"loggedIn":false}'
  exit 0
fi
exit 1
EOF
  chmod 755 "$b"/*
  out=$(PATH="$b:$PATH" bash "$CONF" detect 2>/dev/null | grep '^anthropic: url')
  assert_contains "$out" "login yes (claude.ai)" "detect sees the route's login (dir walked with a trailing slash)"
  out=$(PATH="$b:$PATH" WAW_HOME="$H/" bash "$CONF" check 2>/dev/null | grep 'route anthropic')
  assert_contains "$out" "logged in" "check sees it with WAW_HOME spelled with a slash"
}

# uninstall: what apply added goes, what the developer had stays (byte for byte, as JSON);
# --purge logs the routes out and removes the home; the plugin is uninstalled through claude.
case_uninstall() (
  local C=$ROOT/u-cfg b=$ROOT/u-bin orig x
  export CLAUDE_CONFIG_DIR=$C
  local UH=$C/waw
  mkdir -p "$C" "$b"
  for x in gh glab orca pnpm npm yarn opencode security; do printf '#!/bin/sh\nexit 1\n' >"$b/$x"; done
  printf '#!/bin/sh\necho "codex $*" >>"%s/calls"\nexit 0\n' "$ROOT" >"$b/codex"
  printf '#!/bin/sh\necho "claude $*" >>"%s/calls"\n[ "$1 $2" = "auth status" ] && echo "{\\"loggedIn\\":true}"\nexit 0\n' "$ROOT" >"$b/claude"
  chmod 755 "$b"/*
  export PATH="$b:$PATH"
  orig='{"theme":"dark","model":"claude-x","statusLine":{"type":"command","command":"mine"},"permissions":{"allow":["Read","Bash(agent.sh:*)"]},"modelSettings":{"claude-opus-5-5":{"effortLevel":"low"}}}'
  printf '%s\n' "$orig" >"$C/settings.json"
  choices "$ROOT/u.json" true
  jq '.routes.codex = {"type": "codex"}' "$ROOT/u.json" >"$ROOT/u2.json"
  assert_exit 0 bash "$CONF" apply "$ROOT/u2.json"
  bash "$CONF" apply "$ROOT/u2.json" >/dev/null || fail "second apply failed"
  assert_eq "$(jq -r .model "$C/settings.json")" "claude-opus-5-5" "apply set the model"
  printf '{}\n' >"$UH/workers/codex/auth.json"
  out=$(bash "$CONF" uninstall --keep-plugin) || fail "uninstall failed: $out"
  assert_eq "$(jq -S -c . "$C/settings.json")" "$(printf '%s' "$orig" | jq -S -c .)" "settings back to what they were"
  assert_eq "$(jq -r '.permissions.allow | map(select(. == "Bash(retro.sh:*)")) | length' "$C/settings.json")" "0" "retro.sh permission removed"
  [ ! -e "$C/rules/waw" ] || fail "rules left: $(ls "$C/rules/waw")"
  [ -f "$UH/config" ] || fail "home removed without --purge"
  [ ! -e "$UH/plugin" ] || fail "plugin link left"
  ls "$C"/backups/waw-uninstall-*.settings.json >/dev/null 2>&1 || fail "no settings backup"
  if grep -q 'plugin uninstall' "$ROOT/calls" 2>/dev/null; then fail "--keep-plugin uninstalled the plugin"; fi
  # A setting the developer changed after apply is theirs: it stays.
  bash "$CONF" apply "$ROOT/u2.json" >/dev/null || fail "apply after uninstall failed"
  jq '.model = "mine-now"' "$C/settings.json" >"$C/s.tmp" && mv "$C/s.tmp" "$C/settings.json"
  out=$(bash "$CONF" uninstall --purge) || fail "uninstall --purge failed: $out"
  assert_eq "$(jq -r .model "$C/settings.json")" "mine-now" "a model changed since apply stays"
  assert_eq "$(jq -r .statusLine.command "$C/settings.json")" "mine" "own status line back"
  [ ! -e "$UH" ] || fail "--purge left $UH"
  assert_contains "$(cat "$ROOT/calls")" "codex logout" "codex route logged out"
  assert_contains "$(cat "$ROOT/calls")" "claude auth logout" "claude route logged out"
  assert_contains "$(cat "$ROOT/calls")" "claude plugin uninstall waw@harness" "plugin uninstalled"
  assert_contains "$(cat "$ROOT/calls")" "claude plugin marketplace remove harness" "marketplace removed"
  assert_contains "$out" "security delete-generic-password -s gw-key" "keychain items listed, not deleted"
  if grep -q '^security' "$ROOT/calls" 2>/dev/null; then fail "uninstall touched the keychain"; fi
  # Set up by an older apply (config there, no applied.json): settings equal to ours are ours.
  mkdir -p "$UH"
  printf 'AGENT_DEVELOPER_MODEL="x"\n' >"$UH/config"
  printf '%s\n' "{\"theme\":\"dark\",\"model\":\"claude-opus-5-5\",\"attribution\":{\"commit\":\"\",\"pr\":\"\"},\"includeCoAuthoredBy\":false,\"statusLine\":{\"type\":\"command\",\"command\":\"'$UH/plugin/statusline.sh'\"},\"permissions\":{\"allow\":[\"Read\",\"Bash(agent.sh:*)\",\"EnterWorktree\"]},\"modelSettings\":{\"claude-opus-5-5\":{\"effortLevel\":\"high\"}}}" >"$C/settings.json"
  bash "$CONF" apply "$ROOT/u2.json" >/dev/null || fail "apply on an older setup failed"
  bash "$CONF" uninstall --keep-plugin >/dev/null || fail "uninstall of an older setup failed"
  assert_eq "$(jq -S -c . "$C/settings.json")" '{"permissions":{"allow":["Read"]},"theme":"dark"}' "an older setup's settings are taken back too"
)

case_apply
case_module_off_and_idempotent
case_bad_choices_write_nothing
case_codex_route
case_login_path
case_uninstall
