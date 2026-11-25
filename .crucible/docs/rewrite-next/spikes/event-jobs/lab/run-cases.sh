#!/bin/sh
# Spike: run Stage A cases. Each case gets an empty effort; its fixture writes
# events through ev.sh; its command's output is compared with expect.json by jq -S.
# usage: run-cases.sh [CASE-GLOB]   (from anywhere; default every case)
# exit: 0 all pass · 1 a case failed
set -u
here=$(cd "$(dirname "$0")" && pwd)
spike=$(dirname "$here")
cases=$spike/cases
pat=${1:-*}
pass=0 fail=0
# a case replays its own sessions: it runs in none
unset CLAUDE_CODE_SESSION_ID
for c in "$cases"/$pat/; do
	[ -f "$c/fixture.sh" ] || continue
	name=$(basename "$c")
	EFFORT=$(mktemp -d)
	export EFFORT EV="$here/ev.sh" EV_AT=2026-11-24T09:00:00Z
	if ! (cd "$spike" && sh "$c/fixture.sh") >"$EFFORT/fixture.out" 2>&1; then
		echo "FAIL $name: fixture: $(tail -1 "$EFFORT/fixture.out")"; fail=$((fail + 1)); rm -rf "$EFFORT"; continue
	fi
	cmd=$(cat "$c/command")
	(cd "$spike" && eval "$cmd") >"$EFFORT/got.json" 2>"$EFFORT/got.err"
	if jq -S -s . "$EFFORT/got.json" >"$EFFORT/a" 2>/dev/null && jq -S -s . "$c/expect.json" >"$EFFORT/b" && cmp -s "$EFFORT/a" "$EFFORT/b"; then
		echo "pass $name"; pass=$((pass + 1))
	else
		echo "FAIL $name"; fail=$((fail + 1))
		if [ -n "${VERBOSE:-}" ]; then
			echo "  stderr: $(head -3 "$EFFORT/got.err")"
			diff "$EFFORT/b" "$EFFORT/a" | head -20 | sed 's/^/  /'
		fi
	fi
	rm -rf "$EFFORT"
done
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
