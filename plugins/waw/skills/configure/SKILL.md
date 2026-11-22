---
name: configure
description: Set up or change the waw plugin - check what is installed and logged in, pick the model of every worker role and of the code review, find the route each model can run through (Codex subscription, OpenRouter, opencode, nexos.ai, Anthropic, another gateway), then write the config, the worker routes, the commander rules and the settings. Use when the user types /configure, or asks to set up, re-configure or change the models or providers of this setup.
---

# configure

Argument: `$ARGUMENTS`: optional, what to change ("developer model", "review only"). Empty: the
whole setup. With an argument, run the steps that concern it and keep the rest of the current
config as it is.

The engine is `${CLAUDE_PLUGIN_ROOT}/scripts/configure.sh` (below: `configure.sh`). It
detects, lists and writes. You ask, and you decide what is obvious. Talk to the developer in
their language. Every question goes through `AskUserQuestion`, one decision per step, the
recommendation first and marked "(Recommended)". Batch only questions that do not depend on
each other.

## The setup this plugin comes from (base your proposals on it)

| Role | Original model | Why |
|------|----------------|-----|
| Commander (this session) | Claude Opus 5.5, effort high | decides, briefs, checks, delivers |
| Investigator / planner | GPT 6.1 Sol | reads code and plans well, another family than the commander |
| Developer | Claude Sonnet 5.5 (trial; before: GLM 5.3 Flash, much cheaper) | writes code to a strict brief |
| Reviewer (plans, via agent.sh) | GPT 6.1 Sol | another family than the developer |
| Tester | GPT 6.1 Sol | runs checks and proves criteria |
| Code review + /auto-pilot decisions (attack.sh) | GPT 6.1 Sol | another family than the developer and the planner's draft |

The rules behind it: the code is reviewed by another model family than the one that wrote it;
the developer can be cheaper because its brief is strict; the newest model of a family
usually replaces the one above (GPT 6.2 Sol for GPT 6.1 Sol when it is available).

## How models run (what a route can do)

- **Workers** (investigator, developer, reviewer, tester) are Claude Code sessions, or Codex
  sessions. They run on a *worker route*: `codex` (GPT on the ChatGPT subscription, a Codex
  session with the same guards, sandbox and report schema; the route needs its own Codex login
  once), `anthropic` (Claude models on the developer's own account; the route needs its own
  login once), `opencode-go` (the OpenCode Go subscription through its
  Anthropic-compatible API: GLM, Kimi, DeepSeek, Qwen, MiniMax and more; the Go API key goes
  in the keychain), or a pay-per-token gateway: `openrouter`, `nexos` (nexos.ai), `custom`
  (any other Anthropic-compatible URL).
- **Code review and decisions** (attack.sh) are one-shot calls. Providers: `codex` (Codex
  CLI: GPT on a ChatGPT subscription, no per-token cost), `opencode` (opencode CLI with its
  own logins), `claude` (this session's login), `gateway` (an OpenAI-compatible URL), or any
  worker route by its name.
- A Codex worker has no dollar budget (the subscription has none; `--timeout` bounds it) and
  shares the ChatGPT plan's limits with the developer's own Codex use. In a project whose
  Claude Code permission rules Codex cannot follow, the role runs on its fallback route
  (`fallback_route`, `fallback_model` in the choices; default anthropic and sonnet): ask for
  them when a role is on codex. The opencode CLI cannot host workers.

**Subscriptions first, always.** A model the developer already pays a flat fee for (Codex /
ChatGPT, a claude.ai login, OpenCode Go, another opencode subscription login such as GitHub
Copilot) is offered before any pay-per-token route (OpenRouter, nexos, a custom gateway, an
API key), and is the recommended option whenever it serves the model. Pay-per-token routes
are the fallback, or the way to a model no subscription has. Say what each subscription
limits, when detect or the docs say so (OpenCode Go: a 5-hour limit of 20 % and a weekly
limit of 50 % of the monthly allowance).

Route search order for a model family. Take the first available one. Name the others only
when there is a real choice:

| Family | Review / decide (attack.sh) | Workers (agent.sh) |
|--------|-----------------|---------|
| GPT | codex → opencode (a subscription login that has the model) → openrouter → nexos → custom | codex → opencode-go (if Go has the model) → openrouter → nexos → custom |
| Claude | claude (this login) → anthropic → opencode (subscription) → openrouter → nexos | anthropic → opencode-go (if Go has the model) → openrouter → nexos |
| Others (GLM, Kimi, DeepSeek, Qwen, MiniMax, Gemini, ...) | opencode (`opencode-go/<id>`, subscription) → openrouter → nexos → custom | opencode-go → openrouter → nexos → custom |

"Available" means one of these: installed and logged in, the key is in the keychain, or the
key is in the environment (see detect). An opencode login marked `[pay per token]` (an
OpenRouter key inside opencode) counts as pay per token, like OpenRouter itself. Between paid
gateways, prefer the one the developer already has a key for.

## Steps

### 1. Check (no questions)

Run `configure.sh detect`. Show the developer a summary of at most 8 lines: Claude Code and
its login, the tools that are missing, and each model source with its state and its billing
mark from detect. List the subscriptions first (codex, the claude.ai login, OpenCode Go and
other opencode subscription logins), then the pay-per-token ones (OpenRouter key in the
keychain or only in the environment, nexos key, opencode key logins). Then what is configured
already (config, routes, rules, status line). A
current config or a legacy one (`~/.config/agentic-setup/config`, `~/.claude-nexos`): its
models are the starting point of the proposals below. A missing tool that the setup needs
(jq, python3, node, git, the OS sandbox): say so, with the install command, and go on.

### 2. Models per role (one question)

Propose the plan of the original setup, adapted to what detect found and to the newest
versions there: `configure.sh models codex`, `configure.sh models opencode-go`,
`configure.sh models anthropic`, `configure.sh models opencode '<filter>'`,
`configure.sh models openrouter '<filter>'`, and with a nexos key, `configure.sh models nexos`.
Fill each role from the subscriptions first, and say which roles need a paid route. The filter is an extended regex matched anywhere in the
line, for example `gpt-6|claude-sonnet|glm-5`. Options, each with the concrete model per
role in its description and what it costs:

1. **As in your setup** (Recommended): GPT (the newest Sol) for investigator, plan reviewer,
   tester, code review and decisions, all on the ChatGPT subscription when codex is logged
   in (workers on route `codex`); Claude Sonnet for the developer.
2. **Cheaper developer**: the same, with GLM 5.3 Flash (the original setup's earlier
   developer) or DeepSeek Flash as the developer, on OpenCode Go when it is there.
3. **Claude only**: Sonnet workers, review by Opus. No second model family, so weaker
   review, but no other account is needed.

"Other" lets the developer name models per role in their own words. Then map their words
to exact ids with `configure.sh models` and confirm the mapping in one line.

### 3. Routes (one question per role whose model has more than one available route)

For each model, find the available routes in the search order above. When a role has exactly
one, take it and say so. When it has several, ask, in one call for the independent roles:
"Through what should <model> run for the <role>?". Each option says what it costs: the
subscription, pay per token (with the price per 1M tokens from `configure.sh models
openrouter`), or "needs a key first". When the chosen model has no available route, say
which route would make it work (for example "GPT workers: a Codex login, an OpenRouter key, or nexos") and
ask: add that key, or pick another model.

For the review and decisions, propose an order of two providers when there are two: a
subscription first, then a second subscription or a paid route as the fallback when the
first fails. For example `codex` (gpt-6.2-sol), then `opencode` (opencode-go/kimi-k3), then
`openrouter` (openai/gpt-6.2-sol). The review model should be of another family than the
developer's.

### 4. Keys

For every gateway route chosen whose key is not in the keychain:
- the key is in the environment (`OPENROUTER_API_KEY`): give the developer
  `! security add-generic-password -U -s openrouter -a waw -w "$OPENROUTER_API_KEY"`;
- otherwise they copy the key and run
  `! security add-generic-password -U -s <item> -a waw -w "$(pbpaste)"`, then
  `! pbcopy </dev/null`. (The interactive `-w` prompt cuts a key at 128 characters, so it is
  not used.)

Item names: `openrouter`, `nexos-ai`, `opencode-go` (the OpenCode Go API key from
https://opencode.ai/console, not the opencode login), or `<route>` for a custom one. Never ask for the key in
the chat and never read it yourself. Wait, then check it with `configure.sh detect`. Workers
never get a key from the environment: `agent.sh` removes such variables before a worker
starts. That is why the key goes to the keychain.

### 5. Extras (one call, up to four independent questions)

- **Jira module** (`rules/jira-tickets.md`: read a ticket with all its comments and
  attachments): recommend it when your own tool list has an Atlassian connector
  (`mcp__*atlassian*`). Otherwise off.
- **Decisions rule** (`rules/decisions.md`: ask only what is the developer's to decide, in a
  wizard): on by default. Recommend off when the developer's own rules already have one.
- **Status line**: none yet: install ours (it also saves the cost that `/task-cost`
  reports). Another one is set (detect says "another one", for example an Orca hook): recommend
  keeping it, and say that `/task-cost` then shows no cost per stage.
- **Commander settings** (multiSelect): the permissions for the setup's scripts
  (Recommended), no Claude attribution in commits and pull requests (as in the original
  setup), Opus 5.5 with effort high as this config's model.

### 6. Write

Sum up all choices in one short list. Then write the choices file to
`<home>/configure-choices.json` (home: the `waw home` line of detect) and run
`configure.sh apply <home>/configure-choices.json`. Show its output as it is.

With an argument (a partial change), start the choices from the current config and
change only what was asked. apply always writes the whole config.

### 7. Verify

Run `configure.sh check`. For each TODO, give the developer the fix line it prints. The
`anthropic` route needs its own login: `! CLAUDE_CONFIG_DIR='<dir>' claude auth login`. A
`codex` route needs its own Codex login, in a terminal (it opens the browser):
`CODEX_HOME='<dir>' codex login`; the developer's own `~/.codex` is not used.
Then run check again. Then ask once, because it costs money (cents, or some of the
subscription quota):

1. **Ping every route** (Recommended): `configure.sh ping <provider> <model>` for each review
   provider, and `configure.sh ping route:<route> <model>` for each worker role
   (`route:codex` is the workers' Codex login, `codex` the review's). One tiny call each.
2. **Ping + smoke test**: also `smoke.sh` (one real developer worker in a throwaway repository,
   1 to 3 minutes: it proves the sandbox and the guard).
3. **Nothing now.**

A failed ping: show the error line. A wrong model id: list the right ones with
`configure.sh models` and fix the config with one more apply.

### 8. Done

Say in two lines what is set (the model and route per role, the review order). The new rules
load in a new session: tell the developer to start one (`/clear` is not enough for rules).

## Choices file

```json
{
  "routes": {
    "openrouter": { "type": "openrouter", "keychain": "openrouter" },
    "nexos":      { "type": "nexos", "keychain": "nexos-ai", "default_model": "auto-code" },
    "opencode-go": { "type": "opencode-go", "keychain": "opencode-go" },
    "anthropic":  { "type": "anthropic" },
    "codex":      { "type": "codex" },
    "mygw":       { "type": "custom", "url": "https://gw.example.com/anthropic", "keychain": "mygw" }
  },
  "workers": {
    "investigator": { "model": "gpt-6.2-sol", "route": "codex", "effort": "high",
                      "fallback_route": "anthropic", "fallback_model": "claude-opus-5-5" },
    "developer":    { "model": "claude-sonnet-5-5", "route": "anthropic" },
    "reviewer":     { "model": "gpt-6.2-sol", "route": "codex" },
    "tester":       { "model": "openai/gpt-6.2-sol", "route": "openrouter" }
  },
  "review": {
    "providers": [
      { "provider": "codex", "model": "gpt-6.2-sol" },
      { "provider": "openrouter", "model": "openai/gpt-6.2-sol" }
    ],
    "effort": "high"
  },
  "modules": { "decisions": true, "jira-tickets": false },
  "settings": { "statusline": true, "permissions": true, "no_attribution": true,
                "model": "claude-opus-5-5", "effort": "high" },
  "prices": { "openrouter": ["openai/gpt-6.2-sol"] }
}
```

- `routes`: only the routes the workers or the review use. An existing route (a directory in
  `<home>/workers/`) can be used without being listed. `default_model`: the model Claude Code
  uses there for its own background calls (default: the first role model on that route).
- `routes.<name>.type` `codex`: the name is `codex` or `codex-<x>` (agent.sh runs a route's
  workers on Codex by its name); no key, no url.
- `workers.<role>`: `effort` (Codex: minimal, low, medium, high, xhigh; default high),
  `fallback_route` and `fallback_model` (a Claude Code route for projects Codex cannot follow).
- `review.providers`: tried in this order. A provider is `codex`, `opencode`, `claude`,
  `gateway` (with `url`, an OpenAI-compatible base without `/chat/completions`, and `keychain`)
  or a route name. `model` (codex: empty = its default), `decide_model` (optional: for
  /auto-pilot decisions; default `model`).
- `prices.openrouter`: the OpenRouter models whose prices go into `prices.tsv`, so that
  `agent.sh report` and worker budgets use real dollars. Nexos prices come with the plugin.
  For Claude on `anthropic`, Claude Code's own estimate is right.
- `settings`: leave out what was not chosen. Nothing outside these keys is changed.
