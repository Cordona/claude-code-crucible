#!/usr/bin/env sh
# Closes an open or paused effort with its outcome and the human's words.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh effort-close.sh --effort FOLDER --outcome done|dropped --words TEXT
                          [--leave-open]

Closes an open or paused effort, when the human closes it.

Options:
  --effort FOLDER   the effort's folder, absolute
  --outcome VALUE   done or dropped
  --words TEXT      why, in the human's own words; not blank
  --leave-open      close despite open work, only on the human's word; what
                    was open, and any failed check, goes in left_open
Requires:  no component reports open work (flow, grill, git worktree, mount)
Writes:    one effort.closed event, body {outcome, words, left_open?}
Stdout:    one line, the new event's absolute path
Exit:
  0  closed
  2  refused, nothing written; the reason is on stderr
  6  the events lock stayed held, nothing written: rerun
USAGE
}

ef_prog='effort-close.sh'
. "$(dirname -- "$0")/../lib/effort.sh"
effort='' outcome='' words='' leave_open=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--leave-open) leave_open=1; shift ;;
		--effort | --outcome | --words)
			[ $# -ge 2 ] || ef_refuse "$1 needs a value"
			case $1 in --effort) effort=$2 ;; --outcome) outcome=$2 ;; --words) words=$2 ;; esac
			shift 2 ;;
		*) ef_refuse "unknown argument $1; try --help" ;;
	esac
done
ef_check "${effort}"
body=$(mktemp)
open=$(mktemp)
trap 'rm -f -- "${body}" "${open}"' EXIT

# Open work, from each component's own open-work.sh: effort names none of them.
. "$(dirname -- "$0")/../../../crucible-events/scripts/lib/beside.sh"
components=$(bs_components "$0" 2) || ef_refuse 'the components folder beside crucible-effort is not there'
for check in "${components}"/*/scripts/internal/open-work.sh; do
	[ -f "${check}" ] || continue
	component=${check%/scripts/internal/open-work.sh}
	component=${component##*/}
	if lines=$(sh "${check}" --effort "${effort}" 2>/dev/null); then
		printf '%s\n' "${lines}" | sed '/^[[:space:]]*$/d' >>"${open}"
	else
		printf '%s: check failed\n' "${component}/scripts/internal/open-work.sh" >>"${open}"
	fi
done
if [ -s "${open}" ] && [ -z "${leave_open}" ]; then
	ef_refuse "open work: $(paste -sd '|' "${open}" | sed 's/|/; /g'); end it first, or close with --leave-open on the human's word"
fi
jq -n --arg outcome "${outcome}" --arg words "${words}" --rawfile open "${open}" '
	{outcome: $outcome, words: $words}
	+ ($open | split("\n") | map(select(. != "")) | if length > 0 then {left_open: .} else {} end)' >"${body}"
ef_write effort.closed "${effort}" "${body}"
