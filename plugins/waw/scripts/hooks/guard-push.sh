#!/usr/bin/env bash
# guard-push.sh: Claude Code PreToolUse hook (matcher Bash). In every repository it blocks
# the three things that stay with the developer:
#   gh pr merge, glab mr merge  the developer merges
#   a forced push               --force, -f, --force-with-lease, --force-if-includes, +refspec,
#                               --mirror
#   a push to the default branch: a refspec names it (main, HEAD:main, --delete main), none is
#                               named and the default branch is checked out, or --all sends
#                               every branch
# Everything else is allowed: pushing a task branch, opening a pull request.
#
# Input: the hook JSON on stdin (tool_name, tool_input.command, cwd). Exit 0 allows, exit 2
# blocks with one reason line on stderr. Anything unexpected (no jq, unreadable JSON, not a
# git repository) allows the command, so a broken install never blocks every Bash call.
#
# This is a pattern match on the command text, not a shell parser. It finds each push or
# merge at the start of a command: after ; & | ( { ` or a newline, behind assignments and
# wrappers such as env, command, sudo or timeout. A quoted word keeps its text ("HEAD:main"
# is HEAD:main); any other quoted text is dropped first, so a commit message that mentions
# `git push --force` is allowed, and so are `bash -c "git push -f"` and `eval`: the guard
# stops accidents, not evasion. The default branch is the one
# origin/HEAD names, and always main and master.
# Portable to macOS /bin/bash 3.2 and Linux bash 4/5.
set -u

input=$(cat)

# Fast path: most Bash calls mention neither.
case $input in
  *push* | *gh*pr* | *glab*mr*) ;;
  *) exit 0 ;;
esac
command -v jq >/dev/null 2>&1 || exit 0

cmd=$(printf '%s' "$input" |
  jq -r 'if .tool_name == "Bash" then (.tool_input.command? // "") else "" end' 2>/dev/null) || exit 0
[ -n "$cmd" ] || exit 0
cwd=$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null) || cwd=""

block() {
  printf 'waw: blocked %s. %s\n' "$1" "$2" >&2
  exit 2
}

# One line; then drop backslash escapes, unquote a quoted word, and drop the other
# single-quoted text and the double-quoted text that runs nothing (no $ or backtick inside).
flat=${cmd//$'\n'/;}
word='[A-Za-z0-9_.:/+@=~^-]*'
# shellcheck disable=SC2016 # the sed scripts are literal
flat=$(printf '%s' "$flat" | LC_ALL=C sed -e 's/\\.//g' -e "s/'\\($word\\)'/\\1/g" -e 's/"\('"$word"'\)"/\1/g' \
  -e "s/'[^']*'//g" -e 's/"[^"$`]*"//g') || exit 0

start='(^|[;&|(){}`])[[:space:]]*'
prefix='(([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*|command|builtin|exec|env|sudo|time|nohup|nice|timeout|gtimeout|caffeinate|xargs|if|then|else|do|while|until|!|-[^[:space:]]*|[0-9]+[a-z]?)[[:space:]]+)*'
path='([^[:space:];&|()]*/)?'
args='([[:space:]][^;&|(){}`]*)?'
gh_re="${start}${prefix}${path}"'gh([[:space:]]+((-R|--repo)[[:space:]]+[^[:space:]]+|-[^[:space:]]+))*[[:space:]]+pr[[:space:]]+merge([[:space:];&|)}`]|$)'
git_re="${start}${prefix}${path}"'git([[:space:]]+(-[Cc][[:space:]]+[^[:space:]]+|-[^[:space:]]+))*[[:space:]]+push'"$args"

glab_re="${start}${prefix}${path}"'glab([[:space:]]+((-R|--repo)[[:space:]]+[^[:space:]]+|-[^[:space:]]+))*[[:space:]]+mr[[:space:]]+(merge|accept)([[:space:];&|)}`]|$)'
if [[ $flat =~ $glab_re ]]; then
  block "glab mr merge" "The developer merges: report that the merge request is ready."
fi
if [[ $flat =~ $gh_re ]]; then
  block "gh pr merge" "The developer merges: report that the pull request is ready."
fi

# is_default <dir> <branch>: the branch is a default one in the repository of <dir>.
is_default() {
  local def
  case $2 in main | master) return 0 ;; esac
  def=$(git -C "$1" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null) || return 1
  [ "$2" = "${def#origin/}" ]
}

# check_push <matched text>: one `git ... push ...` command.
check_push() {
  local m=$1 dir=${cwd:-$PWD} head rest="" word n=0 dst cur
  # The arguments are what follows the push word itself, not a later "push" in a name.
  if [[ $m =~ git([[:space:]]+(-[Cc][[:space:]]+[^[:space:]]+|-[^[:space:]]+))*[[:space:]]+push([[:space:]].*)?$ ]]; then
    rest=${BASH_REMATCH[3]:-}
  fi
  head=${m%"push$rest"}
  if [[ $head =~ [[:space:]]-C[[:space:]]+([^[:space:]]+) ]]; then
    case ${BASH_REMATCH[1]} in
      /*) dir=${BASH_REMATCH[1]} ;;
      *) dir="$dir/${BASH_REMATCH[1]}" ;;
    esac
  fi
  cur=$(git -C "$dir" symbolic-ref -q --short HEAD 2>/dev/null) || cur=""
  for word in $rest; do
    case $word in
      --force | --force-with-lease* | --force-if-includes | --mirror | -f | -[a-zA-Z]*f*)
        block "a forced push" "History is never rewritten after a push: add a new commit."
        ;;
      --all | --branches)
        block "a push of every branch" "It includes the default branch: push the task branch by name."
        ;;
      -*) continue ;;
    esac
    n=$((n + 1))
    [ "$n" -gt 1 ] || continue # the first word is the remote
    case $word in +*) block "a forced push" "History is never rewritten after a push: add a new commit." ;; esac
    dst=${word##*:}
    dst=${dst#refs/heads/}
    [ "$dst" != HEAD ] || dst=$cur
    if [ -n "$dst" ] && is_default "$dir" "$dst"; then
      block "a push to the default branch ($dst)" "Changes reach it through a pull request that the developer merges: push a task branch."
    fi
  done
  if [ "$n" -le 1 ] && [ -n "$cur" ] && is_default "$dir" "$cur"; then
    block "a push to the default branch ($cur)" "Changes reach it through a pull request that the developer merges: push a task branch."
  fi
}

rest=$flat
while [[ $rest =~ $git_re ]]; do
  m=${BASH_REMATCH[0]}
  check_push "$m"
  rest=${rest#*"$m"}
done
exit 0
