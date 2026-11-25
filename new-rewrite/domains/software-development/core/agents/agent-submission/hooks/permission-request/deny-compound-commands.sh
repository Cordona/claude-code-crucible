#!/usr/bin/env sh
# Claude Code PermissionRequest hook on Bash: answers a job agent's ask on a
# compound command with a reason it can act on.
set -eu
# A fault gives no answer: the ask goes on to the human or the allow-list.
trap 'exit 0' EXIT

usage() {
	cat <<'USAGE'
usage: sh deny-compound-commands.sh < PERMISSION_REQUEST_HOOK_JSON

Run by Claude Code as the PermissionRequest hook on Bash; not for main to
call. When an agent with an open job is about to be asked about a compound
command (a chain with &&, || or ;, a line break, a variable assignment, or
a $(...) or backtick substitution; quoted text and pipes don't count), it
denies, telling the agent to run plain single commands, one per call. Every
other ask, main's, a helper agent's, an idle agent's or a plain command's,
gets no answer and goes on as usual. Probed only with main in default mode.

Reads:     stdin: tool_name, agent_id, tool_input.command; the agent's open
           job, through agent-jobs' agent-job.sh
Writes:    nothing
Stdout:    nothing; or {"hookSpecificOutput": {"hookEventName":
           "PermissionRequest", "decision": {"behavior": "deny", "message"}}}
Exit:
  0  always
USAGE
}

case ${1-} in -h | --help) usage; exit 0 ;; *) ;; esac
command -v jq >/dev/null 2>&1 || exit 0

input=$(cat)
# One line each: the tool, the agent, then the command with its quoted text
# taken out, which a shell never splits on.
fields=$(printf '%s' "${input}" | jq -r '.tool_name // "", (.agent_id // "" | tostring),
	(.tool_input.command // "" | gsub("'"'"'[^'"'"']*'"'"'"; "Q") | gsub("\"(\\\\.|[^\"\\\\])*\""; "Q") | @json)' 2>/dev/null) || exit 0
tool=$(printf '%s\n' "${fields}" | sed -n 1p)
agent=$(printf '%s\n' "${fields}" | sed -n 2p)
command=$(printf '%s\n' "${fields}" | sed -n 3p | jq -r '.' 2>/dev/null) || exit 0
[ "${tool}" = Bash ] || exit 0
case ${agent} in '' | *[!A-Za-z0-9._-]*) exit 0 ;; *) ;; esac

# Compound: a chain, a line break, a substitution, or a command (each side
# of a pipe) that starts with NAME=.
compound=$(printf '%s' "${command}" | jq -Rs 'test("&&|\\|\\||;|\\n|\\$\\(|`")
	or any(splits("\\|") | sub("^\\s+"; ""); test("^[A-Za-z_][A-Za-z0-9_]*="))') || exit 0
[ "${compound}" = true ] || exit 0

self=$0
case ${self} in /*) ;; *) self="$(pwd)/${self}" ;; esac
agent_job="${self%/*/*/*/*}/agent-jobs/scripts/internal/agent-job.sh"
[ -f "${agent_job}" ] || exit 0
sh "${agent_job}" --agent "${agent}" >/dev/null 2>&1 || exit 0

jq -cn '{hookSpecificOutput: {hookEventName: "PermissionRequest", decision: {behavior: "deny",
	message: "Run it as plain single commands, one per call. Your other commands still run."}}}'
