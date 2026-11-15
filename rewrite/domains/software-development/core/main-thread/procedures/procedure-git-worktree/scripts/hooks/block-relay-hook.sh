#!/usr/bin/env sh
# Claude Code's async SubagentStop hook (asyncRewake) beside report-commit-hook.sh. A
# developer that hands back with SubagentHandback has ended before report-commit-hook.sh
# blocks its stop, so it never sees the block. This hook waits for
# report-commit-hook.sh's stop.blocked or stop.gave-up event for the same
# hook event, or for the seat to leave working, and, for such a
# developer only, wakes the main thread with the exact line to send it, or,
# on a give-up, with what happened; flow-code-development step 4 owns what
# the human is shown. Every other stop ends here silently.
set -eu
umask 077

readonly PROG='block-relay-hook.sh'
# report-commit-hook.sh's outcome for the event is awaited at most this many half-seconds.
readonly WAIT_TICKS=240
readonly WAKE_EXIT=2
readonly CRUCIBLE_SKILL='crucible'
LC_ALL=C
export LC_ALL

usage() {
	cat <<EOF
usage: sh ${PROG}
       sh ${PROG} --help | -h

Claude Code's SubagentStop hook, registered async with asyncRewake, beside
report-commit-hook.sh. Reads the event JSON on stdin; finds the agent's
seat with events.sh find-agent, and goes on only for a developer seat that
seats.sh get shows holding the agent, when the agent's transcript
(agent_transcript_path) ends in a SubagentHandback call. Then waits up to
$((WAIT_TICKS / 2)) s for report-commit-hook.sh's newest stop.blocked or
stop.gave-up event of the agent whose body.hook_event is this event's id
(the cksum of the event JSON), and ends the wait at once when seats.sh get
shows the seat no longer working (a recorded build sets it idle, a give-up
gave-up), reading the events once more.

  blocked     prints to stderr the line to send the agent, the line's
              reason, and exits ${WAKE_EXIT}: Claude Code wakes the main thread
              with it
  gave-up     prints to stderr that the developer gave up, its seat and
              worktree, for flow-code-development step 4's gave-up
              handling; exits ${WAKE_EXIT}
  no line     once the seat is not working, or at the end of the wait (any
              fault): exits 0, silent

writes: nothing

exit codes:
  0  nothing for the main thread, whatever the reason
  1  wrong command line
  ${WAKE_EXIT}  the main thread has a line to act on (stderr)

needs: POSIX sh, jq 1.6+, cksum; ../seats/seats.sh from this script's
folder; the ${CRUCIBLE_SKILL} skill's events.sh
EOF
}

warn() {
	printf '%s: %s\n' "${PROG}" "$1" >&2
}

usage_error() {
	warn "$1"
	printf "Try 'sh %s --help'.\n" "${PROG}" >&2
	exit 1
}

parse_args() {
	while [ "$#" -gt 0 ]; do
		case $1 in
			-h | --help)
				usage
				exit 0
				;;
			*)
				shown_option=$(printf '%s' "$1" | tr '[:cntrl:]' '?')
				usage_error "unknown option: ${shown_option}; expected --help"
				;;
		esac
	done
}

# Nothing for the main thread.
quiet() {
	exit 0
}

script_dir() {
	case $0 in
		*/*) printf '%s' "${0%/*}" ;;
		*) printf '.' ;;
	esac
}

find_events_script() {
	events_script="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/skills/${CRUCIBLE_SKILL}/scripts/events.sh"
	[ -f "${events_script}" ] || quiet
}

read_event() {
	command -v jq >/dev/null 2>&1 || quiet
	cat >"${work_dir}/event" || quiet
	event_id=$(cksum <"${work_dir}/event" | cut -d ' ' -f 1) || quiet
	agent_id=$(jq -r 'if type == "object" then .agent_id // empty | strings else empty end' "${work_dir}/event" 2>/dev/null) || quiet
	transcript=$(jq -r '.agent_transcript_path // empty | strings' "${work_dir}/event" 2>/dev/null) || quiet
	case ${agent_id} in
		'' | *[!a-z0-9_-]*) quiet ;;
		*) ;;
	esac
}

# Sets effort, seat and worktree from the developer seat holding agent_id.
find_seat() {
	found=$(sh "${events_script}" find-agent --agent-id "${agent_id}" 2>/dev/null </dev/null) || quiet
	case ${found} in
		*"	"*) ;;
		*) quiet ;;
	esac
	effort=${found%%"	"*}
	seat=${found#*"	"}
	seat_json=$(sh "${own_dir}/../seats/seats.sh" get --effort "${effort}" --seat "${seat}" 2>/dev/null </dev/null) || quiet
	worktree=$(printf '%s\n' "${seat_json}" |
		jq -r --arg agent "${agent_id}" 'select(.role == "developer" and .agent_id == $agent) | .worktree // ""') || quiet
	[ -n "${worktree}" ] || quiet
}

# Goes on only when the agent's last assistant entry is a SubagentHandback
# call: its run is over, so a block can't reach it.
require_handback() {
	[ -n "${transcript}" ] && [ -f "${transcript}" ] || quiet
	last=$(jq -c 'select(.type == "assistant") | [.message.content[]? | select(.type == "tool_use") | .name]' \
		"${transcript}" 2>/dev/null | tail -n 1) || quiet
	case ${last} in
		*'"SubagentHandback"'*) ;;
		*) quiet ;;
	esac
}

# Sets outcome to the stop event report-commit-hook.sh wrote for this hook
# event: blocked or gave-up. A seat no longer working has had its stop
# handled; report-commit-hook.sh writes the stop event before it changes the
# status, so one more read finds it.
await_outcome() {
	ticks=0
	while [ "${ticks}" -lt "${WAIT_TICKS}" ]; do
		outcome=$(stop_field outcome)
		[ -z "${outcome}" ] || return 0
		# shellcheck disable=SC2310 # its status is the test result; errexit adds nothing
		if ! seat_is_working; then
			outcome=$(stop_field outcome)
			[ -n "${outcome}" ] || quiet
			return 0
		fi
		sleep 0.5
		ticks=$((ticks + 1))
	done
	quiet
}

# Succeeds while seats.sh get shows the seat working; a seat seats.sh can't
# read counts as working, so the wait goes on to its end.
seat_is_working() {
	seat_status=$(sh "${own_dir}/../seats/seats.sh" get --effort "${effort}" --seat "${seat}" 2>/dev/null </dev/null |
		jq -r '.status // empty | strings' 2>/dev/null) || return 0
	[ -z "${seat_status}" ] || [ "${seat_status}" = working ]
}

# Prints, of the newest stop event of this hook event and agent, its outcome
# ($1 outcome: blocked or gave-up) or its body's reason ($1 reason); nothing
# when there is none or the events can't be read.
stop_field() {
	sh "${events_script}" slurp --effort "${effort}" --type 'stop.*' 2>/dev/null </dev/null |
		jq -r --arg e "${event_id}" --arg a "${agent_id}" --arg field "$1" \
			'[.[] | select(.body.hook_event == $e and .body.agent_id == $a)] | last // empty
			| if $field == "outcome" then .type | ltrimstr("stop.") else .body.reason // empty | strings end' 2>/dev/null || :
}

wake() {
	case ${outcome} in
		blocked)
			reason=$(stop_field reason)
			[ -n "${reason}" ] || quiet
			printf '%s\n' "Crucible: the developer in ${seat} handed back, then its stop was blocked; it never saw why and nothing was committed, so its result above is not final. Send agent ${agent_id} exactly the text between the --- lines with SendMessage, then wait for its result:" '---' "${reason}" '---' >&2
			;;
		gave-up)
			printf '%s\n' "Crucible: the developer in ${seat} failed its report check 3 times; nothing was committed in its worktree ${worktree}. Act on seat ${seat} as flow-code-development step 4 does for gave-up." >&2
			;;
		*) quiet ;;
	esac
	exit "${WAKE_EXIT}"
}

# shellcheck disable=SC2329 # invoked by the EXIT trap
on_exit() {
	exit_status=$?
	[ -z "${work_dir}" ] || rm -rf -- "${work_dir}"
	exit "${exit_status}"
}

work_dir='' effort='' seat='' worktree='' outcome=''
trap on_exit EXIT
parse_args "$@"
own_path=$(script_dir)
own_dir=$(cd -P -- "${own_path}" && pwd -P) || quiet
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/crucible-block-relay.XXXXXX") || {
	work_dir=''
	quiet
}
read_event
find_events_script
find_seat
require_handback
await_outcome
wake
