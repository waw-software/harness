#!/usr/bin/env bash
# tests/prepare.test.sh — H2: task.sh prepare, the detached worktree at origin's
# default branch.
# Sourced by tests/run.sh into a fresh subshell: TEST_ROOT, SETUP_UNDER_TEST and
# the runner helpers (fail, assert_eq, assert_contains, assert_exit) exist here.
# Seven cases over the staging task.sh; every remote is a local bare repo under
# TEST_ROOT and no tool but git and task.sh is invoked.
set -u

TASK=$SETUP_UNDER_TEST/task.sh
CASES=$TEST_ROOT/prepare-cases
mkdir -p "$CASES"

absent() { [ ! -e "$1" ] || fail "must not exist: $1"; }

assert_detached() { # the worktree has no branch checked out
  [ -z "$(git -C "$1" symbolic-ref -q --short HEAD 2>/dev/null)" ] || fail "not detached: $1"
}

# setup_repo <origin> <main> <default>: a bare origin whose HEAD is <default> and a
# plain (non-clone) main checkout of it, on <default>, with origin/HEAD resolved.
setup_repo() {
  git init -q --bare -b "$3" "$1" || return 1
  git init -q -b "$3" "$2" || return 1
  git -C "$2" remote add origin "$1" || return 1
  git -C "$2" commit -q --allow-empty -m c1 || return 1
  git -C "$2" push -q origin "$3" || return 1
  git -C "$2" fetch -q origin || return 1
  git -C "$2" remote set-head origin --auto >/dev/null || return 1
}

# push_new <origin> <branch>: advance <branch> on <origin> from a throwaway repo,
# so the main checkout learns of it only through a fetch.
push_new() {
  local w=$CASES/pusher
  rm -rf "$w"
  git init -q "$w" || return 1
  git -C "$w" remote add origin "$1" || return 1
  git -C "$w" fetch -q origin || return 1
  git -C "$w" checkout -q -b "$2" "refs/remotes/origin/$2" || return 1
  git -C "$w" commit -q --allow-empty -m "advance-$2-$RANDOM" || return 1
  git -C "$w" push -q origin "$2" || return 1
  rm -rf "$w"
}

run_prep() { # run_prep <cwd> <args...>: run the staging prepare, output swallowed
  local dir=$1; shift
  (cd "$dir" && bash "$TASK" prepare "$@" >/dev/null 2>&1)
}

case_detached_origin_default() {
  local c=$CASES/c1 origin main out rc dest heads repo
  origin=$c/origin main=$c/main-one
  setup_repo "$origin" "$main" develop || fail "fixture: setup_repo"
  git -C "$main" checkout -q -b side || fail "fixture: side branch"
  push_new "$origin" develop || fail "fixture: advance origin/develop"
  [ "$(git -C "$main" rev-parse develop)" != "$(git -C "$origin" rev-parse develop)" ] ||
    fail "fixture: origin/develop must have advanced past the checkout"
  repo=$(basename "$main")
  heads=$(git -C "$main" for-each-ref 'refs/heads/')
  out=$(cd "$main" && bash "$TASK" prepare mytask 2>"$c/err"); rc=$?
  assert_eq "$rc" "0" "prepare exit code"
  dest=$AGENTIC_WORKTREES/$repo/mytask
  assert_eq "$out" "path $dest" "stdout is exactly the path line"
  assert_detached "$dest"
  assert_eq "$(git -C "$dest" rev-parse HEAD)" "$(git -C "$origin" rev-parse develop)" \
    "worktree HEAD is the fetched origin/develop, not the caller's branch"
  assert_eq "$(git -C "$main" for-each-ref 'refs/heads/')" "$heads" "no new branch refs"
}

case_fatal_fetch() {
  local c=$CASES/c2 origin main out err rc repo
  origin=$c/origin main=$c/main-two
  setup_repo "$origin" "$main" main || fail "fixture: setup_repo"
  git -C "$main" remote set-url origin "$c/no-such-origin" || fail "fixture: break origin"
  repo=$(basename "$main")
  out=$(cd "$main" && bash "$TASK" prepare mytask 2>"$c/err"); rc=$?
  assert_eq "$rc" "3" "a failed fetch exits 3"
  assert_eq "$out" "" "no success line after a failed fetch"
  err=$(cat "$c/err")
  assert_contains "$err" "task.sh: prepare could not fetch origin" "task.sh's message"
  assert_contains "$err" "no-such-origin" "git's own error is preserved"
  absent "$AGENTIC_WORKTREES/$repo/mytask"
  absent "$AGENTIC_WORKTREES/$repo/mytask-2"
  assert_eq "$(git -C "$main" worktree list --porcelain | grep -c '^worktree ')" "1" \
    "no worktree was registered"
  assert_eq "$(git -C "$main" show-ref --heads | wc -l | tr -d ' ')" "1" "no branch was created"
}

case_collision_suffixes() {
  local c=$CASES/c3 origin main out rc repo dest w out1 out2 p1 p2
  origin=$c/origin main=$c/main-three
  setup_repo "$origin" "$main" develop || fail "fixture: setup_repo"
  repo=$(basename "$main")
  # a folder, a file and a dangling symlink are taken, under a root with a space
  w="$CASES/space root/$repo"
  mkdir -p "$w" || fail "fixture: space root"
  mkdir "$w/mytask" && printf keep >"$w/mytask/marker" || fail "fixture: dir collision"
  printf keep >"$w/mytask-2" || fail "fixture: file collision"
  ln -s "$c/no-such-symlink-target" "$w/mytask-3" || fail "fixture: dangling symlink"
  out=$(cd "$main" && AGENTIC_WORKTREES="$CASES/space root" bash "$TASK" prepare mytask 2>"$c/err"); rc=$?
  assert_eq "$rc" "0" "prepare exits 0 past every collision"
  dest="$w/mytask-4"
  assert_eq "$out" "path $dest" "next free suffix, spaces intact"
  assert_detached "$dest"
  assert_eq "$(git -C "$dest" rev-parse HEAD)" "$(git -C "$origin" rev-parse develop)" \
    "collision worktree is at origin/develop"
  assert_eq "$(cat "$w/mytask/marker")" "keep" "pre-existing folder preserved"
  assert_eq "$(cat "$w/mytask-2")" "keep" "pre-existing file preserved"
  [ -L "$w/mytask-3" ] || fail "dangling symlink was replaced"
  assert_eq "$(readlink "$w/mytask-3")" "$c/no-such-symlink-target" "symlink target unchanged"
  # a worktree registered but since deleted is taken too: its registration stays
  mkdir -p "$AGENTIC_WORKTREES/$repo" || fail "fixture: repo worktree dir"
  git -C "$main" worktree add -q --detach "$AGENTIC_WORKTREES/$repo/regslug" origin/develop ||
    fail "fixture: registered worktree"
  rm -rf "$AGENTIC_WORKTREES/$repo/regslug"
  assert_contains "$(git -C "$main" worktree list --porcelain)" \
    "worktree $AGENTIC_WORKTREES/$repo/regslug" "fixture: the registration survives"
  out=$(cd "$main" && bash "$TASK" prepare regslug 2>"$c/err2"); rc=$?
  assert_eq "$rc" "0" "prepare past the registration"
  assert_eq "$out" "path $AGENTIC_WORKTREES/$repo/regslug-2" "registered path skipped"
  absent "$AGENTIC_WORKTREES/$repo/regslug"
  # two prepares of one slug at the same time take distinct free paths
  (cd "$main" && bash "$TASK" prepare contask) >"$c/o1" 2>"$c/e1" & p1=$!
  (cd "$main" && bash "$TASK" prepare contask) >"$c/o2" 2>"$c/e2" & p2=$!
  assert_exit 0 wait "$p1"
  assert_exit 0 wait "$p2"
  out1=$(cat "$c/o1"); out2=$(cat "$c/o2")
  dest=$AGENTIC_WORKTREES/$repo/contask
  if { [ "$out1" = "path $dest" ] && [ "$out2" = "path $dest-2" ]; } ||
     { [ "$out1" = "path $dest-2" ] && [ "$out2" = "path $dest" ]; }; then :; else
    fail "concurrent prepares took [$out1] and [$out2]"
  fi
  assert_detached "$AGENTIC_WORKTREES/$repo/contask"
  assert_detached "$AGENTIC_WORKTREES/$repo/contask-2"
}

case_missing_default_or_invalid_invocation() {
  local c=$CASES/c4 origin main out rc repo wt snap_heads snap_wt
  # an origin with no resolvable default: a bare repo with no refs at all
  origin=$c/empty-origin main=$c/main-zero
  git init -q --bare "$origin" || fail "fixture: bare origin"
  git init -q "$main" || fail "fixture: main"
  git -C "$main" remote add origin "$origin" || fail "fixture: remote"
  git -C "$main" commit -q --allow-empty -m c1 || fail "fixture: commit"
  out=$(cd "$main" && bash "$TASK" prepare mytask 2>"$c/err"); rc=$?
  assert_eq "$rc" "3" "an origin without a resolvable default exits 3"
  assert_eq "$out" "" "no success line"
  absent "$AGENTIC_WORKTREES/$(basename "$main")/mytask"
  assert_eq "$(git -C "$main" show-ref --heads | wc -l | tr -d ' ')" "1" "no branch was created"
  # invalid invocations against a healthy repo
  origin=$c/origin2 main=$c/main-four
  setup_repo "$origin" "$main" develop || fail "fixture: setup_repo"
  repo=$(basename "$main")
  mkdir -p "$AGENTIC_WORKTREES/$repo" || fail "fixture: repo worktree dir"
  wt=$AGENTIC_WORKTREES/$repo/linked
  git -C "$main" worktree add -q -b linked-branch "$wt" origin/develop || fail "fixture: linked worktree"
  snap_heads=$(git -C "$main" for-each-ref)
  snap_wt=$(git -C "$main" worktree list --porcelain)
  assert_exit 2 run_prep "$main" "Bad Slug"
  assert_exit 2 run_prep "$main" mytask --flag
  assert_exit 2 run_prep "$main"
  assert_exit 2 bash "$TASK" prepare mytask extra1 extra2
  assert_exit 3 run_prep "$wt" someslug
  assert_eq "$(git -C "$main" for-each-ref)" "$snap_heads" "no branch side effects"
  assert_eq "$(git -C "$main" worktree list --porcelain)" "$snap_wt" "no worktree side effects"
  absent "$AGENTIC_WORKTREES/$repo/someslug"
  absent "$AGENTIC_WORKTREES/$repo/mytask"
}

case_no_other_workflow() {
  local c=$CASES/c5 origin main out rc repo dest donewt
  origin=$c/origin main=$c/main-five
  setup_repo "$origin" "$main" develop || fail "fixture: setup_repo"
  repo=$(basename "$main")
  mkdir -p "$AGENTIC_WORKTREES/$repo" || fail "fixture: repo worktree dir"
  # a clean worktree whose upstream is gone: do_clean would remove it, prepare must not
  donewt=$AGENTIC_WORKTREES/$repo/donetask
  git -C "$main" worktree add -q -b feat/donetask "$donewt" origin/develop || fail "fixture: done worktree"
  git -C "$donewt" commit -q --allow-empty -m done || fail "fixture: commit"
  git -C "$donewt" push -q -u origin feat/donetask || fail "fixture: push"
  git -C "$origin" branch -q -D feat/donetask || fail "fixture: drop upstream"
  git -C "$main" fetch -q --prune origin || fail "fixture: prune fetch"
  [ "$(git -C "$main" for-each-ref --format='%(upstream:track)' refs/heads/feat/donetask)" = "[gone]" ] ||
    fail "fixture: the upstream should be gone"
  mkdir -p "$main/.ship/mytask" && printf notes >"$main/.ship/mytask/notes.md" || fail "fixture: .ship"
  out=$(cd "$main" && ORCA_CLI_COMMAND=orca ORCA_APP_VERSION=9 bash "$TASK" prepare mytask 2>"$c/err"); rc=$?
  assert_eq "$rc" "0" "prepare exits 0 with the Orca environment set"
  dest=$AGENTIC_WORKTREES/$repo/mytask
  assert_eq "$out" "path $dest" "plain prepare output"
  absent "$TEST_ROOT/audit/orca.log"
  absent "$TEST_ROOT/audit/pnpm.log"
  absent "$TEST_ROOT/audit/npm.log"
  absent "$TEST_ROOT/audit/yarn.log"
  absent "$TEST_ROOT/audit/gh.log"
  [ -d "$donewt" ] || fail "prepare removed the completed worktree"
  assert_eq "$(cat "$main/.ship/mytask/notes.md")" "notes" "the run files were not touched"
  absent "$dest/.ship"
}

case_open_regression() {
  local c=$CASES/c6 origin main out rc repo dest wt
  origin=$c/origin main=$c/main-six
  setup_repo "$origin" "$main" main || fail "fixture: setup_repo"
  repo=$(basename "$main")
  mkdir -p "$AGENTIC_WORKTREES/$repo" || fail "fixture: repo worktree dir"
  # an existing named linked worktree on a non-default branch still answers "here"
  wt=$AGENTIC_WORKTREES/$repo/existing
  git -C "$main" worktree add -q -b task-existing "$wt" origin/main || fail "fixture: linked worktree"
  out=$(cd "$wt" && bash "$TASK" open mytask 2>"$c/err"); rc=$?
  assert_eq "$rc" "0" "open in a linked worktree exits 0"
  assert_eq "$out" "here $wt" "open answers here"
  # main-checkout open still creates feat/<slug> with its existing collision behaviour
  git -C "$main" branch -q feat/mytask || fail "fixture: branch collision"
  out=$(cd "$main" && bash "$TASK" open mytask 2>"$c/err2"); rc=$?
  assert_eq "$rc" "0" "open in the main checkout exits 0"
  dest=$AGENTIC_WORKTREES/$repo/mytask-2
  assert_eq "$out" "path $dest" "open's collision suffix"
  git -C "$main" rev-parse -q --verify refs/heads/feat/mytask-2 >/dev/null ||
    fail "open created no feat/mytask-2 branch"
  assert_eq "$(git -C "$dest" symbolic-ref -q --short HEAD)" "feat/mytask-2" \
    "open's worktree is on the branch"
  absent "$TEST_ROOT/audit/orca.log"
}

case_default_changed_after_clone() {
  local c=$CASES/c7 origin main out rc repo dest
  origin=$c/origin main=$c/main-seven
  setup_repo "$origin" "$main" main || fail "fixture: setup_repo"
  git -C "$main" checkout -q -b develop || fail "fixture: develop"
  git -C "$main" commit -q --allow-empty -m d1 || fail "fixture: commit"
  git -C "$main" push -q origin develop || fail "fixture: push"
  git -C "$origin" symbolic-ref HEAD refs/heads/develop || fail "fixture: move origin HEAD"
  git -C "$main" checkout -q main || fail "fixture: back to the old default"
  [ "$(git -C "$main" symbolic-ref -q --short refs/remotes/origin/HEAD)" = "origin/main" ] ||
    fail "fixture: the clone's origin/HEAD should still say main"
  repo=$(basename "$main")
  out=$(cd "$main" && bash "$TASK" prepare mytask 2>"$c/err"); rc=$?
  assert_eq "$rc" "0" "prepare exit"
  dest=$AGENTIC_WORKTREES/$repo/mytask
  assert_eq "$out" "path $dest" "exact output"
  assert_eq "$(git -C "$dest" rev-parse HEAD)" "$(git -C "$origin" rev-parse develop)" \
    "prepare based the worktree on the origin's new default"
  assert_detached "$dest"
  assert_eq "$(git -C "$main" symbolic-ref -q --short HEAD)" "main" "the caller stayed on its branch"
}

case_unwritable_parent_fails() {
  local c=$CASES/c8 origin main rc repo dir p waited out err
  origin=$c/origin main=$c/main-eight
  setup_repo "$origin" "$main" develop || fail "fixture: setup_repo"
  repo=$(basename "$main")
  dir=$AGENTIC_WORKTREES/$repo
  mkdir -p "$dir" || fail "fixture: worktree dir"
  chmod 555 "$dir" || fail "fixture: make the worktree dir unwritable"
  (cd "$main" && bash "$TASK" prepare mytask) >"$c/out" 2>"$c/err" & p=$!
  waited=0
  while kill -0 "$p" 2>/dev/null && [ "$waited" -lt 100 ]; do
    sleep 0.1; waited=$((waited + 1))
  done
  if kill -0 "$p" 2>/dev/null; then
    kill -KILL -- -"$p" 2>/dev/null
    kill -KILL "$p" 2>/dev/null
    wait "$p" 2>/dev/null
    chmod 755 "$dir" 2>/dev/null
    fail "prepare span for over 10 s instead of failing"
  fi
  wait "$p"; rc=$?
  chmod 755 "$dir" || fail "cannot restore the worktree dir mode"
  assert_eq "$rc" "3" "an unwritable parent exits 3"
  assert_eq "$(cat "$c/out")" "" "no success line"
  err=$(cat "$c/err")
  assert_contains "$err" "task.sh: cannot create $dir/mytask" "the error names the path"
  absent "$dir/mytask"
  absent "$dir/mytask-2"
  assert_eq "$(git -C "$main" show-ref --heads | wc -l | tr -d ' ')" "1" "no branch was created"
  assert_eq "$(git -C "$main" worktree list --porcelain | grep -c '^worktree ')" "1" \
    "no worktree was registered"
}

case_worktree_creation_runs_no_hook() {
  local c=$CASES/c9 origin main out rc repo marker
  origin=$c/origin main=$c/main-nine marker=$c/hook-ran
  setup_repo "$origin" "$main" main || fail "fixture: setup_repo"
  mkdir -p "$main/.husky" || fail "fixture: .husky"
  printf '#!/bin/sh\necho ran >> "%s"\n' "$marker" >"$main/.husky/post-checkout" || fail "fixture: hook"
  chmod 755 "$main/.husky/post-checkout"
  git -C "$main" add .husky || fail "fixture: add hook"
  git -C "$main" commit -q -m hook || fail "fixture: commit hook"
  git -C "$main" push -q origin main || fail "fixture: push hook"
  git -C "$main" config core.hooksPath .husky || fail "fixture: hooksPath"
  repo=$(basename "$main")
  out=$(cd "$main" && bash "$TASK" prepare hooked 2>"$c/err"); rc=$?
  assert_eq "$rc" "0" "prepare exit: $(cat "$c/err")"
  assert_eq "$out" "path $AGENTIC_WORKTREES/$repo/hooked" "prepare output"
  [ -f "$AGENTIC_WORKTREES/$repo/hooked/.husky/post-checkout" ] || fail "the worktree was not created"
  absent "$marker"
  out=$(cd "$main" && bash "$TASK" open hookedopen 2>"$c/err2"); rc=$?
  assert_eq "$rc" "0" "open exit: $(cat "$c/err2")"
  [ -f "$AGENTIC_WORKTREES/$repo/hookedopen/.husky/post-checkout" ] || fail "the open worktree was not created"
  absent "$marker"
}

case_detached_origin_default
case_fatal_fetch
case_collision_suffixes
case_missing_default_or_invalid_invocation
case_no_other_workflow
case_open_regression
case_default_changed_after_clone
case_unwritable_parent_fails
case_worktree_creation_runs_no_hook
printf 'prepare.test.sh: all nine cases passed\n'
