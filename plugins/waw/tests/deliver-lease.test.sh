#!/usr/bin/env bash
# tests/deliver-lease.test.sh — H4: deliver.sh push --force-with-lease, and mr/plain push
# unchanged. Sourced by tests/run.sh into a fresh subshell: TEST_ROOT, SETUP_UNDER_TEST and
# the runner helpers (fail, assert_eq, assert_contains, assert_exit) exist here. All
# remotes are bare repos under TEST_ROOT; glab is a fake returning fixture answers (the
# runner's sentinel is replaced); git is optionally a recording shim delegating to the real
# git. No network, no live files.
set -u

DELIVER=$SETUP_UNDER_TEST/deliver.sh
R=$TEST_ROOT/h4
mkdir -p "$R"
GLAB_LOG=$R/glab.log
GIT_LOG=$R/git.log
SHIM=$TEST_ROOT/shim
real_git=$(command -v git)
git config --global init.defaultBranch main

make_shim() { # records every git argv on one line, then delegates
  mkdir -p "$SHIM"
  cat >"$SHIM/git" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$GIT_LOG"
exec "$real_git" "\$@"
EOF
  chmod 755 "$SHIM/git"
}

make_glab() { # replaces the runner's sentinel: fixture protected branches and MR answers
  cat >"$TEST_ROOT/bin/glab" <<EOF
#!/bin/bash
printf '%s\n' "glab \$*" >> "$GLAB_LOG"
if [ "\$1" = api ]; then
  if [ -n "\${FAKE_PROTECTED:-}" ]; then printf '[{"name":"%s"}]\n' "\${FAKE_PROTECTED:-}"
  else printf '[]\n'; fi
  exit 0
fi
if [ "\$1" = mr ] && [ "\$2" = list ]; then
  if [ -n "\${FAKE_MR_URL:-}" ]; then printf '[{"web_url":"%s"}]\n' "\${FAKE_MR_URL:-}"
  else printf '[]\n'; fi
  exit 0
fi
if [ "\$1" = mr ] && [ "\$2" = create ]; then
  printf '%s\n' "\${FAKE_NEW_MR_URL:-https://gitlab.invalid/g/p/-/merge_requests/99}"
  exit 0
fi
printf 'fake glab: unexpected call: %s\n' "\$*" >&2
exit 99
EOF
  chmod 755 "$TEST_ROOT/bin/glab"
}

make_shim
make_glab

new_case() { # new_case <name> <branch>: bare origin + clone, one commit on <branch>,
  C=$R/$1; B=$2 #          pushed with upstream by plain git (setup, not deliver.sh)
  mkdir -p "$C"
  git init --bare -q "$C/origin.git"
  git init -q -b "$B" "$C/clone"
  git -C "$C/clone" remote add origin "$C/origin.git"
  git -C "$C/clone" commit -q --allow-empty -m init
  git -C "$C/clone" push -q -u origin "$B"
}

dsh() { # dsh <dir> <args...>: run the staging deliver.sh there with the shim on PATH;
  local dir=$1; shift # resets the git log, sets rc/out/err
  : >"$GIT_LOG"
  out=$(cd "$dir" && PATH="$SHIM:$PATH" "$DELIVER" "$@" 2>"$R/err"); rc=$?
  err=$(cat "$R/err")
}

osh() { git -C "$C/origin.git" rev-parse --verify "$1" 2>/dev/null; }
log_lines() { grep -c "^$1" "$GIT_LOG" 2>/dev/null || true; }

case_first_push_requires_plain_mode() {
  C=$R/first; mkdir -p "$C"
  git init --bare -q "$C/origin.git"
  git init -q -b feat/a "$C/clone"
  git -C "$C/clone" remote add origin "$C/origin.git"
  git -C "$C/clone" commit -q --allow-empty -m init
  dsh "$C/clone" push --force-with-lease
  assert_eq "$rc" 3 "lease without upstream is refused"
  assert_contains "$err" "feat/a has no origin upstream; use deliver.sh push first"
  assert_eq "$(osh refs/heads/feat/a)" "" "no remote branch appeared"
  dsh "$C/clone" push
  assert_eq "$rc" 0 "plain push succeeds"
  assert_eq "$(osh refs/heads/feat/a)" "$(git -C "$C/clone" rev-parse HEAD)" "remote has the branch"
  assert_eq "$(git -C "$C/clone" config branch.feat/a.remote)" "origin" "tracking remote set"
  assert_eq "$(git -C "$C/clone" config branch.feat/a.merge)" "refs/heads/feat/a" "tracking merge set"
}

case_rewritten_current_branch_with_pinned_lease() {
  new_case rewrite feat/x
  git -C "$C/clone" branch other
  git -C "$C/clone" push -q origin other
  local a b other
  a=$(git -C "$C/clone" rev-parse HEAD)
  other=$(osh refs/heads/other)
  git -C "$C/clone" commit -q --allow-empty --amend -m rewritten
  b=$(git -C "$C/clone" rev-parse HEAD)
  [ "$a" != "$b" ] || fail "the rewrite did not happen"
  dsh "$C/clone" push --force-with-lease
  assert_eq "$rc" 0 "lease push of the rewrite succeeds"
  assert_eq "$(osh refs/heads/feat/x)" "$b" "origin/feat/x moved to the rewrite"
  assert_eq "$(osh refs/heads/other)" "$other" "other refs unchanged"
  assert_eq "$(log_lines push)" "1" "exactly one push"
  local want='push --force-with-lease=feat/x:'"$a"' origin HEAD:refs/heads/feat/x'
  grep -Fqx "$want" "$GIT_LOG" || fail "exact lease argv: got [$(cat "$GIT_LOG")]"
  grep -Eq '^push .*(--force$| -f$|--force-with-lease )' "$GIT_LOG" &&
    fail "unpinned lease or plain force reached git"
  grep -q '^fetch' "$GIT_LOG" && fail "lease mode fetched"
}

case_stale_lease_preserves_remote_work() {
  new_case stale feat/y
  local a b c
  a=$(git -C "$C/clone" rev-parse HEAD)
  git clone -q --branch feat/y "$C/origin.git" "$C/clone2"
  git -C "$C/clone2" commit -q --allow-empty -m advanced
  git -C "$C/clone2" push -q origin feat/y
  c=$(osh refs/heads/feat/y)
  git -C "$C/clone" commit -q --allow-empty --amend -m rewritten
  b=$(git -C "$C/clone" rev-parse HEAD)
  [ "$a" != "$b" ] || fail "the rewrite did not happen"
  dsh "$C/clone" push --force-with-lease
  assert_eq "$rc" 1 "stale lease is rejected"
  assert_contains "$err" "lease push failed"
  assert_eq "$(osh refs/heads/feat/y)" "$c" "remote work preserved"
  assert_eq "$(git -C "$C/clone" rev-parse refs/remotes/origin/feat/y)" "$a" "tracking ref not refreshed"
  assert_eq "$(log_lines fetch)" "0" "no fetch"
  assert_eq "$(log_lines push)" "1" "no retry"
}

case_protected_and_wrong_upstream() {
  local before
  for b in main develop 'release/1'; do
    new_case "prot-$b" "$b"
    before=$(osh "refs/heads/$b")
    dsh "$C/clone" push
    assert_eq "$rc" 3 "plain push of $b refused"
    assert_contains "$err" "protected"
    dsh "$C/clone" push --force-with-lease
    assert_eq "$rc" 3 "lease push of $b refused"
    assert_contains "$err" "protected"
    assert_eq "$(osh "refs/heads/$b")" "$before" "$b unchanged on origin"
  done
  # the remote's default branch
  C=$R/prot-default; mkdir -p "$C"
  git init --bare -q "$C/origin.git"
  git -C "$C/origin.git" symbolic-ref HEAD refs/heads/trunk
  git init -q -b trunk "$C/clone"
  git -C "$C/clone" remote add origin "$C/origin.git"
  git -C "$C/clone" commit -q --allow-empty -m init
  git -C "$C/clone" push -q -u origin trunk
  before=$(osh refs/heads/trunk)
  dsh "$C/clone" push
  assert_eq "$rc" 3 "plain push of the default refused"
  dsh "$C/clone" push --force-with-lease
  assert_eq "$rc" 3 "lease push of the default refused"
  assert_contains "$err" "protected"
  assert_eq "$(osh refs/heads/trunk)" "$before" "trunk unchanged on origin"
  # the project's own protect list
  new_case prot-project warden
  mkdir -p "$C/clone/.claude/hooks/protect"
  printf 'const PROTECTED_BRANCHES = ["warden"];\n' >"$C/clone/.claude/hooks/protect/git.mjs"
  before=$(osh refs/heads/warden)
  dsh "$C/clone" push
  assert_eq "$rc" 3 "plain push of the project pattern refused"
  dsh "$C/clone" push --force-with-lease
  assert_eq "$rc" 3 "lease push of the project pattern refused"
  assert_eq "$(osh refs/heads/warden)" "$before" "warden unchanged on origin"
  # a branch the fake forge API reports as protected
  new_case prot-api api-locked
  before=$(osh refs/heads/api-locked)
  export FAKE_PROTECTED=api-locked
  dsh "$C/clone" push
  assert_eq "$rc" 3 "plain push of the api pattern refused"
  dsh "$C/clone" push --force-with-lease
  assert_eq "$rc" 3 "lease push of the api pattern refused"
  unset FAKE_PROTECTED
  assert_eq "$(osh refs/heads/api-locked)" "$before" "api-locked unchanged on origin"
  # tracking another remote
  new_case up-remote feat/w
  git init --bare -q "$C/other.git"
  git -C "$C/clone" config branch.feat/w.remote upstream
  dsh "$C/clone" push --force-with-lease
  assert_eq "$rc" 3 "another remote refused"
  assert_contains "$err" "not origin"
  assert_eq "$(osh refs/heads/feat/w)" "$(git -C "$C/clone" rev-parse HEAD)" "nothing pushed"
  # tracking another branch of origin
  new_case up-branch feat/w
  git -C "$C/clone" push -q origin feat/w:refs/heads/other
  git -C "$C/clone" config branch.feat/w.merge refs/heads/other
  dsh "$C/clone" push --force-with-lease
  assert_eq "$rc" 3 "another upstream branch refused"
  assert_contains "$err" "not its own branch"
  # the tracking ref is gone
  new_case up-missing feat/w
  git -C "$C/clone" update-ref -d refs/remotes/origin/feat/w
  dsh "$C/clone" push --force-with-lease
  assert_eq "$rc" 3 "missing tracking ref refused"
  assert_contains "$err" "no origin/feat/w to lease"
}

case_reject_force_variants() {
  new_case reject feat/r
  local before; before=$(osh refs/heads/feat/r)
  local v
  for v in "--force" "-f" "--force-with-lease=abc123" "--force-with-lease origin" \
    "--force-with-lease feat/r" "origin" "feat/r" "--mirror" "--all" "-u origin feat/r" \
    "--force-with-lease --force-with-lease"; do
    dsh "$C/clone" push $v
    assert_eq "$rc" 2 "push $v is usage"
    assert_contains "$err" "usage:"
  done
  assert_eq "$(log_lines push)" "0" "no variant pushed"
  assert_eq "$(osh refs/heads/feat/r)" "$before" "remote unchanged"
}

case_mr_stays_plain() {
  new_case mr feat/m
  printf 'description\n' >"$R/desc.md"
  local url=https://gitlab.invalid/g/p/-/merge_requests/7
  export FAKE_MR_URL=$url
  dsh "$C/clone" mr --title T --description-file "$R/desc.md" --draft --target main
  unset FAKE_MR_URL
  assert_eq "$rc" 0 "existing mr returned"
  assert_contains "$out" "an open merge request exists already: $url"
  assert_eq "$(log_lines push)" "1" "mr pushed once"
  grep -Fq 'push -u origin feat/m' "$GIT_LOG" || fail "mr used the plain push: [$(cat "$GIT_LOG")]"
  grep -q 'force-with-lease' "$GIT_LOG" && fail "a lease flag reached git from mr"
  grep -q 'mr create' "$GLAB_LOG" && fail "mr create ran although an mr exists"
  grep -Fq 'mr list --source-branch feat/m' "$GLAB_LOG" || fail "mr list was not asked"
}

case_first_push_requires_plain_mode
case_rewritten_current_branch_with_pinned_lease
case_stale_lease_preserves_remote_work
case_protected_and_wrong_upstream
case_reject_force_variants
case_mr_stays_plain
printf 'deliver-lease.test.sh: all six cases passed\n'
