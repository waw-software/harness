# providers/opencode.sh: the retry without an effort variant the model lacks.
cp "$TESTS_DIR/fixtures/fake-opencode.sh" "$TEST_ROOT/bin/opencode"
chmod 755 "$TEST_ROOT/bin/opencode"
printf 'review this\n' >"$TEST_ROOT/input.md"
ARGS_LOG=$TEST_ROOT/opencode-args.log

run_adapter() { # run_adapter <mode> <model> [<effort>]: sets rc, out, err
  rm -f "$ARGS_LOG"
  rc=0
  FAKE_OPENCODE_MODE=$1 ATTACK_MODEL=$2 ATTACK_EFFORT=${3:-} \
    bash "$SETUP_UNDER_TEST/providers/opencode.sh" "$TEST_ROOT/input.md" \
    >"$TEST_ROOT/out" 2>"$TEST_ROOT/err" || rc=$?
  out=$(cat "$TEST_ROOT/out")
  err=$(cat "$TEST_ROOT/err")
}
calls() { wc -l <"$ARGS_LOG" | tr -d ' '; }
call() { sed -n "${1}p" "$ARGS_LOG"; }

case_variant_retry() {
  run_adapter variant go/kimi high
  assert_eq "$rc" 0 "variant retry exit"
  assert_contains "$out" '| blocker |' "variant retry stdout"
  assert_contains "$err" 'note: effort high is not a variant of go/kimi; ran without it' "variant retry stderr"
  assert_eq "$(calls)" 2 "variant retry calls"
  assert_contains "$(call 1)" '--model go/kimi#high ' "first call"
  assert_contains "$(call 2)" '--model go/kimi ' "second call"
  case $(call 2) in *'#'*) fail "second call keeps a variant: $(call 2)" ;; esac
}

case_variant_in_model_not_retried() {
  run_adapter variant 'go/kimi#max'
  assert_eq "$rc" 4 "variant in model exit"
  assert_eq "$(calls)" 1 "variant in model calls"
}

case_other_failure_not_retried() {
  run_adapter fail go/kimi high
  assert_eq "$rc" 4 "other failure exit"
  assert_eq "$(calls)" 1 "other failure calls"
  assert_contains "$err" 'Error: rate limited' "other failure stderr"
}

case_ok_without_effort() {
  run_adapter ok go/kimi
  assert_eq "$rc" 0 "no effort exit (stderr: $err)"
  assert_eq "$(calls)" 1 "no effort calls"
  assert_contains "$(call 1)" '--model go/kimi ' "no effort call"
  case $(call 1) in *'#'*) fail "a variant without an effort: $(call 1)" ;; esac
}

case_variant_in_model_not_retried
case_other_failure_not_retried
case_ok_without_effort
case_variant_retry
