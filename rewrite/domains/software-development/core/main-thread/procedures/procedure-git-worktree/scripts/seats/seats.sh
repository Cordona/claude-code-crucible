#!/usr/bin/env sh
# The only writer of an effort's seats.json, the seat list hooks and scripts
# route work by. One command per change, under a mkdir lock beside the file.
# The shell checks the command line and the path; seats.jq checks the options
# and the file, applies the change and checks the result, so the shell never
# edits JSON. Every written file goes through crucible's prune, so a key with
# nothing in it is left out. A change goes in place through a temp file beside
# it, so the file is whole or unchanged, and get, find and busy read it without
# the lock.
set -eu
umask 077

readonly PROG='seats.sh'
readonly MODULE='seats'
readonly CRUCIBLE_SKILL='crucible'
# Bounds stderr so a refusal stays readable; the last line counts the rest.
readonly MAX_PROBLEMS=20
readonly LOCK_WAIT_SECONDS=10
readonly LOCK_POLL_SECONDS=0.2
readonly COMMANDS='choose opened drop add bind status handover get find busy'
# The C locale keeps the shell byte-wise; jq writes the file as UTF-8.
LC_ALL=C
export LC_ALL

# Prints {exit, problems, file, out, remove}: the exit code, the problem lines
# (at most $max), the new file (null when nothing is written), the stdout
# text and, when drop removed the last seat, remove true (the file goes).
# The new file is pruned, then checked against the contract. Each
# --base-seat value comes as $base_seat_<n>, n its place from 0.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly RUN_JQ='include "seats";
include "prune";
([$ARGS.named | to_entries[] | select(.key | startswith("base_seat_"))
	| {place: (.key | ltrimstr("base_seat_") | tonumber), value}] | sort_by(.place) | map(.value)) as $base_seats
| {seat: $seat, role: $role, repo: $repo, base: $base, lens: $lens,
	"agent-id": $agent_id, dispatch: $dispatch, status: $status, "awaiting-round": $awaiting_round,
	"base-seat": $base_seats} as $given
| seats_run($command; $given | with_entries(select(.value != "" and .value != [])); $effort; $seats_dir;
	if $exists == "yes" then $current else null end)
| .file |= prune
| seats_checked
| .problems |= (if length > $max then .[:$max - 1] + ["\(length - $max + 1) more problems not shown; expected none"] else . end)'

usage() {
	cat <<EOF
usage: sh ${PROG} choose --seats FILE --seat S --role developer --repo DIR --base SHA
           [--base-seat S]...
       sh ${PROG} opened --seats FILE --seat S
       sh ${PROG} drop --seats FILE --seat S
       sh ${PROG} add --seats FILE --seat S --role reviewer --lens L
       sh ${PROG} bind --seats FILE --seat S --agent-id ID --dispatch ID
       sh ${PROG} status --seats FILE --seat S --status working|idle|gave-up [--awaiting-round N|none]
       sh ${PROG} handover --seats FILE --seat S
       sh ${PROG} get --seats FILE --seat S
       sh ${PROG} find --seats FILE --agent-id ID
       sh ${PROG} busy --seats FILE
       sh ${PROG} --help | -h

Keeps an effort's seat list. Each change runs under the lock FILE.lock
(waiting at most ${LOCK_WAIT_SECONDS}s) and is written only when the whole file fits
the contract; a file that fails it is refused, never repaired. An empty
key is left out: no value is null, [] or {}.

--seats FILE  absolute path of seats.json; its folder must exist; the
              folder's name is the effort id a new file gets

choose    a writer seat with no worktree yet: status chosen, mode BUILD,
          worktree <FILE's folder, symlinks resolved>/worktrees/S, each
          --base-seat (a developer seat it was cut from) in base_seats in
          order; S is software-developer-<letter>; tester refused
opened    sets a chosen seat open; seat-open.sh runs it once the worktree exists
drop      removes a chosen seat (the last: FILE goes); others refused
add       a reviewer seat, S <L>-reviewer-<letter>: status open
bind      seats an agent and its dispatch on an open seat: status working;
          the same agent and dispatch again changes nothing; refused for
          an agent handed out of the seat
status    sets working, idle or gave-up on a bound seat, and awaiting_round
          when --awaiting-round is given (a developer or tester only; none
          removes it)
handover  frees a bound seat: the agent moves to the end of
          previous_agent_ids, agent_id and dispatch go, status open
get       prints the seat as one line of JSON
find      like get, the seat whose agent_id is ID
busy      prints "seat<TAB>status<TAB>awaiting_round" per seat that is open,
          working or awaits a round (none when it awaits none); never a
          chosen one

the file: {"effort": string, "seats": [seat, ...]}, seat names unique
  every seat   seat (dash-joined lowercase words ending in one of alpha
               ... omega, like software-developer-alpha), role,
               status (chosen, open, working, idle or gave-up), agent_id
               and dispatch (letters, digits, _ and -; absent when chosen or
               open, present otherwise), previous_agent_ids (optional, not
               when chosen: agents handed out, oldest first, no repeats)
  developer    mode BUILD, worktree, repo (absolute paths), base (40 hex),
  tester       mode TEST,  awaiting_round (optional, a whole number >= 1),
               base_seats (optional, set by choose only: other developer
               seats, none chosen, no repeats)
  reviewer     lens (lowercase words joined by dashes); never chosen

needs jq 1.6+ and prune.jq from the ${CRUCIBLE_SKILL} skill, in
${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/skills/${CRUCIBLE_SKILL}/scripts/lib

exit codes:
  0  done; a change prints nothing
  2  wrong command line: a missing or unknown command or option, an option
     the command does not take, or a missing or repeated value
  3  invalid input or the file fails the contract; each problem is one stderr
     line (at most ${MAX_PROBLEMS}); also a --role or --seat name the command
     does not take
  4  jq or prune.jq is missing, jq failed, or the file could not be written
  5  refused by the seat's state: it exists (choose, add), another agent
     or dispatch holds it, the agent was handed out of it, it is chosen
     (bind, status, handover), open (status, handover) or not chosen
     (opened, drop), or find found ID in more than one seat
  6  the seat is not in the file; find: no seat holds ID
  7  the lock is held by another run past ${LOCK_WAIT_SECONDS}s
  8  busy found work in flight
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
		choose) printf -- '--seats --seat --role --repo --base --base-seat' ;;
		add) printf -- '--seats --seat --role --lens' ;;
		bind) printf -- '--seats --seat --agent-id --dispatch' ;;
		find) printf -- '--seats --agent-id' ;;
		status) printf -- '--seats --seat --status --awaiting-round' ;;
		busy) printf -- '--seats' ;;
		*) printf -- '--seats --seat' ;;
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
		choose | opened | drop | add | bind | status | handover | get | find | busy) command=$1 ;;
		*)
			shown_command=$(printable "$1")
			usage_error "unknown command: ${shown_command}; expected one of ${COMMANDS}"
			;;
	esac
	shift
	allowed=$(command_options "${command}")
	seats_file='' seat='' role='' repo='' base='' lens='' agent_id='' dispatch='' status='' awaiting_round=''
	while [ "$#" -gt 0 ]; do
		case $1 in
			-h | --help)
				usage
				exit 0
				;;
			--seats)
				take_value "$1" "${seats_file}" "${2-}"
				seats_file=${option_value}
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
			--lens)
				take_value "$1" "${lens}" "${2-}"
				lens=${option_value}
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
			--awaiting-round)
				take_value "$1" "${awaiting_round}" "${2-}"
				awaiting_round=${option_value}
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
	require --seats "${seats_file}" FILE
	case ${command} in
		busy | find) ;;
		*) require --seat "${seat}" S ;;
	esac
	case ${command} in
		choose)
			require --role "${role}" developer
			require --repo "${repo}" DIR
			require --base "${base}" SHA
			;;
		add)
			require --role "${role}" reviewer
			# Another role is seats.jq's refusal, which names choose.
			[ "${role}" != reviewer ] || require --lens "${lens}" L
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

# Sets seats_dir, physical_dir (the folder with no symlink, where choose puts
# the worktrees folder) and effort from --seats, refusing a path that can't be
# the file.
check_seats_path() {
	shown_seats=$(printable "${seats_file}")
	case ${seats_file} in
		*[[:cntrl:]]*) die 3 "--seats ${shown_seats} holds a control character; expected a plain path" ;;
		*/) die 3 "--seats ${shown_seats} names a folder; expected the seats.json path" ;;
		/*) ;;
		*) die 3 "--seats ${shown_seats} is not absolute; expected an absolute path" ;;
	esac
	seats_dir=${seats_file%/*}
	effort=${seats_dir##*/}
	[ -n "${seats_dir}" ] || seats_dir=/
	shown_dir=$(printable "${seats_dir}")
	[ -d "${seats_dir}" ] || die 3 "--seats folder ${shown_dir} does not exist; expected the effort folder"
	[ ! -d "${seats_file}" ] || die 3 "--seats ${shown_seats} is a folder; expected the seats.json path"
	physical_dir=$(cd -P -- "${seats_dir}" 2>/dev/null && pwd -P) ||
		die 3 "--seats folder ${shown_dir} can't be entered; expected a readable effort folder"
}

# Sets own_dir (seats.jq) and crucible_lib_dir (prune.jq, from the installed
# crucible skill).
load_dependencies() {
	command -v jq >/dev/null 2>&1 || die 4 'jq not found; expected jq 1.6+ on PATH'
	own_dir=$(script_dir)
	crucible_lib_dir="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/skills/${CRUCIBLE_SKILL}/scripts/lib"
	shown_lib_dir=$(printable "${crucible_lib_dir}")
	[ -f "${crucible_lib_dir}/prune.jq" ] && [ -r "${crucible_lib_dir}/prune.jq" ] ||
		die 4 "prune.jq not found in ${shown_lib_dir}; expected the ${CRUCIBLE_SKILL} skill installed"
}

# Waits for the lock folder at most LOCK_WAIT_SECONDS; mkdir is atomic, so
# one run holds it at a time.
take_lock() {
	lock_dir="${seats_file}.lock"
	shown_lock=$(printable "${lock_dir}")
	deadline=$(($(date +%s) + LOCK_WAIT_SECONDS))
	until mkdir -- "${lock_dir}" 2>/dev/null; do
		[ -d "${lock_dir}" ] || die 4 "mkdir could not create the lock ${shown_lock}; expected a writable effort folder"
		now=$(date +%s)
		[ "${now}" -lt "${deadline}" ] ||
			die 7 "the lock ${shown_lock} is still held after ${LOCK_WAIT_SECONDS}s; expected it free (remove it by hand only when no ${PROG} runs)"
		# A fractional sleep is not POSIX; where it fails, wait a whole second.
		sleep "${LOCK_POLL_SECONDS}" 2>/dev/null || sleep 1
	done
	lock_held=yes
}

# Sets result to RUN_JQ's output over the file as it is now; the arguments
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
	if [ -e "${seats_file}" ]; then
		[ -f "${seats_file}" ] && [ -r "${seats_file}" ] ||
			die 3 "--seats ${shown_seats} is not a readable file; expected the seats JSON file"
		exists=yes current_file=${seats_file}
	else
		exists=no current_file=/dev/null
	fi
	result=$(jq -nc -L "${own_dir}" -L "${crucible_lib_dir}" --rawfile current "${current_file}" --arg exists "${exists}" \
		--arg command "${command}" --arg effort "${effort}" --arg seats_dir "${physical_dir}" --argjson max "${MAX_PROBLEMS}" \
		--arg seat "${seat}" --arg role "${role}" --arg repo "${repo}" \
		--arg base "${base}" --arg lens "${lens}" --arg agent_id "${agent_id}" --arg dispatch "${dispatch}" \
		--arg status "${status}" --arg awaiting_round "${awaiting_round}" "$@" "${RUN_JQ}") ||
		die 4 "jq failed; expected jq 1.6+, ${MODULE}.jq beside ${PROG} and prune.jq in ${shown_lib_dir}"
}

# Prints the problems and the output, writes the new file when there is one,
# and exits with the command's code.
finish() {
	outcome=$(printf '%s\n' "${result}" | jq -r '"\(.exit) \(.file != null) \(.remove == true)"') ||
		die 4 'jq failed reading the result; expected jq 1.6+'
	exit_code=${outcome%% *} outcome=${outcome#* }
	[ "${outcome% *}" = false ] || write_file
	[ "${outcome#* }" = false ] || remove_file
	problems=$(printf '%s\n' "${result}" | jq -r '.problems[]') ||
		die 4 'jq failed reading the problems; expected jq 1.6+'
	if [ -n "${problems}" ]; then
		while IFS= read -r problem; do
			warn "${problem}"
		done <<EOF
${problems}
EOF
	fi
	output=$(printf '%s\n' "${result}" | jq -r '.out') || die 4 'jq failed reading the output; expected jq 1.6+'
	[ -z "${output}" ] || printf '%s\n' "${output}"
	exit "${exit_code}"
}

# Writes the new file over --seats through a temp file in the same folder.
write_file() {
	temp_file=$(mktemp "${seats_dir}/.${seats_file##*/}.XXXXXX") ||
		die 4 "mktemp could not create a temp file beside ${shown_seats}; expected a writable folder"
	printf '%s\n' "${result}" | jq '.file' >"${temp_file}" ||
		die 4 "could not write the temp file beside ${shown_seats}; expected free space"
	mv -f "${temp_file}" "${seats_file}" ||
		die 4 "mv could not move the temp file onto ${shown_seats}; expected a writable folder"
	temp_file=''
}

# Removes --seats, under the lock, once its last seat is dropped.
remove_file() {
	rm -f -- "${seats_file}" || die 4 "rm could not remove ${shown_seats}; expected a writable folder"
}

# shellcheck disable=SC2329 # invoked by the EXIT trap
clean_up() {
	[ -z "${temp_file}" ] || rm -f "${temp_file}"
	[ "${lock_held}" != yes ] || rmdir "${lock_dir}" 2>/dev/null || true
}

temp_file='' lock_held=no lock_dir=''
trap clean_up EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

parse_args "$@"
check_seats_path
load_dependencies
case ${command} in
	get | find | busy) ;;
	*) take_lock ;;
esac
shift
run_command "$@"
finish
