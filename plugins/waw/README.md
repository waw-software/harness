# waw: commander + workers for Claude Code

The main session is the **commander**: it talks to you, decides, briefs workers, checks what
they deliver and opens the pull request. **Workers** are separate, sandboxed Claude Code or
Codex sessions, each role on the model and route you pick. A model of another family reviews the
code.

## What you get

| Part | What it does |
|------|--------------|
| `/configure` | Checks what is installed and logged in. Proposes models per role and finds the route for each, subscriptions first (Codex/ChatGPT, claude.ai, OpenCode Go), then pay per token (OpenRouter, nexos.ai, any Anthropic-compatible gateway). Writes the config, the worker routes, the rules and the settings. |
| `/ship <task>` | From the task to a pull request: investigate, ask once, plan, build in slices, test, cross-review, deliver. |
| `/auto-pilot <task>` | `/ship` without you: a decider model answers the questions, with a time limit. |
| `/brainstorm <idea>` | Talk an idea through before any code. |
| `/task-cost` | The time and cost of each stage, and what the workers used. |
| Hooks | A push guard (no merges, no force pushes, no pushes to the default branch), worktrees in `~/worktrees/<repo>/<name>`, and a short note at session start (models, routes). |
| `bin/` | `agent.sh`, `attack.sh`, `task.sh`, `deliver.sh`, `stage.sh`, `smoke.sh` and `configure.sh` on the PATH of the Bash tool. |
| Rules | The commander rules, git delivery for GitHub and GitLab, and optionally the decisions wizard and Jira tickets. `/configure` copies them into `<config>/rules/waw/` (a plugin cannot ship a CLAUDE.md, and Claude Code skips rule files that are links); the session-start hook keeps the copies current, so do not edit them there. |

## Install

```sh
claude plugin marketplace add waw-software/harness
claude plugin install waw@harness
```

Then, in a session: `/configure` (or `/waw:configure`). Start a new session
afterwards so that the rules load.

Requirements: macOS (Seatbelt) or Linux (bubblewrap) for the worker sandbox, plus `jq`,
`python3`, `node`, `git` and `uuidgen`. Optional: `gh` or `glab`, `codex` (review, and Codex workers), `opencode`.

## Where things live

`<config>` is `$CLAUDE_CONFIG_DIR`, by default `~/.claude`.

- `<config>/waw/config`: models and routes (`AGENT_<ROLE>_MODEL`,
  `AGENT_<ROLE>_ROUTE`, `PROVIDERS`, `<P>_MODEL`). Written by `/configure`.
- `<config>/waw/workers/<route>/`: the Claude Code config dir of a worker route.
  Its `settings.json` names the endpoint and an `apiKeyHelper` that reads the key from the
  macOS keychain. The key never enters a worker's environment. Route `codex` (or
  `codex-<name>`) is the `CODEX_HOME` of Codex workers instead: its own Codex login
  (`CODEX_HOME=<dir> codex login`), and the `config.toml` and `hooks.json` that `agent.sh`
  writes.
- `<config>/waw/prices.tsv`: gateway prices, for real-dollar budgets and reports.
- `<config>/waw/state/`: worker slots, session stages, status line figures.
- `<config>/waw/plugin`: a link to the installed plugin version. The session-start
  hook keeps it current.

## What changes when you install it

- **At install** (before `/configure`), in every session of this config: the push guard (no
  merges, force pushes or pushes to the default branch from Claude's Bash), worktrees in
  `~/worktrees/<repo>/<name>`, a short note at session start, the skills and `bin/` on the
  Bash tool's PATH.
- **After `/configure`**: the commander rules in `<config>/rules/waw/` (loaded in every
  session, next to your `CLAUDE.md`, which is not touched), the settings you picked in
  `<config>/settings.json` (status line, script permissions, no attribution, model and
  effort), and `<config>/waw/`. What it replaced is backed up in `<config>/waw/backups/`, and
  what it set is recorded in `<config>/waw/applied.json` for the uninstall.

## Remove it

```sh
configure.sh uninstall            # rules, settings it set, the plugin and its marketplace
configure.sh uninstall --purge    # also logs the worker routes out and removes <config>/waw
```

Run it from a session with the plugin (`! configure.sh uninstall`), or ask Claude to remove
waw. It puts back the settings it changed, as they were before, unless you changed them
since (a backup goes to `<config>/backups/`). It never deletes keychain items (it prints the
commands) or worktrees. Without the plugin installed:
`rm -rf <config>/rules/waw`, and remove the status line and the `agent.sh`/`attack.sh`/...
permissions from `<config>/settings.json` by hand.

## Develop

```sh
bash tests/run.sh        # isolated tests of the scripts (no real model calls)
smoke.sh                 # one real worker: sandbox, guard, route (a few cents)
```

To test the plugin without touching your own `~/.claude`, use
`test-config/claude-setup-test` from the repository root. It runs Claude Code with
`CLAUDE_CONFIG_DIR=~/.claude-setup-test` and only this plugin installed.

## Worker runtimes

- **Claude Code** on `anthropic`, `opencode-go` (the OpenCode Go subscription through its
  Anthropic-compatible API, checked with GLM 5.3 and Kimi K3), or a paid gateway.
- **Codex** on route `codex`: GPT workers on the ChatGPT subscription. They get the same role
  prompt, report schema (a strict copy), guards (`hooks/codex-pre-tool.sh`), approvals and
  sandbox (a Codex permission profile: no secret reads, writes in the worktree, localhost
  only). The project's Claude Code permission rules go through `codex-policy.mjs`. A project
  whose rules it cannot follow sends the role to its fallback route. Skills: the project's
  (`.agents/skills`) and the route's (`<route dir>/skills`), not your own `~/.agents/skills`
  and not Codex's bundled ones. A Claude Code worker likewise gets its project's skills and
  its route dir's `skills/`. Design and spike notes:
  `docs/plans/2026-11-22-codex-runner.md` in the repository.

The opencode CLI serves code review and decisions only.
