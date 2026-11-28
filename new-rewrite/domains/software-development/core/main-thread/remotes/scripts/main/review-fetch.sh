#!/usr/bin/env sh
# Reads the review threads of one fetched change from its host and records
# them as remote-review.fetched, the threads pinned.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh review-fetch.sh --effort FOLDER --change SEQ [--bot NAME]...

Use when an outside review of a fetched change is to be judged, or to read
it again after it moved. Read-only on the host; no gate needed.

Options:
  --effort FOLDER  the effort's folder, absolute
  --change SEQ     the seq of the change's remote-change.fetched
  --bot NAME       an account the human names as AI, repeatable; given none,
                   the names of this change's last fetch are kept, none at
                   the first; on GitHub the host's Bot is one anyway
Requires:  gh or glab logged in for the change's host
Writes:    reports/remote-review/SEQ.json, the threads; the event
           remote-review.fetched
Stdout:    "remote-review.fetched SEQ: N threads of URL at HEAD"
Exit:
  0  fetched and recorded
  1  a read failed, timed out or came back incomplete; the reason is on
     stderr
  2  refused, nothing recorded; the reason is on stderr
USAGE
}

PROG='review-fetch.sh'
say() { printf '%s: %s\n' "${PROG}" "$1" >&2; exit "$2"; }
effort='' change=''
bots_given=no
set_bots=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--effort | --change)
			[ $# -ge 2 ] && [ -n "$2" ] || say "$1 needs a value; try --help" 2
			case $1 in --effort) effort=$2 ;; *) change=$2 ;; esac
			shift 2 ;;
		--bot)
			[ $# -ge 2 ] && [ -n "$2" ] || say '--bot needs a name; try --help' 2
			bots_given=yes
			set_bots="${set_bots} $2"
			shift 2 ;;
		*) say "unknown argument $1; try --help" 2 ;;
	esac
done
command -v jq >/dev/null 2>&1 || say 'jq missing; expected jq 1.6 or later on PATH' 2
case ${effort} in /*) ;; *) say '--effort must be an absolute folder' 2 ;; esac
[ -d "${effort}/events" ] || say "${effort} is not an effort folder" 2
printf '%s' "${change}" | grep -Eqx '[1-9][0-9]*' || say '--change must be the seq of a remote-change.fetched' 2

self=$0
case ${self} in /*) ;; *) self="$(pwd)/${self}" ;; esac
# shellcheck disable=SC2034 # read by pin.sh
remote_skills=${self%/*/*/*/*}
here=${self%/*/*}
# shellcheck source=../lib/remote.sh
. "${here}/lib/remote.sh"
# shellcheck source=../lib/pin.sh
. "${here}/lib/pin.sh"

work=$(mktemp -d "${TMPDIR:-/tmp}/review-fetch.XXXXXX") || remote_fail 1 'mktemp failed; expected a writable temp dir'
trap 'rm -rf -- "${work}"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

reader="${remote_skills}/crucible-events/scripts/internal/events-read.sh"
[ -f "${reader}" ] || remote_fail 2 "crucible-events isn't beside this skill (expected ${reader}); install first"
sh "${reader}" --effort "${effort}" >"${work}/events" || remote_fail 2 'the effort'"'"'s events could not be read'
url=$(jq -r --argjson c "${change}" '[.[] | select(.seq == $c and .type == "remote-change.fetched")][0].body.url // empty' "${work}/events")
[ -n "${url}" ] || remote_fail 2 "event ${change} is not a remote-change.fetched"

# The bots: the names given, or this change's last fetch's.
if [ "${bots_given}" = yes ]; then
	bots='[]'
	for b in ${set_bots}; do bots=$(printf '%s' "${bots}" | jq -c --arg b "${b}" '. + [$b] | unique'); done
else
	bots=$(jq -c --argjson c "${change}" '[.[] | select(.type == "remote-review.fetched" and .body.change == $c)] | last | .body.bots // []' "${work}/events")
fi
set -- --url "${url}"
for b in $(printf '%s' "${bots}" | jq -r '.[]'); do set -- "$@" --bot "${b}"; done

sh "${here}/internal/change-read.sh" --url "${url}" >"${work}/change.json" || exit $?
sh "${here}/internal/review-read.sh" "$@" >"${work}/threads.json" || exit $?

jq -c --argjson c "${change}" --argjson bots "${bots}" --slurpfile t "${work}/threads.json" \
	'{change: $c, head, threads: ($t[0].threads | length), bots: $bots}' "${work}/change.json" >"${work}/body.json"
seq=$(pin_write "${effort}" remote-review.fetched remote-review "${work}/threads.json" "${work}/body.json")
jq -r --argjson s "${seq}" --arg url "${url}" '"remote-review.fetched \($s): \(.threads) threads of \($url) at \(.head[0:12])"' "${work}/body.json"
