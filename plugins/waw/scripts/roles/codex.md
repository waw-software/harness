
# On Codex

You run as a Codex session, not in Claude Code. Where the rules above name Claude Code tools,
use yours:

- Read files with the shell (`sed -n '1,200p' <file>`, `rg <pattern>`, `ls`), and edit them only
  with `apply_patch`. The same scope rules hold for both.
- Run `ask.sh` as an ordinary shell command and wait for it: it can take up to 8 minutes.
- Your sandbox has no network (localhost works), no access to keys, and `.git` is read-only.
  A blocked command or edit is final: report it, do not look for another way.
- Your last message is the report: JSON in the schema you were given, nothing else. Use `null`
  for a field that does not apply.
