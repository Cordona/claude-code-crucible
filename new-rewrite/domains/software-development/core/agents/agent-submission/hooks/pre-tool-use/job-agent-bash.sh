#!/usr/bin/env sh
# Claude Code PreToolUse hook on Bash: keeps a job agent's commands in the
# foreground, so its stop comes only when its work is done.
set -eu
# A hook fault lets the call run unchanged: it sits on every Bash call of
# every sub-agent, and a bug here must never block one.
trap 'exit 0' EXIT

usage() {
	cat <<'USAGE'
usage: sh job-agent-bash.sh < PRE_TOOL_USE_HOOK_JSON

Run by Claude Code as a PreToolUse hook on Bash; not for main to call.
For a Bash call of a job agent (a sub-agent whose agent_type has a
submissions folder): a command run in the background would let the agent
end its turn waiting, and that stop would be taken for its hand-in, so
  - run_in_background: true is denied, the reason telling it to run the
    command in the foreground;
  - a call with no timeout gets timeout BASH_MAX_TIMEOUT_MS, so Claude Code
    doesn't move it to the background itself after its default limit. The
    call then goes through the normal permission checks.
Any other call, main's own, and a call of an agent of another type pass
unchanged.

Reads:     the hook JSON on stdin: agent_type, tool_name, tool_input;
           BASH_MAX_TIMEOUT_MS, which the settings env block sets from
           agent-submission's hooks/env.json
Writes:    nothing
Stdout:    nothing; or {hookSpecificOutput: {hookEventName: "PreToolUse",
           permissionDecision: "deny", permissionDecisionReason}}; or
           {hookSpecificOutput: {hookEventName: "PreToolUse", updatedInput}}
Exit:
  0  always; with BASH_MAX_TIMEOUT_MS unset, or on a fault, the call runs
     unchanged, a note on stderr
USAGE
}

case ${1-} in -h | --help) usage; exit 0 ;; *) ;; esac
prog='job-agent-bash.sh'
note() { printf '%s: %s; the call runs unchanged\n' "${prog}" "$1" >&2; exit 0; }
command -v jq >/dev/null 2>&1 || note 'jq not found'

input=$(cat)
fields=$(printf '%s' "${input}" | jq -r '.tool_name // "", .agent_type // "",
	(.tool_input.run_in_background == true), (.tool_input | has("timeout"))' 2>/dev/null) \
	|| note 'the hook input is not JSON'
tool=$(printf '%s\n' "${fields}" | sed -n 1p)
agent_type=$(printf '%s\n' "${fields}" | sed -n 2p)
background=$(printf '%s\n' "${fields}" | sed -n 3p)
has_timeout=$(printf '%s\n' "${fields}" | sed -n 4p)
[ "${tool}" = Bash ] || exit 0
case ${agent_type} in '' | *[!a-z0-9-]*) exit 0 ;; *) ;; esac
self=$0
case ${self} in /*) ;; *) self="$(pwd)/${self}" ;; esac
[ -d "${self%/*/*/*/*}/${agent_type}/submissions" ] || exit 0

if [ "${background}" = true ]; then
	jq -cn '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny",
		permissionDecisionReason: "Run this command in the foreground, without run_in_background: an agent working on a job waits for each command it starts."}}'
	exit 0
fi
[ "${has_timeout}" = false ] || exit 0
limit=${BASH_MAX_TIMEOUT_MS:-}
case ${limit} in '' | 0* | *[!0-9]*) note 'BASH_MAX_TIMEOUT_MS is not set to a whole number of milliseconds' ;; *) ;; esac
printf '%s' "${input}" | jq -c --argjson limit "${limit}" \
	'{hookSpecificOutput: {hookEventName: "PreToolUse", updatedInput: (.tool_input + {timeout: $limit})}}'
