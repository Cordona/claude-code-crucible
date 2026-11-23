#!/usr/bin/env sh
# Prints where a flow stands, or every open flow of an effort, from the events alone.
# shellcheck source-path=SCRIPTDIR
set -eu

usage() {
	cat <<'USAGE'
usage: sh flow-show.sh --flow NAME [--all]
       sh flow-show.sh --effort FOLDER [--all]

Prints where flows stand, from the effort's events: one flow, even ended,
or every flow of an effort that has not ended. Use it to see the next step,
or whether a flow can end, before flow-step-done.sh or flow-end.sh.

Options:
  --flow NAME      the flow, as flow-agree.sh printed it; wins over --effort
  --effort FOLDER  the effort folder, absolute
  --all            adds `      event SEQ` under each done step: its event
Writes:    nothing
Stdout:    per flow, `flow FOLDER:SEQ · GOAL`, plus ` · ended OUTCOME` once
           ended; then one line per step, `  [M] ID DOES`, M is x done,
           - skipped, space open, ! open with evidence waiting (the line
           ends `  (evidence waiting: event SEQ, ...)`); then, unless ended,
           `  next: ID DOES` or `  every step is done or skipped: end the flow`
Exit:
  0  printed; nothing when no flow of the effort is open
  2  refused, nothing changed; the reason is on stderr
USAGE
}

fl_prog='flow-show.sh'
. "$(dirname -- "$0")/../lib/flow.sh"
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
	fl_read_events
	printf '%s\n' "${fl_all}" | jq -e --argjson s "${fl_seq}" 'any(.[]; .seq == $s and .type == "flow.agreed")' >/dev/null \
		|| fl_refuse "${flow} is not a flow of this effort"
else
	fl_set_effort "${effort}"
	seqs=null
	fl_read_events
fi
# shellcheck disable=SC2016 # the $ names are jq's
printf '%s\n' "${fl_all}" | jq -r -L "${fl_lib}" --argjson seqs "${seqs}" --argjson all "${all}" --arg effort "${fl_effort}" 'include "flow-replay";
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
