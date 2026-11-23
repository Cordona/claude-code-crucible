#!/usr/bin/env sh
# Prints an effort's state as one word, for other pieces to check.
# shellcheck source-path=SCRIPTDIR
set -eu

usage() {
	cat <<'USAGE'
usage: sh effort-state.sh --effort FOLDER

Prints an effort's current state. Use it to check an effort is open before
acting on it; effort-status.sh gives the human a full line.

Options:
  --effort FOLDER  the effort's folder, absolute, as an effort script printed it
Reads:     CRUCIBLE_HOME, default $HOME/.crucible; efforts live in its efforts/
Writes:    nothing
Stdout:    one word: open, paused or closed
Exit:
  0  printed
  2  refused, nothing changed; the reason is on stderr
USAGE
}

ef_prog='effort-state.sh'
. "$(dirname -- "$0")/../lib/effort.sh"
effort=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--effort) [ $# -ge 2 ] || ef_refuse '--effort needs a value'; effort=$2; shift 2 ;;
		*) ef_refuse "unknown argument $1; try --help" ;;
	esac
done
ef_check "${effort}"
summary=$(ef_summary "${effort}") || exit 2
printf '%s\n' "${summary}" | jq -r '.state'
