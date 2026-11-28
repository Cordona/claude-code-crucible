#!/usr/bin/env sh
# Claude Code PreToolUse hook for AskUserQuestion, four steps as one
# question goes out: it holds the question until its card is shown, runs the
# shape check, checks a recorded gate's question and leaves the hand-off for
# its answer, then clears the session's cards. One hook, not several: hooks
# on one matcher run side by side, and nothing may be cleared while another
# check could still refuse the question.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077
# A hook fault allows the question: a bug here must never block the human.
input=''
trap 'rm -f -- ${input:+"${input}"}; exit 0' EXIT

usage() {
	cat <<'EOF'
usage: sh hold-question-until-card-shown.sh < HOOK_JSON

Run by Claude Code as the PreToolUse hook for AskUserQuestion; not for main
to call. Denies main's question until a show-card.sh card is in main's final
message, passes on check-question-shape.sh's deny, and for a recorded gate
denies all but one single-select question offering the card's yes label.
Other tools and subagents' calls pass.

Reads:     stdin, the hook JSON: session_id, agent_id, tool_name,
           tool_use_id, tool_input.questions; env CLAUDE_CONFIG_DIR
Writes:    for a recorded gate, the hand-off record-gate-answer.sh reads; a
           question let through clears the session's cards
Stdout:    on a deny, one JSON object {hookSpecificOutput: {hookEventName,
           permissionDecision: "deny", permissionDecisionReason}}; else nothing
Exit:
  0  always: the question goes ahead unless stdout holds a deny; a fault
     lets it through, writing nothing
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
# The shown card's record, when it is a recorded gate.
recorded=$(printf '%s\n' "${records}" | while IFS= read -r record; do
	[ -z "${record}" ] || jq -c 'select(.status == "shown" and .record) | .record' "${record}" 2>/dev/null
done | tail -n 1)
# The shape check: its deny goes out before anything is touched. A choice
# card's question needs no recommended option. A check that can't run is
# skipped, so a fault never blocks the human.
choice=''
[ -z "${recorded}" ] || [ "$(printf '%s' "${recorded}" | jq -r '.choice // false')" != true ] || choice='--choice'
# shellcheck disable=SC2086 # ${choice} is one word or none
shape=$(sh "$(dirname -- "$0")/../../scripts/internal/check-question-shape.sh" ${choice} <"${input}" 2>/dev/null) || shape=''
[ -z "${shape}" ] || { printf '%s\n' "${shape}"; exit 0; }
# A recorded card: check the question, and leave the hand-off.
if [ -n "${recorded}" ]; then
	problem=$(jq -r --argjson r "${recorded}" '(.tool_input.questions // []) as $q
		| if ($q | length) != 1 then "A recorded gate asks exactly one question."
		  elif $q[0].multiSelect == true then "A recorded gate asks a single-select question."
		  elif $r.choice then empty
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
