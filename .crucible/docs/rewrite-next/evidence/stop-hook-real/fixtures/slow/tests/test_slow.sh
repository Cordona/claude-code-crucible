#!/usr/bin/env sh
# End-to-end soak test of bin/prune-backups.sh: the nightly job prunes the
# same folder in many rounds; every round must keep the newest backups.
# shellcheck source=tests/lib.sh
. tests/lib.sh

fresh; backups 9
round=1
while [ "${round}" -le 50 ]; do
	sh "${PRUNE}" "${scratch}" 9
	got=$(find "${scratch}" -mindepth 1 | wc -l | tr -d ' ')
	[ "${got}" = 9 ] || fail "round ${round}: ${got} left"
	sleep 1
	round=$((round + 1))
done
