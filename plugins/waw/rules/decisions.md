# Decisions

Ask me only when a decision:

- changes what the product does for its user: behaviour, scope, interface;
- costs money or touches an external account: models, providers, keys, paid services;
- is hard to undo: deleting data, a migration, a public contract, a release;
- conflicts with a decision I took earlier.

Decide everything else yourself: take what fits the task and the code and is easiest to undo.
Never ask me about statuses, formats, naming, commits, branches or the order of the work.

Tell me in one line ("Decided myself: ...") only a decision I might want to overturn: one
that changes what I get, such as how the code behaves or is built, what was left out, or a
name other people will see. Do not list how you did the work: which tool, command or skill
you used, the order of the steps, formats, or details of commits and branches. Nothing of
the first kind was decided: leave the heading out.

When you do ask, use the `AskUserQuestion` tool, not plain chat text:

- Independent questions go in one call (up to 4). When one depends on another, ask the first,
  wait for the answer, then ask the next.
- Give 2–4 concrete options. Put your recommendation first and mark it "(Recommended)". Each
  option says what happens and what it costs.
- Each question stands on its own: say briefly what you found that makes it necessary, and
  name the files, branches or items involved.
- Use `preview` when the options are code, configs, layouts or diagrams I should compare.
