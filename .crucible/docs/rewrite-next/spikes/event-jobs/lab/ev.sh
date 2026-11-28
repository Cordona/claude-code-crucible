#!/bin/sh
# Spike: the lab's event writer, an adapter over the real event-write.sh.
# The chain links travel in the body; the session goes in through the
# environment the real writer reads; the type's rule decides under its lock.
# usage: ev.sh [--effort DIR] --session ID --type TYPE [--root SEQ|self]
#              [--round SEQ] [--job SEQ] [--agent ID] [--body JSON] [--by NAME]
# The effort defaults to $EFFORT. Prints the new seq.
# exit: 0 written · 1 usage · 2 refused by the type's rule (reason on stderr) · 6 lock held
set -eu
LAB=$(cd "$(dirname "$0")" && pwd)
WRITER=$LAB/real/crucible-events/scripts/internal/event-write.sh

effort=${EFFORT:-} session='' type='' root=null round=null job=null agent=null body='{}' by=${EV_BY:-ev.sh}
while [ $# -gt 0 ]; do
	case "$1" in
	--effort) effort=$2; shift 2 ;;
	--session) session=$2; shift 2 ;;
	--type) type=$2; shift 2 ;;
	--root) root=$2; shift 2 ;;
	--round) round=$2; shift 2 ;;
	--job) job=$2; shift 2 ;;
	--agent) agent=$2; shift 2 ;;
	--body) body=$2; shift 2 ;;
	--by) by=$2; shift 2 ;;
	*) echo "ev.sh: unknown option $1" >&2; exit 1 ;;
	esac
done
[ -n "$effort" ] && [ -n "$session" ] && [ -n "$type" ] || { echo "ev.sh: --effort, --session and --type are required" >&2; exit 1; }
effort=$(cd "$effort" && pwd) || { echo "ev.sh: no effort folder $effort" >&2; exit 1; }

link() { # a link as JSON: null or a seq
	case "$1" in null) echo null ;; '' | *[!0-9]*) echo "ev.sh: --$2 is not a seq" >&2; exit 1 ;; *) echo "$1" ;; esac
}
if [ "$root" = self ]; then r='"self"'; else r=$(link "$root" root); fi
d=$(link "$round" round); j=$(link "$job" job)

file=$(mktemp "${TMPDIR:-/tmp}/ev-body.XXXXXX")
trap 'rm -f "$file"' EXIT
printf '%s' "$body" | jq -c --argjson root "$r" --argjson round "$d" --argjson job "$j" --arg agent "$agent" \
	'if type == "object" then . + {root: $root, round: $round, job: $job, agent: (if $agent == "null" then null else $agent end)}
	 else error("not an object") end' > "$file" 2>/dev/null || { echo "ev.sh: --body is not a JSON object" >&2; exit 1; }
real_type=$(jq -nr -L "$LAB/real/crucible-jobs/lib" --arg t "$type" 'include "view"; $t | real_type')

# the real writer waits about five seconds for its lock; a caller that may
# wait longer says so in tries of a tenth of a second, as before
rounds=$(( (${EV_LOCK_TRIES:-50} + 49) / 50 ))
while :; do
	status=0
	path=$(CLAUDE_CODE_SESSION_ID=$session sh "$WRITER" --effort "$effort" --type "$real_type" --by "$by" --body-file "$file") || status=$?
	[ "$status" -eq 6 ] && [ "$rounds" -gt 1 ] || break
	rounds=$((rounds - 1))
done
[ "$status" -eq 0 ] || exit "$status"
basename "$path" | cut -c1-6 | sed 's/^0*//'
