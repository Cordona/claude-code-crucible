#!/usr/bin/env sh
# Claude Code PostToolUse hook for AskUserQuestion: writes the human's answer
# to a recorded gate as one gate.answered event, accepted only when they
# picked the option the card named as yes.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077
input=''
trap 'rm -f -- ${input:+"${input}"}; exit 0' EXIT

usage() {
	cat <<'USAGE'
usage: sh record-gate-answer.sh < HOOK_JSON

Run by Claude Code (PostToolUse hook, AskUserQuestion); not for main to call.

Writes the human's answer to a gate recorded by show-card.sh --record, using
the hand-off hold-question-until-card-shown.sh left. Other questions, and a
subagent's, pass untouched.

Reads:     stdin, the hook JSON: session_id, agent_id, tool_name,
           tool_use_id, tool_response.answers; env CLAUDE_CONFIG_DIR
Writes:    one gate.answered event to the card's effort, read by gate-answer.sh,
           then removes the hand-off. A yes gate is accepted only when the
           answer is exactly its show-card.sh --accept label
Stdout:    nothing
Exit:
  0  always; the tool call is never blocked or changed; a fault leaves the
     answer unrecorded, reason on stderr
USAGE
}

case ${1-} in -h | --help) usage; exit 0 ;; esac
command -v jq >/dev/null 2>&1 || { printf 'record-gate-answer.sh: jq not found\n' >&2; exit 0; }
. "$(dirname -- "$0")/../../scripts/lib/owed.sh"
here=$(cd -- "$(dirname -- "$0")" && pwd)
writer="${here}/../../../crucible-events/scripts/internal/event-write.sh"

input=$(mktemp)
cat >"${input}"
[ "$(jq -r '.tool_name // empty' "${input}")" = AskUserQuestion ] || exit 0
[ -z "$(jq -r '.agent_id // empty' "${input}")" ] || exit 0
session=$(jq -r '.session_id // empty' "${input}")
tool_use_id=$(jq -r '.tool_use_id // empty' "${input}")
og_safe_id "${session}" && og_safe_id "${tool_use_id}" || exit 0
og_set_dir "${session}"
handoff="${og_dir%/owed}/answers/${tool_use_id}.json"
[ -f "${handoff}" ] || exit 0

body=$(mktemp)
trap 'rm -f -- "${input}" "${body}"; exit 0' EXIT
jq --slurpfile in "${input}" '. as $h
	| (($in[0].tool_response.answers // {})[$h.question] // "") as $answer
	| {record: $h.record, subject: $h.subject, question: $h.question}
	+ (if $h.choice then {answer: $answer}
	   else {accept: $h.accept, answer: $answer, accepted: ($answer == $h.accept)} end)' "${handoff}" >"${body}"
effort=$(jq -r '.effort' "${handoff}")
if CLAUDE_CODE_SESSION_ID=${session} sh "${writer}" --effort "${effort}" --type gate.answered \
	--by record-gate-answer.sh --body-file "${body}" >/dev/null; then
	rm -f -- "${handoff}"
else
	printf 'record-gate-answer.sh: the answer to %s was not recorded; ask again\n' "$(jq -r '.record' "${handoff}")" >&2
fi
