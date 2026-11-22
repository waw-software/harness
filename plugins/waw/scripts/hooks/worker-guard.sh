#!/usr/bin/env bash
# worker-guard.sh: PreToolUse hook (matchers Bash and Edit|Write|NotebookEdit) for workers.
# agent.sh passes it to every worker it starts (--settings), together with the push guard;
# it is not in any settings.json. Does nothing unless AGENT_ROLE is set.
#
# Blocks, for a worker:
#   git that changes history, the index or the branch: commit, push, pull, fetch, merge,
#     rebase, stash, reset, checkout, switch, restore, clean, cherry-pick, revert, am, tag,
#     branch -d/-D/-m, worktree, gc (the commander owns git; the worktree is shared)
#   pull/merge requests and API writes: gh pr|issue|release|repo|api, glab mr|issue|release|repo|api
#     (read-only `view`, `list`, `diff`, `status`, `checks` are allowed)
#   package installs and removals (pnpm/npm/yarn/npx install-like commands, brew, pip),
#     unless AGENT_ALLOW_INSTALL=1
#   rm on a path outside AGENT_SCOPE (an absolute path elsewhere, ~, ..)
#   Edit/Write outside AGENT_SCOPE; investigator and tester may write only under
#     AGENT_SCOPE/.ship/ or AGENT_RUN_DIR
#
# Input: the hook JSON on stdin. Exit 0 allows, exit 2 blocks with the reason on stderr.
# A pattern match on the command text, not a shell parser: it stops accidents, not evasion.
# Anything unexpected (no jq, unreadable input) allows. Portable to macOS /bin/bash 3.2.
set -u
set -f # words are split, never globbed

[ -n "${AGENT_ROLE:-}" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
input=$(cat)
tool=$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null) || exit 0
scope=${AGENT_SCOPE:-}

block() {
  printf 'worker-guard (%s): blocked %s. %s\n' "$AGENT_ROLE" "$1" "$2" >&2
  exit 2
}

# inside <path> <dir>: the path is the dir or under it (lexically, after resolving ./..).
norm() {
  local p=$1 out="" part
  case $p in /*) ;; *) p=$PWD/$p ;; esac
  local IFS=/
  # shellcheck disable=SC2086
  set -- $p
  for part in "$@"; do
    case $part in
      '' | .) ;;
      ..) out=${out%/*} ;;
      *) out=$out/$part ;;
    esac
  done
  printf '%s' "${out:-/}"
}
inside() {
  local p d
  p=$(norm "$1")
  d=$(norm "$2")
  [ "$p" = "$d" ] || case $p in "$d"/*) return 0 ;; *) return 1 ;; esac
}

# ------------------------------------------------------------------ file tools

case $tool in
  Edit | Write | NotebookEdit | MultiEdit)
    file=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // ""' 2>/dev/null)
    [ -n "$file" ] || exit 0
    [ -n "$scope" ] || exit 0
    case $AGENT_ROLE in
      investigator | tester | reviewer)
        if inside "$file" "$scope/.ship" || { [ -n "${AGENT_RUN_DIR:-}" ] && inside "$file" "$AGENT_RUN_DIR"; }; then
          exit 0
        fi
        block "a write to $file" "A $AGENT_ROLE writes only run files under $scope/.ship/ (notes, drafts, evidence)."
        ;;
      *)
        inside "$file" "$scope" && exit 0
        block "a write to $file" "Write only inside the task's working directory $scope, and only the files your brief gives you."
        ;;
    esac
    ;;
  Bash) ;;
  *) exit 0 ;;
esac

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null) || exit 0
[ -n "$cmd" ] || exit 0

# ------------------------------------------------------------------ commands

# One command per line: split on ; & | ( ) { } ` and newlines. Quoted text stays inside its
# segment, so `echo "git push"` is a segment that starts with echo.
segments=$(printf '%s\n' "$cmd" | tr ';&|(){}`' '\n\n\n\n\n\n\n\n')

check_segment() {
  local s=$1 w1 w2 w3 first n
  # Leading assignments (FOO=bar) and wrappers (env, sudo, timeout 60, ...).
  while :; do
    s=${s#"${s%%[![:space:]]*}"}
    first=${s%%[[:space:]]*}
    case $first in
      '') break ;;
      [A-Za-z_]*=*) s=${s#"$first"} ;;
      env | command | sudo | nice | nohup | exec | time) s=${s#"$first"} ;;
      timeout | gtimeout)
        s=${s#"$first"}; s=${s#"${s%%[![:space:]]*}"}
        n=${s%%[[:space:]]*}; s=${s#"$n"}
        ;;
      *) break ;;
    esac
  done
  # shellcheck disable=SC2086
  set -- $s
  w1=${1:-} w2=${2:-} w3=${3:-}
  w1=${w1##*/}
  [ -n "$w1" ] || return 0

  case $w1 in
    deliver.sh | task.sh | agent.sh | attack.sh)
      block "$w1" "That script is the commander's (delivery, worktrees, workers, reviews)."
      ;;
    git)
      # skip global options such as -C <dir>, -c k=v, --no-pager
      shift
      while [ $# -gt 0 ]; do
        case $1 in
          -C | -c) shift 2 ;;
          -*) shift ;;
          *) break ;;
        esac
      done
      w2=${1:-} w3=${2:-}
      case $w2 in
        commit | push | pull | fetch | merge | rebase | stash | reset | checkout | switch | restore | \
          clean | cherry-pick | revert | am | tag | worktree | gc | filter-branch | update-ref | rm | mv)
          block "git $w2" "Git belongs to the commander: report what you changed, it commits. To undo your own edit, edit the file back."
          ;;
        branch)
          case " $* " in *" -d "* | *" -D "* | *" -m "* | *" -M "* | *" --delete "* | *" --move "*)
            block "git branch $w3" "Git belongs to the commander." ;;
          esac
          ;;
      esac
      ;;
    gh | glab)
      case $w2 in
        pr | mr | issue | release | repo)
          case $w3 in
            view | list | diff | status | checks | "") ;;
            *) block "$w1 $w2 $w3" "Pull/merge requests, issues and releases are the commander's." ;;
          esac
          ;;
        api)
          case " $s " in
            *" -X "* | *" --method "* | *" -f "* | *" -F "* | *" --field "* | *" --raw-field "* | *" --input "*)
              block "$w1 api with a write" "API writes are the commander's." ;;
          esac
          ;;
      esac
      ;;
    pnpm | npm | yarn | bun)
      if [ "${AGENT_ALLOW_INSTALL:-}" != 1 ]; then
        case $w2 in
          install | i | add | remove | rm | uninstall | un | update | up | upgrade | ci | link | unlink | dedupe | prune)
            block "$w1 $w2" "Dependencies are not yours to change in this run: report the need under out_of_scope_needs."
            ;;
        esac
      fi
      ;;
    brew | pip | pip3 | gem | cargo)
      case $w2 in
        install | uninstall | remove | upgrade | update) block "$w1 $w2" "No global installs: report what is missing." ;;
      esac
      ;;
    rm)
      shift
      local a
      for a in "$@"; do
        case $a in
          -*) ;;
          '~'* | *..*) block "rm $a" "Delete only inside the task's working directory, by an explicit relative path." ;;
          /*) [ -n "$scope" ] && inside "$a" "$scope" || block "rm $a" "Delete only inside $scope." ;;
        esac
      done
      ;;
  esac
  return 0
}

while IFS= read -r seg; do
  check_segment "$seg"
done <<EOF
$segments
EOF
exit 0
