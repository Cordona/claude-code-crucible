#!/usr/bin/env sh
# Prints the draft docs folder of an effort's context, creating it.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh context-docs.sh --effort FOLDER

Prints the folder where notes and copied files for the effort's next context
version go; the next cut (context-cut.sh) moves them into v<N>. Write only
<name>.md or diff-<sha>.patch files there, 1 MiB in total (anything else
blocks the cut); a reference goes through context-add.sh instead.

Options:
  --effort FOLDER  the effort's folder, absolute
Requires:  the effort is open
Writes:    creates the folder if missing
Stdout:    one path, absolute
Exit:
  0  the folder exists; its path printed
  2  refused, nothing changed; the reason is on stderr
USAGE
}

cx_prog='context-docs.sh'
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
cx_require_open
mkdir -p -- "${cx_docs}"
printf '%s\n' "${cx_docs}"
