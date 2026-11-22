#!/usr/bin/env bash
# providers/gateway.sh: any OpenAI-compatible gateway, through curl. Usage: gateway.sh <input-file>.
# Environment: ATTACK_MODEL (required), ATTACK_EFFORT (sent as reasoning_effort, "" = not sent),
# GATEWAY_URL (https, no trailing /), GATEWAY_KEY_ENV (name of the variable that holds the key),
# GATEWAY_HEADERS ("Name: value" pairs separated by ";"), ATTACK_TIMEOUT (seconds for the whole
# request, default 900; the connection gets 30). Nothing gateway-specific is built in.
# The key never appears on the command line: headers come from a 0600 file.
# Exit: 0 answer printed, 2 usage, 4 any failure (message on stderr).
set -euo pipefail

die() {
  printf 'gateway.sh: %s\n' "$1" >&2
  exit 4
}

[ $# -eq 1 ] || { echo "usage: gateway.sh <input-file>" >&2; exit 2; }
input=$1
url=${GATEWAY_URL:-}
key_var=${GATEWAY_KEY_ENV:-}
model=${ATTACK_MODEL:-}
max_time=${ATTACK_TIMEOUT:-900}

[ -r "$input" ] || die "input file not readable: $input"
command -v curl >/dev/null 2>&1 || die "curl not found on PATH"
command -v jq >/dev/null 2>&1 || die "jq not found on PATH"
[[ $key_var =~ ^[A-Z_][A-Z0-9_]*$ ]] || die "no valid key variable name (got '$key_var')"
key=${!key_var:-}
[ -n "$key" ] || die "no key in \$$key_var"
case $key in *$'\n'* | *$'\r'*) die "the key in \$$key_var holds a line break" ;; esac
[ -n "$model" ] || die "no model (set GATEWAY_MODEL)"
case $url in https://?*) ;; *) die "base URL must start with https:// (got '$url')" ;; esac
case $max_time in '' | *[!0-9]* | 0) die "ATTACK_TIMEOUT must be a number of seconds (got '$max_time')" ;; esac

tmp=$(mktemp -d "${TMPDIR:-/tmp}/waw.gateway.XXXXXX") || die "mktemp failed"
chmod 700 "$tmp"
trap 'rm -rf "$tmp"' EXIT
(
  umask 077
  {
    printf 'Authorization: Bearer %s\nContent-Type: application/json\n' "$key"
    rest=${GATEWAY_HEADERS:-}
    while [ -n "$rest" ]; do
      pair=${rest%%;*}
      if [ "$pair" = "$rest" ]; then rest=""; else rest=${rest#*;}; fi
      pair=$(printf '%s' "$pair" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
      case $pair in '' | *$'\n'* | *$'\r'*) ;; *:*) printf '%s\n' "$pair" ;; esac
    done
  } >"$tmp/headers"
)
jq -Rs --arg model "$model" --arg effort "${ATTACK_EFFORT:-}" \
  '{model: $model, messages: [{role: "user", content: .}], stream: false}
   | if $effort != "" then .reasoning_effort = $effort else . end' \
  <"$input" >"$tmp/body" || die "could not build the request body"
rc=0
code=$(curl -sS --connect-timeout 30 --max-time "$max_time" -X POST -H "@$tmp/headers" --data-binary "@$tmp/body" \
  -o "$tmp/response" -w '%{http_code}' "$url/chat/completions" 2>"$tmp/curl.err") || rc=$?
if [ "$rc" != 0 ]; then
  cat "$tmp/curl.err" >&2
  die "curl failed with status $rc"
fi
if [ "$code" != 200 ]; then
  head -c 1000 "$tmp/response" >&2
  printf '\n' >&2
  die "HTTP $code"
fi
jq -j '.choices[0].message.content // empty' "$tmp/response" >"$tmp/answer" 2>/dev/null ||
  die "the response is not the expected JSON"
grep -q '[^[:space:]]' "$tmp/answer" || die "empty answer (model $model)"
cat "$tmp/answer"
