---
name: auto-pilot
description: The /ship flow for a developer who is away. The questions and the plan go to a decider (the decide providers of attack.sh, not the model that planned) instead of the developer, the run has a time limit, and every decision taken without them is listed in the pull request. Use when the user types /auto-pilot with a task.
disable-model-invocation: true
---

# auto-pilot

Argument: `$ARGUMENTS`: a task or an issue. The developer is away: the run ends with a pull
request, never with a question.

Read `${CLAUDE_PLUGIN_ROOT}/skills/ship/SKILL.md` and follow it, as the commander, with these
differences:

- **Sandbox first**: before anything else run `agent.sh sandbox-check`.
  Not exit 0: stop, and tell the developer the reason it printed. Without the OS sandbox
  nobody watches the workers, so the run does not start.
- **Workspace** (step 1): the first line of `<dir>/prompt.md` names
  `${CLAUDE_PLUGIN_ROOT}/skills/auto-pilot/SKILL.md` in place of the ship skill.
- **Limit**: in the workspace run `task.sh limit start <dir>` (500
  minutes; an existing deadline stays). Run `task.sh limit check <dir>`
  before the plan, before each build wave, before the verification and before the pull
  request. Exit 5 or 3: stop starting workers, let running ones finish, commit what is
  checked, and deliver it as a draft (`gh pr create --draft`) whose report starts with what
  is left.
- **Ask and plan** (steps 3 and 4): write `<dir>/questions.md`: the task in a few lines, then
  per question an id (`Q1`, ...), what you and the investigator found, two to four options
  with what each costs, and your recommendation; the last question is the plan itself (with
  its slices), to accept or to correct. Run
  `attack.sh --role decide --question <dir>/questions.md` (the
  decider is the first decide provider that answers, as `/configure` set them, never the
  investigator's model that built the plan) and take each answer as the
  developer's. Exit 3 or 4: take your own recommendations. `attack.sh` never exits 5 for
  decide. Do not wait for "ok".
- **Stops**: in place of each stop, one more decision by the same call. A step that could do
  harm is never taken: do the rest and list it under `Left for you`. Host runs (the commander
  rules) are not such a step: run them as in /ship, after reading the diff; one whose diff
  reaches outside the test is not run and goes under `Left for you`. A tester still `blocked`
  after the second run is not a decision: no push and no pull request; list it under
  `Left for you`.
- **Report**: it starts with `Decided without you`: every question, the decision, who took it
  (the provider and model named on the line that starts with `provider: `, or you).
