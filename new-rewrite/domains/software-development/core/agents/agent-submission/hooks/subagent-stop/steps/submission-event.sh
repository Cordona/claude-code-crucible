#!/usr/bin/env sh
# A step of submit-agent-work.sh: writes the job's submission event.
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh submission-event.sh --effort FOLDER --job FILE --type TYPE
                              --sha256 SHA [--commit SHA]

Run by submit-agent-work.sh; not for main to call.
Writes the job's submission event: {job, iteration, fix_round?, agent,
report: {path, sha256}, commit?}, its stamps the job's.

Options:
  --effort FOLDER  the effort's folder, absolute
  --job FILE       the job, as job-of.sh prints it, assigned
  --type TYPE      the event's type, as build.submitted
  --sha256 SHA     the pinned report's sha256
  --commit SHA     the working commit; left out when the tree didn't change
Reads:     CLAUDE_CODE_SESSION_ID, stamped on the event; empty when alone
Writes:    one event
Stdout:    the event's absolute path
Exit:
  0  written
  2  refused, nothing written; the reason is on stderr
  6  the events lock stayed held: rerun
USAGE
}

prog='submission-event.sh'
refuse() {
	printf '%s: %s\n' "${prog}" "$1" >&2
	exit 2
}

effort='' job='' type='' sha256='' commit=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--effort | --job | --type | --sha256 | --commit)
			[ $# -ge 2 ] && [ -n "$2" ] || refuse "$1 needs a value"
			case $1 in
				--effort) effort=$2 ;; --job) job=$2 ;; --type) type=$2 ;;
				--sha256) sha256=$2 ;; --commit) commit=$2 ;; *) ;;
			esac
			shift 2 ;;
		*) refuse "unknown argument $1; try --help" ;;
	esac
done
command -v jq >/dev/null 2>&1 || refuse 'jq not found'
[ -n "${job}" ] && [ -f "${job}" ] || refuse '--job must be a file holding job-of.sh output'
[ -n "${type}" ] || refuse '--type missing'
[ -n "${sha256}" ] || refuse '--sha256 missing'

self=$0
case ${self} in /*) ;; *) self="$(pwd)/${self}" ;; esac
writer="${self%/*/*/*/*/*}/crucible-events/scripts/internal/event-write.sh"
[ -f "${writer}" ] || refuse "crucible-events isn't beside this skill (expected ${writer}); install first"

body=$(mktemp "${TMPDIR:-/tmp}/submission-body.XXXXXX") || refuse 'mktemp could not make a temp file'
trap 'rm -f -- "${body}"' EXIT
jq -L "$(dirname -- "$0")/../../../scripts/lib" --arg sha256 "${sha256}" --arg commit "${commit}" \
	'include "stamps"; st_submission($sha256; $commit)' "${job}" >"${body}" || refuse 'the job could not be read'
sh "${writer}" --effort "${effort}" --type "${type}" --by "${prog}" --body-file "${body}"
