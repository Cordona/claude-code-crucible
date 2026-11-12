#!/usr/bin/env sh
# Claude Code PostToolUse hook (matcher AskUserQuestion) for approval gates in
# an effort: once the human answers a gate's question, it writes one
# gate.<label>.answered event from the hand-off gate-question-hook.sh left
# under the question's tool_use_id, so the decision is a fact a script can
# check. It never blocks: a fault is written as a fault.raised event, or to
# stderr when even that fails.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077

readonly PROG='gate-answer-hook.sh'
readonly EVENTS_SCRIPT="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/skills/crucible/scripts/events.sh"
# The gate label whose plan is a plan.made event; every other gate's event
# carries its rendered plan as view.
readonly PLAN_LABEL='dispatch-plan'

usage() {
	cat <<EOF
usage: sh ${PROG} < post-tool-use-input.json
       sh ${PROG} --help | -h

A Claude Code PostToolUse hook for AskUserQuestion. When the main thread's
question answered a gate of an effort, it appends one event to that
effort, through the crucible skill's events.sh:

  gate.<label>.answered  {label, plan | view, question, answer, approved}
    plan      the seq of the latest plan.made whose body is the gate's plan
              (label ${PLAN_LABEL}); view, the gate's plan, otherwise
    question  the first question's text; answer: the human's answer to it
    approved  true when the answer starts with "Approve"

stdin: the hook JSON (session_id, agent_id, tool_name, tool_use_id,
  tool_response.questions, tool_response.answers). A subagent's question,
  another tool or a question with no hand-off is left untouched.
Reads and removes the hand-off gate-question-hook.sh wrote:
  \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/cache/approval-gate/<session_id>/answers/<tool_use_id>.json

Exit codes: always 0. A failure is a fault.raised event of the effort, or
  a "${PROG}:" stderr line when the event can't be written.

Dependencies: POSIX sh, jq 1.6+, rm, mktemp; the crucible skill's events.sh.
EOF
}

warn() {
	printf '%s: %s\n' "${PROG}" "$1" >&2
}

# Records fault $1 in the effort as a fault.raised event, else on stderr; exits 0.
fault() {
	warn "$1"
	fault_body=$(mktemp 2>/dev/null) || exit 0
	if jq -nc --arg what "$1" '{what: $what}' >"${fault_body}" 2>/dev/null; then
		sh "${EVENTS_SCRIPT}" fault --effort "${effort}" --by "${PROG}" --body-file "${fault_body}" \
			--session "${session_id}" >/dev/null 2>&1 </dev/null || warn 'the fault could not be written as an event'
	fi
	rm -f "${fault_body}"
	exit 0
}

case ${1-} in
	--help | -h)
		usage
		exit 0
		;;
	*) ;;
esac

command -v jq >/dev/null 2>&1 || exit 0
hook_input=$(cat)
fields=$(printf '%s' "${hook_input}" | jq -r '[(if (.agent_id // "") == "" then "main" else "agent" end), ((.session_id | strings) // ""), ((.tool_use_id | strings) // ""), ((.tool_name | strings) // "")] | join(" ")' 2>/dev/null) || exit 0
caller=${fields%% *}
fields=${fields#* }
session_id=${fields%% *}
fields=${fields#* }
tool_use_id=${fields%% *}
tool_name=${fields#* }
[ "${tool_name}" = AskUserQuestion ] && [ "${caller}" = main ] || exit 0
case ${session_id}:${tool_use_id} in
	*[!A-Za-z0-9._:-]* | :* | *: | *..*) exit 0 ;;
	*) ;;
esac
handoff="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/cache/approval-gate/${session_id}/answers/${tool_use_id}.json"
[ -f "${handoff}" ] || exit 0
effort=$(jq -r '.effort // ""' "${handoff}" 2>/dev/null) || effort=''
[ -n "${effort}" ] || {
	warn "the hand-off ${handoff} names no effort; nothing recorded"
	rm -f "${handoff}"
	exit 0
}
[ -f "${EVENTS_SCRIPT}" ] || {
	warn "events.sh missing at ${EVENTS_SCRIPT}; the answer is not recorded"
	exit 0
}
label=$(jq -r '.label // ""' "${handoff}")
case ${label} in
	'' | *[!abcdefghijklmnopqrstuvwxyz0123456789-]*) fault "the hand-off ${handoff} names a bad label; the answer is not recorded" ;;
	*) ;;
esac

# The answer: the first question's text and the human's answer to it.
answer_file=$(mktemp) || fault 'mktemp failed; the answer is not recorded'
printf '%s' "${hook_input}" | jq -c '(.tool_response.questions[0].question // "") as $question
	| {question: $question, answer: ((.tool_response.answers // {})[$question] // "")}' >"${answer_file}" 2>/dev/null ||
	fault 'jq could not read the answer from the hook input; the answer is not recorded'

# The plan's seq for a dispatch plan, matched on the canonical plan.
plan_seq=null
if [ "${label}" = "${PLAN_LABEL}" ]; then
	plans=$(sh "${EVENTS_SCRIPT}" slurp --effort "${effort}" --type plan.made </dev/null 2>/dev/null) ||
		fault "events.sh slurp failed for ${effort}; the answer is not recorded"
	plan_seq=$(printf '%s\n' "${plans}" | jq --slurpfile handoff "${handoff}" \
		'($handoff[0].plan | tojson) as $plan | [.[] | select((.body | tojson) == $plan) | .seq] | last // null') ||
		fault 'jq could not match the gate plan to a plan.made event'
fi

body_file=$(mktemp) || fault 'mktemp failed; the answer is not recorded'
jq -c --argjson plan_seq "${plan_seq}" --slurpfile handoff "${handoff}" \
	'{label: $handoff[0].label}
	+ (if $plan_seq != null then {plan: $plan_seq} else {view: $handoff[0].plan} end)
	+ . + {approved: (.answer | startswith("Approve"))}' "${answer_file}" >"${body_file}" ||
	fault 'jq could not build the gate event; the answer is not recorded'
rm -f "${answer_file}"
if sh "${EVENTS_SCRIPT}" append --effort "${effort}" --type "gate.${label}.answered" --by "${PROG}" \
	--body-file "${body_file}" --session "${session_id}" >/dev/null </dev/null; then
	rm -f "${body_file}" "${handoff}"
	exit 0
fi
rm -f "${body_file}"
fault "events.sh append gate.${label}.answered failed (its stderr is above); the hand-off ${handoff} stays"
