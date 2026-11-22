#!/usr/bin/env sh
# Marks one step of an open flow done, with the evidence its done_when needs.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh flow-step-done.sh --flow NAME --step ID [--event SEQ | --evidence LINE]
       sh flow-step-done.sh --help | -h

Writes flow.step.done once the evidence is checked:
  an event step: the matching event, not already evidence for another step.
    With --event, the event named, which may be older than the flow (work
    done before the flow was agreed) but not older than the step's reopen.
    Without --event, the one waiting event newer than the step's start or
    reopen is taken; with several waiting, they are named: pick one.
  a criteria step: --evidence, one line: how main verified it, or, for
    "by": "human", the human's words.
Any open step may be marked, in any order.

  --flow NAME   the flow, as flow-agree.sh printed it
  --step ID     the step
  --event SEQ   the event that proves it
  --evidence LINE

stdout: the event's path
Exit: 0 marked; 2 refused, nothing written, the reasons on stderr;
  6 the events lock stayed held: rerun
USAGE
}

fl_prog='flow-step-done.sh'
. "$(dirname -- "$0")/lib/flow.sh"
flow='' step='' event='' evidence=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--flow | --step | --event | --evidence)
			[ $# -ge 2 ] || fl_refuse "$1 needs a value"
			case $1 in --flow) flow=$2 ;; --step) step=$2 ;; --event) event=$2 ;; --evidence) evidence=$2 ;; esac
			shift 2 ;;
		*) fl_refuse "unknown argument $1; try --help" ;;
	esac
done
fl_set_flow "${flow}"
case ${step} in '' | *[!0-9]*) fl_refuse '--step must be a step id' ;; esac
case ${event} in *[!0-9]*) fl_refuse '--event must be an event seq' ;; esac
fl_require_open
all=$(fl_events)
# shellcheck disable=SC2016 # the $ names are jq's
body=$(printf '%s' "${all}" | jq -c -L "${fl_lib}" --argjson flow "${fl_seq}" --argjson step "${step}" \
	--arg event "${event}" --arg evidence "${evidence}" 'include "flow-replay";
	. as $all | (flow_state($flow)? // null) as $f
	| if $f == null then {problem: "\($flow) is not a flow of this effort"}
	  else ($f.steps | map(select(.id == $step)) | first) as $s
		| if $s == null then {problem: "step \($step) is not a step of this flow"}
		  elif ($s.done_when | has("event")) then
			if $event != "" then {body: {flow: $flow, step: $step, kind: "event", event: ($event | tonumber)}}
			else ($all | waiting($f) | map(select(.id == $step)) | first | .events // []) as $ev
				| if ($ev | length) == 1 then {body: {flow: $flow, step: $step, kind: "event", event: $ev[0]}}
				  elif ($ev | length) == 0 then {problem: "no \($s.done_when.event) is waiting for step \($step)"}
				  else {problem: "several events fit step \($step): \($ev | map(tostring) | join(", ")); pick one with --event"} end
			end
		  else {body: {flow: $flow, step: $step, kind: (if $s.done_when.by == "human" then "human" else "main" end), evidence: $evidence}}
		  end
	  end')
problem=$(printf '%s' "${body}" | jq -r '.problem // empty')
[ -z "${problem}" ] || fl_refuse "${problem}"
file=$(mktemp)
trap 'rm -f -- "${file}"' EXIT
printf '%s' "${body}" | jq '.body' >"${file}"
fl_write flow.step.done "${file}"
