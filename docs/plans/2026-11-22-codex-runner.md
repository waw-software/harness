# Plan: Codex as a worker runtime (route `codex`)

Date: 2026-11-22. Plugin: `waw` (plugins/waw). Status: waves 0-3 done (tests: 8/8, fake Codex); wave 4 live checks done except the `/ship` (see the end).

## Goal

Any worker role (investigator, developer, reviewer, tester) can run as a Codex session on the
ChatGPT subscription: `AGENT_<ROLE>_ROUTE="codex"`, `AGENT_<ROLE>_MODEL="gpt-6.2-sol"`. The
commander works with it exactly as with a Claude Code worker: `agent.sh run`, events,
`answer`, `steer`, `stop`, `--resume`, `ps`, `log`, `report`, slots, budgets by time. The
same guards hold: scope, no git writes, no installs, push guard, OS sandbox, no secrets.

## What the probe showed (codex-cli 0.167.0, 2026-11-22)

One run in a throwaway repository, with its own `CODEX_HOME` (hooks.json) and `auth.json`
linked from `~/.codex`:

- `codex exec --json` streams JSONL: `thread.started` (`thread_id`, the session id for
  resume), `item.started` / `item.completed` with `type` `command_execution` (`command`,
  `exit_code`, `aggregated_output`), `agent_message`, `error`, and `turn.completed` with
  `usage` (`input_tokens`, `cached_input_tokens`, `output_tokens`).
- `--output-schema <file>` + `-o <file>`: the final message is JSON in the schema. The schema
  must be strict (every property required, `additionalProperties: false`). Our role schemas
  are not, so a strict copy is derived at run time.
- Hooks: `$CODEX_HOME/hooks.json` uses the same format as Claude Code. `PreToolUse` gets the
  same payload (`tool_name: "Bash"`, `tool_input.command`, `cwd`, `session_id`), so
  `worker-guard.sh` and `guard-push.sh` can be reused. A blocked call produces no event in the
  stream, so the guard has to raise BLOCKED itself. Hooks need persisted trust or
  `--dangerously-bypass-hook-trust`. That is safe here, because the hooks file is ours.
- `--sandbox workspace-write` (Seatbelt): writes in the cwd and `--add-dir` only, and `.git`
  stays read-only. The blocked `git commit` failed there too. Network is off by default.
- `codex exec resume <thread_id> "<message>"` continues a session (used by `--resume` and `steer`).

Wave 0 (spike, 2026-11-22) settled the unknowns:
- U1, reads: yes. A permission profile in `config.toml` (`default_permissions = "worker"`,
  `[permissions.worker.filesystem]`) with `":root" = "read"`, `"<path>" = "deny"` and
  `":workspace_roots"` `"." = "write"` blocked reads of a denied dir, `~/.ssh` and
  `~/Library/Keychains`. `security find-generic-password` found nothing (exit 44). It blocked
  writes outside the worktree and into `.git`, and blocked the network (DNS failed). The worker
  gets the same deny list as the Claude sandbox (SECRET_PATHS in agent.sh). D2 is therefore
  not needed. Profiles and `--sandbox` / `sandbox_mode` must not be mixed.
- U2, edits: `PreToolUse` fires for file edits with `tool_name: "apply_patch"`, and
  `tool_input.command` is the patch text. The paths are in its `*** Add/Update/Delete File:
  <path>` lines, and worker-guard learns to read them. The stream reports the edit as
  `file_change` with `changes[].path`.
- U3, blocking: stdout `{"hookSpecificOutput":{"hookEventName":"PreToolUse",
  "permissionDecision":"deny","permissionDecisionReason":"..."}}` blocks, and the model sees
  the reason (documented too: exit 2 + stderr, and `decision: "block"`). Hooks inherit the
  environment of the codex process (`AGENT_ROLE`, `AGENT_SCOPE` were there). A block shows up
  only on stderr (`codex_core::tools::router: Command blocked by PreToolUse hook`), not in
  the JSONL stream, so the guard writes BLOCKED itself.
- U4, long calls: `sleep 150` finished normally. The 8-minute ask.sh wait is checked in wave 2.
- U5, instructions: `-c "developer_instructions=$(jq -Rs . file)"` carries a multi-line role
  prompt, and the model followed it.
- U6, features: `--strict-config` accepts `web_search = "disabled"`, `[features] apps = false,
  multi_agent = false, memories = false`, `[plugins._default] enabled = false`.
- Environment: `[shell_environment_policy] inherit = "core"` kept a test token (and
  `AGENT_ROLE`) out of the model's shell. ask.sh needs `AGENT_*` there, so the route adds them
  with `filters` (`"AGENT_*" = "include"`).
- Still to check in wave 1: localhost from the sandbox (tests with a dev server). curl to a
  closed port gave "connection refused", which suggests it is allowed. If it is not,
  `[permissions.worker.network] allow_local_binding`.

## Design

- **Route `codex`**: `<home>/workers/codex/` is the worker's `CODEX_HOME`. It holds
  `config.toml` (no MCP, no plugins, our feature switches), `hooks.json` (worker-guard,
  push guard, approval hook), and the login (D1). It is a route like the others, so
  `route_of`, `models`, `sandbox-check`, `/configure` and the status line see it.
- **agent.sh**: one runner per route kind. `runner_of <route>` is `claude` or `codex`.
  Everything around the process stays shared: slots, registry, events.log, runs.tsv,
  steer, stop, timeout, tester-after-developer. Only these four parts differ:
  1. *Start*: `codex exec --json -C <cwd> --add-dir <run dir> --sandbox workspace-write
     --output-schema <strict schema> -o <name>.result.json -m <model>
     -c model_reasoning_effort=... -c <instructions>` with the brief on stdin, in a clean
     environment (the same unset list as today, plus `ORCA_*`).
  2. *Resume / steer*: `codex exec resume <thread_id> -` with the message on stdin.
  3. *Following*: a jq formatter for the Codex stream, giving the same step lines
     (`[dev-a 1m05s] Bash pnpm test`) and the same events: FAILING after 3 non-zero exits in
     a row, STALLED, TIMEOUT. BLOCKED comes from the guard: `worker-guard.sh` writes the
     event line to `AGENT_EVENTS` when it blocks. Claude workers get the same line, so both
     runtimes behave alike.
  4. *Usage*: tokens from `turn.completed`. Dollars: `sub` (subscription) in runs.tsv and in
     `agent.sh report`.
- **Budget**: Codex has no `--max-budget-usd`. For a Codex worker the budget is `--timeout`.
  A token ceiling was dropped: `codex exec` reports usage only at `turn.completed`, at the end.
- **Approvals of guarded files** (the APPROVAL flow): Codex has no permission-prompt tool.
  A `PreToolUse` approval hook takes over. For an edit of a guarded path that `--grant` does
  not cover, it writes `<name>.approvals/<aid>.request.json`, raises APPROVAL, and waits up to
  8 minutes for `agent.sh approve|deny`. That is the same contract as approve-mcp.mjs,
  implemented as a hook. It depends on U2.
- **Secrets**: the route's permission profile denies reads of SECRET_PATHS (as the Claude
  sandbox does), and `shell_environment_policy` keeps keys out of the model's shell.
- **Projects with strict permissions** (`disableBypassPermissionsMode`, deny/ask rules in
  `.claude/settings.json`): `codex-policy.mjs` enforces them (D3). Read rules become sandbox
  denies, Bash/Edit/Write rules are checked in the hook, and with bypass disabled only the
  role's pre-approved commands (allowed_of) and the project's allow rules pass.
- **Install workers** (`--allow-install`): the Codex network proxy allows the package
  registries only (`[permissions.worker.network.domains]`, with `features.network_proxy`), and
  the pnpm/npm stores are writable, as for a Claude worker.
- **Review (attack.sh)**: unchanged. `codex` is already a review provider.
- **/configure**: route type `codex` (no keychain; the login check is
  `CODEX_HOME=<dir> codex login status`). In the search order, GPT workers become
  `codex → opencode-go → openrouter → nexos`. The `check` and `ping` commands get Codex cases.
- **smoke.sh**: runs on the developer's route, now including codex. It adds checks for the
  Codex sandbox and the guard's BLOCKED line.

## Work, in waves

| Wave | Task | Files | Proof |
|------|------|-------|-------|
| 0 | Spike U1-U6 (done) | this file | answers above |
| 1 | Codex route home: config.toml, hooks.json, login check | `scripts/agent.sh` (route_dir, runner_of), `scripts/codex-home.sh` (new) | `agent.sh models` and `sandbox-check` with route codex |
| 1 | Strict schema from a role schema | `scripts/lib/strict-schema.jq` (new) | unit test: every schema becomes valid strict |
| 1 | Guard: reads apply_patch paths, writes BLOCKED itself | `scripts/hooks/worker-guard.sh` | guard tests with Codex payloads (Bash, apply_patch) |
| 2 | Codex runner: start, follow, result, usage, resume, steer, stop | `scripts/agent.sh` | `tests/codex-runner.test.sh` with `tests/fixtures/fake-codex.sh` (JSONL replay) |
| 2 | Approval hook | `scripts/hooks/approve-hook.sh` (new) | test: request, approve, deny, timeout |
| 3 | /configure: route type codex, search order, check, ping | `scripts/configure.sh`, `skills/configure/SKILL.md`, `tests/configure.test.sh` | tests + `configure.sh check` |
| 3 | smoke.sh on codex, README, commander rules | `scripts/smoke.sh`, `README.md`, `rules/commander.md` | `smoke.sh` with developer on codex: all PASS |
| 4 | Live run in the test config: one `/ship` of a small task with investigator and tester on codex | — | the task's PR, `agent.sh report` |

## Decisions for the developer

- D1 (decided): the route has its own login. Run `CODEX_HOME=<home>/workers/codex codex login`
  once (ChatGPT). `~/.codex` is never touched.
- D2: not needed. The sandbox denies reads (U1).
- D3 (decided): the approval hook enforces the project's Claude Code permission rules: a
  deny rule blocks, and an ask rule raises APPROVAL to the commander. If a rule cannot be
  translated, agent.sh does not start Codex in that project, and the role uses its fallback
  route (`AGENT_<ROLE>_FALLBACK_ROUTE`, or anthropic).

## Risks

- Codex changes fast (0.167 today): the stream format and the hook payload can change. The
  fixture tests pin today's format, and `smoke.sh` after a Codex update shows a break.
- The ChatGPT plan's limits are shared with your own Codex use: five parallel workers can
  use them up. The slot limit (5) holds, and the developer role can stay on Claude or Go.

## Done (2026-11-22)

- `scripts/agent.sh`: runner_of, codex_home, codex_run_config, the fallback route, Codex start,
  resume and steer, the session from the stream, nulls dropped from the report, cost `sub`.
- `scripts/lib/codex-stream.jq` (stream to stream-json), `scripts/lib/strict-schema.jq`,
  `scripts/lib/approvals.mjs` (shared with approve-mcp.mjs), `scripts/codex-policy.mjs`,
  `scripts/hooks/codex-pre-tool.sh`, `scripts/roles/codex.md` (the Codex note to the role prompt).
- `scripts/configure.sh`: route type codex (dir only; login check; `ping route:<route>`), the
  workers' `effort`, `fallback_route` and `fallback_model`; `skills/configure/SKILL.md`: GPT
  workers search codex first. `scripts/smoke.sh`: a codex developer route.
- Tests: `tests/codex-runner.test.sh` (fake codex: report, session, args, env, resume,
  failure, stop, no login, fallback, hook: guards, project rules, BLOCKED, approvals, grants),
  `tests/configure.test.sh` (codex route).

## Wave 4, live (2026-11-22, test config, gpt-6.2-sol on the route's ChatGPT login)

- `configure.sh ping route:codex gpt-6.2-sol`: ok.
- `smoke.sh` with the developer on codex: all checks passed. Two fixes came out of it:
  - The Codex network proxy ends the whole command when it blocks a host (`exec_command failed:
    ProcessFailed ... domain is not on the allowlist`), so the probe now checks the network
    last and writes "blocked" first.
  - The Codex model would not run the `git commit` the brief asked for, because its rules forbid
    git writes. If the worker did not try, smoke.sh now calls the guard hook directly. If the
    worker tried and no BLOCKED event came, the check still fails.
- `lib/codex-stream.jq` also unwraps `/bin/bash -c '...'` (Codex uses `-c` as well as `-lc`).
- Live guard: a Codex worker's `npm install left-pad` was blocked by worker-guard through
  hooks.json, and the BLOCKED event reached events.log. The model had added `npm_config_*`
  prefixes to the command; the guard still matched it.
- U4 (ask.sh wait): a Codex worker held `ask.sh` for the full 8 minutes (11:48:19 to
  11:56:20), got the timeout and went on with its recommendation. In a second run, answered
  after a minute, it went on with the answer ("beta", not the recommended "alpha").
- Skills: the first live worker read the developer's own `~/.agents/skills/orchestration`
  (Codex loads `~/.agents/skills` whatever `CODEX_HOME` is, plus its bundled skills). Now a
  Codex worker gets what a Claude worker gets: the project's skills (`.agents/skills`) and the
  route's (`<route dir>/skills`). Bundled skills are off (`[skills.bundled] enabled = false`).
  The developer's own skills are turned off per run (`skills.config`, one `enabled = false`
  per SKILL.md), and their folder is denied to the worker's shell. `features.skip_host_skill_discovery`
  and `skills.include_instructions = false` were tried: the first did not hide them, the second
  hid all skills.
- `lib/codex-stream.jq` also unwraps double-quoted `/bin/zsh -lc "..."`.

Left: one `/ship` in the test config with GPT roles on codex (after `/configure`).
