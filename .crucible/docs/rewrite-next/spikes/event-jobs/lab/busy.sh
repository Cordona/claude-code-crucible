#!/bin/sh
# Spike: the tree rule. A writing job needs no open job on its tree; a
# reading job needs no open writing job there. Writes nothing.
# usage: busy.sh --effort DIR --tree PATH --kind KIND
set -eu
LAB=$(cd "$(dirname "$0")" && pwd); . "$LAB/cli.sh"
parse_opts "$@"
[ -n "${opt_tree:-}" ] && [ -n "${opt_kind:-}" ] || die 1 "--tree and --kind are required"
evq --arg t "$opt_tree" --arg k "$opt_kind" 'include "ev"; busy($t; $k) as $by
	| if $by == [] then {busy: false} else {busy: true, by: $by} end'
