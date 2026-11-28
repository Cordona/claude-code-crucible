#!/bin/sh
# Spike: the end card's step: ends a loop with its reason. Refuses a loop
# that has already ended.
# usage: loop-end.sh --effort DIR --loop SEQ --reason REASON [--check] [--session ID]
set -eu
LAB=$(cd "$(dirname "$0")" && pwd); . "$LAB/cli.sh"
parse_opts "$@"
need_seq loop "${opt_loop:-}"
case "${opt_reason:-}" in clean | cap | deadlock | replacement-failed | refused | stopped) ;;
*) die 1 "--reason is clean, cap, deadlock, replacement-failed, refused or stopped" ;; esac
plan_step() {
	evq --argjson l "$opt_loop" 'include "ev"; ev($l) as $F
	| if $F.type != "fix.chosen" then {ok: false, refusal: "not-a-loop"}
	  elif loop_end($F) then {ok: false, refusal: "done-already", by: loop_end($F).seq}
	  else {ok: true, root: $F.root} end'
}
plan=$(plan_step)
printf '%s' "$plan" | jq -e .ok >/dev/null || refusal "$plan"
[ -z "${opt_check:-}" ] || { echo '{"ok":true}'; exit 0; }
seq=$(write loop.ended "$(printf '%s' "$plan" | jq -r .root)" null null "$(jq -nc --arg r "$opt_reason" '{reason: $r}')") || recheck $?
jq -nc --argjson s "$seq" '{ok: true, ended: $s}'
