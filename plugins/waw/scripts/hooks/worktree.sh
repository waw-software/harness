#!/usr/bin/env bash
# worktree.sh: Claude Code WorktreeCreate / WorktreeRemove hook. New worktrees go to
# ${AGENTIC_WORKTREES:-~/worktrees}/<repo>/<name> instead of <repo>/.claude/worktrees/<name>.
#
# Usage: worktree.sh create|remove (the mode may also come from hook_event_name).
# Input: the hook JSON on stdin. create: {cwd, name}; remove: {worktree_path}.
# create prints the absolute worktree path as the LAST line of stdout; git output and
# messages go to stderr. A non-zero exit is a failure. Existing worktrees are never moved.
# Portable to macOS /bin/bash 3.2 and Linux bash 4/5.
set -euo pipefail

PROG=worktree.sh

die() {
  printf '%s: %s\n' "$PROG" "$*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || die "jq not found"
command -v git >/dev/null 2>&1 || die "git not found"

input=$(cat)
printf '%s' "$input" | jq -e 'type == "object"' >/dev/null 2>&1 || die "hook input is not a JSON object"

# field <key>: a top-level string field of the hook input, empty when missing.
field() {
  printf '%s' "$input" | jq -r --arg k "$1" '(.[$k] // "") | tostring' 2>/dev/null
}

mode=${1:-}
if [ -z "$mode" ]; then
  case $(field hook_event_name) in
    WorktreeCreate) mode=create ;;
    WorktreeRemove) mode=remove ;;
  esac
fi

# main_root <dir>: the main repository's top level (physical path), also from inside a
# linked worktree.
main_root() {
  local common
  common=$(git -C "$1" rev-parse --git-common-dir 2>/dev/null) || return 1
  [ -n "$common" ] || return 1
  common=$(cd "$1" && cd "$common" && pwd -P) || return 1
  (cd "$common/.." && pwd -P)
}

# default_branch <root>: the branch origin/HEAD points to, or nothing.
default_branch() {
  local ref
  ref=$(git -C "$1" symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null) || return 0
  printf '%s\n' "${ref#refs/remotes/origin/}"
}

# base_ref_setting <root>: the worktree.baseRef value of the first settings file that has one.
base_ref_setting() {
  local f v
  for f in "$1/.claude/settings.local.json" "$1/.claude/settings.json" \
    "${CLAUDE_HOME:-$HOME/.claude}/settings.json"; do
    [ -f "$f" ] || continue
    v=$(jq -r '.worktree.baseRef // empty' "$f" 2>/dev/null) || continue
    if [ -n "$v" ]; then
      printf '%s\n' "$v"
      return 0
    fi
  done
  return 0
}

do_create() {
  local cwd name root repo def base parent dest branch
  cwd=$(field cwd)
  name=$(field name)
  [ -n "$cwd" ] || cwd=$PWD
  case $name in
    '') die "empty worktree name" ;;
    *..* | /*) die "bad worktree name: $name" ;;
    *[[:cntrl:]]*) die "bad worktree name (control characters)" ;;
  esac
  root=$(main_root "$cwd") || die "$cwd is not inside a git repository"
  repo=$(basename "$root")

  dest=${AGENTIC_WORKTREES:-$HOME/worktrees}/$repo/$name
  mkdir -p "$(dirname "$dest")" || die "cannot create $(dirname "$dest")"
  parent=$(cd "$(dirname "$dest")" && pwd -P)
  dest=$parent/$(basename "$dest")
  branch=worktree-$name

  # Resume: already a registered worktree of this repo.
  if git -C "$root" worktree list --porcelain 2>/dev/null | grep -Fxq "worktree $dest"; then
    printf '%s\n' "$dest"
    return 0
  fi
  [ ! -e "$dest" ] || die "$dest exists and is not a worktree of $root"

  def=$(default_branch "$root")
  base=HEAD
  if [ -n "$def" ] && [ "$(base_ref_setting "$root")" != head ]; then
    git -C "$root" fetch -q origin "$def" >&2 2>&1 || true
    if git -C "$root" rev-parse -q --verify "refs/remotes/origin/$def^{commit}" >/dev/null 2>&1; then
      base=origin/$def
    fi
  fi

  if git -C "$root" show-ref -q --verify "refs/heads/$branch"; then
    git -C "$root" worktree add "$dest" "$branch" >&2 2>&1 || die "git worktree add failed"
  else
    git -C "$root" worktree add -b "$branch" "$dest" "$base" >&2 2>&1 || die "git worktree add failed"
  fi
  printf '%s\n' "$dest"
}

do_remove() {
  local path root br def cur
  path=$(field worktree_path)
  [ -n "$path" ] || die "no worktree_path in the hook input"
  if [ ! -d "$path" ]; then
    printf '%s: %s does not exist; nothing to remove\n' "$PROG" "$path" >&2
    return 0
  fi
  root=$(main_root "$path") || die "$path is not a git worktree"
  br=$(git -C "$path" symbolic-ref --short -q HEAD 2>/dev/null) || br=""

  git -C "$root" worktree remove "$path" >&2 2>&1 ||
    die "cannot remove $path (uncommitted changes or locked?); left as it is"

  [ -n "$br" ] || return 0
  def=$(default_branch "$root")
  cur=$(git -C "$root" symbolic-ref --short -q HEAD 2>/dev/null) || cur=""
  if [ "$br" = "$def" ] || [ "$br" = "$cur" ]; then
    return 0
  fi
  if git -C "$root" merge-base --is-ancestor "$br" HEAD 2>/dev/null ||
    { [ -n "$def" ] && git -C "$root" merge-base --is-ancestor "$br" "origin/$def" 2>/dev/null; }; then
    git -C "$root" branch -D "$br" >&2 2>&1 || true
  else
    printf '%s: kept branch %s (not merged into HEAD or origin/%s)\n' "$PROG" "$br" "${def:-HEAD}" >&2
  fi
}

case $mode in
  create) do_create ;;
  remove) do_remove ;;
  *) die "usage: worktree.sh create|remove" ;;
esac
