#!/bin/sh
# Spike hook, PreToolUse on SendMessage (main). A message to a lab job agent
# must be exactly "JOB: <path>" of an unassigned hot job for that agent.
set -eu
LAB=$(cd "$(dirname "$0")" && pwd); . "$LAB/lib.sh"
in=$(cat); log_hook pre-send "$in"
to=$(printf '%s' "$in" | jq -r '.tool_input.to // ""')
all_events | jq -e --arg a "$to" 'any(.[]; .type == "job.assigned" and .agent == $a)' >/dev/null || exit 0
m=$(printf '%s' "$in" | jq -r '.tool_input.message // ""')
case "$m" in "JOB: "*) path=${m#JOB: } ;; *) deny_pre "every message to a job agent is one JOB: <path> line" ;; esac
[ -f "$path" ] || deny_pre "JOB names no job.dispatched event"
job=$(job_of_path "$path"); je=$(job_event "$job")
printf '%s' "$je" | jq -e '.type == "job.dispatched"' >/dev/null 2>&1 || deny_pre "JOB names no job.dispatched event"
printf '%s' "$je" | jq -e --arg a "$to" '.body.delivery == "hot" and .body.hot_agent == $a' >/dev/null || deny_pre "job $job is not a hot job for $to"
all_events | jq -e --argjson j "$job" 'any(.[]; .type == "job.assigned" and .job == $j)' >/dev/null && deny_pre "job $job is already assigned"
exit 0
