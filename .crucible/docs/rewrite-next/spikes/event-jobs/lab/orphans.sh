#!/bin/sh
# Spike: a background agent does not outlive its session. Every open job
# assigned (or, never assigned, dispatched) in another session than the
# running one is ended as died, by code, once.
# usage: orphans.sh --effort DIR --session ID
set -eu
LAB=$(cd "$(dirname "$0")" && pwd); . "$LAB/cli.sh"
parse_opts "$@"
[ -n "${opt_session:-}" ] || die 1 "--session (the running session) is required"
evq -r --arg s "$SESSION" 'include "ev"; . as $e
	| open_jobs[] | . as $j
	| ((first($e[] | select(.type == "job.assigned" and .job == $j.seq)) // $j) | .session) as $owner
	| select($owner != $s) | .seq' |
	while IFS= read -r job; do
		sh "$LAB/job-end.sh" --effort "$EFFORT" --session "$SESSION" --job "$job" --reason died
	done
