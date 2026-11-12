#!/usr/bin/env sh
# Keeps an effort's seat list, the list hooks and scripts route work by, as
# seat.* events. One command per change: the seat list is the replay of the
# effort's seat events (seats-events.jq), seats.jq checks the options and
# applies the change to it, and the change is one event, appended through the
# crucible skill's events.sh with seats-guard.jq, which checks it again under
# the events lock. The shell never edits JSON.
set -eu
umask 077

readonly PROG='seats.sh'
readonly MODULE='seats'
readonly CRUCIBLE_SKILL='crucible'
# Bounds stderr so a refusal stays readable; the last line counts the rest.
readonly MAX_PROBLEMS=20
readonly LOCK_WAIT_SECONDS=5
readonly COMMANDS='choose opened drop bind status handover get find busy list'
# The C locale keeps the shell byte-wise; jq reads and writes UTF-8.
LC_ALL=C
export LC_ALL

# Prints {exit, problems, file, out, remove, options}: the exit code, the
# problem lines (at most $max), the seat list after the change (null when
# nothing changes), the stdout text, remove true when drop removed the last
# seat, and the options given. The new list is pruned, then checked against
# the contract. Each
# --base-seat value comes as $base_seat_<n>, n its place from 0.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly RUN_JQ='include "seats";
include "prune";
([$ARGS.named | to_entries[] | select(.key | startswith("base_seat_"))
	| {place: (.key | ltrimstr("base_seat_") | tonumber), value}] | sort_by(.place) | map(.value)) as $base_seats
| {seat: $seat, role: $role, repo: $repo, base: $base,
	"agent-id": $agent_id, dispatch: $dispatch, status: $status, "base-seat": $base_seats} as $given
| ($given | with_entries(select(.value != "" and .value != []))) as $options
| seats_run($command; $options; $effort; $seats_dir;
	if $exists == "yes" then $current else null end)
| .options = $options
| .file |= prune
| seats_checked
| .problems |= (if length > $max then .[:$max - 1] + ["\(length - $max + 1) more problems not shown; expected none"] else . end)'

usage() {
	cat <<EOF
usage: sh ${PROG} choose --effort FOLDER --seat S --role developer --repo DIR --base SHA
           [--base-seat S]...
       sh ${PROG} opened --effort FOLDER --seat S
       sh ${PROG} drop --effort FOLDER --seat S
       sh ${PROG} bind --effort FOLDER --seat S --agent-id ID --dispatch ID
       sh ${PROG} status --effort FOLDER --seat S --status working|idle|gave-up
       sh ${PROG} handover --effort FOLDER --seat S
       sh ${PROG} get --effort FOLDER --seat S
       sh ${PROG} find --effort FOLDER --agent-id ID
       sh ${PROG} busy --effort FOLDER
       sh ${PROG} list --effort FOLDER
       sh ${PROG} --help | -h

Keeps an effort's seat list as seat.* events, one per change, appended
under the events lock when the list after it fits the contract. A seat's
build.committed makes it idle. No value is null, [] or {}: an empty key is
left out.

--effort FOLDER  the effort folder, absolute

choose    a seat with no worktree yet: status chosen, mode BUILD,
          worktree <effort, symlinks resolved>/worktrees/<letter>, each
          --base-seat in base_seats; S build-agent-<letter>
opened    sets a chosen seat open; seat-open.sh runs it once the worktree exists
drop      removes a chosen seat; others refused
bind      seats an agent and its dispatch on an open seat: status working;
          the same agent and dispatch again changes nothing; refused for
          an agent handed out of the seat
status    sets working, idle or gave-up on a bound seat
handover  frees a bound seat: the agent moves to the end of
          previous_agent_ids, agent_id and dispatch go, status open
get       prints the seat as one line of JSON; find: the seat of agent ID
list      prints the seat list {effort, seats} as one line of JSON
busy      prints "seat<TAB>status" per seat that is working or gave-up

the list: {"effort": string, "seats": [seat, ...]}, seat names unique
  each seat    seat (dash-joined lowercase words ending in alpha ...
               omega, alpha-2 ... omega-2, alpha-3 ...), role developer,
               mode BUILD, status (chosen, open, working, idle or gave-up),
               agent_id and dispatch (letters, digits, _ and -; absent when
               chosen or open, present otherwise), previous_agent_ids
               (optional, not when chosen: agents handed out, oldest first,
               no repeats), worktree, repo (absolute paths), base (40 hex),
               base_seats (optional, set by choose only: other seats, none
               chosen, no repeats)

needs: POSIX sh, jq 1.6+; the ${CRUCIBLE_SKILL} skill's events.sh and lib/prune.jq,
in ${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/skills/${CRUCIBLE_SKILL}/scripts

exit codes:
  0  done; a change prints nothing
  2  wrong command line: a missing or unknown command or option, an option
     the command does not take, or a missing or repeated value
  3  invalid input or the seat list fails the contract; each problem is one
     stderr line (at most ${MAX_PROBLEMS}); also a --role or --seat name the
     command does not take
  4  jq, prune.jq or events.sh is missing or failed, or no event was written
  5  refused by the seat's state: it exists (choose), another agent
     or dispatch holds it, the agent was handed out of it, it is chosen
     (bind, status, handover), open (status, handover) or not chosen
     (opened, drop), find found ID in more than one seat, or another call
     changed the seat first
  6  the seat is not in the list; find: no seat holds ID
  7  the events lock is held by another run past ${LOCK_WAIT_SECONDS}s
  8  busy found open work; to busy, any exit but 0 and 8 is a failed read
EOF
}

warn() {
	printf '%s: %s\n' "${PROG}" "$1" >&2
}

die() {
	warn "$2"
	exit "$1"
}

usage_error() {
	warn "$1"
	printf "Try 'sh %s --help'.\n" "${PROG}" >&2
	exit 2
}

# Prints $1 with each control character as "?", so a path can't split a stderr line.
printable() {
	printf '%s' "$1" | tr '[:cntrl:]' '?'
}

# Prints the options command $1 takes.
command_options() {
	case $1 in
		choose) printf -- '--effort --seat --role --repo --base --base-seat' ;;
		bind) printf -- '--effort --seat --agent-id --dispatch' ;;
		find) printf -- '--effort --agent-id' ;;
		status) printf -- '--effort --seat --status' ;;
		busy | list) printf -- '--effort' ;;
		*) printf -- '--effort --seat' ;;
	esac
}

# Sets $option_value from "$1 $2", refusing an option command does not take,
# a repeat or a missing value.
take_value() {
	take_repeated "$1" "$3"
	[ -z "$2" ] || usage_error "$1 given twice; expected one"
}

# Sets $option_value from "$1 $2", refusing an option command does not take
# or a missing value.
take_repeated() {
	case " ${allowed} " in
		*" $1 "*) ;;
		*) usage_error "$1 is not an option of ${command}; expected ${allowed}" ;;
	esac
	[ -n "$2" ] || usage_error "$1 needs a value; expected $1 VALUE"
	option_value=$2
}

parse_args() {
	case ${1-} in
		-h | --help)
			usage
			exit 0
			;;
		'') usage_error "command missing; expected one of ${COMMANDS}" ;;
		choose | opened | drop | bind | status | handover | get | find | busy | list) command=$1 ;;
		*)
			shown_command=$(printable "$1")
			usage_error "unknown command: ${shown_command}; expected one of ${COMMANDS}"
			;;
	esac
	shift
	allowed=$(command_options "${command}")
	effort_folder='' seat='' role='' repo='' base='' agent_id='' dispatch='' status=''
	while [ "$#" -gt 0 ]; do
		case $1 in
			-h | --help)
				usage
				exit 0
				;;
			--effort)
				take_value "$1" "${effort_folder}" "${2-}"
				effort_folder=${option_value}
				;;
			--seat)
				take_value "$1" "${seat}" "${2-}"
				seat=${option_value}
				;;
			--role)
				take_value "$1" "${role}" "${2-}"
				role=${option_value}
				;;
			--repo)
				take_value "$1" "${repo}" "${2-}"
				repo=${option_value}
				;;
			--base)
				take_value "$1" "${base}" "${2-}"
				base=${option_value}
				;;
			--base-seat)
				# run_command reads each value from the command line, in order.
				take_repeated "$1" "${2-}"
				;;
			--agent-id)
				take_value "$1" "${agent_id}" "${2-}"
				agent_id=${option_value}
				;;
			--dispatch)
				take_value "$1" "${dispatch}" "${2-}"
				dispatch=${option_value}
				;;
			--status)
				take_value "$1" "${status}" "${2-}"
				status=${option_value}
				;;
			*)
				shown_option=$(printable "$1")
				usage_error "unknown option: ${shown_option}; expected ${allowed} or --help"
				;;
		esac
		shift 2
	done
	require_options
}

# Refuses a command missing an option it needs.
require_options() {
	require --effort "${effort_folder}" FOLDER
	case ${command} in
		busy | find | list) ;;
		*) require --seat "${seat}" S ;;
	esac
	case ${command} in
		choose)
			require --role "${role}" developer
			require --repo "${repo}" DIR
			require --base "${base}" SHA
			;;
		bind)
			require --agent-id "${agent_id}" ID
			require --dispatch "${dispatch}" ID
			;;
		status) require --status "${status}" 'working|idle|gave-up' ;;
		find) require --agent-id "${agent_id}" ID ;;
		*) ;;
	esac
}

# Refuses option $1 when its value $2 is empty; $3 names the value.
require() {
	[ -n "$2" ] || usage_error "$1 missing; expected $1 $3"
}

script_dir() {
	case $0 in
		*/*) printf '%s' "${0%/*}" ;;
		*) printf '.' ;;
	esac
}

# Sets effort (the folder's name), effort_folder without trailing slashes and
# physical_dir (the folder with no symlink, where choose puts the worktrees
# folder), refusing a path that can't be an effort folder.
check_effort_path() {
	shown_effort=$(printable "${effort_folder}")
	case ${effort_folder} in
		*[[:cntrl:]]*) die 3 "--effort ${shown_effort} holds a control character; expected a plain path" ;;
		/*) ;;
		*) die 3 "--effort ${shown_effort} is not absolute; expected an absolute path" ;;
	esac
	while [ "${effort_folder}" != "${effort_folder%/}" ]; do effort_folder=${effort_folder%/}; done
	effort=${effort_folder##*/}
	[ -d "${effort_folder}" ] || die 3 "--effort ${shown_effort} does not exist; expected the effort folder"
	physical_dir=$(cd -P -- "${effort_folder}" 2>/dev/null && pwd -P) ||
		die 3 "--effort ${shown_effort} can't be entered; expected a readable effort folder"
}

# Sets own_dir (seats.jq), crucible_lib_dir (prune.jq) and events_script, from
# the installed crucible skill.
load_dependencies() {
	command -v jq >/dev/null 2>&1 || die 4 'jq not found; expected jq 1.6+ on PATH'
	own_dir=$(script_dir)
	crucible_dir="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/skills/${CRUCIBLE_SKILL}/scripts"
	crucible_lib_dir="${crucible_dir}/lib"
	events_script="${crucible_dir}/events.sh"
	shown_lib_dir=$(printable "${crucible_lib_dir}")
	[ -f "${crucible_lib_dir}/prune.jq" ] && [ -r "${crucible_lib_dir}/prune.jq" ] ||
		die 4 "prune.jq not found in ${shown_lib_dir}; expected the ${CRUCIBLE_SKILL} skill installed"
	shown_crucible_dir=$(printable "${crucible_dir}")
	[ -f "${events_script}" ] && [ -r "${events_script}" ] ||
		die 4 "events.sh not found in ${shown_crucible_dir}; expected the ${CRUCIBLE_SKILL} skill installed"
}

# Sets current to the seat list replayed from the effort's events, and exists
# to yes when it holds a seat.
read_seats() {
	events_json=$(sh "${events_script}" slurp --effort "${effort_folder}" </dev/null) ||
		die 4 "events.sh slurp failed for ${shown_effort} (its stderr is above); expected the effort's events"
	current=$(printf '%s\n' "${events_json}" | jq -c -L "${own_dir}" --arg effort "${effort}" \
		'include "seats-events"; [.[] | select((.type | startswith("seat.")) or .type == "build.committed")] | seats_fold($effort)') ||
		die 4 "jq failed replaying the seat events; expected jq 1.6+ and seats-events.jq beside ${PROG}"
	seat_count=$(printf '%s\n' "${current}" | jq '.seats | length') ||
		die 4 'jq failed counting the seats; expected jq 1.6+'
	exists=yes
	[ "${seat_count}" -ne 0 ] || exists=no
}

# Sets result to RUN_JQ's output over the seat list as it is now; the arguments
# are the checked command line after the command, read for --base-seat.
run_command() {
	place=0 left=$#
	while [ "${left}" -gt 0 ]; do
		[ "$1" != --base-seat ] || {
			set -- "$@" --arg "base_seat_${place}" "$2"
			place=$((place + 1))
		}
		shift 2
		left=$((left - 2))
	done
	read_seats
	result=$(jq -nc -L "${own_dir}" -L "${crucible_lib_dir}" --argjson current "${current}" --arg exists "${exists}" \
		--arg command "${command}" --arg effort "${effort}" --arg seats_dir "${physical_dir}" --argjson max "${MAX_PROBLEMS}" \
		--arg seat "${seat}" --arg role "${role}" --arg repo "${repo}" \
		--arg base "${base}" --arg agent_id "${agent_id}" --arg dispatch "${dispatch}" \
		--arg status "${status}" "$@" "${RUN_JQ}") ||
		die 4 "jq failed; expected jq 1.6+, ${MODULE}.jq beside ${PROG} and prune.jq in ${shown_lib_dir}"
}

# Prints the problems and the output, appends the change's event when the
# seat list changed, and exits with the command's code.
finish() {
	outcome=$(printf '%s\n' "${result}" | jq -r '"\(.exit) \(.file != null or .remove == true)"') ||
		die 4 'jq failed reading the result; expected jq 1.6+'
	exit_code=${outcome%% *} changed=${outcome#* }
	problems=$(printf '%s\n' "${result}" | jq -r '.problems[]') ||
		die 4 'jq failed reading the problems; expected jq 1.6+'
	if [ -n "${problems}" ]; then
		while IFS= read -r problem; do
			warn "${problem}"
		done <<EOF
${problems}
EOF
	fi
	[ "${exit_code}" -ne 0 ] || [ "${changed}" = false ] || append_event
	output=$(printf '%s\n' "${result}" | jq -r '.out') || die 4 'jq failed reading the output; expected jq 1.6+'
	[ -z "${output}" ] || printf '%s\n' "${output}"
	exit "${exit_code}"
}

# Appends the change as one seat event, checked again under the events lock.
append_event() {
	body_file=$(mktemp) || die 4 'mktemp could not create a temp file; expected a writable TMPDIR'
	printf '%s\n' "${result}" | jq -c -L "${own_dir}" --argjson before "${current}" \
		--arg command "${command}" 'include "seats-events"; seats_event_body($command; .options; $before; .file // {seats: []})' >"${body_file}" ||
		die 4 'jq failed building the seat event; expected jq 1.6+ and seats-events.jq'
	event_type=$(jq -nr -L "${own_dir}" --arg command "${command}" 'include "seats-events"; seats_event_types[$command]') ||
		die 4 'jq failed naming the seat event; expected jq 1.6+'
	if sh "${events_script}" append --effort "${effort_folder}" --type "${event_type}" --by "${PROG}" \
		--body-file "${body_file}" --guard "${own_dir}/seats-guard.jq" --wait "${LOCK_WAIT_SECONDS}" >/dev/null </dev/null; then
		append_status=0
	else
		append_status=$?
	fi
	case ${append_status} in
		0) ;;
		3) die 5 "the change was refused under the events lock (events.sh stderr above)" ;;
		6) die 7 "the events lock of ${shown_effort} is still held after ${LOCK_WAIT_SECONDS}s; expected it free" ;;
		*) die 4 "events.sh append exited ${append_status} (its stderr is above); expected the event written" ;;
	esac
}

# shellcheck disable=SC2329 # invoked by the EXIT trap
clean_up() {
	[ -z "${body_file}" ] || rm -f "${body_file}"
}

body_file=''
trap clean_up EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

parse_args "$@"
load_dependencies
check_effort_path
if [ "${command}" = list ]; then
	read_seats
	printf '%s\n' "${current}"
	exit 0
fi
shift
run_command "$@"
finish
