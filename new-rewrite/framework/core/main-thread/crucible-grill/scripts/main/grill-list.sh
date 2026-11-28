#!/usr/bin/env sh
# Lists an effort's grills, open and ended.
# shellcheck source-path=SCRIPTDIR
set -eu

usage() {
	cat <<'USAGE'
usage: sh grill-list.sh --effort FOLDER

Lists an effort's grills, open and ended, to find one to resume or read.
Works whatever state the effort is in.

Options:
  --effort FOLDER  the effort's folder, absolute
Writes:    nothing
Stdout:    one tab-separated line per grill, highest grill number first:
             PATH  open|ended  OPEN  TOPIC
           PATH is the open draft or the grill.ended event, absolute; it is
           what grill-show.sh --grill takes. OPEN is the count of open
           questions. Nothing when the effort has no grills.
Exit:
  0  listed
  2  refused, nothing changed; the reason is on stderr
USAGE
}

gr_prog='grill-list.sh'
. "$(dirname -- "$0")/../lib/grill.sh"
effort=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--effort) [ $# -ge 2 ] || gr_refuse '--effort needs a value'; effort=$2; shift 2 ;;
		*) gr_refuse "unknown argument $1; try --help" ;;
	esac
done
gr_set_effort "${effort}"
ended=$(sh "${gr_reader}" --effort "${gr_effort}" --type grill.ended) || exit 2
# Listed after the read, so each event read has its path at the same index.
paths=$(sh "${gr_reader}" --effort "${gr_effort}" --type grill.ended --paths)
{
	for draft in "${gr_dir}"/[1-9]*.json; do
		[ -f "${draft}" ] || continue
		jq -c --arg f "${draft}" '{f: $f, state: "open", g: .}' "${draft}"
	done
	printf '%s\n' "${ended}" | jq -c --arg paths "${paths}" \
		'($paths | split("\n")) as $p | to_entries[] | {f: $p[.key], state: "ended", g: .value.body}'
} | jq -rs 'sort_by(.g.number) | reverse | .[]
	| [.f, .state, ([.g.questions[] | select(.status == "open")] | length), .g.topic] | @tsv'
