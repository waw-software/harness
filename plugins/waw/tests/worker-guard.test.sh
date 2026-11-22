#!/usr/bin/env bash
# tests/worker-guard.test.sh — worker-guard.sh resolves file-tool targets physically (symlinks,
# `..`, `~`, empty path) and does not block a protected script name that only appears inside a
# quoted argument or a comment. Sourced by tests/run.sh.
set -u

HOOK=$SETUP_UNDER_TEST/hooks/worker-guard.sh
W=$TEST_ROOT/wg
SCOPE=$W/scope
OUT=$W/outside
RUN=$W/run
mkdir -p "$SCOPE/sub" "$SCOPE/.ship" "$OUT" "$RUN"
: >"$SCOPE/sub/existing"
: >"$OUT/f"
ln -s "$SCOPE/sub/existing" "$SCOPE/link_in"
ln -s "$OUT" "$SCOPE/h"
ln -s "$OUT/f" "$SCOPE/f"
ln -s "$OUT/missing" "$SCOPE/dangling"
ln -s "$OUT" "$SCOPE/.ship/l"
ln -s "$OUT" "$RUN/l"

run_tool() { # run_tool <role> <tool> <path-or-empty>: sets hrc
  local role=$1 tool=$2 p=$3 key=file_path
  [ "$tool" = NotebookEdit ] && key=notebook_path
  if [ -n "$p" ]; then
    jq -n --arg t "$tool" --arg k "$key" --arg p "$p" '{tool_name: $t, tool_input: {($k): $p}}' >"$W/in.json"
  else
    jq -n --arg t "$tool" '{tool_name: $t, tool_input: {}}' >"$W/in.json"
  fi
  hrc=0
  (cd "${T_SCOPE:-$SCOPE}" && AGENT_ROLE=$role AGENT_SCOPE=${T_SCOPE:-$SCOPE} AGENT_RUN_DIR=${T_RUN:-$RUN} AGENT_GRANTS=${T_GRANTS:-} bash "$HOOK" <"$W/in.json" >/dev/null 2>"$W/err") || hrc=$?
}
run_bash() { # run_bash <command>: sets hrc
  jq -n --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}' >"$W/in.json"
  hrc=0
  (cd "$SCOPE" && AGENT_ROLE=developer AGENT_SCOPE=$SCOPE AGENT_RUN_DIR=$RUN bash "$HOOK" <"$W/in.json" >/dev/null 2>"$W/err") || hrc=$?
}
dev() { run_tool developer "$1" "$2"; assert_eq "$hrc" "$3" "developer $1 $2"; }

case_new_file_inside() {
  dev Write "$SCOPE/sub/newdir/deeper/x" 0
  dev Edit "$SCOPE/sub/newdir/x" 0
  dev MultiEdit "$SCOPE/new.txt" 0
  dev NotebookEdit "$SCOPE/sub/n.ipynb" 0
}
case_existing_file_inside() { dev Write "$SCOPE/sub/existing" 0; }
case_symlink_inside_to_inside() { dev Write "$SCOPE/link_in" 0; }
case_symlinked_parent_out() {
  dev Write "$SCOPE/h/x" 2
  dev Edit "$SCOPE/h/new/dir/x" 2
}
case_leaf_symlink_out() { dev Write "$SCOPE/f" 2; }
case_dangling_leaf_symlink() { dev Write "$SCOPE/dangling" 2; }
case_dotdot_component() {
  dev Write "$SCOPE/sub/../b" 2
  dev Write "$SCOPE/sub/.." 2
}
case_tilde() {
  dev Write '~/x' 2
  dev Write '~' 2
}
case_relative_path() {
  dev Write "sub/x" 0
  dev Write "../x" 2
}
case_empty_path_refused() {
  dev Write "" 2
  dev NotebookEdit "" 2
}
case_investigator_ship_only() {
  run_tool investigator Write "$SCOPE/.ship/n.md"; assert_eq "$hrc" 0 "ship file"
  run_tool investigator Write "$SCOPE/src/a"; assert_eq "$hrc" 2 "outside .ship"
  run_tool investigator Write "$SCOPE/.ship/l/x"; assert_eq "$hrc" 2 ".ship symlink out"
}
case_run_dir_scope() {
  run_tool investigator Write "$RUN/n.md"; assert_eq "$hrc" 0 "run dir file"
  run_tool tester Write "$RUN/l/x"; assert_eq "$hrc" 2 "run dir symlink out"
}
case_quoted_search_argument() {
  run_bash "rg -n 'a|task.sh deps' plugins"; assert_eq "$hrc" 0 "single-quoted pipe"
  run_bash 'grep "x; agent.sh" f'; assert_eq "$hrc" 0 "double-quoted semicolon"
  run_bash 'echo foo # deliver.sh push'; assert_eq "$hrc" 0 "comment"
}
case_direct_and_chained_commands() {
  run_bash 'task.sh open x'; assert_eq "$hrc" 2 "direct"
  run_bash 'ls && agent.sh run'; assert_eq "$hrc" 2 "after &&"
  run_bash 'echo $(deliver.sh push)'; assert_eq "$hrc" 2 "command substitution"
  run_bash 'cat f | attack.sh'; assert_eq "$hrc" 2 "pipe"
  run_bash '"task.sh" open'; assert_eq "$hrc" 2 "quoted command word"
}
case_hidden_commands() {
  run_bash 'echo "$(deliver.sh push)"'; assert_eq "$hrc" 2 "substitution in double quotes"
  run_bash 'echo "`task.sh open x`"'; assert_eq "$hrc" 2 "backtick in double quotes"
  run_bash 'echo ${#x}; deliver.sh push'; assert_eq "$hrc" 2 "# inside \${#x} is not a comment"
  run_bash 'echo $#; agent.sh run'; assert_eq "$hrc" 2 "\$# is not a comment"
  run_bash "rg -n 'a|task.sh deps' plugins"; assert_eq "$hrc" 0 "quoted search argument"
  run_bash 'echo "a#b"'; assert_eq "$hrc" 0 "# inside quotes"
  run_bash 'echo foo # deliver.sh push'; assert_eq "$hrc" 0 "real comment"
}
case_hidden_in_substitution() {
  run_bash 'echo "$(ls; deliver.sh push)"'; assert_eq "$hrc" 2 "; inside quoted substitution"
  run_bash 'echo "$(ls && task.sh open x)"'; assert_eq "$hrc" 2 "&& inside quoted substitution"
  run_bash 'echo "`ls; agent.sh run`"'; assert_eq "$hrc" 2 "; inside quoted backticks"
  run_bash 'echo "a $(echo "b; c") d"; deliver.sh push'; assert_eq "$hrc" 2 "nested quotes then a real call"
  run_bash 'echo "$(ls)" "x; deliver.sh"'; assert_eq "$hrc" 0 "second argument is quoted text"
}
case_splitter_evasions() {
  run_bash $'ls; \\\ndeliver.sh push'; assert_eq "$hrc" 2 "line continuation"
  run_bash 'X="a b" deliver.sh push'; assert_eq "$hrc" 2 "quoted assignment with a space"
  run_bash "X='a;b' task.sh open x"; assert_eq "$hrc" 2 "quoted assignment with a semicolon"
  run_bash 'X="deliver.sh push" echo hi'; assert_eq "$hrc" 0 "assignment value is text"
  run_bash 'echo a\ #; deliver.sh push'; assert_eq "$hrc" 2 "# after an escaped space"
}
case_settings_case_insensitive() {
  dev Write "$SCOPE/.claude/Settings.json" 2
  dev Write "$SCOPE/.CLAUDE/hooks/x" 2
  dev Write "$SCOPE/.MCP.json" 2
  T_GRANTS=.claude/settings.json dev Write "$SCOPE/.claude/SETTINGS.json" 0
}
case_python39_compatible() {
  if [ ! -x /usr/bin/python3 ]; then
    printf 'case_python39_compatible: skipped, /usr/bin/python3 is missing\n'
    return 0
  fi
  mkdir -p "$W/shim"
  printf '#!/bin/sh\nexec /usr/bin/python3 "$@"\n' >"$W/shim/python3"
  chmod +x "$W/shim/python3"
  PATH=$W/shim:$PATH dev Write "$SCOPE/sub/newdir/x" 0
  PATH=$W/shim:$PATH dev Write "$SCOPE/h/x" 2
}
case_ship_symlink_out() {
  mkdir -p "$W/scope2"
  ln -s "$OUT" "$W/scope2/.ship"
  T_SCOPE=$W/scope2 run_tool investigator Write "$W/scope2/.ship/x"
  assert_eq "$hrc" 2 ".ship redirected outside"
}
case_run_dir_redirected() {
  mkdir -p "$W/real_run"
  ln -s "$W/real_run" "$W/run_link"
  T_RUN=$W/run_link run_tool investigator Write "$W/run_link/x"
  assert_eq "$hrc" 2 "run dir is a symlink"
}
case_project_settings_blocked() {
  dev Write "$SCOPE/.claude/settings.json" 2
  dev Write "$SCOPE/.claude/settings.local.json" 2
  dev Edit "$SCOPE/.claude/hooks/x.sh" 2
  dev Write "$SCOPE/.mcp.json" 2
  run_tool investigator Write "$SCOPE/.claude/settings.json"; assert_eq "$hrc" 2 "investigator"
  T_GRANTS=.claude/settings.json dev Write "$SCOPE/.claude/settings.json" 0
  T_GRANTS=.claude/settings.json dev Write "$SCOPE/.mcp.json" 2
}
case_existing_git_rules_kept() {
  run_bash 'git push'; assert_eq "$hrc" 2 "git push"
}

case_new_file_inside
case_existing_file_inside
case_symlink_inside_to_inside
case_symlinked_parent_out
case_leaf_symlink_out
case_dangling_leaf_symlink
case_dotdot_component
case_tilde
case_relative_path
case_empty_path_refused
case_investigator_ship_only
case_run_dir_scope
case_quoted_search_argument
case_direct_and_chained_commands
case_hidden_commands
case_hidden_in_substitution
case_splitter_evasions
case_settings_case_insensitive
case_python39_compatible
case_ship_symlink_out
case_run_dir_redirected
case_project_settings_blocked
case_existing_git_rules_kept
printf 'worker-guard.test.sh: all cases passed\n'
