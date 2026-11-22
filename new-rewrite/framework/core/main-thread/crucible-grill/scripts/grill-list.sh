#!/usr/bin/env sh
# Lists an effort's grills, open and ended.
# shellcheck source-path=SCRIPTDIR
set -eu

usage() {
	cat <<'USAGE'
usage: sh grill-list.sh --effort FOLDER
       sh grill-list.sh --help | -h

Prints one line per grill, newest first by number, tab-separated:
  <the draft or the grill.ended event>  <open|ended>  <open questions>  <topic>
Prints nothing when the effort has none. Reads only.

Exit: 0 listed; 2 refused, the reason on stderr
USAGE
}

gr_prog='grill-list.sh'
. "$(dirname -- "$0")/lib/grill.sh"
effort=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--effort) [ $# -ge 2 ] || gr_refuse '--effort needs a value'; effort=$2; shift 2 ;;
		*) gr_refuse "unknown argument $1; try --help" ;;
	esac
done
gr_set_effort "${effort}"
{
	for draft in "${gr_dir}"/[1-9]*.json; do
		[ -f "${draft}" ] || continue
		jq -c --arg f "${draft}" '{f: $f, state: "open", g: .}' "${draft}"
	done
	sh "${gr_reader}" --effort "${gr_effort}" --type grill.ended --paths | while IFS= read -r event; do
		jq -c --arg f "${event}" '{f: $f, state: "ended", g: .body}' "${event}"
	done
} | jq -rs 'sort_by(.g.number) | reverse | .[]
	| [.f, .state, ([.g.questions[] | select(.status == "open")] | length), .g.topic] | @tsv'
