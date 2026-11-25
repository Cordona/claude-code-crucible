#!/usr/bin/env sh
# Claude Code PreToolUse hook on Read, Grep, Glob and Bash: runs the
# framework's guards on a tool call and gives the first deny.
set -eu
work=''
# A fault gives no answer: the call runs, as each guard's own fault does.
trap 'rm -rf -- ${work:+"${work}"}; exit 0' EXIT

usage() {
	cat <<'USAGE'
usage: sh guard-framework.sh < PRE_TOOL_USE_HOOK_JSON

Run by Claude Code as a PreToolUse hook on Read, Grep, Glob and Bash; not for
main to call.
Runs the steps in steps/ for the call's tool, in order, each given the
hook's JSON, and prints the first deny; no later step runs. Each step checks
its own tool:
  Bash              deny-direct-event-write.sh, deny-sealed-reads.sh
  Read, Grep, Glob  deny-sealed-reads.sh
A step that fails or prints what isn't one JSON object gives no answer, and
the rest still run. No deny: no answer.

Reads:     the hook JSON on stdin
Writes:    nothing
Stdout:    nothing; or the first deny, {hookSpecificOutput: {hookEventName:
           "PreToolUse", permissionDecision: "deny", permissionDecisionReason}}
Exit:
  0  always
USAGE
}

case ${1-} in -h | --help) usage; exit 0 ;; *) ;; esac
command -v jq >/dev/null 2>&1 || exit 0
input=$(cat)
tool=$(printf '%s' "${input}" | jq -r '.tool_name // ""' 2>/dev/null) || exit 0
case ${tool} in
	Bash) steps='deny-direct-event-write.sh deny-sealed-reads.sh' ;;
	Read | Grep | Glob) steps='deny-sealed-reads.sh' ;;
	*) exit 0 ;;
esac
work=$(mktemp -d "${TMPDIR:-/tmp}/guard-framework.XXXXXX")
printf '%s' "${input}" >"${work}/input"
for step in ${steps}; do
	sh "$(dirname -- "$0")/steps/${step}" <"${work}/input" >"${work}/said" || continue
	if jq -e '.hookSpecificOutput.permissionDecision == "deny"' "${work}/said" >/dev/null 2>&1; then
		jq -c '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny",
			permissionDecisionReason: (.hookSpecificOutput.permissionDecisionReason // "denied")}}' "${work}/said"
		exit 0
	fi
done
