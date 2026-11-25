#!/bin/sh
# Sandbox stand-in for the dispatch step that writes job.assigned: a
# PostToolUse hook on Agent. For an Agent call whose description is
# "job <cell>", writes job.assigned {job, agent, name, session} for the
# cell's live job, through the real event writer under its pinned writer
# name. The agent is the tool response's agentId.
set -eu
in=$(cat)
cell=$(printf '%s' "${in}" | jq -r 'select(.tool_name == "Agent") | .tool_input.description // ""' | sed -n 's/^job \([a-z0-9-]*\)$/\1/p')
agent=$(printf '%s' "${in}" | jq -r '.tool_response.agentId // empty')
session=$(printf '%s' "${in}" | jq -r '.session_id // empty')
[ -n "${cell}" ] && [ -n "${agent}" ] && [ -n "${session}" ] || exit 0
c="${REAL_RUN}/cells/${cell}"
effort=$(cat "${c}/effort")
job=$(cat "${c}/live-seq")
K="${CLAUDE_CONFIG_DIR}/skills"
kind=$(sh "${K}/agent-jobs/scripts/internal/job-of.sh" --effort "${effort}" --job "${job}" | jq -r '.kind')
name="${kind}-shell-$(printf '%s' "${agent}" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9' | cut -c1-6)"
body=$(mktemp)
jq -n --argjson job "${job}" --arg agent "${agent}" --arg name "${name}" --arg session "${session}" \
	'{job: $job, agent: $agent, name: $name, session: $session}' >"${body}"
CLAUDE_CODE_SESSION_ID=${session} sh "${K}/crucible-events/scripts/internal/event-write.sh" \
	--effort "${effort}" --type job.assigned --by assign-job.sh --body-file "${body}" >&2 \
	|| echo "assign-job.sh: job.assigned refused for cell ${cell} job ${job}" >&2
rm -f "${body}"
printf '%s\n' "${agent}" >"${c}/agent"
