# shellcheck shell=bash
# lib/ledger.sh — the one ledger contract: where it is, what a record is, how one is
# appended, and the model prices its costs come from. Sourced; bash 3.2; safe under set -u;
# defines functions only.
#
# Path: ledger_file = <ledger_dir>/ledger.jsonl; ledger_dir = $AGENT_STATE_DIR, else
# <waw_home>/state. It lives in the waw home, so it survives deleted workspaces.
# Readers read ledger.jsonl plus ledger.d/* (the records written without the lock).
#
# Record: one JSON object per line. Common fields:
#   {v:1, kind, t, project, task (slug|null)}       t: ledger_now
# Kinds and their further fields:
#   run-start          run_id, name, role, model, route, runner, session, resumed,
#                      commander_session, cwd, run_dir
#   run                the run-start fields, and status, end, seconds, turns,
#                      tokens{uncached_in, cache_read, cache_write, cache_write_5m,
#                      cache_write_1h, out}, cost_usd, cost_basis (tokens|sub|none),
#                      cost_incomplete, cost_cc, steers, segments, results
#   event              run_id, name, type, text (at most 400 characters)
#   stage, wait, resume  session, stage, reason, cost_usd_cum,
#                      cost_basis (transcript|none)
#
# Lock: mkdir <ledger_dir>/ledger.lock.d. mkdir is atomic on POSIX, works with bash 3.2 and
# gives one code path everywhere; lockf and shlock are macOS-only, and flock is absent there.
# A lock dir older than 10 s belongs to a dead writer and is removed. A writer that does not
# get the lock in LEDGER_LOCK_TRIES tries (default 100, 0.05 s apart; tests lower it)
# writes its record to a file of its own under ledger.d/.

_LEDGER_LIB_DIR=$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

waw_home() {
  local h=${WAW_HOME:-${CLAUDE_CONFIG_DIR:-${CLAUDE_HOME:-$HOME/.claude}}/waw}
  printf '%s\n' "$h" | tr -s /
}

ledger_dir() { printf '%s\n' "${AGENT_STATE_DIR:-$(waw_home)/state}"; }

ledger_file() { printf '%s/ledger.jsonl\n' "$(ledger_dir)"; }

ledger_now() { date +%Y-%m-%dT%H:%M:%S%z; }

# ledger_project <dir>: the name of the repository's main checkout (the same from each of its
# worktrees), else the name of the directory.
ledger_project() {
  local common
  if common=$(git -c core.fsmonitor=false -C "$1" rev-parse --path-format=absolute \
    --git-common-dir 2>/dev/null) && [ -n "$common" ]; then
    basename "$(dirname "$common")"
  else
    basename "$1"
  fi
}

prices_file() { printf '%s\n' "${AGENT_PRICES:-$(waw_home)/prices.tsv}"; }

# price_any <model>: "input output cache-read cache-write cache-write-1h", US dollars per 1M
# tokens, from prices_file, else from the plugin's defaults; nothing for an unknown model.
# An empty cache read or cache write is the input price, an empty 1h write twice the input.
price_any() {
  local f p
  for f in "$(prices_file)" "$_LEDGER_LIB_DIR/../../defaults/prices.tsv"; do
    [ -f "$f" ] || continue
    p=$(awk -F'\t' -v m="$1" '$1 == m && $0 !~ /^#/ {
      print $2, $3, ($4 == "" ? $2 : $4), ($5 == "" ? $2 : $5), ($6 == "" ? 2 * $2 : $6); exit }' "$f")
    if [ -n "$p" ]; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  return 0
}

_ledger_warn() { printf 'ledger: %s\n' "$*" >&2; }

# _ledger_stale <lock dir>: true when it is older than 10 s.
_ledger_stale() {
  local m
  # BSD stat, else GNU stat
  m=$(stat -f %m "$1" 2>/dev/null) || m=$(stat -c %Y "$1" 2>/dev/null) || return 1
  [[ $m =~ ^[0-9]+$ ]] || return 1
  [ $(($(date +%s) - m)) -gt 10 ]
}

# ledger_append <json record>: appends it as one line. Always returns 0: the ledger never
# fails its caller; what goes wrong is a warning on stderr.
ledger_append() {
  local line dir lock spill n=0 max=${LEDGER_LOCK_TRIES:-100}
  # -s: exactly one value, so the record cannot become several lines
  if ! printf '%s' "${1:-}" | jq -es 'length == 1 and (.[0] | type == "object" and .v == 1
      and (.kind | type == "string") and (.t | type == "string"))' >/dev/null 2>&1; then
    _ledger_warn "not a ledger record, not written"
    return 0
  fi
  if ! line=$(printf '%s' "$1" | jq -c . 2>/dev/null); then
    _ledger_warn "could not compact the record, not written"
    return 0
  fi
  dir=$(ledger_dir)
  if ! mkdir -p "$dir" 2>/dev/null; then
    _ledger_warn "cannot create $dir, record not written"
    return 0
  fi
  lock=$dir/ledger.lock.d
  while [ "$n" -lt "$max" ]; do
    if mkdir "$lock" 2>/dev/null; then
      { printf '%s\n' "$line" >>"$dir/ledger.jsonl"; } 2>/dev/null ||
        _ledger_warn "cannot write $dir/ledger.jsonl, record not written"
      rmdir "$lock" 2>/dev/null || true
      return 0
    fi
    n=$((n + 1))
    # a removed stale lock is retried at once
    if _ledger_stale "$lock" && rmdir "$lock" 2>/dev/null; then continue; fi
    sleep 0.05
  done
  if mkdir -p "$dir/ledger.d" 2>/dev/null && spill=$(mktemp "$dir/ledger.d/XXXXXX" 2>/dev/null) &&
    { printf '%s\n' "$line" >"$spill"; } 2>/dev/null; then
    _ledger_warn "no lock on $dir/ledger.jsonl, record written to $spill"
  else
    _ledger_warn "no lock and no spill file in $dir, record not written"
  fi
  return 0
}
