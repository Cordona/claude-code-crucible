#!/usr/bin/env sh
# Claude Code PreToolUse hook (matcher AskUserQuestion) for approval gates. It
# denies the question while this session's gate card is owed (show.sh recorded
# it and show-stop-hook.sh has not seen it shown), so the plan is shown before
# it is asked about. It closes a shown gate as its question goes out, first
# saving an effort's gate's plan as a gate record: a hand-off under the
# question's tool_use_id, from which gate-answer-hook.sh writes the
# gate.<label>.answered event once the human answers. The record is the plan
# the human was shown, so a shown gate whose record can't be saved denies the
# question and stays open. A fault allows the question, except once an owed
# gate is found, or when jq is missing and any session has a live owed gate:
# then it fails closed, since that block is confined to an open gate and ends
# when the gate goes stale.
# shellcheck source-path=SCRIPTDIR
set -eu
# The EXIT trap also removes the record temp file, and a signal exits
# through it.
record_temp=''
trap 'rm -f -- ${record_temp:+"${record_temp}"}; exit 0' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
umask 077

readonly PROG='gate-question-hook.sh'
readonly REASON_PREFIX='procedure-approval-gate:'
readonly DENY_REASON="${REASON_PREFIX} this session's gate is pending: its plan has not been relayed as a turn's last message yet, so the question is denied."
# The record deny when jq can't build the one naming the cause, so a shown
# gate without its record never lets the question through.
readonly RECORD_DENY_FALLBACK='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"procedure-approval-gate: the gate record could not be saved, so the question is denied; the cause is on the hook'\''s stderr; fix it, then ask again."}}'
readonly SPACE_LIB="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/skills/crucible/scripts/lib/crucible-space.sh"
readonly HV_LIB_DIR="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/skills/human-view/scripts/lib"
# The verdict on one owed record: its status (owed or shown) for a gate,
# stale for a gate past the store's stale time, other for anything else.
# shellcheck disable=SC2016 # the $ names are jq's
readonly GATE_JQ='include "owed";
if is_owed_record and .kind == "gate" then (if is_stale(now; $stale) then "stale" else .status end)
else "other" end'

usage() {
	cat <<EOF
usage: sh ${PROG} < pre-tool-use-input.json
       sh ${PROG} --help | -h

A Claude Code PreToolUse hook for AskUserQuestion: denies the main thread's
question while this session's gate card is owed, and closes this session's
shown gate as its question goes out, first saving its plan as the gate
record when the gate has an effort.
On a fault the question is allowed, with two exceptions: while an owed gate
  is open (with jq missing: any session's), exit 2; when a shown gate's
  record could not be saved, the deny on stdout.

stdin: the hook JSON (session_id, agent_id, tool_name, tool_use_id,
  tool_input.questions); a tool_name other than AskUserQuestion, a non-empty
  agent_id (a subagent's or side agent's question) or a missing, non-string
  or unsafe session_id is allowed untouched
Reads the session's gate record, which show.sh wrote (see show.sh --help),
  and the plan file in
  \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/cache/approval-gate/<session_id>/

stdout on a deny (exit 0): one PreToolUse decision for Claude Code,
  {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"<reason>"}}
  with <reason> one of:
  "${DENY_REASON}"
    the gate is not shown yet; it stays owed
  "${REASON_PREFIX} the gate record could not be saved (<cause>), so the question is denied; <fix>, then ask again."
    the shown gate stays open; a <fix> starting "open the gate again" means
      the gate's record is bad and the gate must be opened again
stderr on exit 0: notes on a removed gate, an unsaved record or a missing jq,
  or a failing command's own message

Writes, in this session's gate folder and owed records only:
  a shown gate's record, when it names an effort:
    answers/<tool_use_id>.json in the gate folder, {label, effort,
    question, plan}, the question the first one's text,
    for gate-answer-hook.sh; a gate without an effort saves nothing
  closing a shown gate: removes its owed record and plan.json, then the
    gate folder once empty
  a gate record past the store's stale time: removed

Exit codes:
  0  allowed; or denied by the decision on stdout, which Claude Code applies,
     giving Claude its reason
  2  denied: Claude Code blocks the question and gives Claude the reason from
     stderr, starting "${REASON_PREFIX}"; the block ends at most
     ${hv_stale_minutes-} minutes after the gate was opened

Dependencies:
  POSIX sh; cat, find (with -mmin, as on macOS and Linux), grep, rm, rmdir
    (every macOS and Linux base system)
  jq 1.6+ (macOS: brew install jq; Linux: the distro's jq package)
  human-view's store rules, lib/owed.sh and lib/owed.jq, in
    \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/skills/human-view/scripts/
  for a shown gate: the crucible skill's space rules,
    \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/skills/crucible/scripts/lib/crucible-space.sh,
    and mkdir, mktemp, mv (with an effort)

Environment:
  CLAUDE_CONFIG_DIR  the Claude Code config folder; default \$HOME/.claude
  CRUCIBLE_HOME  the Crucible space; its rules: see crucible.sh --help
EOF
}

warn() {
	printf '%s: %s\n' "${PROG}" "$1" >&2
}

# With jq missing no record can be read, so any session's owed gate record
# changed within the stale time denies the question (exit 2); with none, or
# without human-view's store rules, it is allowed (exit 0).
handle_jq_missing() {
	if [ -n "${hv_root-}" ]; then
		for owed_record in "${hv_root}"/*/owed/*.json; do
			[ -f "${owed_record}" ] || continue
			# show.sh writes records as compact JSON, so the two fields read as written.
			grep -q '"kind":"gate"' "${owed_record}" 2>/dev/null || continue
			grep -q '"status":"owed"' "${owed_record}" 2>/dev/null || continue
			recent=$(find "${owed_record}" -prune ! -mmin "+${hv_stale_minutes}" 2>/dev/null) || recent=''
			[ -n "${recent}" ] || continue
			printf '%s jq is missing and a pending gate exists, so the question is denied; the hooks need jq 1.6+.\n' "${REASON_PREFIX}" >&2
			trap - EXIT
			exit 2
		done
	fi
	warn 'jq missing; no pending gate; question allowed'
	exit 0
}

# Saves the shown gate's plan.json as the hand-off when its record names an
# effort, or denies the question (deny_record exits) naming the cause and the
# fix.
save_gate_record() {
	load_space_lib
	read_gate_target
	[ -n "${record_effort}" ] || return 0
	plan_file="${gate_dir}/plan.json"
	[ -f "${plan_file}" ] && [ ! -L "${plan_file}" ] ||
		deny_record "no plan file at ${plan_file}" 'show the plan again through open-gate.sh --plan-path and the renderer'
	jq -se 'length == 1 and (.[0] | type) == "object"' "${plan_file}" >/dev/null 2>&1 ||
		deny_record "${plan_file} is not one JSON object" 'write the plan again and show it through open-gate.sh'
	make_effort_record
	# The first question's text, as JSON, by which a dashboard answer finds
	# the record.
	question=$(printf '%s' "${hook_input}" | jq -c '(.tool_input.questions[0].question | strings) // ""' 2>/dev/null) ||
		deny_record "jq could not read the question for ${record_path}" 'check jq 1.6+'
	record=$(jq -c --arg label "${record_label}" --arg effort "${record_effort}" --argjson question "${question}" \
		'{label: $label, effort: $effort, question: $question, plan: .}' "${plan_file}" 2>/dev/null) ||
		deny_record "jq could not build the hand-off for ${record_path}" 'check jq 1.6+ and the plan file'
	# Written beside the record and moved onto it, so a record is never half
	# written.
	record_temp=$(mktemp "${record_path%/*}/.gate-record.XXXXXX" 2>/dev/null) ||
		deny_record "cannot create a temp file beside ${record_path}, which stays empty" "make ${record_path%/*} writable"
	if printf '%s\n' "${record}" >"${record_temp}" && mv -f "${record_temp}" "${record_path}"; then
		record_temp=''
		return 0
	fi
	rm -f "${record_temp}"
	record_temp=''
	deny_record "the write to ${record_path} failed, and it stays empty" "make ${record_path%/*} writable"
}

# Sources the crucible skill's space rules, or denies.
load_space_lib() {
	[ -f "${SPACE_LIB}" ] && [ -r "${SPACE_LIB}" ] ||
		deny_record "the space rules are missing at ${SPACE_LIB}" 'install the crucible skill'
	# shellcheck source=../../../../engine/crucible/scripts/lib/crucible-space.sh
	. "${SPACE_LIB}"
}

# Sets record_label and record_effort from the gate's owed record, or denies.
read_gate_target() {
	open_again='open the gate again through open-gate.sh --label LABEL [--effort FOLDER]'
	record_label=$(jq -r '.gate | strings' "${gate_record}" 2>/dev/null) ||
		deny_record "${gate_record} could not be read" "${open_again}"
	record_effort=$(jq -r '.effort // "" | strings' "${gate_record}" 2>/dev/null) ||
		deny_record "${gate_record} could not be read" "${open_again}"
	# shellcheck disable=SC2310 # a pure test; its status is the answer
	crucible_is_label "${record_label}" ||
		deny_record "${gate_record} names a bad label (${crucible_label_problem})" "${open_again}"
}

# Sets record_path to the answer hand-off of this question, answers/<tool_use_id>.json
# in the gate folder, or denies.
make_effort_record() {
	answers_dir="${gate_dir}/answers"
	[ ! -L "${answers_dir}" ] || deny_record "${answers_dir} is a symbolic link" 'remove the link'
	mkdir -p "${answers_dir}" 2>/dev/null && [ ! -L "${answers_dir}" ] ||
		deny_record "cannot create ${answers_dir}" 'make the gate folder writable'
	record_path="${answers_dir}/${tool_use_id}.json"
}

# Removes the gate's record and plan file, and the gate folder once nothing
# else is left in it.
clear_gate() {
	rm -f "${gate_record}" "${gate_dir}/plan.json"
	rmdir "${gate_dir}" 2>/dev/null || true
}

# Denies the question because the record could not be saved (cause $1, fix $2);
# the gate stays, so the next question tries again.
deny_record() {
	record_reason="${REASON_PREFIX} the gate record could not be saved ($1), so the question is denied; $2, then ask again."
	warn "gate record not saved: $1"
	jq -cn --arg reason "${record_reason}" \
		'{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}' ||
		printf '%s\n' "${RECORD_DENY_FALLBACK}"
	exit 0
}

# Sets gate_dir (absolute, so the paths stderr names are whole), and
# gate_record and gate_status from this session's gate record, an owed one
# first, both empty when there is none; removes a stale one.
load_gate() {
	gate_dir="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/cache/approval-gate/$1"
	case ${gate_dir} in
		/*) ;;
		*) gate_dir="$(pwd)/${gate_dir}" ;;
	esac
	# shellcheck disable=SC2310 # its status says whether the paths are usable; the problem is read below
	hv_set_paths "$1" || {
		warn "${hv_path_problem}; question allowed"
		exit 0
	}
	gate_record='' gate_status=''
	for owed_record in "${hv_owed_dir}"/*.json; do
		[ -f "${owed_record}" ] && [ ! -L "${owed_record}" ] || continue
		verdict=$(jq -r -L "${HV_LIB_DIR}" --argjson stale "${hv_stale_seconds}" "${GATE_JQ}" "${owed_record}" 2>/dev/null) || continue
		case ${verdict} in
			stale)
				warn "stale gate removed: ${owed_record}"
				rm -f "${owed_record}"
				;;
			owed)
				gate_record=${owed_record} gate_status=owed
				return 0
				;;
			shown) gate_record=${owed_record} gate_status=shown ;;
			*) ;;
		esac
	done
}

if [ -f "${HV_LIB_DIR}/owed.sh" ] && [ -r "${HV_LIB_DIR}/owed.sh" ] && [ -f "${HV_LIB_DIR}/owed.jq" ]; then
	# shellcheck source=../../../../engine/human-view/scripts/lib/owed.sh
	. "${HV_LIB_DIR}/owed.sh"
	hv_set_root
else
	hv_root=''
fi

case ${1-} in
	--help | -h)
		usage
		exit 0
		;;
	*) ;;
esac
command -v jq >/dev/null 2>&1 || handle_jq_missing
[ -n "${hv_root}" ] || {
	warn "human-view's store rules missing in ${HV_LIB_DIR}; question allowed; reinstall the human-view skill"
	exit 0
}
hook_input=$(cat)
# Fields: the caller ("main", or "agent" when agent_id is set), session_id and
# tool_name, a non-string one as "" so the fields never shift; none holds a
# space once checked.
fields=$(printf '%s' "${hook_input}" | jq -r '[(if (.agent_id // "") == "" then "main" else "agent" end), ((.session_id | strings) // ""), ((.tool_use_id | strings) // ""), ((.tool_name | strings) // "")] | join(" ")')
caller=${fields%% *}
fields=${fields#* }
session_id=${fields%% *}
fields=${fields#* }
tool_use_id=${fields%% *}
tool_name=${fields#* }
[ "${tool_name}" = AskUserQuestion ] || exit 0
# A subagent's or side agent's question carries the parent's session_id plus
# its own agent_id; only the main thread's question may close the gate.
[ "${caller}" = main ] || exit 0
case ${session_id} in
	'' | . | .. | *[!A-Za-z0-9._-]*) exit 0 ;;
	*) ;;
esac
case ${tool_use_id} in
	'' | . | .. | *[!A-Za-z0-9._-]*) tool_use_id=unknown ;;
	*) ;;
esac
load_gate "${session_id}"
[ -n "${gate_record}" ] || exit 0
if [ "${gate_status}" = shown ]; then
	save_gate_record
	clear_gate
	exit 0
fi

# An owed gate is loaded: from here any failure denies the question (exit 2).
# An EXIT trap, not set -E with ERR, so it works in dash too.
trap 'printf "%s internal error in %s with a pending gate, so the question is denied; the question is allowed once the gate is shown, or %s minutes after it opened.\n" "${REASON_PREFIX}" "${PROG}" "${hv_stale_minutes}" >&2; exit 2' EXIT
deny=$(jq -cn --arg reason "${DENY_REASON}" \
	'{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}')
printf '%s\n' "${deny}"
trap - EXIT
exit 0
