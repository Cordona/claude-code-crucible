#!/bin/sh
# Spike: the next fix targets of a merge by the harvest rule, and the keys a
# later fix declined again while the merge held them insisted. Writes nothing.
# usage: harvest.sh --effort DIR --merge SEQ
set -eu
LAB=$(cd "$(dirname "$0")" && pwd); . "$LAB/cli.sh"
parse_opts "$@"
need_seq merge "${opt_merge:-}"
evq --argjson m "$opt_merge" 'include "ev"; ev($m) as $M
	| if $M.type != "review.merged" then error("merge \($m) is not a review.merged") else harvest($M) end'
