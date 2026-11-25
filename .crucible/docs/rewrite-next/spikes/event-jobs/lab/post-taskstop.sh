#!/bin/sh
# Spike hook, PostToolUse on TaskStop (main). A stopped agent runs no stop
# hook, so its open job is ended here as cancelled; task_id is the agent id.
set -eu
LAB=$(cd "$(dirname "$0")" && pwd); . "$LAB/lib.sh"
in=$(cat); log_hook post-taskstop "$in"
aid=$(printf '%s' "$in" | jq -r '.tool_input.task_id // ""')
[ -n "$aid" ] || exit 0
job=$(open_job_of_agent "$aid")
[ -n "$job" ] || exit 0
sess=$(printf '%s' "$in" | jq -r '.session_id')
sh "$LAB/job-end.sh" --effort "$EFFORT" --session "$sess" --job "$job" --reason cancelled >/dev/null
exit 0
