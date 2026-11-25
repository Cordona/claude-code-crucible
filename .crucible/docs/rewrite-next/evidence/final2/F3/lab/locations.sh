#!/bin/sh
# locations.sh LOGS KIND...: per kind, over its counted cells <kind>-1..3 in
# LOGS, the location refusals: the runs refused on a location at all, and
# the location lines (a line naming "is not a location" or "names no file").
set -eu
logs=$1; shift
printf '| Kind | Runs | Runs refused on a location | Location lines | Runs accepted at the first stop |\n|---|---|---|---|---|\n'
for k in "$@"; do
	runs=0 hit=0 lines=0 first=0
	for n in 1 2 3; do
		d="${logs}/${k}-${n}"
		[ -f "${d}/events.json" ] || continue
		runs=$((runs + 1))
		j=$(cat "${d}/live-seq")
		l=$(jq --argjson j "${j}" '[.[] | select(.type == "job.refused" and .body.job == $j) | .body.lines[] | select(test("is not a location|names no file"))] | length' "${d}/events.json")
		r=$(jq --argjson j "${j}" '[.[] | select(.type == "job.refused" and .body.job == $j)] | length' "${d}/events.json")
		lines=$((lines + l)); [ "${l}" -eq 0 ] || hit=$((hit + 1)); [ "${r}" -ne 0 ] || first=$((first + 1))
	done
	printf '| %s | %s | %s | %s | %s |\n' "${k}" "${runs}" "${hit}" "${lines}" "${first}"
done
