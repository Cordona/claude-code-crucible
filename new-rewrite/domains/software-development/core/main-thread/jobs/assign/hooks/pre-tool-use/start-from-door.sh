#!/usr/bin/env sh
# PreToolUse, Agent: a job agent starts only from the door's call, and one
# per message.
set -eu
trap 'exit 0' EXIT

usage() {
	cat <<'USAGE'
usage: sh start-from-door.sh < PRE_TOOL_USE_HOOK_JSON

Run by Claude Code (PreToolUse, Agent); not for main to call.
An Agent call whose subagent_type is a job agent's must be the call
job-assign.sh printed for its job, and only one job agent starts per
message. Allowed, it claims the door's note, which the start matches.
Other agents pass with no decision.

Reads:     stdin: session_id, tool_name, tool_input; CLAUDE_CONFIG_DIR
Writes:    the claimed note, in this session's cache
Stdout:    nothing; or a PreToolUse deny with its reason
Exit:
  0  always
USAGE
}

case ${1-} in -h | --help) usage; exit 0 ;; *) ;; esac
command -v jq >/dev/null 2>&1 || exit 0
self=$0
case ${self} in /*) ;; *) self="$(pwd)/${self}" ;; esac
skills=${self%/*/*/*/*}
. "${self%/*/*/*}/scripts/lib/notes.sh"
. "${skills}/jobs-agent-init/scripts/lib/agent-type.sh"

input=$(cat)
[ "$(printf '%s' "${input}" | jq -r '.tool_name // empty' 2>/dev/null)" = Agent ] || exit 0
type=$(printf '%s' "${input}" | jq -r '.tool_input.subagent_type // empty')
# shellcheck disable=SC2310 # at_base is a test, called for its status
at_base "${type}" "${skills}" >/dev/null || exit 0
deny() {
	jq -cn --arg r "$1" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
	exit 0
}
# shellcheck disable=SC2310 # nt_set_dir fails for an unsafe id
nt_set_dir "$(printf '%s' "${input}" | jq -r '.session_id // empty')" || deny 'this session has no id the door can match: start the job from job-assign.sh in a Claude Code session'

job=$(printf '%s' "${input}" | jq -r '.tool_input.description // empty')
job=${job#job-}
note="${nt_dir}/cold-${job}.json"
case ${job} in '' | *[!0-9]*) deny "a job agent starts only from the call job-assign.sh printed: run it for the job and send what it prints" ;; *) ;; esac
[ -f "${note}" ] || deny "a job agent starts only from the call job-assign.sh printed: run it for job ${job} and send what it prints"
same=$(jq -r --argjson i "$(printf '%s' "${input}" | jq -c '.tool_input')" \
	'.subagent_type == $i.subagent_type and .prompt == $i.prompt and .isolation == ($i.isolation // "")' "${note}")
[ "${same}" = true ] || deny "this is not the call job-assign.sh printed for job ${job}: send it as printed"
# A claim left by a start that never came is stale after ten minutes.
find "${nt_dir}" -name 'claimed-*.json' -mmin +10 -exec rm -f {} + 2>/dev/null || :
# A claim of this same job is a start that never came, as when Claude Code
# refused the call after this check: the retry takes it over.
for claimed in "${nt_dir}"/claimed-*.json; do
	[ -f "${claimed}" ] || continue
	[ "${claimed}" != "${nt_dir}/claimed-${job}.json" ] || continue
	deny "one job agent per message: send one per message, the next as soon as this one returns, in the same turn (job ${job} not started)"
done
mv -f -- "${note}" "${nt_dir}/claimed-${job}.json" || deny "job ${job}'s note could not be claimed: run job-assign.sh again"
