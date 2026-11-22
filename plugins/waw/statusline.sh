#!/usr/bin/env bash
# statusline.sh: Claude Code status line. Reads the session JSON on stdin, prints one line:
#
#   Fable 5.2 high │ ▰▰▰▱▱▱▱▱▱▱ 32% 64k/200k │ 5h 41% ↻2h13m · 7d 12% │ $1.23 · 14m · +120 −30 │ feat/login* my-app │ ⬡ sandbox
#
#   model and effort │ context window │ plan limits (when Claude Code reports them) │
#   cost, session time, lines changed │ git branch (* = uncommitted changes), directory │ sandbox
#
# A part with no data is left out. Colours: context and limits turn yellow from 60 % and red
# from 85 %. In a sandbox the same JSON is passed on to sbx's own hook, so the desktop app
# keeps its session view. Never fails: with no jq or unreadable input it prints nothing.
input=$(cat 2>/dev/null)
[ -n "$input" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# The sbx desktop app reads its session info from the status line command the kit replaced.
if [ -x /usr/local/bin/sbx-claude-hook ]; then
  printf '%s' "$input" | /usr/local/bin/sbx-claude-hook claude-status >/dev/null 2>&1 &
fi

# The figures of this session, kept for /task-cost (waw/stage.sh): Claude Code
# gives the cost to the status line only.
config_dir=${CLAUDE_CONFIG_DIR:-${CLAUDE_HOME:-$HOME/.claude}}
state=${WAW_HOME:-$config_dir/waw}/state
sid=$(printf '%s' "$input" | jq -r '.session_id // empty | select(test("^[A-Za-z0-9_-]+$"))' 2>/dev/null)
if [ -n "$sid" ] && mkdir -p "$state" 2>/dev/null; then
  printf '%s' "$input" | jq -c '{session_id, cost, model: (.model.display_name? // null)}' \
    >"$state/cost-$sid.json.tmp" 2>/dev/null && mv -f "$state/cost-$sid.json.tmp" "$state/cost-$sid.json" 2>/dev/null
fi

sep=$'\037'
IFS=$sep read -r model effort ctx_pct ctx_size cost dur_ms added removed dir h5 h5_reset d7 d7_reset <<EOF
$(printf '%s' "$input" | jq -r --arg s "$sep" '
  # A field of an unexpected shape counts as missing: it must not cost the whole line.
  def get(f): try f catch null;
  def num(f): (get(f) | if type == "number" then . else empty end) // "";
  def pct(f): (get(f) | if type == "number" then floor else empty end) // "";
  def str(f): (get(f) | if type == "string" or type == "number" then . else empty end) // "";
  [ str(.model.display_name // .model.id),
    str(.effort | if type == "object" then .level else . end),
    pct(.context_window.used_percentage),
    num(.context_window.context_window_size),
    num(.cost.total_cost_usd),
    pct(.cost.total_duration_ms),
    num(.cost.total_lines_added),
    num(.cost.total_lines_removed),
    str(.workspace.current_dir // .cwd),
    pct(.rate_limits.five_hour.used_percentage),
    str(.rate_limits.five_hour.resets_at),
    pct(.rate_limits.seven_day.used_percentage),
    str(.rate_limits.seven_day.resets_at)
  ] | map(tostring) | join($s)' 2>/dev/null)
EOF

if [ -z "$effort" ] && [ -r "$config_dir/settings.json" ]; then
  effort=$(jq -r '.effortLevel // .env.CLAUDE_CODE_EFFORT_LEVEL // empty' "$config_dir/settings.json" 2>/dev/null)
fi
[ -n "$effort" ] || effort=${CLAUDE_CODE_EFFORT_LEVEL:-}

reset=$'\033[0m' dim=$'\033[2m' bold=$'\033[1m'
green=$'\033[32m' yellow=$'\033[33m' red=$'\033[31m' cyan=$'\033[36m' magenta=$'\033[35m'

# level <percent>: the colour of a usage figure
level() {
  if [ "$1" -ge 85 ]; then printf '%s' "$red"; elif [ "$1" -ge 60 ]; then printf '%s' "$yellow"; else printf '%s' "$green"; fi
}
# short <tokens>: 64000 -> 64k, 1000000 -> 1M
short() {
  if [ "$1" -ge 1000000 ]; then printf '%sM' "$(($1 / 1000000))"; elif [ "$1" -ge 1000 ]; then printf '%sk' "$(($1 / 1000))"; else printf '%s' "$1"; fi
}
# span <seconds>: 8000 -> 2h13m, 200000 -> 2d7h
span() {
  local s=$1
  if [ "$s" -ge 86400 ]; then printf '%sd%sh' "$((s / 86400))" "$((s % 86400 / 3600))"
  elif [ "$s" -ge 3600 ]; then printf '%sh%sm' "$((s / 3600))" "$((s % 3600 / 60))"
  else printf '%sm' "$((s / 60))"; fi
}
# until_reset <resets_at>: time left; the value is epoch seconds, epoch milliseconds or ISO 8601
until_reset() {
  local at=$1 now
  now=$(date +%s)
  case $at in
    '' ) return ;;
    *[!0-9]*) at=$(date -d "$at" +%s 2>/dev/null || date -j -f '%Y-%m-%dT%H:%M:%S' "${at%%[.Z+]*}" +%s 2>/dev/null) || return ;;
  esac
  [ -n "$at" ] || return
  [ "$at" -lt 100000000000 ] || at=$((at / 1000))
  [ "$at" -gt "$now" ] || return
  printf ' ↻%s' "$(span $((at - now)))"
}

parts=()

# model and effort
if [ -n "$model" ]; then
  parts+=("${bold}${cyan}${model}${reset}${effort:+ ${dim}${effort}${reset}}")
fi

# context window: a ten-cell bar, the percentage, tokens used of the window
if [ -n "$ctx_pct" ]; then
  filled=$(((ctx_pct + 5) / 10))
  [ "$filled" -le 10 ] || filled=10
  bar=""
  i=0
  while [ "$i" -lt 10 ]; do
    if [ "$i" -lt "$filled" ]; then bar="$bar▰"; else bar="$bar▱"; fi
    i=$((i + 1))
  done
  ctx="$(level "$ctx_pct")${bar} ${ctx_pct}%${reset}"
  if [ -n "$ctx_size" ]; then
    ctx="$ctx ${dim}$(short $((ctx_size * ctx_pct / 100)))/$(short "$ctx_size")${reset}"
  fi
  parts+=("$ctx")
fi

# plan limits: the five-hour and the seven-day window
limits=""
if [ -n "$h5" ]; then
  limits="$(level "$h5")5h ${h5}%${reset}${dim}$(until_reset "$h5_reset")${reset}"
fi
if [ -n "$d7" ]; then
  limits="${limits:+$limits ${dim}·${reset} }$(level "$d7")7d ${d7}%${reset}${dim}$(until_reset "$d7_reset")${reset}"
fi
[ -z "$limits" ] || parts+=("$limits")

# cost, session time, lines changed
work=""
[ -z "$cost" ] || work=$(printf '$%.2f' "$cost")
if [ -n "$dur_ms" ] && [ "$dur_ms" -ge 60000 ]; then
  work="${work:+$work ${dim}·${reset} }$(span $((dur_ms / 1000)))"
fi
if [ "${added:-0}" != 0 ] || [ "${removed:-0}" != 0 ]; then
  work="${work:+$work ${dim}·${reset} }${green}+${added:-0}${reset} ${red}−${removed:-0}${reset}"
fi
[ -z "$work" ] || parts+=("$work")

# git branch and directory
if [ -n "$dir" ]; then
  where="${dir##*/}"
  if branch=$(git -C "$dir" --no-optional-locks symbolic-ref --short -q HEAD 2>/dev/null) ||
    branch=$(git -C "$dir" --no-optional-locks rev-parse --short HEAD 2>/dev/null); then
    dirty=""
    [ -z "$(git -C "$dir" --no-optional-locks status --porcelain 2>/dev/null | head -n 1)" ] || dirty="*"
    where="${magenta}${branch}${dirty}${reset} ${where}"
  fi
  parts+=("$where")
fi

# workers running now (agent.sh), any task
agents=$(cd "$(dirname "$0")" 2>/dev/null && pwd)/scripts/agent.sh
if [ -x "$agents" ]; then
  nw=$("$agents" count 2>/dev/null || echo 0)
  case $nw in '' | 0 | *[!0-9]*) ;; 1) parts+=("${yellow}⚙ 1 worker${reset}") ;; *) parts+=("${yellow}⚙ ${nw} workers${reset}") ;; esac
fi

# sandbox name
[ -z "${SANDBOX_NAME:-}" ] || parts+=("${dim}⬡ ${SANDBOX_NAME}${reset}")

out=""
for p in "${parts[@]}"; do
  out="${out:+$out ${dim}│${reset} }$p"
done
printf '%s\n' "$out"
