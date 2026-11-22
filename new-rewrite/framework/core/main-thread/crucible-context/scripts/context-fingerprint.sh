#!/usr/bin/env sh
# Prints the fingerprint of the version a cut would write now, for a plan
# to pin before the human approves it.
# shellcheck source-path=SCRIPTDIR
set -eu

usage() {
	cat <<'USAGE'
usage: sh context-fingerprint.sh --effort FOLDER
       sh context-fingerprint.sh --help | -h

Builds the version a cut would write now and prints its fingerprint: the
latest version's own when nothing is new, an empty first version's when
there is nothing at all. It is the subject of the human's context-done
gate. Writes nothing.

  --effort FOLDER   the effort's folder, absolute

stdout: FINGERPRINT: <64 lowercase hex digits>, then VERSION: v<N>
Exit: 0 printed; 2 refused, the reason on stderr, led by a token:
  DOCS-NAME, DOCS-SIZE  a file the docs folder may not hold, or too much
USAGE
}

cx_prog='context-fingerprint.sh'
. "$(dirname -- "$0")/lib/context.sh"
. "$(dirname -- "$0")/lib/path-rule.sh"
. "$(dirname -- "$0")/lib/body.sh"
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
