#!/usr/bin/env bash
# stage.sh: where the time and the money of a session went.
#
#   stage.sh <stage>            mark the start of a stage now (`done` ends the last one)
#   stage.sh wait [<reason>]    mark that the session now waits for the developer
#   stage.sh resume             mark that the wait is over (the next mark ends it too)
#   stage.sh report             print the stages with their time, wait, cost and output
#                               tokens, then the totals of the session. Works without marks
#                               too: totals only.
#
# Options of every command, after it, in any order:
#   --task <slug>    the task of the mark; a mark without it takes the task of the mark
#                    before. report: only the stages of that task, and their totals.
#   --session <id>   the session; default $CLAUDE_CODE_SESSION_ID (set by Claude Code in
#                    every Bash call)
# <stage>, <slug> and <reason>: a-z, 0-9 and -, at most 40, not starting with -.
#
# Sources: the marks (<state>/stages-<session>.tsv: time, stage or @wait or @resume, cost so
# far, model time, task), the transcript of the session (when each answer was given, its
# model and tokens), and, for the time the model worked only, the last figures Claude Code
# gave the status line (<state>/cost-<session>.json). <state> is $AGENT_STATE_DIR, else
# state/ in the waw home.
# Cost is the transcript's tokens at the prices of lib/ledger.sh (prices.tsv).
# Every mark is also a ledger record: kind (stage, wait, resume), t, session, project, task,
# stage (for wait and resume: the stage they are in), reason (wait only), cost_usd_cum, and
# cost_basis: transcript (every model priced), partial (a model of the transcript has no
# price, its tokens count as 0; the report shows such a cost as ~$x.xx) or none (no
# transcript, cost_usd_cum null).
# The time of a stage is wall-clock time without the marked waits.
# Exit: 0 done, 2 usage, 3 cannot do it. Portable to macOS /bin/bash 3.2 and Linux bash 4/5.
set -euo pipefail

# shellcheck source=lib/ledger.sh
. "$(dirname "$0")/lib/ledger.sh"

die() {
  printf 'stage.sh: %s\n' "$2" >&2
  exit "$1"
}
usage() { die 2 "usage: stage.sh <stage> | wait [<reason>] | resume | report  [--task <slug>] [--session <id>]"; }
is_word() { [[ $1 =~ ^[a-z0-9][a-z0-9-]{0,39}$ ]]; }

[ $# -ge 1 ] || usage
cmd=$1
shift
is_word "$cmd" || usage
sid=${CLAUDE_CODE_SESSION_ID:-}
task='' reason=''
while [ $# -gt 0 ]; do
  case $1 in
    --task)
      [ $# -ge 2 ] && is_word "$2" || usage
      task=$2
      shift 2
      ;;
    --session)
      [ $# -ge 2 ] || usage
      sid=$2
      shift 2
      ;;
    *)
      [ "$cmd" = wait ] && [ -z "$reason" ] && is_word "$1" || usage
      reason=$1
      shift
      ;;
  esac
done
[[ $sid =~ ^[A-Za-z0-9_-]+$ ]] || die 3 "no session id (CLAUDE_CODE_SESSION_ID is not set; pass --session <id>)"
command -v jq >/dev/null 2>&1 || die 3 "jq not found"

home=${CLAUDE_CONFIG_DIR:-${CLAUDE_HOME:-$HOME/.claude}}
state=$(ledger_dir)
marks=$state/stages-$sid.tsv
snap=$state/cost-$sid.json

# snap_field <jq path>: a number from the saved status line figures, or nothing
snap_field() {
  [ -f "$snap" ] || return 0
  jq -r "$1 | if type == \"number\" then . else empty end" "$snap" 2>/dev/null || true
}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/waw.stage.XXXXXX") || die 3 "mktemp failed"
trap 'rm -rf "$tmp"' EXIT

# price_table <transcript>: {model: [input, output, cache read, 5m write, 1h write]} for the
# models of the transcript that have a price
price_table() {
  local m p
  jq -R -r -n '[inputs | fromjson? | objects | select(.type == "assistant")
      | .message.model? | strings] | unique[]' "$1" |
    while IFS= read -r m; do
      p=$(price_any "$m")
      [ -n "$p" ] || continue
      jq -n -c --arg m "$m" --arg p "$p" '{($m): ($p | split(" ") | map(tonumber))}'
    done | jq -s -c 'add // {}'
}

# transcript_cost <until-epoch>: {basis, cost, msgs: [{t, out, cost, unpriced}]} for the
# answers given up to then (a streamed answer is logged several times under one id: the
# last entry counts)
transcript_cost() {
  local file prices
  file=$(find "$home/projects/" -name "$sid.jsonl" 2>/dev/null | head -n 1) || file=''
  if [ -n "$file" ] && [ -f "$file" ] && prices=$(price_table "$file") &&
    jq -R -n -c --argjson prices "$prices" --argjson until "$1" '
      [inputs | fromjson? | objects
        | select(.type == "assistant" and (.message | type) == "object"
            and (.message.usage | type) == "object" and (.timestamp | type) == "string")
        | {id: (.message.id // .uuid),
           t: (.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601),
           model: (.message.model // ""), u: .message.usage}]
      | group_by(.id) | map(last | select(.t <= $until)
          | .u as $u
          | ($u.cache_creation | if type == "object"
              then [.ephemeral_5m_input_tokens // 0, .ephemeral_1h_input_tokens // 0]
              else [$u.cache_creation_input_tokens // 0, 0] end) as $cw
          | [$u.input_tokens // 0, $u.output_tokens // 0, $u.cache_read_input_tokens // 0,
             $cw[0], $cw[1]] as $n
          | $prices[.model] as $p
          | {t, out: $n[1],
             cost: (if $p == null then 0
               else ([range(0; 5) | $n[.] * $p[.]] | add) / 1000000 end),
             unpriced: ($p == null and ($n | add) > 0)})
      | {basis: (if any(.[]; .unpriced) then "partial" else "transcript" end),
         cost: ((map(.cost) | add // 0) * 1000000 | round / 1000000),
         msgs: .}' "$file" 2>/dev/null; then
    return 0
  fi
  echo '{"basis":"none","cost":null,"msgs":[]}'
}

if [ "$cmd" != report ]; then
  case $cmd in
    wait | resume) kind=$cmd name=@$cmd ;;
    *) kind=stage name=$cmd ;;
  esac
  now=$(date +%s)
  stage=$cmd
  if [ -f "$marks" ]; then
    [ -n "$task" ] || task=$(awk -F'\t' '{ t = $5 } END { print t }' "$marks")
  fi
  if [ "$kind" != stage ]; then
    stage=''
    [ ! -f "$marks" ] || stage=$(awk -F'\t' '$2 !~ /^@/ { s = $2 } END { if (s != "done") print s }' "$marks")
  fi
  transcript_cost "$now" >"$tmp/cost.json"
  cost=$(jq -r '.cost // empty' "$tmp/cost.json")
  basis=$(jq -r '.basis' "$tmp/cost.json")
  mkdir -p "$state" || die 3 "cannot create $state"
  printf '%s\t%s\t%s\t%s\t%s\n' "$now" "$name" "$cost" \
    "$(snap_field .cost.total_api_duration_ms)" "$task" >>"$marks" || die 3 "cannot write $marks"
  ledger_append "$(jq -n -c --arg kind "$kind" --arg t "$(ledger_now)" --arg session "$sid" \
    --arg project "$(ledger_project "$PWD")" --arg task "$task" --arg stage "$stage" \
    --arg reason "$reason" --argjson cost "${cost:-null}" --arg basis "$basis" '
    def opt: if . == "" then null else . end;
    {v: 1, kind: $kind, t: $t, session: $session, project: $project, task: ($task | opt),
     stage: ($stage | opt), reason: ($reason | opt), cost_usd_cum: $cost, cost_basis: $basis}')"
  exit 0
fi

# ------------------------------------------------------------------ report

now=$(date +%s)
# every answer of the transcript, also one stamped a moment ahead of this clock
transcript_cost 9999999999 >"$tmp/cost.json"
if [ -f "$marks" ]; then
  jq -R -s 'split("\n") | map(select(length > 0) | split("\t")
      | {t: (.[0] | tonumber), stage: .[1], api: (.[3] | tonumber? // null), task: (.[4] // "")})' \
    "$marks" >"$tmp/marks.json" || die 3 "cannot read $marks"
else
  echo '[]' >"$tmp/marks.json"
fi

jq -r -n --slurpfile cost "$tmp/cost.json" --slurpfile marks "$tmp/marks.json" \
  --argjson api_now "$(v=$(snap_field .cost.total_api_duration_ms); echo "${v:-null}")" \
  --argjson now "$now" --arg task "$task" '
  def dur: floor as $s
    | if $s >= 3600 then "\($s / 3600 | floor)h \($s % 3600 / 60 | floor)m"
      elif $s >= 60 then "\($s / 60 | floor)m \($s % 60)s"
      else "\($s)s" end;
  def usd: "$" + (. * 100 | round | tostring
      | if length < 3 then ("000" + .)[-3:] else . end | .[:-2] + "." + .[-2:]);
  def tok: if . >= 1000000 then "\(. / 100000 | round / 10)M" elif . >= 1000 then "\(. / 100 | round / 10)k" else tostring end;
  def total: add // 0;
  def waited: if length == 0 then "-" else map(.to - .from) | total | dur end;
  def line($name; $time; $waits; $api; $msgs):
    [$name, $time, ($waits | waited),
     (if $api == null then "-" else ($api | dur) end),
     (if $cost[0].basis == "none" then "-"
      else (if any($msgs[]; .unpriced) then "~" else "" end) + ([$msgs[].cost] | total | usd) end),
     ([$msgs[].out] | total | tok)] | @tsv;
  ($cost[0].msgs) as $m | ($marks[0]) as $k | ($k | length) as $len
  # a wait lasts until the mark after it, whatever that is
  | [range(0; $len) as $i | select($k[$i].stage == "@wait")
      | {at: $i, from: $k[$i].t, to: ($k[$i + 1].t // $now)}] as $waits
  # a stage runs until the next mark that is neither a wait nor a resume, else until now
  | [range(0; $len) as $i | $k[$i] as $a
      | select(($a.stage | startswith("@") | not) and $a.stage != "done"
          and ($task == "" or $a.task == $task))
      | (first(range($i + 1; $len) | select($k[.].stage | startswith("@") | not)) // $len) as $j
      | ($k[$j] // {t: $now, api: (if $api_now == null then null else $api_now end)}) as $b
      | [$waits[] | select(.at > $i and .at < $j)] as $w
      | {stage: $a.stage, waits: $w,
         time: ($b.t - $a.t - ([$w[] | .to - .from] | total)),
         api: (if $a.api != null and $b.api != null then ($b.api - $a.api) / 1000 else null end),
         msgs: [$m[] | select(.t >= $a.t and (.t < $b.t or $j == $len))]}] as $rows
  | (if ($rows | length) > 0 then
       (["STAGE", "TIME", "WAIT", "MODEL", "COST", "OUTPUT"] | @tsv),
       ($rows[] | . as $r | line($r.stage; ($r.time | dur); $r.waits; $r.api; $r.msgs))
     else empty end),
    (if $task != "" then
       line("session"; ([$rows[].time] | total | dur); [$rows[].waits[]];
         (if ($rows | length) > 0 and all($rows[]; .api != null) then [$rows[].api] | total else null end);
         [$rows[].msgs[]])
     else
       line("session";
         (if ($m | length) == 0 then "-"
          else ($m | map(.t) | min) as $lo | ($m | map(.t) | max) as $hi
            # only the part of a wait between the first and the last answer
            | $hi - $lo - ([$waits[] | [([.to, $hi] | min) - ([.from, $lo] | max), 0] | max] | total)
            | dur end);
         $waits; (if $api_now == null then null else $api_now / 1000 end); $m)
     end)
  ' >"$tmp/table.tsv" || die 3 "could not build the report"

while IFS=$'\t' read -r a b c d e f; do
  printf '%-12s %10s %10s %10s %9s %8s\n' "$a" "$b" "$c" "$d" "$e" "$f"
done <"$tmp/table.tsv"

echo
echo "COST is priced from the transcript of the session (prices.tsv)."
echo "TIME excludes marked waits (WAIT); MODEL is the time the model worked, from the status line."
[ -f "$marks" ] || echo "No stages were marked in this session: totals only."
case $(jq -r .basis "$tmp/cost.json") in
  none) echo "Cost is not known: no transcript of this session was found." ;;
  partial) echo "~ marks a cost without the models that have no price: their tokens count as 0." ;;
esac
