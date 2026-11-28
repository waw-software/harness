# harness (waw-software)

A Claude Code plugin marketplace (`harness`) with one plugin, **waw**: the main session is
the commander, sandboxed workers (Claude Code or Codex) do the work, and a model of another
family reviews it. Commands: `/configure`, `/ship`, `/auto-pilot`, `/brainstorm`,
`/task-cost`, `/retro`. See [plugins/waw/README.md](plugins/waw/README.md).

## Install

```sh
claude plugin marketplace add waw-software/harness
claude plugin install waw@harness
# then, in a new session: /configure
```

## Update Plugin

The plugin has no fixed version: every commit on `main` is a new one.

- **Automatically** (recommended): `/plugin` → Marketplaces → `harness` → turn auto-update
  on. Claude Code checks in the background, a few minutes after your first message. For
  marketplaces other than the official one, auto-update is off by default.
- **By hand**:

  ```sh
  claude plugin update waw@harness
  ```

The new version loads with the next session, or at once with `/reload-plugins`. On its first
session start, waw refreshes its rules in `<config>/rules/waw/` (a changed rule can take one
more session) and its status line link. Your models, routes and logins in `<config>/waw/`
stay; run `/configure` again only when a change asks for it (new route types or settings).

After an update of the plugin or of Claude Code itself, check it with one real worker before
the next task: in a Claude Code session, ask it to run `smoke.sh` (the plugin's scripts are
on the PATH of its Bash tool; 1-3 minutes, a few cents on the developer's route).

To keep a machine on a reviewed commit instead, see
[Pin a machine](plugins/waw/README.md#pin-a-machine-to-a-reviewed-revision). Details:
[plugins/waw/README.md](plugins/waw/README.md#update).

## Documentation

- [Skills](docs/en/SKILLS.md): what each command does (`/configure`, `/brainstorm`, `/ship`,
  `/auto-pilot`, `/task-cost`, `/retro`) and when to use it.
- [Plugin overview](docs/en/PLUGIN_OVERVIEW.md): how the plugin works: roles, task flow,
  sandbox and guards, models and routes, limits, cost.
- Українською: [Скіли](docs/uk/SKILLS.md), [Огляд плагіна](docs/uk/PLUGIN_OVERVIEW.md).

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

## License

[MIT](LICENSE)
