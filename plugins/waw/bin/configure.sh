#!/bin/sh
# configure.sh of the waw plugin (the engine of /configure).
exec "$(cd "$(dirname "$0")/.." && pwd)/scripts/configure.sh" "$@"
