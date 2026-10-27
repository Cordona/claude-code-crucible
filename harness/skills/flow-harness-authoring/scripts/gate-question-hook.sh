#!/usr/bin/env sh
# Claude Code PreToolUse hook (matcher AskUserQuestion) for
# flow-harness-authoring gates. It denies the question while this session's
# gate is pending, so the view is relayed before it is asked about, and
# closes the gate in any other state as its question goes out. A fault allows
# the question, except once a pending gate is loaded, or when jq is missing
# and this session has a live pending gate: then it fails closed, since that
# block is confined to an open gate and ends when the gate goes stale.
set -eu
trap 'exit 0' EXIT

readonly PROG='gate-question-hook.sh'
readonly PREFIX='flow-harness-authoring:'
# 30 min, as in gate-stop-hook.sh: long enough to read a view, short enough
# that a gate left open by a crashed or abandoned turn soon stops denying
# questions.
readonly STALE_SECONDS=1800
readonly STALE_MINUTES=$((STALE_SECONDS / 60))
readonly DENY_REASON="${PREFIX} this session's gate is pending: its view has not been relayed as a turn's last message yet, so the question is denied; relay the gate text alone as the turn's last message, then ask."

# Prints the top-level session_id of the hook JSON on stdin, when it is a
# string of safe folder-name characters, and nothing when an agent_id is set.
# Needs no jq: a key inside a JSON string is escaped (\"session_id\"), so the
# pattern only matches a real key.
# The program is single-quoted on purpose: its $ signs are awk's.
# shellcheck disable=SC2016
readonly SESSION_AWK='
{ input = input $0 "\n" }
END {
	if (match(input, /"agent_id"[ \t\r\n]*:[ \t\r\n]*"[^"]/)) exit 0
	if (!match(input, /"session_id"[ \t\r\n]*:[ \t\r\n]*"[A-Za-z0-9._-]+"/)) exit 0
	value = substr(input, RSTART, RLENGTH)
	sub(/^"session_id"[ \t\r\n]*:[ \t\r\n]*"/, "", value)
	sub(/"$/, "", value)
	print value
}
'

usage() {
	cat <<EOF
usage: sh ${PROG} < pre-tool-use-input.json
       sh ${PROG} --help | -h

A Claude Code PreToolUse hook for AskUserQuestion: denies the main thread's
question while this session's gate is pending (its view not yet relayed),
and closes this session's gate in any other state as the question goes out.
On a fault the question is allowed, unless a pending gate is open, or jq is
  missing and this session has a live pending gate: then exit 2.

stdin: the hook JSON (session_id, agent_id, tool_name); a tool_name other than
  AskUserQuestion, a non-empty agent_id (a subagent's question) or a missing,
  non-string or unsafe session_id is allowed untouched
Reads the gate state open-gate.sh wrote in
  \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/cache/harness-gate/<session_id>/

stdout on a deny (exit 0): one PreToolUse decision for Claude Code,
  {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"<reason>"}}
  <reason>: ${DENY_REASON}
stderr on exit 0: notes starting "${PREFIX}" on a removed gate or a
  missing jq, or a failing command's own message

Writes, in this session's gate folder only:
  - pending gate: nothing; the question is denied
  - relayed or failed gate: the folder is removed; the question is allowed
  - a malformed gate, a linked state, or one opened over ${STALE_MINUTES} minutes ago:
    the folder is removed; the question is allowed
  - no state: the folder is removed when nothing in it changed for
    ${STALE_MINUTES} minutes; the question is allowed
Never touched: a linked gate folder or its root.

Exit codes:
  0  allowed; or denied by the decision on stdout, which Claude Code applies,
     giving Claude its reason
  2  denied: Claude Code blocks the question and gives Claude the reason from
     stderr, starting "${PREFIX}"; the block ends at most ${STALE_MINUTES} minutes
     after the pending gate opened

Dependencies: POSIX sh, jq 1.6+ (macOS: brew install jq; Linux: the distro's
  jq package), awk, cat, date, find (with -mmin, as on macOS and Linux), rm.
EOF
}

warn() {
	printf '%s %s: %s\n' "${PREFIX}" "${PROG}" "$1" >&2
}

# Removes the gate folder (reason $1 goes to stderr) and allows the question.
remove_gate() {
	warn "$1 removed: ${gate_dir}"
	rm -rf "${gate_dir}"
	exit 0
}

# With no state, removes the folder when nothing in it (the folder included)
# changed within STALE_SECONDS; allows the question either way.
drop_idle_folder() {
	recent=$(find "${gate_dir}" ! -mmin "+${STALE_MINUTES}" 2>/dev/null) || exit 0
	[ -n "${recent}" ] || remove_gate "gate folder with no state, unchanged for over ${STALE_MINUTES} minutes,"
	exit 0
}

# Sets gate_dir to session $1's gate folder; false when it or its root is a
# symbolic link, or it is no folder.
find_gate_dir() {
	gate_root="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/cache/harness-gate"
	gate_dir="${gate_root}/$1"
	[ ! -L "${gate_root}" ] && [ ! -L "${gate_dir}" ] && [ -d "${gate_dir}" ]
}

# Sets gate_status from a live gate, or exits 0 when there is none: a linked
# root or folder (left as it is), no state (an idle folder is removed), or a
# malformed or stale gate (removed).
load_gate() {
	# shellcheck disable=SC2310 # its status is the answer; set -e is not needed inside
	find_gate_dir "$1" || exit 0
	[ ! -L "${gate_dir}/state" ] || remove_gate 'linked state'
	[ -f "${gate_dir}/state" ] || drop_idle_folder
	read -r gate_status tries created _ <"${gate_dir}/state" || true
	case ${gate_status-} in
		pending | relayed | failed) ;;
		*) remove_gate 'malformed state' ;;
	esac
	case ${tries-}:${created-} in
		:* | *: | *[!0-9:]* | *:*:* | 0?*:* | *:0?*) remove_gate 'malformed state' ;;
		*) ;;
	esac
	now=$(date +%s)
	[ $((now - created)) -le "${STALE_SECONDS}" ] || remove_gate 'stale gate'
}

# True when session $1 has a pending gate opened within STALE_SECONDS. Needs
# no jq.
has_live_pending() {
	# shellcheck disable=SC2310 # its status is the answer; set -e is not needed inside
	find_gate_dir "$1" || return 1
	pending_file="${gate_dir}/state"
	[ -f "${pending_file}" ] && [ ! -L "${pending_file}" ] || return 1
	read -r pending_status pending_tries pending_created _ <"${pending_file}" || true
	[ "${pending_status-}" = pending ] || return 1
	case ${pending_tries-}:${pending_created-} in
		:* | *: | *[!0-9:]* | *:*:* | 0?*:* | *:0?*) return 1 ;;
		*) ;;
	esac
	pending_now=$(date +%s) || return 1
	[ $((pending_now - pending_created)) -le "${STALE_SECONDS}" ]
}

# With jq missing, reads the session id with awk; that session's live pending
# gate blocks the question (exit 2); otherwise it is allowed (exit 0).
handle_jq_missing() {
	fallback_session=$(awk "${SESSION_AWK}") || fallback_session=''
	# shellcheck disable=SC2310 # its status is the answer; set -e is not needed inside
	if [ -n "${fallback_session}" ] && has_live_pending "${fallback_session}"; then
		printf '%s jq is missing and this session'"'"'s gate is pending, so the question is denied; the hooks need jq 1.6+.\n' "${PREFIX}" >&2
		trap - EXIT
		exit 2
	fi
	warn 'jq missing; no pending gate in this session; question allowed'
	exit 0
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
# A subagent's question carries the parent's session_id plus its own
# agent_id; only the main thread's question may close the gate.
[ "${caller}" = main ] || exit 0
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
trap 'printf "%s internal error in %s with a pending gate, so the question is denied; the question is allowed once the gate is relayed, or %s minutes after it opened.\n" "${PREFIX}" "${PROG}" "${STALE_MINUTES}" >&2; exit 2' EXIT
deny=$(jq -cn --arg reason "${DENY_REASON}" \
	'{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}')
printf '%s\n' "${deny}"
trap - EXIT
exit 0
