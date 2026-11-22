#!/usr/bin/env sh
# Prints the draft docs folder of an effort's context, creating it.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh context-docs.sh --effort FOLDER
       sh context-docs.sh --help | -h

Prints the draft's docs folder, <effort>/context/draft/docs, creating it:
where the files of the next version are written.

  --effort FOLDER   the effort's folder, absolute; the effort must be open

stdout: the docs folder, absolute
Exit: 0 printed; 2 refused, the reason on stderr
USAGE
}

cx_prog='context-docs.sh'
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
cx_require_open
mkdir -p -- "${cx_docs}"
printf '%s\n' "${cx_docs}"
