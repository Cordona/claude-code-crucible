#!/usr/bin/env sh
# Ends an open flow: done, with its own evidence, or dropped, with the human's words.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh flow-end.sh --flow NAME --outcome done [--event SEQ | --evidence LINE]
       sh flow-end.sh --flow NAME --outcome dropped --words LINE
       sh flow-end.sh --help | -h

Writes flow.ended. done needs every step done or skipped, and the flow's own
done_when met: its event (without --event, the newest matching one after
the flow started), or --evidence for a criteria. dropped needs the human's
words.

stdout: the event's path
Exit: 0 ended; 2 refused, nothing written, the reasons on stderr;
  6 the events lock stayed held: rerun
USAGE
}

fl_prog='flow-end.sh'
. "$(dirname -- "$0")/lib/flow.sh"
flow='' outcome='' event='' evidence='' words=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--flow | --outcome | --event | --evidence | --words)
			[ $# -ge 2 ] || fl_refuse "$1 needs a value"
			case $1 in --flow) flow=$2 ;; --outcome) outcome=$2 ;; --event) event=$2 ;; --evidence) evidence=$2 ;; --words) words=$2 ;; esac
			shift 2 ;;
		*) fl_refuse "unknown argument $1; try --help" ;;
	esac
done
fl_set_flow "${flow}"
case ${outcome} in done | dropped) ;; *) fl_refuse '--outcome must be done or dropped' ;; esac
case ${event} in *[!0-9]*) fl_refuse '--event must be an event seq' ;; esac
fl_require_open
# shellcheck disable=SC2016 # the $ names are jq's
body=$(fl_events | jq -c -L "${fl_lib}" --argjson flow "${fl_seq}" --arg outcome "${outcome}" \
	--arg event "${event}" --arg evidence "${evidence}" --arg words "${words}" 'include "flow-replay";
	. as $all | (flow_state($flow)? // null) as $f
	| if $f == null then {problem: "\($flow) is not a flow of this effort"}
	  elif $outcome == "dropped" then {body: {flow: $flow, outcome: "dropped", words: $words}}
	  elif ($f.done_when | has("event")) then
		(if $event != "" then ($event | tonumber)
		 else [$all[] | select(.seq > $f.seq and fits($f.done_when)) | .seq] | last end) as $ev
		| {body: {flow: $flow, outcome: "done", kind: "event", event: $ev}}
	  else {body: {flow: $flow, outcome: "done", kind: (if $f.done_when.by == "human" then "human" else "main" end), evidence: $evidence}}
	  end')
problem=$(printf '%s' "${body}" | jq -r '.problem // empty')
[ -z "${problem}" ] || fl_refuse "${problem}"
file=$(mktemp)
trap 'rm -f -- "${file}"' EXIT
printf '%s' "${body}" | jq '.body' >"${file}"
fl_write flow.ended "${file}"
