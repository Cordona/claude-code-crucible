#!/usr/bin/env sh
# Claude Code's PostToolUse hook on Agent. It links a background agent, at its
# launch, to the seat its dispatch names: the Agent hook left the dispatch path
# in <effort>/pending/<tool_use_id>, the one key both events of an Agent call
# share. PostToolUse can't undo a launch, so every outcome lets the call go on;
# only faults are written, to the seat folder's faults log.
set -eu
umask 077

readonly PROG='seat-bind-hook.sh'
# A fault line quotes at most this many bytes of a child's first stderr line.
readonly MAX_QUOTE_BYTES=200
readonly FAULTS='bind-hook-faults.log'
# The C locale keeps the shell byte-wise; jq reads the JSON as UTF-8.
LC_ALL=C
export LC_ALL

usage() {
	cat <<EOF
usage: sh ${PROG} [--efforts DIR]
       sh ${PROG} --help | -h

Claude Code's PostToolUse hook on Agent. Reads the event JSON on stdin; with
a tool_response.agentId and a DIR/*/pending/<tool_use_id> file, reads the
dispatch path in it, then that dispatch's id and seat, and runs
seats.sh bind --seats <effort>/seats.json --seat <seat> --agent-id <agentId>
--dispatch <id>. The pending file is removed whatever bind's outcome.
No agentId or no pending file: not an effort dispatch, nothing done.

The dispatch path is accepted only when, symlinks resolved, it is
<effort>/worktrees/<worktree>/.crucible/seats/<seat>/dispatch-<ID>.json,
<effort> the pending file's own, not itself a link, and the dispatch's id
is <ID> and its seat <seat>.

--efforts DIR  absolute path of the efforts folder; default
               \${CRUCIBLE_HOME:-\$HOME/.crucible}/efforts

writes, faults only: <seat folder>/${FAULTS}, one line per fault (UTC
time, tool_use_id, agent id, the dispatch ID its file name holds, fault:
<what failed>); a fault before the
dispatch path is accepted, or when the file can't be written, goes to
stderr. Nothing is written through a symbolic link: a link at the faults
log, or at a folder from the worktree's .crucible down to it, is named on
stderr and the fault goes there too. stdout: nothing.

exit codes:
  0  done, whatever the outcome
  1  wrong command line (never 2: Claude Code reads 2 as a block)

needs: POSIX sh, jq 1.6+; ../seats/seats.sh from this script's folder
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
			*)
				shown_option=$(printable "$1")
				usage_error "unknown option: ${shown_option}; expected --efforts or --help"
				;;
		esac
	done
	case ${efforts} in
		'' | /*) ;;
		*)
			shown_efforts=$(printable "${efforts}")
			usage_error "--efforts ${shown_efforts} is not absolute; expected an absolute path"
			;;
	esac
}

# Removes the pending file once found and lets the call go on.
finish() {
	[ -z "${pending_file}" ] || rm -f -- "${pending_file}"
	pending_file=''
	exit 0
}

# Appends fault $1 to the seat folder's faults log, with the dispatch ID, so
# a reader matches a fault to its dispatch; stderr while no seat folder is
# known or when the log can't be written.
log_fault() {
	if [ -z "${seat_dir}" ]; then
		warn "fault: $1"
		return 0
	fi
	now=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || now='unknown-time'
	# shellcheck disable=SC2310 # its status is the answer; it checks each step itself
	if no_link_below "${worktree_root}" "${seat_dir}/${FAULTS}" &&
		{ printf '%s %s %s %s fault: %s\n' "${now}" "${tool_use_id:--}" "${shown_agent:--}" "${shown_file_id:--}" "$1" >>"${seat_dir}/${FAULTS}"; } 2>/dev/null; then
		return 0
	fi
	warn "could not append to ${seat_dir}/${FAULTS}: fault: $1"
}

# Succeeds when neither file $2 nor a folder between worktree $1 and it is a
# symbolic link; else names the link on stderr. A missing level ends the
# walk: nothing below it exists. The hook runs outside the agent's permission
# prompts, so a link the agent planted must never carry a write out.
no_link_below() {
	case $2 in
		"$1"/*) ;;
		*) return 1 ;;
	esac
	level_path=$1
	levels_left=${2#"$1"/}
	while [ -n "${levels_left}" ]; do
		level=${levels_left%%/*}
		case ${levels_left} in
			*/*) levels_left=${levels_left#*/} ;;
			*) levels_left='' ;;
		esac
		case ${level} in
			'' | . | ..) return 1 ;;
			*) ;;
		esac
		level_path="${level_path}/${level}"
		if [ -L "${level_path}" ]; then
			shown_link=$(printable "${level_path}")
			warn "${shown_link} is a symbolic link; nothing is written through it"
			return 1
		fi
		[ -e "${level_path}" ] || return 0
	done
}

fault() {
	log_fault "$1"
	finish
}

# Runs a command, its stdout dropped, its stderr in a file, its exit code in
# child_rc; never stops the script.
run() {
	child_rc=0
	"$@" >/dev/null 2>"${work_dir}/stderr" || child_rc=$?
}

script_dir() {
	case $0 in
		*/*) printf '%s' "${0%/*}" ;;
		*) printf '.' ;;
	esac
}

# Sets agent_id and tool_use_id from the event on stdin; an event without an
# agentId is no background launch, so nothing is done.
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
			(.tool_response.agentId? // "" | strings), (.tool_use_id // "" | strings)
		else empty end' "${work_dir}/event" 2>/dev/null) || {
		warn 'stdin is not one JSON object; expected the PostToolUse event; no seat bound'
		finish
	}
	agent_id='' tool_use_id=''
	{
		IFS= read -r agent_id || :
		IFS= read -r tool_use_id || :
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
}

# Sets efforts to the default when --efforts is not given; a space that can't
# be named holds no effort dispatch.
resolve_efforts() {
	[ -z "${efforts}" ] || return 0
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

# Sets pending_file and effort_dir from the first effort holding a pending
# file for tool_use_id; none: not an effort dispatch.
find_pending() {
	for candidate in "${efforts}"/*/pending/"${tool_use_id}"; do
		[ -f "${candidate}" ] && [ ! -L "${candidate}" ] || continue
		candidate_dir=${candidate%/pending/*}
		[ ! -L "${candidate_dir}" ] || continue
		pending_file=${candidate} effort_dir=${candidate_dir}
		return 0
	done
	finish
}

# Sets dispatch_file, file_id, shown_file_id, path_seat, worktree_root and
# seat_dir from the pending file's one line, a dispatch file in a seat folder
# of one of the pending file's own effort's worktrees.
read_pending() {
	dispatch_file=''
	{ IFS= read -r dispatch_file <"${pending_file}"; } 2>/dev/null || :
	shown_file=$(printable "${dispatch_file}")
	expected='expected <effort>/worktrees/<worktree>/.crucible/seats/<seat>/dispatch-<ID>.json of the pending file'\''s effort'
	case ${dispatch_file} in
		/*/dispatch-?*.json) ;;
		*) fault "pending file holds '${shown_file}'; ${expected}" ;;
	esac
	[ -f "${dispatch_file}" ] && [ ! -L "${dispatch_file}" ] || fault "dispatch file ${shown_file} is missing or a link; ${expected}"
	file_name=${dispatch_file##*/}
	file_id=${file_name#dispatch-}
	file_id=${file_id%.json}
	shown_file_id=$(printable "${file_id}")
	real_folder=$(cd -P -- "${dispatch_file%/*}" 2>/dev/null && pwd -P) || real_folder=''
	real_effort=$(cd -P -- "${effort_dir}" 2>/dev/null && pwd -P) || real_effort=''
	[ -n "${real_effort}" ] && [ -n "${real_folder}" ] || fault "dispatch file ${shown_file}'s folder or its effort could not be entered"
	in_worktrees=${real_folder#"${real_effort}/worktrees/"}
	[ "${in_worktrees}" != "${real_folder}" ] || fault "dispatch file ${shown_file} is not under this effort's worktrees/; ${expected}"
	path_seat=${in_worktrees#*/.crucible/seats/}
	worktree_name=${in_worktrees%%/*}
	case ${path_seat} in
		'' | */*) fault "dispatch file ${shown_file} is not directly in a seat folder; ${expected}" ;;
		*) ;;
	esac
	[ "${in_worktrees}" = "${worktree_name}/.crucible/seats/${path_seat}" ] ||
		fault "dispatch file ${shown_file} is not in a worktree's .crucible/seats/<seat>/; ${expected}"
	worktree_root="${real_effort}/worktrees/${worktree_name}"
	seat_dir=${real_folder}
}

# Sets dispatch_id and seat from the dispatch file; both must match its path.
read_dispatch() {
	ids=$(jq -r '(.id // "" | strings), (.seat // "" | strings)' "${dispatch_file}" 2>/dev/null) ||
		fault "jq could not read ${shown_file}; expected the dispatch JSON"
	dispatch_id='' seat=''
	{
		IFS= read -r dispatch_id || :
		IFS= read -r seat || :
	} <<EOF
${ids}
EOF
	[ -n "${dispatch_id}" ] && [ -n "${seat}" ] || {
		seat=$(printable "${seat}")
		fault "dispatch file ${shown_file} has no id or seat; expected both strings"
	}
	seat=$(printable "${seat}")
	[ "${seat}" = "${path_seat}" ] || fault "dispatch file ${shown_file} names seat ${seat}; expected ${path_seat}, its seat folder"
	[ "${dispatch_id}" = "${file_id}" ] || {
		shown_id=$(printable "${dispatch_id}")
		fault "dispatch file ${shown_file} has id ${shown_id}; expected the id in its name"
	}
}

bind_seat() {
	run sh "${own_dir}/../seats/seats.sh" bind --seats "${effort_dir}/seats.json" --seat "${seat}" \
		--agent-id "${agent_id}" --dispatch "${dispatch_id}"
	[ "${child_rc}" -ne 0 ] || finish
	first_line=$(head -n 1 "${work_dir}/stderr" | cut -c "1-${MAX_QUOTE_BYTES}") || first_line=''
	shown_line=$(printable "${first_line}")
	fault "seats.sh bind exit ${child_rc}: ${shown_line}"
}

# An unexpected failure lets the call go on too, logged, the pending file removed.
# shellcheck disable=SC2329 # invoked by the EXIT trap
on_exit() {
	exit_status=$?
	[ -z "${work_dir}" ] || rm -rf -- "${work_dir}"
	[ -z "${pending_file}" ] || rm -f -- "${pending_file}"
	[ "${exit_status}" -ne 0 ] && [ "${usage_failed}" = no ] || return 0
	work_dir='' pending_file=''
	log_fault "unexpected exit ${exit_status}"
	exit 0
}

work_dir='' pending_file='' usage_failed=no effort_dir='' worktree_root='' seat_dir='' seat='' tool_use_id='' shown_agent='' shown_file_id=''
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
find_pending
read_pending
read_dispatch
bind_seat
