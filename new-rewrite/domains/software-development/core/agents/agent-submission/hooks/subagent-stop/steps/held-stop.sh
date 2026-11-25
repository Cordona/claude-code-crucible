#!/usr/bin/env sh
# A step of submit-agent-work.sh: records a refusal of a job's report, and
# ends the job on the second.
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh held-stop.sh --effort FOLDER --job FILE --lines FILE

Run by submit-agent-work.sh; not for main to call.
Records a refusal of the job's report: job.refused, try the job's refusals
plus one. The second also ends the job: job.ended gave-up, the tree kept. A
job refused twice whose end wasn't written is ended with no third refusal.

Options:
  --effort FOLDER  the effort's folder, absolute
  --job FILE       the job, as job-of.sh prints it, assigned
  --lines FILE     the repair lines, one per line
Reads:     CLAUDE_CODE_SESSION_ID, stamped on the event; empty when alone
Writes:    job.refused; on the second, job.ended
Stdout:    one word: held, or ended
Exit:
  0  recorded
  2  refused, nothing written, or the refusal written and not the end; the
     reason is on stderr
  6  the events lock stayed held: rerun
USAGE
}

prog='held-stop.sh'
# A report refused twice is given up on: a third try rarely repairs what two
# could not, and the stop must not loop.
max_tries=2
refuse() {
	printf '%s: %s\n' "${prog}" "$1" >&2
	exit 2
}

effort='' job='' lines=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--effort | --job | --lines)
			[ $# -ge 2 ] && [ -n "$2" ] || refuse "$1 needs a value"
			case $1 in --effort) effort=$2 ;; --job) job=$2 ;; --lines) lines=$2 ;; *) ;; esac
			shift 2 ;;
		*) refuse "unknown argument $1; try --help" ;;
	esac
done
command -v jq >/dev/null 2>&1 || refuse 'jq not found'
case ${effort} in /*) ;; *) refuse '--effort must be an absolute folder' ;; esac
[ -d "${effort}/events" ] || refuse "${effort} is not an effort folder"
[ -n "${job}" ] && [ -f "${job}" ] || refuse '--job must be a file holding job-of.sh output'
[ -n "${lines}" ] && [ -s "${lines}" ] || refuse '--lines must be a file holding the repair lines'
refusals=$(jq -r '.refusals' "${job}")
printf '%s\n' "${refusals}" | grep -Eqx '[0-9]+' || refuse 'the job has no refusals count'

self=$0
case ${self} in /*) ;; *) self="$(pwd)/${self}" ;; esac
writer="${self%/*/*/*/*/*}/crucible-events/scripts/internal/event-write.sh"
[ -f "${writer}" ] || refuse "crucible-events isn't beside this skill (expected ${writer}); install first"
lib="$(dirname -- "$0")/../../../scripts/lib"

body=$(mktemp "${TMPDIR:-/tmp}/held-stop.XXXXXX") || refuse 'mktemp could not make a temp file'
trap 'rm -f -- "${body}"' EXIT
try=$((refusals + 1))
if [ "${try}" -le "${max_tries}" ]; then
	jq -L "${lib}" --argjson try "${try}" --rawfile lines "${lines}" \
		'include "stamps"; st_stamps + {try: $try, lines: [$lines | split("\n")[] | select(test("\\S"))]}' "${job}" >"${body}" \
		|| refuse 'the job could not be read'
	sh "${writer}" --effort "${effort}" --type job.refused --by "${prog}" --body-file "${body}" >/dev/null
	if [ "${try}" -lt "${max_tries}" ]; then
		echo held
		exit 0
	fi
fi
jq -L "${lib}" 'include "stamps"; st_stamps + {reason: "gave-up"}' "${job}" >"${body}" || refuse 'the job could not be read'
sh "${writer}" --effort "${effort}" --type job.ended --by "${prog}" --body-file "${body}" >/dev/null
echo ended
