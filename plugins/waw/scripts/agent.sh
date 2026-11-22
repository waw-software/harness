#!/usr/bin/env bash
# agent.sh: start, supervise and talk to workers (Claude Code sessions, each role on its route:
# Anthropic directly, or an Anthropic-compatible gateway such as nexos.ai or OpenRouter; or
# Codex sessions on the ChatGPT subscription, route codex).
#
#   agent.sh run --role <role> --brief <file> --out <dir> [--cwd <dir>] [--name <id>]
#                [--resume <session-id>] [--budget <usd>] [--timeout <minutes>] [--allow-install]
#                (--budget: real US dollars at the model's price, see PRICES; default
#                budget_of the role)
#                [--grant <glob>]... [--quiet]
#       Runs the worker headless in --cwd (default: the current directory) with the brief as
#       its prompt, and waits for it. Roles: investigator, developer, reviewer, tester.
#       --resume continues an earlier worker session (its context is kept) with the brief as
#       the next message: use it to send fixes back to the same worker. Give a new --name.
#       --allow-install lets this worker run package installs (pnpm install, add, ...), which
#       the worker guard blocks otherwise; use it only when nobody else works in --cwd.
#       --grant <glob> (repeatable) pre-approves edits of files the project guards with "ask"
#       rules (package.json, tsconfig.json, docs/conventions/**, ...): relative to --cwd, a glob
#       without / matches the file name at any depth. Other such edits become APPROVAL events
#       for the commander (approve-mcp.mjs, the worker's permission-prompt tool); commands
#       outside the allowed ones are refused. Decisions: <name>.approvals.log.
#       Files in --out (the run directory, usually .ship/<slug>/agents):
#         <name>.brief.md     the brief as sent (<name>.steer-<n>.md: each steering message)
#         <name>.jsonl        the worker's whole session (stream-json): what it read, ran, wrote
#         <name>.result.json  its report, in the role's schema (schemas/<role>.json)
#         <name>.err          stderr
#         <name>.questions/   what it asked the commander (q<n>.question.json, q<n>.answer.txt)
#         events.log          what needs the commander: QUESTION, BLOCKED, FAILING, STALLED,
#                             TIMEOUT, one line each (agent.sh events follows it)
#         runs.tsv            one line per run: time, role, model, status, turns, tokens, session
#       While the worker runs, prints one line per step it takes ("[name 1m05s] Bash pnpm
#       test", "[name 1m20s] says: ...") and each event ("[name] !! QUESTION ..."), unless
#       --quiet; at the end, always one last line:
#       <name> <status> turns=<n> time=<s>s result=<file> session=<id>
#
#   Talking to a running worker (by its --name):
#   agent.sh answer <name> [<qid>] <text...>
#                            answer its question (default: its oldest open one); the worker,
#                            waiting in ask.sh, continues with the answer
#   agent.sh approve <name> [<aid>] [<note...>] | agent.sh deny <name> [<aid>] <reason...>
#                            decide its approval request (default: its oldest open one): an
#                            edit of a file the project guards ("ask" rules), which was not
#                            granted with --grant; the worker waits for it (8 minutes)
#   agent.sh approvals [<run dir>]
#                            the open approval requests of running workers
#   agent.sh steer <name> <text...>
#                            interrupt it and resume its session with this message (a
#                            correction, a new constraint); it keeps its context
#   agent.sh stop <name>     end it now; the run ends with status stopped
#   agent.sh events <run dir>
#                            follow events.log of a run directory: prints the open questions,
#                            then each new event; exits when no worker of that directory has
#                            run for a while. For the Monitor tool.
#   agent.sh questions [<run dir>]
#                            the open questions of running workers
#
#   agent.sh ps              the workers running now (any task): name, role, model, elapsed
#                            time, worktree and the last tool call each made (a run queued
#                            for a slot shows WAITING FOR WORKER SLOT)
#   agent.sh log <name|file.jsonl> [-f]
#                            the steps of a worker so far; -f keeps following a running one
#   agent.sh count           the number of admitted workers holding a slot (for the status line)
#   agent.sh models          print each role's model, route and worker config dir
#   agent.sh report <dir>    sum runs.tsv of a run directory per role and model, with the fix
#                            runs (names ending in -fix<n>) and steering messages, and the fix
#                            runs per developer slice
#   agent.sh sandbox-check   exit 0 when workers start inside the OS sandbox (the precondition
#                            of /auto-pilot), 3 with the reason otherwise
#
# Worker slots: every run holds one of at most AGENT_MAX_WORKERS (default 5) slots — shared
# by all install roots through AGENT_STATE_DIR (default $WAW_HOME/state) — from
# admission until its worker has exited, steering included. A run queues until a slot frees;
# after AGENT_SLOT_WAIT_SECONDS (default 600) it reports slot-timeout and exits 7. Slots are
# kept by slots.py; attack.sh claims none.
#
# Home: WAW_HOME, default ${CLAUDE_CONFIG_DIR:-~/.claude}/waw (config,
# prices.tsv, state/, workers/<route>/). Written by the plugin's /configure.
# Model per role: AGENT_<ROLE>_MODEL in $WAW_CONFIG, else $WAW_HOME/config,
# else ${XDG_CONFIG_HOME:-~/.config}/agentic-setup/config (KEY="value" lines, never sourced).
# Route per role: AGENT_<ROLE>_ROUTE, else WORKER_ROUTE, else nexos. A route is a Claude Code
# config dir (CLAUDE_CONFIG_DIR of the worker): $WAW_HOME/workers/<route>, whose
# settings.json holds the base URL and the apiKeyHelper (route anthropic: none, its own login).
# Route nexos falls back to NEXOS_CONFIG_DIR, then ~/.claude-nexos (the setup before the plugin).
# Route codex (or codex-<name>): the worker is a Codex session (`codex exec`), with
# $WAW_HOME/workers/<route> as its CODEX_HOME (its own login: `CODEX_HOME=<dir> codex login`;
# agent.sh writes config.toml and hooks.json there). The same contract as a Claude worker:
# the role prompt (developer_instructions), the report in the role's schema (a strict copy,
# lib/strict-schema.jq), the same guards (hooks/codex-pre-tool.sh: worker-guard, guard-push,
# and codex-policy.mjs for the project's Claude Code permission rules and approvals), an OS
# sandbox from a Codex permission profile (writes in the worktree and the run dir, no reads of
# SECRET_PATHS, localhost only, an install worker its registries), --resume, steer and stop.
# The stream is written to <name>.jsonl in Claude Code's stream-json form (lib/codex-stream.jq),
# so log, ps, events and report read it as they read a Claude worker. No dollar budget: the
# subscription has none (runs.tsv cost "sub"); --timeout bounds the run. When a project's
# permission rules cannot be enforced for Codex (codex-policy.mjs check), the run moves to the
# role's fallback: AGENT_<ROLE>_FALLBACK_ROUTE (default: WORKER_ROUTE, else anthropic) and
# AGENT_<ROLE>_FALLBACK_MODEL (default: sonnet). AGENT_<ROLE>_EFFORT sets a Codex worker's
# reasoning effort (default high).
# Each role gets roles/common.md and roles/<role>.md appended to its system prompt (saved as
# <name>.system.md) and its own tools; every worker runs with bypassPermissions (or, where
# the project's settings disable that mode, acceptEdits with the role's pre-approved
# commands, allowed_of), no MCP servers, no sub-agents, no web tools, CLAUDE_CHECKS=off for
# all roles but developer, a 10-minute default Bash timeout (ask.sh waits that long), and two
# PreToolUse hooks given with --settings: hooks/worker-guard.sh (scope, git, installs; it
# reads AGENT_ROLE, AGENT_SCOPE, AGENT_RUN_DIR, AGENT_ALLOW_INSTALL) and
# hooks/guard-push.sh (merges, force pushes, the default branch). The same --settings
# put every Bash command of the worker in Claude Code's OS sandbox (worker_settings): the
# hooks match command text and stop accidents; the sandbox is the isolation, which is also why
# bypassPermissions is safe where a project allows it. A tester does not start while a
# developer works in the same --cwd: it tests a settled tree.
# Exit: 0 report written, 2 usage, 3 config, 4 the worker failed or gave no valid report,
# 5 timed out, 6 stopped, 7 slot-wait timeout. Portable to macOS /bin/bash 3.2.
set -euo pipefail
unset CDPATH

HERE=$(cd "$(dirname "$0")" && pwd)
ROLES="investigator developer reviewer tester"
AS_HOME=${WAW_HOME:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/waw}
# One spelling: a worker's CLAUDE_CONFIG_DIR is built from it, and Claude Code keys the route's
# login on the exact path (".../anthropic/" or "a//b" looks logged out).
AS_HOME=$(printf '%s' "$AS_HOME" | sed 's#//*#/#g; s#\(.\)/$#\1#')
STATE_DIR=${AGENT_STATE_DIR:-$AS_HOME/state}
REGISTRY=$STATE_DIR/workers
MAX_WORKERS=${AGENT_MAX_WORKERS:-5}
SLOT_WAIT_SECONDS=${AGENT_SLOT_WAIT_SECONDS:-600}
STALL_SECONDS=${AGENT_STALL_SECONDS:-600}

die() {
  printf 'agent.sh: %s\n' "$2" >&2
  exit "$1"
}
command -v jq >/dev/null 2>&1 || die 3 "jq not found"

# ------------------------------------------------------------------ config

CFG_NEXOS_CONFIG_DIR="" CFG_WORKER_ROUTE="" CFG_AGENT_WORKER_ENV=""
CFG_AGENT_INVESTIGATOR_MODEL="" CFG_AGENT_DEVELOPER_MODEL="" CFG_AGENT_REVIEWER_MODEL="" CFG_AGENT_TESTER_MODEL=""
CFG_AGENT_INVESTIGATOR_ROUTE="" CFG_AGENT_DEVELOPER_ROUTE="" CFG_AGENT_REVIEWER_ROUTE="" CFG_AGENT_TESTER_ROUTE=""
for _r in INVESTIGATOR DEVELOPER REVIEWER TESTER; do
  for _k in FALLBACK_ROUTE FALLBACK_MODEL EFFORT; do eval "CFG_AGENT_${_r}_${_k}=''"; done
done
unset _r _k
cfg=${WAW_CONFIG:-}
if [ -z "$cfg" ]; then
  cfg=$AS_HOME/config
  [ -f "$cfg" ] || [ ! -f "${XDG_CONFIG_HOME:-$HOME/.config}/agentic-setup/config" ] ||
    cfg=${XDG_CONFIG_HOME:-$HOME/.config}/agentic-setup/config
fi
if [ -f "$cfg" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    if [[ $line =~ ^[[:space:]]*(NEXOS_CONFIG_DIR|WORKER_ROUTE|AGENT_WORKER_ENV|AGENT_(INVESTIGATOR|DEVELOPER|REVIEWER|TESTER)_(MODEL|ROUTE|FALLBACK_ROUTE|FALLBACK_MODEL|EFFORT))=\"([^\"]*)\"[[:space:]]*$ ]]; then
      # shellcheck disable=SC2034 # read by the eval
      val=${BASH_REMATCH[4]}
      eval "CFG_${BASH_REMATCH[1]}=\$val"
    fi
  done <"$cfg"
fi
# AGENT_WORKER_ENV: names of extra variables a worker's CLI inherits (a work proxy's token, a
# test's settings); the environment variable of the same name wins over the config's.
WORKER_ENV_NAMES=${AGENT_WORKER_ENV:-$CFG_AGENT_WORKER_ENV}

model_of() {
  case $1 in
    investigator) printf '%s' "$CFG_AGENT_INVESTIGATOR_MODEL" ;;
    developer) printf '%s' "$CFG_AGENT_DEVELOPER_MODEL" ;;
    reviewer) printf '%s' "$CFG_AGENT_REVIEWER_MODEL" ;;
    tester) printf '%s' "$CFG_AGENT_TESTER_MODEL" ;;
  esac
}

# route_of <role>: the route the role's worker runs through (a name: letters, digits, -).
route_of() {
  local r=""
  case $1 in
    investigator) r=$CFG_AGENT_INVESTIGATOR_ROUTE ;;
    developer) r=$CFG_AGENT_DEVELOPER_ROUTE ;;
    reviewer) r=$CFG_AGENT_REVIEWER_ROUTE ;;
    tester) r=$CFG_AGENT_TESTER_ROUTE ;;
  esac
  printf '%s' "${r:-${CFG_WORKER_ROUTE:-nexos}}"
}

# role_cfg <role> <KEY>: AGENT_<ROLE>_<KEY> of the config (KEY: FALLBACK_ROUTE, FALLBACK_MODEL, EFFORT).
role_cfg() {
  local v
  eval "v=\${CFG_AGENT_$(printf '%s' "$1" | tr a-z A-Z)_$2:-}"
  printf '%s' "$v"
}

# runner_of <route>: the program a route's workers run on: codex (route codex, codex-<name>) or claude.
runner_of() {
  case $1 in codex | codex-*) printf codex ;; *) printf claude ;; esac
}

# route_dir <route>: the Claude Code config dir of a route (route codex: its CODEX_HOME).
route_dir() {
  if [ "$1" = nexos ] && [ ! -d "$AS_HOME/workers/nexos" ]; then
    if [ -n "$CFG_NEXOS_CONFIG_DIR" ]; then printf '%s' "$CFG_NEXOS_CONFIG_DIR"; return; fi
    if [ -d "$HOME/.claude-nexos" ]; then printf '%s' "$HOME/.claude-nexos"; return; fi
  fi
  printf '%s' "$AS_HOME/workers/$1"
}

# Tools a role must not have. Write stays for investigator and tester: the guard hook limits
# it to the run files (.ship/). Web tools and MCP do not work through the proxy reliably,
# and gathering outside information is the commander's job.
denied_of() {
  case $1 in
    investigator) printf '%s' "Edit NotebookEdit Agent WebSearch WebFetch" ;;
    reviewer) printf '%s' "Edit Write NotebookEdit Agent WebSearch WebFetch" ;;
    developer) printf '%s' "NotebookEdit Agent WebSearch WebFetch" ;;
    tester) printf '%s' "Edit NotebookEdit Agent WebSearch WebFetch" ;;
  esac
}

# Pre-approved commands for a project that disables bypassPermissions (its settings set
# permissions.disableBypassPermissionsMode): the worker then runs in acceptEdits mode (edits
# inside --cwd need no approval) with these rules. Anything else is refused, headless; the
# project's own deny and ask rules still win (an ask is a refusal without a person).
allowed_of() {
  local read="Read Grep Glob Skill TodoWrite
Bash(cat:*) Bash(head:*) Bash(tail:*) Bash(sed -n:*) Bash(less:*) Bash(find:*) Bash(ls:*) Bash(tree:*)
Bash(wc:*) Bash(sort:*) Bash(uniq:*) Bash(cut:*) Bash(tr:*) Bash(awk:*) Bash(jq:*) Bash(diff:*) Bash(cmp:*)
Bash(file:*) Bash(stat:*) Bash(du:*) Bash(pwd) Bash(echo:*) Bash(printf:*) Bash(test:*) Bash(true) Bash(date:*)
Bash(grep:*) Bash(rg:*) Bash(which:*) Bash(command -v:*) Bash(basename:*) Bash(dirname:*) Bash(realpath:*)
Bash(git status:*) Bash(git diff:*) Bash(git log:*) Bash(git show:*) Bash(git blame:*) Bash(git ls-files:*)
Bash(git grep:*) Bash(git rev-parse:*) Bash(git branch:*) Bash(git check-ignore:*) Bash(git cat-file:*)
Bash(node:*) Bash(pnpm run:*) Bash(pnpm test:*) Bash(pnpm exec:*) Bash(pnpm --filter:*) Bash(pnpm -C:*)
Bash(pnpm list:*) Bash(pnpm ls:*) Bash(pnpm why:*) Bash(npm run:*) Bash(npm test:*) Bash(npm ls:*)
Bash(npx tsc:*) Bash(npx eslint:*) Bash(npx prettier:*) Bash(npx jest:*) Bash(npx vitest:*)
Bash(timeout:*) Bash(sleep:*)
Bash($HERE/ask.sh:*)"
  case $1 in
    investigator) printf '%s\n%s' "$read" "Write Bash(mkdir -p:*)" ;;
    reviewer) printf '%s' "$read" ;;
    developer) printf '%s\n%s' "$read" "Edit Write MultiEdit Bash(mkdir -p:*) Bash(touch:*)" ;;
    tester)
      printf '%s\n%s' "$read" "Write Bash(mkdir -p:*) Bash(cp:*) Bash(curl:*) Bash(ffmpeg:*)"
      ;;
  esac
}

# bypass_disabled <dir>: the project's settings forbid bypassPermissions.
bypass_disabled() {
  local f
  for f in "$1/.claude/settings.json" "$1/.claude/settings.local.json"; do
    [ -f "$f" ] && jq -e '.permissions.disableBypassPermissionsMode == "disable"' "$f" >/dev/null 2>&1 && return 0
  done
  return 1
}

# budget_of <role>: the default budget of a run, in real US dollars at the model's price.
budget_of() {
  case $1 in
    developer) echo 5 ;;
    reviewer) echo 4 ;;
    tester) echo 6 ;;
    *) echo 10 ;;
  esac
}

# Prices: PRICES (default $WAW_HOME/prices.tsv, else the legacy
# ~/.config/agentic-setup/prices.tsv, else the plugin's defaults/prices.tsv), one line per
# gateway model: model<TAB>input<TAB>output<TAB>cached input<TAB>cache write, US dollars per 1M
# tokens, as the gateway's price list gives them; # starts a comment. Claude Code does not know
# a gateway's model ids and prices each at Opus rates (5 / 25 / 0.5 / 6.25 per 1M), so its cost
# estimate and its --max-budget-usd are in "Opus dollars". With a model's price, a budget in
# real dollars is converted for it (cc_factor), and agent.sh report shows real dollars. A
# Claude model on the anthropic route needs no line: Claude Code's own estimate is right.
PRICES=${AGENT_PRICES:-$AS_HOME/prices.tsv}
if [ -z "${AGENT_PRICES:-}" ] && [ ! -f "$PRICES" ]; then
  PRICES=${XDG_CONFIG_HOME:-$HOME/.config}/agentic-setup/prices.tsv
  [ -f "$PRICES" ] || PRICES=$HERE/../defaults/prices.tsv
fi

# price_of <model>: "input output cached write" of the model, or nothing.
price_of() {
  [ -f "$PRICES" ] || return 0
  awk -F'\t' -v m="$1" '$1 == m && $0 !~ /^#/ { print $2, $3, $4, ($5 == "" ? $2 : $5); exit }' "$PRICES"
}

# cc_factor <model>: Claude Code's estimate divided by the real price, for a typical worker's
# mix of tokens (4 % input, 92 % cached input, 4 % output); nothing when the price is unknown.
cc_factor() {
  local p
  p=$(price_of "$1")
  [ -n "$p" ] || return 0
  printf '%s\n' "$p" | awk '{ real = 0.04 * $1 + 0.92 * $3 + 0.04 * $2
    if (real > 0) printf "%.4f\n", (0.04 * 5 + 0.92 * 0.5 + 0.04 * 25) / real }'
}

guard=$HERE/hooks/worker-guard.sh
push_guard=${AGENT_PUSH_GUARD:-$HERE/hooks/guard-push.sh}

# tilde <path>: the path with $HOME written as ~ (the form sandbox and permission rules take).
tilde() { case $1 in "$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;; *) printf '%s' "$1" ;; esac; }

# What a worker never reads: keys, tokens, the route configs (gateway URLs, key helpers, logins),
# the other agents' logins. Denied to its Bash (the sandbox) and to its Read tool (permission
# rules: the sandbox does not cover file tools). Of a route dir only its secret files: the
# worker's own Claude Code reads the rest of its dir (shell snapshots). An array: a path with
# spaces stays one entry. The commander's own list, $WAW_HOME/read-deny, is added at launch
# (read_deny_extra).
SECRET_PATHS=("~/.ssh" "~/Library/Keychains" "~/.claude-nexos/settings.json" "~/.claude-nexos/.claude.json"
  "~/.claude.json" "~/.config/gh" "~/.config/glab-cli" "~/.aws" "~/.netrc" "~/.docker/config.json" "~/.npmrc"
  "~/.codex/auth.json" "~/.local/share/opencode/auth.json"
  "~/.gnupg" "~/.kube" "~/.config/gcloud" "~/.azure" "~/.config/azure" "~/.config/doctl" "~/.oci"
  "~/.zsh_history" "~/.bash_history" "~/.sh_history" "~/.zhistory" "~/.zsh_sessions" "~/.bash_sessions"
  "~/.local/share/fish/fish_history"
  "~/Library/Application Support/Google/Chrome" "~/Library/Application Support/Chromium"
  "~/Library/Application Support/Firefox" "~/Library/Application Support/BraveSoftware"
  "~/Library/Application Support/1Password" "~/Library/Application Support/Code/User/globalStorage")
for _d in "${CLAUDE_CONFIG_DIR:-/nonexistent}"/ "$AS_HOME"/workers/*/ "${CFG_NEXOS_CONFIG_DIR:-/nonexistent}"/; do
  [ -d "$_d" ] || continue
  for _f in settings.json .claude.json .credentials.json auth.json; do
    SECRET_PATHS+=("$(tilde "${_d%/}/$_f")")
  done
done
unset _d _f

# read_deny_extra <worktree> <run dir>: the paths of $WAW_HOME/read-deny, one per line (an
# absolute path or ~/..., spaces kept; blank lines and # lines skipped). A path that is the
# worktree, the run directory or a parent of either is skipped with a warning: the worker
# needs them. Physical paths are compared (symlinks resolved when the path exists).
read_deny_extra() {
  local wdir=$1 wout=$2 f=$AS_HOME/read-deny line p rp s skip pw po
  [ -f "$f" ] || return 0
  pw=$(cd -P "$wdir" 2>/dev/null && pwd -P) || pw=$wdir
  po=$(cd -P "$wout" 2>/dev/null && pwd -P) || po=$wout
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case $line in '' | '#'*) continue ;; esac
    case $line in
      "~/"*) p=$HOME/${line#"~/"} ;;
      /*) p=$line ;;
      *) printf 'agent.sh: read-deny: %s is not an absolute path, skipped\n' "$line" >&2; continue ;;
    esac
    p=${p%/}
    rp=$p
    if [ -d "$p" ]; then rp=$(cd -P "$p" && pwd -P) || rp=$p; fi
    rp=${rp%/}
    skip=0
    for s in "$pw" "$po"; do
      case "$s/" in "$rp"/*) skip=1 ;; esac
    done
    if [ "$skip" = 1 ]; then
      printf 'agent.sh: read-deny: %s contains the worktree, skipped\n' "${p:-/}" >&2
      continue
    fi
    tilde "$p"; printf '\n'
    if [ "$rp" != "$p" ]; then tilde "$rp"; printf '\n'; fi
  done <"$f"
}

# registry_hosts <dir>: the package registries named in <dir>/.npmrc and ~/.npmrc (host names).
registry_hosts() {
  grep -hoE 'https?://[^/:" ]+' "$1/.npmrc" "$HOME/.npmrc" 2>/dev/null | sed 's#^.*//##' | sort -u
}

# worker_settings <role> <dir> <run dir> <allow_install 0|1>: the --settings JSON of a worker.
#   hooks        worker-guard.sh and guard-push.sh before Bash, Edit and Write calls;
#   permissions  Read denied on SECRET_PATHS;
#   sandbox      Claude Code's OS sandbox (Seatbelt on macOS) around every Bash command and
#                its children: writes only in <dir>, <run dir>, the per-user temp dir and the
#                tool caches; reads none of SECRET_PATHS; no network host (an install worker:
#                its package registries), localhost allowed (tests start servers); no
#                unsandboxed retry, and no worker without the sandbox.
# AGENT_SANDBOX=off leaves the sandbox out, for debugging only: sandbox-check (and so
# /auto-pilot) refuses then.
worker_settings() {
  local role=$1 wdir=$2 wout=$3 install=$4 p hosts=()
  local secrets=()
  for p in "${SECRET_PATHS[@]}"; do
    if [ "$install" = 1 ] && [ "$p" = "~/.npmrc" ]; then continue; fi
    secrets+=("$p")
  done
  while IFS= read -r p; do [ -z "$p" ] || secrets+=("$p"); done < <(read_deny_extra "$wdir" "$wout")
  if [ "$install" = 1 ]; then
    hosts=(registry.npmjs.org)
    while IFS= read -r p; do [ -z "$p" ] || hosts+=("$p"); done < <(registry_hosts "$wdir")
  fi
  jq -nc --arg g "$guard" --arg pg "$push_guard" --arg d "$wdir" --arg o "$wout" \
    --arg role "$role" --arg install "$install" --arg sb "${AGENT_SANDBOX:-on}" \
    --arg hosts "${hosts[*]:-}" '
    ($ARGS.positional) as $sec
    | {hooks: {PreToolUse: [
        {matcher: "Bash", hooks: [{type: "command", command: $g}, {type: "command", command: $pg}]},
        {matcher: "Edit|Write|NotebookEdit|MultiEdit", hooks: [{type: "command", command: $g}]}]},
       permissions: {deny: [$sec[] | (if startswith("/") then "/" + . else . end)
         | ("Read(\(.))", "Read(\(.)/**)")]}}
    | if $sb == "off" then . else .sandbox = ({
        enabled: true, failIfUnavailable: true, allowUnsandboxedCommands: false,
        filesystem: {
          allowWrite: ([$d, $o, "~/Library/Caches", "~/.cache"]
            + (if $install == "1" then ["~/Library/pnpm", "~/.pnpm-store", "~/.npm"] else [] end)),
          denyRead: $sec},
        network: {strictAllowlist: true, allowLocalBinding: true,
          allowedDomains: ($hosts | split(" ") | map(select(. != "")))}}) end
    ' --args "${secrets[@]}"
}

# codex_home <dir>: write the files of a Codex route that do not depend on the run (rewritten
# when they differ, atomically: workers of the route share them). The login (auth.json) is the
# developer's: `CODEX_HOME=<dir> codex login`.
codex_home() {
  local d=$1 f tmp
  mkdir -p "$d"
  chmod 700 "$d"
  tmp=$(mktemp "$d/.cfg.XXXXXX")
  cat >"$tmp" <<TOML
# Written by agent.sh (waw) for Codex workers; rewritten when it differs. The run adds the
# filesystem and network of the sandbox, the environment and the role prompt (-c).
default_permissions = "worker"
web_search = "disabled"
model_reasoning_effort = "high"
check_for_update_on_startup = false

[features]
apps = false
multi_agent = false
memories = false
network_proxy = true
hooks = true
plugins = false

# Skills: the project's (.agents/skills) and the route's (<this dir>/skills) load, as a Claude
# worker loads its project's and its route's. Codex's bundled ones do not; the developer's own
# (~/.agents/skills) are turned off per run (skills.config).
[skills.bundled]
enabled = false

[plugins._default]
enabled = false

[permissions.worker.network]
enabled = true
allow_local_binding = true
TOML
  cmp -s "$tmp" "$d/config.toml" && rm -f "$tmp" || mv -f "$tmp" "$d/config.toml"
  tmp=$(mktemp "$d/.hooks.XXXXXX")
  jq -n --arg c "$HERE/hooks/codex-pre-tool.sh" \
    '{hooks: {PreToolUse: [{matcher: "^(Bash|apply_patch)$", hooks: [{type: "command", command: $c, timeout: 600}]}]}}' >"$tmp"
  cmp -s "$tmp" "$d/hooks.json" && rm -f "$tmp" || mv -f "$tmp" "$d/hooks.json"
  for f in config.toml hooks.json; do chmod 600 "$d/$f"; done
}

# toml_table: a JSON object on stdin as a TOML inline table (nested objects too).
toml_value() {
  jq -r 'def v: if type == "object" then to_entries | map("\(.key | tojson) = \(.value | v)") | join(", ") | "{ \(.) }"
    elif type == "array" then map(v) | join(", ") | "[\(.)]" else tojson end; v'
}
toml_table() { toml_value; }

# codex_run_config <role> <dir> <run dir> <allow_install 0|1> <project read-denies JSON>: the
# -c options of one Codex worker run, one per line (key=value): the sandbox's filesystem and
# network, the environment of its shell, the role prompt and the effort.
codex_run_config() {
  local role=$1 wdir=$2 wout=$3 install=$4 extra=$5 p hosts=() effort
  local secrets=("~/.agents/skills")
  for p in "${SECRET_PATHS[@]}"; do
    if [ "$install" = 1 ] && [ "$p" = "~/.npmrc" ]; then continue; fi
    secrets+=("$p")
  done
  # worker_settings has warned about skipped read-deny lines already
  while IFS= read -r p; do [ -z "$p" ] || secrets+=("$p"); done < <(read_deny_extra "$wdir" "$wout" 2>/dev/null)
  if [ "$install" = 1 ]; then
    hosts=(registry.npmjs.org)
    while IFS= read -r p; do [ -z "$p" ] || hosts+=("$p"); done < <(registry_hosts "$wdir")
  fi
  printf 'permissions.worker.filesystem=%s\n' "$(jq -nc --arg o "$wout" --arg install "$install" --argjson extra "$extra" '
    ($ARGS.positional | map({(.): "deny"}) | add // {}) as $deny
    | {":root": "read", ":tmpdir": "write", ($o): "write", "~/Library/Caches": "write", "~/.cache": "write"}
      + (if $install == "1" then {"~/Library/pnpm": "write", "~/.pnpm-store": "write", "~/.npm": "write"} else {} end)
      + $deny + ($extra | del(.[":workspace_roots"]))
      + {":workspace_roots": ({".": "write"} + ($extra[":workspace_roots"] // {}))}' --args "${secrets[@]}" | toml_table)"
  printf 'permissions.worker.network=%s\n' "$(jq -nc --arg hosts "${hosts[*]:-}" '
    {enabled: true, allow_local_binding: true}
    + (($hosts | split(" ") | map(select(. != ""))) as $h | if ($h | length) > 0 then {domains: ($h | map({(.): "allow"}) | add)} else {} end)' | toml_table)"
  printf 'shell_environment_policy=%s\n' "$(jq -nc --arg n "$AGENT_NAME_V" --arg r "$role" --arg s "$wdir" --arg o "$wout" --arg e "$wout/events.log" '
    {inherit: "core", set: {AGENT_NAME: $n, AGENT_ROLE: $r, AGENT_SCOPE: $s, AGENT_RUN_DIR: $o, AGENT_EVENTS: $e}}' | toml_table)"
  # The developer's own skills (~/.agents/skills) stay out; the project's (.agents/skills) and the
  # route's ($CODEX_HOME/skills) are the worker's, as a Claude worker has its project's and its
  # route's. Codex has no switch for that one place, so each of its skills is turned off.
  printf 'skills.config=%s\n' "$(find "$HOME/.agents/skills" -mindepth 2 -maxdepth 2 -name SKILL.md 2>/dev/null |
    jq -Rnc '[inputs | {path: ., enabled: false}]' | toml_value)"
  printf 'developer_instructions=%s\n' "$(jq -Rs . <"$prompt")"
  effort=$(role_cfg "$role" EFFORT)
  [ -z "$effort" ] || printf 'model_reasoning_effort=%s\n' "$(jq -Rn --arg e "$effort" '$e')"
}

# ------------------------------------------------------------------ following a worker

# The worker's actions in its stream-json log, one line each: tool calls, and the text it
# writes between them (shortened).
STEP_FMT='select(.type == "assistant") | .message.content[]?
  | if .type == "tool_use" then
      "\(.name) \((.input.command // .input.file_path // .input.pattern // .input.skill // .input.description // "") | tostring)"
    elif .type == "text" then "says: \(.text)"
    else empty end
  | gsub("[\n\t]+"; " ") | .[0:140]'

# What events are made of: T<tab>tool call, O (a tool call succeeded), E<tab>error text.
EVT_FMT='if .type == "assistant" then
    (.message.content[]? | select(.type == "tool_use")
     | "T\t" + ("\(.name) \((.input.command // .input.file_path // .input.pattern // "") | tostring)" | gsub("[\n\t]+"; " ") | .[0:120]))
  elif .type == "user" then
    (.message.content[]? | select(.type == "tool_result")
     | if .is_error == true then
         "E\t" + ((.content | if type == "array" then map(.text? // "") | join(" ") else tostring end) | gsub("[\n\t]+"; " ") | .[0:220])
       else "O" end)
  else empty end'

# emit <events file> <type> <name> <text>: one event line.
emit() {
  [ "$1" != - ] || return 0
  printf '%s %s %s: %s\n' "$(date +%H:%M:%S)" "$2" "$3" "$4" >>"$1"
}

# follow_log <log> <runfile|-> <name> <started epoch> <events file|-> <print 0|1>
# Prints the log's steps as they are written ([name m:ss] ...), and, with an events file,
# writes the events that need the commander: BLOCKED (a guard or a permission refused a
# call), FAILING (3 failed calls in a row), STALLED (no step for STALL_SECONDS, unless the
# worker waits for an answer). Runs while <runfile> exists ("-": one pass over what is there).
follow_log() {
  local log=$1 runfile=$2 wname=$3 wstart=$4 events=$5 print=$6
  local seen=0 total alive el line root="" kind text last_tool="" fails=0 changed stalled=0 now chunk
  case $log in */.ship/*) root=${log%%/.ship/*}/ ;; esac
  changed=$(date +%s)
  while :; do
    alive=0
    [ "$runfile" != - ] && [ -f "$runfile" ] && alive=1
    if [ -f "$log" ]; then
      total=$(wc -l <"$log" | tr -d ' ')
      if [ "$total" -gt "$seen" ]; then
        el=$(($(date +%s) - wstart))
        chunk=$(sed -n "$((seen + 1)),${total}p" "$log")
        seen=$total
        changed=$(date +%s) stalled=0
        if [ "$print" = 1 ]; then
          while IFS= read -r line; do
            [ -z "$root" ] || line=${line//$root/}
            if [ "$runfile" = - ]; then printf '[%s] %s\n' "$wname" "$line"
            else printf '[%s %dm%02ds] %s\n' "$wname" $((el / 60)) $((el % 60)) "$line"; fi
          done < <(printf '%s\n' "$chunk" | jq -r "$STEP_FMT" 2>/dev/null)
        fi
        if [ "$events" != - ]; then
          while IFS=$'\t' read -r kind text; do
            [ -z "$root" ] || text=${text//$root/}
            case $kind in
              T) last_tool=$text ;;
              O) fails=0 ;;
              E)
                case $text in
                  *"denied by the commander"*)
                    # the commander's own decision: no event, it knows
                    fails=0
                    ;;
                  *worker-guard* | *"has been denied"* | *"Permission to use"* | *"hook error"* | *"requires approval"* | \
                    *"not among the calls workers may make"* | *"no approval within"* | *"outside your working directory"*)
                    emit "$events" BLOCKED "$wname" "$last_tool -> $text"
                    [ "$print" = 0 ] || printf '[%s] !! BLOCKED %s -> %s\n' "$wname" "$last_tool" "$text"
                    fails=0
                    ;;
                  *)
                    fails=$((fails + 1))
                    if [ "$fails" = 3 ]; then
                      emit "$events" FAILING "$wname" "3 failed tool calls in a row; last: $last_tool -> $text"
                      [ "$print" = 0 ] || printf '[%s] !! FAILING 3 in a row; last: %s\n' "$wname" "$last_tool"
                    fi
                    ;;
                esac
                ;;
            esac
          done < <(printf '%s\n' "$chunk" | jq -r "$EVT_FMT" 2>/dev/null)
        fi
      fi
    fi
    [ "$alive" = 1 ] || break
    if [ "$events" != - ] && [ "$stalled" = 0 ]; then
      now=$(date +%s)
      case $last_tool in *ask.sh*) ;; *)
        if [ $((now - changed)) -ge "$STALL_SECONDS" ]; then
          emit "$events" STALLED "$wname" "no step for $((STALL_SECONDS / 60)) min; last: ${last_tool:-none}"
          [ "$print" = 0 ] || printf '[%s] !! STALLED, last: %s\n' "$wname" "${last_tool:-none}"
          stalled=1
        fi
        ;;
      esac
    fi
    sleep 2
  done
}

# find_worker <name>: set W_PID W_START W_NAME W_ROLE W_MODEL W_DIR W_LOG W_OUT of the running
# worker of that name (the newest when there are several); return 1 when there is none.
find_worker() {
  local f p s n r m d l o found=1
  for f in "$REGISTRY"/*.tsv; do
    [ -f "$f" ] || continue
    IFS=$'\t' read -r p s n r m d l o <"$f" || continue
    kill -0 "$p" 2>/dev/null || { rm -f "$f"; continue; }
    if [ "$n" = "$1" ]; then
      W_PID=$p W_START=$s W_NAME=$n W_ROLE=$r W_MODEL=$m W_DIR=$d W_LOG=$l W_OUT=$o
      found=0
    fi
  done
  return $found
}

# open_questions <run dir>: "name qid question" of every question without an answer or a timeout.
open_questions() {
  local q base qdir wname
  for q in "$1"/*.questions/q*.question.json; do
    [ -f "$q" ] || continue
    base=${q%.question.json}
    [ -f "$base.answer.txt" ] || [ -f "$base.timeout" ] && continue
    qdir=$(dirname "$q")
    wname=$(basename "$qdir" .questions)
    find_worker "$wname" || continue
    jq -r --arg n "$wname" '"\($n) \(.id): \(.question) | options: \((.options // []) | join(" / ")) | recommends: \(.recommend // "-")"' "$q"
  done
}

# open_approvals <run dir>: "name aid: tool file" of every approval request without a decision.
open_approvals() {
  local r base adir wname
  for r in "$1"/*.approvals/a*.request.json; do
    [ -f "$r" ] || continue
    base=${r%.request.json}
    [ -f "$base.decision.json" ] || [ -f "$base.timeout" ] && continue
    adir=$(dirname "$r")
    wname=$(basename "$adir" .approvals)
    find_worker "$wname" || continue
    jq -r --arg n "$wname" '"\($n) \(.id): \(.tool) \(.file)"' "$r"
  done
}

# kill_worker <runfile>: stop the worker process recorded in it, with its children.
kill_worker() {
  local p
  p=$(cat "$1" 2>/dev/null || true)
  [ -n "$p" ] || return 0
  pkill -TERM -P "$p" 2>/dev/null || true
  kill -TERM "$p" 2>/dev/null || true
}

# ------------------------------------------------------------------ commands

cmd=${1:-}
[ $# -eq 0 ] || shift
case $cmd in
  -h | --help | "")
    awk 'NR > 1 && /^set -euo/ { exit } NR > 1' "$0"
    exit 0
    ;;
  models)
    # --tsv: role<TAB>model<TAB>route<TAB>worker config dir, no header (for scripts)
    if [ "${1:-}" = --tsv ]; then
      for r in $ROLES; do
        rt=$(route_of "$r")
        printf '%s\t%s\t%s\t%s\n' "$r" "$(model_of "$r")" "$rt" "$(route_dir "$rt")"
      done
      exit 0
    fi
    printf '%-13s %-32s %-12s %s\n' ROLE MODEL ROUTE "WORKER CONFIG DIR"
    for r in $ROLES; do
      rt=$(route_of "$r")
      printf '%-13s %-32s %-12s %s\n' "$r" "$(model_of "$r")" "$rt" "$(route_dir "$rt")"
    done
    printf 'config        %s\n' "$cfg"
    exit 0
    ;;
  ps)
    now=$(date +%s) found=0
    for f in "$REGISTRY"/*.tsv; do
      [ -f "$f" ] || continue
      IFS=$'\t' read -r wpid wstart wname wrole wmodel wdir wlog wout <"$f" || continue
      if ! kill -0 "$wpid" 2>/dev/null; then rm -f "$f"; continue; fi
      if [ "$found" = 0 ]; then
        printf '%-20s %-12s %-24s %7s  %-42s %s\n' NAME ROLE MODEL ELAPSED WORKTREE "LAST ACTION"
        found=1
      fi
      el=$((now - wstart))
      last=$(tail -n 40 "$wlog" 2>/dev/null | jq -rs '
        [.[] | select(.type == "assistant") | .message.content[]? | select(.type == "tool_use")
         | .name + " " + ((.input.command // .input.file_path // .input.pattern // .input.skill // "") | tostring)]
        | last // "starting"' 2>/dev/null | tr '\n' ' ' | cut -c1-70)
      case $last in *ask.sh*) last="WAITING FOR AN ANSWER (agent.sh questions)" ;; esac
      if [ -n "$wout" ] && open_approvals "$wout" | grep -q "^$wname "; then
        last="WAITING FOR APPROVAL (agent.sh approvals)"
      fi
      if [ -f "$wout/$wname.queued" ]; then last="WAITING FOR WORKER SLOT"; fi
      printf '%-20s %-12s %-24s %4dm%02ds  %-42s %s\n' "$wname" "$wrole" "$wmodel" $((el / 60)) $((el % 60)) \
        "$(printf '%s' "$wdir" | sed "s|^$HOME|~|" | tail -c 42)" "${last:-starting}"
    done
    [ "$found" = 1 ] || echo "no workers running"
    exit 0
    ;;
  log)
    [ $# -ge 1 ] || die 2 "usage: agent.sh log <name|file.jsonl> [-f]"
    target=$1 follow=0
    [ "${2:-}" = -f ] && follow=1
    if [ -f "$target" ]; then
      follow_log "$target" - "$(basename "$target" .jsonl)" "$(date +%s)" - 1
    elif find_worker "$target"; then
      if [ "$follow" = 1 ]; then rf=$W_OUT/$W_NAME.pid; else rf=-; fi
      follow_log "$W_LOG" "$rf" "$W_NAME" "$W_START" - 1
    else
      die 3 "no running worker named $target (give the path of its .jsonl for a finished one)"
    fi
    exit 0
    ;;
  count)
    # Admitted workers only: what slots.py counts, not the queued wrappers.
    exec python3 -I "$HERE/slots.py" count --state-dir "$STATE_DIR"
    ;;
  answer)
    [ $# -ge 2 ] || die 2 "usage: agent.sh answer <name> [<qid>] <text...>"
    find_worker "$1" || die 3 "no running worker named $1"
    shift
    qdir=$W_OUT/$W_NAME.questions
    qid=""
    if [[ $1 =~ ^q[0-9]+$ ]] && [ $# -ge 2 ]; then qid=$1; shift; fi
    if [ -z "$qid" ]; then
      for q in "$qdir"/q*.question.json; do
        [ -f "$q" ] || continue
        b=${q%.question.json}
        if [ ! -f "$b.answer.txt" ] && [ ! -f "$b.timeout" ]; then qid=$(basename "$b"); break; fi
      done
    fi
    [ -n "$qid" ] || die 3 "$W_NAME has no open question (agent.sh questions)"
    [ -f "$qdir/$qid.question.json" ] || die 3 "$W_NAME has no question $qid"
    if [ -f "$qdir/$qid.timeout" ]; then
      die 3 "$W_NAME stopped waiting for $qid and went on with its recommendation: steer it instead"
    fi
    printf '%s\n' "$*" >"$qdir/$qid.answer.txt.tmp" && mv -f "$qdir/$qid.answer.txt.tmp" "$qdir/$qid.answer.txt"
    echo "answered $W_NAME $qid"
    exit 0
    ;;
  approve | deny)
    [ $# -ge 1 ] || die 2 "usage: agent.sh approve <name> [<aid>] [<note...>] | agent.sh deny <name> [<aid>] <reason...>"
    find_worker "$1" || die 3 "no running worker named $1"
    shift
    adir=$W_OUT/$W_NAME.approvals
    aid=""
    if [ $# -ge 1 ] && [[ $1 =~ ^a[0-9]+$ ]]; then aid=$1; shift; fi
    if [ -z "$aid" ]; then
      for r in "$adir"/a*.request.json; do
        [ -f "$r" ] || continue
        b=${r%.request.json}
        if [ ! -f "$b.decision.json" ] && [ ! -f "$b.timeout" ]; then aid=$(basename "$b"); break; fi
      done
    fi
    [ -n "$aid" ] || die 3 "$W_NAME has no open approval request (agent.sh approvals)"
    [ -f "$adir/$aid.request.json" ] || die 3 "$W_NAME has no approval request $aid"
    [ ! -f "$adir/$aid.timeout" ] || die 3 "$aid was already denied for lack of a decision: steer $W_NAME instead"
    [ "$cmd" = approve ] || [ $# -ge 1 ] || die 2 "deny needs a reason the worker can act on"
    if [ "$cmd" = approve ]; then behavior=allow; else behavior=deny; fi
    jq -n --arg b "$behavior" --arg m "$*" '{behavior: $b, message: $m}' >"$adir/$aid.decision.json.tmp" &&
      mv -f "$adir/$aid.decision.json.tmp" "$adir/$aid.decision.json"
    if [ "$cmd" = approve ]; then done_word=approved; else done_word=denied; fi
    echo "$done_word $W_NAME $aid ($(jq -r '"\(.tool) \(.file)"' "$adir/$aid.request.json"))"
    exit 0
    ;;
  approvals)
    if [ $# -ge 1 ]; then
      open_approvals "$1"
    else
      for f in "$REGISTRY"/*.tsv; do
        [ -f "$f" ] || continue
        IFS=$'\t' read -r _ _ _ _ _ _ _ o <"$f" || continue
        printf '%s\n' "$o"
      done | sort -u | while IFS= read -r o; do [ -n "$o" ] && open_approvals "$o"; done
    fi
    exit 0
    ;;
  steer | stop)
    [ $# -ge 1 ] || die 2 "usage: agent.sh steer <name> <text...> | agent.sh stop <name>"
    find_worker "$1" || die 3 "no running worker named $1"
    shift
    if [ "$cmd" = steer ]; then
      [ $# -ge 1 ] || die 2 "usage: agent.sh steer <name> <text...>"
      printf '%s\n' "$*" >"$W_OUT/$W_NAME.steer.msg.tmp" && mv -f "$W_OUT/$W_NAME.steer.msg.tmp" "$W_OUT/$W_NAME.steer.msg"
    else
      : >"$W_OUT/$W_NAME.stop"
    fi
    kill_worker "$W_OUT/$W_NAME.pid"
    if [ "$cmd" = steer ]; then echo "steering $W_NAME: interrupted; it resumes its session with your message"
    else echo "stopping $W_NAME"; fi
    exit 0
    ;;
  questions)
    if [ $# -ge 1 ]; then
      open_questions "$1"
    else
      for f in "$REGISTRY"/*.tsv; do
        [ -f "$f" ] || continue
        IFS=$'\t' read -r _ _ _ _ _ _ _ o <"$f" || continue
        printf '%s\n' "$o"
      done | sort -u | while IFS= read -r o; do open_questions "$o"; done
    fi
    exit 0
    ;;
  events)
    [ $# -eq 1 ] && [ -d "$1" ] || die 2 "usage: agent.sh events <run dir>"
    rd=$(cd "$1" && pwd -P)
    ev=$rd/events.log
    touch "$ev"
    seen=$(wc -l <"$ev" | tr -d ' ')
    open_questions "$rd" | sed 's/^/OPEN QUESTION /'
    open_approvals "$rd" | sed 's/^/OPEN APPROVAL /'
    t0=$(date +%s) any=0 idle=0
    while :; do
      total=$(wc -l <"$ev" | tr -d ' ')
      if [ "$total" -gt "$seen" ]; then
        sed -n "$((seen + 1)),${total}p" "$ev"
        seen=$total
      fi
      running=0
      for f in "$REGISTRY"/*.tsv; do
        [ -f "$f" ] || continue
        IFS=$'\t' read -r p _ _ _ _ _ _ o <"$f" || continue
        [ "$o" = "$rd" ] && kill -0 "$p" 2>/dev/null && running=1
      done
      if [ "$running" = 1 ]; then any=1 idle=0
      else idle=$((idle + 1)); fi
      # No worker for ~20 s after one ran, or none at all within 2 minutes: done.
      if { [ "$any" = 1 ] && [ "$idle" -ge 10 ]; } || { [ "$any" = 0 ] && [ $(($(date +%s) - t0)) -ge 120 ]; }; then
        echo "NO WORKERS RUNNING in $rd: events watch ended"
        exit 0
      fi
      sleep 2
    done
    ;;
  report)
    [ $# -eq 1 ] || die 2 "usage: agent.sh report <run dir>"
    tsv=$1/runs.tsv
    [ -f "$tsv" ] || die 3 "no runs in $1 (no runs.tsv)"
    # steering messages: one <name>.steer-<n>.md per message, counted for the run <name>
    steers=""
    for s in "$1"/*.steer-*.md; do
      [ -f "$s" ] || continue
      s=$(basename "$s")
      steers="$steers ${s%.steer-*.md}"
    done
    prices=$PRICES
    [ -f "$prices" ] || prices=/dev/null
    awk -F'\t' -v steers="$steers" -v pfile="$prices" '
      BEGIN { n = split(steers, sl, " "); for (i = 1; i <= n; i++) st[sl[i]]++ }
      FILENAME == pfile { if ($0 !~ /^#/ && NF >= 4) { pin[$1] = $2; pout[$1] = $3; pcr[$1] = $4; pcw[$1] = ($5 == "" ? $2 : $5) }; next }
      FNR == 1 { next }
      { k = $4 " | " $5; runs[k]++; if ($6 != "ok") failed[k]++
        turns[k] += $7; secs[k] += $8; tin[k] += $9; tout[k] += $10
        if ($2 ~ /-fix[0-9]+$/) fix[k]++
        # real dollars at the model price: exact with the token split (columns 12-14), else
        # Claude Code estimate (column 11, Opus rates) scaled by the typical mix (marked ~)
        if ($11 == "sub") subs[k] = 1
        else if (($5 in pin) && NF >= 14) usd[k] += ($12 * pin[$5] + $13 * pcr[$5] + $14 * pcw[$5] + $10 * pout[$5]) / 1e6
        else if (($5 in pin) && $11 != "") { r = 0.04 * pin[$5] + 0.92 * pcr[$5] + 0.04 * pout[$5]; usd[k] += $11 * r / 1.66; approx[k] = 1 }
        else nousd[k] = 1
        steer[k] += st[$2]
        if ($4 == "developer") { slice = $2; sub(/-fix[0-9]+$/, "", slice); slices[slice] = 1; if ($2 ~ /-fix[0-9]+$/) dfix++ } }
      END {
        printf "%-40s %5s %6s %4s %5s %6s %8s %10s %10s %9s\n", "role | model", "runs", "failed", "fix", "steer", "turns", "minutes", "in tok", "out tok", "usd"
        for (k in runs) {
          u = subs[k] ? "sub" : nousd[k] ? "n/a" : sprintf("%s%.2f", approx[k] ? "~" : "", usd[k])
          printf "%-40s %5d %6d %4d %5d %6d %8.1f %10d %10d %9s\n", k, runs[k], failed[k], fix[k], steer[k], turns[k], secs[k] / 60, tin[k], tout[k], u
          R += runs[k]; F += failed[k]; X += fix[k]; G += steer[k]; T += turns[k]; S += secs[k]; I += tin[k]; O += tout[k]; U += usd[k]
          if (nousd[k]) NU = 1; if (approx[k]) AP = 1
        }
        u = NU ? "n/a" : sprintf("%s%.2f", AP ? "~" : "", U)
        printf "%-40s %5d %6d %4d %5d %6d %8.1f %10d %10d %9s\n", "total", R, F, X, G, T, S / 60, I, O, u
        if (AP) print "~ estimated from older runs without the token split"
        for (k in subs) { print "sub: on a subscription (Codex), not billed per token; total without those runs"; break }
        ns = 0; for (s in slices) ns++
        if (ns > 0) printf "developer slices: %d, fix runs per slice: %.1f\n", ns, dfix / ns
      }' "$prices" "$tsv"
    exit 0
    ;;
  sandbox-check)
    # The precondition of /auto-pilot: every worker starts inside the OS sandbox.
    [ "${AGENT_SANDBOX:-on}" != off ] || die 3 "AGENT_SANDBOX=off: workers would start without the OS sandbox"
    case $(uname -s) in
      Darwin) command -v sandbox-exec >/dev/null 2>&1 || die 3 "sandbox-exec not found: no macOS Seatbelt" ;;
      Linux) command -v bwrap >/dev/null 2>&1 || die 3 "bwrap not found: Linux needs bubblewrap for the sandbox" ;;
      *) die 3 "no OS sandbox on $(uname -s)" ;;
    esac
    sb=$(worker_settings developer /nonexistent/wt /nonexistent/wt/.ship/x/agents 0)
    printf '%s' "$sb" | jq -e '.sandbox.enabled == true and .sandbox.failIfUnavailable == true
      and .sandbox.allowUnsandboxedCommands == false and .sandbox.network.strictAllowlist == true
      and (.sandbox.filesystem.denyRead | index("~/.ssh")) != null' >/dev/null ||
      die 3 "the worker settings lack the sandbox (worker_settings)"
    echo "sandbox ok: workers run Bash in the OS sandbox (no network, no secrets, writes in the worktree only)"
    exit 0
    ;;
  run) ;;
  *) die 2 "unknown command: $cmd (see agent.sh --help)" ;;
esac

# ------------------------------------------------------------------ run

role="" brief="" out="" dir=$PWD name="" resume="" budget="" timeout_min=60 allow_install=0 quiet=0 grants=""
while [ $# -gt 0 ]; do
  case $1 in
    --role) [ $# -ge 2 ] || die 2 "--role needs a value"; role=$2; shift ;;
    --brief) [ $# -ge 2 ] || die 2 "--brief needs a file"; brief=$2; shift ;;
    --out) [ $# -ge 2 ] || die 2 "--out needs a directory"; out=$2; shift ;;
    --cwd) [ $# -ge 2 ] || die 2 "--cwd needs a directory"; dir=$2; shift ;;
    --name) [ $# -ge 2 ] || die 2 "--name needs a value"; name=$2; shift ;;
    --resume) [ $# -ge 2 ] || die 2 "--resume needs a session id"; resume=$2; shift ;;
    --budget) [ $# -ge 2 ] || die 2 "--budget needs a number"; budget=$2; shift ;;
    --timeout) [ $# -ge 2 ] || die 2 "--timeout needs minutes"; timeout_min=$2; shift ;;
    --allow-install) allow_install=1 ;;
    --grant) [ $# -ge 2 ] || die 2 "--grant needs a path or glob"; grants="${grants:+$grants
}$2"; shift ;;
    --quiet) quiet=1 ;;
    *) die 2 "unknown argument: $1 (see agent.sh --help)" ;;
  esac
  shift
done

case " $ROLES " in *" $role "*) ;; *) die 2 "--role must be one of: $ROLES" ;; esac
[ -n "$brief" ] && [ -r "$brief" ] || die 2 "--brief: cannot read ${brief:-(none)}"
[ -n "$out" ] || die 2 "--out is required"
[ -d "$dir" ] || die 2 "--cwd: not a directory: $dir"
[[ $timeout_min =~ ^[1-9][0-9]*$ ]] || die 2 "--timeout must be whole minutes"
budget=${budget:-$(budget_of "$role")}
[[ $budget =~ ^[0-9]+(\.[0-9]+)?$ ]] || die 2 "--budget must be a number of USD"
[ -z "$resume" ] || [[ $resume =~ ^[A-Za-z0-9-]+$ ]] || die 2 "--resume: not a session id"
model=$(model_of "$role")
[ -n "$model" ] || die 3 "no model for $role: set AGENT_$(printf '%s' "$role" | tr a-z A-Z)_MODEL in $cfg"
route=$(route_of "$role")
[[ $route =~ ^[a-z0-9][a-z0-9-]{0,39}$ ]] || die 3 "bad route name for $role: '$route'"
runner=$(runner_of "$route")
# A Codex worker follows the project's Claude Code permission rules through codex-policy.mjs;
# a project whose rules it cannot follow gets the role's fallback route instead.
if [ "$runner" = codex ] && [ -d "$dir" ]; then
  command -v node >/dev/null 2>&1 || die 3 "node not found on PATH (needed for the Codex worker policy)"
  if ! why=$(node "$HERE/codex-policy.mjs" check "$dir" 2>&1); then
    route=$(role_cfg "$role" FALLBACK_ROUTE)
    route=${route:-${CFG_WORKER_ROUTE:-anthropic}}
    [ "$(runner_of "$route")" = claude ] || route=anthropic
    model=$(role_cfg "$role" FALLBACK_MODEL)
    model=${model:-sonnet}
    runner=claude
    printf 'agent.sh: %s; this %s runs on route %s (%s) instead\n' "$why" "$role" "$route" "$model" >&2
  fi
fi
# The budget is in real dollars; Claude Code counts in Opus dollars (see PRICES). Without a
# price for the model the budget is passed as it is.
factor=$(cc_factor "$model")
if [ -n "$factor" ]; then cc_budget=$(awk -v b="$budget" -v f="$factor" 'BEGIN { printf "%.2f", b * f }')
else cc_budget=$budget; fi
WORKER_DIR=$(route_dir "$route")
if [ "$runner" = codex ]; then
  command -v codex >/dev/null 2>&1 || die 3 "codex not found on PATH (route $route)"
  [ -f "$WORKER_DIR/auth.json" ] ||
    die 3 "route $route is not logged in: run CODEX_HOME='$WORKER_DIR' codex login (once, in a terminal)"
else
  [ -f "$WORKER_DIR/settings.json" ] ||
    die 3 "$WORKER_DIR/settings.json missing (the config of route $route): run /configure"
fi
schema=$HERE/schemas/$role.json
[ -r "$schema" ] && [ -r "$HERE/roles/common.md" ] && [ -r "$HERE/roles/$role.md" ] ||
  die 3 "missing $schema, roles/common.md or roles/$role.md"
[ "$runner" = codex ] || command -v claude >/dev/null 2>&1 || die 3 "claude not found on PATH"
command -v python3 >/dev/null 2>&1 || die 3 "python3 not found on PATH (needed for the worker slots)"
[ -r "$HERE/slots.py" ] || die 3 "missing $HERE/slots.py (the worker-slot store)"

dir=$(cd "$dir" && pwd -P)
# A tester proves the change on a settled tree: not while a developer works in it.
if [ "$role" = tester ]; then
  for f in "$REGISTRY"/*.tsv; do
    [ -f "$f" ] || continue
    IFS=$'\t' read -r p _ n r _ d _ _ <"$f" || continue
    if [ "$r" = developer ] && [ "$d" = "$dir" ] && kill -0 "$p" 2>/dev/null; then
      die 2 "developer $n is still working in $dir: start the tester when it has finished"
    fi
  done
fi
mkdir -p "$out"
out=$(cd "$out" && pwd -P)
name=${name:-$role-$(date +%H%M%S)}
[[ $name =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || die 2 "--name: letters, digits, . _ - (at most 64)"
[ ! -e "$out/$name.jsonl" ] || die 2 "--name $name is taken in $out: give another"
! find_worker "$name" || die 2 "a worker named $name is running already: give another --name"
# A Codex session id is Codex's own: known once the worker has started (its init line).
if [ "$runner" = codex ]; then session=${resume:-}; else session=${resume:-$(uuidgen | tr 'A-Z' 'a-z')}; fi

log=$out/$name.jsonl err=$out/$name.err result=$out/$name.result.json
events=$out/events.log runfile=$out/$name.pid
cp "$brief" "$out/$name.brief.md"
: >"$log"
: >"$err"
touch "$events"
rm -f "$out/$name.steer.msg" "$out/$name.stop" "$out/$name.timed-out"
# The worker's standing instructions: the rules every worker follows, then its role's.
prompt=$out/$name.system.md
common=$(cat "$HERE/roles/common.md")
{ printf '%s\n\n' "${common//@ASK_SH@/$HERE/ask.sh}"; cat "$HERE/roles/$role.md"
  [ "$runner" != codex ] || cat "$HERE/roles/codex.md"; } >"$prompt"

[ -x "$guard" ] && [ -x "$push_guard" ] || die 3 "missing $guard or $push_guard"
hooks=$(worker_settings "$role" "$dir" "$out" "$allow_install") || die 3 "could not build the worker settings"

# The OS sandbox confines Bash and its children; the file tools are held by worker-guard.sh
# (physical path check) and the Read deny rules. bypassPermissions is used because those layers,
# not the mode, keep the worker in scope.
if bypass_disabled "$dir"; then mode=acceptEdits; else mode=bypassPermissions; fi
# Permission prompts (a project's ask rules, a hook that asks, a command outside the allowed
# ones) go to approve-mcp.mjs: granted files pass, other file edits go to the commander,
# the rest is refused.
node_bin=$(command -v node) || die 3 "node not found on PATH (needed for the approval tool)"
mcp=$(jq -nc --arg n "$node_bin" --arg s "$HERE/approve-mcp.mjs" \
  '{mcpServers: {approver: {type: "stdio", command: $n, args: [$s]}}}')
args=(-p --model "$model" --output-format stream-json --verbose
  --permission-mode "$mode" --strict-mcp-config --mcp-config "$mcp"
  --permission-prompt-tool mcp__approver__approve --settings "$hooks"
  --append-system-prompt-file "$prompt" --json-schema "$(cat "$schema")"
  --max-budget-usd "$cc_budget")
# shellcheck disable=SC2207 # tool names have no spaces
denied=($(denied_of "$role"))
args+=(--disallowedTools "${denied[@]}")
if [ "$mode" = acceptEdits ]; then
  allowed=()
  # A rule is a tool name or Bash(...), which may hold spaces: Bash(git status:*).
  while IFS= read -r rule; do allowed+=("$rule"); done < <(allowed_of "$role" | grep -oE 'Bash\([^)]*\)|[A-Za-z]+')
  args+=(--allowedTools "${allowed[@]}")
fi
if [ "$runner" = codex ]; then
  codex_home "$WORKER_DIR"
  strict=$out/$name.schema.json
  jq -f "$HERE/lib/strict-schema.jq" "$schema" >"$strict" || die 3 "could not make the strict schema of $role"
  read_denies=$(node "$HERE/codex-policy.mjs" read-denies "$dir") || die 3 "could not read the project's permission rules"
  AGENT_NAME_V=$name
  cxargs=(--json --skip-git-repo-check --dangerously-bypass-hook-trust --output-schema "$strict" -m "$model")
  while IFS= read -r kv; do cxargs+=(-c "$kv"); done < <(codex_run_config "$role" "$dir" "$out" "$allow_install" "$read_denies")
  AGENT_ALLOWED_V=""
  if [ "$mode" = acceptEdits ]; then AGENT_ALLOWED_V=$(allowed_of "$role" | grep -oE 'Bash\([^)]*\)'); fi
fi

queued_started=$(date +%s)
rc=0

# Registry of running workers (agent.sh ps, steer, answer, the status line): one file per run,
# keyed by this script's pid, removed when it ends. Written before admission, so a run queued
# for a slot can be found (and stopped) while it waits.
mkdir -p "$REGISTRY"
entry=$REGISTRY/$$.tsv
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$$" "$queued_started" "$name" "$role" "$model" "$dir" "$log" "$out" >"$entry"
: >"$runfile"
lease='' lease_held=0 acq_pid='' seg_pid=''
cleanup() { # idempotent: runs from the traps and at exit; releases the lease if we still hold it
  rm -f "$entry" "$runfile" "$out/$name.queued"
  if [ "$lease_held" = 1 ]; then
    python3 -I "$HERE/slots.py" release --state-dir "$STATE_DIR" --lease "$lease" \
      --owner-pid "$$" >/dev/null 2>&1 || true
    lease_held=0
  fi
  return 0
}
on_signal() { # INT/TERM: stop the acquisition/worker child, wait for it, then release
  local n=0
  if [ -n "$acq_pid" ]; then kill "$acq_pid" 2>/dev/null || true; fi
  if [ -n "$seg_pid" ]; then
    kill "$seg_pid" 2>/dev/null || true
    pkill -TERM -P "$seg_pid" 2>/dev/null || true
  fi
  kill_worker "$runfile"
  if [ -n "$seg_pid" ]; then
    while kill -0 "$seg_pid" 2>/dev/null && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
  fi
  cleanup
  exit 130
}
trap cleanup EXIT
trap on_signal INT TERM

# slot_final <status> <run_status>: the report of a run that never started a model (a queue
# timeout, or a stop that landed before admission): the result file and the normal last line.
slot_final() {
  jq -n --arg s "$2" '{run_status: $s}' >"$result"
  printf '%s %s turns=0 time=%ss result=%s session=-\n' \
    "$name" "$1" "$(( $(date +%s) - queued_started ))" "$result"
}

# Admission: one slot for the whole run, every steering segment included, held until the
# worker has exited. The waiting line goes to stderr even with --quiet.
: >"$out/$name.queued"
arc=0
python3 -I "$HERE/slots.py" acquire --state-dir "$STATE_DIR" --max-workers "$MAX_WORKERS" \
  --wait-seconds "$SLOT_WAIT_SECONDS" --owner-pid "$$" --name "$name" \
  --stop-file "$out/$name.stop" >"$out/$name.lease" &
acq_pid=$!
wait "$acq_pid" || arc=$?
acq_pid=''
case $arc in
  0)
    lease=$(cat "$out/$name.lease"); lease=${lease#lease }; lease_held=1
    # A stop may land between admission and the first launch; AGENT_TEST_PAUSE_AFTER_ACQUIRE
    # (a test hook) holds the admitted run there until that file exists.
    while :; do
      if [ -f "$out/$name.stop" ]; then
        python3 -I "$HERE/slots.py" release --state-dir "$STATE_DIR" --lease "$lease" \
          --owner-pid "$$" >/dev/null 2>&1 || true
        lease_held=0
        rm -f "$out/$name.stop"
        slot_final stopped stopped-before-admission
        exit 6
      fi
      if [ -z "${AGENT_TEST_PAUSE_AFTER_ACQUIRE:-}" ] || [ -e "$AGENT_TEST_PAUSE_AFTER_ACQUIRE" ]; then break; fi
      sleep 0.2
    done
    ;;
  6) rm -f "$out/$name.stop"; slot_final stopped stopped-before-admission; exit 6 ;;
  7) slot_final slot-timeout slot-timeout; exit 7 ;;
  *) die 3 "could not acquire a worker slot (slots.py exit $arc)" ;;
esac
rm -f "$out/$name.queued"

# Another run may have claimed this name while we waited for a slot.
for f in "$REGISTRY"/*.tsv; do
  [ -f "$f" ] || continue
  if [ "$f" != "$entry" ]; then
    IFS=$'\t' read -r p s n r m d l o <"$f" || continue
    if [ "$n" = "$name" ] && kill -0 "$p" 2>/dev/null; then
      die 2 "a worker named $name started while waiting for a slot: give another --name"
    fi
  fi
done

started=$(date +%s)
started_iso=$(date '+%Y-%m-%dT%H:%M:%S')

# Watchdog: ends the worker after the timeout; stops by itself when the run ends.
(
  n=0 limit=$((timeout_min * 60))
  while [ -f "$runfile" ]; do
    if [ "$n" -ge "$limit" ]; then
      : >"$out/$name.timed-out"
      emit "$events" TIMEOUT "$name" "ended after $timeout_min min"
      kill_worker "$runfile"
      exit 0
    fi
    sleep 5
    n=$((n + 5))
  done
) </dev/null >/dev/null 2>&1 &
wd=$!

[ "$quiet" = 1 ] || printf '[%s] %s (%s) started in %s\n' "$name" "$role" "$model" "$dir"
if [ "$quiet" = 1 ]; then pr=0; else pr=1; fi
follow_log "$log" "$runfile" "$name" "$started" "$events" "$pr" &
fp=$!

# The worker runs in segments: the brief, then one more for each steering message (the same
# session, resumed, with the message as the next prompt).
seg=0 input=$out/$name.brief.md
while :; do
  if [ "$seg" = 0 ] && [ -z "$resume" ]; then sarg=(--session-id "$session"); else sarg=(--resume "$session"); fi
  if [ "$runner" = codex ] && [ "$seg" -gt 0 ] && [ -z "$session" ]; then
    # steering a Codex worker that ended before it reported its session: nothing to resume
    break
  fi
  ready=$out/$name.ready-$seg
  rm -f "$ready"
  (
    # The parent binds this child to the slot lease before it may call Claude; until then it
    # must not start, and it exits when the run ends or the wrapper disappears ($$ is this
    # script's pid even inside the subshell; $PPID would be the grandparent).
    while [ ! -e "$ready" ]; do
      if [ -f "$out/$name.stop" ]; then exit 6; fi
      if ! kill -0 "$$" 2>/dev/null; then exit 3; fi
      sleep 0.1
    done
    # AGENT_TEST_PAUSE_AFTER_GATE (a test hook): the child touches <file>.reached, then holds
    # after the gate opens and before its last stop check until <file> exists.
    if [ -n "${AGENT_TEST_PAUSE_AFTER_GATE:-}" ]; then
      : >"$AGENT_TEST_PAUSE_AFTER_GATE.reached"
      while [ ! -e "$AGENT_TEST_PAUSE_AFTER_GATE" ]; do sleep 0.1; done
    fi
    cd "$dir"
    # The worker's CLI starts from an empty environment (env -i): a short allowlist, the names
    # of AGENT_WORKER_ENV, and the values computed here. The route's settings.json is the only
    # source of the endpoint and the key: nothing the commander's environment holds (a
    # gateway URL, API keys, forge tokens, cloud credentials) reaches the worker or its Bash.
    worker_env=() seen_names=""
    IFS=' ' read -r -a extra_names <<<"$WORKER_ENV_NAMES" || true
    for v in HOME USER LOGNAME SHELL PATH TMPDIR LANG LC_ALL LC_CTYPE LC_MESSAGES TERM TZ \
      __CF_USER_TEXT_ENCODING XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_STATE_HOME \
      HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy ALL_PROXY all_proxy \
      NODE_EXTRA_CA_CERTS SSL_CERT_FILE SSL_CERT_DIR ${extra_names[@]+"${extra_names[@]}"}; do
      [[ $v =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
      case " $seen_names " in *" $v "*) continue ;; esac
      seen_names="$seen_names $v"
      if [ -z "${!v+x}" ]; then continue; fi
      # A proxy value with credentials (user:pass@host, with or without a scheme) passes only
      # when AGENT_WORKER_ENV names it.
      case $v in
        HTTP_PROXY | HTTPS_PROXY | ALL_PROXY | http_proxy | https_proxy | all_proxy)
          pv=${!v}
          if [[ $pv =~ ^[A-Za-z][A-Za-z0-9+.-]*:// ]]; then pv=${pv#"${BASH_REMATCH[0]}"}; fi
          pv=${pv%%/*}
          if [[ $pv == *@* ]] && ! [[ " ${extra_names[*]:-} " == *" $v "* ]]; then continue; fi
          ;;
      esac
      worker_env+=("$v=${!v}")
    done
    worker_env+=(WAW_HOME="$AS_HOME" AGENT_ROLE="$role" AGENT_NAME="$name" AGENT_SCOPE="$dir"
      AGENT_RUN_DIR="$out" AGENT_EVENTS="$events" AGENT_ALLOW_INSTALL="$allow_install"
      AGENT_GRANTS="$grants" BASH_DEFAULT_TIMEOUT_MS=600000 BASH_MAX_TIMEOUT_MS=1800000
      MCP_TOOL_TIMEOUT=600000)
    # A project's stop-time checks (CLAUDE_CHECKS, a project's stop-check hook) keep
    # a session working until the changed files are green: only a developer can act on that;
    # the others would spend their turns on it (and see other workers' unfinished changes).
    [ "$role" = developer ] || worker_env+=(CLAUDE_CHECKS=off)
    if [ "$role" = developer ] && [ -n "${CLAUDE_CHECKS+x}" ]; then worker_env+=("CLAUDE_CHECKS=$CLAUDE_CHECKS"); fi
    if [ -f "$out/$name.stop" ]; then exit 6; fi
    if [ "$runner" = codex ]; then
      worker_env+=(CODEX_HOME="$WORKER_DIR" AGENT_BYPASS_DISABLED="$([ "$mode" = acceptEdits ] && echo 1 || echo 0)"
        AGENT_ALLOWED="$AGENT_ALLOWED_V")
      set -o pipefail
      if [ "$seg" = 0 ] && [ -z "$resume" ]; then
        env -i "${worker_env[@]}" codex exec "${cxargs[@]}" - <"$input" 2>>"$err" | jq -n --unbuffered -c -f "$HERE/lib/codex-stream.jq" >>"$log"
      else
        env -i "${worker_env[@]}" codex exec resume "${cxargs[@]}" "$session" - <"$input" 2>>"$err" | jq -n --unbuffered -c -f "$HERE/lib/codex-stream.jq" >>"$log"
      fi
      exit $?
    fi
    worker_env+=(CLAUDE_CONFIG_DIR="$WORKER_DIR")
    exec env -i "${worker_env[@]}" claude "${args[@]}" "${sarg[@]}" <"$input" >>"$log" 2>>"$err"
  ) &
  pid=$!
  seg_pid=$pid
  if ! python3 -I "$HERE/slots.py" bind --state-dir "$STATE_DIR" --lease "$lease" \
      --owner-pid "$$" --child-pid "$pid"; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    if [ -f "$out/$name.stop" ]; then break; fi
    die 3 "could not bind the worker child to its slot lease"
  fi
  printf '%s\n' "$pid" >"$runfile"
  # AGENT_TEST_PAUSE_BEFORE_GATE (a test hook): hold the bound, gated child there until the
  # file exists, so a test can kill the wrapper in that window.
  if [ -n "${AGENT_TEST_PAUSE_BEFORE_GATE:-}" ]; then
    while [ ! -e "$AGENT_TEST_PAUSE_BEFORE_GATE" ] && [ ! -f "$out/$name.stop" ]; do
      sleep 0.1
    done
  fi
  : >"$ready"
  rc=0
  wait "$pid" || rc=$?
  if [ "$runner" = codex ] && [ -z "$session" ]; then
    session=$(jq -r 'select(.type == "system" and .subtype == "init") | .session_id // empty' "$log" 2>/dev/null | head -n 1)
  fi
  [ ! -f "$out/$name.stop" ] && [ ! -f "$out/$name.timed-out" ] || break
  if [ -f "$out/$name.steer.msg" ]; then
    seg=$((seg + 1))
    input=$out/$name.steer-$seg.md
    {
      printf 'Message from the commander. Your previous step was interrupted to deliver it; a command you were running was stopped and may need to be run again.\n\n'
      cat "$out/$name.steer.msg"
      printf '\nTake this into account and continue the brief from where you are. Finish with the report in the schema, as before.\n'
    } >"$input"
    rm -f "$out/$name.steer.msg"
    [ "$quiet" = 1 ] || printf '[%s] >> steered by the commander: %s\n' "$name" "$(sed -n 3p "$input" | cut -c1-120)"
    continue
  fi
  break
done

rm -f "$runfile"
kill "$wd" 2>/dev/null || true
wait "$wd" 2>/dev/null || true
wait "$fp" 2>/dev/null || true
if [ "$lease_held" = 1 ]; then
  # The worker has exited on every path here: the slot goes back (steering never released it).
  python3 -I "$HERE/slots.py" release --state-dir "$STATE_DIR" --lease "$lease" \
    --owner-pid "$$" >/dev/null 2>&1 || true
  lease_held=0
fi
secs=$(($(date +%s) - started))

# The proxy's model ids are unknown to Claude Code, which warns about each: not an error.
if [ -s "$err" ]; then
  grep -v -e 'claude-code:unrecognized_model' -e '^Reading additional input from stdin' -e 'dangerously-bypass-hook-trust' "$err" >"$err.tmp" || true
  mv -f "$err.tmp" "$err"
fi

# Each segment that finished wrote a result: the last one holds the report; usage is summed.
results=$(grep '"type":"result"' "$log" 2>/dev/null || true)
final=$(printf '%s\n' "$results" | grep . | tail -n 1 || true)
status=ok turns=0 tin=0 tout=0 cost=0 tunc=0 tcr=0 tcw=0
if [ -f "$out/$name.timed-out" ]; then rm -f "$out/$name.timed-out"; status=timed-out; fi
if [ -f "$out/$name.stop" ]; then rm -f "$out/$name.stop"; status=stopped; fi
rm -f "$out/$name.steer.msg"
if [ -n "$results" ]; then
  read -r turns tin tout cost tunc tcr tcw < <(printf '%s\n' "$results" | grep . | jq -rs '
    [ (map(.num_turns // 0) | add),
      (map((.usage.input_tokens // 0) + (.usage.cache_read_input_tokens // 0) + (.usage.cache_creation_input_tokens // 0)) | add),
      (map(.usage.output_tokens // 0) | add),
      (map(.total_cost_usd // 0) | add),
      (map(.usage.input_tokens // 0) | add),
      (map(.usage.cache_read_input_tokens // 0) | add),
      (map(.usage.cache_creation_input_tokens // 0) | add) ] | @tsv')
fi
[ "$runner" != codex ] || cost=sub
if [ "$status" = ok ] && [ -n "$final" ] &&
  printf '%s' "$final" | jq -e '.structured_output | type == "object"' >/dev/null 2>&1; then
  # a Codex report fills the role schema's optional fields with null (strict schema): dropped
  printf '%s' "$final" | jq 'if $cx then .structured_output | walk(if type == "object" then with_entries(select(.value != null)) else . end) else .structured_output end' \
    --argjson cx "$([ "$runner" = codex ] && echo true || echo false)" >"$result"
elif [ -n "$final" ] && [ "$status" != ok ]; then
  # Stopped or timed out after a segment finished: keep what that segment reported, marked.
  printf '%s' "$final" | jq --arg s "$status" '(.structured_output // {}) + {run_status: $s}' >"$result"
elif [ -n "$final" ]; then
  status=failed
  printf '%s' "$final" | jq '{error: ("no structured report: " + (.subtype // "unknown")), is_error, result}' >"$result"
else
  [ "$status" != ok ] || status=failed
  last=$(grep '[^[:space:]]' "$err" 2>/dev/null | tail -n 1 | cut -c1-300 || true)
  jq -n --arg why "worker ended without a result ($status, exit $rc)${last:+: $last}" '{error: $why}' >"$result"
fi

tsv=$out/runs.tsv
[ -f "$tsv" ] || printf 'started\tname\tsession\trole\tmodel\tstatus\tturns\tseconds\tin_tokens\tout_tokens\tcost_estimate_usd\tuncached_in\tcache_read\tcache_write\n' >"$tsv"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$started_iso" "$name" "${session:--}" "$role" "$model" \
  "$status" "$turns" "$secs" "$tin" "$tout" "$cost" "$tunc" "$tcr" "$tcw" >>"$tsv"

printf '%s %s turns=%s time=%ss result=%s session=%s\n' "$name" "$status" "$turns" "$secs" "$result" "${session:--}"
case $status in
  ok) exit 0 ;;
  timed-out) exit 5 ;;
  stopped) exit 6 ;;
  *) exit 4 ;;
esac
