#!/usr/bin/env bash
# retro.sh: what past runs cost and where they went wrong, from the ledger. Reads only.
#
#   retro.sh [--since YYYY-MM-DD] [--until YYYY-MM-DD] [--project <name> | --all]
#            [--task <slug>] [--ledger <file>]
#
#   --since <date>     the first day of the period; default: 6 days before its last day
#   --until <date>     the last day of the period; default: today. Without --since and
#                      --until the period is the last 7 days.
#   --project <name>   only the records of this project
#   --all              the records of every project; not with --project
#                      With neither: in a project directory (a CLAUDE.md or AGENTS.md at the
#                      repository root or in the current directory) only that project (its
#                      name: ledger_project of lib/ledger.sh), elsewhere every project. The
#                      first line says which.
#   --task <slug>      only the records of this task
#   --ledger <file>    the ledger; default: that of lib/ledger.sh. The records in ledger.d/
#                      next to it are read too.
#
# Prints: the runs per role and model (interrupted: a run-start without a run, or a run with
# that status; failed: any other status than ok; fix runs: names ending in -fix<n>; ~ marks
# a cost without the runs that have no price, sub a cost of subscription runs only), the fix
# runs per developer slice (a slice: project, task and name without -fix<n>), the events and
# the most frequent BLOCKED texts (without the "PreToolUse:<tool> hook error: [<hook>]: "
# prefix, cut at 100 characters), the commander's stages, and the total cost.
# The records of smoke.sh (project agentic-smoke.<suffix>) are not in the runs, slices,
# events or worker costs; without a project filter a last line counts its runs. They still
# count as records of the session that started them.
# A stage lasts until the next stage mark of its session, the last one until the session's
# last record (a mark, or a record of a run it started). Its cost is the difference of the
# commander's cost at the marks that start and end it (~: partly priced, or the last stage's
# session went on after its last mark; -: not known).
# Period: a stage, with all its time, wait and cost, belongs to the period of its start
# mark. Runs and events are filtered by their own time. The day is the one of the record's
# own time zone.
# Exit: 0 done, 2 usage, 3 no ledger or cannot read it. Portable to macOS /bin/bash 3.2 and
# Linux bash 4/5.
set -euo pipefail

# shellcheck source=lib/ledger.sh
. "$(dirname "$0")/lib/ledger.sh"

die() {
  printf 'retro.sh: %s\n' "$2" >&2
  exit "$1"
}
usage() {
  die 2 "usage: retro.sh [--since YYYY-MM-DD] [--until YYYY-MM-DD] [--project <name> | --all] [--task <slug>] [--ledger <file>]"
}
is_day() { [[ $1 =~ ^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$ ]]; }

since='' until_day='' project='' task='' ledger='' all=''
while [ $# -gt 0 ]; do
  if [ "$1" = --all ]; then
    all=1
    shift
    continue
  fi
  [ $# -ge 2 ] && [ -n "$2" ] || usage
  case $1 in
    --since) is_day "$2" || usage; since=$2 ;;
    --until) is_day "$2" || usage; until_day=$2 ;;
    --project) project=$2 ;;
    --task) task=$2 ;;
    --ledger) ledger=$2 ;;
    *) usage ;;
  esac
  shift 2
done
[ -z "$all" ] || [ -z "$project" ] || usage
project_from=''
if [ -z "$all" ] && [ -z "$project" ]; then
  root=$(git -c core.fsmonitor=false -C "$PWD" rev-parse --show-toplevel 2>/dev/null) || root=$PWD
  for f in CLAUDE.md AGENTS.md; do
    if [ -f "$root/$f" ] || [ -f "$PWD/$f" ]; then
      project=$(ledger_project "$PWD")
      project_from=$f
      break
    fi
  done
fi
command -v jq >/dev/null 2>&1 || die 3 "jq not found"
[ -n "$ledger" ] || ledger=$(ledger_file)
[ -n "$until_day" ] || until_day=$(date +%Y-%m-%d)
[ -n "$since" ] || since=$(jq -n -r --arg u "$until_day" \
  '$u + "T12:00:00Z" | fromdateiso8601 - 6 * 86400 | strftime("%Y-%m-%d")')

files=()
[ ! -f "$ledger" ] || files+=("$ledger")
for f in "$(dirname "$ledger")"/ledger.d/*; do
  [ ! -f "$f" ] || files+=("$f")
done
[ ${#files[@]} -gt 0 ] || die 3 "no ledger: $ledger"

# shellcheck disable=SC2016 # a jq program
PROGRAM='
  def epoch:
    (.[0:19] + "Z" | fromdateiso8601) as $local
    | (capture("(?<s>[+-])(?<h>[0-9]{2}):?(?<m>[0-9]{2})$") // {s: "+", h: "00", m: "00"}) as $z
    | $local - (if $z.s == "-" then -1 else 1 end) * (($z.h | tonumber) * 3600 + ($z.m | tonumber) * 60);
  def total: add // 0;
  def clean: tostring | gsub("[[:cntrl:]]"; " ");
  def dur: floor as $s
    | if $s >= 3600 then "\($s / 3600 | floor)h \($s % 3600 / 60 | floor)m"
      elif $s >= 60 then "\($s / 60 | floor)m \($s % 60)s"
      else "\($s)s" end;
  def usd: "$" + (. * 100 | round | tostring
      | if length < 3 then ("000" + .)[-3:] else . end | .[:-2] + "." + .[-2:]);
  def fixed1: (. * 10 | round) as $n | "\($n / 10 | floor).\($n % 10)";
  def marked($approx): (if $approx then "~" else "" end) + usd;
  def in_period: .t[0:10] >= $since and .t[0:10] <= $until;
  def selected: ($project == "" or .project == $project) and ($task == "" or .task == $task);
  def is_fix: (.name // "") | test("-fix[0-9]+$");
  def smoke: (.project // "") | test("^agentic-smoke\\.");

  [inputs | fromjson? | objects
    | select((.t | type) == "string"
        and (.t | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}")))] as $all
  # a run-start whose run_id has no run record is an interrupted run
  | (reduce ($all[] | select(.kind == "run")) as $r ({}; .[$r.run_id | tostring] = true)) as $ended
  | [$all[]
      | if .kind == "run" then .
        elif .kind == "run-start" and ($ended[.run_id | tostring] | not)
        then . + {status: "interrupted"}
        else empty end
      | select(in_period and selected)] as $found
  | [$found[] | select(smoke | not)] as $runs
  | ([$found[] | select(smoke)] | length) as $smoke_runs
  | [$all[] | select(.kind == "event" and in_period and selected and (smoke | not))] as $events

  # stages: over all marks of a session, filtered only afterwards, so that a stage ends at
  # the next stage mark whatever its task or day is
  | [$all[] | . + {at: (.t | epoch)}] as $timed
  | (reduce ($timed[]
        | {s: (if .kind == "run" or .kind == "run-start" then .commander_session else .session end),
           at}
        | select(.s != null and .s != "")) as $x
      ({}; .[$x.s] = ([.[$x.s] // $x.at, $x.at] | max))) as $last
  | [$timed[] | select((.kind == "stage" or .kind == "wait" or .kind == "resume") and .session != null)]
  | group_by(.session)
  | [ .[] | sort_by(.at) as $k | ($k | length) as $len
      | range(0; $len) as $i | $k[$i] as $a
      | select($a.kind == "stage" and $a.stage != "done" and ($a | in_period and selected))
      | (first(range($i + 1; $len) | select($k[.].kind == "stage")) // null) as $j
      | (if $j == null then $last[$a.session] else $k[$j].at end) as $end
      # the cost at the mark that ends the stage, else at the last mark of the session
      | $k[$j // ($len - 1)] as $b
      # a wait lasts until the mark after it, else until the end of the stage
      | ([range($i + 1; $j // $len) | select($k[.].kind == "wait")
          | ($k[. + 1].at // $end) - $k[.].at]) as $waits
      | {stage: ($a.stage | clean), at: $a.at, work: ($end - $a.at - ($waits | total)),
         waits: ($waits | length), wait: ($waits | total),
         cost: (if $a.cost_usd_cum == null or $b.cost_usd_cum == null then null
                else $b.cost_usd_cum - $a.cost_usd_cum end),
         # an open stage that went on after the last mark has only a part of its cost
         partial: ($a.cost_basis == "partial" or $b.cost_basis == "partial"
                   or ($j == null and $end > $b.at))} ] as $stages

  | ([$stages[].cost // 0] | total) as $commander
  | (any($stages[]; .cost == null or .partial)) as $commander_approx
  | ([$runs[].cost_usd // 0] | total) as $workers
  | (any($runs[]; .cost_basis == "none")) as $workers_approx
  | [$runs[] | select(.role == "developer")] as $dev
  | ($dev | map([.project, .task, ((.name // "") | sub("-fix[0-9]+$"; ""))]) | unique | length) as $slices

  | ["text", "retro: \($since) .. \($until), " +
       (if $project == "" then "all projects"
        else "project \($project | clean)" +
          (if $project_from == "" then "" else " (from \($project_from); all projects: --all)" end)
        end)],
    ["text", ""],
    ["text", "runs"],
    ["run", "ROLE | MODEL", "RUNS", "FAILED", "INTERRUPTED", "FIX", "STEERS", "TURNS", "MINUTES",
     "USD", "COST-INCOMPLETE"],
    ($runs | group_by([.role, .model])[]
     | ["run", ("\(.[0].role) | \(.[0].model)" | clean), length,
        (map(select(.status != "ok" and .status != "interrupted")) | length),
        (map(select(.status == "interrupted")) | length),
        (map(select(is_fix)) | length),
        (map(.steers // 0) | total),
        (map(.turns // 0) | total),
        (map(.seconds // 0) | total / 60 | fixed1),
        (if all(.[]; .cost_basis == "sub") then "sub"
         else any(.[]; .cost_basis == "none") as $approx
           | map(.cost_usd // 0) | total | marked($approx) end),
        (map(select(.cost_incomplete == true)) | length)]),
    ["text", "developer slices: \($slices), fix runs per slice: " +
       (if $slices == 0 then "-" else ($dev | map(select(is_fix)) | length) / $slices | fixed1 end)],
    ["text", ""],
    ["text", "events"],
    (("BLOCKED", "FAILING", "STALLED", "TIMEOUT", "QUESTION", "QUESTION-TIMEOUT", "APPROVAL") as $type
     | ["text", "\($type) \([$events[] | select(.type == $type)] | length)"]),
    ([$events[] | select(.type == "BLOCKED") | (.text // "") | clean
       | sub("PreToolUse:[A-Za-z_]+ hook error: \\[[^]]*\\]: "; "") | .[0:100]
       | sub("\\s+$"; "")]
     | group_by(.) | map({text: .[0], n: length}) | sort_by([-.n, .text]) | .[0:5]
     | if length == 0 then empty
       else ["text", "most frequent BLOCKED:"], (.[] | ["text", "  \(.n)x \(.text)"]) end),
    ["text", ""],
    ["text", "stages"],
    ["stage", "STAGE", "COUNT", "WORK", "WAIT", "COMMANDER"],
    ($stages | group_by(.stage) | sort_by(map(.at) | min)[]
     | ["stage", .[0].stage, length,
        (map(.work) | total | dur),
        (if (map(.waits) | total) == 0 then "-" else map(.wait) | total | dur end),
        (if all(.[]; .cost == null) then "-"
         else any(.[]; .cost == null or .partial) as $approx
           | map(.cost // 0) | total | marked($approx) end)]),
    ["text", "A stage, with all its time, wait and cost, belongs to the period of its start mark."],
    ["text", ""],
    ["text", "total: \($commander + $workers | marked($commander_approx or $workers_approx))" +
       " (commander \($commander | marked($commander_approx))," +
       " workers \($workers | marked($workers_approx)))"],
    ["text", "sub runs (not in usd): \([$runs[] | select(.cost_basis == "sub")] | length)"],
    (if $project == "" and $smoke_runs > 0
     then ["text", "smoke runs (not counted): \($smoke_runs)"] else empty end)
  | map(tostring) | join("\t")
'

# awk 1: a file that does not end in a newline does not run into the next one
awk 1 "${files[@]}" |
  jq -R -n -r --arg since "$since" --arg until "$until_day" --arg project "$project" \
    --arg project_from "$project_from" --arg task "$task" "$PROGRAM" |
  while IFS= read -r line; do
    kind=${line%%$'\t'*}
    rest=${line#*$'\t'}
    # no field of a table row is empty, so read does not merge two tabs
    case $kind in
      run)
        IFS=$'\t' read -r a b c d e f g h i j < <(printf '%s\n' "$rest")
        printf '%-40s %5s %6s %11s %4s %6s %6s %8s %9s %15s\n' \
          "$a" "$b" "$c" "$d" "$e" "$f" "$g" "$h" "$i" "$j"
        ;;
      stage)
        IFS=$'\t' read -r a b c d e < <(printf '%s\n' "$rest")
        printf '%-16s %5s %10s %10s %10s\n' "$a" "$b" "$c" "$d" "$e"
        ;;
      *) printf '%s\n' "$rest" ;;
    esac
  done || die 3 "could not build the report from $ledger"
