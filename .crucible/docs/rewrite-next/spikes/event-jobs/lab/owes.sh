#!/bin/sh
# Spike: per root, the one step owed inside an agreed step, the facts for a
# next step, the open jobs and the live loop (contract 2.1). Writes nothing.
# usage: owes.sh --effort DIR [--session ID]
set -eu
LAB=$(cd "$(dirname "$0")" && pwd); . "$LAB/cli.sh"
parse_opts "$@"
evq 'include "owes"; owes'
