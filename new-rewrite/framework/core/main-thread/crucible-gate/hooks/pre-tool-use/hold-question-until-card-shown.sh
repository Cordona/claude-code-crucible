#!/usr/bin/env sh
# Claude Code PreToolUse hook for AskUserQuestion, three steps as one
# question goes out: it holds the question until its card is shown, checks a
# recorded gate's question and leaves the hand-off for its answer, then
# clears the session's cards. One hook, not three: hooks on one matcher run
# side by side, and the hand-off and the clearing both need the card's record
# at the moment the question is allowed.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077
# A hook fault allows the question: a bug here must never block the human.
input=''
trap 'rm -f -- ${input:+"${input}"}; exit 0' EXIT

usage() {
	cat <<'EOF'
usage: sh hold-question-until-card-shown.sh < pre-tool-use-input.json
       sh hold-question-until-card-shown.sh --help | -h

A Claude Code PreToolUse hook for AskUserQuestion. In order, as one
question goes out:
  1. Holds the question: denied while this session has no card, or a card
     not yet shown in main's final message.
  2. For a recorded card: denies a question that isn't one single-select
     question offering the card's yes label; otherwise writes the hand-off
     for the answer hook, <the session's cache folder>/answers/
     <tool_use_id>.json, holding the card's record and the question's text.
  3. Removes every card record of the session (<the session's cache
     folder>/owed/*), so the next question needs a new card.
The session's cache folder is
  ${CLAUDE_CONFIG_DIR:-~/.claude}/cache/crucible-gate/<session_id>.
Nothing else is written or removed. It is one hook, not three: hooks on one
matcher run side by side, and steps 2 and 3 both need the card's record at
the moment the question is allowed.

stdin: the hook JSON; reads session_id, agent_id, tool_name, tool_use_id,
  tool_input.questions
  Another tool, or a subagent's call (non-empty agent_id), passes untouched.
stdout on a deny:
  {"hookSpecificOutput":{"hookEventName":"PreToolUse",
   "permissionDecision":"deny","permissionDecisionReason":"<reason>"}}
Exit: always 0
EOF
}

case ${1-} in -h | --help) usage; exit 0 ;; esac
command -v jq >/dev/null 2>&1 || { printf 'hold-question-until-card-shown.sh: jq not found\n' >&2; exit 0; }
. "$(dirname -- "$0")/../../scripts/lib/owed.sh"
. "$(dirname -- "$0")/../../../crucible-events/scripts/lib/atomic-write.sh"

input=$(mktemp)
cat >"${input}"
[ "$(jq -r '.tool_name // empty' "${input}")" = AskUserQuestion ] || exit 0
[ -z "$(jq -r '.agent_id // empty' "${input}")" ] || exit 0
session=$(jq -r '.session_id // empty' "${input}")
og_safe_id "${session}" || exit 0
og_set_dir "${session}"

records=$(og_records)
deny() {
	jq -cn --arg r "$1" '{hookSpecificOutput: {hookEventName: "PreToolUse",
		permissionDecision: "deny", permissionDecisionReason: $r}}'
	exit 0
}
shown=false
# Paths are read line by line, so a space in them doesn't split one.
while IFS= read -r record; do
	[ -n "${record}" ] || continue
	case $(jq -r '.status' "${record}" 2>/dev/null) in
		owed) deny 'The card is not shown yet. End your turn with it exactly as show-card.sh printed it, then ask.' ;;
		shown) shown=true ;;
	esac
done <<EOF2
${records}
EOF2
[ "${shown}" = true ] || deny 'Every question needs a card. Write one, run show-card.sh, end your turn with the card, then ask.'
# A recorded card: check the question, and leave the hand-off.
recorded=$(printf '%s\n' "${records}" | while IFS= read -r record; do
	[ -z "${record}" ] || jq -c 'select(.status == "shown" and .record) | .record' "${record}" 2>/dev/null
done | tail -n 1)
if [ -n "${recorded}" ]; then
	problem=$(jq -r --argjson r "${recorded}" '(.tool_input.questions // []) as $q
		| if ($q | length) != 1 then "A recorded gate asks exactly one question."
		  elif $q[0].multiSelect == true then "A recorded gate asks a single-select question."
		  elif ([$q[0].options[]?.label] | index([$r.accept])) == null then "The question must offer the yes option the card named: \($r.accept)"
		  else empty end' "${input}")
	[ -z "${problem}" ] || deny "${problem}"
	tool_use_id=$(jq -r '.tool_use_id // empty' "${input}")
	og_safe_id "${tool_use_id}" || exit 0
	answers="${og_dir%/owed}/answers"
	mkdir -p -- "${answers}"
	jq -c --argjson r "${recorded}" '$r + {question: .tool_input.questions[0].question}' "${input}" | aw_write "${answers}/${tool_use_id}.json"
fi
printf '%s\n' "${records}" | while IFS= read -r record; do
	[ -z "${record}" ] || rm -f -- "${record}"
done
