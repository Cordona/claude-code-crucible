#!/usr/bin/env sh
# Claude Code PreToolUse hook (matcher AskUserQuestion) for approval gates. It
# denies the question while this session's gate is pending, so the plan is
# relayed before it is asked about, and clears any other gate as its question
# goes out. A fault allows the question, except once a pending gate is loaded,
# or when jq is missing and any session has a live pending gate: then it fails
# closed, since that block is confined to an open gate and ends when the gate
# goes stale.
set -eu
trap 'exit 0' EXIT

readonly PROG='gate-question-hook.sh'
readonly REASON_PREFIX='procedure-approval-gate:'
# 30 min, as in gate-stop-hook.sh: long enough to read a plan, short enough that
# a gate left open by a crashed or abandoned turn soon stops denying questions.
readonly STALE_SECONDS=1800
readonly STALE_MINUTES=$((STALE_SECONDS / 60))
readonly DENY_REASON="${REASON_PREFIX} this session's gate is pending: its plan has not been relayed as a turn's last message yet, so the question is denied."

usage() {
	cat <<EOF
Usage: sh ${PROG} < pre-tool-use-input.json

A Claude Code PreToolUse hook for the AskUserQuestion tool. It reads the hook
JSON on stdin (session_id, tool_name, tool_input, ...) and the gate state
open-gate.sh wrote in
  \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/cache/approval-gate/<session_id>/
  - no gate, or a malformed gate or one older than ${STALE_SECONDS}s (removed
    with its folder, plan.json included): allows the question
  - no gate state, and a plan.json there older than ${STALE_SECONDS}s: removes
    the folder, allows the question
  - pending: prints a PreToolUse deny decision, exit 0:
    {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny",
     "permissionDecisionReason":"${DENY_REASON}"}}
  - relayed, shown or failed: removes the gate folder, plan.json included,
    allows the question
A tool_name other than AskUserQuestion is allowed untouched.

Exit codes:
  0  allowed, or denied through the JSON above; a hook fault before a pending
     gate is loaded also allows (a note goes to stderr)
  2  denied with the reason on stderr (starting "${REASON_PREFIX}"): an internal
     error after a pending gate was loaded, or jq missing while some session
     has a pending gate younger than ${STALE_SECONDS}s

Dependencies: POSIX sh, jq 1.6+, cat, date, find (with -mmin, as on macOS and
Linux), rm.
Runtime: about 13 ms with no gate, 20 ms denying; measured on macOS (average of 5 runs).
EOF
}

warn() {
	printf '%s: %s\n' "${PROG}" "$1" >&2
}

# Removes the gate folder (reason $1 goes to stderr) and allows the question.
remove_gate() {
	warn "$1 removed: ${gate_dir}"
	rm -rf "${gate_dir}"
	exit 0
}

# With no gate state, removes the folder when its plan.json is older than
# STALE_SECONDS; allows the question either way.
drop_stale_plan() {
	old_plan=$(find "${gate_dir}/plan.json" -prune -type f -mmin "+${STALE_MINUTES}" 2>/dev/null) || exit 0
	[ -z "${old_plan}" ] || remove_gate 'stale plan.json with no gate state'
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

# Sets gate_status from a live gate, or exits 0 when there is none: no state
# (a stale plan.json alone is removed), a malformed or stale one (both removed).
load_gate() {
	gate_dir="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/cache/approval-gate/$1"
	[ -f "${gate_dir}/state" ] || drop_stale_plan
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
fields=$(printf '%s' "${hook_input}" | jq -r '[(.session_id // "" | strings), (.tool_name // "" | strings)] | join(" ")')
session_id=${fields% *}
tool_name=${fields#* }
[ "${tool_name}" = AskUserQuestion ] || exit 0
case ${session_id} in
	'' | . | .. | *[!A-Za-z0-9._-]*) exit 0 ;;
	*) ;;
esac
load_gate "${session_id}"
if [ "${gate_status}" != pending ]; then
	rm -rf "${gate_dir}"
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
