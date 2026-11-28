# waw skills: a user guide

In Claude Code, a skill is a set of instructions that a plugin adds and that you start with a
slash command, such as `/ship`. The waw plugin adds six. In all of them the main session is the
**commander**: it talks to you, decides, writes briefs for sandboxed **workers**
(`investigator`, `developer`, `reviewer`, `tester`), checks what they deliver, and does the git
work itself. How the roles, the sandbox, the guards and the routes work is explained in
[PLUGIN_OVERVIEW.md](PLUGIN_OVERVIEW.md); install and update are in the
[root README](../../README.md) and the [plugin README](../../plugins/waw/README.md).

| Skill | In one line |
|-------|-------------|
| `/configure` | Set up waw: pick the model and route of every worker role and of the code review. |
| `/brainstorm` | Talk an idea through before any code; ends with a page of notes. |
| `/ship` | Take a task to a pull request, with you there for the questions and the plan. |
| `/auto-pilot` | The same as `/ship` while you are away: a decider model answers instead of you. |
| `/task-cost` | The time and cost of each stage of the current task, and what the workers used. |
| `/retro` | What past runs cost and where they went wrong, from the ledger. |

## Which one to use

| Situation | Skill |
|-----------|-------|
| First setup, or you want other models or routes | `/configure` |
| An idea that is not yet a task | `/brainstorm` |
| A task, and you will be around to answer and approve the plan | `/ship` |
| A task, and you will be away | `/auto-pilot` |
| What the task in this session cost | `/task-cost` |
| How recent runs went | `/retro` |

All skills except `/configure` start only when you type their command; Claude does not start
them on its own. `/configure` also starts when you ask Claude to set up, change or remove waw.

## `/configure`

**What it is for.** The first setup of the plugin, and every later change of models,
routes, review providers or settings. It also removes waw when you ask.

**How to start it.** `/configure` (or `/waw:configure`) for the whole setup. With an argument,
only that part changes and the rest of the current config stays:

    /configure
    /configure developer model
    /configure review only

**What happens.**

1. **Check.** It runs `configure.sh detect` and shows a summary of at most 8 lines: Claude
   Code and its login, missing tools (with the install command), each model source with its
   billing (subscriptions first: Codex/ChatGPT, the claude.ai login, OpenCode Go; then pay
   per token: OpenRouter, nexos.ai, a custom gateway), and what is configured already.
2. **Models per role.** One question. It proposes models for the investigator, developer,
   reviewer, tester and for the code review and `/auto-pilot` decisions. The usual options:
   "As in your setup" (GPT for most roles on the ChatGPT subscription, Claude Sonnet as the
   developer), "Cheaper developer" (GLM or DeepSeek as the developer, on OpenCode Go when
   you have it), "Claude only" (no second model family, so a weaker review). You can also
   name models in your own words; it maps them to exact ids and confirms.
3. **Routes.** For each role whose model can run through more than one available route, it
   asks which one, with the cost of each (subscription, price per 1M tokens, or "needs a key
   first"). Subscriptions are always offered first. For the review it proposes an order of
   two providers, the second as the fallback.
4. **Keys.** For each gateway whose key is not in the macOS keychain, it gives you a
   `security add-generic-password ...` line to run yourself. It never asks for a key in the
   chat and never reads it.
5. **Extras.** Up to four questions at once: the Jira module, the decisions rule (on by
   default), the status line, and the commander settings (script permissions, no Claude
   attribution in commits and pull requests, the commander's model and effort).
6. **Write.** It lists your choices, writes `configure-choices.json` in the waw home and runs
   `configure.sh apply` on it.
7. **Verify.** It runs `configure.sh check` and gives you the fix line of each TODO (for
   example the separate login of the `anthropic` or `codex` worker route). Then one question,
   because it costs a little: ping every route (recommended), ping plus `smoke.sh` (one real
   worker in a throwaway repository, 1 to 3 minutes), or nothing now.
8. **Done.** Two lines on what is set.

**What it asks you.** The models, the routes when there is a real choice, the extras, and
whether to ping. Each question comes with a recommendation marked "(Recommended)". It never
asks for a key's value.

**What you get at the end.** The config and the worker routes in the waw home (`waw/` in your
Claude config dir), the commander rules in `<config>/rules/waw/`, the settings you picked,
and a two-line summary.

**Limits and good to know.**
- The new rules load only in a new session; `/clear` is not enough.
- To remove waw, ask for it: one question (keep the waw home for a reinstall, or purge it),
  then `configure.sh uninstall` or `configure.sh uninstall --purge`. Keychain items stay; it
  prints the commands that would delete them. Then start a new session.
- Details of what it writes: [plugin README](../../plugins/waw/README.md).

## `/brainstorm`

**What it is for.** An idea you want to think through before it becomes a task: how it fits
the code, what it conflicts with, the options and what each costs. No code is written, no
branch is created, nothing is pushed.

**How to start it.** `/brainstorm <idea, link or issue>`:

    /brainstorm let users export their reports as CSV
    /brainstorm #42

**What happens.**

1. The commander picks a short name for the task (the slug) and creates its run directory,
   `.ship/<slug>/`.
2. It gathers the context itself: the issue with its comments, a Jira ticket, and what the
   connectors hold (Confluence, designs, Slack), saved in `.ship/<slug>/context/`.
3. An `investigator` worker reads the code: how it works today, how the idea fits, what it
   conflicts with, the options with their cost (effort, risk, what each rules out later),
   the risky zones (authentication, secrets, money, outside input, deleting or migrating
   data), and a recommendation. For a broad idea, up to three investigators run in parallel.
4. The commander checks the findings it relies on and tells you, in under a page, what it
   found and what it recommends.
5. You talk as long as you want. New questions about the code go back to the investigator.
6. At the end it writes `.ship/<slug>/notes.md`.

**What it asks you.** Only what is yours to decide (see "Decisions" below); technical details
it decides itself and says so.

**What you get at the end.** `.ship/<slug>/notes.md`, one page at most: the idea in your
words, every decision you took (with the date), what was decided against and why, what is
still open, and the paths of the investigator's reports.

**Limits and good to know.** Run `/ship` with no argument right after it: the notes are the
task.

## `/ship`

**What it is for.** A task you will be around for, taken from your words to a pull request.
You answer the questions that are yours and approve the plan; after that it works to the
pull request without stopping.

**How to start it.** `/ship <task>`: a task in your words, an issue (`#N`), a Jira key or a
URL; or nothing right after `/brainstorm`.

    /ship show the build number in the About screen
    /ship PROJ-123

**What happens.** Seven steps; each is marked with `stage.sh` so that `/task-cost` can show
its time and cost.

1. **Workspace.** It picks the slug and a branch named the way your project names branches
   (with a Jira ticket: for example `feat/PROJ-123_status-label`). `task.sh open` creates a
   worktree in `~/worktrees/<repo>/<slug>`, and the session works there. The dependencies are
   installed from the lockfile in the background (`task.sh deps`).
2. **Understand.** It sizes the task: **S** (at most 2 files and ~50 lines, no risky zone),
   **M**, or **L** (more than two slices, or a risky zone). It gathers the context (issue,
   Jira, connectors) into `.ship/<slug>/context/`. For M and L an `investigator` reports how
   the code works today, the risks, how the project is checked, open questions and a draft
   plan; the commander checks the findings the plan rests on.
3. **Ask, once.** One round of questions, only those that are yours. Nothing open: no
   questions.
4. **Plan.** For L, a `reviewer` worker reviews the plan first. You see half a page: the
   size, what it will do, what it will not do, the proof for each acceptance criterion, the
   slices, the guarded files it will change, what it decided itself, and the risk (in a
   risky zone). It waits for your "ok" or corrections. Work too big for one readable pull
   request is split into parts written as a checklist in one issue; `/ship #N` takes the
   next unchecked part.
5. **Build.** It writes `.ship/<slug>/task.md`. `developer` workers build the slices, up to
   five in parallel when they share no file, tests first. The commander checks each diff,
   sends wrong work back to the same worker, and commits each slice.
6. **Verify.** A `tester` runs the project's full check and the end-to-end specs and proves
   each criterion on the running product, keeping evidence in `.ship/<slug>/evidence/`. At
   the same time a model of another family reviews the code (`attack.sh --role review`,
   output in `.ship/<slug>/review.md`; in a risky zone also a security review). The commander
   checks every finding and every bug against the code; real ones are fixed, the rest are
   declined with a reason. Documents the change made false are corrected.
7. **Deliver.** It writes the report to `.ship/<slug>/mr.md`, pushes the branch and opens the
   pull request (GitHub) or merge request (GitLab) with `deliver.sh mr`. It watches CI to the
   end. A red job goes to a developer worker (two rounds at most). Comments of an AI reviewer
   in CI are checked and shown to you all at once, each with a verdict; none is applied
   without you.

**What it asks you.** The questions of step 3, once, and the plan in step 4. That plan is
the only planned stop. After your "ok" it stops only when the task turns out different from
what you agreed to, a check still fails after two different attempts, workers keep failing
on the same slice after a rewritten brief, or the next step could do harm (data loss,
production, secrets, money). It never asks about statuses, formats, names, commits, branches
or the order of the work.

**What you get at the end.** A pull request whose description is the report:
1. **Try it**: how to see it work in a minute.
2. **Proof**: `tests: pass | pass-with-exclusions | fail | blocked`, then how each criterion
   was proven, with key screenshots.
3. **E2E proposal**: specs the tester proposes to add.
4. **Not covered**: what the proof does not show, and why.
5. **Deploy risk and rollback.**
6. **Guarded files changed**: each "ask-first" file touched, and why.
7. **Edited by the commander**: small fixes it made itself (only when there are any).
8. **Run on the host**: host runs (only when there are any).

Then `Decided myself`, `Review` (who reviewed, what was fixed or declined, the CI reviewer's
findings), and, in the chat only, `Workers` (the output of `agent.sh report`).

**Limits and good to know.**
- **One review round per task**; a second only when the first found a blocker.
- A criterion counts as proven only by an end-to-end spec or by the tester on the running
  product, never by reading code or unit tests alone. A tester result of `blocked` means no
  push and no pull request.
- **Host runs.** Electron/Chromium and the iOS simulator cannot start in any worker sandbox.
  When the investigator marks such a command, or the tester reports
  `blocked` with `needs host: <command>`, the commander runs that one command on your
  machine itself, but only after reading the full diff of the branch. If anything reaches
  outside the test (network beyond localhost, keys, home files, a download), it does not run
  it and reports it as a finding. Output goes to `.ship/<slug>/evidence/host-<n>-<name>.txt`;
  the tester then checks that file instead of running it again.
- The run files in `.ship/<slug>/` are never committed.
- You merge. It never merges, never pushes to the default branch and never deploys.

## `/auto-pilot`

**What it is for.** The `/ship` flow while you are away. The run ends with a pull request,
never with a question to you.

**How to start it.** `/auto-pilot <task or issue>`:

    /auto-pilot fix the crash when the settings file is empty
    /auto-pilot #57

**What happens.** The `/ship` steps, with these differences:

1. **Sandbox first.** `agent.sh sandbox-check` runs before anything else. If workers would
   not start inside the OS sandbox, the run does not start and you get the reason.
2. **Time limit.** `task.sh limit start` sets a deadline of 500 minutes. The limit is checked
   before the plan, before each build wave, before verification and before the pull
   request. When it is reached, no new workers start, running ones finish, the checked work
   is committed and delivered as a **draft** pull request whose report starts with what is
   left.
3. **Questions and plan.** Instead of asking you, the commander writes
   `.ship/<slug>/questions.md`: each question (`Q1`, ...) with what was found, two to four
   options with their cost, and a recommendation; the last question is the plan itself. A
   **decider** answers it (`attack.sh --role decide`): the first review provider that
   answers, as `/configure` set them, never the model that built the plan. Its answers are
   taken as yours. If no provider answers, the commander takes its own recommendations.
4. **Stops.** Where `/ship` would stop, the decider takes one more decision. A step that
   could do harm is never taken: the rest is done and that step is listed under
   `Left for you`.

**What it asks you.** Nothing. The decider, or the commander when no decider answers,
decides instead of you.

**What you get at the end.** A pull request with the `/ship` report, starting with
`Decided without you`: every question, the decision, and who took it (the provider and
model, or the commander). What it could not do safely is under `Left for you`.

**Limits and good to know.**
- The deadline is 500 minutes; an existing deadline in the run directory is kept.
- A missing or broken deadline file counts as a stop, not as a pass.
- Host runs happen as in `/ship`, after the diff is read; one whose diff reaches outside the
  test is not run and goes under `Left for you`.
- A tester still `blocked` after its second run means no push and no pull request; it is
  listed under `Left for you`.

## `/task-cost`

**What it is for.** What the current session and its task cost, how long each stage took,
and what the workers used.

**How to start it.** `/task-cost`, with no argument.

**What happens.**

1. `stage.sh report --task <slug>` prints the commander's stages (the `/ship` steps), with
   time, wait, cost and output tokens, then the totals. Without a marked task it prints the
   totals of the session only. TIME leaves out the marked waits for you; the WAIT column
   shows them.
2. When the task has workers (`.ship/<slug>/agents/runs.tsv`), `agent.sh report` adds runs,
   failures, fix runs (`-fix<n>`), steering messages, turns, minutes and tokens per role and
   model, and the fix runs per developer slice.
3. When the task has a merge request, two more lines: the CI reviewer's findings (how many,
   how many real) and whether you asked for changes after it was opened.

**What it asks you.** Nothing.

**What you get at the end.** Both outputs as they are, in code blocks, and at most one line
of comment when something stands out.

**Limits and good to know.** The workers' dollars (`usd`) use gateway prices from
`prices.tsv` in the waw home. `~` marks an estimate, `n/a` a model with no price (add its
line, or run `/configure` again), `sub` a subscription run. For past tasks use `/retro`.

## `/retro`

**What it is for.** How past runs went: fix runs, blocks, questions, steering, and time and
cost per stage. It reads the ledger in the waw home (`state/ledger.jsonl`), which survives
deleted worktrees.

**How to start it.** `/retro`, optionally with a period, a task or a project:

    /retro
    /retro since 2026-11-01
    /retro task proj-123

**What happens.**

1. It runs `retro.sh` with what you named: `--since YYYY-MM-DD` (and `--until` for the last
   day), `--task <slug>`, or `--project <name>`. Without them it covers the last 7 days;
   for an older task give a start date too. In a project directory it covers only that
   project; `--all` covers every project.
2. For a task whose `.ship/<slug>/review.md` still exists, it adds the number of review
   findings and how many were blockers.
3. It shows the output as it is, in a code block.
4. Then at most three lines on what stands out, each naming the commander rule it bears on.

**What it asks you.** Nothing.

**What you get at the end.** The table of runs per role and model, fix runs per slice,
events and the most frequent blocks, the commander's stages and the total cost.

**Limits and good to know.** It only reads; it changes nothing. Runs of `smoke.sh` are kept
apart from the task numbers.

## Decisions: what you are asked and what is decided for you

The decisions rule (on by default, set in `/configure`) says the commander asks you only
when a decision:

- changes what the product does for its user: behaviour, scope, interface;
- costs money or touches an external account: models, providers, keys, paid services;
- is hard to undo: deleting data, a migration, a public contract, a release;
- conflicts with a decision you took earlier.

Everything else it decides itself, taking what fits the task and the code and is easiest to
undo. It never asks about statuses, formats, naming, commits, branches or the order of the
work. A decision you might want to overturn (how the code behaves or is built, what was left
out, a name others will see) is reported in one line under `Decided myself`.

When it asks, it uses a question dialog: independent questions together (up to four), two to
four options each, the recommendation first and marked "(Recommended)", each option saying
what it costs.

Under `/auto-pilot` the same questions go to the decider instead, and every one of them is
listed under `Decided without you`.

## Where to look while it runs

- **The background task output.** Each worker streams one line per step, for example
  `[dev-a 1m05s] Bash pnpm test`.
- `agent.sh ps`: the workers running now, for any task: name, role, model, elapsed time,
  worktree and the last tool call. A queued run shows `WAITING FOR WORKER SLOT` (at most 5
  workers run at a time).
- `agent.sh log <name>`: the steps of one worker so far; `-f` keeps following it.
- `.ship/<slug>/` in the task's worktree: `context/`, `briefs/`, `agents/` (worker logs and
  reports), `task.md`, `questions.md` (`/auto-pilot`), `review.md`, `evidence/`, `mr.md`,
  and `notes.md` from `/brainstorm`.
- You can also ask the commander how the workers are doing; it answers from `agent.sh ps`
  and `agent.sh log`.

## See also

- [PLUGIN_OVERVIEW.md](PLUGIN_OVERVIEW.md): roles, sandbox, guards, routes and the ledger.
- [Root README](../../README.md): install, update, trying it in a separate config.
- [Plugin README](../../plugins/waw/README.md): where things live, update, pinning, removal.
