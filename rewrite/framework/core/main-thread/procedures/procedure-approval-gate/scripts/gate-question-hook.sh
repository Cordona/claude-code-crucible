#!/usr/bin/env sh
# Claude Code PreToolUse hook (matcher AskUserQuestion) for approval gates. It
# denies the question while this session's gate is pending, so the plan is
# relayed before it is asked about, and clears any other gate as its question
# goes out, saving a relayed gate's plan as a gate record first, in its
# effort's cache/gates/ or, before any effort, in the session's gate folder:
# the record is the plan the human was shown, which a dispatch is later
# matched against, so a relayed gate whose record can't be saved denies the
# question and stays open. A fault allows the question, except once a
# pending gate is loaded, or when jq is missing and any session has a live
# pending gate: then it fails closed, since that block is confined to an open
# gate and ends when the gate goes stale.
# shellcheck source-path=SCRIPTDIR
set -eu
trap 'exit 0' EXIT
umask 077

readonly PROG='gate-question-hook.sh'
readonly REASON_PREFIX='procedure-approval-gate:'
# 30 min, as in gate-stop-hook.sh: long enough to read a plan, short enough that
# a gate left open by a crashed or abandoned turn soon stops denying questions.
readonly STALE_SECONDS=1800
readonly STALE_MINUTES=$((STALE_SECONDS / 60))
readonly DENY_REASON="${REASON_PREFIX} this session's gate is pending: its plan has not been relayed as a turn's last message yet, so the question is denied."
# The record deny when jq can't build the one naming the cause, so a relayed
# gate without its record never lets the question through.
readonly RECORD_DENY_FALLBACK='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"procedure-approval-gate: the gate record could not be saved, so the question is denied; the cause is on the hook'\''s stderr; fix it, then ask again."}}'
readonly CRUCIBLE_HELPER="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/skills/crucible/scripts/crucible.sh"
readonly SPACE_LIB="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/skills/crucible/scripts/lib/crucible-space.sh"

usage() {
	cat <<EOF
Usage: sh ${PROG} < pre-tool-use-input.json

A Claude Code PreToolUse hook for the AskUserQuestion tool. It reads the hook
JSON on stdin (session_id, agent_id, tool_name, ...) and the gate state
open-gate.sh wrote in
  \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/cache/approval-gate/<session_id>/
  - no gate, or a malformed gate or one older than ${STALE_SECONDS}s (removed
    with its folder, plan.json included, unless plan.json changed in the last
    ${STALE_SECONDS}s: then only gate.md and the state go, and plan.json stays
    for the next gate): allows the question
  - no gate state, and nothing in the folder (the folder itself included)
    changed in the last ${STALE_SECONDS}s: removes the folder, allows the
    question
  - pending: prints a PreToolUse deny decision, exit 0:
    {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny",
     "permissionDecisionReason":"${DENY_REASON}"}}
  - shown or failed: clears the gate (below), allows the question.
  - relayed: first saves plan.json, with "v": 1 set, as a gate record, its
    label and effort read from the gate's target file, which open-gate.sh
    --label LABEL [--effort FOLDER] wrote (its --help states the format),
    the label checked by the crucible skill's space rules,
    scripts/lib/crucible-space.sh:
      with an effort, the file
        \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/skills/crucible/scripts/crucible.sh
        new --kind cache/gates --label <LABEL> --effort <FOLDER>
      prints, in the effort's cache/gates/ (it expires as crucible.sh
      --help sets);
      with none (a gate before any effort, such as the effort offer), a new
      file in <gate folder>/records/, named as a cache/gates item of label
      <LABEL> and created without overwriting, its ID minted afresh on a
      clash up to the space rules' number of tries, as crucible.sh new
      does (crucible_claim_item_file of the space rules), never in the
      Crucible space;
    written to a temp file in the record's folder and moved onto it;
    then clears the gate and allows the question. Clearing a gate removes
    its gate.md, state, target file and plan.json, and the gate folder
    itself once nothing else is left in it: records/ stays until the
    folder is removed whole (open-gate.sh's sweep of a stale folder, or a
    hook removing a malformed, stale or idle gate with its folder, as
    above). When the record can't be saved (the target file
    missing, malformed or naming a bad label; crucible.sh or the space
    rules missing; plan.json missing, a symbolic link or not one JSON
    object; jq unable to read plan.json; crucible.sh new failing, its
    stderr passed through, or printing no .json file path; the records/
    file not creatable; or the temp file or move failing) it prints a
    PreToolUse deny, exit 0, its reason
      "${REASON_PREFIX} the gate record could not be saved (<cause>), so
       the question is denied; <fix>, then ask again."
    and keeps the gate, so the next question tries again; a gate left so
    goes stale after ${STALE_SECONDS}s like any other. A record whose write
    fails after crucible.sh created it stays as its empty file.
A tool_name other than AskUserQuestion is allowed untouched, and so is any
call whose input has a non-empty agent_id: such a call comes from a subagent,
or from a side agent Claude Code runs inside the session, which carries the
main thread's session_id. The gate belongs to the main thread, so only its
own question saves the record and clears the gate; another agent's question
leaves the gate, plan.json included, as it is, with no record and no deny.

Exit codes:
  0  allowed, or denied through the JSON above; a hook fault before a pending
     gate is loaded also allows (any stderr is the failing command's own,
     such as jq's parse error); a missing, non-string or unsafe session_id
     allows silently
  2  denied with the reason on stderr (starting "${REASON_PREFIX}"): an internal
     error after a pending gate was loaded, or jq missing while some session
     has a pending gate younger than ${STALE_SECONDS}s

Stderr notes (exit 0): "<what> removed: <folder>" or "<what> removed,
plan.json kept: <folder>" when a gate is cleared as malformed, stale or idle;
"gate record not saved: <cause>" with a record deny; "jq missing; no pending
gate; question allowed".

Dependencies: POSIX sh, jq 1.6+ (macOS: brew install jq; Linux: the distro's
jq package), cat, date, find (with -mmin, as on macOS and
Linux), rm, rmdir; for the record of a relayed gate also mktemp and mv, the
crucible skill's scripts/lib/crucible-space.sh, and crucible.sh (with an
effort) or od and mkdir (without one); without them a relayed gate's
question is denied.
Runtime: about 13 ms with no gate, 20 ms denying, 80 ms clearing a relayed gate
with its record; measured on macOS (average of 5 runs).
EOF
}

warn() {
	printf '%s: %s\n' "${PROG}" "$1" >&2
}

# Removes the gate (reason $1 goes to stderr) and allows the question: the whole
# folder, or only gate.md and the state when plan.json changed within
# STALE_SECONDS, since that is the session's next plan, written before its gate
# opens.
remove_gate() {
	fresh_plan=$(find "${gate_dir}/plan.json" -prune -type f ! -mmin "+${STALE_MINUTES}" 2>/dev/null) || fresh_plan=''
	if [ -n "${fresh_plan}" ]; then
		warn "$1 removed, plan.json kept: ${gate_dir}"
		rm -f "${gate_dir}/state" "${gate_dir}/gate.md"
	else
		warn "$1 removed: ${gate_dir}"
		rm -rf "${gate_dir}"
	fi
	exit 0
}

# With no gate state, removes the folder when nothing in it (the folder
# included) changed within STALE_SECONDS; allows the question either way.
drop_idle_folder() {
	recent=$(find "${gate_dir}" ! -mmin "+${STALE_MINUTES}" 2>/dev/null) || exit 0
	[ -n "${recent}" ] || remove_gate 'gate folder with no gate state, unchanged for over '"${STALE_SECONDS}"'s,'
	exit 0
}

# True when the state line in file $1 is a pending gate younger than
# STALE_SECONDS. Needs no jq.
is_live_pending() {
	read -r pending_status pending_tries pending_created _ <"$1" || true
	[ "${pending_status-}" = pending ] || return 1
	case ${pending_tries-}:${pending_created-} in
		:* | *: | *[!0-9:]* | *:*:*) return 1 ;;
		*) ;;
	esac
	pending_now=$(date +%s) || return 1
	[ $((pending_now - pending_created)) -le "${STALE_SECONDS}" ]
}

# With jq missing the session id can't be read, so any session's live pending
# gate denies the question (exit 2); with none it is allowed (exit 0).
handle_jq_missing() {
	for state_file in "${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"/cache/approval-gate/*/state; do
		[ -f "${state_file}" ] || continue
		# shellcheck disable=SC2310 # its status is the answer; set -e is not needed inside
		if is_live_pending "${state_file}"; then
			printf '%s jq is missing and a pending gate exists, so the question is denied; the hooks need jq 1.6+.\n' "${REASON_PREFIX}" >&2
			trap - EXIT
			exit 2
		fi
	done
	warn 'jq missing; no pending gate; question allowed'
	exit 0
}

# Saves the relayed gate's plan.json as a gate record where the gate's target
# file says, or denies the question (deny_record exits) naming the cause and
# the fix.
save_gate_record() {
	load_space_lib
	read_target
	plan_file="${gate_dir}/plan.json"
	[ -f "${plan_file}" ] && [ ! -L "${plan_file}" ] ||
		deny_record "no plan file at ${plan_file}" 'show the plan again through open-gate.sh --plan-path and the renderer'
	jq -se 'length == 1 and (.[0] | type) == "object"' "${plan_file}" >/dev/null 2>&1 ||
		deny_record "${plan_file} is not one JSON object" 'write the plan again and show it through open-gate.sh'
	# del(.v) so a plan's own v never overrides the record version; v stays first.
	record=$(jq -c '{v: 1} + del(.v)' "${plan_file}" 2>/dev/null) ||
		deny_record "jq could not read ${plan_file}" 'check jq 1.6+ and the plan file'
	if [ -n "${record_effort}" ]; then
		make_effort_record
	else
		make_session_record
	fi
	record_temp=$(mktemp "${record_path%/*}/.gate-record.XXXXXX" 2>/dev/null) ||
		deny_record "cannot create a temp file beside ${record_path}, which stays empty" 'make the Crucible space writable'
	if printf '%s\n' "${record}" >"${record_temp}" && mv -f "${record_temp}" "${record_path}"; then return 0; fi
	rm -f "${record_temp}"
	deny_record "the write to ${record_path} failed, and it stays empty" 'make the Crucible space writable'
}

# Sources the crucible skill's space rules, or denies.
load_space_lib() {
	[ -f "${SPACE_LIB}" ] && [ -r "${SPACE_LIB}" ] ||
		deny_record "the space rules are missing at ${SPACE_LIB}" 'install the crucible skill'
	# shellcheck source=../../../../engine/crucible/scripts/lib/crucible-space.sh
	. "${SPACE_LIB}"
}

# Sets record_label and record_effort from the gate's target file, in the
# format open-gate.sh --help states, or denies.
read_target() {
	target_file="${gate_dir}/target"
	open_again='open the gate again through open-gate.sh --label LABEL [--effort FOLDER]'
	[ -f "${target_file}" ] && [ ! -L "${target_file}" ] ||
		deny_record "no target file at ${target_file}" "${open_again}"
	label_line='' effort_line=''
	{
		IFS= read -r label_line || true
		IFS= read -r effort_line || true
	} <"${target_file}"
	record_label=${label_line#label }
	record_effort=${effort_line#effort }
	if [ "${record_label}" = "${label_line}" ] || [ "${record_effort}" = "${effort_line}" ]; then
		deny_record "${target_file} is not a label line then an effort line" "${open_again}"
	fi
	# shellcheck disable=SC2310 # a pure test; its status is the answer
	crucible_is_label "${record_label}" ||
		deny_record "${target_file} names a bad label (${crucible_label_problem})" "${open_again}"
}

# Sets record_path to a new empty file crucible.sh new made in the effort's
# cache/gates/, or denies.
make_effort_record() {
	[ -f "${CRUCIBLE_HELPER}" ] ||
		deny_record "crucible.sh missing at ${CRUCIBLE_HELPER}" 'install the crucible skill'
	if record_path=$(sh "${CRUCIBLE_HELPER}" new --kind cache/gates --label "${record_label}" --effort "${record_effort}" </dev/null); then
		new_status=0
	else
		new_status=$?
	fi
	[ "${new_status}" -eq 0 ] ||
		deny_record "crucible.sh new failed (exit ${new_status}; its stderr is above)" 'fix what crucible.sh names, such as the effort folder or CRUCIBLE_HOME'
	case ${record_path} in
		/*.json) ;;
		*) deny_record 'crucible.sh new printed no file path' 'reinstall the crucible skill' ;;
	esac
}

# Sets record_path to a new empty file in the session's gate folder,
# records/, named as a Crucible item, or denies.
make_session_record() {
	records_dir="${gate_dir}/records"
	[ ! -L "${records_dir}" ] || deny_record "${records_dir} is a symbolic link" 'remove the link'
	mkdir -p "${records_dir}" 2>/dev/null && [ ! -L "${records_dir}" ] ||
		deny_record "cannot create ${records_dir}" 'make the gate folder writable'
	# shellcheck disable=SC2310 # its status says whether a file was made; the fault is read below
	if crucible_claim_item_file "${records_dir}" "${record_label}" cache/gates; then
		record_path=${crucible_claimed_file}
		return 0
	fi
	[ "${crucible_claim_fault}" != id ] || deny_record "no record ID: ${crucible_claim_problem}" 'fix the tool it names'
	deny_record "no record file: ${crucible_claim_problem}" 'make the gate folder writable'
}

# Removes the gate's own files, and its folder once nothing else is left in
# it; records/ stays.
clear_gate() {
	rm -f "${gate_dir}/state" "${gate_dir}/gate.md" "${gate_dir}/target" "${gate_dir}/plan.json"
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

# Sets gate_status from a live gate, or exits 0 when there is none: no state
# (an idle folder is removed), or a malformed or stale one (removed as
# remove_gate sets).
load_gate() {
	gate_dir="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/cache/approval-gate/$1"
	[ -f "${gate_dir}/state" ] || drop_idle_folder
	read -r gate_status tries created _ <"${gate_dir}/state" || true
	case ${gate_status-} in
		pending | relayed | shown | failed) ;;
		*) remove_gate 'malformed state' ;;
	esac
	case ${tries-}:${created-} in
		:* | *: | *[!0-9:]* | *:*:*) remove_gate 'malformed state' ;;
		*) ;;
	esac
	now=$(date +%s)
	[ $((now - created)) -le "${STALE_SECONDS}" ] || remove_gate 'stale gate'
}

case ${1-} in
	--help | -h)
		usage
		exit 0
		;;
	*) ;;
esac

command -v jq >/dev/null 2>&1 || handle_jq_missing
hook_input=$(cat)
# Fields: the caller ("main", or "agent" when agent_id is set), session_id and
# tool_name, a non-string one as "" so the fields never shift; none holds a
# space once checked.
fields=$(printf '%s' "${hook_input}" | jq -r '[(if (.agent_id // "") == "" then "main" else "agent" end), ((.session_id | strings) // ""), ((.tool_name | strings) // "")] | join(" ")')
caller=${fields%% *}
fields=${fields#* }
session_id=${fields%% *}
tool_name=${fields#* }
[ "${tool_name}" = AskUserQuestion ] || exit 0
# A subagent's or side agent's question carries the parent's session_id plus
# its own agent_id; only the main thread's question may close the gate.
[ "${caller}" = main ] || exit 0
case ${session_id} in
	'' | . | .. | *[!A-Za-z0-9._-]*) exit 0 ;;
	*) ;;
esac
load_gate "${session_id}"
if [ "${gate_status}" != pending ]; then
	if [ "${gate_status}" = relayed ]; then save_gate_record; fi
	clear_gate
	exit 0
fi

# A pending gate is loaded: from here any failure denies the question (exit 2).
# An EXIT trap, not set -E with ERR, so it works in dash too.
trap 'printf "%s internal error in %s with a pending gate, so the question is denied; the question is allowed once the gate is relayed, or %s minutes after it opened.\n" "${REASON_PREFIX}" "${PROG}" "${STALE_MINUTES}" >&2; exit 2' EXIT
deny=$(jq -cn --arg reason "${DENY_REASON}" \
	'{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}')
printf '%s\n' "${deny}"
trap - EXIT
exit 0
