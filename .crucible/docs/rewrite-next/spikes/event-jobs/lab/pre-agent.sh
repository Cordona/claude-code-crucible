#!/bin/sh
# Spike hook, PreToolUse on Agent (main). A lab job agent must be started in
# the background with the whole prompt "JOB: <path of an unassigned job.dispatched>"
# whose agent_type matches. Writes nothing. Other agents pass.
set -eu
LAB=$(cd "$(dirname "$0")" && pwd); . "$LAB/lib.sh"
in=$(cat); log_hook pre-agent "$in"
t=$(printf '%s' "$in" | jq -r '.tool_input.subagent_type // ""')
case "$t" in lab-*) ;; *) exit 0 ;; esac
p=$(printf '%s' "$in" | jq -r '.tool_input.prompt // ""')
# where the tool has the field, it must be true; where it has none (an
# interactive session, whose agents always run in the background) it passes
bg=$(printf '%s' "$in" | jq -r 'if .tool_input | has("run_in_background") then .tool_input.run_in_background else "absent" end')
[ "$bg" = true ] || [ "$bg" = absent ] || deny_pre "a job agent runs in the background only"
case "$p" in "JOB: "*) path=${p#JOB: } ;; *) deny_pre "a job agent's whole prompt is JOB: <path>" ;; esac
case "$path" in *"
"*) deny_pre "a job agent's whole prompt is one JOB: line" ;; esac
[ -f "$path" ] || deny_pre "JOB names no job.dispatched event"
job=$(job_of_path "$path"); je=$(job_event "$job")
printf '%s' "$je" | jq -e '.type == "job.dispatched"' >/dev/null 2>&1 || deny_pre "JOB names no job.dispatched event"
printf '%s' "$je" | jq -e --arg t "$t" '.body.agent_type == $t and .body.delivery == "cold"' >/dev/null || deny_pre "job $job is not a cold job for $t"
all_events | jq -e --argjson j "$job" 'any(.[]; .type == "job.assigned" and .job == $j)' >/dev/null && deny_pre "job $job is already assigned"
exit 0
