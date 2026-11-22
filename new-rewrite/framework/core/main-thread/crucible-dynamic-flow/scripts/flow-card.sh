#!/usr/bin/env sh
# Prints the card for agreeing a flow not yet agreed.
# shellcheck source-path=SCRIPTDIR
set -eu

usage() {
	cat <<'USAGE'
usage: sh flow-card.sh --file FLOW
       sh flow-card.sh --help | -h

Prints the card for agreeing FLOW, a flow not yet agreed: its goal, then
each step resolved from the catalogue (flow-candidates.sh): what it does,
the skills it uses and the event that ends it. A FLOW of the wrong shape, or one
naming a step that isn't declared, is refused, naming each problem. Reads
only.

  --file FLOW   the flow's JSON file:
                {"goal": "<one line>", "steps": [{"id": N, "step": "<key>"}, ...]}

Exit: 0 printed; 2 refused, the reason on stderr
USAGE
}

fl_prog='flow-card.sh'
. "$(dirname -- "$0")/lib/flow.sh"
. "$(dirname -- "$0")/lib/catalogue.sh"
file=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--file) [ $# -ge 2 ] || fl_refuse '--file needs a value'; file=$2; shift 2 ;;
		*) fl_refuse "unknown argument $1; try --help" ;;
	esac
done
[ -f "${file}" ] || fl_refuse "--file ${file} is not a file"
problems=$(jq -r -L "${fl_lib}" 'include "flow-replay"; proposal_problems' "${file}" 2>/dev/null) || fl_refuse "${file} is not JSON"
[ -z "${problems}" ] || fl_refuse "$(printf '%s' "${problems}" | paste -sd '|' - | sed 's/|/; /g')"
cat=$(ct_catalogue) || exit 2
resolved=$(jq -c '.steps' "${file}" | ct_resolve "${cat}")
problems=$(printf '%s' "${resolved}" | jq -r '.problems[]')
[ -z "${problems}" ] || fl_refuse "$(printf '%s' "${problems}" | paste -sd '|' - | sed 's/|/; /g')"
printf '%s' "${resolved}" | jq -r --arg goal "$(jq -r '.goal' "${file}")" '
	"Flow to agree: \($goal)",
	(.steps[] | "  \(.id). \(.does) [\(.skills | join(", "))]",
		"     ends with: \(.ends_with.event)\(if .ends_with.match then " matching \(.ends_with.match | tojson)" else "" end)")'
