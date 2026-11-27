#!/usr/bin/env bash
# tests/tester-status.test.sh — the tester reports pass, pass-with-exclusions (with an
# `exclusions` list), fail or blocked: the schema, its Codex strict copy, and the texts that
# read the status, and agent.sh's check of the exclusions. Sourced by tests/run.sh (TEST_ROOT,
# SETUP_UNDER_TEST, fail, assert_eq, assert_contains, assert_exit).
set -u

PLUGIN=$SETUP_UNDER_TEST/..
SCHEMA=$SETUP_UNDER_TEST/schemas/tester.json

# --- cases

case_status_enum() {
  jq -e '.properties.status.enum == ["pass","pass-with-exclusions","fail","blocked"]' \
    "$SCHEMA" >/dev/null || fail "tester.json: status enum: $(jq -c '.properties.status.enum' "$SCHEMA")"
}

case_exclusions_shape() {
  jq -e '.properties.exclusions.type == "array"' "$SCHEMA" >/dev/null ||
    fail "tester.json: exclusions is not an array"
  jq -e '.properties.exclusions.items.required == ["check","command","reason"]' "$SCHEMA" >/dev/null ||
    fail "tester.json: exclusions items do not require check, command, reason"
  jq -e '.required | index("exclusions") == null' "$SCHEMA" >/dev/null ||
    fail "tester.json: exclusions must stay optional"
}

case_strict_copy() {
  local strict
  strict=$(jq -f "$SETUP_UNDER_TEST/lib/strict-schema.jq" "$SCHEMA") || fail "strict-schema.jq failed"
  jq -e '.required | index("exclusions") != null' <<<"$strict" >/dev/null ||
    fail "strict copy: exclusions is not required"
  jq -e '.properties.exclusions.type == ["array","null"]' <<<"$strict" >/dev/null ||
    fail "strict copy: exclusions is not a nullable array"
  jq -e '.properties.status.enum | index("pass-with-exclusions") != null' <<<"$strict" >/dev/null ||
    fail "strict copy: the status enum lacks pass-with-exclusions"
}

case_text_reads_status() {
  local file word
  for word in 'pass-with-exclusions' '`blocked`' '--cacheDirectory'; do
    grep -qF -- "$word" "$SETUP_UNDER_TEST/roles/tester.md" || fail "roles/tester.md lacks '$word'"
  done
  for file in rules/commander.md skills/ship/SKILL.md; do
    grep -qF -- 'pass-with-exclusions' "$PLUGIN/$file" || fail "$file lacks 'pass-with-exclusions'"
  done
}

report_run() { # report_run <name> <report JSON>: a tester run through agent.sh that reports it
  local d=$TEST_ROOT/report-$1
  mkdir -p "$d"
  printf '%s' "$2" | jq -c . >"$TEST_ROOT/report.json" || fail "bad report JSON for $1"
  printf 'tester status test brief\n' >"$d/brief.md"
  bash "$SETUP_UNDER_TEST/agent.sh" run --role tester --brief "$d/brief.md" --out "$d/.ship/t/agents" \
    --cwd "$d" --name "$1" --quiet >"$d/run.log" 2>&1
}

case_exclusions_enforced() {
  local err='pass-with-exclusions must list every check that did not pass in exclusions'
  local unit='{"name":"unit","command":"u","result":"fail"}' lint='{"name":"lint","command":"l","result":"not_run"}'
  local ex='[{"check":"unit","command":"u","reason":"environment"}]' base name result
  base='{"status":"pass-with-exclusions","criteria":[],"not_covered":[],"bugs":[]'
  # a claude that reports what report_run wrote (the worker's environment is empty: paths inline)
  cat >"$TEST_ROOT/bin/claude" <<EOF
#!/bin/sh
printf '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"usage":{},"total_cost_usd":0,"structured_output":%s}\n' "\$(cat "$TEST_ROOT/report.json")"
EOF
  chmod 755 "$TEST_ROOT/bin/claude"
  result() { cat "$TEST_ROOT/report-$1/.ship/t/agents/$1.result.json"; }

  assert_exit 0 report_run ex-listed "$base,\"checks\":[$unit],\"exclusions\":$ex}"
  assert_eq "$(result ex-listed | jq -r 'has("error")')" false "a complete report has no error"

  # a link planted at <result>.tmp, a path in the worker's run directory
  mkdir -p "$TEST_ROOT/report-ex-missing/.ship/t/agents"
  printf 'keep me\n' >"$TEST_ROOT/tmp-victim"
  ln -s "$TEST_ROOT/tmp-victim" "$TEST_ROOT/report-ex-missing/.ship/t/agents/ex-missing.result.json.tmp"
  assert_exit 4 report_run ex-missing "$base,\"checks\":[$unit]}"
  assert_eq "$(cat "$TEST_ROOT/tmp-victim")" "keep me" "the target of a planted result.json.tmp link"
  assert_exit 4 report_run ex-empty "$base,\"checks\":[$unit],\"exclusions\":[]}"
  assert_exit 4 report_run ex-partial "$base,\"checks\":[$unit,$lint],\"exclusions\":$ex}"
  for name in ex-missing ex-empty ex-partial; do
    assert_eq "$(result "$name" | jq -r .error)" "$err" "$name: the reason"
    assert_eq "$(result "$name" | jq -r '.status + " " + .checks[0].name')" "pass-with-exclusions unit" "$name: the report is kept"
  done

  # an exclusion covers one check by name and command
  assert_exit 4 report_run ex-same-name "$base,\"checks\":[$unit,{\"name\":\"unit\",\"command\":\"u2\",\"result\":\"fail\"}],\"exclusions\":$ex}"
  assert_exit 4 report_run ex-other-command "$base,\"checks\":[$unit],\"exclusions\":[{\"check\":\"unit\",\"command\":\"other\",\"reason\":\"environment\"}]}"
  for name in ex-same-name ex-other-command; do
    assert_eq "$(result "$name" | jq -r .error)" "$err" "$name: the reason"
  done
}

case_status_enum
case_exclusions_shape
case_strict_copy
case_text_reads_status
case_exclusions_enforced
printf 'tester-status.test.sh: all five cases passed\n'
