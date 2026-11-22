#!/usr/bin/env sh
# Prints where an effort's context stands: its latest version, and whether
# anything waits for the next one.
# shellcheck source-path=SCRIPTDIR
set -eu

usage() {
	cat <<'USAGE'
usage: sh context-status.sh --effort FOLDER
       sh context-status.sh --help | -h

Prints, one per line:
  VERSION: v<N> | none
  CONTEXT_FILE: <the latest context.cut event, absolute>   with a version
  PENDING: yes | no   yes when the docs folder holds files or entries wait
Reads only.

  --effort FOLDER   the effort's folder, absolute

Exit: 0 printed; 2 refused, the reason on stderr
USAGE
}

cx_prog='context-status.sh'
. "$(dirname -- "$0")/lib/context.sh"
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
