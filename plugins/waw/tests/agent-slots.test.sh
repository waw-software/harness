#!/usr/bin/env bash
# tests/agent-slots.test.sh — H1b: admission and cleanup in agent.sh.
# Sourced by tests/run.sh into a fresh subshell: TEST_ROOT, SETUP_UNDER_TEST, AGENT_STATE_DIR
# and the runner helpers (fail, assert_eq, assert_contains, assert_exit) exist here.
# The claude sentinel is replaced by tests/fixtures/fake-claude.sh, so every run below
# exercises real agent.sh admission, steering and cleanup without a model. Eight cases.
set -u

AGENT=$SETUP_UNDER_TEST/agent.sh
ROOT=$TEST_ROOT/agent-cases
STARTS=$TEST_ROOT/claude-starts.log
ARGS=$TEST_ROOT/claude-args.log
RUNS_REC=$ROOT/runs.txt
mkdir -p "$ROOT"
cp "$TESTS_DIR/fixtures/fake-claude.sh" "$TEST_ROOT/bin/claude"
chmod 755 "$TEST_ROOT/bin/claude"

slots_count() { bash "$AGENT" count; }
live_fakes() { pgrep -f "$TEST_ROOT/bin/claude" 2>/dev/null | wc -l | tr -d ' '; }
pid_gone() { ! kill -0 "$1" 2>/dev/null; }
starts_of() { awk -v n="$1" '$1 == n' "$STARTS" 2>/dev/null | wc -l | tr -d ' '; }
starts_line_of() { awk -v n="$1" '$1 == n' "$STARTS" 2>/dev/null | tail -n 1; }
starts_total() { wc -l <"$STARTS" 2>/dev/null | tr -d ' '; }
pid_of() { awk -v n="$1" '$1 == n {print $2}' "$RUNS_REC"; }
run_status_of() { jq -r '.run_status // empty' "$1" 2>/dev/null; }
holder_field() { jq -r "$1" "$AGENT_STATE_DIR/slots.json" 2>/dev/null; }
assert_final_line() { # assert_final_line <name> <status> <run log> <result path>: the whole line
  local line
  line=$(cat "$3")
  case $line in
    "$1 $2 turns=0 time="[0-9]*"s result=$4 session=-") ;;
    *) fail "final line: [$line] is not <$1 $2 turns=0 time=<n>s result=$4 session=->" ;;
  esac
}
wait_for() { # wait_for <seconds> <condition string>: re-evaluated on every poll
  local n=0 max=$(($1 * 10)); shift
  while ! eval "$*"; do
    n=$((n + 1)); [ "$n" -le "$max" ] || return 1
    sleep 0.1
  done
}
until_within() { # until_within <seconds> <command...> (arguments without substitutions)
  local n=0 max=$(($1 * 10)); shift
  while ! "$@"; do
    n=$((n + 1)); [ "$n" -le "$max" ] || return 1
    sleep 0.1
  done
}
LAST_PID=''
start_run() { # start_run <name> <case-dir> [agent.sh run args...]; FAKE_*/AGENT_* env from caller
  local name=$1 cdir=$2; shift 2
  mkdir -p "$cdir/dir-$name"
  bash "$AGENT" run --role developer --brief "$cdir/brief.md" --out "$cdir/out-$name" \
    --cwd "$cdir/dir-$name" --name "$name" "$@" >"$cdir/run-$name.log" 2>"$cdir/run-$name.err" &
  LAST_PID=$!
  echo "$name $LAST_PID" >>"$RUNS_REC"
}
mkcase() { mkdir -p "$1"; printf 'hold one worker slot for the H1b test\n' >"$1/brief.md"; }
stop_run() { bash "$AGENT" stop "$1" >/dev/null; }

case_six_runs_start_at_most_five() {
  local c=$ROOT/c1; mkcase "$c"
  local i queued='' released='' live
  some_queued() { for i in 1 2 3 4 5 6; do [ -s "$c/run-c1-w$i.err" ] && return 0; done; return 1; }
  for i in 1 2 3 4 5 6; do
    FAKE_CLAUDE_MODE=barrier FAKE_CLAUDE_BARRIER="$c/go-$i" start_run "c1-w$i" "$c" --quiet
  done
  wait_for 25 '[ "$(live_fakes)" = 5 ]' || fail "five holders never started (live=$(live_fakes))"
  live=$(live_fakes)
  if [ "$live" != 5 ]; then sleep 1; live=$(live_fakes); fi # a snapshot may catch a startup subshell
  assert_eq "$live" "5" "at most five fake Claude runs at once"
  assert_eq "$(slots_count)" "5" "count counts admitted workers only"
  assert_contains "$(bash "$AGENT" ps)" "WAITING FOR WORKER SLOT" "queued run is visible in ps"
  wait_for 25 some_queued || fail "no run of the six ever queued"
  for i in 1 2 3 4 5 6; do
    if [ -s "$c/run-c1-w$i.err" ]; then
      assert_eq "$(cat "$c/run-c1-w$i.err")" "[c1-w$i] waiting for a worker slot (5/5)" "one waiting line"
      queued=$i
    fi
  done
  [ -n "$queued" ] || fail "no run of the six ever queued"
  for i in 1 2 3 4 5 6; do
    if [ "$i" != "$queued" ] && [ -z "$released" ]; then released=$i; fi
  done
  touch "$c/go-$released"
  assert_exit 0 wait "$(pid_of "c1-w$released")"
  wait_for 25 "[ \$(starts_of c1-w$queued) = 1 ]" || fail "the queued run never started after a release"
  assert_eq "$(live_fakes)" "5" "the queued run took the freed slot"
  for i in 1 2 3 4 5 6; do
    if [ "$i" != "$released" ]; then touch "$c/go-$i"; fi
  done
  for i in 1 2 3 4 5 6; do
    if [ "$i" != "$released" ]; then assert_exit 0 wait "$(pid_of "c1-w$i")"; fi
  done
  assert_eq "$(cat "$c/run-c1-w$queued.err")" "[c1-w$queued] waiting for a worker slot (5/5)" \
    "the waiting line exactly once"
  assert_eq "$(slots_count)" "0" "all released at the end"
}

case_queue_timeout_and_queued_stop() {
  local c=$ROOT/c2; mkcase "$c"
  local i res
  for i in 1 2 3 4 5; do FAKE_CLAUDE_MODE=hang start_run "c2-h$i" "$c" --quiet; done
  wait_for 25 '[ "$(live_fakes)" = 5 ]' || fail "holders never started (live=$(live_fakes))"
  assert_eq "$(slots_count)" "5"
  # a sixth run times out waiting (exit 7), without starting Claude or leaking a slot
  FAKE_CLAUDE_MODE=ok AGENT_SLOT_WAIT_SECONDS=1 start_run "c2-t" "$c" --quiet
  assert_exit 7 wait "$(pid_of c2-t)"
  res=$c/out-c2-t/c2-t.result.json
  assert_final_line c2-t slot-timeout "$c/run-c2-t.log" "$res"
  assert_eq "$(run_status_of "$res")" "slot-timeout" "result file run_status"
  assert_eq "$(jq 'length' "$res")" "1" "no role fields in the pre-admission result"
  assert_eq "$(starts_of c2-t)" "0" "the timed-out run started no Claude"
  assert_eq "$(slots_count)" "5" "the timeout leaked no slot"
  # a queued run stopped before admission: exit 6, same final line shape, no leaked slot
  FAKE_CLAUDE_MODE=ok AGENT_SLOT_WAIT_SECONDS=30 start_run "c2-q" "$c" --quiet
  until_within 25 test -s "$c/run-c2-q.err" || fail "c2-q never queued"
  assert_exit 0 stop_run c2-q
  assert_exit 6 wait "$(pid_of c2-q)"
  assert_final_line c2-q stopped "$c/run-c2-q.log" "$c/out-c2-q/c2-q.result.json"
  assert_eq "$(run_status_of "$c/out-c2-q/c2-q.result.json")" "stopped-before-admission"
  assert_eq "$(starts_of c2-q)" "0" "the stopped run started no Claude"
  assert_eq "$(slots_count)" "5" "the queued stop leaked no slot"
  for i in 1 2 3 4 5; do stop_run "c2-h$i"; done
  for i in 1 2 3 4 5; do assert_exit 6 wait "$(pid_of "c2-h$i")"; done
  assert_eq "$(slots_count)" "0" "holders released"
}

case_all_exit_paths_release() {
  local c=$ROOT/c3; mkcase "$c"
  FAKE_CLAUDE_MODE=ok start_run "c3-ok" "$c" --quiet
  assert_exit 0 wait "$(pid_of c3-ok)"
  assert_eq "$(slots_count)" "0" "released after a valid report"
  FAKE_CLAUDE_MODE=no-result start_run "c3-no" "$c" --quiet
  assert_exit 4 wait "$(pid_of c3-no)"
  assert_eq "$(slots_count)" "0" "released after no report"
  FAKE_CLAUDE_MODE=hang start_run "c3-to" "$c" --quiet --timeout 1
  assert_exit 5 wait "$(pid_of c3-to)"
  assert_eq "$(slots_count)" "0" "released after the watchdog"
  FAKE_CLAUDE_MODE=hang start_run "c3-st" "$c" --quiet
  wait_for 25 '[ "$(live_fakes)" = 1 ]' || fail "c3-st never started (live=$(live_fakes))"
  assert_exit 0 stop_run c3-st
  assert_exit 6 wait "$(pid_of c3-st)"
  assert_eq "$(slots_count)" "0" "released after stop"
  FAKE_CLAUDE_MODE=hang start_run "c3-sg" "$c" --quiet
  wait_for 25 '[ "$(live_fakes)" = 1 ]' || fail "c3-sg never started (live=$(live_fakes))"
  kill -TERM "$(pid_of c3-sg)"
  assert_exit 130 wait "$(pid_of c3-sg)"
  assert_eq "$(slots_count)" "0" "released after TERM"
}

case_steer_keeps_one_slot() {
  local c=$ROOT/c4; mkcase "$c"
  local lease owner
  FAKE_CLAUDE_MODE=barrier FAKE_CLAUDE_BARRIER="$c/go" start_run "c4-s" "$c" --quiet
  wait_for 25 '[ "$(live_fakes)" = 1 ]' || fail "c4-s never started (live=$(live_fakes))"
  lease=$(holder_field '.holders[0].lease')
  owner=$(holder_field '.holders[0].owner_pid')
  assert_exit 0 bash "$AGENT" steer c4-s "continue with the plan"
  wait_for 25 '[ "$(starts_of c4-s)" = 2 ]' || fail "steering never relaunched the worker"
  assert_contains "$(starts_line_of c4-s)" "--resume" "the resumed segment resumes the session"
  assert_eq "$(live_fakes)" "1" "one current fake worker while steered"
  assert_eq "$(holder_field '.holders[0].lease')" "$lease" "steering keeps the same lease"
  assert_eq "$(holder_field '.holders[0].owner_pid')" "$owner" "steering keeps the owner"
  assert_eq "$(slots_count)" "1" "steering never released the slot"
  touch "$c/go"
  assert_exit 0 wait "$(pid_of c4-s)"
  assert_eq "$(slots_count)" "0" "completion frees the slot"
}

case_death_at_launch_barrier() {
  local c=$ROOT/c5 sd=$ROOT/c5-state; mkcase "$c"; mkdir -p "$sd"
  local orphan
  c5count() { python3 -I "$SETUP_UNDER_TEST/slots.py" count --state-dir "$sd"; }
  # a wrapper TERMed while it holds a lease but before the child is bound: no Claude start
  FAKE_CLAUDE_MODE=ok AGENT_STATE_DIR=$sd AGENT_MAX_WORKERS=1 \
    AGENT_TEST_PAUSE_AFTER_ACQUIRE="$c/pause-1" start_run "c5-a" "$c" --quiet
  wait_for 25 '[ "$(c5count)" = 1 ]' || fail "the lease was never held at the pause"
  kill -TERM "$(pid_of c5-a)"
  assert_exit 130 wait "$(pid_of c5-a)"
  assert_eq "$(starts_of c5-a)" "0" "no Claude start before the barrier"
  assert_eq "$(c5count)" "0" "the signal released the lease"
  # a wrapper SIGKILLed after binding: the bound child keeps the slot until it exits
  FAKE_CLAUDE_MODE=hang AGENT_STATE_DIR=$sd AGENT_MAX_WORKERS=1 start_run "c5-b" "$c" --quiet
  wait_for 25 '[ "$(live_fakes)" = 1 ]' || fail "c5-b never started (live=$(live_fakes))"
  kill -9 "$(pid_of c5-b)"
  wait "$(pid_of c5-b)" 2>/dev/null || true
  assert_eq "$(c5count)" "1" "the dead wrapper keeps the slot while its child lives"
  FAKE_CLAUDE_MODE=ok AGENT_STATE_DIR=$sd AGENT_MAX_WORKERS=1 AGENT_SLOT_WAIT_SECONDS=1 \
    start_run "c5-c" "$c" --quiet
  assert_exit 7 wait "$(pid_of c5-c)"
  assert_eq "$(live_fakes)" "1" "no second fake worker while the orphan holds the slot"
  orphan=$(cat "$c/out-c5-b/c5-b.pid")
  kill -TERM "$orphan"
  wait_for 25 '[ "$(c5count)" = 0 ]' || fail "the slot never came back after the orphan exited"
}

case_staging_paths_only() {
  local c=$ROOT/c6; mkcase "$c"
  local settings mcp prompt row
  FAKE_CLAUDE_MODE=barrier FAKE_CLAUDE_BARRIER="$c/go" start_run "c6-p" "$c" --quiet
  wait_for 25 '[ "$(starts_of c6-p)" = 1 ]' || fail "c6-p never started"
  row=$(ls "$AGENT_STATE_DIR"/workers/*.tsv 2>/dev/null) || fail "no registry row under AGENT_STATE_DIR"
  assert_contains "$(cat "$row")" "$TEST_ROOT" "the registry row points into the test root"
  settings=$(awk '/^=== c6-p$/{f=1; next} f && $1 == "--settings" {getline; print; exit}' "$ARGS")
  assert_contains "$settings" "$SETUP_UNDER_TEST/hooks/worker-guard.sh" "worker guard from the copy"
  assert_contains "$settings" "$AGENT_PUSH_GUARD" "push guard override honoured"
  if [ "${settings#*home/.claude/hooks}" != "$settings" ]; then fail "live push-guard path leaked"; fi
  mcp=$(awk '/^=== c6-p$/{f=1; next} f && $1 == "--mcp-config" {getline; print; exit}' "$ARGS")
  assert_contains "$mcp" "$SETUP_UNDER_TEST/approve-mcp.mjs" "approval tool from the copy"
  prompt=$(awk '/^=== c6-p$/{f=1; next} f && $1 == "--append-system-prompt-file" {getline; print; exit}' "$ARGS")
  case $prompt in "$TEST_ROOT"/*) ;; *) fail "role prompt not under TEST_ROOT: $prompt";; esac
  { sed "s#@ASK_SH@#$SETUP_UNDER_TEST/ask.sh#g" "$SETUP_UNDER_TEST/roles/common.md"; printf '\n'
    cat "$SETUP_UNDER_TEST/roles/developer.md"; } >"$c/expected-prompt"
  grep -q '@ASK_SH@' "$prompt" && fail "the ask.sh placeholder is left in the prompt"
  cmp -s "$prompt" "$c/expected-prompt" || fail "role prompt not built from the copy's roles"
  assert_eq "$(ls -A "$TEST_ROOT/audit" 2>/dev/null | wc -l | tr -d ' ')" "0" "no sentinel call"
  touch "$c/go"
  assert_exit 0 wait "$(pid_of c6-p)"
  assert_eq "$(slots_count)" "0" "released"
}

case_stop_between_acquire_and_launch() {
  local c=$ROOT/c7; mkcase "$c"
  FAKE_CLAUDE_MODE=ok AGENT_TEST_PAUSE_AFTER_ACQUIRE="$c/pause-1" start_run "c7-p" "$c" --quiet
  wait_for 25 '[ "$(slots_count)" = 1 ]' || fail "c7-p never paused with its lease"
  assert_exit 0 stop_run c7-p
  assert_exit 6 wait "$(pid_of c7-p)"
  assert_final_line c7-p stopped "$c/run-c7-p.log" "$c/out-c7-p/c7-p.result.json"
  assert_eq "$(run_status_of "$c/out-c7-p/c7-p.result.json")" "stopped-before-admission"
  assert_eq "$(starts_of c7-p)" "0" "no fake Claude start between acquire and launch"
  assert_eq "$(slots_count)" "0" "zero leases left"
}

case_sigkill_before_bind_child_exits() {
  local c=$ROOT/c10 childpid; mkcase "$c"
  # the gated child must notice the wrapper's death (its own $$ is agent.sh's pid there);
  # the wrapper's watchdog and log follower are orphaned by a SIGKILL and are not counted
  FAKE_CLAUDE_MODE=ok AGENT_TEST_PAUSE_BEFORE_GATE="$c/pause-gate" start_run "c10-k" "$c" --quiet
  wait_for 25 '[ "$(slots_count)" = 1 ]' || fail "c10-k never held a slot"
  wait_for 25 "test -s '$c/out-c10-k/c10-k.pid'" || fail "c10-k never bound its gated child"
  childpid=$(cat "$c/out-c10-k/c10-k.pid")
  kill -9 "$(pid_of c10-k)"
  wait_for 10 "pid_gone $childpid" || fail "the gated child outlived the wrapper"
  assert_eq "$(starts_of c10-k)" "0" "fake Claude never started"
  wait_for 10 '[ "$(slots_count)" = 0 ]' || fail "the dead owner was not reaped"
}

case_stop_after_gate_before_exec() {
  local c=$ROOT/c9 line; mkcase "$c"
  FAKE_CLAUDE_MODE=ok AGENT_TEST_PAUSE_AFTER_GATE="$c/pause-gate" start_run "c9-p" "$c" --quiet
  wait_for 25 "test -s '$c/out-c9-p/c9-p.pid'" || fail "c9-p never bound its child"
  wait_for 10 "test -e '$c/pause-gate.reached'" || fail "c9-p never reached its after-gate pause"
  assert_exit 0 stop_run c9-p
  assert_exit 6 wait "$(pid_of c9-p)"
  assert_eq "$(starts_of c9-p)" "0" "no fake Claude start after the gate"
  line=$(cat "$c/run-c9-p.log") # a stop after admission reports through the normal path
  case $line in
    "c9-p stopped turns=0 time="[0-9]*"s result=$c/out-c9-p/c9-p.result.json session="*) ;;
    *) fail "final line: [$line] is not <c9-p stopped ... result=... session=<id>>" ;;
  esac
  assert_eq "$(slots_count)" "0" "zero leases left"
  # and the child's own last stop check: the stop file is already there when it is released,
  # and nothing TERMs it on the way — it must stop before exec without starting Claude
  FAKE_CLAUDE_MODE=ok AGENT_TEST_PAUSE_AFTER_GATE="$c/pause-q" start_run "c9-q" "$c" --quiet
  wait_for 25 "test -s '$c/out-c9-q/c9-q.pid'" || fail "c9-q never bound its child"
  wait_for 10 "test -e '$c/pause-q.reached'" || fail "c9-q never reached its after-gate pause"
  : >"$c/out-c9-q/c9-q.stop"
  : >"$c/pause-q"
  assert_exit 6 wait "$(pid_of c9-q)"
  assert_eq "$(starts_of c9-q)" "0" "the released child must not start Claude once stopped"
  assert_eq "$(slots_count)" "0" "c9-q released"
}

case_one_ledger_across_install_roots() {
  local c=$ROOT/c8; mkcase "$c"
  local shared=$TEST_ROOT/home/.claude/waw/state
  local t0 n queued='' released=''
  cp -R "$SETUP_UNDER_TEST" "$c/copy-a"
  cp -R "$SETUP_UNDER_TEST" "$c/copy-b"
  t0=$(starts_total)
  for n in a-1 a-2 a-3; do
    mkdir -p "$c/dir-$n"
    FAKE_CLAUDE_MODE=barrier FAKE_CLAUDE_BARRIER="$c/go-$n" env -u AGENT_STATE_DIR \
      bash "$c/copy-a/agent.sh" run --role developer --brief "$c/brief.md" \
      --out "$c/out-$n" --cwd "$c/dir-$n" --name "c8-$n" --quiet \
      >"$c/run-$n.log" 2>"$c/run-$n.err" &
    echo "c8-$n $!" >>"$RUNS_REC"
  done
  for n in b-1 b-2 b-3; do
    mkdir -p "$c/dir-$n"
    FAKE_CLAUDE_MODE=barrier FAKE_CLAUDE_BARRIER="$c/go-$n" env -u AGENT_STATE_DIR \
      bash "$c/copy-b/agent.sh" run --role developer --brief "$c/brief.md" \
      --out "$c/out-$n" --cwd "$c/dir-$n" --name "c8-$n" --quiet \
      >"$c/run-$n.log" 2>"$c/run-$n.err" &
    echo "c8-$n $!" >>"$RUNS_REC"
  done
  # a fake is visible to pgrep a moment before it writes its start line: wait for both
  wait_for 25 '[ "$(live_fakes)" = 5 ] && [ $(( $(starts_total) - t0 )) -ge 5 ]' ||
    fail "never five live fake workers with their start lines (live=$(live_fakes), starts=$(( $(starts_total) - t0 )))"
  assert_eq "$(( $(starts_total) - t0 ))" "5" "at most five fake Claude starts across both copies"
  assert_eq "$(python3 -I "$c/copy-a/slots.py" count --state-dir "$shared")" "5" "one shared ledger"
  for n in a-1 a-2 a-3 b-1 b-2 b-3; do
    if [ -f "$c/out-$n/c8-$n.queued" ]; then queued=$n; fi
  done
  [ -n "$queued" ] || fail "no run of the six was queued"
  for n in a-1 a-2 a-3 b-1 b-2 b-3; do
    if [ -z "$released" ] && [ "$n" != "$queued" ]; then released=$n; fi
  done
  touch "$c/go-$released"
  assert_exit 0 wait "$(pid_of "c8-$released")"
  wait_for 25 "[ \$(starts_of c8-$queued) = 1 ]" || fail "the queued run never started"
  for n in a-1 a-2 a-3 b-1 b-2 b-3; do
    if [ "$n" != "$released" ]; then touch "$c/go-$n"; fi
  done
  for n in a-1 a-2 a-3 b-1 b-2 b-3; do
    if [ "$n" != "$released" ]; then assert_exit 0 wait "$(pid_of "c8-$n")"; fi
  done
  assert_eq "$(python3 -I "$c/copy-a/slots.py" count --state-dir "$shared")" "0" "shared ledger drained"
}

case_six_runs_start_at_most_five
case_queue_timeout_and_queued_stop
case_all_exit_paths_release
case_steer_keeps_one_slot
case_death_at_launch_barrier
case_staging_paths_only
case_stop_between_acquire_and_launch
case_sigkill_before_bind_child_exits
case_stop_after_gate_before_exec
case_one_ledger_across_install_roots
printf 'agent-slots.test.sh: all ten cases passed\n'
