#!/usr/bin/env sh
# Lists the steps the components beside this one declare in their flow-step.json,
# the only steps a flow may hold.
# shellcheck source-path=SCRIPTDIR
set -eu

usage() {
	cat <<'USAGE'
usage: sh flow-candidates.sh [--stage NAME]
       sh flow-candidates.sh --stages
       sh flow-candidates.sh --help | -h

Lists the steps declared in every flow-step.json beside this component (the
folder holding it, as this script was called: installed, the skills
folder), one line each, sorted by key:
  <key> · <does> · ends with <event>[ matching <match>] · stages: <names> · skills: <names> · propose when: <propose_when>
The key, <component>/<name>, is how a flow names a step. A stage is a
filter, never an order.

  --stage NAME   only the steps whose stage holds NAME
  --stages       each stage name found, with its number of steps

A flow-step.json is a JSON array of entries {name, stage, does, propose_when,
ends_with, skills}: stage lists one stage or more; ends_with is {event,
match?}, an event with exactly one rule and never gate.answered; skills
lists the skills main loads for the step, each one installed beside it. A file or entry of the
wrong shape is left out, one line per problem on stderr:
  flow-candidates.sh: left out <file>[ <key>]: <problem>

Exit: 0 printed (an empty list included); 2 a usage error. Reads only.
USAGE
}

fl_prog='flow-candidates.sh'
. "$(dirname -- "$0")/lib/flow.sh"
. "$(dirname -- "$0")/lib/catalogue.sh"
stage='' stages=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--stage) [ $# -ge 2 ] || fl_refuse '--stage needs a value'; stage=$2; shift 2 ;;
		--stages) stages=1; shift ;;
		*) fl_refuse "unknown argument $1; try --help" ;;
	esac
done
[ -z "${stage}" ] || [ -z "${stages}" ] || fl_refuse '--stage and --stages go alone'
cat=$(ct_catalogue)
printf '%s' "${cat}" | jq -r '.rejected[] | "flow-candidates.sh: left out \(.file)\(if .key then " \(.key)" elif .entry != null then " entry \(.entry)" else "" end): \(.problem)"' >&2
if [ -n "${stages}" ]; then
	printf '%s' "${cat}" | jq -r '[.entries[].stage[]] | group_by(.) | map("\(.[0]) \(length)")[]'
else
	printf '%s' "${cat}" | jq -r --arg stage "${stage}" '.entries[]
		| select($stage == "" or (.stage | index([$stage])))
		| "\(.key) · \(.does) · ends with \(.ends_with.event)\(if .ends_with.match then " matching \(.ends_with.match | tojson)" else "" end) · stages: \(.stage | join(", ")) · skills: \(.skills | join(", ")) · propose when: \(.propose_when)"'
fi
