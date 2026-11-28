#!/usr/bin/env sh
# Deletes the oldest backups in a folder, keeping the newest few.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../lib/common.sh
. "${here}/../lib/common.sh"

usage() {
	cat <<'USAGE'
usage: prune-backups.sh DIR [KEEP]

Deletes the oldest *.tar.gz files in DIR, keeping the newest KEEP (default 5).
USAGE
}

[ $# -ge 1 ] || { usage >&2; exit 2; }
case $1 in -h | --help) usage; exit 0 ;; *) ;; esac

dir=$1
keep=${2:-5}
is_uint "${keep}" || die "KEEP must be a whole number, got: ${keep}"
[ -d "${dir}" ] || die "not a folder: ${dir}"

count=0
# shellcheck disable=SC2012 # backup names are made by backup.sh and hold no newline
ls -1t -- "${dir}" | while IFS= read -r name; do
	case ${name} in *.tar.gz) ;; *) continue ;; esac
	count=$((count + 1))
	if [ "${count}" -le "${keep}" ]; then continue; fi
	rm -f -- "${dir}/${name}"
done
