#!/usr/bin/env sh
# Prints the card for agreeing a flow not yet agreed.
# shellcheck source-path=SCRIPTDIR
set -eu

usage() {
	cat <<'USAGE'
usage: sh flow-card.sh --file FLOW

Prints the card for a proposed flow, to show at the flow-agree gate; the
same FLOW then goes to flow-agree.sh --file.

Options:
  --file FLOW  {"goal": "<one line>", "steps": [{"id": N, "step":
               "<component>/<name>"}, ...]}: ids unique from 1, each step
               a key flow-candidates.sh lists, repeatable under another id
Writes:    nothing
Stdout:    the card, plain text: the goal, then each step's does, skills
           and ending event, in file order
Exit:
  0  printed
  2  refused, nothing changed; the reason is on stderr
USAGE
}

fl_prog='flow-card.sh'
. "$(dirname -- "$0")/../lib/flow.sh"
. "$(dirname -- "$0")/../lib/catalogue.sh"
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
