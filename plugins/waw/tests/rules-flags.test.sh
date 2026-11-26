#!/usr/bin/env bash
# tests/rules-flags.test.sh — every --flag that rules/*.md and skills/*/SKILL.md name next to
# one of the scripts is documented in that script's header (or a usage line), and the rule texts
# about the lease push, the script calls and the workers' file edits are there. Sourced by
# tests/run.sh (TEST_ROOT, SETUP_UNDER_TEST, fail, assert_contains).
set -u

PLUGIN=$SETUP_UNDER_TEST/..
RULES=$PLUGIN/rules

script_flags() { # script_flags <script.sh>: the --flags of its header and its usage lines
  awk 'NR == 1 {next} NR == 2 {h = 1} h && !/^#/ {h = 0} h || /usage/' "$SETUP_UNDER_TEST/$1" |
    grep -oE -- '--[a-z][a-z0-9-]*' | sort -u
}

named_flags() { # named_flags <md file>: "<script.sh> <--flag> <file>:<line>" per named flag
  awk -v file="$1" '
    function emit(script, text, line) {
      while (match(text, /--[a-z][a-z0-9-]*/)) {
        print script, substr(text, RSTART, RLENGTH), file ":" line
        text = substr(text, RSTART + RLENGTH)
      }
    }
    # The inline code spans of one paragraph; a span may wrap over its lines.
    function flush(   n, part, i, j, m, row, line, span, script) {
      # macOS awk also splits at newlines on a one-character separator: hide them first.
      gsub(/\n/, "\001", para)
      n = split(para, part, "`")
      line = start
      for (i = 1; i <= n; i++) {
        m = split(part[i], row, "\001")
        if (i % 2 == 0 && i < n) {
          span = part[i]
          gsub(/\001/, " ", span)
          sub(/^(! )?/, "", span)
          if (match(span, /^(agent|attack|task|deliver|stage|smoke)\.sh/)) {
            script = substr(span, 1, RLENGTH)
            for (j = 1; j <= m; j++) emit(script, row[j], line + j - 1)
          }
        }
        if (m > 1) line += m - 1
      }
      para = ""; ticks = 0
    }
    /^[ \t]*```/ { flush(); fenced = !fenced; cont = ""; next }
    {
      text = $0
      sub(/^[ \t]+/, "", text)
      code = fenced || (/^(    |\t)/ && ticks % 2 == 0)
      if (cont != "" && (code || fenced)) script = cont
      else if (code && match(text, /^(agent|attack|task|deliver|stage|smoke)\.sh/))
        script = substr(text, 1, RLENGTH)
      else script = ""
      cont = ""
      if (script != "") {
        flush()
        emit(script, text, FNR)
        if (text ~ /\\$/) cont = script
        next
      }
      if (fenced) next
      if (text == "") { flush(); next }
      if (para == "") { start = FNR; para = $0 } else para = para "\n" $0
      ticks += gsub(/`/, "`")
    }
    END { flush() }
  ' "$1"
}

check_flags() { # check_flags <md file>...: MISSING lines, then "checked <n>"
  local md script flag loc n=0
  for md in "$@"; do
    [ -f "$md" ] || fail "check_flags: no such file: $md"
    while read -r script flag loc; do
      [ -n "$script" ] || continue
      n=$((n + 1))
      script_flags "$script" | grep -qE -- "(^|[^a-z0-9-])$flag([^a-z0-9-]|\$)" ||
        printf 'MISSING %s %s at %s\n' "$script" "$flag" "$loc"
    done <<<"$(named_flags "$md")"
  done
  printf 'checked %s\n' "$n"
}

# --- cases

case_detects_unknown_flag() {
  local fx=$TEST_ROOT/rules-fx out
  mkdir -p "$fx"
  cat >"$fx/x.md" <<'EOF'
Push with `deliver.sh push --no-such-flag` now.

Open it with `deliver.sh mr --title t
[--bogus-wrap]` afterwards.

    agent.sh run --role r \
      --bogus-cont
EOF
  out=$(check_flags "$fx/x.md") || fail "check_flags on the fixture: $out"
  assert_contains "$out" "MISSING deliver.sh --no-such-flag at $fx/x.md:1" "span"
  assert_contains "$out" "MISSING deliver.sh --bogus-wrap at $fx/x.md:4" "wrapped span"
  assert_contains "$out" "MISSING agent.sh --bogus-cont at $fx/x.md:7" "continued code line"
  case $out in
    *' --title '*|*' --role '*) fail "documented flag reported missing: $out" ;;
  esac
  assert_contains "$out" "checked 5" "fixture pairs"
}

case_rules_flags_exist() {
  local out missing n
  out=$(check_flags "$RULES"/*.md "$PLUGIN"/skills/*/SKILL.md) || fail "check_flags: $out"
  missing=$(printf '%s\n' "$out" | grep '^MISSING ')
  [ -z "$missing" ] || fail "flags that the script header does not document:
$missing"
  n=$(printf '%s\n' "$out" | tail -n 1)
  n=${n#checked }
  [ "$n" -ge 25 ] || fail "only $n flags checked in the rules and skills, expected at least 25"
}

case_lease_rule() {
  local hits
  hits=$(grep -niF -- 'never forces' "$RULES"/*.md "$PLUGIN"/skills/*/SKILL.md)
  [ -z "$hits" ] || fail "'never forces' is still there:
$hits"
  grep -qF -- 'deliver.sh push --force-with-lease' "$RULES/git-delivery.md" ||
    fail "rules/git-delivery.md lacks 'deliver.sh push --force-with-lease'"
  grep -qw -- 'approval' "$RULES/git-delivery.md" ||
    fail "rules/git-delivery.md lacks the word 'approval'"
}

case_cheat_sheet() {
  local section script
  grep -qx -- '## Script calls' "$RULES/commander.md" ||
    fail "rules/commander.md lacks the line '## Script calls'"
  section=$(awk '$0 == "## Script calls" {f = 1; next} /^## / {f = 0} f' "$RULES/commander.md")
  for script in agent attack task deliver stage smoke; do
    printf '%s\n' "$section" | grep -q "^    $script\.sh " ||
      fail "rules/commander.md '## Script calls' lacks an indented line starting with '$script.sh '"
  done
}

case_roles_edit_rule() {
  local word
  for word in Edit Write Grep Glob 'sed -i' heredoc python; do
    grep -qF -- "$word" "$SETUP_UNDER_TEST/roles/common.md" ||
      fail "scripts/roles/common.md lacks '$word'"
  done
}

case_detects_unknown_flag
case_rules_flags_exist
case_lease_rule
case_cheat_sheet
case_roles_edit_rule
printf 'rules-flags.test.sh: all five cases passed\n'
