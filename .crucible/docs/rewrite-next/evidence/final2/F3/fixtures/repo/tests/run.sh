#!/usr/bin/env sh
# Runs every tests/test_*.sh from the project root; exits 1 when any fails.
set -eu
cd "$(dirname "$0")/.."
fails=0
for t in tests/test_*.sh; do
	if sh "${t}"; then
		echo "ok   ${t}"
	else
		echo "FAIL ${t}"
		fails=$((fails + 1))
	fi
done
[ "${fails}" -eq 0 ]
