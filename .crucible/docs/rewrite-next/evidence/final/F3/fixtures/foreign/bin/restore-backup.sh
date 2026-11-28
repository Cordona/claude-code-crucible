#!/usr/bin/env sh
# Restores one backup archive into a folder.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../lib/common.sh
. "${here}/../lib/common.sh"

[ $# -eq 2 ] || { echo "usage: restore-backup.sh ARCHIVE DEST" >&2; exit 2; }
archive=$1
dest=$2
[ -f "${archive}" ] || die "no such archive: ${archive}"

tmp=/tmp/restore.$$
mkdir ${tmp}
tar -xzf "${archive}" -C ${tmp}
cp -R ${tmp}/* ${dest}
rm -rf ${tmp}
echo "restored ${archive} into ${dest}"
