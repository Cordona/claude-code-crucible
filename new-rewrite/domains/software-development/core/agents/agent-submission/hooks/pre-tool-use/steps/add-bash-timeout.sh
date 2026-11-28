#!/usr/bin/env sh
# A step of job-agent-tools.sh: gives a job agent's command the longest time
# limit, so Claude Code doesn't move it to the background itself.
set -eu
# A fault gives no answer: the wrapper runs its other steps.
trap 'exit 0' EXIT

usage() {
	cat <<'USAGE'
usage: sh add-bash-timeout.sh < PRE_TOOL_USE_HOOK_JSON

Run by job-agent-tools.sh for a job agent's Bash call; not for main to call.
Every call gets timeout BASH_MAX_TIMEOUT_MS, replacing any timeout the agent
gave, shorter or longer: Claude Code moves a command past its timeout to the
background, and a job agent must wait for each. A call already at the limit
passes unchanged. The rewrite allows nothing: the call still goes through
the normal permission checks.

Reads:     the hook JSON on stdin: tool_name, tool_input; BASH_MAX_TIMEOUT_MS,
           which the settings env block sets from agent-submission's
           hooks/env.json
Writes:    nothing
Stdout:    nothing; or {hookSpecificOutput: {hookEventName: "PreToolUse",
           updatedInput}}
Exit:
  0  always; with BASH_MAX_TIMEOUT_MS unset the call passes unchanged, a
     note on stderr
USAGE
}

case ${1-} in -h | --help) usage; exit 0 ;; *) ;; esac
command -v jq >/dev/null 2>&1 || exit 0
input=$(cat)
bash=$(printf '%s' "${input}" | jq -r '.tool_name == "Bash"' 2>/dev/null) || exit 0
[ "${bash}" = true ] || exit 0
limit=${BASH_MAX_TIMEOUT_MS:-}
case ${limit} in
	'' | 0* | *[!0-9]*)
		printf 'add-bash-timeout.sh: BASH_MAX_TIMEOUT_MS is not set to a whole number of milliseconds; the call runs unchanged\n' >&2
		exit 0 ;;
	*) ;;
esac
printf '%s' "${input}" | jq -c --argjson limit "${limit}" 'select(.tool_input.timeout != $limit)
	| {hookSpecificOutput: {hookEventName: "PreToolUse", updatedInput: (.tool_input + {timeout: $limit})}}'
