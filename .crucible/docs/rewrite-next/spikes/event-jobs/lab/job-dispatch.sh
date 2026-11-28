#!/bin/sh
# Spike: the only way main dispatches a job. Derives the root and the
# approval from the events, refuses a misfit, busy or unapproved dispatch, writes job.dispatched and
# prints the Agent or SendMessage call main must make.
# usage: job-dispatch.sh --effort DIR [--check] [--session ID]
#   [--kind KIND] [--tree PATH] [--task TEXT] [--target SEQ] [--round SEQ] [--slot N]
#   [--merge SEQ --side production|tests] [--replaces SEQ | --job SEQ]
#   [--delivery cold|hot] [--hot-agent ID]
# A step's own args work as given: a replacement by --job, a plan rework by --round.
set -eu
LAB=$(cd "$(dirname "$0")" && pwd); . "$LAB/cli.sh"
parse_opts "$@"
replaces=${opt_replaces:-${opt_job:-}}
for n in target round slot merge; do
	eval "v=\${opt_$n:-}"
	[ -z "$v" ] || need_seq "$n" "$v"
done
[ -z "$replaces" ] || need_seq replaces "$replaces"
kind=${opt_kind:-}
[ -n "$kind" ] || { [ -z "${opt_round:-}" ] || [ -n "$replaces" ] || kind=test-plan; }

opts=$(jq -nc --arg kind "$kind" --arg tree "${opt_tree:-}" --arg task "${opt_task:-}" \
	--arg target "${opt_target:-}" --arg round "${opt_round:-}" --arg merge "${opt_merge:-}" \
	--arg side "${opt_side:-production}" --arg replaces "$replaces" \
	--arg delivery "${opt_delivery:-cold}" --arg hot "${opt_hot_agent:-}" --arg running "$RUNNING" '
	def n: if . == "" then null else tonumber end;
	def s: if . == "" then null else . end;
	{kind: ($kind | s), tree: ($tree | s), task: ($task | s), target: ($target | n), round: ($round | n),
	 merge: ($merge | n), side: $side, replaces: ($replaces | n), delivery: $delivery, hot_agent: ($hot | s), running: ($running | s)}')
plan_step() { evq --argjson o "$opts" 'include "dispatch"; job_plan($o)'; }
plan=$(plan_step)
printf '%s' "$plan" | jq -e .ok >/dev/null || refusal "$plan"
[ -z "${opt_check:-}" ] || { echo '{"ok":true}'; exit 0; }
dispatch_job "$(printf '%s' "$plan" | jq -r .root)" "$(printf '%s' "$plan" | jq -r .round)" "$(printf '%s' "$plan" | jq -c .body)" || recheck $?
