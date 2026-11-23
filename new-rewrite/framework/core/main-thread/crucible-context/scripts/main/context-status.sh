#!/usr/bin/env sh
# Prints where an effort's context stands: its latest version, and whether
# anything waits for the next one.
# shellcheck source-path=SCRIPTDIR
set -eu

usage() {
	cat <<'USAGE'
usage: sh context-status.sh --effort FOLDER

Shows an effort's latest cut context version and whether the draft holds
anything for the next cut. Use it to decide whether to cut, or to get the
CONTEXT_FILE that context-verify.sh takes. Works on any effort, open or not.

Options:
  --effort FOLDER  the effort's folder, absolute
Writes:  nothing
Stdout:
  VERSION: v<N> | none
  CONTEXT_FILE: <latest context.cut event, absolute>   only with a version
  PENDING: yes | no
Exit:
  0  printed
  2  refused, nothing changed; the reason is on stderr
USAGE
}

cx_prog='context-status.sh'
. "$(dirname -- "$0")/../lib/context.sh"
effort=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--effort) [ $# -ge 2 ] || cx_refuse '--effort needs a value'; effort=$2; shift 2 ;;
		*) cx_refuse "unknown argument $1; try --help" ;;
	esac
done
cx_set "${effort}"
latest=$(cx_latest)
if [ -n "${latest}" ]; then
	printf 'VERSION: v%s\nCONTEXT_FILE: %s\n' "$(jq -r '.body.version' "${latest}")" "${latest}"
else
	echo 'VERSION: none'
fi
pending=no
if [ -d "${cx_docs}" ] && [ -n "$(ls -A -- "${cx_docs}")" ]; then pending=yes; fi
if [ -f "${cx_entries}" ] && jq -e '([.paths[]?, .links[]?, .retire[]?] | length) > 0' "${cx_entries}" >/dev/null; then pending=yes; fi
printf 'PENDING: %s\n' "${pending}"
