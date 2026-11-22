# harness (waw-software)

A Claude Code plugin marketplace (`harness`) with one plugin, **waw**: the main session is
the commander, sandboxed workers (Claude Code or Codex) do the work, and a model of another
family reviews it. Commands: `/configure`, `/ship`, `/auto-pilot`, `/brainstorm`,
`/task-cost`. See [plugins/waw/README.md](plugins/waw/README.md).

## Install

```sh
claude plugin marketplace add waw-software/harness
claude plugin install waw@harness
# then, in a new session: /configure
```

## Try it without touching your own setup

A separate Claude Code config dir works like another user: its own login, settings, plugins
and worker routes. Your `~/.claude` (and `~/.codex`) stay as they are.

```sh
export CLAUDE_CONFIG_DIR=~/.claude-waw-try
claude plugin marketplace add waw-software/harness
claude plugin install waw@harness
claude            # /login, then /configure, then a new session
```

To remove it: `rm -rf ~/.claude-waw-try` (and the keychain items `/configure` added, if any).
In your own config, `configure.sh uninstall` (or `--purge`) undoes what the plugin added; see
[plugins/waw/README.md](plugins/waw/README.md#remove-it).

From a clone of this repository, `test-config/claude-setup-test` does the same with the
local copy (`~/.claude-setup-test`), for work on the plugin itself.

## Develop

```sh
bash plugins/waw/tests/run.sh      # unit tests, no network, no real claude/codex calls
claude plugin validate .
plugins/waw/scripts/smoke.sh       # one real worker on the developer's route (a few cents)
```

Design notes: [docs/plans/](docs/plans/).

## License

[MIT](LICENSE)
