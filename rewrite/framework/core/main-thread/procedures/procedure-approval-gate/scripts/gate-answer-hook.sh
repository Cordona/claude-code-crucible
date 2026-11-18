#!/usr/bin/env sh
# Claude Code hook for approval gates in an effort, registered twice: on
# PostToolUse (matcher AskUserQuestion), once the human answers a gate's
# question in its dialog, and on UserPromptSubmit, when the human answered it
# from a dashboard instead: the dialog is then dismissed, the tool call ends
# as a rejection with no PostToolUse, and the answer comes as the next prompt.
# Either way it writes one gate.<label>.answered event from the hand-off
# gate-question-hook.sh left under the question's tool_use_id, so the decision
# is a fact a script can check. It never blocks and prints nothing on stdout,
# which a UserPromptSubmit hook adds to the context: a fault is written as a
# fault.raised event, or to stderr when even that fails.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077
body_file=''
trap '[ -z "${body_file}" ] || rm -f -- "${body_file}"' EXIT

readonly PROG='gate-answer-hook.sh'
readonly EVENTS_SCRIPT="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/skills/crucible/scripts/events.sh"
readonly GATE_ROOT="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/cache/approval-gate"
# The gate label whose plan is a plan.made event; every other gate's event
# carries its rendered plan as view.
readonly PLAN_LABEL='dispatch-plan'
# The line a dashboard answer starts with, in the prompt that carries it.
readonly ANSWERS_MARKER='[[HUMAN_ANSWERS]]'
# From a prompt holding the marker line, then the dashboard's
# {"answers": {<header>: {question, selectedAnswers, customAnswer}}} JSON, as
# in a <pasted_content> wrapper: one {question, answer} per answered
# question, the answer its first selected option, else its typed text. Any
# other prompt gives nothing.
# shellcheck disable=SC2016 # the $ names are jq's
readonly PROMPT_ANSWERS_JQ='((.prompt | strings) // "")
	| capture("(?:^|\n)\\[\\[HUMAN_ANSWERS\\]\\][ \t]*\r?\n[^{]*(?<json>\\{.*\\})"; "p").json
	| (try fromjson catch null)
	| (objects | .answers | objects) // empty
	| .[] | objects
	| {question, answer: (if (.selectedAnswers | type) == "array" and (.selectedAnswers | length) > 0
		then .selectedAnswers[0] else .customAnswer end)}
	| select((.question | type) == "string" and (.answer | type) == "string")'

usage() {
	cat <<EOF
usage: sh ${PROG} < hook-input.json
       sh ${PROG} --help | -h

A Claude Code hook, registered on PostToolUse for AskUserQuestion and on
UserPromptSubmit. When the main thread's question answered a gate of an
effort, it appends one event to that effort, through the crucible skill's
events.sh:

  gate.<label>.answered  {plan | view, answer}
    plan      label ${PLAN_LABEL}: the seq of the latest plan.made whose body
              is the gate's plan, or null when none matches
    view      every other label: the gate's plan
    answer    the human's answer to the first question

stdin, one of:
  PostToolUse (session_id, agent_id, tool_name, tool_use_id,
    tool_response.questions, tool_response.answers): the hand-off of
    tool_use_id. A subagent's question or another tool is left untouched.
  UserPromptSubmit (session_id, prompt, hook_event_name): a question
    answered from a dashboard, its dialog dismissed. When the prompt holds
    a "${ANSWERS_MARKER}" line, then JSON {"answers": {<header>:
    {question, selectedAnswers, customAnswer}}}, each answered question
    takes the newest hand-off whose question is its question; the answer
    is selectedAnswers[0], else customAnswer.
  A question with no hand-off, or a prompt without the block or with no
  match, is left untouched.
Reads and removes the hand-off gate-question-hook.sh wrote:
  \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/cache/approval-gate/<session_id>/answers/<tool_use_id>.json

stdout: nothing, ever.
Exit codes: always 0. A failure is a fault.raised event of the effort, or
  a "${PROG}:" stderr line when the event can't be written.

Dependencies: POSIX sh, jq 1.6+, ls, rm, mktemp; the crucible skill's
  events.sh.
EOF
}

warn() {
	printf '%s: %s\n' "${PROG}" "$1" >&2
}

# Records fault $1 in the effort as a fault.raised event, else on stderr; exits 0.
fault() {
	warn "$1"
	[ -z "${body_file}" ] || rm -f -- "${body_file}"
	body_file=$(mktemp 2>/dev/null) || exit 0
	if jq -nc --arg what "$1" '{what: $what}' >"${body_file}" 2>/dev/null; then
		sh "${EVENTS_SCRIPT}" fault --effort "${effort}" --by "${PROG}" --body-file "${body_file}" \
			--session "${session_id}" >/dev/null 2>&1 </dev/null || warn 'the fault could not be written as an event'
	fi
	exit 0
}

# True when id $1 is safe as one path component.
is_safe_id() {
	case $1 in
		'' | . | .. | *[!A-Za-z0-9._:-]*) return 1 ;;
		*) return 0 ;;
	esac
}

# Records the PostToolUse answer of question tool_use_id.
record_tool_answer() {
	[ "${tool_name}" = AskUserQuestion ] || exit 0
	# shellcheck disable=SC2310 # a pure test; its status is the answer
	is_safe_id "${tool_use_id}" || exit 0
	handoff="${GATE_ROOT}/${session_id}/answers/${tool_use_id}.json"
	[ -f "${handoff}" ] || exit 0
	answer=$(printf '%s' "${hook_input}" | jq -c '(.tool_response.questions[0].question // "") as $question
		| {question: $question, answer: ((.tool_response.answers // {})[$question] // "")}' 2>/dev/null) ||
		answer=''
	record_answer "${answer}"
}

# Records each dashboard answer in the prompt that has a hand-off.
record_prompt_answers() {
	case ${hook_input} in
		*"${ANSWERS_MARKER}"*) ;;
		*) exit 0 ;;
	esac
	answers_dir="${GATE_ROOT}/${session_id}/answers"
	[ -d "${answers_dir}" ] && [ ! -L "${answers_dir}" ] || exit 0
	prompt_answers=$(printf '%s' "${hook_input}" | jq -c "${PROMPT_ANSWERS_JQ}" 2>/dev/null) || exit 0
	while IFS= read -r answer; do
		[ -n "${answer}" ] || continue
		find_handoff "${answer}"
		[ -z "${handoff}" ] || record_answer "${answer}"
	done <<EOF
${prompt_answers}
EOF
}

# Sets handoff to the newest hand-off in answers_dir whose question is the
# question of answer $1, or to '' when none is.
find_handoff() {
	handoff=''
	# shellcheck disable=SC2012 # ls -t is the portable newest-first order; each name is checked below
	handoff_names=$(ls -t "${answers_dir}" 2>/dev/null) || return 0
	while IFS= read -r handoff_name; do
		# shellcheck disable=SC2310 # a pure test; its status is the answer
		is_safe_id "${handoff_name%.json}" && [ "${handoff_name%.json}.json" = "${handoff_name}" ] || continue
		candidate="${answers_dir}/${handoff_name}"
		[ -f "${candidate}" ] && [ ! -L "${candidate}" ] || continue
		if jq -e --argjson answer "$1" '.question == $answer.question' "${candidate}" >/dev/null 2>&1; then
			handoff=${candidate}
			return 0
		fi
	done <<EOF
${handoff_names}
EOF
}

# Appends the gate.<label>.answered event of hand-off handoff, with answer
# $1 ({question, answer}), then removes the hand-off; a fault exits.
record_answer() {
	effort=$(jq -r '.effort // ""' "${handoff}" 2>/dev/null) || effort=''
	[ -n "${effort}" ] || {
		warn "the hand-off ${handoff} names no effort; nothing recorded"
		rm -f "${handoff}"
		return 0
	}
	[ -f "${EVENTS_SCRIPT}" ] || {
		warn "events.sh missing at ${EVENTS_SCRIPT}; the answer is not recorded"
		exit 0
	}
	label=$(jq -r '.label // ""' "${handoff}" 2>/dev/null) || label=''
	case ${label} in
		'' | *[!abcdefghijklmnopqrstuvwxyz0123456789-]*) fault "the hand-off ${handoff} names a bad label; the answer is not recorded" ;;
		*) ;;
	esac
	[ -n "$1" ] || fault 'jq could not read the answer from the hook input; the answer is not recorded'
	find_plan_seq
	body_file=$(mktemp) || fault 'mktemp failed; the answer is not recorded'
	printf '%s\n' "$1" | jq -c --argjson plan_seq "${plan_seq}" --arg label "${label}" --arg plan_label "${PLAN_LABEL}" --slurpfile handoff "${handoff}" \
		'(if $label == $plan_label then {plan: $plan_seq} else {view: $handoff[0].plan} end)
		+ {answer: .answer}' >"${body_file}" ||
		fault 'jq could not build the gate event; the answer is not recorded'
	sh "${EVENTS_SCRIPT}" append --effort "${effort}" --type "gate.${label}.answered" --by "${PROG}" \
		--body-file "${body_file}" --session "${session_id}" >/dev/null </dev/null ||
		fault "events.sh append gate.${label}.answered failed (its stderr is above); the hand-off ${handoff} stays"
	rm -f "${body_file}" "${handoff}"
	body_file=''
}

# Sets plan_seq to the seq of the plan.made matching a dispatch plan's
# canonical plan, else null.
find_plan_seq() {
	plan_seq=null
	[ "${label}" = "${PLAN_LABEL}" ] || return 0
	plans=$(sh "${EVENTS_SCRIPT}" slurp --effort "${effort}" --type plan.made </dev/null 2>/dev/null) ||
		fault "events.sh slurp failed for ${effort}; the answer is not recorded"
	plan_seq=$(printf '%s\n' "${plans}" | jq --slurpfile handoff "${handoff}" \
		'($handoff[0].plan | tojson) as $plan | [.[] | select((.body | tojson) == $plan) | .seq] | last // null') ||
		fault 'jq could not match the gate plan to a plan.made event'
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
# Fields: the caller ("main", or "agent" when agent_id is set), session_id,
# tool_use_id, hook_event_name and tool_name, a non-string or spaced one as
# "" so the fields never shift.
fields=$(printf '%s' "${hook_input}" | jq -r '[(if (.agent_id // "") == "" then "main" else "agent" end),
	([.session_id, .tool_use_id, .hook_event_name, .tool_name][]
		| if type == "string" and (test(" ") | not) then . else "" end)] | join(" ")' 2>/dev/null) || exit 0
caller=${fields%% *}
fields=${fields#* }
session_id=${fields%% *}
fields=${fields#* }
tool_use_id=${fields%% *}
fields=${fields#* }
event_name=${fields%% *}
tool_name=${fields#* }
[ "${caller}" = main ] || exit 0
# shellcheck disable=SC2310 # a pure test; its status is the answer
is_safe_id "${session_id}" || exit 0
case ${event_name} in
	UserPromptSubmit) record_prompt_answers ;;
	*) record_tool_answer ;;
esac
exit 0
