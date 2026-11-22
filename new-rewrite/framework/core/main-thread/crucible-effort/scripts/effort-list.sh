#!/usr/bin/env sh
# Lists the efforts, newest change first.
# shellcheck source-path=SCRIPTDIR
set -eu

usage() {
	cat <<'USAGE'
usage: sh effort-list.sh [--all]
       sh effort-list.sh --help | -h

Prints one line per open or paused effort, newest change first,
tab-separated:
  <folder>  <state>  <name>  <at>
With --all, closed efforts too, their state shown as closed:<outcome>.
Prints nothing when there are none.

Exit: 0 listed; 2 an unknown argument
USAGE
}

ef_prog='effort-list.sh'
. "$(dirname -- "$0")/lib/effort.sh"
all=false
case ${1-} in
	-h | --help) usage; exit 0 ;;
	--all) all=true ;;
	'') ;;
	*) ef_refuse "unknown argument $1; try --help" ;;
esac
[ -d "${ef_efforts}" ] || exit 0
for folder in "${ef_efforts}"/*; do
	[ -d "${folder}/events" ] && [ ! -L "${folder}" ] || continue
	ef_summary "${folder}"
done | jq -rs --argjson all "${all}" '
	map(select($all or .state != "closed")) | sort_by(.at) | reverse | .[]
	| [.folder, (if .state == "closed" then "closed:\(.outcome)" else .state end), .name, .at] | @tsv'
