#!/usr/bin/env sh
# Prints where a flow stands, or every open flow of an effort, from the events alone.
# shellcheck source-path=SCRIPTDIR
set -eu

usage() {
	cat <<'USAGE'
usage: sh flow-show.sh --flow NAME [--all]
       sh flow-show.sh --effort FOLDER
       sh flow-show.sh --help | -h

Replays the effort's events and prints each flow: its goal, then one line
per step in order, marked
  [x] done, by its event   [-] skipped
  [ ] open                 [!] open, its event waiting
then what is next, and whether the flow can end. --effort prints every
open flow; --all adds the event that ended each done step. Reads only.

Exit: 0 printed; 2 refused, the reason on stderr
USAGE
}

fl_prog='flow-show.sh'
. "$(dirname -- "$0")/lib/flow.sh"
flow='' effort='' all=false
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--flow | --effort)
			[ $# -ge 2 ] || fl_refuse "$1 needs a value"
			case $1 in --flow) flow=$2 ;; --effort) effort=$2 ;; esac
			shift 2 ;;
		--all) all=true; shift ;;
		*) fl_refuse "unknown argument $1; try --help" ;;
	esac
done
if [ -n "${flow}" ]; then
	fl_set_flow "${flow}"
	seqs="[${fl_seq}]"
	fl_events | jq -e --argjson s "${fl_seq}" 'any(.[]; .seq == $s and .type == "flow.agreed")' >/dev/null \
		|| fl_refuse "${flow} is not a flow of this effort"
else
	fl_set_effort "${effort}"
	seqs=null
fi
# shellcheck disable=SC2016 # the $ names are jq's
fl_events | jq -r -L "${fl_lib}" --argjson seqs "${seqs}" --argjson all "${all}" --arg effort "${fl_effort}" 'include "flow-replay";
	. as $events
	| ($seqs // ($events | open_flows))[] as $seq
	| ($events | flow_state($seq)? // null) as $f
	| if $f == null then "\($seq) is not a flow of this effort" else
	  ($events | waiting($f)) as $w
	  | ($w | map(.id)) as $wids
	  | ([$f.steps[] | select(.status == "open")]) as $open
	  | "flow \($effort):\($seq) · \($f.goal)\(if $f.ended then " · ended \($f.ended.outcome)" else "" end)",
	    ($f.steps[] | . as $s
		| (if .status == "done" then "x"
		   elif .status == "skipped" then "-"
		   elif (.id as $i | $wids | index([$i])) then "!" else " " end) as $mark
		| "  [\($mark)] \(.id) \(.does)\(if $mark == "!" then "  (evidence waiting: event \($w | map(select(.id == $s.id)) | first | .events | map(tostring) | join(", ")))" else "" end)",
		  (if $all and .status == "done" then "      event \(.event)" else empty end)),
	    (if $f.ended then empty
	     elif ($open | length) == 0 then "  every step is done or skipped: end the flow"
	     else "  next: \($open[0].id) \($open[0].does)" end)
	  end'
