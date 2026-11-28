#!/usr/bin/env sh
# Drops, defers or reopens one question of a grill, with a reason.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh grill-mark.sh --grill FILE --id ID --to STATUS --reason TEXT

Drops, defers or reopens one question of an open grill. Reopen a dropped
question before answering it with grill-answer.sh.

Options:
  --grill FILE     the grill's draft, absolute, as grill-new.sh printed it
  --id ID          the question (q<N>), not already in STATUS
  --to STATUS      dropped, deferred or open
  --reason TEXT    why, one line
Requires:  the effort is open
Writes:    the grill draft; dropped or deferred adds answer "<Status>: <reason>"
Stdout:    one line, "<id> <status>"
Exit:
  0  marked
  2  refused, nothing changed; the reason is on stderr
USAGE
}

gr_prog='grill-mark.sh'
. "$(dirname -- "$0")/../lib/grill.sh"
grill='' id='' to='' reason=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--grill | --id | --to | --reason)
			[ $# -ge 2 ] || gr_refuse "$1 needs a value"
			case $1 in --grill) grill=$2 ;; --id) id=$2 ;; --to) to=$2 ;; --reason) reason=$2 ;; esac
			shift 2 ;;
		*) gr_refuse "unknown argument $1; try --help" ;;
	esac
done
case ${to} in dropped | deferred | open) ;; *) gr_refuse '--to must be dropped, deferred or open' ;; esac
printf '%s' "${reason}" | grep -q '[^[:space:]]' || gr_refuse '--reason is empty'
gr_set_grill "${grill}"
gr_require_open
gr_lock
now=$(jq -r --arg id "${id}" '.questions[] | select(.id == $id) | .status' "${gr_file}")
[ -n "${now}" ] || gr_refuse "${id} is not a question of this grill"
[ "${now}" != "${to}" ] || gr_refuse "${id} is already ${to}"
# shellcheck disable=SC2016 # the $ names are jq's
jq --arg id "${id}" --arg to "${to}" --arg reason "${reason}" '
	.questions |= map(if .id == $id then .status = $to
		| if $to == "open" then . else .answers += [{text: "\($to | .[:1] | ascii_upcase)\($to | .[1:]): \($reason)"}] end
	  else . end)' "${gr_file}" | gr_save "${gr_file}"
printf '%s %s\n' "${id}" "${to}"
