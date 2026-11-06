#!/usr/bin/env sh
# Claude Code's async SubagentStop hook (asyncRewake) beside report-commit-hook.sh. A
# developer that hands back with SubagentHandback has ended before report-commit-hook.sh
# blocks its stop, so it never sees the block. This hook waits for
# report-commit-hook.sh's outcome for the same event and, for such a developer only,
# wakes the main thread with the exact line to send it, or, on a give-up, the
# line to show the human. Every other stop ends here silently.
set -eu
umask 077

readonly PROG='block-relay-hook.sh'
# report-commit-hook.sh's outcome for the event is awaited this many half-seconds.
readonly WAIT_TICKS=240
readonly WAKE_EXIT=2
LC_ALL=C
export LC_ALL

usage() {
	cat <<EOF
usage: sh ${PROG} [--efforts DIR]
       sh ${PROG} --help | -h

Claude Code's SubagentStop hook, registered async with asyncRewake, beside
report-commit-hook.sh. Reads the event JSON on stdin; finds the agent's developer seat
with slots.sh find in each DIR/*/slots.json; goes on only when the agent's
transcript (agent_transcript_path) ends in a SubagentHandback call. Then waits
up to $((WAIT_TICKS / 2)) s for report-commit-hook.sh's line for the same event in
DIR/<effort>/logs/report-commit.log (the event id: the cksum of the event JSON).

  blocked N   prints to stderr the line to send the agent, the reason from
              the worktree's .crucible-effort/logs/<slot>/report-commit.jsonl,
              and exits ${WAKE_EXIT}: Claude Code wakes the main thread with it
  gave-up     prints to stderr the line to show the human; exits ${WAKE_EXIT}
  any other   exits 0, silent

--efforts DIR  absolute path of the efforts folder; default
               \${CRUCIBLE_HOME:-\$HOME/.crucible}/efforts

writes: nothing

exit codes:
  0  nothing for the main thread, whatever the reason
  1  wrong command line
  ${WAKE_EXIT}  the main thread has a line to act on (stderr)

needs: POSIX sh, jq 1.6+, cksum; ../seats/slots.sh from this script's folder
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
	efforts=''
	while [ "$#" -gt 0 ]; do
		case $1 in
			-h | --help)
				usage
				exit 0
				;;
			--efforts)
				[ -n "${2-}" ] || usage_error '--efforts needs a value; expected --efforts DIR'
				[ -z "${efforts}" ] || usage_error '--efforts given twice; expected one'
				efforts=$2
				shift 2
				;;
			*) usage_error "unknown option: $(printf '%s' "$1" | tr '[:cntrl:]' '?'); expected --efforts or --help" ;;
		esac
	done
	case ${efforts} in
		'' | /*) ;;
		*) usage_error '--efforts is not absolute; expected an absolute path' ;;
	esac
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

resolve_efforts() {
	[ -z "${efforts}" ] || return 0
	root=${CRUCIBLE_HOME:-${HOME:-}/.crucible}
	case ${root} in
		/*) ;;
		*) quiet ;;
	esac
	while [ "${root}" != "${root%/}" ]; do root=${root%/}; done
	efforts="${root}/efforts"
}

read_event() {
	command -v jq >/dev/null 2>&1 || quiet
	cat >"${work_dir}/event" || quiet
	event_id=$(cksum <"${work_dir}/event" | cut -d ' ' -f 1) || quiet
	agent_id=$(jq -r 'if type == "object" then .agent_id // empty | strings else empty end' "${work_dir}/event" 2>/dev/null) || quiet
	transcript=$(jq -r '.agent_transcript_path // empty | strings' "${work_dir}/event" 2>/dev/null) || quiet
	case ${agent_id} in
		'' | *[!A-Za-z0-9_-]*) quiet ;;
		*) ;;
	esac
}

# Sets effort_dir, slot and worktree from the developer seat holding agent_id.
find_seat() {
	for candidate in "${efforts}"/*/slots.json; do
		[ -f "${candidate}" ] || continue
		[ ! -L "${candidate%/slots.json}" ] || continue
		seat=$(sh "${own_dir}/../seats/slots.sh" find --slots "${candidate}" --agent-id "${agent_id}" 2>/dev/null) || continue
		fields=$(printf '%s\n' "${seat}" | jq -r 'select(.role == "developer") | .slot, .worktree // ""') || quiet
		[ -n "${fields}" ] || quiet
		effort_dir=${candidate%/slots.json}
		slot=$(printf '%s\n' "${fields}" | sed -n 1p)
		worktree=$(printf '%s\n' "${fields}" | sed -n 2p)
		return 0
	done
	quiet
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

# Sets outcome to report-commit-hook.sh's outcome for this event.
await_outcome() {
	log="${effort_dir}/logs/report-commit.log"
	ticks=0
	while [ "${ticks}" -lt "${WAIT_TICKS}" ]; do
		line=$(awk -v a="${agent_id}" -v e="${event_id}" '$3 == a && $4 == e { l = $0 } END { print l }' "${log}" 2>/dev/null) || line=''
		if [ -n "${line}" ]; then
			outcome=$(printf '%s\n' "${line}" | cut -d ' ' -f 5 | tr -d ':')
			return 0
		fi
		sleep 0.5
		ticks=$((ticks + 1))
	done
	quiet
}

# Prints the reason report-commit-hook.sh recorded for this event.
seat_reason() {
	jq -rs --arg e "${event_id}" 'map(select(.event == $e)) | last | .reason // empty' \
		"${worktree}/.crucible-effort/logs/${slot}/report-commit.jsonl" 2>/dev/null
}

wake() {
	case ${outcome} in
		blocked)
			reason=$(seat_reason)
			[ -n "${reason}" ] || quiet
			printf '%s\n' "Crucible: the developer in ${slot} handed back, then its stop was blocked; it never saw why and nothing was committed, so its result above is not final. Send agent ${agent_id} exactly the text between the --- lines with SendMessage, then wait for its result:" '---' "${reason}" '---' >&2
			;;
		gave-up)
			printf '%s\n' "Crucible: the developer in ${slot} failed its report check 3 times; nothing was committed. Show the human exactly this line: The developer in ${slot} could not write a valid report; its work stays uncommitted in ${worktree}." >&2
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

work_dir='' effort_dir='' slot='' worktree='' outcome=''
trap on_exit EXIT
parse_args "$@"
own_dir=$(cd -P -- "$(script_dir)" && pwd -P) || quiet
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/crucible-block-relay.XXXXXX") || {
	work_dir=''
	quiet
}
read_event
resolve_efforts
find_seat
require_handback
await_outcome
wake
