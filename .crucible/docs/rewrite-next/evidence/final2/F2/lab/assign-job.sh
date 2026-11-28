#!/bin/sh
# Sandbox stand-in for the dispatch step that writes job.assigned, run as a
# PostToolUse hook on Agent and a PreToolUse hook on SendMessage. For a
# prompt or message starting "JOB: <seq>. CELL: <cell>.", writes
# job.assigned {job, agent, name, session} in that cell's effort, through
# the real event writer under its pinned writer name. The agent is the
# tool response's agentId (Agent) or the message's recipient (SendMessage).
set -eu
in=$(cat)
tool=$(printf '%s' "${in}" | jq -r '.tool_name // ""')
case ${tool} in
	Agent) text=$(printf '%s' "${in}" | jq -r '.tool_input.prompt // ""')
		agent=$(printf '%s' "${in}" | jq -r '.tool_response.agentId // empty') ;;
	SendMessage) text=$(printf '%s' "${in}" | jq -r '.tool_input.message // .tool_input.content // ""')
		agent=$(printf '%s' "${in}" | jq -r '.tool_input.to // .tool_input.recipient // empty') ;;
	*) exit 0 ;;
esac
job=$(printf '%s' "${text}" | sed -n 's/^JOB: \([0-9][0-9]*\)\. CELL: \([A-Za-z0-9-]*\)\..*/\1/p' | head -n 1)
cell=$(printf '%s' "${text}" | sed -n 's/^JOB: \([0-9][0-9]*\)\. CELL: \([A-Za-z0-9-]*\)\..*/\2/p' | head -n 1)
session=$(printf '%s' "${in}" | jq -r '.session_id // empty')
[ -n "${job}" ] && [ -n "${agent}" ] && [ -n "${session}" ] || exit 0
effort=$(cat "${MATRIX_RUN}/cells/${cell}/effort")
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
