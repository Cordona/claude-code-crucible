# Spike: shared helpers, sourced. Needs $EFFORT and $LAB.
LAB=${LAB:-$(cd "$(dirname "$0")" && pwd)}
EV="$LAB/ev.sh"

all_events() { # every event as one JSON array, in the lab's shape, through the real reader
	[ -d "$EFFORT/events" ] || { echo '[]'; return 0; }
	sh "$LAB/real/crucible-events/scripts/internal/events-read.sh" --effort "$(cd "$EFFORT" && pwd)" |
		jq -c -L "$LAB/real/crucible-jobs/lib" 'include "view"; lab_view'
}
event_path() { ls "$EFFORT/events/" 2>/dev/null | grep "^$(printf '%06d' "$1")-" | sed "s|^|$EFFORT/events/|" | head -1; }
job_of_path() { basename "$1" | cut -c1-6 | sed 's/^0*//'; }

# open job of an agent id: the latest job.assigned to it whose job has no end
open_job_of_agent() {
	all_events | jq -r --arg a "$1" '
		(map(select(.type | test("\\.submitted$") or . == "job.ended")) | map(.job)) as $ended
		| map(select(.type == "job.assigned" and .agent == $a and ((.job) as $j | $ended | index($j) | not)))
		| last | .job // empty'
}
job_event() { all_events | jq -c --argjson s "$1" '.[] | select(.seq == $s)'; }
deny_pre() { jq -nc --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'; exit 0; }
log_hook() { mkdir -p "$EFFORT/hook-log"; printf '%s\n' "$2" > "$(mktemp "$EFFORT/hook-log/$1-XXXXXX")"; }
# an agent's job may still be being assigned: its launch hook runs while the
# agent already works, and a hot job's send hook runs while the resumed agent
# works. Wait for it, up to about a minute, before deciding.
wait_job_of_agent() {
	w=0
	while :; do
		j=$(open_job_of_agent "$1"); [ -z "$j" ] || { echo "$j"; return 0; }
		[ "$w" -lt "${WAIT_ASSIGN:-60}" ] || return 0
		sleep 1; w=$((w + 1))
	done
}
