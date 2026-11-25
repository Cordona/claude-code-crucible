#!/bin/sh
# Spike: makes one round: a round.made with its whole set, base and head
# pinned and each slot's cover, then a job.dispatched per slot; prints the
# calls main must make. A round in a loop derives its swarm from the fix; a
# gated round takes the agreed kinds, one reviewer per kind, no file split.
# Refuses a second round over the same fix submissions or plan.
# usage: round.sh --effort DIR --kind code|external|challenge --targets SEQ[,SEQ]
#                 [--kinds K[,K]] [--check] [--session ID]
set -eu
LAB=$(cd "$(dirname "$0")" && pwd); . "$LAB/cli.sh"
parse_opts "$@"
[ -n "${opt_kind:-}" ] && [ -n "${opt_targets:-}" ] || die 1 "--kind and --targets are required"
targets=$(list_json "$opt_targets")
printf '%s' "$targets" | jq -e 'length > 0 and all(.[]; test("^[0-9]+$"))' >/dev/null || die 1 "--targets must be seqs"
targets=$(printf '%s' "$targets" | jq -c 'map(tonumber)')
kinds=null
[ -z "${opt_kinds:-}" ] || kinds=$(list_json "$opt_kinds")

# what the events can't say: the files and the base of a range, from its tree
git_facts() {
	evq --argjson t "$targets" 'include "ev"; . as $e | ev($t[0]) as $f | ($t | last) as $l | ev($l) as $L
		| {tree: ($L.body.tree // (if $L.job then ($e | ev($L.job)).body.tree else null end)),
		   first: $f.body.commit, base: $L.body.base, head: $L.body.head}' |
	{
		IFS= read -r f
		tree=$(printf '%s' "$f" | jq -r '.tree // ""')
		if [ -n "$tree" ] && git -C "$tree" rev-parse --git-dir >/dev/null 2>&1; then
			first=$(printf '%s' "$f" | jq -r '.first // ""')
			base=$(printf '%s' "$f" | jq -r '.base // ""')
			head=$(printf '%s' "$f" | jq -r '.head // ""')
			[ -n "$base" ] || base=$(git -C "$tree" rev-parse -q --verify "$first^" 2>/dev/null || true)
			files='[]'
			[ -z "$base" ] || [ -z "$head" ] ||
				files=$(git -C "$tree" diff --name-only "$base" "$head" | jq -Rsc 'split("\n") | map(select(length > 0))')
			jq -nc --arg b "$base" --argjson f "$files" '{base: (if $b == "" then null else $b end), files: $f}'
		else
			echo '{"base":null,"files":[]}'
		fi
	}
}
git='{"base":null,"files":[]}'
[ "$kinds" = null ] || [ "$opt_kind" != code ] || git=$(git_facts)

opts=$(jq -nc --arg k "$opt_kind" --argjson t "$targets" --argjson ks "$kinds" --arg r "$RUNNING" '{kind: $k, targets: $t, kinds: $ks, running: (if $r == "" then null else $r end)}')
plan_step() { evq --argjson o "$opts" --argjson git "$git" 'include "dispatch"; round_plan($o; $git)'; }
plan=$(plan_step)
printf '%s' "$plan" | jq -e .ok >/dev/null || refusal "$plan"
[ -z "${opt_check:-}" ] || { echo '{"ok":true}'; exit 0; }

root=$(printf '%s' "$plan" | jq -r .root)
round=$(write round.made "$root" null null "$(printf '%s' "$plan" | jq -c .round)") || recheck $?
printf '%s' "$plan" | jq -c --argjson r "$round" '.approval as $a | .tree as $tree | .jobs[]
	| {kind, target: $r, tree: $tree, agent_type, delivery, hot_agent, slot, replaces: null, approval: $a, payload}' |
	while IFS= read -r job; do
		dispatch_job "$root" "$round" "$job"
	done
