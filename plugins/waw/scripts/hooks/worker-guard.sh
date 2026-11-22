#!/usr/bin/env bash
# worker-guard.sh: PreToolUse hook (matchers Bash and Edit|Write|NotebookEdit|MultiEdit) for workers.
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
# No jq or unreadable input allows; a python3 failure blocks (command split and file-tool paths). Portable to macOS /bin/bash 3.2.
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

# inside_physical <path> <root>: the physical target of the path (symlinks followed, also in
# parents of a file that does not exist yet) is the root's physical path or under it. A `..`
# component, a leading `~`, a dangling link, a loop or any error: not inside.
#   physical_path <path>: prints that physical target (the root need not exist), or fails.
# Python 3.9 (macOS /usr/bin/python3) has no realpath(strict=True): strict_real stands in.
PHYS_PY='
import os, sys
mode, path, root, cwd = sys.argv[1:5]

def strict_real(x):
    r = os.path.realpath(x)
    if not os.path.exists(r):
        raise OSError(x)
    return r

try:
    if path.startswith("~"):
        sys.exit(1)
    if not path.startswith("/"):
        path = cwd + "/" + path
    if ".." in path.split("/"):
        sys.exit(1)
    if mode == "inside":
        root = strict_real(root)
    cur = os.path.normpath(path)
    suffix = []
    while True:
        try:
            os.lstat(cur)
            break
        except FileNotFoundError:
            parent = os.path.dirname(cur)
            if parent == cur:
                sys.exit(1)
            suffix.insert(0, os.path.basename(cur))
            cur = parent
    resolved = strict_real(cur)
    if suffix:
        if not os.path.isdir(resolved):
            sys.exit(1)
        resolved = os.path.join(resolved, *suffix)
    if mode == "print":
        print(resolved)
        sys.exit(0)
    sys.exit(0 if os.path.commonpath([root, resolved]) == root else 1)
except Exception:
    sys.exit(1)
'
inside_physical() {
  command -v python3 >/dev/null 2>&1 || return 1
  python3 -I -c "$PHYS_PY" inside "$1" "$2" "$PWD" 2>/dev/null
}
physical_path() {
  command -v python3 >/dev/null 2>&1 || return 1
  python3 -I -c "$PHYS_PY" print "$1" "" "$PWD" 2>/dev/null
}
# protected_write <file>: the physical target is one of the project files that run code for
# the next worker (settings, hooks, MCP servers) and is not listed in AGENT_GRANTS.
protected_write() {
  # Compared lowercased: macOS volumes are case-insensitive (.claude/SETTINGS.json is the same file).
  local pf ps t pt g rel
  pf=$(physical_path "$1") || return 1
  ps=$(physical_path "$scope") || return 1
  pf=$(printf '%s' "$pf" | tr '[:upper:]' '[:lower:]')
  ps=$(printf '%s' "$ps" | tr '[:upper:]' '[:lower:]')
  for t in .claude/settings.json .claude/settings.local.json .claude/hooks .mcp.json; do
    pt=$(physical_path "$scope/$t") || continue
    pt=$(printf '%s' "$pt" | tr '[:upper:]' '[:lower:]')
    case $pf in "$pt" | "$pt"/*) ;; *) continue ;; esac
    rel=${pf#"$ps"/}
    for g in ${AGENT_GRANTS:-}; do
      g=$(printf '%s' "$g" | tr '[:upper:]' '[:lower:]')
      [ "$g" = "$rel" ] && return 1
    done
    return 0
  done
  return 1
}

# ------------------------------------------------------------------ file tools

case $tool in
  Edit | Write | NotebookEdit | MultiEdit)
    file=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // ""' 2>/dev/null)
    [ -n "$scope" ] || exit 0
    [ -n "$file" ] || block "a file tool call without a path" "Give the file path; it must be inside $scope."
    if protected_write "$file"; then
      block "a write to $file" "Project settings and hooks run code for the next worker: the commander changes them."
    fi
    case $AGENT_ROLE in
      investigator | tester | reviewer)
        # .ship must stay inside the scope, the run dir must be its own physical path:
        # a link that redirects either one outside allows nothing.
        run_phys=
        [ -n "${AGENT_RUN_DIR:-}" ] && run_phys=$(cd "$AGENT_RUN_DIR" 2>/dev/null && pwd -P)
        if { inside_physical "$scope/.ship" "$scope" && inside_physical "$file" "$scope/.ship"; } ||
          { [ -n "$run_phys" ] && [ "$run_phys" = "${AGENT_RUN_DIR%/}" ] && inside_physical "$file" "$AGENT_RUN_DIR"; }; then
          exit 0
        fi
        block "a write to $file" "A $AGENT_ROLE writes only run files under $scope/.ship/ (notes, drafts, evidence)."
        ;;
      *)
        inside_physical "$file" "$scope" && exit 0
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

# One command per line: split on ; & | ( ) { } ` and newlines, but only outside single quotes,
# double quotes and after a backslash; a # that starts a word outside quotes drops the rest
# of its line. Quoted text stays inside its segment, so `echo "git push"` is one segment that
# starts with echo.
split_commands() {
  python3 -I -c '
import re, shlex, sys
t = sys.argv[1]

def words(seg):
    # Real words of a segment: quotes removed, whitespace inside a word made "_", leading
    # NAME=value assignments dropped, so the first word is the command.
    try:
        toks = shlex.split(seg, posix=True)
    except ValueError:
        return seg
    while toks and re.match(r"[A-Za-z_][A-Za-z0-9_]*=", toks[0]):
        toks.pop(0)
    return " ".join(re.sub(r"\s+", "_", w) for w in toks)

out, cur = [], []
q = None
stack = []  # [saved quote state, "(" or "`", paren depth] of each open substitution
i, n = 0, len(t)
while i < n:
    c = t[i]
    if q != "\x27" and c == "\\" and t[i + 1:i + 2] == "\n":
        i += 2
        continue
    if q == "\x27":
        cur.append(c)
        if c == q:
            q = None
    elif q == "\"":
        if c == "`" or (c == "$" and t[i + 1:i + 2] == "("):
            out.append("".join(cur))
            cur = []
            stack.append([q, "(" if c == "$" else "`", 0])
            q = None
            i += 2 if c == "$" else 1
            continue
        cur.append(c)
        if c == "\\" and i + 1 < n:
            i += 1
            cur.append(t[i])
        elif c == q:
            q = None
    elif c == "\\" and i + 1 < n:
        cur.append(c)
        i += 1
        cur.append(t[i])
    elif c in "\x27\"":
        q = c
        cur.append(c)
    elif c == "#" and (i == 0 or (t[i - 1] in " \t\n" and t[i - 2:i - 1] != "\\")):
        while i < n and t[i] != "\n":
            i += 1
        continue
    elif c in ";&|(){}`\n":
        if stack and c == stack[-1][1] == "`":
            q = stack.pop()[0]
        elif stack and stack[-1][1] == "(" and c == "(":
            stack[-1][2] += 1
        elif stack and stack[-1][1] == "(" and c == ")":
            if stack[-1][2] == 0:
                q = stack.pop()[0]
            else:
                stack[-1][2] -= 1
        out.append("".join(cur))
        cur = []
    else:
        cur.append(c)
    i += 1
out.append("".join(cur))
print("\n".join(words(s).replace("\n", " ") for s in out))
' "$1"
}
segments=$(split_commands "$cmd" 2>/dev/null) ||
  block "this command" "worker-guard needs python3 to parse a command and python3 failed: report this as BLOCKED to the commander."

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
  w1=${w1//[\"\']/}
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
