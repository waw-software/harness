#!/usr/bin/env bash
# deliver.sh: the commander's delivery, without prompts: push a task branch and open its
# merge request (GitLab, glab) or pull request (GitHub, gh). The developer allowed this for
# branches that are not protected; the checks below are what make it safe to skip the prompt.
#
#   deliver.sh check
#       Dry run: print the branch and the protected patterns, and whether a push is allowed.
#   deliver.sh push
#       Push the current branch to origin (with upstream). Refused: a detached HEAD, the
#       default branch, a protected branch (main, master, develop, release/*, hotfix/*, the
#       project's own list in .claude/hooks/protect/git.mjs, and the remote's protected
#       branches from the GitLab/GitHub API), and any force: a push the remote rejects as
#       non-fast-forward fails; never retried with force.
#   deliver.sh push --force-with-lease
#       The one force form: move origin/<branch> to the current HEAD with a lease pinned to
#       the last-fetched origin/<branch> SHA, for a rebased task branch. Only the current,
#       already-tracked, unprotected branch, and no fetch: a stale lease fails with 1 and is
#       never retried with force. Refused with 3: a detached HEAD, no origin upstream (use
#       deliver.sh push first), a tracking mismatch, a missing origin/<branch>, a protected
#       branch. Anything else after push: usage, 2.
#   deliver.sh mr --title <title> --description-file <file> [--draft] [--target <branch>]
#                 [--label <label>]...
#       Push (as above), then open the merge request from the current branch into --target
#       (default: the default branch). An open one for this branch exists already: print its
#       URL and do nothing else. Prints the URL of the new one.
#
# Run it from the task's worktree. Exit: 0 done, 2 usage, 3 refused (protected, detached,
# no remote), 1 git or glab/gh failed (their output is shown). Portable to macOS bash 3.2.
set -euo pipefail

die() {
  printf 'deliver.sh: %s\n' "$2" >&2
  exit "$1"
}
usage() { die 2 "usage: deliver.sh push [--force-with-lease] | deliver.sh mr --title <t> --description-file <f> [--draft] [--target <b>] [--label <l>]..."; }

[ $# -ge 1 ] || usage
cmd=$1
shift

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die 3 "not inside a git checkout"
branch=$(git symbolic-ref --quiet --short HEAD) || die 3 "detached HEAD: check out the task branch"
url=$(git remote get-url origin 2>/dev/null) || die 3 "no remote named origin"

default_branch() {
  local d
  d=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  [ -n "$d" ] || { git remote set-head origin --auto >/dev/null 2>&1 || true
    d=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true); }
  printf '%s' "${d#origin/}"
}

case $url in
  *github.com[:/]*) forge=github ;;
  *) forge=gitlab ;;
esac

# Protected branch patterns: built in, the project's protect hook list, and the remote's.
protected_patterns() {
  printf '%s\n' main master develop 'release/*' 'hotfix/*'
  local d top
  d=$(default_branch)
  [ -z "$d" ] || printf '%s\n' "$d"
  top=$(git rev-parse --show-toplevel)
  if [ -f "$top/.claude/hooks/protect/git.mjs" ]; then
    sed -n "s/.*PROTECTED_BRANCHES *= *\[\(.*\)\].*/\1/p" "$top/.claude/hooks/protect/git.mjs" |
      tr ',' '\n' | tr -d " '\"" | grep . || true
  fi
  if [ "$forge" = gitlab ] && command -v glab >/dev/null 2>&1; then
    glab api "projects/:fullpath/protected_branches?per_page=100" 2>/dev/null | jq -r '.[].name' 2>/dev/null || true
  elif [ "$forge" = github ] && command -v gh >/dev/null 2>&1; then
    gh api "repos/{owner}/{repo}/branches?protected=true&per_page=100" 2>/dev/null | jq -r '.[].name' 2>/dev/null || true
  fi
}

check_branch() {
  local p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    # shellcheck disable=SC2053 # the pattern is a glob on purpose (release/*)
    if [[ $branch == $p ]]; then
      die 3 "$branch is protected ($p): it reaches the remote only through a merge request the developer merges"
    fi
  done < <(protected_patterns | sort -u)
}

do_push() {
  check_branch
  echo "deliver: git push -u origin $branch"
  git push -u origin "$branch" || die 1 "push failed (a rejected non-fast-forward push is never forced: fetch, rebase or merge first, or ask the developer)"
}

do_push_lease() {
  local remote merge expected
  remote=$(git config --get "branch.$branch.remote") ||
    die 3 "$branch has no origin upstream; use deliver.sh push first"
  merge=$(git config --get "branch.$branch.merge") ||
    die 3 "$branch has no origin upstream; use deliver.sh push first"
  [ "$remote" = origin ] || die 3 "$branch tracks $remote, not origin: lease push moves only an origin branch"
  [ "$merge" = "refs/heads/$branch" ] || die 3 "$branch tracks ${merge#refs/heads/}, not its own branch: lease push moves only $branch"
  expected=$(git rev-parse --verify "refs/remotes/origin/$branch^{commit}") ||
    die 3 "$branch has no origin/$branch to lease: use deliver.sh push first"
  check_branch
  echo "deliver: git push --force-with-lease=$branch:$expected origin HEAD:refs/heads/$branch"
  git push "--force-with-lease=$branch:$expected" origin "HEAD:refs/heads/$branch" ||
    die 1 "lease push failed: origin/$branch has commits since the last fetch: fetch, inspect, rebase or merge first; never retried with force"
}

case $cmd in
  check)
    [ $# -eq 0 ] || usage
    echo "branch: $branch  forge: $forge  default: $(default_branch)"
    echo "protected: $(protected_patterns | sort -u | tr '\n' ' ')"
    check_branch
    echo "deliver: $branch may be pushed"
    ;;
  push)
    if [ $# -ge 1 ] && [ "$1" = "--force-with-lease" ]; then
      [ $# -eq 1 ] || usage
      do_push_lease
    elif [ $# -eq 0 ]; then
      do_push
    else
      usage
    fi
    ;;
  mr)
    title="" desc="" draft=0 target="" labels=()
    while [ $# -gt 0 ]; do
      case $1 in
        --title) [ $# -ge 2 ] || usage; title=$2; shift ;;
        --description-file) [ $# -ge 2 ] || usage; desc=$2; shift ;;
        --draft) draft=1 ;;
        --target) [ $# -ge 2 ] || usage; target=$2; shift ;;
        --label) [ $# -ge 2 ] || usage; labels+=("$2"); shift ;;
        *) usage ;;
      esac
      shift
    done
    [ -n "$title" ] && [ -n "$desc" ] && [ -r "$desc" ] || usage
    target=${target:-$(default_branch)}
    [ -n "$target" ] || die 3 "cannot tell the default branch: give --target"
    [ "$target" != "$branch" ] || die 3 "the target branch is the current branch"
    do_push
    if [ "$forge" = gitlab ]; then
      command -v glab >/dev/null 2>&1 || die 3 "glab not found"
      existing=$(glab mr list --source-branch "$branch" -F json 2>/dev/null | jq -r '.[0].web_url // empty' 2>/dev/null || true)
      if [ -n "$existing" ]; then echo "deliver: an open merge request exists already: $existing"; exit 0; fi
      a=(mr create --source-branch "$branch" --target-branch "$target" --title "$title"
        --description "$(cat "$desc")" --yes)
      [ "$draft" = 0 ] || a+=(--draft)
      for l in ${labels[@]+"${labels[@]}"}; do a+=(--label "$l"); done
      glab "${a[@]}" || die 1 "glab mr create failed"
    else
      command -v gh >/dev/null 2>&1 || die 3 "gh not found"
      existing=$(gh pr list --head "$branch" --state open --json url -q '.[0].url' 2>/dev/null || true)
      if [ -n "$existing" ]; then echo "deliver: an open pull request exists already: $existing"; exit 0; fi
      a=(pr create --head "$branch" --base "$target" --title "$title" --body-file "$desc")
      [ "$draft" = 0 ] || a+=(--draft)
      for l in ${labels[@]+"${labels[@]}"}; do a+=(--label "$l"); done
      gh "${a[@]}" || die 1 "gh pr create failed"
    fi
    ;;
  *) usage ;;
esac
