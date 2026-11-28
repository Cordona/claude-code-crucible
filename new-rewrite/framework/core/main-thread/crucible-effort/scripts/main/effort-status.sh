#!/usr/bin/env sh
# Prints one effort's state in one line.
# shellcheck source-path=SCRIPTDIR
set -eu

usage() {
	cat <<'USAGE'
usage: sh effort-status.sh --effort FOLDER

Prints one effort's state as one line for the human, to show where it stands.

Options:
  --effort FOLDER  the effort's folder, absolute, as effort-list.sh printed it
Reads:     CRUCIBLE_HOME, default $HOME/.crucible
Writes:    nothing
Stdout:    one line, one of:
             <name> · open since <at>, or resumed <at>: <words>
             <name> · paused <at>: <words>
             <name> · closed, <outcome>, <at>: <words>[; left open: <a, b>]
           <at> is the newest effort event's UTC time; outcome is done|dropped
Exit:
  0  printed
  2  refused, nothing changed; the reason is on stderr
USAGE
}

ef_prog='effort-status.sh'
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
printf '%s\n' "${summary}" | jq -r '
	if .state == "open" and .words != null then "\(.name) · resumed \(.at): \(.words)"
	elif .state == "open" then "\(.name) · open since \(.at)"
	elif .state == "paused" then "\(.name) · paused \(.at): \(.words)"
	else "\(.name) · closed, \(.outcome), \(.at): \(.words)"
		+ (if .left_open then "; left open: \(.left_open | join(", "))" else "" end) end'
