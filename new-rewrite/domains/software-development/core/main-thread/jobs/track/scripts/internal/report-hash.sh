#!/usr/bin/env sh
# Prints the sha256 of one report: the one hash a report is pinned and
# checked by.
set -eu

usage() {
	cat <<'USAGE'
usage: sh report-hash.sh --report FILE

Run by component scripts and hooks; not for main to call.
Prints the sha256 of one report file. The pin and every check of the pin
call it, so both hash the same way.

Options:
  --report FILE  the report, absolute; a file, not a link
Writes:    nothing
Stdout:    one line, 64 lowercase hex digits
Exit:
  0  printed
  2  refused, nothing printed; the reason is on stderr
USAGE
}

prog='report-hash.sh'
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
[ -f "${report}" ] && [ ! -L "${report}" ] && [ -r "${report}" ] || refuse "${report} is not a readable file"
if command -v sha256sum >/dev/null 2>&1; then
	sum=$(sha256sum -- "${report}") || refuse "sha256sum could not read ${report}"
elif command -v shasum >/dev/null 2>&1; then
	sum=$(shasum -a 256 -- "${report}") || refuse "shasum could not read ${report}"
else
	refuse 'neither sha256sum nor shasum is installed'
fi
printf '%s\n' "${sum%% *}"
