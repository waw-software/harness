---
name: ship
description: Take a task from the developer's words to a pull request, as the commander. Workers do the research, the code, the tests and the review (agent.sh, attack.sh); you ask only the questions that are the developer's, show a short plan, check every worker's result and deliver, without stopping in between. Use when the user types /ship.
disable-model-invocation: true
---

# ship

Argument: `$ARGUMENTS`: a task in the developer's words, an issue (`#N`, a Jira key or a
URL), or nothing right after `/brainstorm` (its notes are the task).

The developer gives the input and takes the decisions that matter. You command: you
decide, brief the workers, check what they deliver and deliver it. You do not write code
(the commander rules, `rules/waw/commander.md`: roles, briefs, checking). The developer does not read the code: they
read your plan before the work and your report after it, and they merge.

As the first thing in each of the seven steps below, run
`stage.sh <step>` with the step's name (`workspace`, `understand`,
`ask`, `plan`, `build`, `verify`, `deliver`), and `stage.sh done`
after the report. `/task-cost` shows the time and the cost of each step from these marks.

Workers run with `agent.sh run ... --out <dir>/agents`, in the background, at most 5 at a
time; briefs go to `<dir>/briefs/<name>.md`. Names: `inv-1`, `plan-review-1`, `dev-<slice>`,
`dev-<slice>-fix1`, `test-1`, ... Whenever workers run, a Monitor on
`agent.sh events <dir>/agents` is armed, and you answer their questions, handle blocks and
steer drift as the commander rules ("Supervising and talking to workers") say, instead of waiting
for their reports.

## 1. Workspace

One task is one branch in one worktree, shared by all its workers.

1. Pick `<slug>`: kebab-case, at most 40 characters. After `/brainstorm`, or with a prompt
   that names the run files (`.ship/<slug>/`), the slug is that one. The slug names the run
   files and the worktree folder, not the branch.

   Pick `<branch>` the way the project names branches. A project rule (AGENTS.md,
   CONTRIBUTING, a branch skill) wins; otherwise follow its recent branches
   (`git branch -r --sort=-committerdate`). With a Jira ticket and no other rule, the form
   is `<type>/<KEY>_<short-kebab-description>`:
   - the type is `fix` for a bug ticket or a fix, and `feat` otherwise;
   - the key stays in capitals, as Jira writes it;
   - the description is 2 to 6 lowercase words saying what changes.

   For example, `feat/PROJ-123_status-label` with the slug `proj-123`. Without a
   ticket: `<type>/<slug>`.
2. `<dir>` = the output of `task.sh dir <slug>`: the run files, never
   committed. Write `<dir>/prompt.md`: the line
   `Follow ${CLAUDE_PLUGIN_ROOT}/skills/ship/SKILL.md for this task. Run files: .ship/<slug>/ in this workspace.`
   and then the task exactly as the developer gave it.
3. Run `task.sh clean`, then
   `task.sh open <slug> --branch <branch> --prompt-file <dir>/prompt.md`:
   - `handed-off <path>`: Orca opened a workspace with its own session for this task. Tell
     the developer its name and stop; the work goes on there.
   - `path <path>`: enter it with `EnterWorktree` and `name` = the last folder of `<path>`
     (`~/worktrees/my-app/proj-123` → `name: "proj-123"`), never with `path`
     (see the commander rules, "Git in a worktree session"). Without that tool, run every command as
     `cd <path> && ...` and give files by absolute path.
   - `here <path>`: this session already is the task's workspace. Work here.

   From here `<dir>` is `.ship/<slug>/` of the workspace; create `briefs/`, `agents/`,
   `context/` in it.
4. The worktree has no dependencies yet: start
   `task.sh deps <path>` in the background now (lockfile only; it can
   take minutes). It must have finished before the first worker that builds, tests or lints;
   the investigator can read the code meanwhile. It fails: show the developer the tail of
   `.ship/deps.log` (often a registry login) and wait.

## 2. Understand

0. **Size.** From the task, its context and a quick look with Explore, pick the size; it is
   shown in the plan, and the developer may correct it:
   - **S**: at most 2 files and ~50 changed lines, no risky zone (step 6), and every
     acceptance criterion provable by one command or one screen. No investigator: you locate
     the code with Explore and write the plan yourself. One developer, the review once. A
     tester only when the change is visible to the user; otherwise you run the proving
     command yourself and keep its output in `<dir>/evidence/`.
   - **L**: more than two slices, or a risky zone. The full flow below, with the plan review.
   - **M**: everything else. The flow below, without the plan review.

   When it turns out bigger than its size (a third file, a risky zone), move it up and say
   so in one line.
1. **Context, yourself.** Read the task. An issue: `gh issue view <ref> --comments` (GitLab:
   `glab`). A Jira ticket: everything `rules/jira-tickets.md` says, attachments included.
   Linked Confluence pages, designs, Slack threads: through the connectors. Save what the
   workers need as files in `<dir>/context/` (text as markdown, images as files), and
   `<dir>/notes.md` when it exists is part of it.
2. **Investigator** (`inv-1`; not for size S). Brief: the task, the context files, and the questions to answer:
   how the code does this today (with `file:line`), what the change touches, the risks, how
   the project is checked (full check, unit tests, lint, e2e and which specs touch the
   area), the open questions with options and a recommendation, and a draft plan
   (`plan`: acceptance criteria and slices with owned files, interfaces, tests first,
   steps). Ask it for the project's `AGENTS.md` / `CLAUDE.md` rules that bear on the task.
3. **Check it.** Open the `file:line` of each finding the plan rests on. A claim that does
   not hold: resume the investigator with the correction.

## 3. Ask, once

Ask the developer only what is theirs to decide (the decisions rule, `rules/waw/decisions.md`), in one
`AskUserQuestion` call: the investigator's open questions that are of that kind, and yours.
Never ask what the notes or the task already answer. Nothing of that kind is open: ask
nothing. Decide the rest yourself and keep one line per decision.

## 4. Plan

1. When the answers change the draft, resume the investigator with them (`inv-1-plan`) for
   the final plan.
2. Check the slices yourself: no file in two slices; shared files owned by one slice; each
   slice at most ~300 changed lines; interfaces given where slices meet; every acceptance
   criterion has a proof. Size L (more than two slices or a risky zone): also run a reviewer
   on the plan (`plan-review-1`, brief: the task, the plan file, "review this plan").
3. Show the plan in the chat, half a page at most:
   - **Size**: S, M or L, and what that leaves out (for S: no investigator; a tester only for a change the user sees).
   - **Will do**: how the product behaves after the change, in the developer's terms.
   - **Will not do**: what someone could expect and will not get.
   - **Proof**: the acceptance criteria, each one a check that can fail, and for each how it
     will be proven for real: the end-to-end spec that covers it, or the tool the tester
     will run it with.
   - **Slices**: one line each (what, owned files), and which run in parallel.
   - **Guarded files**: the files the project guards ("ask-first") that slices will change,
     and why; the developer's "ok" approves them (`--grant` in step 5).
   - **Decided myself**: one line each.
   - **Risk**: only in a risky zone: what can break, in plain words.

Work larger than one pull request a person could read (several independent parts, or far
more than 400 changed lines of code): split it into pull requests that each ship by
themselves, write them as a checklist into one issue (`gh issue create`), and plan the
first only. `/ship #N` takes the next unchecked one.

Then stop and wait for "ok" or corrections. This is the only planned stop.

## 5. Build

Write `<dir>/task.md`: the request, the plan as agreed, the acceptance criteria. Then, wave
by wave (a wave = the slices whose dependencies are committed, at most 5):

1. Brief each slice's developer (`dev-<slice>`) by the brief format of the commander rules: owned
   files, the files the other slices of the wave are changing, interfaces, tests first,
   steps, commands, "do not", done when. Start the wave's developers in parallel, each with
   `--grant <path>` for the guarded files of its slice that the plan listed.
2. As each one reports, check it (the commander rules, "Checking what comes back"): only its files
   changed, the diff does what the brief asked, its tests ran and passed. Wrong or partial:
   a small exact fix (the commander rules) you make yourself; anything more goes back to it with a
   fix brief (`dev-<slice>-fix1`). Right: commit exactly its files.
3. `out_of_scope_needs`: assign them to the slice that owns the file, or to a new slice.
4. After the last wave, check the whole diff against the plan (`git diff <base>...HEAD
   --stat`, and read what the slices connect).

Beyond a small exact fix (the commander rules), never fix code yourself: a precise brief to a
developer.

## 6. Verify

Start the tester and the review at the same time; they only read the code.

1. **Tester** (`test-1`, only when no developer is running). Brief: `<dir>/task.md`, the
   evidence directory `<dir>/evidence/`, the project's full check command, the e2e specs to
   run (from the investigator's `checks`), and for each criterion how to prove it on the
   running product (the platform's skill when the project has one; a web app in a
   browser; an API with requests). It reports per criterion, with evidence, the bugs,
   what it could not run, and the e2e proposal.
2. **Review by another model.** In the worktree run in the background, stdout to
   `<dir>/review.md`: `attack.sh --role review --task <dir>/task.md`,
   and in a risky zone also `--role security` (to `<dir>/security.md`). A risky zone:
   authentication or authorization, secrets, money, input from outside the system, deleting
   or migrating data, or a path the project lists as risky. Exit 3 or 4: no reviewer
   answered; say so in the report.
3. **Triage.** Check every reviewer finding and every tester bug against the code yourself.
   Real: a small exact fix yourself, or a fix brief to the developer of that slice (resume
   it) with the finding, where, and the fix; commit after checking. Fix only real bugs; a
   test-quality nit is declined unless cheap, and then batched into one brief. Not real:
   decline it with a one-line reason. Then run the tester again for the affected criteria
   and the full check. **One review round per task**: review again only when the first
   round found a blocker. What is still open goes into the report as it is.
4. **Proof is complete** only when every criterion is proven by an e2e spec that asserts it
   or by the tester on the running product (size S without a tester: the command you ran,
   its output in `<dir>/evidence/`), with evidence you opened. Never count a
   criterion as proven by code reading or unit tests alone; what could not be run goes
   under "Not covered".
5. **Documents**: statements in the project's documents that this change made false are
   fixed by a developer brief, once, now. A decision that changes what the product does or
   how it is built goes where the project keeps decisions, as accepted: the developer's
   answer is the approval.

## 7. Deliver

You deliver, without asking: write the report to `<dir>/mr.md`, then
`deliver.sh mr --title "<title>" --description-file <dir>/mr.md`
pushes the branch and opens the pull/merge request (GitLab or GitHub) with the report as
its body; later pushes: `deliver.sh push`. It refuses protected branches and never forces:
a refusal goes to the developer as it is. Its title follows the commits, not the branch name: the type the commits have
(`fix` when they fix, whatever the type in the branch name says), with the ticket as the scope
when the branch names one, for example `fix(PROJ-456): ...`; a project rule for titles
wins. Then watch it, without asking whether to: watching is part of delivering. Watch until
every job has finished: `gh pr checks --watch` in the background (on GitLab: the pipeline
of the merge request, with `glab`).

When all jobs are done, read two things:

- **CI.** Red: brief a developer with the failing job's log lines and the files involved,
  check, commit, push, wait again; after two rounds report it as it is.
- **The AI reviewer's comments.** A reviewer that runs in CI posts its findings when its job
  ends, so read them now and not earlier: the comments and review threads that a bot or an
  AI review job left on the pull request (`gh pr view --comments` and
  `gh api repos/{owner}/{repo}/pulls/<number>/comments`; on GitLab the notes and discussions
  of the merge request). Check every finding against the code, as in step 6. Then, without
  being asked, show the developer all of them at once: each finding with its verdict (real
  or not, the reason in one line) and, for a real one, the solution you propose. Do not
  apply them silently. What the developer accepts goes to a developer worker; check, run
  the check, push, and watch the jobs once more.

The report, in the pull request and in the chat:

1. **Try it**: how to see it work in a minute.
2. **Proof**: per acceptance criterion, how it was proven (the e2e specs run, or what the
   tester ran and with which tool) and what it showed, with the key screenshots.
3. **E2E proposal**: from the tester, when there is one: the specs to add or extend and the
   criteria they would cover.
4. **Not covered**: what the proof does not show, and why it could not be run.
5. **Deploy risk and rollback**: what the merge can break and how to undo it.
6. **Guarded files changed**: each ask-first file the change touched (from
   `<dir>/agents/*.approvals.log`), granted in the plan or approved during the run, and why.
7. **Edited by the commander**: each small exact fix you made yourself (file, what, why);
   leave the heading out when there is none.

Then `Decided myself` (one line each), `Review` (who reviewed, what was fixed, what was
declined and why; the AI reviewer of CI is listed here too, with each finding's verdict),
and `Workers` (the output of `agent.sh report <dir>/agents`, in the
chat only). A checklist issue: tick the item and add `Part of #N`; the last one gets
`Closes #N`.

The developer merges. Never merge, never push to the default branch, never deploy.

## Stops

Between "ok" and the pull request you do not ask. Stop only when the task turns out to be
different from what the developer agreed to, when a check still fails after two different
attempts, when workers keep failing on the same slice after a rewritten brief, or when the
next step could do harm (data loss, production, secrets, money). Say what happened and what
you propose.
