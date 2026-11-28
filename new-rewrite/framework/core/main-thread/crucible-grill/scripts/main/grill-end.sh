#!/usr/bin/env sh
# Ends a grill: writes it once as a grill.ended event and removes the draft.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh grill-end.sh --grill FILE

Ends an open grill for good. Use when the human says you share one
understanding; open and deferred questions may remain.

Options:
  --grill FILE  the open grill's draft <effort>/grills/<n>.json, absolute
Requires:  the effort is open
Writes:    one grill.ended event holding the draft; deletes the draft
Stdout:    one path: the grill.ended event, absolute
Exit:
  0  ended
  2  refused, nothing written; the reason is on stderr
  6  the events lock stayed held, nothing written: rerun
USAGE
}

gr_prog='grill-end.sh'
. "$(dirname -- "$0")/../lib/grill.sh"
grill=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--grill) [ $# -ge 2 ] || gr_refuse '--grill needs a value'; grill=$2; shift 2 ;;
		*) gr_refuse "unknown argument $1; try --help" ;;
	esac
done
gr_set_grill "${grill}"
gr_require_open
gr_lock
event=$(sh "${gr_writer}" --effort "${gr_effort}" --type grill.ended --by "${gr_prog}" \
	--body-file "${gr_file}") || exit $?
rm -f -- "${gr_file}"
printf '%s\n' "${event}"
