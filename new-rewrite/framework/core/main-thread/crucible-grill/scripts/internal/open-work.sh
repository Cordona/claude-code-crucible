#!/usr/bin/env sh
# Prints the effort's open grills, one line each: the open-work contract.
# shellcheck source-path=SCRIPTDIR
set -eu

usage() {
	cat <<'USAGE'
usage: sh open-work.sh --effort FOLDER

Run by crucible-effort's effort-close.sh; not for main to call.
Lists the effort's open grills: drafts not yet ended.

Options:
  --effort FOLDER  the effort's folder, absolute
Writes:    nothing
Stdout:    one line per open grill, by number, `grill <n> "<topic>"`;
           nothing when none is open
Exit:
  0  checked; the lines are the open grills
  2  refused, nothing changed; the reason is on stderr
USAGE
}

gr_prog='open-work.sh'
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
for draft in "${gr_dir}"/[1-9]*.json; do
	[ -f "${draft}" ] || continue
	jq -c '{number, topic}' "${draft}"
done | jq -rs 'sort_by(.number) | .[] | "grill \(.number) \"\(.topic)\""'
