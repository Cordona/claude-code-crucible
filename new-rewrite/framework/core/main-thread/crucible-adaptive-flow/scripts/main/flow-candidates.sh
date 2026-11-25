#!/usr/bin/env sh
# Lists the steps the components beside this one declare in their flow-step.json,
# the only steps a flow may hold.
# shellcheck source-path=SCRIPTDIR
set -eu

usage() {
	cat <<'USAGE'
usage: sh flow-candidates.sh [--stage NAME]
       sh flow-candidates.sh --stages

Lists the steps a flow may hold, from the installed components'
flow-step.json; a bad entry is left out, its reason on stderr. Run before
an effort's work starts, and to pick the next stage.

Options:
  --stage NAME  only the steps of stage NAME; default all
  --stages      each stage with its number of steps instead
Writes:    nothing
Stdout:    one line per step, sorted by its key <component>/<name>:
           <key> · <does> · ends with <event>[ matching <JSON>] · stages:
           <names> · skills: <names> · propose when: <text>; a stage is a
           filter, never an order. --stages: <stage> <count> lines
Exit:
  0  listed, an empty list included
  2  refused, nothing changed; the reason is on stderr
USAGE
}

fl_prog='flow-candidates.sh'
. "$(dirname -- "$0")/../lib/flow.sh"
. "$(dirname -- "$0")/../lib/catalogue.sh"
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
