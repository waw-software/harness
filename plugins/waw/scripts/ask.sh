#!/usr/bin/env bash
# ask.sh: a worker asks the commander a question and waits for the answer.
#
#   ask.sh "<question>" [--option "<text>"]... [--recommend "<text>"]
#                                  [--wait <minutes>]
#
# Writes the question to <run dir>/<name>.questions/q<n>.question.json, raises a QUESTION
# event for the commander (events.log), and waits (default 8 minutes, at most 9) for
# q<n>.answer.txt, which `agent.sh answer` writes. Prints the answer, or, when none comes in
# time, tells the worker to go on with its recommendation. Always exits 0 except on misuse,
# so the worker does not retry. Needs AGENT_NAME and AGENT_RUN_DIR (set by agent.sh run).
set -euo pipefail

usage() {
  echo 'usage: ask.sh "<question>" [--option "<text>"]... [--recommend "<text>"] [--wait <minutes>]' >&2
  exit 2
}

[ $# -ge 1 ] || usage
question=$1
shift
options=() recommend="" wait_min=8
while [ $# -gt 0 ]; do
  case $1 in
    --option) [ $# -ge 2 ] || usage; options+=("$2"); shift ;;
    --recommend) [ $# -ge 2 ] || usage; recommend=$2; shift ;;
    --wait) [ $# -ge 2 ] || usage; wait_min=$2; shift ;;
    *) usage ;;
  esac
  shift
done
[ -n "${question// /}" ] || usage
[[ $wait_min =~ ^[0-9]+$ ]] || usage
[ "$wait_min" -le 9 ] || wait_min=9
[ "$wait_min" -ge 1 ] || wait_min=1

if [ -z "${AGENT_NAME:-}" ] || [ -z "${AGENT_RUN_DIR:-}" ] || [ ! -d "${AGENT_RUN_DIR:-/nonexistent}" ]; then
  echo "No commander to ask in this session. Decide yourself${recommend:+ (your recommendation: $recommend)} and list the question and your choice under concerns."
  exit 0
fi

qdir=$AGENT_RUN_DIR/$AGENT_NAME.questions
mkdir -p "$qdir"
n=1
while [ -e "$qdir/q$n.question.json" ]; do n=$((n + 1)); done
id=q$n
if [ ${#options[@]} -gt 0 ]; then
  opts=$(printf '%s\n' "${options[@]}" | jq -R . | jq -s .)
else
  opts='[]'
fi
jq -n --arg id "$id" --arg name "$AGENT_NAME" --arg q "$question" --argjson o "$opts" --arg r "$recommend" \
  --arg at "$(date '+%Y-%m-%dT%H:%M:%S')" \
  '{id: $id, worker: $name, question: $q, options: $o, recommend: $r, asked: $at}' >"$qdir/$id.question.json"

events=${AGENT_EVENTS:-$AGENT_RUN_DIR/events.log}
line="$id: $(printf '%s' "$question" | tr '\n\t' '  ')"
[ ${#options[@]} -eq 0 ] || line="$line | options: $(printf '%s / ' "${options[@]}" | sed 's| / $||' | tr '\n\t' '  ')"
[ -z "$recommend" ] || line="$line | recommends: $(printf '%s' "$recommend" | tr '\n\t' '  ')"
line="$line | reply: agent.sh answer $AGENT_NAME $id \"...\""
printf '%s QUESTION %s: %s\n' "$(date +%H:%M:%S)" "$AGENT_NAME" "$line" >>"$events"

deadline=$(($(date +%s) + wait_min * 60))
while [ "$(date +%s)" -lt "$deadline" ]; do
  if [ -f "$qdir/$id.answer.txt" ]; then
    echo "ANSWER from the commander to $id:"
    cat "$qdir/$id.answer.txt"
    echo
    echo "Go on with this answer. Mention the question and the answer in your report (concerns or summary)."
    exit 0
  fi
  sleep 2
done

: >"$qdir/$id.timeout"
printf '%s QUESTION-TIMEOUT %s: %s went unanswered for %s min; the worker goes on with its recommendation\n' \
  "$(date +%H:%M:%S)" "$AGENT_NAME" "$id" "$wait_min" >>"$events"
echo "NO ANSWER to $id within $wait_min minutes. Do not ask it again. Go on with your recommendation${recommend:+ ($recommend)} and list the question and your choice under concerns."
exit 0
