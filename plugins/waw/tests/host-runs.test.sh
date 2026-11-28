#!/usr/bin/env bash
# tests/host-runs.test.sh — the commands no worker sandbox can start (Electron/Chromium, the iOS
# simulator) are host runs: the investigator names them, the commander runs them after reading
# the diff, the tester checks their evidence or reports `needs host:`; and the /auto-pilot time
# limit defaults to 500 minutes. Sourced by tests/run.sh (TEST_ROOT, SETUP_UNDER_TEST, fail,
# assert_eq, assert_contains, assert_exit).
set -u

PLUGIN=$SETUP_UNDER_TEST/..

# --- cases

case_texts_name_host_runs() {
  local file word
  for word in '**Host runs**' 'needs host: <command>' 'mach-register' 'Run on the host' \
    'evidence/host-<n>-<name>.txt'; do
    grep -qF -- "$word" "$PLUGIN/rules/commander.md" || fail "rules/commander.md lacks '$word'"
  done
  for word in '**Host runs**' 'needs host: <the exact command>' 'host run: <file>' '`not_run`'; do
    grep -qF -- "$word" "$SETUP_UNDER_TEST/roles/tester.md" || fail "roles/tester.md lacks '$word'"
  done
  grep -qF -- 'host_runs' "$SETUP_UNDER_TEST/roles/investigator.md" || fail "roles/investigator.md lacks 'host_runs'"
  for file in skills/ship/SKILL.md skills/auto-pilot/SKILL.md; do
    grep -qF -- 'Host runs' "$PLUGIN/$file" || fail "$file lacks 'Host runs'"
  done
  grep -qF -- 'needs host' "$PLUGIN/skills/ship/SKILL.md" || fail "skills/ship/SKILL.md lacks 'needs host'"
  # the old rule that sent every host run to the developer
  if grep -qF -- 'never on the host yourself' "$PLUGIN/skills/ship/SKILL.md"; then
    fail "skills/ship/SKILL.md still forbids every host run"
  fi
}

case_investigator_schema() {
  local schema=$SETUP_UNDER_TEST/schemas/investigator.json strict
  jq -e '.properties.checks.properties.host_runs.type == "array"
    and .properties.checks.properties.host_runs.items.type == "string"' "$schema" >/dev/null ||
    fail "investigator.json: checks.host_runs is not an array of strings"
  strict=$(jq -f "$SETUP_UNDER_TEST/lib/strict-schema.jq" "$schema") || fail "strict-schema.jq failed"
  jq -e '.properties.checks.properties.host_runs != null' <<<"$strict" >/dev/null ||
    fail "strict copy: checks.host_runs is missing"
}

case_limit_default() {
  local d=$TEST_ROOT/limit out left
  mkdir -p "$d"
  out=$(bash "$SETUP_UNDER_TEST/task.sh" limit start "$d" 2>&1) || fail "limit start failed: $out"
  assert_eq "$out" "within the limit: 500 minutes left" "limit start: the default"
  left=$(( ($(head -n 1 "$d/deadline") - $(date +%s) + 59) / 60 ))
  [ "$left" -ge 499 ] && [ "$left" -le 500 ] || fail "deadline is $left minutes away, not 500"
  grep -qF -- '(default 500 minutes)' "$SETUP_UNDER_TEST/task.sh" || fail "task.sh header lacks the 500 default"
  grep -qF -- '`task.sh limit start <dir>` (500' "$PLUGIN/skills/auto-pilot/SKILL.md" ||
    fail "skills/auto-pilot/SKILL.md does not name 500 minutes"
}

case_texts_name_host_runs
case_investigator_schema
case_limit_default
printf 'host-runs.test.sh: all three cases passed\n'
