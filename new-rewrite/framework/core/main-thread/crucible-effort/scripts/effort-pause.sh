#!/usr/bin/env sh
# Pauses an open effort, with the human's words.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh effort-pause.sh --effort FOLDER --words TEXT
       sh effort-pause.sh --help | -h

Writes effort.paused to an open effort; effort-resume.sh brings it back.

  --effort FOLDER   the effort's folder, absolute
  --words TEXT      why, in the human's own words

stdout: the event's path
Exit: 0 paused; 2 refused (not open, or a bad value), the reason on stderr;
  6 the events lock stayed held, nothing written: rerun
USAGE
}

ef_prog='effort-pause.sh'
. "$(dirname -- "$0")/lib/effort.sh"
effort='' words=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--effort | --words)
			[ $# -ge 2 ] || ef_refuse "$1 needs a value"
			case $1 in --effort) effort=$2 ;; --words) words=$2 ;; esac
			shift 2 ;;
		*) ef_refuse "unknown argument $1; try --help" ;;
	esac
done
ef_check "${effort}"
body=$(mktemp)
trap 'rm -f -- "${body}"' EXIT
jq -n --arg words "${words}" '{words: $words}' >"${body}"
ef_write effort.paused "${effort}" "${body}"
