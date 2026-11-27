#!/usr/bin/env bash
# providers/opencode.sh: opencode CLI adapter. Usage: opencode.sh <input-file>.
# Environment: ATTACK_MODEL (required: provider/model as `opencode models` lists it, e.g.
# "openai/gpt-6.1"), ATTACK_EFFORT (optional: sent as the model variant, provider/model#effort).
# When the model lacks that variant ("Variant unavailable"), the call runs once more without
# it and stderr gets "note: effort <effort> is not a variant of <model>; ran without it"
# (stderr lines starting with "note: " are notes for attack.sh). A variant written in
# ATTACK_MODEL is never dropped.
# opencode brings its own logins (`opencode auth login`): a subscription or a key it holds.
# The input goes in as an attached file; the plan agent (read-only: no edits), no auto-approval,
# an archived session. The answer is the text it prints.
set -euo pipefail
[ $# -eq 1 ] && [ -r "$1" ] || { echo "usage: opencode.sh <input-file>" >&2; exit 2; }
[ -n "${ATTACK_MODEL:-}" ] || { echo "opencode.sh: no model (set OPENCODE_MODEL)" >&2; exit 2; }
command -v opencode >/dev/null 2>&1 || { echo "opencode.sh: opencode not found on PATH" >&2; exit 4; }
base=$ATTACK_MODEL
model=$base
variant_from_effort=0
if [ -n "${ATTACK_EFFORT:-}" ]; then
  [[ $ATTACK_EFFORT =~ ^[a-z]+$ ]] || { echo "opencode.sh: bad EFFORT '$ATTACK_EFFORT'" >&2; exit 4; }
  case $model in *'#'*) ;; *) model="$base#$ATTACK_EFFORT"; variant_from_effort=1 ;; esac
fi
tmp=$(mktemp -d "${TMPDIR:-/tmp}/waw.opencode.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
cp "$1" "$tmp/input.md"
run_once() { # run_once <model>: the answer to $tmp/answer, stderr to $tmp/log
  opencode run --model "$1" --agent plan --archived --title waw-review \
    --file "$tmp/input.md" "Follow the instructions in the attached file input.md and answer exactly in the form it asks for. Do not change any file." \
    >"$tmp/answer" 2>"$tmp/log"
}
rc=0
run_once "$model" || rc=$?
if [ "$rc" -ne 0 ] && [ "$variant_from_effort" -eq 1 ] && grep -qi 'variant unavailable' "$tmp/log"; then
  echo "note: effort $ATTACK_EFFORT is not a variant of $base; ran without it" >&2
  rc=0
  run_once "$base" || rc=$?
fi
[ "$rc" -eq 0 ] || { tail -n 20 "$tmp/log" >&2; exit 4; }
grep -q '[^[:space:]]' "$tmp/answer" || { tail -n 20 "$tmp/log" >&2; echo "opencode.sh: empty answer" >&2; exit 4; }
# opencode prints ANSI colours on a terminal only; strip any that slip through.
sed $'s/\x1b\\[[0-9;]*m//g' "$tmp/answer"
