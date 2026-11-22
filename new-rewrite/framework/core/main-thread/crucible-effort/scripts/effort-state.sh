#!/usr/bin/env sh
# Prints an effort's state as one word, for other pieces to check.
# shellcheck source-path=SCRIPTDIR
set -eu

usage() {
	cat <<'USAGE'
usage: sh effort-state.sh --effort FOLDER
       sh effort-state.sh --help | -h

Prints the effort's state, read from its newest effort event: one word,
open, paused or closed.

  --effort FOLDER   the effort's folder, absolute

Exit: 0 printed; 2 refused, the reason on stderr
USAGE
}

ef_prog='effort-state.sh'
. "$(dirname -- "$0")/lib/effort.sh"
effort=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--effort) [ $# -ge 2 ] || ef_refuse '--effort needs a value'; effort=$2; shift 2 ;;
		*) ef_refuse "unknown argument $1; try --help" ;;
	esac
done
ef_check "${effort}"
ef_summary "${effort}" | jq -r '.state'
