#!/usr/bin/env sh
# Prints the card for agreeing a flow not yet agreed.
# shellcheck source-path=SCRIPTDIR
set -eu

usage() {
	cat <<'USAGE'
usage: sh flow-card.sh --file FLOW
       sh flow-card.sh --help | -h

Prints the card for agreeing FLOW, a flow not yet agreed: its goal, each
step and its check, and the flow's own check. A FLOW of the wrong shape is
refused, naming each problem. Reads only.

  --file FLOW   the flow's JSON file: {goal, done_when, steps}

Exit: 0 printed; 2 refused, the reason on stderr
USAGE
}

fl_prog='flow-card.sh'
. "$(dirname -- "$0")/lib/flow.sh"
file=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--file) [ $# -ge 2 ] || fl_refuse '--file needs a value'; file=$2; shift 2 ;;
		*) fl_refuse "unknown argument $1; try --help" ;;
	esac
done
[ -f "${file}" ] || fl_refuse "--file ${file} is not a file"
problems=$(jq -r -L "${fl_lib}" 'include "flow-replay"; flow_problems' "${file}" 2>/dev/null) || fl_refuse "${file} is not JSON"
[ -z "${problems}" ] || fl_refuse "$(printf '%s' "${problems}" | paste -sd '|' - | sed 's/|/; /g')"
# shellcheck disable=SC2016 # the $ names are jq's
jq -r 'def check: if .event then "event \(.event)\(if .match then " matching \(.match | tojson)" else "" end)"
		else "\(.criteria)\(if .by == "human" then " (you confirm)" else " (main verifies)" end)" end;
	"Flow to agree: \(.goal)",
	(.steps[] | "  \(.id). \(.do)\(if .uses then " [\(.uses)]" else "" end)", "     done when: \(.done_when | check)"),
	"  The flow is done when: \(.done_when | check)"' "${file}"
