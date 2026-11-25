#!/bin/sh
# Spike hook, PostToolUse on SendMessage (main). After a hot job's send
# succeeded, writes job.assigned to the same agent.
set -eu
LAB=$(cd "$(dirname "$0")" && pwd); . "$LAB/lib.sh"
in=$(cat); log_hook post-send "$in"
m=$(printf '%s' "$in" | jq -r '.tool_input.message // ""')
case "$m" in "JOB: "*) path=${m#JOB: } ;; *) exit 0 ;; esac
[ -f "$path" ] || exit 0
printf '%s' "$in" | jq -e '.tool_response.success == true' >/dev/null || exit 0
job=$(job_of_path "$path"); je=$(job_event "$job")
aid=$(printf '%s' "$je" | jq -r '.body.hot_agent')
all_events | jq -e --argjson j "$job" 'any(.[]; .type == "job.assigned" and .job == $j)' >/dev/null && exit 0
root=$(printf '%s' "$je" | jq -r '.root // "null"'); round=$(printf '%s' "$je" | jq -r '.round // "null"')
kind=$(printf '%s' "$je" | jq -r '.body.kind'); t=$(printf '%s' "$je" | jq -r '.body.agent_type')
sess=$(printf '%s' "$in" | jq -r '.session_id')
EV_LOCK_TRIES=600 "$EV" --session "$sess" --by post-send.sh --type job.assigned --root "$root" --round "$round" --job "$job" --agent "$aid" \
	--body "$(jq -nc --arg n "$kind-${t#lab-}-$(printf '%s' "$aid" | cut -c1-6)" --arg u "$(printf '%s' "$in" | jq -r .tool_use_id)" '{name:$n, tool_use_id:$u}')" >/dev/null
exit 0
