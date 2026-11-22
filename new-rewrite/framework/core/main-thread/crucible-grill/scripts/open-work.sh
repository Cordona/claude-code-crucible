#!/usr/bin/env sh
# Prints the effort's open grills, one line each: the open-work contract.
# shellcheck source-path=SCRIPTDIR
set -eu

usage() {
	cat <<'USAGE'
usage: sh open-work.sh --effort FOLDER
       sh open-work.sh --help | -h

Prints one line per open grill (a draft not yet ended), by number:
  grill <n> "<topic>"
and nothing when none is open. Reads only.

  --effort FOLDER   the effort's folder, absolute

Exit: 0 printed; 2 refused, the reason on stderr
USAGE
}

gr_prog='open-work.sh'
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
for draft in "${gr_dir}"/[1-9]*.json; do
	[ -f "${draft}" ] || continue
	jq -c '{number, topic}' "${draft}"
done | jq -rs 'sort_by(.number) | .[] | "grill \(.number) \"\(.topic)\""'
