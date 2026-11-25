#!/usr/bin/env sh
# End-to-end tests of bin/prune-backups.sh.
# shellcheck source=tests/lib.sh
. tests/lib.sh

# keeps the newest five by default
fresh; backups 7
sh "${PRUNE}" "${scratch}"
got=$(left)
[ "${got}" = "day-03.tar.gz day-04.tar.gz day-05.tar.gz day-06.tar.gz day-07.tar.gz" ] || fail "default keep: ${got}"

# keeps the newest KEEP
fresh; backups 7
sh "${PRUNE}" "${scratch}" 2
got=$(left)
[ "${got}" = "day-06.tar.gz day-07.tar.gz" ] || fail "keep 2: ${got}"

# leaves files that are not backups
fresh; backups 3; backups 3 txt
sh "${PRUNE}" "${scratch}" 1
got=$(left)
[ "${got}" = "day-01.txt day-02.txt day-03.tar.gz day-03.txt" ] || fail "non-backups: ${got}"

# refuses a KEEP that is not a whole number
if sh "${PRUNE}" "${scratch}" two 2>/dev/null; then fail "KEEP two accepted"; fi
