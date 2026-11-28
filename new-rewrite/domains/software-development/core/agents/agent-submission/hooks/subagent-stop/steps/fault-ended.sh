#!/usr/bin/env sh
# A step of submit-agent-work.sh: records a fault before the report was
# accepted, which ends the job.
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh fault-ended.sh --effort FOLDER --job FILE --step STEP --fault TEXT

Run by submit-agent-work.sh; not for main to call.
Records a fault before the report was accepted: job.ended fault. The
job ends; the next job starts again.

Options:
  --effort FOLDER  the effort's folder, absolute
  --job FILE       the job, as job-of.sh prints it, assigned
  --step STEP      the step that failed: check or hook
  --fault TEXT     the line the human is told; kept to one line, 300 chars
Reads:     CLAUDE_CODE_SESSION_ID, stamped on the event; empty when alone
Writes:    one job.ended event
Stdout:    nothing
Exit:
  0  written
  2  refused, nothing written; the reason is on stderr
  6  the events lock stayed held: rerun
USAGE
}

prog='fault-ended.sh'
refuse() {
	printf '%s: %s\n' "${prog}" "$1" >&2
	exit 2
}

effort='' job='' step='' fault=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--effort | --job | --step | --fault)
			[ $# -ge 2 ] && [ -n "$2" ] || refuse "$1 needs a value"
			case $1 in --effort) effort=$2 ;; --job) job=$2 ;; --step) step=$2 ;; --fault) fault=$2 ;; *) ;; esac
			shift 2 ;;
		*) refuse "unknown argument $1; try --help" ;;
	esac
done
command -v jq >/dev/null 2>&1 || refuse 'jq not found'
case ${effort} in /*) ;; *) refuse '--effort must be an absolute folder' ;; esac
[ -d "${effort}/events" ] || refuse "${effort} is not an effort folder"
[ -n "${job}" ] && [ -f "${job}" ] || refuse '--job must be a file holding job-of.sh output'

self=$0
case ${self} in /*) ;; *) self="$(pwd)/${self}" ;; esac
writer="${self%/*/*/*/*/*}/crucible-events/scripts/internal/event-write.sh"
[ -f "${writer}" ] || refuse "crucible-events isn't beside this skill (expected ${writer}); install first"

body=$(mktemp "${TMPDIR:-/tmp}/fault-ended.XXXXXX") || refuse 'mktemp could not make a temp file'
trap 'rm -f -- "${body}"' EXIT
jq -L "$(dirname -- "$0")/../../../scripts/lib" --arg step "${step}" --arg fault "${fault}" '
	include "stamps"; st_stamps + {reason: "fault", step: $step, fault: ($fault | gsub("[[:cntrl:]]+"; " ") | .[:300])}' \
	"${job}" >"${body}" || refuse 'the job could not be read'
sh "${writer}" --effort "${effort}" --type job.ended --by "${prog}" --body-file "${body}" >/dev/null
