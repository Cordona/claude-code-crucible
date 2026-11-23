#!/usr/bin/env sh
# Prints the fingerprint of the version a cut would write now, for a plan
# to pin before the human approves it.
# shellcheck source-path=SCRIPTDIR
set -eu

usage() {
	cat <<'USAGE'
usage: sh context-fingerprint.sh --effort FOLDER

Prints the fingerprint of the version context-cut.sh would write now. Run it
right before the context-done gate; FINGERPRINT is the gate's subject.
After any draft change, run it again and ask again.

Options:
  --effort FOLDER  the effort's folder, absolute
Writes:    nothing
Stdout:    FINGERPRINT: <64 lowercase hex>, then VERSION: v<N>, the version
           a cut would write; the latest one when nothing is new
Exit:
  0  printed
  2  refused, nothing changed; the reason on stderr
USAGE
}

cx_prog='context-fingerprint.sh'
. "$(dirname -- "$0")/../lib/context.sh"
. "$(dirname -- "$0")/../lib/path-rule.sh"
. "$(dirname -- "$0")/../lib/body.sh"
effort=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--effort) [ $# -ge 2 ] || cx_refuse '--effort needs a value'; effort=$2; shift 2 ;;
		*) cx_refuse "unknown argument $1; try --help" ;;
	esac
done
cx_set "${effort}"
body=$(bd_build)
printf 'FINGERPRINT: %s\nVERSION: v%s\n' "$(bd_fingerprint "${body}")" "$(printf '%s' "${body}" | jq -r '.version')"
