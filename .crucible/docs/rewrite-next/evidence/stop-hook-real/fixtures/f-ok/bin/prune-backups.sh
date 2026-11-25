#!/usr/bin/env sh
# Deletes the oldest backups in a folder, keeping the newest few.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../lib/common.sh
. "${here}/../lib/common.sh"

usage() {
	cat <<'USAGE'
usage: prune-backups.sh [--dry-run] [--pattern GLOB] DIR [KEEP]

Deletes the oldest files matching GLOB (default *.tar.gz) in DIR, keeping the
newest KEEP (default 5). With --dry-run, prints each file it would delete and
deletes nothing.
USAGE
}

dry_run=0
pattern='*.tar.gz'
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--dry-run) dry_run=1; shift ;;
		--pattern)
			[ $# -ge 2 ] || { usage >&2; exit 2; }
			pattern=$2; shift 2 ;;
		--) shift; break ;;
		-*) usage >&2; exit 2 ;;
		*) break ;;
	esac
done
[ $# -ge 1 ] || { usage >&2; exit 2; }

dir=$1
keep=${2:-5}
is_uint "${keep}" || die "KEEP must be a whole number, got: ${keep}"
[ -d "${dir}" ] || die "not a folder: ${dir}"

count=0
# shellcheck disable=SC2012 # backup names are made by backup.sh and hold no newline
ls -1t -- "${dir}" | while IFS= read -r name; do
	# shellcheck disable=SC2254 # the pattern is a glob on purpose
	case ${name} in ${pattern}) ;; *) continue ;; esac
	count=$((count + 1))
	if [ "${count}" -le "${keep}" ]; then continue; fi
	if [ "${dry_run}" = 1 ]; then
		printf 'would delete %s\n' "${dir}/${name}"
	else
		rm -f -- "${dir}/${name}"
	fi
done
