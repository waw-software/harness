#!/usr/bin/env bash
# tests/tester-status.test.sh — the tester reports pass, pass-with-exclusions (with an
# `exclusions` list), fail or blocked: the schema, its Codex strict copy, and the texts that
# read the status. Sourced by tests/run.sh (SETUP_UNDER_TEST, fail, assert_contains).
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

case_status_enum
case_exclusions_shape
case_strict_copy
case_text_reads_status
printf 'tester-status.test.sh: all four cases passed\n'
