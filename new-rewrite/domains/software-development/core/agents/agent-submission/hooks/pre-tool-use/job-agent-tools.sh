#!/usr/bin/env sh
# Claude Code PreToolUse hook on Bash, Write and Edit: runs the steps for a
# job agent's tool call and gives their one combined answer.
set -eu
work=''
# A fault gives no answer, so Claude Code's own permissions apply.
trap 'rm -rf -- ${work:+"${work}"}; exit 0' EXIT

usage() {
	cat <<'USAGE'
usage: sh job-agent-tools.sh < PRE_TOOL_USE_HOOK_JSON

Run by Claude Code as a PreToolUse hook on Bash, Write and Edit; not for
main to call. For a job agent's call (its agent_type has a submissions
folder), runs its tool's steps in order, each given tool_input as the one
before left it:
  Bash         deny-background-bash.sh, add-bash-timeout.sh
  Write, Edit  write-scope.sh
The first deny wins and stops the rest; else allow if a step allowed; else
no answer. The last updatedInput goes with an allow or alone; messages are
joined. A step that fails or prints no JSON object gives no answer.

Reads:     stdin: agent_type, tool_name, tool_input
Writes:    nothing
Stdout:    nothing; or {hookSpecificOutput: {hookEventName: "PreToolUse",
           permissionDecision?, permissionDecisionReason?, updatedInput?},
           systemMessage?}
Exit:
  0  always
USAGE
}

case ${1-} in -h | --help) usage; exit 0 ;; *) ;; esac
command -v jq >/dev/null 2>&1 || exit 0

input=$(cat)
fields=$(printf '%s' "${input}" | jq -r '.tool_name // "", .agent_type // ""' 2>/dev/null) || exit 0
tool=$(printf '%s\n' "${fields}" | sed -n 1p)
agent_type=$(printf '%s\n' "${fields}" | sed -n 2p)
case ${tool} in
	Bash) steps='deny-background-bash.sh add-bash-timeout.sh' ;;
	Write | Edit) steps='write-scope.sh' ;;
	*) exit 0 ;;
esac
case ${agent_type} in '' | *[!a-z0-9-]*) exit 0 ;; *) ;; esac
self=$0
case ${self} in /*) ;; *) self="$(pwd)/${self}" ;; esac
. "${self%/*/*/*/*}/jobs-agent-init/scripts/lib/agent-type.sh"
# shellcheck disable=SC2310 # at_base is a test, called for its status
at_base "${agent_type}" "${self%/*/*/*/*}" >/dev/null || exit 0

work=$(mktemp -d "${TMPDIR:-/tmp}/job-agent-tools.XXXXXX")
printf '%s' "${input}" >"${work}/input"
printf '{}\n' >"${work}/answer"
for step in ${steps}; do
	: >"${work}/said"
	sh "$(dirname -- "$0")/steps/${step}" <"${work}/input" >"${work}/said" || : >"${work}/said"
	[ -s "${work}/said" ] || continue
	jq -e 'type == "object"' "${work}/said" >/dev/null 2>&1 || continue
	jq -s '.[0] as $a | (.[1].hookSpecificOutput // {}) as $h | .[1].systemMessage as $m
		| $a
		| (if $h.permissionDecision == "deny" then .deny = ($h.permissionDecisionReason // "denied") else . end)
		| (if $h.permissionDecision == "allow" then .allow = ($h.permissionDecisionReason // "allowed") else . end)
		| (if ($h.updatedInput | type) == "object" then .updated = $h.updatedInput else . end)
		| (if ($m | type) == "string" then .messages += [$m] else . end)' \
		"${work}/answer" "${work}/said" >"${work}/next" || continue
	mv -f -- "${work}/next" "${work}/answer"
	! jq -e 'has("deny")' "${work}/answer" >/dev/null || break
	if jq -e 'has("updated")' "${work}/answer" >/dev/null; then
		jq --slurpfile a "${work}/answer" '.tool_input = $a[0].updated' "${work}/input" >"${work}/next" \
			&& mv -f -- "${work}/next" "${work}/input"
	fi
done

jq -c 'def message: if has("messages") then {systemMessage: (.messages | join("; "))} else {} end;
	if has("deny") then {hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny",
		permissionDecisionReason: .deny}} + message
	elif has("allow") then {hookSpecificOutput: ({hookEventName: "PreToolUse", permissionDecision: "allow",
		permissionDecisionReason: .allow} + (if has("updated") then {updatedInput: .updated} else {} end))} + message
	elif has("updated") then {hookSpecificOutput: {hookEventName: "PreToolUse", updatedInput: .updated}} + message
	elif has("messages") then message
	else empty end' "${work}/answer"
