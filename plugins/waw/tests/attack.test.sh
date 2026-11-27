#!/usr/bin/env bash
# tests/attack.test.sh — attack.sh: provider order, timing settings, the lines it prints while
# it works, failover on no progress, stopping providers, kept invalid answers, adapter notes,
# the scaled timeout and exit 5. Sourced by tests/run.sh (TEST_ROOT, SETUP_UNDER_TEST, fail,
# assert_eq, assert_contains).
set -u

ATTACK=$SETUP_UNDER_TEST/attack.sh
FIXTURES=$TESTS_DIR/fixtures
REPO=$TEST_ROOT/repo
FINDING='| blocker | a.txt:1 | fake finding | fix it |'

cp "$FIXTURES/fake-claude-print.sh" "$TEST_ROOT/bin/claude"
cp "$FIXTURES/fake-opencode.sh" "$TEST_ROOT/bin/opencode"
chmod 755 "$TEST_ROOT/bin/claude" "$TEST_ROOT/bin/opencode"
export WAW_CONFIG=$TEST_ROOT/attack.config WAW_HOME=$TEST_ROOT/wawhome
mkdir -p "$WAW_HOME/workers/fast" "$WAW_HOME/workers/slow"
printf '{}\n' >"$WAW_HOME/workers/fast/settings.json"
printf '{}\n' >"$WAW_HOME/workers/slow/settings.json"

set_config() { # set_config <providers> [effort]
  {
    printf 'PROVIDERS="%s"\n' "$1"
    printf 'OPENCODE_MODEL="go/kimi"\n'
    printf 'AGENT_REVIEWER_MODEL="reviewer-model"\n'
    printf 'FAST_MODEL="fast-model"\n'
    printf 'SLOW_MODEL="slow-model"\n'
    [ -z "${2:-}" ] || printf 'EFFORT="%s"\n' "$2"
  } >"$WAW_CONFIG"
}

new_repo() { # new_repo [bytes of b.txt]: a branch that changes a.txt and adds b.txt
  rm -rf "$REPO"
  git init -q "$REPO"
  git -C "$REPO" symbolic-ref HEAD refs/heads/main
  printf 'one\n' >"$REPO/a.txt"
  git -C "$REPO" add a.txt
  git -C "$REPO" commit -qm base
  git -C "$REPO" checkout -qb change
  printf 'two\n' >"$REPO/a.txt"
  if [ -n "${1:-}" ]; then
    awk -v n="$1" 'BEGIN { for (i = 0; i < int(n / 100); i++) printf "%099d\n", i }' >"$REPO/b.txt"
  else
    printf 'new\n' >"$REPO/b.txt"
  fi
  git -C "$REPO" add a.txt b.txt
  git -C "$REPO" commit -qm change
}

reset_case() {
  new_repo "${1:-}"
  rm -rf "$TEST_ROOT/keep" "$TEST_ROOT/out" "$TEST_ROOT/err" "$TEST_ROOT/release" \
    "$TEST_ROOT/opencode-child.pid"
  unset ATTACK_TIMEOUT ATTACK_FIRST_OUTPUT ATTACK_HEARTBEAT ATTACK_TEST_RUNNER \
    FAKE_OPENCODE_MODE FAKE_CLAUDE_PRINT_MODE FAKE_RELEASE
}

rc=0 out='' err=''
attack() { # attack <args...>: sets rc, out, err
  rc=0
  bash "$ATTACK" --repo "$REPO" --keep-dir "$TEST_ROOT/keep" "$@" \
    >"$TEST_ROOT/out" 2>"$TEST_ROOT/err" || rc=$?
  out=$(cat "$TEST_ROOT/out")
  err=$(cat "$TEST_ROOT/err")
}

exit_is() { assert_eq "$rc" "$1" "$2: exit (stdout: $out; stderr: $err)"; }
line_of() { # line_of <prefix>: the number of the first stdout line that starts with it
  awk -v p="$1" 'index($0, p) == 1 { print NR; exit }' "$TEST_ROOT/out"
}
in_order() { # in_order <prefix...>
  local p n last=0
  for p in "$@"; do
    n=$(line_of "$p")
    [ -n "$n" ] && [ "$n" -gt "$last" ] || fail "no line [$p] after line $last in: $out"
    last=$n
  done
}

case_duplicate_providers() {
  reset_case
  set_config "opencode opencode"
  rc=0
  out=$(bash "$ATTACK" --check-config 2>"$TEST_ROOT/err") || rc=$?
  err=$(cat "$TEST_ROOT/err")
  exit_is 3 duplicate
  assert_contains "$err" "duplicate provider 'opencode'" "duplicate stderr"
}

case_bad_timing() {
  reset_case
  set_config opencode
  local v
  for v in ATTACK_HEARTBEAT=abc ATTACK_HEARTBEAT=0 ATTACK_FIRST_OUTPUT=-1 ATTACK_TIMEOUT=0 \
    ATTACK_TIMEOUT=1.5; do
    export "${v?}"
    attack --role review
    exit_is 2 "$v"
    assert_contains "$err" "${v%%=*}" "$v stderr"
    unset "${v%%=*}"
  done
  attack --role review --max-bytes abc
  exit_is 2 "--max-bytes abc"
  attack --role review --max-bytes 0900000
  exit_is 0 "--max-bytes with a leading zero"
  set_config fast
  export ATTACK_FIRST_OUTPUT=08
  attack --role review
  exit_is 0 "ATTACK_FIRST_OUTPUT=08"
  assert_contains "$out" 'trying: fast:fast-model (timeout ' "trying line"
  assert_contains "$out" 's, first output within 8s)' "first-output wait"
}

case_valid_no_note() {
  reset_case
  set_config opencode
  attack --role review
  exit_is 0 valid
  in_order 'trying: opencode:go/kimi (timeout ' 'provider: opencode:go/kimi' 'coverage: full' "$FINDING"
  case $out in *'note:'* | *'first output'*) fail "unexpected line: $out" ;; esac
}

case_failover_on_no_progress() {
  reset_case
  set_config "slow opencode"
  export FAKE_CLAUDE_PRINT_MODE=startup-only ATTACK_FIRST_OUTPUT=2 ATTACK_HEARTBEAT=1
  local start=$SECONDS
  attack --role review
  exit_is 0 failover
  in_order 'trying: slow:slow-model' 'waiting: slow 1s' 'skipped: slow (no first output within 2s)' \
    'trying: opencode' 'provider: opencode'
  assert_eq "$(grep -c '^skipped: slow ' "$TEST_ROOT/out")" 1 "skipped lines"
  [ $((SECONDS - start)) -lt 15 ] || fail "failover took $((SECONDS - start))s"
}

case_progress_keeps_provider() {
  reset_case
  set_config "fast opencode"
  local pid n=0
  FAKE_CLAUDE_PRINT_MODE=held ATTACK_FIRST_OUTPUT=1 ATTACK_HEARTBEAT=1 \
    FAKE_RELEASE=$TEST_ROOT/release bash "$ATTACK" --repo "$REPO" --role review \
    --keep-dir "$TEST_ROOT/keep" >"$TEST_ROOT/out" 2>"$TEST_ROOT/err" &
  pid=$!
  while ! grep -qx 'waiting: fast 2s' "$TEST_ROOT/out" 2>/dev/null && [ "$n" -lt 100 ]; do
    sleep 0.1; n=$((n + 1))
  done
  grep -qx 'waiting: fast 2s' "$TEST_ROOT/out" ||
    fail "no heartbeat while running: $(cat "$TEST_ROOT/out" "$TEST_ROOT/err")"
  kill -0 "$pid" 2>/dev/null || fail "attack.sh ended before the release"
  ! grep -q '^provider:' "$TEST_ROOT/out" || fail "provider line before the release"
  : >"$TEST_ROOT/release"
  rc=0
  wait "$pid" || rc=$?
  out=$(cat "$TEST_ROOT/out") err=$(cat "$TEST_ROOT/err")
  exit_is 0 held
  assert_contains "$out" 'provider: fast' "provider"
  case $out in *'skipped: fast'*) fail "fast was skipped: $out" ;; esac
}

case_stubborn_child_killed() {
  reset_case
  set_config "opencode fast"
  export FAKE_OPENCODE_MODE=stubborn ATTACK_TIMEOUT=2
  local start=$SECONDS child t
  # A timeout(1) that ends only the command itself, as GNU timeout does once that has exited:
  # attack.sh must not use it, or the child stays.
  for t in timeout gtimeout; do
    cat >"$TEST_ROOT/bin/$t" <<'EOF'
#!/bin/sh
[ "$1" != -k ] || shift 2
limit=$1
shift
"$@" &
pid=$!
sleep "$limit"
kill -0 "$pid" 2>/dev/null || { wait "$pid"; exit; }
kill -KILL "$pid"
exit 124
EOF
    chmod 755 "$TEST_ROOT/bin/$t"
  done
  attack --role review
  rm -f "$TEST_ROOT/bin/timeout" "$TEST_ROOT/bin/gtimeout"
  exit_is 0 stubborn
  in_order 'skipped: opencode (timed out after 2s)' 'provider: fast'
  [ $((SECONDS - start)) -lt 15 ] || fail "stopping took $((SECONDS - start))s"
  child=$(cat "$TEST_ROOT/opencode-child.pid")
  if kill -0 "$child" 2>/dev/null; then
    kill -KILL "$child" 2>/dev/null
    fail "the child that ignores TERM is still running"
  fi
}

case_invalid_concurrent() {
  reset_case
  set_config opencode
  export FAKE_OPENCODE_MODE=invalid
  local i p1 p2 rc1=0 rc2=0 raw1 raw2 f old_umask
  old_umask=$(umask)
  umask 022
  for i in 1 2; do
    bash "$ATTACK" --repo "$REPO" --role review --keep-dir "$TEST_ROOT/keep" \
      >"$TEST_ROOT/out$i" 2>"$TEST_ROOT/err$i" &
    eval "p$i=\$!"
  done
  wait "$p1" || rc1=$?
  wait "$p2" || rc2=$?
  assert_eq "$rc1 $rc2" '4 4' "exits: $(cat "$TEST_ROOT"/out[12] "$TEST_ROOT"/err[12])"
  raw1=$(sed -n 's/^skipped: opencode (invalid answer; raw: \(.*\))$/\1/p' "$TEST_ROOT/out1")
  raw2=$(sed -n 's/^skipped: opencode (invalid answer; raw: \(.*\))$/\1/p' "$TEST_ROOT/out2")
  [ -n "$raw1" ] && [ -n "$raw2" ] || fail "no raw path: $(cat "$TEST_ROOT"/out[12])"
  [ "$raw1" != "$raw2" ] || fail "both runs kept $raw1"
  assert_eq "${raw1%/*}" "$TEST_ROOT/keep" "keep dir"
  case ${raw1##*/} in attack-review-opencode.*) ;; *) fail "kept name: $raw1" ;; esac
  grep -qE '^all fine pid [0-9]+$' "$raw1" || fail "raw1: $(cat "$raw1")"
  grep -qE '^all fine pid [0-9]+$' "$raw2" || fail "raw2: $(cat "$raw2")"
  [ "$(cat "$raw1")" != "$(cat "$raw2")" ] || fail "both files hold the same answer"
  [ -f "$raw1.err" ] && [ -f "$raw2.err" ] || fail "stderr was not kept"
  umask "$old_umask"
  for f in "$raw1" "$raw1.err" "$raw2" "$raw2.err"; do
    assert_eq "$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f")" 600 "mode of $f"
  done
  assert_eq "$(grep -c '^skipped: ' "$TEST_ROOT/out1")" 1 "skipped lines"
}

case_keep_dir_default() {
  reset_case
  set_config opencode
  export FAKE_OPENCODE_MODE=invalid
  mkdir -p "$TEST_ROOT/run"
  printf 'the task\n' >"$TEST_ROOT/run/task.md"
  rc=0
  (cd "$TEST_ROOT" && bash "$ATTACK" --repo "$REPO" --role review --task "$TEST_ROOT/run/task.md") \
    >"$TEST_ROOT/out" 2>"$TEST_ROOT/err" || rc=$?
  out=$(cat "$TEST_ROOT/out") err=$(cat "$TEST_ROOT/err")
  exit_is 4 "keep dir of --task"
  assert_contains "$out" "raw: $TEST_ROOT/run/attack-review-opencode." "next to the task"
  mkdir -p "$TEST_ROOT/tmpdir"
  rc=0
  TMPDIR=$TEST_ROOT/tmpdir bash "$ATTACK" --repo "$REPO" --role review \
    >"$TEST_ROOT/out" 2>"$TEST_ROOT/err" || rc=$?
  out=$(cat "$TEST_ROOT/out") err=$(cat "$TEST_ROOT/err")
  exit_is 4 "keep dir in TMPDIR"
  assert_contains "$out" "raw: $TEST_ROOT/tmpdir/waw-attack/attack-review-opencode." "in TMPDIR"
}

case_partial_review_exits_5() {
  reset_case 2000
  set_config opencode
  local role
  for role in review security; do
    attack --role "$role" --max-bytes 300
    exit_is 5 "partial $role"
    assert_contains "$out" 'coverage: partial' "coverage"
    assert_contains "$out" "$FINDING" "finding"
  done
}

case_decide_capped_doc() {
  reset_case
  set_config opencode
  cp "$TEST_ROOT/bin/opencode" "$TEST_ROOT/opencode.saved"
  printf '#!/bin/sh\necho "| Q1 | A | because |"\n' >"$TEST_ROOT/bin/opencode"
  { printf 'Q1: which one?\n'; printf '%02000d\n' 0; } >"$TEST_ROOT/question.md"
  attack --role decide --question "$TEST_ROOT/question.md" --max-bytes 300
  cp "$TEST_ROOT/opencode.saved" "$TEST_ROOT/bin/opencode"
  exit_is 0 "partial decide"
  assert_contains "$out" 'coverage: partial' "coverage"
  assert_contains "$out" '| Q1 | A | because |' "decision"
}

case_note_shown() {
  reset_case
  set_config opencode high
  export FAKE_OPENCODE_MODE=variant
  attack --role review
  exit_is 0 note
  in_order 'provider: opencode' 'note: opencode: effort high is not a variant of go/kimi' \
    'coverage: full' "$FINDING"
}

case_timeout_scaled() {
  reset_case 100000
  set_config opencode
  local t
  attack --role review
  exit_is 0 scaled
  t=$(sed -n 's/^trying: opencode:go\/kimi (timeout \([0-9]*\)s)$/\1/p' "$TEST_ROOT/out")
  [ -n "$t" ] && [ "$t" -ge 1100 ] && [ "$t" -le 1300 ] || fail "scaled timeout [$t]: $out"
  export ATTACK_TIMEOUT=30
  attack --role review
  exit_is 0 "set timeout"
  assert_contains "$out" '(timeout 30s)' "set timeout"
  # With omitted files the deadline follows the provider's whole input, their list included.
  reset_case 2000
  cp "$TEST_ROOT/bin/opencode" "$TEST_ROOT/opencode.saved"
  cat >"$TEST_ROOT/bin/opencode" <<'EOF'
#!/usr/bin/env bash
prev=''
for a in "$@"; do
  [ "$prev" != --file ] || cp "$a" "$TEST_ROOT/sent-input"
  prev=$a
done
exec bash "$TEST_ROOT/opencode.saved" "$@"
EOF
  attack --role review --max-bytes 300
  cp "$TEST_ROOT/opencode.saved" "$TEST_ROOT/bin/opencode"
  exit_is 5 "scaled with omitted files"
  grep -q '^===== NOT IN THIS INPUT' "$TEST_ROOT/sent-input" || fail "no omitted list in the input"
  local bytes
  bytes=$(wc -c <"$TEST_ROOT/sent-input" | tr -d ' ')
  t=$(sed -n 's/^trying: opencode:go\/kimi (timeout \([0-9]*\)s)$/\1/p' "$TEST_ROOT/out")
  assert_eq "$t" "$((600 + 6 * bytes / 1000))" "deadline of a $bytes byte input"
}

cases="duplicate_providers bad_timing valid_no_note failover_on_no_progress progress_keeps_provider
stubborn_child_killed invalid_concurrent keep_dir_default partial_review_exits_5
decide_capped_doc note_shown timeout_scaled"
for c in $cases; do
  printf 'case %s\n' "$c"
  "case_$c"
done
printf 'attack.test.sh: all cases passed\n'
