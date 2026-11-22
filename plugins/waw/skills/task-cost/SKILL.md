---
name: task-cost
description: Show what this session cost, how long each stage of the task took, and what the workers used. Use when the user types /task-cost.
disable-model-invocation: true
---

# task-cost

1. Run `stage.sh report`: this session (the commander), its stages,
   time and cost.
2. When the task has run files with workers (`.ship/<slug>/agents/runs.tsv` in the current
   worktree), also run `agent.sh report .ship/<slug>/agents`: runs,
   failures, fix runs (`-fix<n>`), steering messages, turns, minutes and tokens per role and
   model, and the fix runs per developer slice.
3. When the task has a merge request (`glab mr view` on the task branch), add two lines of
   your own from it: the findings of the CI reviewer (count, and how many were real) and
   whether the developer asked for changes after it was opened (their comments, and commits
   pushed after their first comment). These are the outcome measures the commander rules ("After a
   model update") compares.

Show both outputs as they are, each in a code block. Add nothing to the numbers. The workers'
dollars (`usd`) are real: gateway prices from `prices.tsv` in the waw home
(`waw/` in the Claude config dir), not Claude Code's estimate (it prices
every gateway model at Opus rates); `~` marks older runs estimated
without the token split, `n/a` a model with no price in that file (add its line from
the gateway's price list, or run `/configure` again). One line of your own is
enough, and only when something stands out: a stage or a role that took most of the time,
or a worker that failed or was re-run many times.

The stages are the steps of `/ship` and `/auto-pilot`, which mark them as they go. In a
session without them the report has the totals only.
