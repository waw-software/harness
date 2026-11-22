#!/usr/bin/env bash
# tests/deps-security.test.sh: task.sh deps installs only on the untouched task base.
# Sourced by tests/run.sh into a fresh subshell: TEST_ROOT, SETUP_UNDER_TEST and the
# runner helpers (fail, assert_eq, assert_contains) exist here.
# A fake pnpm (first on PATH) records each call in its own marker file and exits 0;
# every remote is a local bare repo under TEST_ROOT.
set -u

TASK=$SETUP_UNDER_TEST/task.sh
CASES=$TEST_ROOT/deps-cases
FAKEBIN=$TEST_ROOT/deps-fakebin
CALLS=$TEST_ROOT/deps-pnpm-calls
mkdir -p "$CASES" "$FAKEBIN"
cat >"$FAKEBIN/pnpm" <<EOF
#!/bin/sh
printf '%s\n' "pnpm \$*" >> "$CALLS"
exit 0
EOF
chmod 755 "$FAKEBIN/pnpm"
export PATH="$FAKEBIN:$PATH"

calls() { if [ -f "$CALLS" ]; then wc -l <"$CALLS" | tr -d ' '; else echo 0; fi; }

# make_clone <name> [nolock]: a bare origin with package.json (and pnpm-lock.yaml) on main
# and a clone of it with origin/HEAD set; prints the clone path. Resets the call log.
make_clone() {
  local c=$CASES/$1 w
  rm -f "$CALLS"
  git init -q --bare -b main "$c/origin" || return 1
  w=$c/seed
  git init -q -b main "$w" || return 1
  printf '{}\n' >"$w/package.json"
  [ "${2:-}" = nolock ] || printf 'lockfileVersion: 9\n' >"$w/pnpm-lock.yaml"
  git -C "$w" add . || return 1
  git -C "$w" commit -q -m c1 || return 1
  git -C "$w" push -q "$c/origin" main || return 1
  git clone -q "$c/origin" "$c/clone" || return 1
  git -C "$c/clone" remote set-head origin --auto >/dev/null || return 1
  printf '%s\n' "$c/clone"
}

# run_deps <rc-var-free>: runs task.sh deps in <dir> with args; sets OUT and RC.
run_deps() {
  local dir=$1; shift
  OUT=$(cd "$dir" && bash "$TASK" deps "$@" 2>&1); RC=$?
}

local_commit() { git -C "$1" commit -q --allow-empty -m local || fail "fixture: local commit"; }

case_clean_base_installs() {
  local d; d=$(make_clone clean) || fail "fixture"
  run_deps "$d"
  assert_eq "$RC" "0" "clean base exit: $OUT"
  assert_eq "$(calls)" "1" "pnpm called once"
}

case_commit_beyond_base_refused() {
  local d; d=$(make_clone beyond) || fail "fixture"
  local_commit "$d"
  run_deps "$d"
  assert_eq "$RC" "3" "exit with a commit beyond the base"
  assert_contains "$OUT" "deps: HEAD has commits beyond" "message"
  assert_eq "$(calls)" "0" "pnpm not called"
}

case_modified_file_refused() {
  local d; d=$(make_clone modified) || fail "fixture"
  printf '{"scripts":{"postinstall":"x"}}\n' >"$d/package.json"
  run_deps "$d"
  assert_eq "$RC" "3" "exit with a modified file"
  assert_contains "$OUT" "deps: the worktree has changes (package.json)" "message"
  assert_eq "$(calls)" "0" "pnpm not called"
}

case_untracked_file_refused() {
  local d; d=$(make_clone untracked) || fail "fixture"
  printf 'module.exports = {}\n' >"$d/.pnpmfile.cjs"
  run_deps "$d"
  assert_eq "$RC" "3" "exit with an untracked file"
  assert_contains "$OUT" "deps: the worktree has changes (.pnpmfile.cjs)" "message"
  assert_eq "$(calls)" "0" "pnpm not called"
}

case_force_keeps_gate() {
  local d; d=$(make_clone force) || fail "fixture"
  local_commit "$d"
  run_deps "$d" --force
  assert_eq "$RC" "3" "--force does not lift the gate"
  assert_eq "$(calls)" "0" "pnpm not called"
}

case_ship_dir_ignored() {
  local d; d=$(make_clone ship) || fail "fixture"
  mkdir -p "$d/.ship/x" && printf notes >"$d/.ship/x/notes.md" || fail "fixture: .ship"
  mkdir -p "$d/node_modules/pkg" && printf x >"$d/node_modules/pkg/index.js" || fail "fixture: node_modules"
  touch -t 202001010000 "$d/node_modules"
  run_deps "$d"
  assert_eq "$RC" "0" "only .ship and node_modules present: $OUT"
  assert_eq "$(calls)" "1" "pnpm called"
}

case_explicit_base() {
  local d sha parent; d=$(make_clone base) || fail "fixture"
  parent=$(git -C "$d" rev-parse HEAD)
  local_commit "$d"
  sha=$(git -C "$d" rev-parse HEAD)
  run_deps "$d" --base "$sha"
  assert_eq "$RC" "0" "HEAD equals the base: $OUT"
  assert_eq "$(calls)" "1" "pnpm called"
  run_deps "$d" --force --base "$parent"
  assert_eq "$RC" "3" "HEAD differs from the base"
  assert_eq "$(calls)" "1" "pnpm not called again"
  run_deps "$d" --base no-such-commit
  assert_eq "$RC" "3" "unknown base"
  assert_contains "$OUT" "deps: unknown base no-such-commit" "message"
}

case_fresh_deps_skip() {
  local d; d=$(make_clone fresh) || fail "fixture"
  touch -t 202001010000 "$d/pnpm-lock.yaml"
  mkdir -p "$d/node_modules" || fail "fixture: node_modules"
  local_commit "$d"
  run_deps "$d"
  assert_eq "$RC" "0" "fresh node_modules exit: $OUT"
  assert_contains "$OUT" "up to date" "message"
  assert_eq "$(calls)" "0" "pnpm not called"
}

case_no_lockfile() {
  local d; d=$(make_clone nolock nolock) || fail "fixture"
  run_deps "$d"
  assert_eq "$RC" "0" "no lockfile exit: $OUT"
  assert_eq "$(calls)" "0" "pnpm not called"
}

case_symlinked_log_refused() {
  local d; d=$(make_clone symlog) || fail "fixture"
  printf 'precious\n' >"$TEST_ROOT/victim" || fail "fixture: victim"
  mkdir -p "$d/.ship" && ln -s "$TEST_ROOT/victim" "$d/.ship/deps.log" || fail "fixture: symlink"
  run_deps "$d"
  assert_eq "$RC" "3" "symlinked log exit: $OUT"
  assert_contains "$OUT" "is a symlink" "message"
  assert_eq "$(cat "$TEST_ROOT/victim")" "precious" "victim unchanged"
  assert_eq "$(calls)" "0" "pnpm not called"
}

case_symlinked_ship_refused() {
  local d; d=$(make_clone symship) || fail "fixture"
  mkdir -p "$TEST_ROOT/elsewhere" && ln -s "$TEST_ROOT/elsewhere" "$d/.ship" || fail "fixture: symlink"
  run_deps "$d"
  assert_eq "$RC" "3" "symlinked .ship exit: $OUT"
  assert_eq "$(calls)" "0" "pnpm not called"
  assert_eq "$(ls -A "$TEST_ROOT/elsewhere" | wc -l | tr -d ' ')" "0" "nothing written through the link"
}

case_clean_base_installs
case_symlinked_log_refused
case_symlinked_ship_refused
case_commit_beyond_base_refused
case_modified_file_refused
case_untracked_file_refused
case_force_keeps_gate
case_ship_dir_ignored
case_explicit_base
case_fresh_deps_skip
case_no_lockfile
printf 'deps-security.test.sh: all eleven cases passed\n'
