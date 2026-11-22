#!/bin/sh
# deliver.sh of the waw plugin, on the PATH of the Bash tool while the plugin is enabled.
exec "$(cd "$(dirname "$0")/.." && pwd)/scripts/deliver.sh" "$@"
