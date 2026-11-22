#!/usr/bin/env bash
# stage.sh: where the time and the money of a session went.
#
#   stage.sh <stage>     mark the start of a stage now (a-z, 0-9 and -; `done` ends the last one)
#   stage.sh report      print the stages with their time, cost and output tokens, then the
#                        totals of the session. Works without marks too: totals only.
#
# The session is $CLAUDE_CODE_SESSION_ID (set by Claude Code in every Bash call), or
# --session <id> as the last arguments.
# Sources: the marks (state/stages-<session>.tsv), the transcript of the session (when each
# answer was given, its output tokens), and the last figures Claude Code gave the status
# line (state/cost-<session>.json: cost in USD, time the model worked). The cost needs a
# status line that saves them; without one the report shows time and tokens only.
# The time of a stage is wall-clock time and includes waiting for the developer.
# Exit: 0 done, 2 usage, 3 cannot do it. Portable to macOS /bin/bash 3.2 and Linux bash 4/5.
set -euo pipefail

die() {
  printf 'stage.sh: %s\n' "$2" >&2
  exit "$1"
}
usage() { die 2 "usage: stage.sh <stage> | report  [--session <id>]"; }

[ $# -ge 1 ] || usage
cmd=$1
shift
sid=${CLAUDE_CODE_SESSION_ID:-}
if [ "${1:-}" = --session ]; then
  [ $# -eq 2 ] || usage
  sid=$2
elif [ $# -ne 0 ]; then
  usage
fi
[[ $sid =~ ^[A-Za-z0-9_-]+$ ]] || die 3 "no session id (CLAUDE_CODE_SESSION_ID is not set; pass --session <id>)"
command -v jq >/dev/null 2>&1 || die 3 "jq not found"

home=${CLAUDE_CONFIG_DIR:-${CLAUDE_HOME:-$HOME/.claude}}
state=${AGENT_STATE_DIR:-${WAW_HOME:-$home/waw}/state}
marks=$state/stages-$sid.tsv
snap=$state/cost-$sid.json

# snap_field <jq path>: a number from the saved status line figures, or nothing
snap_field() {
  [ -f "$snap" ] || return 0
  jq -r "$1 | if type == \"number\" then . else empty end" "$snap" 2>/dev/null || true
}

if [ "$cmd" != report ]; then
  [[ $cmd =~ ^[a-z0-9][a-z0-9-]{0,39}$ ]] || usage
  mkdir -p "$state" || die 3 "cannot create $state"
  printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$cmd" "$(snap_field .cost.total_cost_usd)" \
    "$(snap_field .cost.total_api_duration_ms)" >>"$marks" || die 3 "cannot write $marks"
  exit 0
fi

# ------------------------------------------------------------------ report

transcript=$(find "$home/projects/" -name "$sid.jsonl" 2>/dev/null | head -n 1) || transcript=""
tmp=$(mktemp -d "${TMPDIR:-/tmp}/waw.stage.XXXXXX") || die 3 "mktemp failed"
trap 'rm -rf "$tmp"' EXIT

# one line per answer of the model: when, output tokens (a streamed answer is logged several
# times under one id: the last entry counts)
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
  jq -c 'select(.type == "assistant" and (.message.usage | type) == "object" and (.timestamp | type) == "string")
         | {id: (.message.id // .uuid),
            t: (.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601),
            out: (.message.usage.output_tokens // 0)}' "$transcript" 2>/dev/null |
    jq -s 'group_by(.id) | map(last)' >"$tmp/msgs.json" || echo '[]' >"$tmp/msgs.json"
else
  echo '[]' >"$tmp/msgs.json"
fi
if [ -f "$marks" ]; then
  jq -R -s 'split("\n") | map(select(length > 0) | split("\t")
      | {t: (.[0] | tonumber), stage: .[1], cost: (.[2] | tonumber? // null), api: (.[3] | tonumber? // null)})' \
    "$marks" >"$tmp/marks.json"
else
  echo '[]' >"$tmp/marks.json"
fi
if [ -f "$snap" ]; then cp "$snap" "$tmp/snap.json"; else echo 'null' >"$tmp/snap.json"; fi

jq -r -n --slurpfile msgs "$tmp/msgs.json" --slurpfile marks "$tmp/marks.json" \
  --slurpfile snap "$tmp/snap.json" --argjson now "$(date +%s)" '
  def dur: floor as $s
    | if $s >= 3600 then "\($s / 3600 | floor)h \($s % 3600 / 60 | floor)m"
      elif $s >= 60 then "\($s / 60 | floor)m \($s % 60)s"
      else "\($s)s" end;
  def usd: if . == null then "-" else "$" + (. * 100 | round | tostring
      | if length < 3 then ("000" + .)[-3:] else . end | .[:-2] + "." + .[-2:]) end;
  def tok: if . >= 1000000 then "\(. / 100000 | round / 10)M" elif . >= 1000 then "\(. / 100 | round / 10)k" else tostring end;
  ($msgs[0]) as $m | ($marks[0]) as $k | ($snap[0]) as $s
  | ($s.cost.total_cost_usd? // null) as $cost_now
  | ($s.cost.total_api_duration_ms? // null) as $api_now
  # each mark with the mark that ends it; the last one runs until now
  | [range(0; $k | length) as $i | $k[$i] as $a
      | select($a.stage != "done")
      | ($k[$i + 1] // {t: $now, cost: $cost_now, api: $api_now}) as $b
      | {stage: $a.stage,
         wall: ($b.t - $a.t),
         cost: (if $a.cost != null and $b.cost != null then $b.cost - $a.cost else null end),
         api: (if $a.api != null and $b.api != null then ($b.api - $a.api) / 1000 else null end),
         out: ([$m[] | select(.t >= $a.t and .t < $b.t) | .out] | add // 0)}] as $rows
  | (if ($rows | length) > 0 then
       (["STAGE", "TIME", "MODEL", "COST", "OUTPUT"] | @tsv),
       ($rows[] | [.stage, (.wall | dur), (if .api == null then "-" else (.api | dur) end), (.cost | usd), (.out | tok)] | @tsv)
     else empty end),
    (["session",
      (if ($s.cost.total_duration_ms? // null) != null then ($s.cost.total_duration_ms / 1000 | dur)
       elif ($m | length) > 0 then (($m | map(.t) | max) - ($m | map(.t) | min) | dur) else "-" end),
      (if $api_now == null then "-" else ($api_now / 1000 | dur) end),
      ($cost_now | usd),
      ([$m[].out] | add // 0 | tok)] | @tsv)
  ' >"$tmp/table.tsv" || die 3 "could not build the report"

while IFS=$'\t' read -r a b c d e; do
  printf '%-12s %10s %10s %9s %8s\n' "$a" "$b" "$c" "$d" "$e"
done <"$tmp/table.tsv"

echo
echo "TIME is wall-clock time and includes waiting for you; MODEL is the time the model worked."
[ -f "$marks" ] || echo "No stages were marked in this session: totals only."
if [ ! -f "$snap" ]; then
  echo "Cost is not known: Claude Code gives it to the status line only, and this session's"
  echo "status line does not save it (the project may use its own)."
fi
