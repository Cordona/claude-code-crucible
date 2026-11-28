# shellcheck shell=sh
# Test helpers, sourced by tests/test_*.sh from the project root.
set -eu
# shellcheck disable=SC2034 # read by the tests that source this file
PRUNE="$(pwd)/bin/prune-backups.sh"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/prune-test.XXXXXX")
trap 'rm -rf -- "${scratch}"' EXIT

# fresh: empties the scratch folder.
fresh() { find "${scratch}" -mindepth 1 -delete; }

# backups N [SUFFIX]: N files day-01.SUFFIX .. day-N.SUFFIX in the scratch
# folder, each a day newer than the last (SUFFIX defaults to tar.gz).
backups() {
	i=1
	while [ "${i}" -le "$1" ]; do
		f="${scratch}/day-$(printf '%02d' "${i}").${2:-tar.gz}"
		: >"${f}"
		touch -t "202601$(printf '%02d' "${i}")1200" "${f}"
		i=$((i + 1))
	done
}

# left: the names left in the scratch folder, sorted, on one line.
left() { find "${scratch}" -mindepth 1 -exec basename {} \; | sort | tr '\n' ' ' | sed 's/ $//'; }

fail() { printf 'not ok: %s\n' "$1" >&2; exit 1; }
