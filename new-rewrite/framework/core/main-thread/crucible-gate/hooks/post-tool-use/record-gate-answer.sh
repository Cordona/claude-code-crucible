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
usage: sh record-gate-answer.sh < post-tool-use-input.json
       sh record-gate-answer.sh --help | -h

A Claude Code PostToolUse hook for AskUserQuestion. When the question had a
hand-off from hold-question-until-card-shown.sh (a recorded gate), it
writes one event to the card's effort:
  gate.answered {record, subject, question, accept, answer, accepted}
accepted is true only when the answer is the --accept label; a typed
answer never is. Other questions, and a subagent's, pass untouched.

stdin: the hook JSON; reads session_id, agent_id, tool_name, tool_use_id,
  tool_response.answers
Reads and removes the hand-off:
  ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/cache/crucible-gate/<session>/answers/<tool_use_id>.json
stdout: nothing. Exit: always 0; a fault is shown on stderr
USAGE
}

case ${1-} in -h | --help) usage; exit 0 ;; esac
command -v jq >/dev/null 2>&1 || { printf 'record-gate-answer.sh: jq not found\n' >&2; exit 0; }
. "$(dirname -- "$0")/../../scripts/lib/owed.sh"
here=$(cd -- "$(dirname -- "$0")" && pwd)
writer="${here}/../../../crucible-events/scripts/event-write.sh"

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
	| {record: $h.record, subject: $h.subject, question: $h.question, accept: $h.accept,
	   answer: $answer, accepted: ($answer == $h.accept)}' "${handoff}" >"${body}"
effort=$(jq -r '.effort' "${handoff}")
if CLAUDE_CODE_SESSION_ID=${session} sh "${writer}" --effort "${effort}" --type gate.answered \
	--by record-gate-answer.sh --body-file "${body}" >/dev/null; then
	rm -f -- "${handoff}"
else
	printf 'record-gate-answer.sh: the answer to %s was not recorded; ask again\n' "$(jq -r '.record' "${handoff}")" >&2
fi
