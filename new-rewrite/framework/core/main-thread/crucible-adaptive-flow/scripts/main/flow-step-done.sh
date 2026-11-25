#!/usr/bin/env sh
# Marks one step of an open flow done, by the event its ends_with names.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh flow-step-done.sh --flow NAME --step ID [--event SEQ]

Marks one open step done with the event its ends_with names, once that
event is there (flow-show.sh shows it waiting); steps in any order.

Options:
  --flow NAME  the flow, as flow-agree.sh printed it
  --step ID    the step's id
  --event SEQ  the ending event; default the one waiting since the step
               opened, needed when several wait or it predates the flow
Requires:  the effort open, the flow not ended, the step open
Writes:    one flow.step.done event {flow, step, event}
Stdout:    the event's absolute path
Exit:
  0  marked
  2  refused, nothing changed; the reason is on stderr
  6  the events lock stayed held: rerun
USAGE
}

fl_prog='flow-step-done.sh'
. "$(dirname -- "$0")/../lib/flow.sh"
flow='' step='' event=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--flow | --step | --event)
			[ $# -ge 2 ] || fl_refuse "$1 needs a value"
			case $1 in --flow) flow=$2 ;; --step) step=$2 ;; --event) event=$2 ;; esac
			shift 2 ;;
		*) fl_refuse "unknown argument $1; try --help" ;;
	esac
done
fl_set_flow "${flow}"
case ${step} in '' | *[!0-9]*) fl_refuse '--step must be a step id' ;; esac
case ${event} in *[!0-9]*) fl_refuse '--event must be an event seq' ;; esac
fl_require_open
fl_read_events
# shellcheck disable=SC2016 # the $ names are jq's
body=$(printf '%s' "${fl_all}" | jq -c -L "${fl_lib}" --argjson flow "${fl_seq}" --argjson step "${step}" \
	--arg event "${event}" 'include "flow-replay";
	. as $all | (flow_state($flow)? // null) as $f
	| if $f == null then {problem: "\($flow) is not a flow of this effort"}
	  else ($f.steps | map(select(.id == $step)) | first) as $s
		| if $s == null then {problem: "step \($step) is not a step of this flow"}
		  elif $event != "" then {body: {flow: $flow, step: $step, event: ($event | tonumber)}}
		  else ($all | waiting($f) | map(select(.id == $step)) | first | .events // []) as $ev
			| if ($ev | length) == 1 then {body: {flow: $flow, step: $step, event: $ev[0]}}
			  elif ($ev | length) == 0 then {problem: "no \($s.ends_with.event) is waiting for step \($step)"}
			  else {problem: "several events fit step \($step): \($ev | map(tostring) | join(", ")); pick one with --event"} end
		  end
	  end')
problem=$(printf '%s' "${body}" | jq -r '.problem // empty')
[ -z "${problem}" ] || fl_refuse "${problem}"
file=$(mktemp)
trap 'rm -f -- "${file}"' EXIT
printf '%s' "${body}" | jq '.body' >"${file}"
fl_write flow.step.done "${file}"
