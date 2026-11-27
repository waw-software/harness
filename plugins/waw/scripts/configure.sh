#!/usr/bin/env bash
# configure.sh: the engine of /configure. It finds out, lists and writes; the skill asks.
#
#   configure.sh detect             what is installed and set up: Claude Code and its login, the
#                                   tools, every model source (codex, opencode, OpenRouter, nexos,
#                                   Anthropic, other gateways), the current waw config,
#                                   rules and settings. Never prints a secret.
#   configure.sh models <source> [<regex>]
#                                   the model ids a source offers, one per line:
#                                   id<TAB>name<TAB>$ per 1M input<TAB>$ per 1M output (when known).
#                                   Sources: codex, opencode, opencode-go, openrouter, nexos,
#                                   anthropic.
#                                   <regex> (extended, case-insensitive) filters the ids and names.
#   configure.sh apply <choices.json>
#                                   write the setup the developer chose (format: the configure
#                                   skill, "Choices file"); backs up what it replaces in
#                                   <home>/backups/<time>/ and prints each change.
#   configure.sh check              verify the setup: PASS, TODO (with the command that fixes it)
#                                   or FAIL per item. Exit 0 when nothing is TODO or FAIL.
#   configure.sh uninstall [--purge] [--keep-plugin]
#                                   undo what the plugin and /configure added to this config:
#                                   the rules (<config>/rules/waw/), and in settings.json the status
#                                   line, the script permissions, the attribution, model and effort
#                                   it set (back to what they were before, where you did not change
#                                   them since; a backup goes to <config>/backups/); then
#                                   `claude plugin uninstall waw@harness` and the marketplace,
#                                   unless --keep-plugin. <home> (config, worker routes and their
#                                   logins) stays for a reinstall; --purge logs the routes out and
#                                   removes it too. Keychain items and ~/worktrees are never
#                                   touched: it prints the commands for the keys.
#   configure.sh ping <provider> <model>
#                                   one tiny real call (a few tokens; on a gateway it costs a
#                                   fraction of a cent) through a worker route or a review
#                                   provider, to prove the key and the model id work.
#
# Home: WAW_HOME, default ${CLAUDE_CONFIG_DIR:-~/.claude}/waw.
# Exit: 0 done, 1 check found something to do, 2 usage, 3 cannot do it.
set -euo pipefail
unset CDPATH

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
CONFIG_DIR=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
AS_HOME=${WAW_HOME:-$CONFIG_DIR/waw}
# One spelling per dir: Claude Code keys a login's keychain entry on the exact path, so
# ".../anthropic/" or "a//b" would look logged out.
normpath() { printf '%s' "$1" | sed 's#//*#/#g; s#\(.\)/$#\1#'; }
CONFIG_DIR=$(normpath "$CONFIG_DIR")
AS_HOME=$(normpath "$AS_HOME")
APPLIED=$AS_HOME/applied.json # what apply changed in settings.json, for uninstall
ROLES="investigator developer reviewer tester"
MODEL_RE='^[A-Za-z0-9._/:@+()# -]+$'
NAME_RE='^[a-z0-9][a-z0-9-]{0,39}$'
KEYCHAIN_RE='^[A-Za-z0-9._-]{1,64}$'
NEXOS_URL=https://api.nexos.ai
OPENROUTER_URL=https://openrouter.ai/api
OPENCODE_GO_URL=https://opencode.ai/inference/go
# The scripts the commander runs without a prompt (bare names: the plugin's bin/ is on the PATH).
PERMISSIONS='Bash(agent.sh:*) Bash(attack.sh:*) Bash(task.sh:*) Bash(stage.sh:*) Bash(deliver.sh:*) Bash(retro.sh:*) EnterWorktree ExitWorktree'

die() {
  printf 'configure.sh: %s\n' "$2" >&2
  exit "$1"
}
command -v jq >/dev/null 2>&1 || die 3 "jq not found (brew install jq)"

have() { command -v "$1" >/dev/null 2>&1; }
# keychain_has <service>: the macOS keychain holds a generic password for it (never read).
keychain_has() { have security && security find-generic-password -s "$1" >/dev/null 2>&1; }
# helper_item <settings.json>: the keychain service its apiKeyHelper reads, if it is ours.
helper_item() {
  jq -r '.apiKeyHelper // ""' "$1" 2>/dev/null | sed -n 's/.*find-generic-password.* -s \([A-Za-z0-9._-]*\).*/\1/p'
}
# logged_in <config dir>: Claude Code is logged in there ("yes (<method>)" or "no").
# The default dir is asked without CLAUDE_CONFIG_DIR: Claude Code keys its keychain entry on
# whether the variable is set, so ~/.claude named explicitly looks logged out.
logged_in() {
  local s
  set -- "$(normpath "$1")"
  if [ "$1" = "$HOME/.claude" ] && [ -z "${CLAUDE_CONFIG_DIR:-}" ]; then
    s=$(env -u CLAUDE_CONFIG_DIR claude auth status --json 2>/dev/null) || s=""
  else
    s=$(CLAUDE_CONFIG_DIR=$1 claude auth status --json 2>/dev/null) || s=""
  fi
  if printf '%s' "$s" | jq -e '.loggedIn == true' >/dev/null 2>&1; then
    printf 'yes (%s)' "$(printf '%s' "$s" | jq -r '.authMethod // "unknown"')"
  else
    printf 'no'
  fi
}
cfg_get() { # cfg_get <file> <KEY>: a value of a KEY="value" config, or nothing
  [ -f "$1" ] || return 0
  sed -n "s/^[[:space:]]*$2=\"\\([^\"]*\\)\"[[:space:]]*\$/\\1/p" "$1" | tail -n 1
}
stamp() { date +%Y%m%d-%H%M%S; }

cmd=${1:-}
[ $# -eq 0 ] || shift

# ------------------------------------------------------------------ detect

detect() {
  local v s f d item n
  echo "== Claude Code"
  printf 'version: %s\n' "$(claude --version 2>/dev/null | head -n 1 || echo 'not found')"
  printf 'config dir: %s%s\n' "$CONFIG_DIR" "${CLAUDE_CONFIG_DIR:+ (CLAUDE_CONFIG_DIR)}"
  printf 'this config logged in: %s\n' "$(logged_in "$CONFIG_DIR")"
  printf 'plugin: %s\n' "$ROOT"
  printf 'waw home: %s\n' "$AS_HOME"

  echo "== Tools"
  for v in jq python3 node git uuidgen curl; do
    if have "$v"; then printf '%s: ok\n' "$v"; else printf '%s: MISSING\n' "$v"; fi
  done
  case $(uname -s) in
    Darwin) if have sandbox-exec; then echo "os sandbox: ok (Seatbelt)"; else echo "os sandbox: MISSING (sandbox-exec)"; fi ;;
    Linux) if have bwrap; then echo "os sandbox: ok (bubblewrap)"; else echo "os sandbox: MISSING (bwrap)"; fi ;;
    *) echo "os sandbox: none on $(uname -s)" ;;
  esac
  if have gh; then
    if gh auth status >/dev/null 2>&1; then echo "gh: logged in"; else echo "gh: installed, not logged in"; fi
  else echo "gh: not installed"; fi
  if have glab; then
    if glab auth status >/dev/null 2>&1; then echo "glab: logged in"; else echo "glab: installed, not logged in"; fi
  else echo "glab: not installed"; fi

  echo "== Model sources ([subscription] first, then [pay per token])"
  # codex: GPT on a ChatGPT subscription (or an OpenAI key), one-shot calls (review, decide).
  if have codex; then
    s=$(codex login status 2>&1 | head -n 1) || true
    printf 'codex [subscription]: installed (%s), %s; models: %s; use: review and decide; workers on route codex (its own login: CODEX_HOME=<route dir> codex login)\n' \
      "$(codex --version 2>/dev/null | head -n 1)" "${s:-login unknown}" \
      "$(codex debug models 2>/dev/null | jq -r '[.models[]? | select(.visibility == "list") | .slug] | .[0:6] | join(", ")' 2>/dev/null || echo '?')"
  else echo "codex: not installed"; fi
  # opencode: its own logins, each a subscription (OpenCode Go, GitHub Copilot, a ChatGPT or
  # Claude plan) or a key (pay per token). The CLI serves one-shot calls; OpenCode Go also has
  # an Anthropic-compatible API, so its key in the keychain makes it a worker route (opencode-go).
  if have opencode; then
    s=$(opencode auth list 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' | awk -F'  +' 'NF > 1 && $1 !~ /^[^A-Za-z]/ {
        kind = ($1 ~ /OpenCode Go|Copilot/ || $2 ~ /ChatGPT|Claude Pro|Claude Max|Pro\/Max|OAuth/) ? "subscription" : "pay per token"
        if ($NF == "environment") kind = kind ": from env"
        print $1 " [" kind "]" }' | sort -u | paste -sd ',' - | sed 's/,/, /g') || s=""
    n=$(opencode models 2>/dev/null | cut -d/ -f1 | sort | uniq -c | awk '{ printf "%s%s (%s)", (k++ ? ", " : ""), $2, $1 }') || n=""
    printf 'opencode: installed (%s); logins: %s; models by provider: %s; use: review and decide (the CLI)\n' \
      "$(opencode --version 2>/dev/null | head -n 1)" "${s:-none}" "${n:-none}"
    if opencode models 2>/dev/null | grep -q '^opencode-go/'; then
      printf 'opencode-go [subscription]: Go models: %s; keychain item "opencode-go": %s; use: workers (route opencode-go, needs the Go API key in the keychain), review and decide (the CLI)\n' \
        "$(opencode models 2>/dev/null | sed -n 's#^opencode-go/##p' | grep -v -- '-free$' | paste -sd ',' - | sed 's/,/, /g')" \
        "$(keychain_has opencode-go && echo present || echo absent)"
    fi
  else echo "opencode: not installed"; fi
  # OpenRouter: any model, pay per token; workers (Anthropic-compatible URL) and one-shot.
  printf 'openrouter [pay per token]: keychain item "openrouter": %s; env OPENROUTER_API_KEY: %s; use: workers, review, decide\n' \
    "$(keychain_has openrouter && echo present || echo absent)" "$([ -n "${OPENROUTER_API_KEY:-}" ] && echo set || echo unset)"
  # nexos.ai: the gateway of the original setup.
  printf 'nexos [pay per token]: keychain item "nexos-ai": %s; legacy ~/.claude-nexos: %s; use: workers, review, decide\n' \
    "$(keychain_has nexos-ai && echo present || echo absent)" "$([ -f "$HOME/.claude-nexos/settings.json" ] && echo present || echo absent)"
  # Anthropic: Claude models on the developer's own account; a worker route needs its own login.
  printf 'anthropic [subscription when logged in with claude.ai; an API key is pay per token]: this session: %s; env ANTHROPIC_API_KEY: %s; worker route %s: %s; use: Claude workers, review, decide\n' \
    "$(logged_in "$CONFIG_DIR")" "$([ -n "${ANTHROPIC_API_KEY:-}" ] && echo set || echo unset)" \
    "$AS_HOME/workers/anthropic" \
    "$([ -d "$AS_HOME/workers/anthropic" ] && logged_in "$AS_HOME/workers/anthropic" || echo 'not created')"

  echo "== Worker routes (in $AS_HOME/workers)"
  n=0
  for d in "$AS_HOME"/workers/*/; do
    case $(basename "$d") in codex | codex-*)
      n=$((n + 1))
      printf '%s: codex worker route; login %s\n' "$(basename "$d")" \
        "$(have codex && CODEX_HOME=${d%/} codex login status >/dev/null 2>&1 && echo yes || echo no)"
      continue ;;
    esac
    [ -f "$d/settings.json" ] || continue
    n=$((n + 1))
    f=$d/settings.json
    item=$(helper_item "$f")
    printf '%s: url %s; key item %s; login %s\n' "$(basename "$d")" \
      "$(jq -r '.env.ANTHROPIC_BASE_URL // "anthropic"' "$f")" \
      "${item:+"$item ($(keychain_has "$item" && echo present || echo absent))"}${item:-none}" \
      "$([ -n "$item" ] && echo n/a || logged_in "$d")"
  done
  [ "$n" != 0 ] || echo "(none)"

  echo "== Current setup"
  if [ -f "$AS_HOME/config" ]; then
    echo "config: $AS_HOME/config"
    { grep -E '^[A-Z]' "$AS_HOME/config" || true; } | sed 's/^/  /'
  else
    echo "config: none (not configured)"
  fi
  for f in "${XDG_CONFIG_HOME:-$HOME/.config}/agentic-setup/config"; do
    [ -f "$f" ] || continue
    echo "legacy config (the setup before the plugin): $f"
    { grep -E '^[A-Z][A-Z0-9_]*="' "$f" || true; } | sed 's/^/  /'
  done
  printf 'rules: '
  n=0
  for f in "$CONFIG_DIR"/rules/waw/*.md; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    n=$((n + 1))
    printf '%s%s ' "${f##*/}" "$([ -e "$f" ] || echo '(broken)')"
  done
  [ "$n" != 0 ] || printf 'none'
  printf '\n'
  f=$CONFIG_DIR/settings.json
  if [ -f "$f" ]; then
    printf 'settings: model %s; statusLine %s\n' "$(jq -r '.model // "default"' "$f")" \
      "$(jq -r '.statusLine.command // "none" | if test("waw/plugin/statusline.sh") then "waw (ours)"
        elif . == "none" then . else "another one (" + (if length > 70 then .[0:70] + "..." else . end) + ")" end' "$f")"
    n=0
    for v in $PERMISSIONS; do
      if jq -e --arg r "$v" '(.permissions.allow // []) | index($r) != null' "$f" >/dev/null; then n=$((n + 1)); fi
    done
    printf 'settings: %s of 7 script permissions; attribution %s\n' "$n" \
      "$(jq -r 'if .attribution == {"commit": "", "pr": ""} then "off" else "default (Claude lines in commits and PRs)" end' "$f")"
  else
    echo "settings: $f does not exist"
  fi
}

# ------------------------------------------------------------------ models

models() {
  local src=${1:-} re=${2:-.} key
  [ -n "$src" ] || die 2 "usage: configure.sh models <codex|opencode|opencode-go|openrouter|nexos|anthropic> [<regex>]"
  case $src in
    codex)
      have codex || die 3 "codex is not installed"
      codex debug models 2>/dev/null |
        jq -r '.models[]? | select(.visibility == "list") | [.slug, (.display_name // .slug), "", ""] | @tsv'
      ;;
    opencode)
      have opencode || die 3 "opencode is not installed"
      opencode models 2>/dev/null | awk 'NF { printf "%s\t%s\t\t\n", $1, $1 }'
      ;;
    opencode-go)
      # The ids the Go API takes are the opencode ids without the opencode-go/ prefix.
      have opencode || die 3 "opencode is not installed"
      opencode models 2>/dev/null | sed -n 's#^opencode-go/##p' | awk 'NF { printf "%s\t%s (OpenCode Go)\t\t\n", $1, $1 }'
      ;;
    openrouter)
      curl -sS -m 30 https://openrouter.ai/api/v1/models |
        jq -r '.data[] | [.id, .name, ((.pricing.prompt // "0") | tonumber * 100000000 | round / 100 | tostring),
          ((.pricing.completion // "0") | tonumber * 100000000 | round / 100 | tostring)] | @tsv'
      ;;
    nexos)
      keychain_has nexos-ai || die 3 "no keychain item nexos-ai (see /configure)"
      key=$(security find-generic-password -s nexos-ai -w 2>/dev/null) || die 3 "cannot read the keychain item nexos-ai"
      # The key goes in a header file, never on the command line.
      local h
      h=$(mktemp "${TMPDIR:-/tmp}/waw.h.XXXXXX")
      chmod 600 "$h"
      printf 'Authorization: Bearer %s\n' "$key" >"$h"
      curl -sS -m 30 -H "@$h" "$NEXOS_URL/v1/models" | jq -r '.data[]? | [.id, (.name // .id), "", ""] | @tsv' || true
      rm -f "$h"
      ;;
    anthropic)
      printf '%s\t%s\t%s\t%s\n' \
        claude-opus-5-5 "Claude Opus 5.5" "" "" \
        claude-sonnet-5-5 "Claude Sonnet 5.5" "" "" \
        claude-haiku-5-5 "Claude Haiku 5.5" "" "" \
        claude-fable-5-2 "Claude Fable 5.2" "" "" \
        opus "alias: the latest Opus" "" "" \
        sonnet "alias: the latest Sonnet" "" "" \
        haiku "alias: the latest Haiku" "" ""
      ;;
    *) die 2 "unknown source: $src" ;;
  esac | { grep -iE -- "$re" || true; }
}

# ------------------------------------------------------------------ apply

# route_settings <type> <url> <keychain> <default model>: the settings.json of a worker route.
route_settings() {
  local type=$1 url=$2 item=$3 model=$4
  case $type in
    anthropic)
      jq -n '{skipDangerousModePermissionPrompt: true}'
      ;;
    nexos | openrouter | opencode-go | custom)
      jq -n --arg url "$url" --arg item "$item" --arg m "$model" --arg type "$type" '
        {env: ({ANTHROPIC_BASE_URL: $url}
          + (if $type == "openrouter" or $type == "opencode-go" then {ANTHROPIC_API_KEY: ""} else {} end)
          + (if $m == "" then {} else {ANTHROPIC_MODEL: $m, ANTHROPIC_DEFAULT_OPUS_MODEL: $m,
              ANTHROPIC_DEFAULT_SONNET_MODEL: $m, ANTHROPIC_DEFAULT_HAIKU_MODEL: $m,
              ANTHROPIC_SMALL_FAST_MODEL: $m} end)),
         skipDangerousModePermissionPrompt: true,
         apiKeyHelper: ("/usr/bin/security find-generic-password -s " + $item + " -w")}
        + (if $m == "" then {} else {model: $m} end)'
      ;;
  esac
}

backup() { # backup <file>: copy it into this run's backup dir, keeping its path below $HOME
  [ -e "$1" ] || return 0
  local rel=${1#"$HOME"/}
  mkdir -p "$BACKUP/$(dirname "$rel")"
  cp -p "$1" "$BACKUP/$rel"
}

apply() {
  local choices=${1:-} r t url item m route role p k dm f tmp n link mod legacy
  [ -n "$choices" ] && [ -r "$choices" ] || die 2 "usage: configure.sh apply <choices.json>"
  jq -e 'type == "object"' "$choices" >/dev/null 2>&1 || die 2 "$choices is not a JSON object"
  BACKUP=$AS_HOME/backups/$(stamp)
  # Set up before apply recorded its changes (no applied.json yet): settings equal to ours are ours.
  legacy=false
  [ -f "$AS_HOME/config" ] && [ ! -f "$APPLIED" ] && legacy=true

  # Validate everything before writing anything.
  for r in $(jq -r '.routes // {} | keys[]' "$choices"); do
    [[ $r =~ $NAME_RE ]] || die 2 "route name '$r': lowercase letters, digits and -"
    t=$(jq -r --arg r "$r" '.routes[$r].type // ""' "$choices")
    case $t in anthropic | nexos | openrouter | opencode-go | custom | codex) ;; *) die 2 "route $r: type must be anthropic, nexos, openrouter, opencode-go, custom or codex" ;; esac
    # agent.sh runs a route's workers on Codex by its name: codex, codex-<name>.
    case $r in
      codex | codex-*) [ "$t" = codex ] || die 2 "route name '$r' is for routes of type codex" ;;
      *) [ "$t" != codex ] || die 2 "route $r: a codex route is named codex or codex-<name>"
        case " opencode claude gateway " in *" $r "*) die 2 "route name '$r' is taken by a review provider" ;; esac ;;
    esac
    item=$(jq -r --arg r "$r" '.routes[$r].keychain // ""' "$choices")
    url=$(jq -r --arg r "$r" '.routes[$r].url // ""' "$choices")
    if [ "$t" != anthropic ] && [ "$t" != codex ]; then
      [[ $item =~ $KEYCHAIN_RE ]] || die 2 "route $r: keychain must be a keychain service name"
    fi
    if [ "$t" = custom ]; then
      case $url in https://?*) ;; *) die 2 "route $r: url must start with https://" ;; esac
      [[ $url =~ ^https://[A-Za-z0-9.:/_-]+$ ]] || die 2 "route $r: url has characters it may not have"
    fi
  done
  for role in $ROLES; do
    m=$(jq -r --arg r "$role" '.workers[$r].model // ""' "$choices")
    route=$(jq -r --arg r "$role" '.workers[$r].route // ""' "$choices")
    [[ $m =~ $MODEL_RE ]] || die 2 "workers.$role.model is missing or has characters it may not have"
    v=$(jq -r --arg r "$role" '.workers[$r].fallback_model // ""' "$choices")
    [ -z "$v" ] || [[ $v =~ $MODEL_RE ]] || die 2 "workers.$role.fallback_model has characters it may not have"
    v=$(jq -r --arg r "$role" '.workers[$r].fallback_route // ""' "$choices")
    [ -z "$v" ] || { [[ $v =~ $NAME_RE ]] && case $v in codex | codex-*) false ;; esac; } ||
      die 2 "workers.$role.fallback_route must name a Claude Code route"
    v=$(jq -r --arg r "$role" '.workers[$r].effort // ""' "$choices")
    case $v in "" | minimal | low | medium | high | xhigh) ;; *) die 2 "workers.$role.effort: minimal, low, medium, high or xhigh" ;; esac
    jq -e --arg r "$route" '.routes[$r] != null' "$choices" >/dev/null ||
      [ -f "$AS_HOME/workers/$route/settings.json" ] || [ -d "$AS_HOME/workers/$route" ] ||
      die 2 "workers.$role.route '$route' is not in routes"
  done
  n=$(jq '.review.providers // [] | length' "$choices")
  [ "$n" -gt 0 ] || die 2 "review.providers is empty: name at least one provider for code review and decisions"
  local dup
  dup=$(jq -r '[.review.providers[].provider] | group_by(.) | map(select(length > 1)[0]) | join(" ")' "$choices")
  [ -z "$dup" ] || die 2 "review.providers: $dup is named more than once (a second entry would overwrite the first one's model)"
  for i in $(seq 0 $((n - 1))); do
    p=$(jq -r --argjson i "$i" '.review.providers[$i].provider // ""' "$choices")
    m=$(jq -r --argjson i "$i" '.review.providers[$i].model // ""' "$choices")
    dm=$(jq -r --argjson i "$i" '.review.providers[$i].decide_model // ""' "$choices")
    [[ $p =~ $NAME_RE ]] || die 2 "review.providers[$i].provider: bad name"
    case $p in
      codex | claude) [ -z "$m" ] || [[ $m =~ $MODEL_RE ]] || die 2 "review.providers[$i].model: bad characters" ;;
      opencode | gateway) [[ $m =~ $MODEL_RE ]] || die 2 "review.providers[$i] ($p) needs a model" ;;
      codex-*) die 2 "review.providers[$i]: '$p' is a worker route; Codex reviews use the provider codex" ;;
      *)
        jq -e --arg r "$p" '.routes[$r] != null' "$choices" >/dev/null || [ -f "$AS_HOME/workers/$p/settings.json" ] ||
          die 2 "review provider '$p' is neither built in (codex, opencode, claude, gateway) nor a route"
        [[ $m =~ $MODEL_RE ]] || die 2 "review.providers[$i] ($p) needs a model"
        ;;
    esac
    [ -z "$dm" ] || [[ $dm =~ $MODEL_RE ]] || die 2 "review.providers[$i].decide_model: bad characters"
    if [ "$p" = gateway ]; then
      url=$(jq -r --argjson i "$i" '.review.providers[$i].url // ""' "$choices")
      item=$(jq -r --argjson i "$i" '.review.providers[$i].keychain // ""' "$choices")
      [[ $url =~ ^https://[A-Za-z0-9.:/_-]+$ ]] || die 2 "review gateway: url must be https://... (an OpenAI-compatible base, without /chat/completions)"
      [[ $item =~ $KEYCHAIN_RE ]] || die 2 "review gateway: keychain must be a keychain service name"
    fi
  done
  t=$(jq -r '.review.effort // ""' "$choices")
  [ -z "$t" ] || [[ $t =~ ^[a-z]+$ ]] || die 2 "review.effort: one lowercase word such as high"
  m=$(jq -r '.settings.model // ""' "$choices")
  local smodel_re='^[][A-Za-z0-9._:@+-]+$'
  [ -z "$m" ] || [[ $m =~ $smodel_re ]] || die 2 "settings.model: bad characters"

  mkdir -p "$AS_HOME/workers" "$AS_HOME/state"
  ln -sfn "$ROOT" "$AS_HOME/plugin"
  echo "home: $AS_HOME (plugin link -> $ROOT)"

  # Worker routes.
  for r in $(jq -r '.routes // {} | keys[]' "$choices"); do
    t=$(jq -r --arg r "$r" '.routes[$r].type' "$choices")
    if [ "$t" = codex ]; then
      # A Codex route is the workers' CODEX_HOME: agent.sh writes its config.toml and
      # hooks.json at each run; the login is the developer's (check says how).
      d=$AS_HOME/workers/$r
      mkdir -p "$d"
      chmod 700 "$d"
      echo "route $r: $d (codex: CODEX_HOME of the workers; log in once: CODEX_HOME='$d' codex login)"
      continue
    fi
    item=$(jq -r --arg r "$r" '.routes[$r].keychain // ""' "$choices")
    url=$(jq -r --arg r "$r" '.routes[$r].url // ""' "$choices")
    case $t in nexos) url=${url:-$NEXOS_URL} ;; openrouter) url=${url:-$OPENROUTER_URL} ;; opencode-go) url=${url:-$OPENCODE_GO_URL} ;; esac
    dm=$(jq -r --arg r "$r" '.routes[$r].default_model // ""' "$choices")
    if [ -z "$dm" ] && [ "$t" != anthropic ]; then
      dm=$(jq -r --arg r "$r" '[.workers[]? | select(.route == $r) | .model][0] // ""' "$choices")
      [ "$t" != nexos ] || [ -n "$dm" ] || dm=auto-code
    fi
    [ -z "$dm" ] || [[ $dm =~ $MODEL_RE ]] || die 2 "routes.$r.default_model: bad characters"
    d=$AS_HOME/workers/$r
    mkdir -p "$d"
    chmod 700 "$d"
    backup "$d/settings.json"
    tmp=$(route_settings "$t" "$url" "$item" "$dm")
    printf '%s\n' "$tmp" >"$d/settings.json"
    chmod 600 "$d/settings.json"
    echo "route $r: $d/settings.json ($t${url:+, $url}${item:+, key from keychain item $item})"
  done

  # The config.
  f=$AS_HOME/config
  backup "$f"
  tmp=$(mktemp "$AS_HOME/.config.XXXXXX")
  {
    printf '# waw config, written by /configure on %s. KEY="value" lines, parsed and never sourced.\n' "$(date +%Y-%m-%d)"
    printf '# Workers (agent.sh): model and route per role. A route is %s/workers/<route>/,\n' "$AS_HOME"
    printf '# a Claude Code config dir whose settings.json names the endpoint and the key helper.\n'
    for role in $ROLES; do
      k=$(printf '%s' "$role" | tr a-z A-Z)
      printf 'AGENT_%s_MODEL="%s"\n' "$k" "$(jq -r --arg r "$role" '.workers[$r].model' "$choices")"
      printf 'AGENT_%s_ROUTE="%s"\n' "$k" "$(jq -r --arg r "$role" '.workers[$r].route' "$choices")"
      # A Codex worker's effort, and where the role runs when a project's rules keep Codex out.
      for kv in fallback_route:FALLBACK_ROUTE fallback_model:FALLBACK_MODEL effort:EFFORT; do
        v=$(jq -r --arg r "$role" --arg f "${kv%%:*}" '.workers[$r][$f] // ""' "$choices")
        [ -z "$v" ] || printf 'AGENT_%s_%s="%s"\n' "$k" "${kv#*:}" "$v"
      done
    done
    printf '\n# Code review and /auto-pilot decisions (attack.sh): providers tried in this order, the\n'
    printf '# first valid answer wins. <P>_MODEL reviews, <P>_DECIDE_MODEL decides (default <P>_MODEL).\n'
    printf 'PROVIDERS="%s"\n' "$(jq -r '[.review.providers[].provider] | join(" ")' "$choices")"
    for i in $(seq 0 $((n - 1))); do
      p=$(jq -r --argjson i "$i" '.review.providers[$i].provider' "$choices")
      k=$(printf '%s' "$p" | tr 'a-z-' 'A-Z_')
      m=$(jq -r --argjson i "$i" '.review.providers[$i].model // ""' "$choices")
      dm=$(jq -r --argjson i "$i" '.review.providers[$i].decide_model // ""' "$choices")
      [ -z "$m" ] || printf '%s_MODEL="%s"\n' "$k" "$m"
      [ -z "$dm" ] || printf '%s_DECIDE_MODEL="%s"\n' "$k" "$dm"
      if [ "$p" = gateway ]; then
        printf 'GATEWAY_URL="%s"\n' "$(jq -r --argjson i "$i" '.review.providers[$i].url' "$choices")"
        printf 'GATEWAY_KEYCHAIN="%s"\n' "$(jq -r --argjson i "$i" '.review.providers[$i].keychain' "$choices")"
      fi
    done
    t=$(jq -r '.review.effort // ""' "$choices")
    [ -z "$t" ] || printf 'EFFORT="%s"\n' "$t"
  } >"$tmp"
  mv -f "$tmp" "$f"
  echo "config: $f"

  # Prices: the defaults once, then the OpenRouter models the developer chose.
  [ -f "$AS_HOME/prices.tsv" ] || { cp "$ROOT/defaults/prices.tsv" "$AS_HOME/prices.tsv"; echo "prices: $AS_HOME/prices.tsv (defaults)"; }
  if [ "$(jq '.prices.openrouter // [] | length' "$choices")" -gt 0 ]; then
    backup "$AS_HOME/prices.tsv"
    local catalog
    catalog=$(curl -sS -m 30 https://openrouter.ai/api/v1/models 2>/dev/null) || catalog=""
    if [ -z "$catalog" ]; then
      echo "prices: could not read the OpenRouter catalog; agent.sh report shows n/a for those models"
    else
      for m in $(jq -r '.prices.openrouter[]' "$choices"); do
        line=$(printf '%s' "$catalog" | jq -r --arg m "$m" '.data[] | select(.id == $m) | .pricing as $p
          | def usd: tonumber * 100000000 | round / 100;
            [$m, ($p.prompt | usd), ($p.completion | usd), (($p.input_cache_read // $p.prompt) | usd),
             (if $p.input_cache_write then ($p.input_cache_write | usd | tostring) else "" end)]
          | map(tostring) | join("\t")')
        if [ -z "$line" ]; then echo "prices: $m is not in the OpenRouter catalog"; continue; fi
        awk -F'\t' -v m="$m" '$1 != m' "$AS_HOME/prices.tsv" >"$AS_HOME/prices.tsv.tmp"
        printf '%s\n' "$line" >>"$AS_HOME/prices.tsv.tmp"
        mv -f "$AS_HOME/prices.tsv.tmp" "$AS_HOME/prices.tsv"
        echo "prices: $m (OpenRouter, $(date +%Y-%m-%d))"
      done
    fi
  fi

  # Rules: copies of the plugin's rules, the core and the chosen modules. Copies, not links:
  # Claude Code does not load a rule file that is a symbolic link. The session-start hook
  # refreshes every copy from the plugin when the plugin changes (edits there are overwritten).
  mkdir -p "$CONFIG_DIR/rules/waw"
  for mod in commander git-delivery decisions jira-tickets; do
    link=$CONFIG_DIR/rules/waw/$mod.md
    case $mod in
      commander | git-delivery) want=true ;;
      *) want=$(jq -r --arg m "$mod" '.modules[$m] // false' "$choices") ;;
    esac
    if [ "$want" = true ]; then
      [ -L "$link" ] && rm -f "$link"
      cp "$ROOT/rules/$mod.md" "$link"
      echo "rule: $link"
    elif [ -e "$link" ] || [ -L "$link" ]; then
      rm -f "$link"
      echo "rule removed: $link"
    fi
  done

  # Settings of this Claude config: only what the developer chose.
  f=$CONFIG_DIR/settings.json
  backup "$f"
  [ -f "$f" ] || printf '{}\n' >"$f"
  jq -e 'type == "object"' "$f" >/dev/null 2>&1 || die 3 "$f is not a JSON object: fix it, then run apply again"
  # What this changes, and what was there before (the first time), for `configure.sh uninstall`.
  tmp=$(mktemp "$AS_HOME/.applied.XXXXXX")
  # shellcheck disable=SC2086 # the rules have no spaces
  jq -n --slurpfile c "$choices" --slurpfile o "$f" --slurpfile r <(cat "$APPLIED" 2>/dev/null || echo '{}') \
    --arg sl "$AS_HOME/plugin/statusline.sh" --argjson perms "$(printf '%s\n' $PERMISSIONS | jq -R . | jq -s .)" \
    --argjson legacy "$legacy" '
    ($c[0].settings // {}) as $s | $o[0] as $o | ($r[0] // {}) as $r
    | def ours($k): $legacy and (
        if $k == "statusLine" then (($o.statusLine.command? // "") | test("/waw/plugin/statusline\\.sh"))
        elif $k == "attribution" then $o.attribution == {commit: "", pr: ""}
        elif $k == "includeCoAuthoredBy" then $o.includeCoAuthoredBy == false
        elif $k == "model" then $o.model == $s.model
        else false end);
      def was($k): if ours($k) then {had: false, value: null} else {had: ($o | has($k)), value: $o[$k]} end;
      def first($rk; $k): if $r[$rk] then $r[$rk].before else was($k) end;
    $r
    | if $s.statusline == true then .statusLine = {set: {type: "command", command: ("\u0027" + $sl + "\u0027")}, before: first("statusLine"; "statusLine")} else . end
    | if $s.permissions == true then .permissions_added = ((($r.permissions_added // []) + (if $legacy then $perms else $perms - ($o.permissions.allow // []) end)) | unique) else . end
    | if $s.no_attribution == true then .attribution = {before: first("attribution"; "attribution"),
        coauthored_before: (if $r.attribution then $r.attribution.coauthored_before else was("includeCoAuthoredBy") end)} else . end
    | if ($s.model // "") != "" then .model = {set: $s.model, before: first("model"; "model")} else . end
    | if ($s.model // "") != "" and ($s.effort // "") != "" then .effort = {model: $s.model, set: $s.effort,
        before: (if $r.effort and $r.effort.model == $s.model then $r.effort.before
          elif $legacy and $o.modelSettings[$s.model].effortLevel? == $s.effort then {had: false, value: null}
          else {had: ($o.modelSettings[$s.model] | has("effortLevel")?) // false, value: $o.modelSettings[$s.model].effortLevel?} end)} else . end' \
    >"$tmp" || { rm -f "$tmp"; die 3 "could not record the settings change"; }
  mv -f "$tmp" "$APPLIED"
  tmp=$(mktemp "$CONFIG_DIR/.settings.XXXXXX")
  # shellcheck disable=SC2086 # the rules have no spaces
  jq --slurpfile c "$choices" --arg sl "$AS_HOME/plugin/statusline.sh" --argjson perms "$(printf '%s\n' $PERMISSIONS | jq -R . | jq -s .)" \
    '($c[0].settings // {}) as $s
    | if $s.statusline == true then .statusLine = {type: "command", command: ("\u0027" + $sl + "\u0027")} else . end
    | if $s.permissions == true then .permissions.allow = ((.permissions.allow // []) + ($perms - (.permissions.allow // []))) else . end
    | if $s.no_attribution == true then .attribution = {commit: "", pr: ""} | .includeCoAuthoredBy = false else . end
    | if ($s.model // "") != "" then .model = $s.model else . end
    | if ($s.model // "") != "" and ($s.effort // "") != "" then .modelSettings[$s.model].effortLevel = $s.effort else . end' \
    "$f" >"$tmp" || { rm -f "$tmp"; die 3 "could not update $f"; }
  mv -f "$tmp" "$f"
  echo "settings: $f ($(jq -r '.settings // {} | to_entries | map(select(.value != false and .value != "")) | map(.key) | join(", ")' "$choices"))"
  [ ! -d "$BACKUP" ] || echo "backup of what was replaced: $BACKUP"
}

# ------------------------------------------------------------------ check

check() {
  local todo=0 fail=0 role m route d f item p s
  pass() { printf 'PASS  %s\n' "$1"; }
  todo() { printf 'TODO  %s\n      fix: %s\n' "$1" "$2"; todo=$((todo + 1)); }
  bad() { printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); }

  for p in jq python3 node git uuidgen; do have "$p" || bad "$p is not installed"; done
  [ -f "$AS_HOME/config" ] || { todo "no config ($AS_HOME/config)" "run /configure"; printf '\n%s to do, %s failed\n' "$todo" "$fail"; return 1; }
  if s=$("$HERE/attack.sh" --check-config 2>&1); then pass "attack.sh config: $(printf '%s' "$s" | grep '^PROVIDERS' )"
  else bad "attack.sh config: $(printf '%s' "$s" | tail -n 3 | tr '\n' ' ')"; fi
  if s=$("$HERE/agent.sh" sandbox-check 2>&1); then pass "worker sandbox"; else bad "worker sandbox: $s"; fi

  # Worker routes: a settings file, and a key or a login.
  local seen=" "
  while IFS=$'\t' read -r role m route d; do
    [ -n "$m" ] || bad "no model for the $role"
    case $seen in *" $route "*) continue ;; esac
    seen="$seen$route "
    case $route in codex | codex-*)
      if ! have codex; then bad "route $route: codex is not installed"
      elif [ -f "$d/auth.json" ] && CODEX_HOME=$d codex login status >/dev/null 2>&1; then pass "route $route: Codex logged in"
      else todo "route $route: Codex is not logged in there" "CODEX_HOME='$d' codex login   (in a terminal: it opens the browser)"; fi
      continue ;;
    esac
    f=$d/settings.json
    if [ ! -f "$f" ]; then bad "route $route: $f is missing"; continue; fi
    item=$(helper_item "$f")
    if [ -n "$item" ]; then
      if keychain_has "$item"; then pass "route $route: key in keychain item $item"
      elif [ "$item" = openrouter ] && [ -n "${OPENROUTER_API_KEY:-}" ]; then
        todo "route $route: no key in keychain item $item (it is in OPENROUTER_API_KEY)" "! security add-generic-password -U -s $item -a waw -w \"\$OPENROUTER_API_KEY\""
      else todo "route $route: no key in keychain item $item" "! security add-generic-password -U -s $item -a waw -w \"\$(pbpaste)\"   (copy the key first; then: pbcopy </dev/null)"; fi
    elif jq -e '.env.ANTHROPIC_BASE_URL == null' "$f" >/dev/null; then
      if [ "$(logged_in "$d")" = no ]; then
        todo "route $route: Claude Code is not logged in there" "! CLAUDE_CONFIG_DIR='$d' claude auth login"
      else pass "route $route: logged in ($(logged_in "$d"))"; fi
    fi
  done < <("$HERE/agent.sh" models --tsv)

  # Review providers.
  for p in $(cfg_get "$AS_HOME/config" PROVIDERS); do
    case $p in
      codex)
        if ! have codex; then todo "review codex: not installed" "npm i -g @openai/codex (or brew install codex)"
        elif codex login status >/dev/null 2>&1; then pass "review codex: logged in"
        else todo "review codex: not logged in" "! codex login"; fi
        ;;
      opencode)
        m=$(cfg_get "$AS_HOME/config" OPENCODE_MODEL)
        if ! have opencode; then todo "review opencode: not installed" "see https://opencode.ai"
        elif opencode models 2>/dev/null | grep -qxF "${m%%#*}"; then pass "review opencode: $m is available"
        else todo "review opencode: $m is not in \`opencode models\`" "! opencode auth login, or run /configure again"; fi
        ;;
      claude) pass "review claude: this session's login" ;;
      gateway)
        item=$(cfg_get "$AS_HOME/config" GATEWAY_KEYCHAIN)
        if [ -n "$item" ] && ! keychain_has "$item"; then
          todo "review gateway: no key in keychain item $item" "! security add-generic-password -U -s $item -a waw -w \"\$(pbpaste)\""
        else pass "review gateway: configured"; fi
        ;;
      *) [ -f "$AS_HOME/workers/$p/settings.json" ] && pass "review $p: worker route" || bad "review $p: no route $AS_HOME/workers/$p" ;;
    esac
  done

  # Rules and settings.
  for f in commander git-delivery; do
    if [ -f "$CONFIG_DIR/rules/waw/$f.md" ] && [ ! -L "$CONFIG_DIR/rules/waw/$f.md" ]; then
      if cmp -s "$ROOT/rules/$f.md" "$CONFIG_DIR/rules/waw/$f.md"; then pass "rule $f"
      else todo "rule $f differs from the plugin's" "start a new session (the session-start hook refreshes it)"; fi
    else todo "rule $f is not installed" "run /configure (apply copies it)"; fi
  done
  f=$CONFIG_DIR/settings.json
  s=$(jq -r '.statusLine.command // ""' "$f" 2>/dev/null) || s=""
  case $s in *waw/plugin/statusline.sh*) pass "status line" ;; '') todo "no status line (it saves the model time /task-cost shows; costs come from the transcript)" "run /configure and choose the status line" ;; *) pass "status line: your own ($s); /task-cost shows costs from the transcript, no model time" ;; esac
  if have claude; then
    p=$(PATH="$ROOT/bin:$PATH" command -v agent.sh || true)
    [ -n "$p" ] && pass "scripts on the PATH (plugin bin/)" || bad "agent.sh is not on the PATH"
  fi
  printf '\n%s to do, %s failed\n' "$todo" "$fail"
  [ "$todo" = 0 ] && [ "$fail" = 0 ]
}

# ------------------------------------------------------------------ ping

ping_() {
  local p=${1:-} m=${2:-} d out rc=0
  [ -n "$p" ] && [ -n "$m" ] || die 2 "usage: configure.sh ping <codex|opencode|<route>|route:<route>> <model>"
  [[ $m =~ $MODEL_RE ]] || die 2 "bad model name"
  # route:<name> names a worker route even where a review provider has the name (route:codex).
  case $p in route:*) p=${p#route:}; [[ $p =~ $NAME_RE ]] || die 2 "bad route" ;; esac
  case ${1:-} in route:codex | route:codex-* | codex-*)
    d=$AS_HOME/workers/$p
    [ -f "$d/auth.json" ] || die 3 "route $p is not logged in: CODEX_HOME='$d' codex login"
    out=$(cd "${TMPDIR:-/tmp}" && CODEX_HOME=$d codex exec --ignore-user-config --sandbox read-only --ephemeral \
      --skip-git-repo-check --color never -m "$m" "Reply with the single word OK." </dev/null 2>&1) || rc=$?
    p="route:$p" ;;
  esac
  case $p in
    route:*) ;;
    codex) out=$(codex exec --sandbox read-only --ephemeral --skip-git-repo-check --color never -m "$m" "Reply with the single word OK." 2>&1) || rc=$? ;;
    opencode) out=$(opencode run --model "$m" --agent plan --archived "Reply with the single word OK." 2>&1) || rc=$? ;;
    *)
      [[ $p =~ $NAME_RE ]] || die 2 "bad provider"
      d=$AS_HOME/workers/$p
      [ -f "$d/settings.json" ] || die 3 "no route $d"
      out=$(cd "${TMPDIR:-/tmp}" && env -u ANTHROPIC_BASE_URL -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN \
        CLAUDE_CONFIG_DIR="$d" claude -p --model "$m" --tools "" --no-session-persistence \
        --strict-mcp-config --setting-sources user "Reply with the single word OK." 2>&1) || rc=$?
      ;;
  esac
  out=$(printf '%s' "$out" | grep -v 'unrecognized_model' | tail -n 5)
  if [ "$rc" = 0 ] && printf '%s' "$out" | grep -qi 'ok'; then echo "ping $p $m: ok"; return 0; fi
  echo "ping $p $m: failed (exit $rc): $out"
  return 1
}

uninstall() {
  local purge=0 keep_plugin=0 f tmp d n item keys=() bak mod changed
  while [ $# -gt 0 ]; do
    case $1 in
      --purge) purge=1 ;;
      --keep-plugin) keep_plugin=1 ;;
      *) die 2 "usage: configure.sh uninstall [--purge] [--keep-plugin]" ;;
    esac
    shift
  done

  # Rules: the copies apply made (Claude Code loads them in every session).
  for mod in commander git-delivery decisions jira-tickets; do
    f=$CONFIG_DIR/rules/waw/$mod.md
    if [ -e "$f" ] || [ -L "$f" ]; then rm -f "$f" && echo "rule removed: $f"; fi
  done
  rmdir "$CONFIG_DIR/rules/waw" 2>/dev/null || true
  rmdir "$CONFIG_DIR/rules" 2>/dev/null || true # only when empty: nothing of yours is in it

  # Settings: what apply set, back to what was there, unless the developer changed it since.
  f=$CONFIG_DIR/settings.json
  if [ -f "$f" ] && jq -e 'type == "object"' "$f" >/dev/null 2>&1; then
    bak=$CONFIG_DIR/backups/waw-uninstall-$(stamp).settings.json
    mkdir -p "$CONFIG_DIR/backups" && cp -p "$f" "$bak"
    tmp=$(mktemp "$CONFIG_DIR/.settings.XXXXXX")
    # shellcheck disable=SC2086 # the rules have no spaces
    jq --slurpfile r <(cat "$APPLIED" 2>/dev/null || echo '{}') --arg sl "$AS_HOME/plugin/statusline.sh" \
      --argjson ours "$(printf '%s\n' $PERMISSIONS | jq -R . | jq -s .)" '
      ($r[0] // {}) as $r
      | def restore($k; $b): if $b.had then .[$k] = $b.value else del(.[$k]) end;
      (if $r.statusLine then (if .statusLine == $r.statusLine.set then restore("statusLine"; $r.statusLine.before) else . end)
       elif ((.statusLine.command? // "") | contains($sl) or test("/waw/plugin/statusline\\.sh")) then del(.statusLine) else . end)
      | (($r.permissions_added // $ours)) as $rm
      | (if (.permissions.allow? | type) == "array" then .permissions.allow -= $rm
          | (if .permissions.allow == [] then del(.permissions.allow) else . end)
          | (if .permissions == {} then del(.permissions) else . end) else . end)
      | (if $r.attribution and .attribution == {commit: "", pr: ""} then
          restore("attribution"; $r.attribution.before) | restore("includeCoAuthoredBy"; $r.attribution.coauthored_before) else . end)
      | (if $r.model and .model == $r.model.set then restore("model"; $r.model.before) else . end)
      | (if $r.effort and (.modelSettings[$r.effort.model].effortLevel? == $r.effort.set) then
          (if $r.effort.before.had then .modelSettings[$r.effort.model].effortLevel = $r.effort.before.value
           else del(.modelSettings[$r.effort.model].effortLevel)
             | (if .modelSettings[$r.effort.model] == {} then del(.modelSettings[$r.effort.model]) else . end)
             | (if .modelSettings == {} then del(.modelSettings) else . end) end) else . end)' \
      "$f" >"$tmp" || { rm -f "$tmp"; die 3 "could not update $f (unchanged; nothing else was done after the rules)"; }
    if cmp -s <(jq -S . "$f") <(jq -S . "$tmp"); then
      rm -f "$tmp" "$bak"
      echo "settings: nothing of waw in $f"
    else
      changed=$(jq -rn --slurpfile a "$f" --slurpfile b "$tmp" '
        [($a[0] | keys[]) as $k | select($a[0][$k] != $b[0][$k]) | $k] | join(", ")')
      mv -f "$tmp" "$f"
      echo "settings: $f ($changed restored or removed; backup: $bak)"
    fi
    if [ ! -f "$APPLIED" ] && jq -e '.attribution == {commit: "", pr: ""} or (.model // "" | length > 0)' "$f" >/dev/null 2>&1; then
      echo "settings: attribution and model are left as they are (set before waw recorded its changes; yours to keep or remove)"
    fi
  fi
  rm -f "$AS_HOME/plugin"

  # Home: the config and the worker routes (with their logins), only with --purge.
  if [ -d "$AS_HOME" ]; then
    if [ "$purge" = 1 ]; then
      case $AS_HOME in "$HOME" | / | "$CONFIG_DIR") die 3 "refusing to remove $AS_HOME" ;; esac
      [ "${AS_HOME##*/}" = waw ] || [ -f "$AS_HOME/config" ] || die 3 "$AS_HOME does not look like a waw home: not removed"
      for d in "$AS_HOME"/workers/*/; do
        [ -d "$d" ] || continue
        d=$(normpath "$d")
        case ${d##*/} in
          codex | codex-*)
            if [ -f "$d/auth.json" ] && have codex; then CODEX_HOME=$d codex logout >/dev/null 2>&1 && echo "logged out: route ${d##*/} (Codex)"; fi ;;
          *)
            item=$(helper_item "$d/settings.json")
            if [ -n "$item" ]; then keys+=("$item")
            elif [ "$(logged_in "$d")" != no ]; then CLAUDE_CONFIG_DIR=$d claude auth logout >/dev/null 2>&1 && echo "logged out: route ${d##*/} (Claude Code)"; fi ;;
        esac
      done
      rm -rf "$AS_HOME" && echo "removed: $AS_HOME (config, worker routes, state, backups)"
    else
      echo "kept: $AS_HOME (config, worker routes and their logins; for a reinstall). --purge removes it."
    fi
  fi

  # The plugin and its marketplace.
  if [ "$keep_plugin" = 0 ]; then
    if have claude; then
      claude plugin uninstall waw@harness >/dev/null 2>&1 && echo "plugin: waw@harness uninstalled" ||
        echo "plugin: not uninstalled here (another scope?): claude plugin uninstall waw@harness --scope project|local"
      claude plugin marketplace remove harness >/dev/null 2>&1 && echo "marketplace: harness removed" || true
    else
      echo "plugin: run claude plugin uninstall waw@harness && claude plugin marketplace remove harness"
    fi
  fi

  if [ "${#keys[@]}" -gt 0 ]; then
    n=$(printf '%s\n' "${keys[@]}" | sort -u | tr '\n' ' ')
    echo "keychain: the route keys are still there (other tools may use them): $n"
    for item in $(printf '%s\n' "${keys[@]}" | sort -u); do echo "  security delete-generic-password -s $item"; done
  fi
  echo "not touched: worktrees in ~/worktrees, your CLAUDE.md, ~/.codex. Start a new session."
}

case $cmd in
  detect) detect ;;
  models) models "$@" ;;
  apply) apply "$@" ;;
  check) check ;;
  ping) ping_ "$@" ;;
  uninstall) uninstall "$@" ;;
  -h | --help | "") awk 'NR > 1 && /^set -euo/ { exit } NR > 1' "$0" ;;
  *) die 2 "unknown command: $cmd (see configure.sh --help)" ;;
esac
