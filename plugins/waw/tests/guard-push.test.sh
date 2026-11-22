#!/usr/bin/env bash
# tests/guard-push.test.sh — H4: the unchanged guard-push hook allows the wrapper's lease
# push (command text, never executed) and still blocks direct forced pushes, merges and
# default-branch pushes. Sourced by tests/run.sh. Feeds hook JSON to
# $SETUP_UNDER_TEST/hooks/guard-push.sh; the hook file is not modified.
set -u

HOOK=$SETUP_UNDER_TEST/hooks/guard-push.sh
G=$TEST_ROOT/guard
mkdir -p "$G"
git config --global init.defaultBranch main

# a repo with an origin whose default is main and a task branch checked out
git init --bare -q "$G/origin.git"
git init -q "$G/clone"
git -C "$G/clone" commit -q --allow-empty -m init
git -C "$G/clone" push -q -u origin main
git -C "$G/clone" remote set-head origin --auto
git -C "$G/clone" checkout -q -b feat/task

run_hook() { # run_hook <command-text> [cwd]: feed the hook its JSON, set hrc/hook_err
  jq -n --arg c "$1" --arg d "${2:-$G/clone}" \
    '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d}' >"$G/in.json"
  "$HOOK" <"$G/in.json" >/dev/null 2>"$G/hookerr"; hrc=$?
  hook_err=$(cat "$G/hookerr")
}

case_wrapper_lease_allowed() {
  run_hook '~/.claude/waw/deliver.sh push --force-with-lease'
  assert_eq "$hrc" 0 "the wrapper's lease push is allowed as text"
}

case_direct_force_blocked() {
  run_hook 'git push --force-with-lease origin HEAD'
  assert_eq "$hrc" 2 "direct --force-with-lease blocked"
  run_hook 'git push --force'
  assert_eq "$hrc" 2 "--force blocked"
  run_hook 'git push -f'
  assert_eq "$hrc" 2 "-f blocked"
  run_hook 'git push origin +HEAD'
  assert_eq "$hrc" 2 "+ref blocked"
}

case_merges_and_default_branch_blocked() {
  run_hook 'glab mr merge 1'
  assert_eq "$hrc" 2 "glab mr merge blocked"
  run_hook 'gh pr merge 1'
  assert_eq "$hrc" 2 "gh pr merge blocked"
  run_hook 'git push origin main'
  assert_eq "$hrc" 2 "push to the default branch blocked"
}

case_ordinary_push_allowed() {
  run_hook 'git push origin feat/task'
  assert_eq "$hrc" 0 "task-branch push allowed"
  run_hook 'git push'
  assert_eq "$hrc" 0 "bare push on the task branch allowed"
}

case_wrapper_lease_allowed
case_direct_force_blocked
case_merges_and_default_branch_blocked
case_ordinary_push_allowed
printf 'guard-push.test.sh: all four cases passed\n'
