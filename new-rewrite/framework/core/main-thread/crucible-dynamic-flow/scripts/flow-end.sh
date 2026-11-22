#!/usr/bin/env sh
# Ends an open flow: done, once every step is done or skipped, or dropped, with the human's words.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh flow-end.sh --flow NAME --outcome done
       sh flow-end.sh --flow NAME --outcome dropped --words LINE
       sh flow-end.sh --help | -h

Writes flow.ended. done needs every step done or skipped: each step ended
in its own event, so that is the whole check. dropped needs the human's
words.

stdout: the event's path
Exit: 0 ended; 2 refused, nothing written, the reasons on stderr;
  6 the events lock stayed held: rerun
USAGE
}

fl_prog='flow-end.sh'
. "$(dirname -- "$0")/lib/flow.sh"
flow='' outcome='' words=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--flow | --outcome | --words)
			[ $# -ge 2 ] || fl_refuse "$1 needs a value"
			case $1 in --flow) flow=$2 ;; --outcome) outcome=$2 ;; --words) words=$2 ;; esac
			shift 2 ;;
		*) fl_refuse "unknown argument $1; try --help" ;;
	esac
done
fl_set_flow "${flow}"
case ${outcome} in done | dropped) ;; *) fl_refuse '--outcome must be done or dropped' ;; esac
fl_require_open
# shellcheck disable=SC2016 # the $ names are jq's
body=$(fl_events | jq -c -L "${fl_lib}" --argjson flow "${fl_seq}" --arg outcome "${outcome}" \
	--arg words "${words}" 'include "flow-replay";
	. as $all | (flow_state($flow)? // null) as $f
	| if $f == null then {problem: "\($flow) is not a flow of this effort"}
	  elif $outcome == "dropped" then {body: {flow: $flow, outcome: "dropped", words: $words}}
	  else {body: {flow: $flow, outcome: "done"}} end')
problem=$(printf '%s' "${body}" | jq -r '.problem // empty')
[ -z "${problem}" ] || fl_refuse "${problem}"
file=$(mktemp)
trap 'rm -f -- "${file}"' EXIT
printf '%s' "${body}" | jq '.body' >"${file}"
fl_write flow.ended "${file}"
