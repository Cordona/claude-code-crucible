#!/usr/bin/env sh
# Keeps an effort's seat list, the list hooks and scripts route work by, as
# seat.* events. One command per change: the seat list is the replay of the
# effort's seat events (seats-events.jq), seats.jq checks the options and
# applies the change to it, and the change is one event, appended through the
# crucible skill's events.sh with seats-guard.jq, which checks it again under
# the events lock. The shell never edits JSON.
# shellcheck source-path=SCRIPTDIR source-path=SCRIPTDIR/../../../../../../../../framework/core/engine/human-view/scripts/lib
set -eu
umask 077

readonly PROG='seats.sh'
readonly MODULE='seats'
readonly CRUCIBLE_SKILL='crucible'
# Bounds stderr so a refusal stays readable; the last line counts the rest.
readonly MAX_PROBLEMS=20
# events.sh's own default: an append holds the lock for a moment, so a lock
# still held after 5 s is stuck, and waiting longer only delays the refusal.
readonly LOCK_WAIT_SECONDS=5
readonly COMMANDS='choose opened drop bind status handover move task get find busy list'
# The commands that change the seat list; a refusal of one is kept as a fault.
readonly CHANGE_COMMANDS='choose opened drop bind status handover move task'
# The C locale keeps the shell byte-wise; jq reads and writes UTF-8.
LC_ALL=C
export LC_ALL

# Prints {exit, problems, rejections, file, out, remove, options}: the exit
# code, the problem lines (at most $max), each problem as a fault body
# {refused, rule} (at most $max), the seat list after the change (null when
# nothing changes), the stdout text, remove true when drop removed the last
# seat, and the options given. The new list is pruned, then checked against
# the contract. Each --base-seat value comes as $base_seat_<n>, n its place
# from 0; the --task text comes as $task_text, made one line.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly RUN_JQ='include "seats";
include "prune";
([$ARGS.named | to_entries[] | select(.key | startswith("base_seat_"))
	| {place: (.key | ltrimstr("base_seat_") | tonumber), value}] | sort_by(.place) | map(.value)) as $base_seats
| {seat: $seat, role: $role, repo: $repo, base: $base,
	"agent-id": $agent_id, dispatch: $dispatch, status: $status, "base-seat": $base_seats,
	branch: $branch, "from-head": $from_head, follows: $follows,
	task: ($task_text | gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; ""))} as $given
| ($given | with_entries(select(.value != "" and .value != []))) as $options
| seats_run($command; $options; $effort; $seats_dir;
	if $exists == "yes" then $current else null end)
| .options = $options
| .file |= prune
| seats_checked
| .rejections = (.problems | map(seats_rejection($command)) | unique | .[:$max])
| .problems |= (if length > $max then .[:$max - 1] + ["\(length - $max + 1) more problems not shown; expected none"] else . end)'

usage() {
	cat <<EOF
usage: sh ${PROG} choose --effort FOLDER --seat S --role developer --repo DIR --base SHA
           [--base-seat S]...
       sh ${PROG} opened --effort FOLDER --seat S --branch NAME
       sh ${PROG} drop --effort FOLDER --seat S
       sh ${PROG} bind --effort FOLDER --seat S --agent-id ID --dispatch ID
       sh ${PROG} status --effort FOLDER --seat S --status working|idle|gave-up
       sh ${PROG} handover --effort FOLDER --seat S
       sh ${PROG} move --effort FOLDER --seat S --base SHA --from-head SHA
           [--follows NAME]
       sh ${PROG} task --effort FOLDER --seat S --task TEXT
       sh ${PROG} get --effort FOLDER --seat S
       sh ${PROG} find --effort FOLDER --agent-id ID [--card]
       sh ${PROG} busy --effort FOLDER
       sh ${PROG} list --effort FOLDER
       sh ${PROG} --help | -h

Keeps an effort's seat list as seat.* events: a change is one event,
appended under the events lock only when the list after it fits the
contract; a refused change writes no event, only one fault per problem in
the ${CRUCIBLE_SKILL} skill's rejection log (events.sh). A seat's
build.committed makes it idle. Reads check the list's shape, not the rules
a change meets. Nothing else is left behind (a SIGKILL aside).

--effort FOLDER   the effort folder, absolute
--seat S          the seat, like build-agent-alpha
--role developer  choose: the seat's role
--repo DIR        choose: the repository's main checkout, absolute
--base SHA        choose, move: the commit the worktree starts from
--base-seat S     choose: a seat the new one is cut from; repeatable
--branch NAME     opened: the branch the worktree was cut on
--agent-id ID     bind, find: Claude Code's agent id
--dispatch ID     bind: the dispatch that seated the agent
--status STATUS   status: working, idle or gave-up
--from-head SHA   move: the worktree's HEAD before the move, for the record
--follows NAME    move: the name the new base was taken from, for the record
--task TEXT       task: the new work, made one line, for the record
--card            find: also print its line (below)

choose    a new seat, status chosen, worktree
          <effort, symlinks resolved>/worktrees/<letter>
opened    sets a chosen seat open, once its worktree exists
drop      removes a chosen seat
bind      seats an agent on an open seat: working; the same agent and
          dispatch again changes nothing
status    sets the status of a bound seat
handover  frees a bound seat: the agent goes to previous_agent_ids, open
move      sets the base of a seat neither chosen nor working; base_seats go
task      gives an idle seat's bound agent new work: working

stdout of get and find: the seat, one JSON line; of list: {effort, seats},
  one JSON line. A seat's keys: seat, role, mode, status (chosen, open,
  working, idle, gave-up), agent_id and dispatch (none while chosen or
  open), previous_agent_ids, worktree, repo, base, base_seats; an empty key
  is left out. Their rules: seats.jq
then, with find --card, show.sh prints (owed this session, for --effort)
  views/lines.jq's report_gave_up (gave-up) or run_not_committed (working)
stdout of busy: "seat<TAB>status" per seat working or gave-up
stderr on exits 3, 5 and 6: one line per problem, at most ${MAX_PROBLEMS}

needs: POSIX sh, jq 1.6+; the ${CRUCIBLE_SKILL} skill's events.sh and lib/prune.jq,
in ${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/skills/${CRUCIBLE_SKILL}/scripts; --card:
../cards/cards-lib.sh, views/, human-view's show.sh and lib/render.sh

exit codes:
  0  done; a change prints nothing
  2  wrong command line; fix what stderr names
  3  invalid input or seat list, nothing changed; show the human stderr,
     and stop
  4  a dependency is missing or failed (also show.sh after find --card's
     seat); show the human stderr, and stop
  5  refused by the seat's state, nothing changed; show the human stderr,
     and stop
  6  no such seat (find: no seat holds ID); pass it on, else show the human
     stderr, and stop
  7  the events lock is busy past ${LOCK_WAIT_SECONDS}s; rerun once, else show the
     human stderr, and stop
  8  busy found open work; stdout names it (any other exit is a failed read)
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
		opened) printf -- '--effort --seat --branch' ;;
		move) printf -- '--effort --seat --base --from-head --follows' ;;
		task) printf -- '--effort --seat --task' ;;
		bind) printf -- '--effort --seat --agent-id --dispatch' ;;
		find) printf -- '--effort --agent-id --card' ;;
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
	take_option "$1"
	[ -n "$2" ] || usage_error "$1 needs a value; expected $1 VALUE"
	option_value=$2
}

# Refuses option $1 when command does not take it.
take_option() {
	case " ${allowed} " in
		*" $1 "*) ;;
		*) usage_error "$1 is not an option of ${command}; expected ${allowed}" ;;
	esac
}

parse_args() {
	case ${1-} in
		-h | --help)
			usage
			exit 0
			;;
		'') usage_error "command missing; expected one of ${COMMANDS}" ;;
		choose | opened | drop | bind | status | handover | move | task | get | find | busy | list) command=$1 ;;
		*)
			shown_command=$(printable "$1")
			usage_error "unknown command: ${shown_command}; expected one of ${COMMANDS}"
			;;
	esac
	shift
	allowed=$(command_options "${command}")
	effort_folder='' seat='' role='' repo='' base='' agent_id='' dispatch='' status=''
	branch='' from_head='' follows='' task='' card=''
	while [ "$#" -gt 0 ]; do
		case $1 in
			-h | --help)
				usage
				exit 0
				;;
			--card)
				take_option "$1"
				[ -z "${card}" ] || usage_error '--card given twice; expected one'
				card=yes
				shift
				continue
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
			--branch)
				take_value "$1" "${branch}" "${2-}"
				branch=${option_value}
				;;
			--from-head)
				take_value "$1" "${from_head}" "${2-}"
				from_head=${option_value}
				;;
			--follows)
				take_value "$1" "${follows}" "${2-}"
				follows=${option_value}
				;;
			--task)
				take_value "$1" "${task}" "${2-}"
				task=${option_value}
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
		opened) require --branch "${branch}" NAME ;;
		move)
			require --base "${base}" SHA
			require --from-head "${from_head}" SHA
			;;
		task) require --task "${task}" TEXT ;;
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
	[ -z "${card}" ] || load_printer
}

# Sources ../cards/cards-lib.sh and checks the line printer it loads.
load_printer() {
	[ -f "${own_dir}/../cards/cards-lib.sh" ] ||
		die 4 "../cards/cards-lib.sh not found from ${PROG}'s folder; expected the procedure's scripts folders whole"
	# shellcheck source=../cards/cards-lib.sh
	. "${own_dir}/../cards/cards-lib.sh"
	# shellcheck disable=SC2310 # its status names the fault; set -e is not relied on inside
	card_load_printer lines || die 4 "${card_problem}"
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

# Refuses a --task of whitespace only.
check_task() {
	case ${task} in
		*[![:space:]]*) ;;
		*)
			record_rejections '{"refused": "task --task", "rule": "expected the task'"'"'s text"}'
			die 3 "--task holds no text; expected the task's text"
			;;
	esac
}

# Sets result to RUN_JQ's output over the seat list as it is now; the arguments
# are the checked command line after the command, read for --base-seat.
run_command() {
	place=0 left=$#
	while [ "${left}" -gt 0 ]; do
		if [ "$1" = --card ]; then
			shift
			left=$((left - 1))
			continue
		fi
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
		--arg status "${status}" --arg branch "${branch}" --arg from_head "${from_head}" \
		--arg follows "${follows}" --arg task_text "${task}" "$@" "${RUN_JQ}") ||
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
	[ "${exit_code}" -eq 0 ] || keep_rejections
	[ "${exit_code}" -ne 0 ] || [ "${changed}" = false ] || append_event
	output=$(printf '%s\n' "${result}" | jq -r '.out') || die 4 'jq failed reading the output; expected jq 1.6+'
	[ -z "${output}" ] || printf '%s\n' "${output}"
	[ "${exit_code}" -ne 0 ] || [ -z "${card}" ] || show_seat_line
	exit "${exit_code}"
}

# Prints the line find --card gives the seat in output, by its status.
show_seat_line() {
	seat_fields=$(printf '%s\n' "${output}" | jq -r '.status // "", .seat // "", .worktree // ""') ||
		die 4 'jq failed reading the seat found; expected jq 1.6+'
	found_status='' found_seat='' found_worktree=''
	{
		IFS= read -r found_status || :
		IFS= read -r found_seat || :
		IFS= read -r found_worktree || :
	} <<EOF
${seat_fields}
EOF
	case ${found_status} in
		gave-up) seat_line=report_gave_up ;;
		working) seat_line=run_not_committed ;;
		*) return 0 ;;
	esac
	# shellcheck disable=SC2310 # its status names the fault; set -e is not relied on inside
	hv_show_line "${card_show}" "${card_views}" "${seat_line}" "${effort_folder}" \
		--arg seat "${found_seat}" --arg worktree "${found_worktree}" ||
		die 4 "${hv_render_problem}; the seat is printed, its line not shown"
}

# Keeps a refused change's problems as faults; a read's refusal is not kept.
keep_rejections() {
	case " ${CHANGE_COMMANDS} " in
		*" ${command} "*) ;;
		*) return 0 ;;
	esac
	rejections=$(printf '%s\n' "${result}" | jq -c '.rejections[]') ||
		die 4 'jq failed reading the rejections; expected jq 1.6+'
	record_rejections "${rejections}"
}

# Writes each line of $1, a fault body, as one fault of the effort; a failed
# write is said on stderr and keeps the refusal's exit.
record_rejections() {
	[ -n "$1" ] || return 0
	body_file=$(mktemp) || {
		warn 'a refusal was not kept as a fault: mktemp failed; expected a writable TMPDIR'
		return 0
	}
	while IFS= read -r rejection; do
		if ! printf '%s\n' "${rejection}" >"${body_file}" ||
			! sh "${events_script}" fault --effort "${effort_folder}" --by "${PROG}" --body-file "${body_file}" >/dev/null </dev/null; then
			warn 'a refusal was not kept as a fault (events.sh stderr above)'
		fi
	done <<EOF
$1
EOF
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
[ "${command}" != task ] || check_task
shift
run_command "$@"
finish
