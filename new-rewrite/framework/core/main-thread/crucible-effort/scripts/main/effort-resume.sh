#!/usr/bin/env sh
# Resumes a paused or closed effort, putting it back to open, with the
# human's words.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh effort-resume.sh --effort FOLDER --words TEXT

Puts a paused or closed effort back to open. Use it only on the human's ask,
or their yes at a gate.

Options:
  --effort FOLDER  the effort's folder, absolute, as an effort script printed it
  --words TEXT     why, in the human's own words
Requires:  the effort is paused or closed (effort-status.sh shows it)
Reads:     CRUCIBLE_HOME, where efforts live; default $HOME/.crucible
Writes:    one effort.resumed event, body {words}
Stdout:    one line, the new event's absolute path
Exit:
  0  resumed
  2  refused, nothing changed; the reason is on stderr
  6  the events lock stayed held, nothing written: rerun
USAGE
}

ef_prog='effort-resume.sh'
. "$(dirname -- "$0")/../lib/effort.sh"
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
ef_write effort.resumed "${effort}" "${body}"
