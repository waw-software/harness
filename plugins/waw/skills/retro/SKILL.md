---
name: retro
description: "What past runs cost and where they went wrong: fix runs, blocks, questions, steering, time and cost per stage. Use when the user types /retro."
disable-model-invocation: true
---

# retro

1. Run `retro.sh` with what the user named: a period (`retro.sh --since YYYY-MM-DD`, with
   `--until` for its last day), a task (`retro.sh --task <slug>`) or a project
   (`retro.sh --project <name>`). Without them it covers the last 7 days: for an older
   task, give `--since` too.
2. For a task whose review file still exists (`<dir>/review.md`, with `<dir>` its
   `.ship/<slug>` in the current worktree), add one line with its number of findings and how
   many of them are blockers: the table rows whose first cell is `blocker` or `non-blocker`.
3. Show the output of `retro.sh` as it is, in a code block. Add nothing to the numbers.
4. Then at most three lines on what stands out, each naming the **(b)** rule of the
   commander rules ("After a model update") it bears on.
