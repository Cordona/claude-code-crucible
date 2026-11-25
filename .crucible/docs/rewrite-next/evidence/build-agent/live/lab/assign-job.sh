#!/bin/sh
# Sandbox-only PostToolUse hook on Agent, standing in for the dispatch step
# that will write job.assigned: for a code-builder launched with a prompt
# starting "JOB: <seq>", writes job.assigned {job, agent, name, session} for the
# agentId the tool response returns, through the real event writer under its
# pinned writer name, named <job kind>-php-<agent id>. Logs its input to $LIVE/logs/.
set -eu
in=$(cat)
mkdir -p "${LIVE}/logs"
printf '%s\n' "${in}" >>"${LIVE}/logs/post-agent.jsonl"
[ "$(printf '%s' "${in}" | jq -r '.tool_input.subagent_type // ""')" = code-builder ] || exit 0
job=$(printf '%s' "${in}" | jq -r '.tool_input.prompt // "" | capture("^JOB: (?<j>[0-9]+)").j // empty')
agent=$(printf '%s' "${in}" | jq -r '.tool_response.agentId // empty')
session=$(printf '%s' "${in}" | jq -r '.session_id // empty')
[ -n "${job}" ] && [ -n "${agent}" ] && [ -n "${session}" ] || { echo "assign-job.sh: no JOB line, agentId or session_id" >&2; exit 0; }
kind=$(sh "${CLAUDE_CONFIG_DIR}/skills/agent-jobs/scripts/internal/job-of.sh" --effort "${LIVE_EFFORT}" --job "${job}" | jq -r '.kind')
name="${kind}-php-$(printf '%s' "${agent}" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9' | cut -c1-6)"
body=$(mktemp)
jq -n --argjson job "${job}" --arg agent "${agent}" --arg name "${name}" --arg session "${session}" \
	'{job: $job, agent: $agent, name: $name, session: $session}' >"${body}"
CLAUDE_CODE_SESSION_ID=${session} \
	sh "${CLAUDE_CONFIG_DIR}/skills/crucible-events/scripts/internal/event-write.sh" \
	--effort "${LIVE_EFFORT}" --type job.assigned --by assign-job.sh --body-file "${body}" >>"${LIVE}/logs/post-agent.out" 2>&1 \
	|| echo "assign-job.sh: job.assigned refused, see logs/post-agent.out" >&2
rm -f "${body}"
