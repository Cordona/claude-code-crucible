#!/bin/sh
# Spike hook, PostToolUse on Agent (main). Writes job.assigned for a lab job agent.
set -eu
LAB=$(cd "$(dirname "$0")" && pwd); . "$LAB/lib.sh"
in=$(cat); log_hook post-agent "$in"
t=$(printf '%s' "$in" | jq -r '.tool_input.subagent_type // ""')
case "$t" in lab-*) ;; *) exit 0 ;; esac
p=$(printf '%s' "$in" | jq -r '.tool_input.prompt // ""'); path=${p#JOB: }
aid=$(printf '%s' "$in" | jq -r '.tool_response.agentId // empty')
[ -n "$aid" ] || { echo "post-agent: no agentId" >&2; exit 0; }
job=$(job_of_path "$path"); je=$(job_event "$job")
root=$(printf '%s' "$je" | jq -r '.root // "null"'); round=$(printf '%s' "$je" | jq -r '.round // "null"'); kind=$(printf '%s' "$je" | jq -r '.body.kind')
sess=$(printf '%s' "$in" | jq -r '.session_id')
name="$kind-${t#lab-}-$(printf '%s' "$aid" | cut -c1-6)"
EV_LOCK_TRIES=600 "$EV" --session "$sess" --by post-agent.sh --type job.assigned --root "$root" --round "$round" --job "$job" --agent "$aid" \
	--body "$(jq -nc --arg n "$name" --arg u "$(printf '%s' "$in" | jq -r .tool_use_id)" '{name:$n, tool_use_id:$u}')" >/dev/null
exit 0
