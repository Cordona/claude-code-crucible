#!/usr/bin/env sh
# Starts, lists and finds the effort folders of the Crucible space, one folder
# per effort, <space>/efforts/<id>-<name>/, and keeps each effort's state as
# effort.* events, written through the crucible skill's events.sh. It never
# deletes or renames anything in an effort folder, except that start removes
# the folder it just made when it fails.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077

readonly PROG='effort.sh'
readonly CRUCIBLE_SKILL='crucible'
readonly METRICS_SKILL='procedure-metrics'
# The default list keeps the newest efforts on one screen; --all lifts it.
readonly LIST_LIMIT=20
# A clash needs the same second and the same 4 random hex digits; a handful of
# fresh draws makes a repeat practically impossible.
readonly MAX_START_ATTEMPTS=5
# Unknown arguments are echoed back only up to this length, so a long or
# hostile value never floods a diagnostic.
readonly MAX_SHOWN_CHARS=40
# The exit of a state change refused because the events lock was held too long.
readonly LOCKED_EXIT=6
# The exit of a state change the moves do not allow.
readonly BAD_MOVE_EXIT=7
# Claude Code writes the transcript line of the API call that ran this script
# only after the call returns; the harvest waits this long so it counts it.
readonly HARVEST_DELAY_SECONDS=10

usage() {
	print_block <<'EOF'
usage: effort.sh start --name NAME
       effort.sh pause|complete|drop|reopen --effort FOLDER
       effort.sh state --effort FOLDER
       effort.sh list [--all]
       effort.sh path VALUE
       effort.sh --help | -h
EOF
}

# NAME's rule and its 40 mirror crucible_effort_name_max_chars and
# crucible_effort_name_rule (lib/crucible-space.sh); --help prints before it
# loads, so update this when they change.
help_text() {
	usage
	print_block <<'EOF'

Starts, lists and finds the Crucible space's effort folders,
<space>/efforts/<id>-<name>/, and keeps each effort's state, one of
effort_states in effort-state-validator.jq. Each change is one effort.* event
in the effort's events/; the newest is the state. Event types and moves: see
effort-state-validator.jq (effort_type_states, effort_moves).

  ID      <YYYYMMDDTHHMMSS>-<hex>: the local start time and 4 random lowercase
          hex digits
  NAME    words of a-z and 0-9 joined by single dashes, 1 to 40 characters
  --name NAME      start: the new effort's NAME
  --effort FOLDER  pause, complete, drop, reopen, state: an effort folder
                   directly in <space>/efforts/, absolute
  --all            list: every effort, not only the newest 20
  VALUE            path: a full ID, its 4 hex digits or an exact NAME
  CLAUDE_CODE_SESSION_ID  start and the moves: required; the session ID
                   Claude Code sets, a lowercase UUID
  CRUCIBLE_HOME    the space; default $HOME/.crucible
  CLAUDE_CONFIG_DIR  holds skills/ and projects/; default $HOME/.claude

stdout on exit 0, in order:
  EFFORT: <folder>  start only: the new effort folder, absolute
  STATE: <state>    start, the moves and state: the state after the call
  EVENT: <path>     start and the moves: the new event; state: each effort.*
                    event, oldest first
  list:  one "<id>-<name> <state>" per line, newest first; <state> unknown
         for a folder with no events (an effort from before events)
  path:  the matching effort's folder, absolute, one line
stderr: "effort.sh:" lines to show the human, except:
  list, over 20 and no --all:
    "effort.sh: showing 20 of <N>; add --all for every effort"
  path, exit 1 with matches: each <id>-<name>, unprefixed, newest first

pause, complete and drop start procedure-metrics' harvest, detached, when
procedure-metrics is installed and nohup is on PATH.
start creates the effort folder, and the space and efforts/ when missing; a
failed start removes its new folder unless that removal fails (stderr then
names the folder). Nothing else is left behind but, after a move, a fault in
events/faults/ when events.sh refuses or times out (exits 5, 6, 7) (a SIGKILL
aside); no existing event or fault is ever deleted, renamed or rewritten.
list, path and state write nothing.

Exit codes:
  0  done; read stdout
  1  path: not exactly one effort matches VALUE; with efforts on stderr, ask
     which one is meant; with none, run list
  2  usage error; nothing written; show the human stderr, and stop
     effort.sh: bad name  start: NAME breaks the NAME rule; pick another NAME
       and rerun once, else show the human stderr
  4  the space or the effort can't be used; show the human stderr, and stop
  5  install fault; show the human stderr, and stop
  6  the events lock stayed held; no event written; rerun once, else show the
     human stderr
  7  the move is not allowed; no event written; show the human stderr, and stop
  129, 130, 143  stopped by HUP, INT or TERM; show the human stderr, and stop

Dependencies:
  POSIX sh; date, od (with /dev/urandom), mkdir, chmod, rmdir, ls, sort,
    mktemp, rm, sleep; jq 1.6+ but for path; nohup for the harvest
  the crucible skill's scripts/events.sh and scripts/lib/crucible-space.sh;
    effort-state-validator.jq and effort-move-guard.jq beside this script
EOF
}

# Copies stdin to stdout with the shell alone, so --help needs no tool.
print_block() {
	while IFS= read -r line; do
		printf '%s\n' "${line}"
	done
}

warn() {
	printf '%s: %s\n' "${PROG}" "$1" >&2
}

usage_error() {
	warn "$1"
	usage >&2
	exit 2
}

bad_value() {
	warn "$1"
	exit 2
}

space_fault() {
	warn "space: $1"
	exit 4
}

install_fault() {
	warn "install: $1"
	exit 5
}

main() {
	[ "$#" -gt 0 ] || usage_error 'a command is missing; expected start, pause, complete, drop, reopen, state, list, path or --help'
	command=$1
	shift
	case ${command} in
		--help | -h)
			[ "$#" -eq 0 ] || usage_error "${command} takes no arguments; expected ${command} alone"
			help_text
			exit 0
			;;
		start | pause | complete | drop | reopen | state | list | path) ;;
		*)
			show_safely "${command}"
			usage_error "unknown command: ${shown}; expected start, pause, complete, drop, reopen, state, list, path or --help"
			;;
	esac
	check_tools
	load_dependencies
	resolve_root
	efforts_dir="${root}/efforts"
	case ${command} in
		start) run_start "$@" ;;
		pause) run_move effort.paused "$@" ;;
		complete) run_move effort.completed "$@" ;;
		drop) run_move effort.dropped "$@" ;;
		reopen) run_move effort.reopened "$@" ;;
		state) run_state "$@" ;;
		list) run_list "$@" ;;
		*) run_path "$@" ;;
	esac
}

# Sets shown to a value fit to echo in a diagnostic.
show_safely() {
	case $1 in
		'') shown="''" ;;
		*[![:alnum:]._=-]*) shown='(a value with other characters)' ;;
		*)
			if [ "${#1}" -le "${MAX_SHOWN_CHARS}" ]; then
				shown="'$1'"
			else
				shown="(a value of ${#1} characters)"
			fi
			;;
	esac
}

check_tools() {
	for tool in date od mkdir chmod rmdir ls sort mktemp rm sleep; do
		command -v "${tool}" >/dev/null 2>&1 ||
			install_fault "${tool} missing; expected it on PATH; try installing the base-system tools (coreutils on Linux)"
	done
	[ "${command}" != path ] || return 0
	command -v jq >/dev/null 2>&1 ||
		install_fault 'jq missing; expected jq 1.6+ on PATH; try brew install jq (macOS) or the distro jq package'
}

# Sources the crucible skill's space rules and sets own_dir and events_script,
# or exits 5.
load_dependencies() {
	crucible_dir="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/skills/${CRUCIBLE_SKILL}/scripts"
	space_lib="${crucible_dir}/lib/crucible-space.sh"
	events_script="${crucible_dir}/events.sh"
	require_file "${space_lib}" 'space rules' "try installing the ${CRUCIBLE_SKILL} skill"
	case $0 in
		*/*) own_dir=${0%/*} ;;
		*) own_dir=. ;;
	esac
	case ${command} in
		path) ;;
		list) require_file "${own_dir}/effort-state-validator.jq" 'state rules' 'try reinstalling procedure-effort' ;;
		*)
			require_file "${own_dir}/effort-state-validator.jq" 'state rules' 'try reinstalling procedure-effort'
			require_file "${own_dir}/effort-move-guard.jq" 'move guard' 'try reinstalling procedure-effort'
			require_file "${events_script}" 'events.sh' "try installing the ${CRUCIBLE_SKILL} skill"
			;;
	esac
	# shellcheck source=../../../../engine/crucible/scripts/lib/crucible-space.sh
	. "${space_lib}"
	case ${command} in
		path | start) ;;
		*) load_type_states ;;
	esac
}

# Sets type_states to effort_type_states of effort-state-validator.jq, one
# "<type> <state>" per line, so every state read uses that one definition.
load_type_states() {
	type_states=$(jq -nr -L "${own_dir}" \
		'include "effort-state-validator"; effort_type_states | to_entries[] | "\(.key) \(.value)"' </dev/null) ||
		install_fault 'jq failed on the state rules; expected jq 1.6+ and effort-state-validator.jq; try reinstalling procedure-effort'
}

# Exits 5 unless file $1, named $2, is readable; $3 is the fix.
require_file() {
	[ -f "$1" ] && [ -r "$1" ] || install_fault "$2 missing; expected $1; $3"
}

resolve_root() {
	# shellcheck disable=SC2310 # its status says whether the root is usable; the fault is read below
	if ! crucible_resolve_root; then
		[ "${crucible_root_fault}" != usage ] || usage_error "${crucible_root_problem}"
		space_fault "${crucible_root_problem}"
	fi
	root=${crucible_root}
}

refuse_link() {
	[ ! -L "$1" ] || space_fault "$1 is a symbolic link; expected a real folder; try pointing CRUCIBLE_HOME at the target instead"
}

run_start() {
	name='' name_given=false
	while [ "$#" -gt 0 ]; do
		case $1 in
			--name)
				[ "${name_given}" = false ] || usage_error '--name given twice; expected it once; try start --name NAME'
				[ "$#" -ge 2 ] || usage_error '--name needs a value; expected start --name NAME'
				name=$2 name_given=true
				shift 2
				;;
			*)
				show_safely "$1"
				usage_error "unknown argument for start: ${shown}; expected --name NAME"
				;;
		esac
	done
	[ "${name_given}" = true ] || usage_error '--name missing; expected start --name NAME'
	check_name
	check_session
	refuse_link "${efforts_dir}"
	create_space_folder "${root}"
	create_space_folder "${efforts_dir}"
	start_effort
	effort=${folder}
	started_folder=${folder}
	body_file=$(mktemp) || install_fault 'mktemp failed; expected a writable temp folder; try checking TMPDIR'
	printf '{}\n' >"${body_file}"
	append_event effort.opened
	started_folder=''
	printf 'EFFORT: %s\n' "${folder}"
	printf 'STATE: open\nEVENT: %s\n' "${event_file}"
}

# Exits 2 unless name keeps the space rules' effort NAME rule.
check_name() {
	# shellcheck disable=SC2310 # a pure test; its status is the answer
	crucible_is_effort_words "${name}" && return 0
	case ${name} in
		*[!abcdefghijklmnopqrstuvwxyz0123456789-]*)
			describe_first_bad_char
			bad_value "bad name: it holds ${bad_char}; expected only a-z, 0-9 and - (the effort name rule); try a lowercase slug such as prune-dry-run"
			;;
		*) ;;
	esac
	if [ "${#name}" -lt 1 ] || [ "${#name}" -gt "${crucible_effort_name_max_chars}" ]; then
		bad_value "bad name: it is ${#name} characters; expected 1 to ${crucible_effort_name_max_chars} (the effort name rule); try a slug of up to 3 words"
	fi
	describe_dash_fault "${name}"
	[ -z "${dash_fault}" ] ||
		bad_value "bad name: ${dash_fault}; expected words of a-z and 0-9 joined by single - (the effort name rule); try a slug such as prune-dry-run"
	bad_value "bad name: it breaks the effort name rule; expected the NAME of ${crucible_effort_name_rule}; try a slug such as prune-dry-run"
}

# Sets session_id from CLAUDE_CODE_SESSION_ID, or exits 2 before anything is created.
check_session() {
	# shellcheck disable=SC2310 # its status says whether the session is usable; the problem is read here
	crucible_check_session || bad_value "${crucible_session_problem}"
	session_id=${crucible_session_id}
}

describe_dash_fault() {
	case $1 in
		-*) dash_fault='it starts with -' ;;
		*-) dash_fault='it ends with -' ;;
		*--*) dash_fault='it holds a double dash' ;;
		*) dash_fault='' ;;
	esac
}

describe_first_bad_char() {
	valid_prefix=${name%%[!abcdefghijklmnopqrstuvwxyz0123456789-]*}
	from_bad=${name#"${valid_prefix}"}
	first=${from_bad%"${from_bad#?}"}
	position=$((${#valid_prefix} + 1))
	case ${first} in
		' ') bad_char="a space at character ${position}" ;;
		[[:graph:]]) bad_char="'${first}' at character ${position}" ;;
		*) bad_char="a non-printable character at character ${position}" ;;
	esac
}

# Creates a folder of the space, and any missing parent, when it is missing.
create_space_folder() {
	refuse_link "$1"
	if [ -e "$1" ] && [ ! -d "$1" ]; then
		space_fault "$1 exists and is not a folder; expected a folder of the space; try moving it aside"
	fi
	if [ ! -d "$1" ]; then
		mkdir -p "$1" 2>/dev/null || [ -d "$1" ] ||
			space_fault "cannot create $1; expected a writable parent folder; try checking its permissions"
	fi
	refuse_link "$1"
}

start_effort() {
	attempt=1
	while :; do
		# shellcheck disable=SC2310 # its status says whether an ID was minted; the problem is read below
		crucible_mint_id || install_fault "${crucible_id_problem}"
		id=${crucible_id}
		folder="${efforts_dir}/${id}-${name}"
		if mkdir "${folder}" 2>/dev/null; then
			chmod 700 "${folder}" || {
				rmdir "${folder}" 2>/dev/null || true
				space_fault "cannot set mode 700 on ${folder}; expected a folder it owns; try checking the space's owner"
			}
			count_id_holders
			[ "${id_holders}" -ne 1 ] || break
			rmdir "${folder}" ||
				space_fault "cannot remove its own new folder ${folder} after an ID clash; expected it empty; try start again"
		elif [ ! -e "${folder}" ] && [ ! -L "${folder}" ]; then
			space_fault "cannot create a folder in ${efforts_dir}; expected a writable folder; try checking its permissions"
		fi
		[ "${attempt}" -lt "${MAX_START_ATTEMPTS}" ] ||
			space_fault "no free ID found after ${MAX_START_ATTEMPTS} attempts; expected a free one; try start again"
		attempt=$((attempt + 1))
	done
}

# Sets id_holders to the number of entries in efforts/ that carry the ID.
count_id_holders() {
	id_holders=0
	for holder in "${efforts_dir}/${id}"-*; do
		[ -e "${holder}" ] || [ -L "${holder}" ] || continue
		id_holders=$((id_holders + 1))
	done
}

# pause, complete, drop and reopen: moves the effort with event type $1 to
# the state effort_type_states gives it. The move is checked here for a clear
# refusal, and again by the guard under the events lock.
run_move() {
	event_type=$1
	shift
	state_of_type "${event_type}"
	[ -n "${type_state}" ] ||
		install_fault "the state rules give ${event_type} no state; expected it in effort_type_states of effort-state-validator.jq; try reinstalling procedure-effort"
	target=${type_state}
	parse_effort_option "$@"
	check_session
	read_state
	refusal=$(jq -nr -L "${own_dir}" --arg from "${current_state}" --arg to "${target}" \
		'include "effort-state-validator"; effort_move_refusal($from; $to)' </dev/null) ||
		install_fault 'jq failed on the move rules; expected jq 1.6+ and effort-state-validator.jq; try reinstalling procedure-effort'
	if [ -n "${refusal}" ]; then
		warn "${refusal}"
		exit "${BAD_MOVE_EXIT}"
	fi
	body_file=$(mktemp) || install_fault 'mktemp failed; expected a writable temp folder; try checking TMPDIR'
	printf '{}\n' >"${body_file}" ||
		install_fault 'writing the move failed; expected a writable temp folder; try checking TMPDIR'
	append_event "${event_type}"
	printf 'STATE: %s\nEVENT: %s\n' "${target}" "${event_file}"
	[ "${target}" = open ] || start_metrics_harvest
}

# Appends an event of type $1 with body_file through events.sh; sets event_file.
append_event() {
	if event_file=$(sh "${events_script}" append --effort "${effort}" --type "$1" --by "${PROG}" \
		--body-file "${body_file}" --session "${session_id}" --guard "${own_dir}/effort-move-guard.jq" </dev/null); then
		append_status=0
	else
		append_status=$?
	fi
	rm -f "${body_file}"
	body_file=''
	case ${append_status} in
		0) ;;
		3)
			warn 'the move was refused under the events lock (events.sh stderr above); expected a move the effort state allows; try effort.sh state for the state now'
			exit "${BAD_MOVE_EXIT}"
			;;
		6) exit "${LOCKED_EXIT}" ;;
		4) space_fault "events.sh could not write the event (its stderr is above); expected a writable ${effort}/events/; try checking its permissions" ;;
		*) install_fault "events.sh exited ${append_status} (its stderr is above); expected exit 0; try reinstalling the ${CRUCIBLE_SKILL} skill" ;;
	esac
}

# Starts procedure-metrics' harvest of the effort detached, when it is
# installed; nothing waits for it. The harvest waits HARVEST_DELAY_SECONDS first.
start_metrics_harvest() {
	metrics_script="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/skills/${METRICS_SKILL}/scripts/metrics.sh"
	[ -f "${metrics_script}" ] && [ -r "${metrics_script}" ] || return 0
	if ! command -v nohup >/dev/null 2>&1; then
		warn "nohup missing, so the ${METRICS_SKILL} harvest did not start; expected nohup on PATH; try installing the base-system tools (coreutils on Linux)"
		return 0
	fi
	# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are the inner sh's
	nohup sh -c 'sleep "$1"; exec sh "$2" harvest --effort "$3"' metrics-harvest \
		"${HARVEST_DELAY_SECONDS}" "${metrics_script}" "${effort}" </dev/null >/dev/null 2>&1 &
}

# Sets effort from the one --effort FOLDER option once it names an effort
# folder of the space.
parse_effort_option() {
	effort='' effort_given=false
	while [ "$#" -gt 0 ]; do
		case $1 in
			--effort)
				[ "${effort_given}" = false ] || usage_error "--effort given twice; expected it once; try ${command} --effort FOLDER"
				[ "$#" -ge 2 ] || usage_error "--effort needs a value; expected ${command} --effort FOLDER"
				effort=$2 effort_given=true
				shift 2
				;;
			*)
				show_safely "$1"
				usage_error "unknown argument for ${command}: ${shown}; expected --effort FOLDER"
				;;
		esac
	done
	[ "${effort_given}" = true ] || usage_error "--effort missing; expected ${command} --effort FOLDER"
	case ${effort} in
		*[[:cntrl:]]*) bad_value '--effort holds a control character; expected the effort folder effort.sh start printed; try the folder effort.sh path prints' ;;
		*) ;;
	esac
	# shellcheck disable=SC2310 # its status says whether the folder passed; the fault is read below
	if ! crucible_check_effort_folder "${effort}"; then
		[ "${crucible_effort_fault}" = space ] || bad_value "${crucible_effort_refusal}"
		space_fault "${crucible_effort_refusal}"
	fi
	effort=${crucible_effort}
}

# Sets effort_events to the effort's effort.* event paths, oldest first, one
# per line, and current_state to the newest one's state; exits 4 for an
# effort with no events, one from before events.
read_state() {
	events_dir="${effort}/events"
	[ -f "${events_dir}/000001-effort.opened.json" ] ||
		space_fault "${effort} has no events/000001-effort.opened.json; expected an effort this version of Crucible started; an effort from before events cannot be used; try another effort, or start a new one"
	effort_events='' newest_type=''
	for named in "${events_dir}"/[0-9][0-9][0-9][0-9][0-9][0-9]-effort.*.json; do
		[ -f "${named}" ] || continue
		effort_events="${effort_events}${named}
"
		newest_type=${named##*/}
		newest_type=${newest_type#*-}
		newest_type=${newest_type%.json}
	done
	state_of_type "${newest_type}"
	[ -n "${type_state}" ] ||
		space_fault "no effort.* event names a known state in ${effort}/events; expected effort.opened first; try showing the human the event files in events/, which only events.sh writes"
	current_state=${type_state}
}

# Sets type_state to the state effort.* event type $1 records, or to empty
# for a type type_states does not hold.
state_of_type() {
	type_state=''
	while IFS=' ' read -r known_type known_state; do
		[ "${known_type}" != "$1" ] || type_state=${known_state}
	done <<EOF
${type_states}
EOF
}

run_state() {
	parse_effort_option "$@"
	read_state
	printf 'STATE: %s\n' "${current_state}"
	printf '%s' "${effort_events}" | while IFS= read -r listed; do
		printf 'EVENT: %s\n' "${listed}"
	done
}

run_list() {
	show_all=false
	while [ "$#" -gt 0 ]; do
		case $1 in
			--all)
				[ "${show_all}" = false ] || usage_error '--all given twice; expected it at most once; try list --all'
				show_all=true
				shift
				;;
			*)
				show_safely "$1"
				usage_error "unknown argument for list: ${shown}; expected --all or nothing"
				;;
		esac
	done
	collect_efforts
	[ -n "${efforts_found}" ] || return 0
	total=0
	while IFS= read -r entry; do
		total=$((total + 1))
		[ "${show_all}" = true ] || [ "${total}" -le "${LIST_LIMIT}" ] || continue
		effort="${efforts_dir}/${entry}"
		if [ -f "${effort}/events/000001-effort.opened.json" ]; then
			newest_type=''
			for named in "${effort}"/events/[0-9][0-9][0-9][0-9][0-9][0-9]-effort.*.json; do
				[ -f "${named}" ] || continue
				newest_type=${named##*/}
				newest_type=${newest_type#*-}
				newest_type=${newest_type%.json}
			done
			state_of_type "${newest_type}"
			listed_state=${type_state:-unknown}
		else
			listed_state=unknown
		fi
		printf '%s %s\n' "${entry}" "${listed_state}"
	done <<EOF
${efforts_found}
EOF
	if [ "${show_all}" = false ] && [ "${total}" -gt "${LIST_LIMIT}" ]; then
		warn "showing ${LIST_LIMIT} of ${total}; add --all for every effort"
	fi
}

run_path() {
	[ "$#" -eq 1 ] || usage_error 'path takes exactly one VALUE; expected path VALUE; try list --all for the IDs'
	value=$1
	case ${value} in
		'') bad_value 'VALUE is empty; expected a full ID, its 4 hex digits or an exact name; try list --all' ;;
		*[!abcdefghijklmnopqrstuvwxyzT0123456789-]*)
			bad_value 'VALUE holds a character outside a-z, 0-9, T and -; expected a full ID, its 4 hex digits or an exact name; try list --all'
			;;
		*) ;;
	esac
	describe_dash_fault "${value}"
	[ -z "${dash_fault}" ] ||
		bad_value "bad VALUE: ${dash_fault}; expected a full ID, its 4 hex digits or an exact name, words joined by single -; try list --all"
	collect_efforts
	match_efforts
	if [ "${match_count}" -eq 1 ]; then
		printf '%s/%s\n' "${efforts_dir}" "${matches}"
		return 0
	fi
	if [ "${match_count}" -eq 0 ]; then
		warn "no effort matches '${value}'; expected a full ID, its 4 hex digits or the exact name of an effort; try list --all"
		exit 1
	fi
	printf '%s\n' "${matches}" >&2
	warn "${match_count} efforts match '${value}'; expected one; try path with the full ID of the one meant"
	exit 1
}

# Sets matches to the efforts whose ID, hex or name equals value, newest
# first, one per line, and match_count to their number.
match_efforts() {
	matches='' match_count=0
	[ -n "${efforts_found}" ] || return 0
	while IFS= read -r entry; do
		split_entry "${entry}"
		if [ "${value}" = "${entry_id}" ] || [ "${value}" = "${entry_hex}" ] || [ "${value}" = "${entry_name}" ]; then
			matches="${matches:+${matches}
}${entry}"
			match_count=$((match_count + 1))
		fi
	done <<EOF
${efforts_found}
EOF
}

# Sets efforts_found to the effort folder names, newest first, one per line.
collect_efforts() {
	efforts_found=''
	[ -e "${root}" ] || return 0
	[ -d "${root}" ] || space_fault "${root} is not a folder; expected the space folder; try pointing CRUCIBLE_HOME elsewhere"
	refuse_link "${efforts_dir}"
	[ -e "${efforts_dir}" ] || return 0
	[ -d "${efforts_dir}" ] || space_fault "${efforts_dir} is not a folder; expected the efforts folder; try moving it aside"
	entries=$(ls "${efforts_dir}" 2>/dev/null) ||
		space_fault "cannot read ${efforts_dir}; expected a readable folder; try checking its permissions"
	accepted=''
	while IFS= read -r entry; do
		split_entry "${entry}"
		[ -n "${entry_id}" ] || continue
		[ -d "${efforts_dir}/${entry}" ] && [ ! -L "${efforts_dir}/${entry}" ] || continue
		accepted="${accepted}${entry}
"
	done <<EOF
${entries}
EOF
	[ -n "${accepted}" ] || return 0
	# Effort names lead with their timestamp, so a reversed byte sort is newest first.
	efforts_found=$(printf '%s' "${accepted}" | LC_ALL=C sort -r) ||
		install_fault 'sort failed; expected a POSIX sort; try a POSIX sort on PATH'
}

# Sets entry_id, entry_hex and entry_name from an effort folder name <id>-<name>.
split_entry() {
	entry_id='' entry_hex='' entry_name=''
	# shellcheck disable=SC2310 # a pure test; its status is the answer
	crucible_is_effort_name "$1" || return 0
	entry_id=${crucible_name_id}
	entry_hex=${entry_id##*-}
	entry_name=${crucible_name_rest}
}

# Removes a temp body file and, on a failing start, the folder start made.
# shellcheck disable=SC2329 # invoked by the EXIT trap
clean_up() {
	exit_status=$?
	[ -z "${body_file}" ] || rm -f "${body_file}"
	if [ "${exit_status}" -ne 0 ] && [ -n "${started_folder}" ]; then
		rm -rf "${started_folder}/events" 2>/dev/null || true
		if rmdir "${started_folder}" 2>/dev/null; then
			warn "removed ${started_folder}, made by this run"
		else
			warn "left ${started_folder}, made by this run; remove it by hand"
		fi
	fi
}

body_file='' started_folder='' session_id=''
trap clean_up EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

main "$@"
