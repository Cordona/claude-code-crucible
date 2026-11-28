#!/bin/sh
# Spike: a range of commits to review cold, as the first event of its chain.
# usage: import.sh --effort DIR --base SHA --head SHA --tree PATH [--session ID]
set -eu
LAB=$(cd "$(dirname "$0")" && pwd); . "$LAB/cli.sh"
parse_opts "$@"
[ -n "${opt_base:-}" ] && [ -n "${opt_head:-}" ] && [ -n "${opt_tree:-}" ] || die 1 "--base, --head and --tree are required"
seq=$(write range.imported self null null "$(jq -nc --arg b "$opt_base" --arg h "$opt_head" --arg t "$opt_tree" '{base: $b, head: $h, tree: $t}')")
jq -nc --argjson s "$seq" '{ok: true, seq: $s}'
