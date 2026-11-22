#!/usr/bin/env bash
# task.sh: the workspace of a task, the cleanup of finished ones, and the time limit of an
# unattended run. One task is one branch feat/<slug> in one worktree with one session.
#
#   task.sh open <slug> [--branch <branch>] [--prompt-file <file>]
#       Prints one line:
#         here <path>        the session already works in a task worktree (a linked worktree
#                            on a branch other than the default one): work there
#         handed-off <path>  inside Orca, with --prompt-file: Orca created the workspace and
#                            started a session there with the file's text as its prompt;
#                            this session's part is done
#         path <path>        a new worktree ${AGENTIC_WORKTREES:-~/worktrees}/<repo>/<slug>
#                            on <branch>, from origin/<default branch>: work there
#       <branch> is the branch name as the project names branches, for example
#       feat/PROJ-123_status-label (default: feat/<slug>); the worktree folder is named
#       by the slug. A taken branch or folder gets -2, -3 on both. Orca is used when
#       ORCA_CLI_COMMAND or ORCA_APP_VERSION is set and AGENTIC_NO_ORCA is not; when its
#       call fails, the plain worktree is made.
#   task.sh prepare <slug>
#       Print one line `path <path>`: a new detached worktree
#       ${AGENTIC_WORKTREES:-~/worktrees}/<repo>/<slug> at origin/<default branch>,
#       fetched first: a failed fetch is fatal (exit 3, nothing is created) and
#       origin's default branch is re-resolved from the remote every time. No branch
#       is created; the commander names it later. A taken name gets -2, -3. Only from
#       the main checkout, never a linked worktree.
#   task.sh deps [<dir>] [--force] [--base <commit>]
#       Install the dependencies of the checkout at <dir> (default: here) exactly as its
#       lockfile pins them (pnpm install --frozen-lockfile, npm ci, yarn --frozen-lockfile);
#       never changes package.json or the lockfile. Skipped when node_modules is newer than
#       the lockfile, unless --force. For the commander, in a new task worktree.
#       Only on the untouched task base, also with --force (install scripts and package
#       manager config run from the checkout): HEAD has no commits beyond origin/<default
#       branch>, or equals <commit> with --base; the tree is clean (.ship/ and node_modules/
#       ignored). Otherwise exit 3 and no package manager runs.
#   task.sh dir <slug>
#       Print <this worktree>/.ship/<slug>, created, with .ship/ kept out of git through
#       info/exclude: the run files of a task (notes, the task text, review output). They
#       are never committed. `open` copies them into the workspace it creates.
#   task.sh clean
#       Remove the linked worktrees of this repository whose tree is clean and whose branch
#       is done: its pull request is merged (gh), or its upstream branch is gone. Never the
#       main checkout, never the worktree the command runs in. Prints "removed <path>" each.
#       The run files the task left in the main checkout (.ship/<worktree folder>) go with it.
#   task.sh limit start <dir> [--minutes N]    write <dir>/deadline (default 240 minutes);
#                                              never overwrites one
#   task.sh limit check <dir>                  exit 0 with the minutes left, 5 past the
#                                              deadline, 3 when <dir>/deadline is missing or
#                                              broken: a stop, never a pass
#
# Exit: 0 done, 2 usage, 3 cannot do it, 5 the limit is reached.
# Portable to macOS /bin/bash 3.2 and Linux bash 4/5.
set -euo pipefail
unset CDPATH

die() {
  printf 'task.sh: %s\n' "$2" >&2
  exit "$1"
}
usage() { die 2 "usage: task.sh open <slug> [--branch <branch>] [--prompt-file <file>] | prepare <slug> | dir <slug> | deps [<dir>] [--force] [--base <commit>] | clean | limit start <dir> [--minutes N] | limit check <dir>"; }

# check_slug <slug>: a-z, 0-9 and -, at most 40 characters.
check_slug() {
  [[ $1 =~ ^[a-z0-9][a-z0-9-]{0,39}$ ]] || die 2 "the slug is a-z, 0-9 and -, at most 40 characters: '$1'"
}

# main_root: the main checkout of the repository the command runs in (physical path).
main_root() {
  local common
  common=$(git rev-parse --git-common-dir 2>/dev/null) || return 1
  common=$(cd "$common" && pwd -P) || return 1
  dirname "$common"
}

# default_branch <root>: the branch origin/HEAD points to, else main or master when it exists.
default_branch() {
  local ref b
  if ref=$(git -C "$1" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null); then
    printf '%s\n' "${ref#origin/}"
    return 0
  fi
  for b in main master; do
    if git -C "$1" show-ref -q --verify "refs/heads/$b"; then
      printf '%s\n' "$b"
      return 0
    fi
  done
  return 0
}

# orca_cli: print the Orca command when this session runs inside Orca.
orca_cli() {
  [ -z "${AGENTIC_NO_ORCA:-}" ] || return 1
  [ -n "${ORCA_CLI_COMMAND:-}${ORCA_APP_VERSION:-}" ] || return 1
  command -v "${ORCA_CLI_COMMAND:-orca}" 2>/dev/null
}

do_open() {
  local slug=${1:-} prompt_file="" branch_arg="" root repo def cur top orca out path base name n dest branch
  [ $# -ge 1 ] || usage
  shift
  while [ $# -gt 0 ]; do
    case $1 in
      --prompt-file)
        [ $# -ge 2 ] || die 2 "--prompt-file needs a file"
        prompt_file=$2
        shift
        ;;
      --branch)
        [ $# -ge 2 ] || die 2 "--branch needs a branch name"
        branch_arg=$2
        shift
        ;;
      *) usage ;;
    esac
    shift
  done
  check_slug "$slug"
  branch_arg=${branch_arg:-feat/$slug}
  git check-ref-format --branch "$branch_arg" >/dev/null 2>&1 || die 2 "not a valid branch name: '$branch_arg'"
  [ ${#branch_arg} -le 100 ] || die 2 "the branch name is longer than 100 characters: '$branch_arg'"
  [ -z "$prompt_file" ] || [ -f "$prompt_file" ] || die 2 "file not found: $prompt_file"
  root=$(main_root) || die 3 "not inside a git repository"
  repo=$(basename "$root")
  def=$(default_branch "$root")

  top=$(git rev-parse --show-toplevel)
  top=$(cd "$top" && pwd -P)
  cur=$(git symbolic-ref -q --short HEAD 2>/dev/null || true)
  if [ "$top" != "$root" ] && [ -n "$cur" ] && [ "$cur" != "$def" ]; then
    printf 'here %s\n' "$top"
    return 0
  fi

  keep_out_of_git
  if [ -n "$prompt_file" ] && orca=$(orca_cli) && command -v jq >/dev/null 2>&1; then
    if out=$("$orca" worktree create --repo "path:$root" --name "$slug" --branch "$branch_arg" \
      --no-parent --agent claude --prompt "$(cat "$prompt_file")" --activate --json 2>&1) &&
      path=$(printf '%s' "$out" | jq -er 'select(.ok == true) | .result.worktree.path' 2>/dev/null); then
      copy_run_files "$top" "$slug" "$path"
      printf 'handed-off %s\n' "$path"
      return 0
    fi
    printf 'task.sh: Orca did not create the workspace; making a plain worktree. Its answer: %s\n' \
      "$(printf '%s' "$out" | tail -n 3 | cut -c1-300)" >&2
  fi

  base=HEAD
  if [ -n "$def" ]; then
    # A failed fetch must not go unseen: the task would start from an old state.
    git -C "$root" fetch -q origin "$def" >/dev/null 2>&1 ||
      printf 'task.sh: WARNING: could not fetch origin/%s; the worktree starts from the last fetched state, which may be old. Tell the developer.\n' "$def" >&2
    if git -C "$root" rev-parse -q --verify "refs/remotes/origin/$def^{commit}" >/dev/null 2>&1; then
      base=origin/$def
    elif git -C "$root" show-ref -q --verify "refs/heads/$def"; then
      base=$def
    fi
  fi
  name=$slug branch=$branch_arg n=1
  while git -C "$root" show-ref -q --verify "refs/heads/$branch" ||
    git -C "$root" show-ref -q --verify "refs/remotes/origin/$branch" ||
    [ -e "${AGENTIC_WORKTREES:-$HOME/worktrees}/$repo/$name" ]; do
    n=$((n + 1))
    name=$slug-$n branch=$branch_arg-$n
  done
  dest=${AGENTIC_WORKTREES:-$HOME/worktrees}/$repo/$name
  mkdir -p "$(dirname "$dest")" || die 3 "cannot create $(dirname "$dest")"
  git -C "$root" worktree add -q -b "$branch" "$dest" "$base" >&2 || die 3 "git worktree add failed"
  copy_run_files "$top" "$slug" "$dest"
  printf 'path %s\n' "$(cd "$dest" && pwd -P)"
}

# taken <root> <path>: an existing path of any kind (even a dangling symlink) or a path
# registered as a worktree of <root> is taken; a branch named feat/<slug> alone is not.
taken() {
  [ -e "$2" ] || [ -L "$2" ] && return 0
  git -C "$1" worktree list --porcelain 2>/dev/null | grep -xF "worktree $2" >/dev/null
}

do_prepare() {
  local slug=${1:-} root top def repo wtroot name n dest err
  [ $# -eq 1 ] || usage
  check_slug "$slug"
  root=$(main_root) || die 3 "not inside a git repository"
  top=$(git rev-parse --show-toplevel 2>/dev/null) || die 3 "not inside a git repository"
  top=$(cd "$top" && pwd -P)
  [ "$top" = "$root" ] || die 3 "prepare runs from the main checkout, not a linked worktree: $top"

  # A failed fetch must stop prepare: the task would start from an old state.
  git -C "$root" fetch origin >&2 || die 3 "prepare could not fetch origin"
  git -C "$root" remote set-head origin --auto >&2 || die 3 "prepare could not set origin's HEAD"
  def=$(git -C "$root" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null) ||
    die 3 "prepare could not resolve origin's default branch"
  def=${def#origin/}
  git -C "$root" rev-parse -q --verify "refs/remotes/origin/$def^{commit}" >/dev/null 2>&1 ||
    die 3 "prepare: origin/$def is not a commit"

  wtroot=${AGENTIC_WORKTREES:-$HOME/worktrees}
  mkdir -p "$wtroot" || die 3 "cannot create the worktree root $wtroot"
  wtroot=$(cd "$wtroot" && pwd -P) || die 3 "cannot enter the worktree root $wtroot"
  repo=$(basename "$root")
  mkdir -p "$wtroot/$repo" || die 3 "cannot create $wtroot/$repo"
  name=$slug n=1
  while taken "$root" "$wtroot/$repo/$name"; do
    n=$((n + 1)); name=$slug-$n
  done
  # Claim the destination with mkdir: atomic, so two concurrent prepares of one slug
  # cannot end up in the same path. A destination that exists, or that another
  # prepare won between the check and the claim, is retried with the next suffix;
  # any other mkdir failure (permissions, a read-only root) is fatal.
  until err=$(mkdir "$wtroot/$repo/$name" 2>&1); do
    if taken "$root" "$wtroot/$repo/$name"; then
      n=$((n + 1)); name=$slug-$n
    else
      die 3 "cannot create $wtroot/$repo/$name: ${err#mkdir: }"
    fi
  done
  dest=$wtroot/$repo/$name
  keep_out_of_git
  git -C "$root" worktree add --detach "$dest" "origin/$def" >&2 ||
    { rmdir "$dest" 2>/dev/null; die 3 "git worktree add failed for $dest"; }
  printf 'path %s\n' "$(cd "$dest" && pwd -P)"
}

# keep_out_of_git: the line .ship/ in info/exclude, which every worktree shares.
keep_out_of_git() {
  local ex
  ex="$(cd "$(git rev-parse --git-common-dir)" && pwd -P)/info/exclude"
  grep -qxF '.ship/' "$ex" 2>/dev/null && return 0
  mkdir -p "$(dirname "$ex")" || die 3 "cannot create $(dirname "$ex")"
  printf '.ship/\n' >>"$ex" || die 3 "cannot write $ex"
}

# copy_run_files <from top> <slug> <to top>: the run files follow the task into its workspace.
copy_run_files() {
  [ -d "$1/.ship/$2" ] && [ -d "$3" ] && [ ! -e "$3/.ship/$2" ] || return 0
  mkdir -p "$3/.ship" && cp -R "$1/.ship/$2" "$3/.ship/$2" || true
}

do_dir() {
  local top
  [ $# -eq 1 ] || usage
  check_slug "$1"
  top=$(git rev-parse --show-toplevel 2>/dev/null) || die 3 "not inside a git repository"
  top=$(cd "$top" && pwd -P)
  keep_out_of_git
  mkdir -p "$top/.ship/$1" || die 3 "cannot create $top/.ship/$1"
  printf '%s\n' "$top/.ship/$1"
}

# branch_done <root> <branch>: its pull request is merged, or its upstream branch is gone.
branch_done() {
  local n
  if command -v gh >/dev/null 2>&1; then
    n=$(cd "$1" && gh pr list --head "$2" --state merged --json number --jq 'length' 2>/dev/null) || n=""
    [ "${n:-0}" = 0 ] || return 0
  fi
  [ "$(git -C "$1" for-each-ref --format='%(upstream:track)' "refs/heads/$2")" = "[gone]" ]
}

do_clean() {
  local root def here orca="" path="" branch=""
  [ $# -eq 0 ] || usage
  root=$(main_root) || die 3 "not inside a git repository"
  def=$(default_branch "$root")
  here=$(git rev-parse --show-toplevel)
  here=$(cd "$here" && pwd -P)
  orca=$(orca_cli) || orca=""
  git -C "$root" fetch -q --prune origin >/dev/null 2>&1 || true
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in
      "worktree "*) path=${line#worktree } branch="" ;;
      "branch refs/heads/"*) branch=${line#branch refs/heads/} ;;
      "")
        if [ -n "$path" ] && [ -n "$branch" ]; then remove_done "$root" "$def" "$here" "$orca" "$path" "$branch"; fi
        path="" branch=""
        ;;
    esac
  done < <(git -C "$root" worktree list --porcelain && echo)
}

# remove_done <root> <default> <here> <orca> <path> <branch>: remove one worktree when it is done.
remove_done() {
  local root=$1 def=$2 here=$3 orca=$4 path=$5 branch=$6 phys
  [ -d "$path" ] || return 0
  phys=$(cd "$path" && pwd -P)
  if [ "$phys" = "$root" ] || [ "$phys" = "$here" ] || [ "$branch" = "$def" ]; then return 0; fi
  [ -z "$(git -C "$path" status --porcelain 2>/dev/null)" ] || return 0
  branch_done "$root" "$branch" || return 0
  if [ -z "$orca" ] || ! "$orca" worktree rm --worktree "path:$phys" --json >/dev/null 2>&1; then
    git -C "$root" worktree remove "$path" >/dev/null 2>&1 || return 0
  fi
  # -d refuses a branch that is not merged into its upstream or HEAD: then it stays.
  git -C "$root" branch -q -d "$branch" >/dev/null 2>&1 || true
  # The run files of the task live under the worktree folder's name (the slug).
  case ${phys##*/} in '' | . | ..) ;; *) rm -rf "$root/.ship/${phys##*/}" ;; esac
  printf 'removed %s\n' "$path"
}

# do_deps [<dir>] [--force]: install the dependencies of the checkout at <dir> (default: the
# current one) exactly as its lockfile pins them: pnpm install --frozen-lockfile, npm ci, or
# yarn install --frozen-lockfile. Never changes package.json or the lockfile (a lockfile that
# is out of date fails the install). Skipped when node_modules is newer than the lockfile,
# unless --force. Output goes to <root>/.ship/deps.log; the last lines are printed.
# Install scripts and package-manager config run from the checkout, so the install runs only
# on the untouched task base, also with --force: without --base, HEAD must have no commits
# beyond origin/<default branch>; with --base <commit>, HEAD must equal that commit. The tree
# must be clean (paths under .ship/ and node_modules/ are ignored). Otherwise exit 3, no
# package manager is called.
do_deps() {
  local dir="" force=0 base_arg="" root lock cmd log base line first status
  while [ $# -gt 0 ]; do
    case $1 in
      --force) force=1 ;;
      --base)
        [ $# -ge 2 ] || die 2 "--base needs a commit"
        base_arg=$2
        shift
        ;;
      -*) usage ;;
      *) [ -z "$dir" ] || usage; dir=$1 ;;
    esac
    shift
  done
  root=$(git -C "${dir:-.}" rev-parse --show-toplevel 2>/dev/null) || die 3 "not inside a git checkout: ${dir:-.}"
  if [ -f "$root/pnpm-lock.yaml" ]; then lock=pnpm-lock.yaml cmd="pnpm install --frozen-lockfile"
  elif [ -f "$root/package-lock.json" ]; then lock=package-lock.json cmd="npm ci"
  elif [ -f "$root/yarn.lock" ]; then lock=yarn.lock cmd="yarn install --frozen-lockfile"
  else
    echo "deps: no lockfile in $root, nothing to install"
    return 0
  fi
  if [ "$force" = 0 ] && [ -d "$root/node_modules" ] && [ "$root/node_modules" -nt "$root/$lock" ]; then
    echo "deps: up to date ($root/node_modules is newer than $lock)"
    return 0
  fi
  if [ -n "$base_arg" ]; then
    base=$(git -c core.fsmonitor=false -C "$root" rev-parse --verify "$base_arg^{commit}" 2>/dev/null) ||
      die 3 "deps: unknown base $base_arg"
    [ "$(git -c core.fsmonitor=false -C "$root" rev-parse HEAD 2>/dev/null)" = "$base" ] ||
      die 3 "deps: HEAD has commits beyond $base_arg: install only on the untouched base (see --base)"
  else
    base=origin/$(default_branch "$root")
    git -c core.fsmonitor=false -C "$root" rev-parse -q --verify "refs/remotes/$base^{commit}" >/dev/null 2>&1 ||
      die 3 "deps: no base to compare with; pass --base <commit>"
    git -c core.fsmonitor=false -C "$root" merge-base --is-ancestor HEAD "refs/remotes/$base" 2>/dev/null ||
      die 3 "deps: HEAD has commits beyond $base: install only on the untouched base (see --base)"
  fi
  first=""
  status=$(git -c core.fsmonitor=false -C "$root" status --porcelain --untracked-files=all 2>/dev/null) ||
    die 3 "deps: cannot read the worktree status"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case ${line:3} in .ship/* | node_modules/*) continue ;; esac
    first=${line:3}
    break
  done <<<"$status"
  [ -z "$first" ] || die 3 "deps: the worktree has changes ($first): install only on the untouched base"
  log=$root/.ship/deps.log
  if [ -L "$root/.ship" ] || [ -L "$log" ]; then
    die 3 "deps: $root/.ship or its log is a symlink"
  fi
  (cd "$root" && keep_out_of_git)
  mkdir -p "$root/.ship"
  rm -f "$log"
  echo "deps: $cmd in $root (log: $log)"
  # shellcheck disable=SC2086 # cmd is one of the fixed commands above
  if (cd "$root" && $cmd) >"$log" 2>&1; then
    touch "$root/node_modules" 2>/dev/null || true
    tail -n 3 "$log"
    echo "deps: done"
  else
    tail -n 20 "$log" >&2
    die 1 "deps: $cmd failed (log: $log)"
  fi
}

do_limit() {
  local cmd=${1:-} dir=${2:-} minutes=240 file deadline now
  [ $# -ge 2 ] || usage
  shift 2
  file="$dir/deadline"
  case $cmd in
    start)
      if [ $# -gt 0 ]; then
        [ $# -eq 2 ] && [ "$1" = --minutes ] || usage
        case $2 in '' | *[!0-9]*) die 2 "--minutes needs a whole number" ;; esac
        [ ${#2} -le 6 ] || die 2 "--minutes is too large"
        minutes=$((10#$2))
      fi
      [ "$minutes" -gt 0 ] || die 2 "--minutes must be at least 1"
      [ -d "$dir" ] || die 2 "not a directory: $dir"
      # noclobber: an existing deadline is never moved.
      (set -C && printf '%s\n' "$(($(date +%s) + minutes * 60))" >"$file") 2>/dev/null ||
        die 2 "$file exists already (or the directory is not writable); use limit check"
      printf 'within the limit: %s minutes left\n' "$minutes"
      ;;
    check)
      [ $# -eq 0 ] || usage
      [ -r "$file" ] || die 3 "no deadline in $dir (run task.sh limit start $dir first)"
      deadline=$(head -n 1 "$file")
      case $deadline in '' | *[!0-9]*) die 3 "$file is broken" ;; esac
      [ ${#deadline} -le 12 ] || die 3 "$file is broken"
      deadline=$((10#$deadline))
      now=$(date +%s)
      if [ "$now" -ge "$deadline" ]; then
        printf 'limit reached: the deadline passed %s minutes ago\n' "$(((now - deadline) / 60))"
        exit 5
      fi
      printf 'within the limit: %s minutes left\n' "$(((deadline - now + 59) / 60))"
      ;;
    *) usage ;;
  esac
}

[ $# -ge 1 ] || usage
cmd=$1
shift
case $cmd in
  open) do_open "$@" ;;
  prepare) do_prepare "$@" ;;
  dir) do_dir "$@" ;;
  deps) do_deps "$@" ;;
  clean) do_clean "$@" ;;
  limit) do_limit "$@" ;;
  *) usage ;;
esac
