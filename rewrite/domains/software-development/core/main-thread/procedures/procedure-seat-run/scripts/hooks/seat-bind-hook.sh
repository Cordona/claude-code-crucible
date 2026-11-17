#!/usr/bin/env sh
# Claude Code's PostToolUse hook on Agent. It links a background agent, at its
# launch, to the seat its dispatch names: the Agent hook appended a
# dispatch.allowed event holding the call's tool_use_id, the one key both
# events of an Agent call share, and the seq of the dispatch.made event it
# allowed. PostToolUse can't undo a launch, so every outcome lets the call go
# on; only faults are written, as fault.raised events of the effort.
set -eu
umask 077

readonly PROG='seat-bind-hook.sh'
# A fault quotes at most this many bytes of a child's first stderr line.
readonly MAX_QUOTE_BYTES=200
readonly ALLOWED_EVENT='dispatch.allowed'
readonly DISPATCH_EVENT='dispatch.made'
# The C locale keeps the shell byte-wise; jq reads the JSON as UTF-8.
LC_ALL=C
export LC_ALL

usage() {
	cat <<EOF
usage: sh ${PROG}
       sh ${PROG} --help | -h

Claude Code's PostToolUse hook on Agent. Reads the event JSON on stdin; with
a tool_response.agentId and an effort of the space
\${CRUCIBLE_HOME:-\$HOME/.crucible}/efforts holding a ${ALLOWED_EVENT} event
whose body.tool_use_id is the call's (the crucible skill's events.sh latest),
reads that event's dispatch id and seq, then the ${DISPATCH_EVENT} event of
that seq, and runs
seats.sh bind --effort <effort> --seat <its seat> --agent-id <agentId>
--dispatch <id>, which appends seat.bound.
No agentId or no such event: not an effort dispatch, nothing done.

The dispatch is accepted only when the ${DISPATCH_EVENT} event of that seq is
in the same effort and its body.id is the ${ALLOWED_EVENT} event's dispatch.

writes, faults only: a fault.raised event of the effort (events.sh fault)
{what, tool_use_id, agent_id, dispatch}; a fault before the effort is known,
or when the event can't be written, goes to stderr. stdout: nothing.
The session of the hook input stamps the events when
CLAUDE_CODE_SESSION_ID is unset.

exit codes:
  0  done, whatever the outcome
  1  wrong command line (never 2: Claude Code reads 2 as a block)

needs: POSIX sh, jq 1.6+; ../seats/seats.sh from this script's folder; the
crucible skill's events.sh, in \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/skills
EOF
}

warn() {
	printf '%s: %s\n' "${PROG}" "$1" >&2
}

usage_error() {
	warn "$1"
	printf "Try 'sh %s --help'.\n" "${PROG}" >&2
	usage_failed=yes
	exit 1
}

# Prints $1 with each control character as "?", so a value can't split a line.
printable() {
	printf '%s' "$1" | tr '[:cntrl:]' '?'
}

parse_args() {
	while [ "$#" -gt 0 ]; do
		case $1 in
			-h | --help)
				usage
				exit 0
				;;
			*)
				shown_option=$(printable "$1")
				usage_error "unknown option: ${shown_option}; expected --help"
				;;
		esac
	done
}

# Lets the call go on.
finish() {
	exit 0
}

# Writes fault $1 as a fault.raised event of the effort, with the call's
# tool_use_id, agent id and dispatch id; stderr while no effort is known or
# when the event can't be written.
log_fault() {
	if [ -z "${effort_dir}" ] || [ -z "${work_dir}" ]; then
		warn "fault: $1"
		return 0
	fi
	if jq -n --arg what "$1" --arg tool_use_id "${tool_use_id}" --arg agent_id "${shown_agent}" --arg dispatch "${shown_dispatch}" \
		'{what: $what, tool_use_id: $tool_use_id, agent_id: $agent_id, dispatch: $dispatch}
		| with_entries(select(.value != ""))' >"${work_dir}/fault.json" 2>/dev/null &&
		sh "${events_script}" fault --effort "${effort_dir}" --by "${PROG}" --body-file "${work_dir}/fault.json" \
			</dev/null >/dev/null 2>&1; then
		return 0
	fi
	warn "could not write a fault.raised event of ${effort_dir}: fault: $1"
}

fault() {
	log_fault "$1"
	finish
}

# Runs a command, its stdout in a file, its stderr in a file, its exit code
# in child_rc; never stops the script.
run() {
	child_rc=0
	"$@" >"${work_dir}/stdout" 2>"${work_dir}/stderr" || child_rc=$?
}

script_dir() {
	case $0 in
		*/*) printf '%s' "${0%/*}" ;;
		*) printf '.' ;;
	esac
}

# Sets agent_id, tool_use_id and hook_session from the event on stdin; an
# event without an agentId is no background launch, so nothing is done.
read_event() {
	command -v jq >/dev/null 2>&1 || {
		warn 'jq not found; expected jq 1.6+ on PATH; no seat bound'
		finish
	}
	cat >"${work_dir}/event" || {
		warn 'stdin could not be read; no seat bound'
		finish
	}
	fields=$(jq -r 'if type == "object" then
			(.tool_response.agentId? // "" | strings), (.tool_use_id // "" | strings), (.session_id // "" | strings)
		else empty end' "${work_dir}/event" 2>/dev/null) || {
		warn 'stdin is not one JSON object; expected the PostToolUse event; no seat bound'
		finish
	}
	agent_id='' tool_use_id='' hook_session=''
	{
		IFS= read -r agent_id || :
		IFS= read -r tool_use_id || :
		IFS= read -r hook_session || :
	} <<EOF
${fields}
EOF
	[ -n "${agent_id}" ] || finish
	shown_agent=$(printable "${agent_id}")
	case ${tool_use_id} in
		'' | *[!A-Za-z0-9_-]*)
			shown_id=$(printable "${tool_use_id}")
			tool_use_id=''
			warn "tool_use_id '${shown_id}' is not letters, digits, _ and -; expected Claude Code's id; no seat bound"
			finish
			;;
		*) ;;
	esac
	stamp_session
}

# Exports the hook input's session as CLAUDE_CODE_SESSION_ID for the events
# seats.sh and events.sh append, when the environment names none: it stamps
# the events' provenance and grants nothing.
stamp_session() {
	[ -z "${CLAUDE_CODE_SESSION_ID:-}" ] || return 0
	case ${hook_session} in
		*[!0-9a-f-]* | '') return 0 ;;
		*) [ "${#hook_session}" -eq 36 ] || return 0 ;;
	esac
	CLAUDE_CODE_SESSION_ID=${hook_session}
	export CLAUDE_CODE_SESSION_ID
}

# Sets efforts to the space's efforts folder; a space that can't be named
# holds no effort dispatch.
resolve_efforts() {
	if [ -n "${CRUCIBLE_HOME:-}" ]; then
		root=${CRUCIBLE_HOME}
	elif [ -n "${HOME:-}" ]; then
		root="${HOME}/.crucible"
	else
		warn 'neither CRUCIBLE_HOME nor HOME is set; expected one to name the space; no seat bound'
		finish
	fi
	case ${root} in
		/*) ;;
		*)
			shown_root=$(printable "${root}")
			warn "the space ${shown_root} is not absolute; expected CRUCIBLE_HOME absolute; no seat bound"
			finish
			;;
	esac
	while [ "${root}" != "${root%/}" ]; do root=${root%/}; done
	efforts="${root}/efforts"
}

# Sets effort_dir and allowed_event from the first effort whose newest
# dispatch.allowed event of tool_use_id events.sh latest finds; none: not an
# effort dispatch. The id holds only letters, digits, _ and -, so it is safe
# inside the jq string.
find_allowed() {
	events_script="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/skills/crucible/scripts/events.sh"
	[ -f "${events_script}" ] || {
		warn "events.sh missing; expected ${events_script}; no seat bound"
		finish
	}
	for candidate_dir in "${efforts}"/*/; do
		candidate_dir=${candidate_dir%/}
		[ ! -L "${candidate_dir}" ] || continue
		set -- "${candidate_dir}"/events/[0-9][0-9][0-9][0-9][0-9][0-9]-"${ALLOWED_EVENT}".json
		[ -f "$1" ] || continue
		found=$(sh "${events_script}" latest --effort "${candidate_dir}" --type "${ALLOWED_EVENT}" \
			--where ".body.tool_use_id == \"${tool_use_id}\"" </dev/null 2>/dev/null) || continue
		[ -n "${found}" ] || continue
		effort_dir=${candidate_dir} allowed_event=${found}
		return 0
	done
	finish
}

# Sets dispatch_id and dispatch_seq from the dispatch.allowed event, then seat
# from the dispatch.made event of that seq in the same effort, whose id must
# be dispatch_id.
read_dispatch() {
	allowed_fields=$(jq -r '(.body.dispatch // "" | strings), (.body.seq // "" | numbers | tostring)' "${allowed_event}" 2>/dev/null) ||
		fault "jq could not read ${allowed_event}; expected the ${ALLOWED_EVENT} event"
	dispatch_id='' dispatch_seq=''
	{
		IFS= read -r dispatch_id || :
		IFS= read -r dispatch_seq || :
	} <<EOF
${allowed_fields}
EOF
	shown_dispatch=$(printable "${dispatch_id}")
	case ${dispatch_seq} in
		'' | 0* | *[!0-9]*) fault "${allowed_event##*/} holds no dispatch seq; expected a whole number from 1" ;;
		*) ;;
	esac
	[ -n "${dispatch_id}" ] || fault "${allowed_event##*/} holds no dispatch id; expected the ${DISPATCH_EVENT} body's id"
	run sh "${events_script}" latest --effort "${effort_dir}" --type "${DISPATCH_EVENT}" --where ".seq == ${dispatch_seq}"
	[ "${child_rc}" -eq 0 ] || fault "events.sh latest exit ${child_rc} reading the ${DISPATCH_EVENT} of seq ${dispatch_seq}"
	dispatch_event=$(cat "${work_dir}/stdout")
	[ -n "${dispatch_event}" ] || fault "no ${DISPATCH_EVENT} event of seq ${dispatch_seq} in the effort; expected the one ${allowed_event##*/} allowed"
	ids=$(jq -r '(.body.id // "" | strings), (.body.seat // "" | strings)' "${dispatch_event}" 2>/dev/null) ||
		fault "jq could not read ${dispatch_event##*/}; expected the ${DISPATCH_EVENT} event"
	made_id='' seat=''
	{
		IFS= read -r made_id || :
		IFS= read -r seat || :
	} <<EOF
${ids}
EOF
	shown_made_id=$(printable "${made_id}")
	[ "${made_id}" = "${dispatch_id}" ] || fault "${dispatch_event##*/} holds dispatch ${shown_made_id}; expected ${shown_dispatch}, the one ${allowed_event##*/} allowed"
	[ -n "${seat}" ] || fault "${dispatch_event##*/} names no seat; expected the dispatch's seat"
	seat=$(printable "${seat}")
}

bind_seat() {
	run sh "${own_dir}/../seats/seats.sh" bind --effort "${effort_dir}" --seat "${seat}" \
		--agent-id "${agent_id}" --dispatch "${dispatch_id}"
	[ "${child_rc}" -ne 0 ] || finish
	first_line=$(head -n 1 "${work_dir}/stderr" | cut -c "1-${MAX_QUOTE_BYTES}") || first_line=''
	shown_line=$(printable "${first_line}")
	fault "seats.sh bind exit ${child_rc}: ${shown_line}"
}

# An unexpected failure lets the call go on too, as a fault.
# shellcheck disable=SC2329 # invoked by the EXIT trap
on_exit() {
	exit_status=$?
	[ "${exit_status}" -eq 0 ] || [ "${usage_failed}" = yes ] || log_fault "unexpected exit ${exit_status}"
	[ -z "${work_dir}" ] || rm -rf -- "${work_dir}"
	[ "${exit_status}" -eq 0 ] || [ "${usage_failed}" = yes ] || exit 0
}

work_dir='' usage_failed=no effort_dir='' seat='' tool_use_id='' shown_agent='' shown_dispatch='' events_script=''
trap on_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

parse_args "$@"
own_path=$(script_dir)
own_dir=$(cd -P -- "${own_path}" && pwd -P) || {
	warn 'this script'\''s folder could not be entered; no seat bound'
	finish
}
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/crucible-seat-bind.XXXXXX") || {
	warn 'mktemp could not create a work folder; expected a writable TMPDIR; no seat bound'
	work_dir=''
	finish
}
read_event
resolve_efforts
find_allowed
read_dispatch
bind_seat
