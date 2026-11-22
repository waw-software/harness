---
name: brainstorm
description: Talk a feature or an idea through with the developer before any code. An investigator worker reads the code; you say how the idea fits and what it costs, ask the product questions, and leave a page of notes that /ship continues from. Use when the user types /brainstorm.
disable-model-invocation: true
---

# brainstorm

Argument: `$ARGUMENTS`: an idea, a link or an issue. This is a conversation. No code is
written, no branch created, nothing pushed.

1. Pick `<slug>` (kebab-case, at most 40 characters); `<dir>` is the output of
   `task.sh dir <slug>`; create `briefs/`, `agents/`, `context/`.
2. Gather the context yourself: the link or the issue (`gh issue view <ref> --comments`; a
   Jira ticket as `rules/jira-tickets.md` says), and what the connectors hold (Confluence,
   designs, Slack). Save what matters in `<dir>/context/`.
3. Brief an investigator (`agent.sh run --role investigator ... --name inv-1`, in the
   background): the idea in the developer's words, the context files, and what to find out:
   how the code does this today, how the idea fits, what it conflicts with, the options with
   what each costs (effort, risk, what it rules out later), the risky zones it touches
   (authentication, secrets, money, input from outside, deleting or migrating data), and
   its recommendation. No plan or slices yet. A broad idea: up to three investigators on
   separate questions, in parallel.
4. Check the findings you will rely on (open their `file:line`), then tell the developer
   what you found, in under a page: how the idea fits, what it conflicts with, the options
   with their cost, and what you recommend.
5. Talk as long as the developer wants. Ask what is theirs to decide
   (the decisions rule, `rules/waw/decisions.md`) with `AskUserQuestion`; decide technical details
   yourself and say so. A new question about the code: resume the investigator
   (`--resume`, `inv-1-q2`) rather than reading around yourself.
6. When the developer has what they need, write `<dir>/notes.md`: one page at most: the idea
   in the developer's words, every decision they took (with the date), what was decided
   against and why, what is still open, and the paths of the investigator's reports. Tell
   them that `/ship` continues from these notes.
