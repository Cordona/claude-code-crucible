#!/usr/bin/env sh
# A step of job-agent-tools.sh: keeps a job agent's commands in the
# foreground, so its stop comes only when its work is done.
set -eu
# A fault gives no answer: the wrapper runs its other steps.
trap 'exit 0' EXIT

usage() {
	cat <<'USAGE'
usage: sh deny-background-bash.sh < PRE_TOOL_USE_HOOK_JSON

Run by job-agent-tools.sh for a job agent's Bash call; not for main to call.
Denies a call with run_in_background: true, the reason telling the agent
to run the command in the foreground: an agent that ends its turn waiting
on a background command would have that stop taken for its hand-in.

Reads:     the hook JSON on stdin: tool_name, tool_input.run_in_background
Writes:    nothing
Stdout:    nothing; or {hookSpecificOutput: {hookEventName: "PreToolUse",
           permissionDecision: "deny", permissionDecisionReason}}
Exit:
  0  always
USAGE
}

case ${1-} in -h | --help) usage; exit 0 ;; *) ;; esac
command -v jq >/dev/null 2>&1 || exit 0
input=$(cat)
background=$(printf '%s' "${input}" | jq -r '.tool_name == "Bash" and .tool_input.run_in_background == true' 2>/dev/null) || exit 0
[ "${background}" = true ] || exit 0
jq -cn '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny",
	permissionDecisionReason: "Run this command in the foreground, without run_in_background: an agent working on a job waits for each command it starts."}}'
