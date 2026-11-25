#!/usr/bin/env sh
# A step of submit-agent-work.sh: pins an accepted report.
set -eu

usage() {
	cat <<'USAGE'
usage: sh report-pin.sh --report FILE

Run by submit-agent-work.sh; not for main to call.
Makes an accepted report read-only and prints its sha256, from agent-jobs'
report-hash.sh, which the submission event pins it by.

Options:
  --report FILE  the report, absolute
Writes:    the report's mode, read-only (444)
Stdout:    one line, the report's sha256: 64 lowercase hex digits
Exit:
  0  pinned
  2  refused, nothing changed; the reason is on stderr
USAGE
}

prog='report-pin.sh'
refuse() {
	printf '%s: %s\n' "${prog}" "$1" >&2
	exit 2
}

report=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--report) [ $# -ge 2 ] && [ -n "$2" ] || refuse '--report needs a value'; report=$2; shift 2 ;;
		*) refuse "unknown argument $1; try --help" ;;
	esac
done
case ${report} in /*) ;; *) refuse '--report must be an absolute file' ;; esac
[ -f "${report}" ] && [ ! -L "${report}" ] || refuse "${report} is not a file"
self=$0
case ${self} in /*) ;; *) self="$(pwd)/${self}" ;; esac
report_hash="${self%/*/*/*/*}/agent-jobs/scripts/internal/report-hash.sh"
[ -f "${report_hash}" ] || refuse "agent-jobs isn't beside this skill (expected ${report_hash}); install first"
chmod 444 "${report}" || refuse "could not make ${report} read-only"
sh "${report_hash}" --report "${report}" || exit 2
