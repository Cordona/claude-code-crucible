#!/bin/sh
# Spike: ends an open job with no report: cancelled (TaskStop, or the human
# said stop) or died. Refuses a job that has already ended.
# usage: job-end.sh --effort DIR --job SEQ --reason cancelled|died [--check] [--session ID]
set -eu
LAB=$(cd "$(dirname "$0")" && pwd); . "$LAB/cli.sh"
parse_opts "$@"
need_seq job "${opt_job:-}"
case "${opt_reason:-}" in cancelled | died) ;; *) die 1 "--reason is cancelled or died" ;; esac
plan_step() {
	evq --argjson j "$opt_job" 'include "ev"; ev($j) as $J
	| if $J.type != "job.dispatched" then {ok: false, refusal: "not-a-job"}
	  elif end_of($j) then {ok: false, refusal: "done-already", by: end_of($j).seq}
	  else {ok: true, root: $J.root, round: $J.round} end'
}
plan=$(plan_step)
printf '%s' "$plan" | jq -e .ok >/dev/null || refusal "$plan"
[ -z "${opt_check:-}" ] || { echo '{"ok":true}'; exit 0; }
seq=$(write job.ended "$(printf '%s' "$plan" | jq -r .root)" "$(printf '%s' "$plan" | jq -r .round)" "$opt_job" \
	"$(jq -nc --arg r "$opt_reason" '{reason: $r}')") || recheck $?
jq -nc --argjson s "$seq" '{ok: true, ended: $s}'
