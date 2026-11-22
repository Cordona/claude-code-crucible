#!/usr/bin/env sh
# Ends a grill: writes it once as a grill.ended event and removes the draft.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh grill-end.sh --grill PATH
       sh grill-end.sh --help | -h

Writes the grill as the body of one grill.ended event, then removes the
draft. Open and deferred questions stay as they are: an ended grill is not
all decisions. To give it to the agents, add the event's path to the
effort's context.

  --grill PATH   the open grill's draft

stdout: the grill.ended event, absolute
Exit: 0 ended; 2 refused, nothing written, the reason on stderr
USAGE
}

gr_prog='grill-end.sh'
. "$(dirname -- "$0")/lib/grill.sh"
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
	--body-file "${gr_file}") || exit 2
rm -f -- "${gr_file}"
printf '%s\n' "${event}"
