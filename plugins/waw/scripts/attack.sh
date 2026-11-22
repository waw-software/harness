#!/usr/bin/env bash
# attack.sh: the review engine. Sends the diff of the current branch to a model of another
# family and prints its findings. Report only: changes no code.
#
#   attack.sh --role review|security [--task <file>] [--base <ref>]
#                                 review the change against the task in the file (the request,
#                                 the agreed plan, the acceptance criteria)
#   attack.sh --role decide --question <file> [--task <file>]
#                                 /auto-pilot: answer the decision questions (Q1, ...) in the file
#   common:   [--repo <dir>] (run as if started there) [--max-bytes <n>]
#   attack.sh --check-config      validate the config, print the provider order and models
#
# Config: $WAW_CONFIG, else $WAW_HOME/config (WAW_HOME defaults to
# ${CLAUDE_CONFIG_DIR:-~/.claude}/waw), else ${XDG_CONFIG_HOME:-~/.config}/agentic-setup/config.
# KEY="value" lines, parsed and never sourced. Keys: PROVIDERS EFFORT, per provider <P>_MODEL
# (review, security) and <P>_DECIDE_MODEL (decide; default <P>_MODEL), GATEWAY_URL
# GATEWAY_KEY_ENV GATEWAY_KEYCHAIN GATEWAY_HEADERS, and the keys of agent.sh (NEXOS_CONFIG_DIR
# WORKER_ROUTE AGENT_<ROLE>_MODEL AGENT_<ROLE>_ROUTE AGENT_DECIDER_MODEL), which it shares.
# Providers: codex (Codex CLI, its own login: a ChatGPT subscription), opencode (opencode CLI,
# its own logins), claude (Claude Code on this session's own login), gateway (an
# OpenAI-compatible /chat/completions URL), and every worker route: a name with
# $WAW_HOME/workers/<name>/settings.json (nexos, openrouter, anthropic, ...): Claude
# Code under that route, read-only tools. A route's model: <NAME>_MODEL (NEXOS_MODEL, ...),
# else AGENT_REVIEWER_MODEL; decide: <NAME>_DECIDE_MODEL, else AGENT_DECIDER_MODEL, else the
# review model. Route nexos also falls back to NEXOS_CONFIG_DIR, then ~/.claude-nexos.
# Providers are tried in order (default "codex gateway claude"); the first valid answer wins.
# Unavailable (not installed, not authorized, not configured, failed, empty, timed out after
# $ATTACK_TIMEOUT seconds, default 900) or an invalid answer -> next.
# Only regular files inside the repository, not ignored by git and without a secret-like name
# (.env* except .env.example, keys, credentials) are added from a diff or a question file, the
# rule files (CLAUDE.md, AGENTS.md, SECURITY.md) included; the files passed by option are sent as
# given, unless they have a secret-like name (exit 2). A changed file with a secret-like name or
# a line break in its name is not sent at all: neither its diff nor its content (file names are
# read from git NUL-delimited).
# Coverage: full when the whole diff, every new file and every document are in the input;
# tools when something is cut and the provider can read the rest (codex; claude unless the
# diff is cut, since Read brings back files but not removed lines); partial otherwise. The
# input then ends with the cut documents and the omitted files. The reason also counts the
# changed files that are not sent ("full (not sent: 1 changed file)"); they lower nothing.
# A decide row counts only with every cell filled.
# Output: "provider: <name>[:<model>]", "skipped: <name> (<reason>)" lines,
# "coverage: full|tools|partial[ (<reason>)]", then the answer: the findings table or
# "No findings."; for decide the decisions table.
# Exit: 0 answered, 2 usage, 3 config, 4 no provider gave a valid answer.
set -euo pipefail
unset CDPATH

HERE=$(cd "$(dirname "$0")" && pwd)
PROVIDER_DIR="$HERE/providers"
PROMPT_DIR="$HERE/prompts"
AS_HOME=${WAW_HOME:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/waw}
BUILTIN="codex gateway claude opencode"
KEYS="PROVIDERS GATEWAY_URL GATEWAY_KEY_ENV GATEWAY_KEYCHAIN GATEWAY_HEADERS EFFORT
NEXOS_CONFIG_DIR WORKER_ROUTE AGENT_INVESTIGATOR_MODEL AGENT_DEVELOPER_MODEL AGENT_REVIEWER_MODEL
AGENT_TESTER_MODEL AGENT_DECIDER_MODEL AGENT_INVESTIGATOR_ROUTE AGENT_DEVELOPER_ROUTE
AGENT_REVIEWER_ROUTE AGENT_TESTER_ROUTE"
KEYS=${KEYS//$'\n'/ }
TIMEOUT=${ATTACK_TIMEOUT:-900}

die() {
  printf 'attack.sh: %s\n' "$2" >&2
  exit "$1"
}

role="" input="" task_file="" question_file="" base="" repo_dir="" max_bytes=200000 check=0
while [ $# -gt 0 ]; do
  case $1 in
    --role) [ $# -ge 2 ] || die 2 "--role needs a value"; role=$2; shift ;;
    --task) [ $# -ge 2 ] || die 2 "--task needs a file"; task_file=$2; shift ;;
    --question) [ $# -ge 2 ] || die 2 "--question needs a file"; question_file=$2; shift ;;
    --base) [ $# -ge 2 ] || die 2 "--base needs a ref"; base=$2; shift ;;
    --repo) [ $# -ge 2 ] || die 2 "--repo needs a directory"; repo_dir=$2; shift ;;
    --max-bytes) [ $# -ge 2 ] || die 2 "--max-bytes needs a number"; max_bytes=$2; shift ;;
    --check-config) check=1 ;;
    -h | --help) awk 'NR > 1 && /^set -euo/ { exit } NR > 1' "$0"; exit 0 ;;
    *) die 2 "unknown argument: $1 (see attack.sh --help)" ;;
  esac
  shift
done
case $max_bytes in '' | *[!0-9]*) die 2 "--max-bytes must be a number" ;; esac
case $TIMEOUT in '' | *[!0-9]* | 0) die 2 "ATTACK_TIMEOUT must be a number of seconds" ;; esac
if [ -n "$repo_dir" ]; then
  cd -P -- "$repo_dir" 2>/dev/null || die 2 "--repo: not a directory: $repo_dir"
fi

# ------------------------------------------------------------------ config

for k in $KEYS; do eval "CFG_$k=''"; done
cfg_errors=""
# Per-provider model keys (<P>_MODEL, <P>_DECIDE_MODEL), as read: "KEY<TAB>value" lines.
MODEL_KEYS=""
cfg=${WAW_CONFIG:-}
if [ -z "$cfg" ]; then
  cfg=$AS_HOME/config
  [ -f "$cfg" ] || [ ! -f "${XDG_CONFIG_HOME:-$HOME/.config}/agentic-setup/config" ] ||
    cfg=${XDG_CONFIG_HOME:-$HOME/.config}/agentic-setup/config
fi

parse_config() {
  local line key val n=0
  [ -f "$cfg" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line=${line%$'\r'}
    case $line in '' | '#'*) continue ;; esac
    if [[ $line =~ ^[[:space:]]*([A-Z][A-Z0-9_]*)=\"([^\"]*)\"[[:space:]]*$ ]]; then
      key=${BASH_REMATCH[1]}
      # shellcheck disable=SC2034 # read by the eval below
      val=${BASH_REMATCH[2]}
    else
      cfg_errors="${cfg_errors}line $n: expected KEY=\"value\""$'\n'
      continue
    fi
    case " $KEYS " in
      *" $key "*) eval "CFG_$key=\$val" ;;
      *)
        case $key in
          AGENT_*) printf 'attack.sh: config line %s: unknown key %s ignored\n' "$n" "$key" >&2 ;;
          *_DECIDE_MODEL | *_MODEL) MODEL_KEYS="${MODEL_KEYS}${key}"$'\t'"${val}"$'\n' ;;
          *) printf 'attack.sh: config line %s: unknown key %s ignored\n' "$n" "$key" >&2 ;;
        esac
        ;;
    esac
  done <"$cfg"
}

parse_config

# key_of <provider>: its config key prefix (openrouter-eu -> OPENROUTER_EU).
key_of() { printf '%s' "$1" | tr 'a-z-' 'A-Z_'; }
# cfg_model <KEY>: a per-provider model key as read, or nothing.
cfg_model() { printf '%s' "$MODEL_KEYS" | awk -F'\t' -v k="$1" '$1 == k { v = $2 } END { printf "%s", v }'; }
# route_dir <route>: the Claude Code config dir of a worker route (see agent.sh).
route_dir() {
  if [ "$1" = nexos ] && [ ! -d "$AS_HOME/workers/nexos" ]; then
    if [ -n "$CFG_NEXOS_CONFIG_DIR" ]; then printf '%s' "$CFG_NEXOS_CONFIG_DIR"; return; fi
    if [ -d "$HOME/.claude-nexos" ]; then printf '%s' "$HOME/.claude-nexos"; return; fi
  fi
  printf '%s' "$AS_HOME/workers/$1"
}
is_route() { case " $BUILTIN " in *" $1 "*) return 1 ;; esac; [[ $1 =~ ^[a-z0-9][a-z0-9-]{0,39}$ ]]; }

ORDER=${CFG_PROVIDERS:-codex gateway claude}
for p in $ORDER; do
  case " $BUILTIN " in *" $p "*) continue ;; esac
  is_route "$p" || { cfg_errors="${cfg_errors}PROVIDERS: bad provider name '$p'"$'\n'; continue; }
  [ "$p" = nexos ] || [ -d "$(route_dir "$p")" ] ||
    cfg_errors="${cfg_errors}PROVIDERS: unknown provider '$p' (built in: $BUILTIN; routes: the dirs in $AS_HOME/workers)"$'\n'
done
[ -n "${ORDER// /}" ] || cfg_errors="${cfg_errors}PROVIDERS is empty"$'\n'
# A gateway may name its models with spaces and parentheses ("GPT 6 Astra (trusted)"); the
# name only travels as one argument or inside the JSON request body.
model_re='^[A-Za-z0-9._/:@+()# -]*$'
while IFS=$'\t' read -r k v; do
  [ -n "$k" ] || continue
  [[ $v =~ $model_re ]] || cfg_errors="${cfg_errors}invalid model name in $k"$'\n'
done <<EOF
$MODEL_KEYS
AGENT_INVESTIGATOR_MODEL	$CFG_AGENT_INVESTIGATOR_MODEL
AGENT_DEVELOPER_MODEL	$CFG_AGENT_DEVELOPER_MODEL
AGENT_REVIEWER_MODEL	$CFG_AGENT_REVIEWER_MODEL
AGENT_TESTER_MODEL	$CFG_AGENT_TESTER_MODEL
AGENT_DECIDER_MODEL	$CFG_AGENT_DECIDER_MODEL
EOF
for p in $ORDER; do
  if is_route "$p" && [ -z "$(cfg_model "$(key_of "$p")_MODEL")" ] && [ -z "$CFG_AGENT_REVIEWER_MODEL" ]; then
    cfg_errors="${cfg_errors}provider $p needs $(key_of "$p")_MODEL or AGENT_REVIEWER_MODEL"$'\n'
  fi
  if [ "$p" = opencode ] && [ -z "$(cfg_model OPENCODE_MODEL)" ]; then
    cfg_errors="${cfg_errors}provider opencode needs OPENCODE_MODEL"$'\n'
  fi
done
if [ -n "$CFG_EFFORT" ] && ! [[ $CFG_EFFORT =~ ^[a-z]+$ ]]; then
  cfg_errors="${cfg_errors}EFFORT must be one lowercase word such as high"$'\n'
fi
if [ -n "$CFG_GATEWAY_URL" ]; then
  case $CFG_GATEWAY_URL in https://?*) ;; *) cfg_errors="${cfg_errors}GATEWAY_URL must start with https://"$'\n' ;; esac
fi
if [ -n "$CFG_GATEWAY_KEYCHAIN" ] && ! [[ $CFG_GATEWAY_KEYCHAIN =~ ^[A-Za-z0-9._-]+$ ]]; then
  cfg_errors="${cfg_errors}GATEWAY_KEYCHAIN must be a keychain service name (letters, digits, . _ -)"$'\n'
fi
if [ -n "$CFG_GATEWAY_KEY_ENV" ] && ! [[ $CFG_GATEWAY_KEY_ENV =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
  cfg_errors="${cfg_errors}GATEWAY_KEY_ENV must be an environment variable name"$'\n'
fi
if [ -n "$cfg_errors" ]; then
  printf 'attack.sh: config %s:\n%s' "$cfg" "$cfg_errors" >&2
  exit 3
fi

# model_of <provider>: the model it is called with for this role (decide: not the
# investigator's model, which built the plan the decider judges).
model_of() {
  local k m d
  k=$(key_of "$1")
  m=$(cfg_model "${k}_MODEL")
  d=$(cfg_model "${k}_DECIDE_MODEL")
  if is_route "$1"; then
    m=${m:-$CFG_AGENT_REVIEWER_MODEL}
    d=${d:-$CFG_AGENT_DECIDER_MODEL}
  fi
  [ "$1" != claude ] || m=${m:-sonnet}
  if [ "$role" = decide ]; then printf '%s' "${d:-$m}"; else printf '%s' "$m"; fi
}

if [ "$check" = 1 ]; then
  printf 'config %s: ok\nPROVIDERS=%s\n' "$cfg" "$ORDER"
  for p in $ORDER; do
    printf '%s model=%s' "$p" "$(model_of "$p")"
    [ "$p" = gateway ] || printf ' decide=%s' "$(role=decide model_of "$p")"
    if is_route "$p"; then printf ' dir=%s' "$(route_dir "$p")"; fi
    printf '\n'
  done
  printf 'EFFORT=%s\n' "$CFG_EFFORT"
  exit 0
fi

# ------------------------------------------------------------------ usage checks

# ids_in <file> <letter>: the ids <letter><n> that start a line of the file (after Markdown
# marks), one per line, no duplicates.
ids_in() {
  awk -v l="$2" '
    match($0, "^[[:space:]#*>|-]*" l "[0-9]+") {
      id = substr($0, RSTART, RLENGTH); sub("^[^" l "]*", "", id)
      if (substr($0, RSTART + RLENGTH, 1) !~ /[A-Za-z0-9_]/ && !seen[id]++) print id
    }' "$1"
}

want_ids=""
case $role in
  decide)
    # A decision: the question file is the input, with the repository files it names.
    [ -n "$question_file" ] && [ -f "$question_file" ] || die 2 "--role decide needs --question <existing file>"
    want_ids=$(ids_in "$question_file" Q | tr '\n' ' ')
    [ -n "$want_ids" ] || die 2 "$question_file defines no question ids (Q1, Q2, ...)"
    input=question
    ;;
  review | security) input="diff" ;;
  *) die 2 "--role must be review, security or decide" ;;
esac
[ -z "$question_file" ] || [ "$role" = decide ] || die 2 "--question needs --role decide"
[ -z "$task_file" ] || [ -f "$task_file" ] || die 2 "file not found: $task_file"
# Paths given by option are read from the start directory; everything else works from the
# repository's top level, where the file names git prints are valid.
abs() { case $1 in '' | /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }
question_file=$(abs "$question_file") task_file=$(abs "$task_file")

# ------------------------------------------------------------------ the input

tmp=$(mktemp -d "${TMPDIR:-/tmp}/waw.attack.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# The repository's top level (physical path), empty outside a repository.
REPO_TOP=$(git rev-parse --show-toplevel 2>/dev/null) && REPO_TOP=$(cd -P -- "$REPO_TOP" && pwd -P) || REPO_TOP=""
[ -z "$REPO_TOP" ] || cd "$REPO_TOP"

# secret_name <path>: the file name looks like it holds a secret.
secret_name() {
  local name
  name=$(printf '%s' "${1##*/}" | tr '[:upper:]' '[:lower:]')
  case $name in
    .env.example) return 1 ;;
    .env* | *.pem | *.key | *.p12 | id_rsa* | id_ed25519* | .npmrc | .netrc | credentials* | secrets.*) return 0 ;;
  esac
  return 1
}

# A file passed by option is the caller's choice, wherever it lies, but never a secret-named one.
for f in "$task_file" "$question_file"; do
  [ -z "$f" ] || ! secret_name "$f" || die 2 "not sent: $f has a secret-like name"
done

# eligible <path>: a regular file that, with every symlink resolved, lies inside the
# repository (not in .git), is not ignored by git and has no secret-like name.
eligible() {
  local f=$1 dir=. phys rc=0
  [ -n "$REPO_TOP" ] && [ -f "$f" ] && [ ! -L "$f" ] || return 1
  case $f in /*/* | [!/]*/*) dir=${f%/*} ;; /*) dir=/ ;; esac
  phys=$(cd -P -- "$dir" 2>/dev/null && pwd -P) || return 1
  phys="${phys%/}/${f##*/}"
  case $phys in "$REPO_TOP"/*) ;; *) return 1 ;; esac
  case /${phys#"$REPO_TOP"/} in */.git/*) return 1 ;; esac
  ! secret_name "$f" || return 1
  git -C "$REPO_TOP" check-ignore -q -- "${phys#"$REPO_TOP"/}" 2>/dev/null || rc=$?
  [ "$rc" = 1 ]
}

# add_files <list-file> <omit>: append each eligible text file within the cap, counted in
# $used. With omit=1 a file that does not fit goes to $tmp/omitted: an untracked file has no
# diff section, so its text is the change; for a tracked one the text is only context.
add_files() {
  local f size
  while IFS= read -r f; do
    if [ -z "$f" ] || ! eligible "$f"; then continue; fi
    LC_ALL=C grep -q -I . "$f" 2>/dev/null || continue
    size=$(wc -c <"$f" | tr -d ' ')
    if [ $((used + size)) -gt "$max_bytes" ]; then
      [ "$2" = 0 ] || printf '%s\n' "$f" >>"$tmp/omitted"
      continue
    fi
    used=$((used + size))
    printf '\n===== BEGIN file %s\n' "$f"
    cat "$f"
    printf '\n===== END file %s\n' "$f"
  done <"$1"
}

# emit_capped <file> <label>: the file's content cut at the cap.
emit_capped() {
  head -c "$max_bytes" "$1"
  if [ "$(wc -c <"$1" | tr -d ' ')" -gt "$max_bytes" ]; then
    printf '\n[%s truncated at %s bytes]\n' "$2" "$max_bytes"
  fi
}

# emit_doc <label> <file>: one named, capped document; a cut one goes to $tmp/cut.docs.
emit_doc() {
  printf '\n===== BEGIN %s\n' "$1"
  emit_capped "$2" "$1"
  printf '\n===== END %s\n' "$1"
  if [ "$(wc -c <"$2" | tr -d ' ')" -gt "$max_bytes" ]; then
    printf '%s: %s\n' "$1" "$(abs "$2")" >>"$tmp/cut.docs"
  fi
}

# emit_context: questions, task, and the repo's rule files.
emit_context() {
  local c rules="CLAUDE.md AGENTS.md"
  [ "$role" != security ] || rules="$rules SECURITY.md"
  [ -z "$question_file" ] || emit_doc questions "$question_file"
  [ -z "$task_file" ] || emit_doc task "$task_file"
  for c in $rules; do
    if eligible "$c"; then emit_doc "$c" "$c"; fi
  done
  return 0
}

# cut_files: the tracked files whose part of the diff lies past the cap ($tmp/tracked holds
# the files of the diff in the order git prints their sections).
cut_files() {
  local whole
  whole=$(LC_ALL=C awk -v cap="$max_bytes" '
    /^diff --git / { if (n && end <= cap) ok++; n++ }
    { end += length($0) + 1 }
    END { if (n && end <= cap) ok++; print ok + 0 }' "$tmp/diff")
  sed -n "$((whole + 1)),\$p" "$tmp/tracked"
}

prompt_file="$PROMPT_DIR/$role.md"
[ -r "$prompt_file" ] || die 2 "prompt not found: $prompt_file"

: >"$tmp/files"
: >"$tmp/tracked"
: >"$tmp/untracked"
: >"$tmp/omitted"
: >"$tmp/cut.docs"
mb="" head_sha="" diff_cut=0 not_sent=0
head_sha=$(git rev-parse -q --verify HEAD 2>/dev/null || true)
if [ "$input" = diff ]; then
  [ -n "$REPO_TOP" ] || die 2 "not inside a git repository"
  if [ -z "$base" ]; then
    base=$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)
    if [ -z "$base" ]; then
      for b in main master; do
        if git rev-parse -q --verify "$b" >/dev/null 2>&1; then base=$b; break; fi
      done
    fi
  fi
  [ -n "$base" ] || die 2 "no base branch found; pass --base <ref>"
  mb=$(git merge-base "$base" HEAD 2>/dev/null) || die 2 "no merge base with '$base'"
  # The changed files, read NUL-delimited (git quotes unusual names in its line output). One
  # with a secret-like name or a line break in its name is not sent: it is left out of the
  # diff and of the file contents, and only counted. No rename detection: each section of
  # the diff is one name of $tmp/tracked, in the same order.
  git diff --no-renames --name-only -z "$mb" >"$tmp/tracked.z"
  git ls-files --others --exclude-standard -z >"$tmp/untracked.z"
  excluded=()
  for list in tracked untracked; do
    while IFS= read -r -d '' f; do
      case $f in
        *$'\n'*) ;;
        *) if ! secret_name "$f"; then printf '%s\n' "$f" >>"$tmp/$list"; continue; fi ;;
      esac
      not_sent=$((not_sent + 1))
      [ "$list" = untracked ] || excluded+=(":(top,exclude,literal)$f")
    done <"$tmp/$list.z"
  done
  git diff --no-renames "$mb" -- ':(top)' ${excluded[@]+"${excluded[@]}"} >"$tmp/diff"
  cat "$tmp/tracked" "$tmp/untracked" >"$tmp/files"
  if [ ! -s "$tmp/files" ]; then
    if [ "$not_sent" = 0 ]; then
      echo "Nothing to review: no changes against $base."
    else
      echo "Nothing to review: the only changes against $base are $not_sent files that are not sent (secret-like names or line breaks in the name)."
    fi
    exit 0
  fi
  if [ "$(wc -c <"$tmp/diff" | tr -d ' ')" -gt "$max_bytes" ]; then
    diff_cut=1
    cut_files >"$tmp/omitted"
  fi
else
  # Repo files the question file names: tokens that look like paths, no duplicates; add_files
  # keeps only the eligible ones.
  { grep -oE '[A-Za-z0-9_./-]+\.[A-Za-z0-9]+|[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+' "$question_file" || true; } |
    sed 's|^\./||' | awk '!seen[$0]++' >"$tmp/files"
fi

# The explicit files count toward the cap, each as far as it is sent.
used=0
for f in "$question_file" "$task_file"; do
  [ -z "$f" ] || used=$((used + $(head -c "$max_bytes" "$f" | wc -c | tr -d ' ')))
done
{
  cat "$prompt_file"
  if [ "$input" = diff ]; then
    printf '\n===== BEGIN diff against %s\n' "$base"
    emit_capped "$tmp/diff" diff
    printf '\n===== END diff\n\nChanged files: %s\n' "$(tr '\n' ' ' <"$tmp/files")"
    [ "$not_sent" = 0 ] ||
      printf 'Not sent: %s changed files with a secret-like name or a line break in the name (neither their diff nor their content). Never read or diff the files that are not sent, nor any other file with such a name.\n' "$not_sent"
    size=$(wc -c <"$tmp/diff" | tr -d ' ')
    [ "$size" -le "$max_bytes" ] || size=$max_bytes
    used=$((used + size))
  fi
  emit_context
  if [ "$input" = diff ]; then
    add_files "$tmp/tracked" 0
    add_files "$tmp/untracked" 1
  else
    add_files "$tmp/files" 0 # a question file counts as complete
  fi
} >"$tmp/input.base"
awk '!seen[$0]++' "$tmp/omitted" >"$tmp/omitted.list"

# codex_diff_cmd: the git command for the whole change, with the exclusions of the diff above.
codex_diff_cmd() {
  local e
  printf 'git diff --no-renames %s --' "$mb"
  for e in ':(top)' ${excluded[@]+"${excluded[@]}"}; do printf ' %q' "$e"; done
}

# emit_omitted <provider>: the end of the input when something is cut: the cut documents, the
# omitted changed files and, for a provider with repository access, where to read the rest.
emit_omitted() {
  local changes=0
  if [ -s "$tmp/omitted.list" ] || [ "$diff_cut" = 1 ]; then changes=1; fi
  [ "$changes" = 1 ] || [ -s "$tmp/cut.docs" ] || return 0
  printf '\n===== NOT IN THIS INPUT (cut at %s bytes)\n' "$max_bytes"
  if [ -s "$tmp/cut.docs" ]; then
    printf 'Cut documents (the rest is in the file):\n'
    sed 's/^/- /' "$tmp/cut.docs"
  fi
  if [ "$changes" = 1 ]; then
    printf 'Changed files not in this input:\n'
    sed 's/^/- /' "$tmp/omitted.list"
  fi
  case $1 in
    codex)
      if [ "$changes" = 1 ]; then
        # shellcheck disable=SC2016 # the backticks are Markdown
        printf 'The change is `%s` (merge base %s to the working tree, HEAD %s). Read the omitted files and their diff (`git diff --no-renames %s -- <file>`) in the repository before you answer.\n' \
          "$(codex_diff_cmd)" "$mb" "$head_sha" "$mb"
      fi
      [ ! -s "$tmp/cut.docs" ] || printf 'Read the rest of each cut document at its path before you answer.\n'
      ;;
    claude)
      if [ "$diff_cut" = 1 ]; then
        printf 'The diff above is cut and you have no shell: the removed lines and deleted files past the cut are not in this input, and you cannot read them. Read the current text of each listed file that still exists with your Read tool, and report nothing about changes you could not see.\n'
      elif [ "$changes" = 1 ]; then
        printf 'These files are new, so they have no diff above. You have no shell: read each omitted file with your Read tool before you answer.\n'
      fi
      [ ! -s "$tmp/cut.docs" ] || printf 'Read the rest of each cut document at its path with your Read tool before you answer.\n'
      ;;
    *) printf 'You cannot read what is left out: review what is above and report nothing about it.\n' ;;
  esac
  printf '===== END NOT IN THIS INPUT\n'
}

# coverage_of <provider>: the coverage line's value for this input and provider: tools only
# when the provider can read what is left out (codex runs git; claude reads files, which
# brings back new files and documents but not a cut diff), else partial. The reason also
# counts the changed files that are not sent; they do not lower the coverage.
coverage_of() {
  local kind=full why="" n
  n=$(wc -l <"$tmp/omitted.list" | tr -d ' ')
  [ "$diff_cut" = 0 ] || why="diff cut at $max_bytes bytes, "
  if [ "$diff_cut" = 1 ] || [ "$n" != 0 ]; then why="${why}omitted changed files: $n, "; fi
  if [ -s "$tmp/cut.docs" ]; then
    why="${why}documents cut at $max_bytes bytes: $(awk -F': ' '{ printf "%s%s", (NR > 1 ? ", " : ""), $1 }' "$tmp/cut.docs"), "
  fi
  if [ -n "$why" ]; then
    kind=partial
    case $1:$diff_cut in codex:* | claude:0) kind=tools ;; esac
  fi
  if [ "$not_sent" = 1 ]; then why="${why}not sent: 1 changed file, "; fi
  if [ "$not_sent" -gt 1 ]; then why="${why}not sent: $not_sent changed files, "; fi
  why=${why%, }
  printf '%s%s\n' "$kind" "${why:+ ($why)}"
}

# ------------------------------------------------------------------ providers

# unavailable <provider>: print the reason when it cannot be used; print nothing when it can.
unavailable() {
  case $1 in
    codex)
      command -v codex >/dev/null 2>&1 || { echo "not installed"; return 0; }
      if ! codex login status >"$tmp/login" 2>&1; then
        # A CLI without `login status` is treated as authorized; the call decides.
        if grep -qiE 'unrecognized|unexpected argument|unknown (command|subcommand)|no such command' "$tmp/login"; then
          return 0
        fi
        echo "not authorized"
      fi
      ;;
    gateway)
      if [ -z "$CFG_GATEWAY_URL" ] || [ -z "$(model_of gateway)" ]; then echo "not configured"
      elif [ -n "$CFG_GATEWAY_KEYCHAIN" ]; then
        [ -n "${AGENTIC_GATEWAY_KEY:-}" ] || echo "no key in the keychain item $CFG_GATEWAY_KEYCHAIN"
      elif [ -z "$CFG_GATEWAY_KEY_ENV" ] || [ -z "${!CFG_GATEWAY_KEY_ENV:-}" ]; then
        echo "not configured"
      fi
      ;;
    claude)
      command -v claude >/dev/null 2>&1 || echo "not installed"
      ;;
    opencode)
      command -v opencode >/dev/null 2>&1 || echo "not installed"
      ;;
    *)
      if ! command -v claude >/dev/null 2>&1; then echo "not installed"
      elif [ ! -f "$(route_dir "$1")/settings.json" ]; then echo "not configured ($(route_dir "$1")/settings.json missing)"; fi
      ;;
  esac
  return 0
}

# kill_tree <pid>: stop the process, end all its descendants, then end it; prints the pids.
# shellcheck disable=SC2329 # called by with_deadline
kill_tree() {
  local child
  kill -STOP "$1" 2>/dev/null || return 0
  for child in $(ps -A -o pid= -o ppid= | awk -v p="$1" '$2 == p { print $1 }'); do
    kill_tree "$child"
  done
  kill -TERM "$1" 2>/dev/null || true
  kill -CONT "$1" 2>/dev/null || true
  echo "$1"
}

# with_deadline <cmd...>: run the command; after TIMEOUT seconds end it with its children
# and return 124, as timeout(1) does. For machines without timeout and gtimeout.
# shellcheck disable=SC2329 # called through the runner array of run_provider
with_deadline() {
  local pid wd rc=0
  "$@" &
  pid=$!
  (
    n=0
    while kill -0 "$pid" 2>/dev/null; do
      if [ "$n" -ge "$TIMEOUT" ]; then
        : >"$tmp/timed-out"
        pids=$(kill_tree "$pid")
        # What ignores TERM gets KILL after a grace of 3 seconds.
        for g in 1 2 3 4; do
          alive=""
          for q in $pids; do if kill -0 "$q" 2>/dev/null; then alive="$alive $q"; fi; done
          [ -n "$alive" ] || exit 0
          [ "$g" = 4 ] || sleep 1
        done
        for q in $alive; do kill -KILL "$q" 2>/dev/null || true; done
        exit 0
      fi
      sleep 1
      n=$((n + 1))
    done
  ) </dev/null >/dev/null 2>&1 &
  wd=$!
  wait "$pid" || rc=$?
  # After a timeout the watchdog may still have to KILL what ignored TERM: let it finish.
  [ -f "$tmp/timed-out" ] || kill "$wd" 2>/dev/null || true
  wait "$wd" 2>/dev/null || true
  if [ -f "$tmp/timed-out" ]; then
    rm -f "$tmp/timed-out"
    return 124
  fi
  return "$rc"
}

# run_provider <provider>: one attempt, answer in $tmp/answer. Returns 124 on timeout, 1 on
# an empty answer, the provider's status when it fails.
run_provider() {
  local rc=0
  local -a runner=(with_deadline)
  if command -v timeout >/dev/null 2>&1; then
    runner=(timeout -k 5 "$TIMEOUT")
  elif command -v gtimeout >/dev/null 2>&1; then
    runner=(gtimeout -k 5 "$TIMEOUT")
  fi
  { cat "$tmp/input.base"; emit_omitted "$1"; } >"$tmp/input"
  local key_env=$CFG_GATEWAY_KEY_ENV adapter=$PROVIDER_DIR/$1.sh
  [ -z "$CFG_GATEWAY_KEYCHAIN" ] || key_env=AGENTIC_GATEWAY_KEY
  export ATTACK_MODEL ATTACK_EFFORT=$CFG_EFFORT ATTACK_TIMEOUT=$TIMEOUT GATEWAY_URL=$CFG_GATEWAY_URL \
    GATEWAY_KEY_ENV=$key_env GATEWAY_HEADERS=$CFG_GATEWAY_HEADERS ROUTE_CONFIG_DIR=""
  if is_route "$1"; then
    adapter=$PROVIDER_DIR/route.sh
    ROUTE_CONFIG_DIR=$(route_dir "$1")
  fi
  ATTACK_MODEL=$(model_of "$1")
  "${runner[@]}" "$adapter" "$tmp/input" >"$tmp/answer" 2>"$tmp/err" || rc=$?
  [ "$rc" = 0 ] || return "$rc"
  grep -q '[^[:space:]]' "$tmp/answer"
}

# valid_answer <file>: the answer has the form the role asks for. Findings: exactly the
# sentence "No findings." or a table row whose first cell is blocker or non-blocker with at
# least four cells. Decide: for every id of $want_ids a row of at least three cells, none of
# them empty. Cells are compared trimmed, without ` and *, in lower case.
valid_answer() {
  if [ -z "$want_ids" ] && [ "$(grep -c '[^[:space:]]' "$1")" = 1 ] &&
    grep -qE '^[[:space:]]*No findings\.?[[:space:]]*$' "$1"; then
    return 0
  fi
  # shellcheck disable=SC2016 # the backtick is part of the awk program
  LC_ALL=C awk -v ids="$want_ids" '
    function cell(i) { x = (i <= n) ? c[i] : ""; gsub(/[`*]/, "", x); gsub(/^[[:space:]]+/, "", x)
      gsub(/[[:space:]]+$/, "", x); return tolower(x) }
    /^[[:space:]]*\|/ {
      line = $0; sub(/^[[:space:]]*\|/, "", line); sub(/\|[[:space:]]*$/, "", line)
      n = split(line, c, "|"); c1 = cell(1)
      if (ids == "") { if (n >= 4 && (c1 == "blocker" || c1 == "non-blocker")) ok = 1 }
      else {
        filled = (n >= 3)
        for (k = 1; k <= n; k++) if (cell(k) == "") filled = 0
        if (filled) seen[c1] = 1
      }
    }
    END {
      if (ids == "") exit !ok
      m = split(tolower(ids), want, " ")
      for (i = 1; i <= m; i++) if (!(want[i] in seen)) exit 1
      exit 0
    }' "$1"
}

# The gateway's key from the macOS keychain, read once and only when the gateway is in the order.
if [ -n "$CFG_GATEWAY_KEYCHAIN" ]; then
  case " $ORDER " in
    *" gateway "*)
      AGENTIC_GATEWAY_KEY=$(security find-generic-password -s "$CFG_GATEWAY_KEYCHAIN" -w 2>/dev/null) || AGENTIC_GATEWAY_KEY=""
      export AGENTIC_GATEWAY_KEY
      ;;
  esac
fi

skipped=""
for p in $ORDER; do
  why=$(unavailable "$p")
  if [ -z "$why" ]; then
    rc=0
    run_provider "$p" || rc=$?
    if [ "$rc" = 0 ] && valid_answer "$tmp/answer"; then
      m=$(model_of "$p")
      cov=$(coverage_of "$p")
      printf 'provider: %s%s\n' "$p" "${m:+:$m}"
      printf '%s' "$skipped"
      printf 'coverage: %s\n' "$cov"
      cat "$tmp/answer"
      exit 0
    fi
    case $rc in
      0) why="invalid answer" ;;
      124) why="timed out" ;;
      *)
        # The provider's last line says why (a usage limit, a bad model name).
        last=$({ grep '[^[:space:]]' "$tmp/err" 2>/dev/null || true; } | tail -n 1 | tr -d '\r' | cut -c1-160)
        why="call failed${last:+: $last}"
        ;;
    esac
    [ "$rc" = 0 ] || tail -n 5 "$tmp/err" >&2 || true
  fi
  skipped="${skipped}skipped: $p ($why)"$'\n'
done
printf '%s' "$skipped"
die 4 "no provider answered with a valid answer ($ORDER)"
