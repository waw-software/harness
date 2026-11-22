#!/usr/bin/env bash
# tests/sandbox.test.sh — the worker sandbox settings, sandbox-check, the tester guard and the
# fix/steer columns of agent.sh report. Sourced by tests/run.sh (TEST_ROOT, SETUP_UNDER_TEST,
# fail, assert_eq, assert_contains, assert_exit). The fake claude records each worker's argv.
set -u

AGENT=$SETUP_UNDER_TEST/agent.sh
ROOT=$TEST_ROOT/sandbox-cases
ARGS=$TEST_ROOT/claude-args.log
STARTS=$TEST_ROOT/claude-starts.log
mkdir -p "$ROOT"
# The worker starts from an empty environment: the fake claude reads these names from ours.
export AGENT_WORKER_ENV="TEST_ROOT FAKE_CLAUDE_MODE FAKE_CLAUDE_BARRIER"
cp "$TESTS_DIR/fixtures/fake-claude.sh" "$TEST_ROOT/bin/claude"
chmod 755 "$TEST_ROOT/bin/claude"

settings_of() { # settings_of <worker name>: the --settings JSON it was started with
  awk -v n="=== $1" '$0 == n {f=1; next} /^=== /{f=0} f && $1 == "--settings" {getline; print; exit}' "$ARGS"
}
run_worker() { # run_worker <name> <role> <cwd> [args...]: one fake run to the end
  local name=$1 role=$2 cwd=$3; shift 3
  mkdir -p "$cwd"
  printf 'sandbox test brief\n' >"$ROOT/brief.md"
  bash "$AGENT" run --role "$role" --brief "$ROOT/brief.md" --out "$cwd/.ship/t/agents" \
    --cwd "$cwd" --name "$name" --quiet "$@" >"$ROOT/$name.log" 2>"$ROOT/$name.err"
}
jqs() { printf '%s' "$1" | jq -r "$2"; }

case_developer_sandbox() {
  local cwd=$ROOT/dev s
  assert_exit 0 run_worker sb-dev developer "$cwd"
  cwd=$(cd "$cwd" && pwd -P)
  s=$(settings_of sb-dev)
  [ -n "$s" ] || fail "no --settings recorded for sb-dev"
  assert_eq "$(jqs "$s" '.sandbox.enabled')" true "sandbox on"
  assert_eq "$(jqs "$s" '.sandbox.failIfUnavailable')" true "no worker without the sandbox"
  assert_eq "$(jqs "$s" '.sandbox.allowUnsandboxedCommands')" false "no unsandboxed retry"
  assert_eq "$(jqs "$s" '.sandbox.network.strictAllowlist')" true "strict network allowlist"
  assert_eq "$(jqs "$s" '.sandbox.network.allowedDomains | length')" 0 "no network host"
  assert_eq "$(jqs "$s" '.sandbox.filesystem.allowWrite[0]')" "$cwd" "writes in the worktree"
  assert_eq "$(jqs "$s" '.sandbox.filesystem.denyRead | index("~/.ssh") != null')" true "ssh keys unreadable"
  assert_eq "$(jqs "$s" '.sandbox.filesystem.denyRead | index("~/.npmrc") != null')" true "npm tokens unreadable"
  assert_eq "$(jqs "$s" '.permissions.deny | index("Read(~/.ssh/**)") != null')" true "Read tool denied on ssh"
  assert_eq "$(jqs "$s" '.sandbox.excludedCommands // "none"')" none "no command outside the sandbox"
  assert_contains "$s" "$SETUP_UNDER_TEST/hooks/worker-guard.sh" "hooks kept"
}

case_tester_and_install() {
  local s
  assert_exit 0 run_worker sb-test tester "$ROOT/test"
  s=$(settings_of sb-test)
  assert_eq "$(jqs "$s" '.sandbox.excludedCommands == null')" true "tester runs nothing outside the sandbox"
  mkdir -p "$ROOT/inst"
  printf 'registry=https://npm.example.invalid/api/\n' >"$ROOT/inst/.npmrc"
  assert_exit 0 run_worker sb-inst developer "$ROOT/inst" --allow-install
  s=$(settings_of sb-inst)
  assert_eq "$(jqs "$s" '.sandbox.network.allowedDomains | index("registry.npmjs.org") != null')" true "npm registry"
  assert_eq "$(jqs "$s" '.sandbox.network.allowedDomains | index("npm.example.invalid") != null')" true "project registry"
  assert_eq "$(jqs "$s" '.sandbox.filesystem.denyRead | index("~/.npmrc") == null')" true "installer reads ~/.npmrc"
}

case_sandbox_off_and_check() {
  local s
  AGENT_SANDBOX=off assert_exit 0 run_worker sb-off developer "$ROOT/off"
  s=$(settings_of sb-off)
  assert_eq "$(jqs "$s" 'has("sandbox")')" false "AGENT_SANDBOX=off leaves the sandbox out"
  assert_eq "$(jqs "$s" '.permissions.deny | length > 0')" true "Read denies stay"
  AGENT_SANDBOX=off assert_exit 3 bash "$AGENT" sandbox-check
  if [ "$(uname -s)" = Darwin ]; then
    assert_exit 0 bash "$AGENT" sandbox-check
  fi
}

case_tester_waits_for_developer() {
  local cwd=$ROOT/busy pid n=0
  mkdir -p "$cwd"
  printf 'hold\n' >"$ROOT/brief.md"
  FAKE_CLAUDE_MODE=barrier FAKE_CLAUDE_BARRIER="$ROOT/go" bash "$AGENT" run --role developer \
    --brief "$ROOT/brief.md" --out "$cwd/.ship/t/agents" --cwd "$cwd" --name sb-busy --quiet \
    >"$ROOT/sb-busy.log" 2>&1 &
  pid=$!
  while ! grep -q '^sb-busy' "$STARTS" 2>/dev/null; do
    n=$((n + 1)); [ "$n" -le 250 ] || fail "sb-busy never started"; sleep 0.1
  done
  assert_exit 2 run_worker sb-early tester "$cwd"
  assert_contains "$(cat "$ROOT/sb-early.err")" "developer sb-busy is still working" "the reason names it"
  assert_exit 0 run_worker sb-elsewhere tester "$ROOT/other"
  touch "$ROOT/go"
  assert_exit 0 wait "$pid"
  assert_exit 0 run_worker sb-late tester "$cwd"
}

case_report_fix_and_steer() {
  local d=$ROOT/report out
  mkdir -p "$d"
  {
    printf 'started\tname\tsession\trole\tmodel\tstatus\tturns\tseconds\tin\tout\n'
    printf 't\tdev-a\ts1\tdeveloper\tm-dev\tok\t10\t60\t100\t10\n'
    printf 't\tdev-a-fix1\ts1\tdeveloper\tm-dev\tok\t5\t60\t100\t10\n'
    printf 't\tdev-a-fix2\ts1\tdeveloper\tm-dev\tok\t5\t60\t100\t10\n'
    printf 't\tdev-b\ts2\tdeveloper\tm-dev\tok\t10\t60\t100\t10\n'
    printf 't\tinv-1\ts3\tinvestigator\tm-inv\tok\t10\t60\t100\t10\n'
  } >"$d/runs.tsv"
  : >"$d/dev-b.steer-1.md"
  : >"$d/dev-b.steer-2.md"
  out=$(bash "$AGENT" report "$d")
  assert_contains "$out" "fix steer" "new columns"
  assert_contains "$(printf '%s\n' "$out" | grep '^developer')" "    4      0    2     2" "developer: 4 runs, 2 fix, 2 steer"
  assert_contains "$out" "developer slices: 2, fix runs per slice: 1.0" "per slice"
}

case_budget_in_real_dollars() {
  local budget
  printf '# test prices\ntest-developer-model\t0.2\t0.5\t0.05\t\n' >"$TEST_ROOT/prices.tsv"
  AGENT_PRICES=$TEST_ROOT/prices.tsv assert_exit 0 run_worker sb-budget developer "$ROOT/budget"
  budget=$(awk '/^=== sb-budget$/{f=1; next} /^=== /{f=0} f && $1 == "--max-budget-usd" {getline; print; exit}' "$ARGS")
  # 5 real dollars at 0.2/0.5/0.05 for the typical mix = 5 * 1.66 / 0.074
  assert_eq "$budget" "112.16" "budget converted to Claude Code's Opus-rate dollars"
  assert_exit 0 run_worker sb-noprice developer "$ROOT/noprice"
  budget=$(awk '/^=== sb-noprice$/{f=1; next} /^=== /{f=0} f && $1 == "--max-budget-usd" {getline; print; exit}' "$ARGS")
  assert_eq "$budget" "5" "no price: the budget as it is"
}

case_space_path_denied() {
  local s d="$HOME/.claude/waw/workers/spaced route"
  mkdir -p "$d"
  printf '{}\n' >"$d/settings.json"
  assert_exit 0 run_worker sb-space developer "$ROOT/space"
  s=$(settings_of sb-space)
  assert_eq "$(jqs "$s" '.permissions.deny | index("Read(~/.claude/waw/workers/spaced route/settings.json)") != null')" true "space path in Read deny"
  assert_eq "$(jqs "$s" '.sandbox.filesystem.denyRead | index("~/.claude/waw/workers/spaced route/settings.json") != null')" true "space path in denyRead"
  rm -rf "$d"
}

case_new_default_denies() {
  local s p
  assert_exit 0 run_worker sb-newdeny developer "$ROOT/newdeny"
  s=$(settings_of sb-newdeny)
  for p in "~/.gnupg" "~/.kube" "~/.config/gcloud" "~/.azure" "~/.config/azure" "~/.config/doctl" "~/.oci" \
    "~/.zsh_history" "~/.bash_history" "~/.sh_history" "~/.zhistory" "~/.zsh_sessions" "~/.bash_sessions" \
    "~/.local/share/fish/fish_history" "~/Library/Application Support/Google/Chrome" \
    "~/Library/Application Support/Chromium" "~/Library/Application Support/Firefox" \
    "~/Library/Application Support/BraveSoftware" "~/Library/Application Support/1Password" \
    "~/Library/Application Support/Code/User/globalStorage"; do
    printf '%s' "$s" | jq -e --arg p "$p" '(.sandbox.filesystem.denyRead | index($p)) != null
      and (.permissions.deny | index("Read(\($p))")) != null and (.permissions.deny | index("Read(\($p)/**)")) != null' >/dev/null ||
      fail "default deny missing: $p"
  done
}

case_read_deny_file() {
  local s cwd=$ROOT/rd err
  mkdir -p "$cwd" "$HOME/.claude/waw"
  cwd=$(cd "$cwd" && pwd -P)
  {
    printf '# neighbours\n\n'
    printf '%s\n' "$TEST_ROOT/sibling checkout" "~/other-repo" "$cwd" "$ROOT"
  } >"$HOME/.claude/waw/read-deny"
  assert_exit 0 run_worker sb-rd developer "$cwd"
  s=$(settings_of sb-rd)
  printf '%s' "$s" | jq -e --arg p "$TEST_ROOT/sibling checkout" '(.sandbox.filesystem.denyRead | index($p)) != null
    and (.permissions.deny | index("Read(/\($p)/**)")) != null and (.permissions.deny | index("Read(/\($p))")) != null' >/dev/null || fail "read-deny line with a space missing (absolute: //path in permissions.deny)"
  printf '%s' "$s" | jq -e '.sandbox.filesystem.denyRead | index("~/other-repo") != null' >/dev/null || fail "~/ read-deny line missing"
  printf '%s' "$s" | jq -e '(.permissions.deny | index("Read(~/other-repo/**)")) != null' >/dev/null || fail "~/ entry must stay Read(~/...)"
  printf '%s' "$s" | jq -e --arg c "$cwd" '.sandbox.filesystem.denyRead | index($c) == null' >/dev/null || fail "the worktree itself was denied"
  printf '%s' "$s" | jq -e --arg c "$ROOT" '.sandbox.filesystem.denyRead | index($c) == null' >/dev/null || fail "a parent of the worktree was denied"
  err=$(cat "$ROOT/sb-rd.err")
  assert_contains "$err" "agent.sh: read-deny: $cwd contains the worktree, skipped" "warning for the scope"
  assert_contains "$err" "agent.sh: read-deny: $ROOT contains the worktree, skipped" "warning for a parent"
  rm -f "$HOME/.claude/waw/read-deny"
}

case_parent_env_allowlist() {
  local f=$TEST_ROOT/claude-env-sb-env.log
  WAW_TEST_SECRET=leak AWS_SESSION_TOKEN=leak WAW_TEST_PASS=passed AGENT_WORKER_ENV="$AGENT_WORKER_ENV WAW_TEST_PASS" \
    assert_exit 0 run_worker sb-env developer "$ROOT/env"
  [ -s "$f" ] || fail "the fake claude recorded no environment"
  ! grep -q '^WAW_TEST_SECRET=' "$f" || fail "WAW_TEST_SECRET leaked to the worker"
  ! grep -q '^AWS_SESSION_TOKEN=' "$f" || fail "AWS_SESSION_TOKEN leaked to the worker"
  grep -q "^HOME=$HOME\$" "$f" || fail "HOME missing"
  grep -q '^PATH=' "$f" || fail "PATH missing"
  grep -q '^AGENT_ROLE=developer$' "$f" || fail "AGENT_ROLE missing"
  grep -q '^AGENT_NAME=sb-env$' "$f" || fail "AGENT_NAME missing"
  grep -q '^WAW_TEST_PASS=passed$' "$f" || fail "a name in AGENT_WORKER_ENV did not pass"
}

case_proxy_credentials() {
  local f=$TEST_ROOT/claude-env-sb-proxy.log
  HTTPS_PROXY=http://u:p@proxy:3128 HTTP_PROXY=http://proxy:3128 assert_exit 0 run_worker sb-proxy developer "$ROOT/proxy"
  ! grep -q '^HTTPS_PROXY=' "$f" || fail "a proxy value with credentials was passed by default"
  grep -q '^HTTP_PROXY=http://proxy:3128$' "$f" || fail "a proxy value without credentials was not passed"
  HTTPS_PROXY=u:p@proxy:3128 NO_PROXY=localhost,.example.test HTTP_PROXY=http://proxy:3128/path@x \
    assert_exit 0 run_worker sb-proxy3 developer "$ROOT/proxy3"
  f=$TEST_ROOT/claude-env-sb-proxy3.log
  ! grep -q '^HTTPS_PROXY=' "$f" || fail "a schemeless proxy value with credentials was passed by default"
  grep -q '^NO_PROXY=localhost,.example.test$' "$f" || fail "NO_PROXY without @ was not passed"
  grep -q '^HTTP_PROXY=http://proxy:3128/path@x$' "$f" || fail "an @ after the host was taken for credentials"
  f=$TEST_ROOT/claude-env-sb-proxy2.log
  HTTPS_PROXY=http://u:p@proxy:3128 AGENT_WORKER_ENV="$AGENT_WORKER_ENV HTTPS_PROXY" assert_exit 0 run_worker sb-proxy2 developer "$ROOT/proxy2"
  grep -q '^HTTPS_PROXY=http://u:p@proxy:3128$' "$f" || fail "a proxy named in AGENT_WORKER_ENV was not passed"
}

case_developer_sandbox
case_budget_in_real_dollars
case_tester_and_install
case_sandbox_off_and_check
case_tester_waits_for_developer
case_report_fix_and_steer
case_space_path_denied
case_new_default_denies
case_read_deny_file
case_parent_env_allowlist
case_proxy_credentials
printf 'sandbox.test.sh: all eleven cases passed\n'
