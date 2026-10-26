#!/usr/bin/env sh
# Starts, lists and finds the effort folders of the Crucible space, one folder
# per effort, <space>/efforts/<id>-<name>/, and keeps each effort's state as
# write-once items in its states/ folder. It never deletes or renames anything
# in an effort folder, except that start removes what it just made when it
# fails, and a state change removes its own empty item when it cannot fill it.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077

readonly PROG='effort.sh'
readonly KIND='states'
readonly CRUCIBLE_SKILL='crucible'
# The default list keeps the newest efforts on one screen; --all lifts it.
readonly LIST_LIMIT=20
# A clash needs the same second and the same 4 random hex digits; a handful of
# fresh draws makes a repeat practically impossible.
readonly MAX_START_ATTEMPTS=5
# Unknown arguments are echoed back only up to this length, so a long or
# hostile value never floods a diagnostic.
readonly MAX_SHOWN_CHARS=40
# The exit of a state change refused because another call holds the lock.
readonly LOCKED_EXIT=6
# The exit of a state change the moves do not allow.
readonly BAD_MOVE_EXIT=7
# Item IDs carry the second only, so a new item waits until the clock is past
# the newest one's second; a clock still behind after this many seconds was
# set back, and waiting longer would not help.
readonly MAX_CLOCK_WAIT_SECONDS=2
# A reader that finds the newest item still empty while a writer holds the
# lock waits this many times one second for the writer to fill it.
readonly MAX_EMPTY_ITEM_WAITS=3
# Bounds stderr so a fault stays readable; the rest is counted.
readonly MAX_PROBLEMS=20

# Reads the $count items passed as $ARGS.named pairs p<n> (the path) and
# i<n> (its text) into $items, each {path, parsed, problems}: its problems
# against effort-state-validator.jq, plus a state other than its file name's.
# The head of ITEMS_JQ and LIST_JQ; the program is single-quoted on purpose:
# its $ signs are jq's.
# shellcheck disable=SC2016
readonly READ_ITEMS_JQ='include "effort-state-validator";
$ARGS.named as $named
| [range(0; $count) | {path: $named["p\(.)"], parsed: [$named["i\(.)"] | try fromjson]}
	| .path as $path
	| ($path | sub("^.*/[0-9]{8}T[0-9]{6}-[0-9a-f]{4}-"; "") | sub("[.]json$"; "")) as $label
	| .problems = [if (.parsed | length) == 0 then "is not one JSON value; expected a state item effort.sh writes"
		else .parsed[0]
			| (effort_state_item_problems),
			  (if (.state | effort_is_state) and .state != $label then "holds state \(.state) under the name \($label); expected the state its file name holds" else empty end)
		end]] as $items'

# Prints each item's state, one per line in order; or, when any item is
# broken, a "!" line and then one "<path>: <problem>" line per problem.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly ITEMS_JQ="${READ_ITEMS_JQ}"'
| [$items[] | .path as $path | .problems[] | "\($path): \(.)"] as $problems
| if ($problems | length) == 0 then $items[].parsed[0].state
  else "!", $problems[:$max][],
	(if ($problems | length) > $max then "\($problems | length) problems, showing \($max)" else empty end)
  end'

# list: prints one line per item in order: its state; or, for a broken item,
# "unknown" and then one line naming it and its first problem.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly LIST_JQ="${READ_ITEMS_JQ}"'
| $items[]
| if (.problems | length) == 0 then .parsed[0].state
  else "unknown",
	"\(.path): \(.problems[0])\(if (.problems | length) > 1 then " (and \(.problems | length - 1) more)" else "" end)"
  end'

# Prints {item} for the move from $from ("" for the first item, which start
# writes) to $to, pruned so an empty from or session is left out, its at
# left for the write to set; or {refusal} when the moves do not allow it.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly MOVE_JQ='include "effort-state-validator";
include "prune";
{open: "reopen", paused: "pause", completed: "complete", dropped: "drop"} as $commands
| if $from == "" or effort_move_ok($from; $to) then
	{item: ({state: $to, from: (if $from == "" then null else $from end), at: "", session: (if $session == "" then null else $session end)} | prune)}
  elif $from == $to then {refusal: "bad move: \($from) -> \($to); the effort is already \($to)"}
  else {refusal: "bad move: \($from) -> \($to); a \($from) effort can only move to \(effort_moves[$from] | map("\(.) (\($commands[.]))") | join(" or "))"}
  end'

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
# crucible_effort_name_rule (lib/crucible-space.sh), and the moves mirror
# effort_moves (effort-state-validator.jq), which callers pick a move from;
# --help prints before either loads, so update this when they change.
help_text() {
	usage
	print_block <<'EOF'

Starts, lists and finds the Crucible space's effort folders,
<space>/efforts/<id>-<name>/, and keeps each effort's state: open, paused,
completed or dropped. One item per change in the effort's states/ folder; the
newest is the state, none is open. Moves: open -> paused|completed|dropped,
paused -> open|completed|dropped, completed|dropped -> open. Item shape:
effort-state-validator.jq.

  ID      <YYYYMMDDTHHMMSS>-<hex>: the local start time and 4 random lowercase
          hex digits; never reused
  NAME    words of a-z and 0-9 joined by single dashes, 1 to 40 characters
  --name NAME      start: the new effort's NAME
  --effort FOLDER  pause, complete, drop, reopen, state: an effort folder
                   directly in <space>/efforts/, absolute
  --all            list: every effort, not only the newest 20
  VALUE            path: a full ID, its 4 hex digits or an exact NAME
  CLAUDE_CODE_SESSION_ID  the session each new item names; unset or empty: none
  CRUCIBLE_HOME    the space; default $HOME/.crucible
  CLAUDE_CONFIG_DIR  holds the skills, in its skills/; default $HOME/.claude

stdout on exit 0, in this order:
  EFFORT: <folder>  start only: the new effort folder, absolute
  STATE: <state>    start, the moves and state: the effort's state after the
                    call (start: open)
  ITEM: <path>      a state item, absolute: start and the moves print the new
                    one; state one per item, oldest first, none when none
  list:  one "<id>-<name> <state>" per line, newest first; <state> unknown
         when the effort's state items are broken
  path:  the matching effort's folder, absolute, one line
stderr: "effort.sh:" lines to show the human, except:
  list, over 20 and no --all: "effort.sh: showing 20 of <N>; add --all for
    every effort"
  path, exit 1 with matches: each <id>-<name>, unprefixed, newest first
  list, per unknown effort: "effort.sh: space: <file>: <why>", exit 0

start creates the effort folder, mode 700, and the space and efforts/ when
missing; a failed start leaves no new folder unless stderr names it. A state
change adds one item, whole, mode 600; refused or failed, it adds none. list,
path and state write nothing. Nothing is written through a symbolic link.
Nothing else is left behind (a SIGKILL aside: it can leave the lock, a temp
file or an empty item, which reads as exit 4 until removed).

Exit codes:
  0  done; read stdout
  1  path: no effort matches VALUE, or several do; with matches on stderr,
     ask which one is meant; with none, run list
  2  usage error, or an unusable CRUCIBLE_HOME, HOME or CLAUDE_CODE_SESSION_ID;
     show the human stderr, and stop
     effort.sh: bad name:  start: NAME breaks the rule; pick another name
  4  the space, an effort folder or a state item is unusable; show the human
     stderr, and stop
  5  install fault; show the human stderr, and stop
  6  another call is changing the effort's state, or a killed run left its
     lock; nothing written; rerun once, else show the human stderr
  7  the move is not allowed; nothing written; show the human stderr
  129, 130, 143  stopped by HUP, INT or TERM; show the human stderr, and stop

Dependencies (a missing one exits 5):
  POSIX sh; date, od (with /dev/urandom), mkdir, chmod, rmdir, ls, sort,
    mktemp, mv, rm, sleep (macOS and Linux base systems); jq 1.6+ but for
    path (macOS: brew install jq; Linux: the distro's jq package)
  in the skills: the crucible skill's
    crucible.sh, lib/crucible-space.sh and lib/prune.jq;
    effort-state-validator.jq beside this script
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
	# Checked before a command's arguments, so a missing tool or space rules
	# exit 5 ahead of any usage error in them.
	check_tools
	load_dependencies
	resolve_root
	efforts_dir="${root}/efforts"
	case ${command} in
		start) run_start "$@" ;;
		pause) run_move paused "$@" ;;
		complete) run_move completed "$@" ;;
		drop) run_move dropped "$@" ;;
		reopen) run_move open "$@" ;;
		state) run_state "$@" ;;
		list) run_list "$@" ;;
		*) run_path "$@" ;;
	esac
}

# Sets shown to a value fit to echo in a diagnostic: the value itself when it
# is short and plain, else a description, so no control character reaches a log.
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
	for tool in date od mkdir chmod rmdir ls sort mktemp mv rm sleep; do
		command -v "${tool}" >/dev/null 2>&1 ||
			install_fault "${tool} missing; expected it on PATH; try installing the base-system tools (coreutils on Linux)"
	done
	[ "${command}" != path ] || return 0
	command -v jq >/dev/null 2>&1 ||
		install_fault 'jq missing; expected jq 1.6+ on PATH; try brew install jq (macOS) or the distro jq package'
	jq_version=$(jq --version 2>/dev/null) || install_fault 'jq --version failed; expected jq 1.6+; try reinstalling jq'
	case ${jq_version} in
		jq-1.[6-9]* | jq-1.[1-9][0-9]* | jq-[2-9]*) ;;
		*) install_fault "jq is ${jq_version}; expected jq 1.6+; try upgrading jq" ;;
	esac
}

# Sources the crucible skill's space rules and sets own_dir (the validator),
# crucible_lib_dir (prune.jq) and crucible_script, or exits 5.
load_dependencies() {
	crucible_dir="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/skills/${CRUCIBLE_SKILL}/scripts"
	crucible_lib_dir="${crucible_dir}/lib"
	crucible_script="${crucible_dir}/crucible.sh"
	space_lib="${crucible_lib_dir}/crucible-space.sh"
	require_file "${space_lib}" 'space rules' "try installing the ${CRUCIBLE_SKILL} skill"
	if [ "${command}" != path ]; then
		case $0 in
			*/*) own_dir=${0%/*} ;;
			*) own_dir=. ;;
		esac
		require_file "${own_dir}/effort-state-validator.jq" 'state item shape' 'try reinstalling procedure-effort'
		require_file "${crucible_lib_dir}/prune.jq" 'prune module' "try installing the ${CRUCIBLE_SKILL} skill"
		require_file "${crucible_script}" 'crucible.sh' "try installing the ${CRUCIBLE_SKILL} skill"
	fi
	# shellcheck source=../../../../engine/crucible/scripts/lib/crucible-space.sh
	. "${space_lib}"
}

# Exits 5 unless file $1, named $2, is readable; $3 is the fix.
require_file() {
	[ -f "$1" ] && [ -r "$1" ] || install_fault "$2 missing; expected $1; $3"
}

# Sets root from the space rules, or exits 2 or 4 with their problem.
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
	states_dir="${effort}/${KIND}"
	started_folder=${folder}
	take_lock
	collect_items
	write_item open ''
	started_folder=''
	printf 'EFFORT: %s\n' "${folder}"
	printf 'STATE: open\nITEM: %s\n' "${item_file}"
}

# Exits 2 unless name keeps the space rules' effort NAME rule; the checks
# after the rule's own test only say why it failed.
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

# Sets session from CLAUDE_CODE_SESSION_ID, or exits 2 when it holds anything
# but what the item's session may hold.
check_session() {
	session=${CLAUDE_CODE_SESSION_ID:-}
	case ${session} in
		*[!0123456789abcdef-]*)
			bad_value 'CLAUDE_CODE_SESSION_ID holds a character outside 0-9, a-f and -; expected the session ID Claude Code sets; try unsetting it'
			;;
		*) ;;
	esac
}

# Sets dash_fault to why the dashes of $1 break the word rule (words joined by
# single dashes), or to empty when they keep it.
describe_dash_fault() {
	case $1 in
		-*) dash_fault='it starts with -' ;;
		*-) dash_fault='it ends with -' ;;
		*--*) dash_fault='it holds a double dash' ;;
		*) dash_fault='' ;;
	esac
}

# Sets bad_char to a description of the name's first character outside the rule.
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

# Creates a folder of the space, and any missing parent, when it is missing;
# the umask makes each mode 700.
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

# Sets id_holders to the number of entries in efforts/ that carry the ID. Each
# start counts after its own mkdir, so of two racing for one ID at most one
# sees itself alone.
count_id_holders() {
	id_holders=0
	for holder in "${efforts_dir}/${id}"-*; do
		[ -e "${holder}" ] || [ -L "${holder}" ] || continue
		id_holders=$((id_holders + 1))
	done
}

# pause, complete, drop and reopen: moves the effort to state $1 under its lock.
run_move() {
	target=$1
	shift
	parse_effort_option "$@"
	check_session
	take_lock
	read_newest_state
	write_item "${target}" "${current_state}"
	printf 'STATE: %s\nITEM: %s\n' "${target}" "${item_file}"
}

# Sets effort from the one --effort FOLDER option once it names an effort
# folder of the space, and states_dir to its states/ folder.
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
		*[[:cntrl:]]*) bad_value '--effort holds a control character; expected the effort folder effort.sh start printed' ;;
		*) ;;
	esac
	# shellcheck disable=SC2310 # its status says whether the folder passed; the fault is read below
	if ! crucible_check_effort_folder "${effort}"; then
		[ "${crucible_effort_fault}" = space ] || bad_value "${crucible_effort_refusal}"
		space_fault "${crucible_effort_refusal}"
	fi
	effort=${crucible_effort}
	states_dir="${effort}/${KIND}"
}

# Takes the effort's lock, a folder only one call can create, so one state
# change at a time reads the newest item and adds the next. clean_up removes
# it; a killed run leaves it, and the refusal says how to remove it.
take_lock() {
	lock_path="${effort}/.${KIND}.lock"
	if mkdir "${lock_path}" 2>/dev/null; then
		lock_dir=${lock_path}
		return 0
	fi
	[ -d "${lock_path}" ] && [ ! -L "${lock_path}" ] ||
		space_fault "cannot create the lock ${lock_path}; expected a writable effort folder; try checking its permissions"
	warn "${effort} is locked by ${lock_path}; expected one state change at a time; try again once the other call has ended; if none is running, a killed run left the lock: remove it with rmdir '${lock_path}', then rerun"
	exit "${LOCKED_EXIT}"
}

# Sets newest_item (empty for none), newest_digits and newest_id from the
# effort's state items, and items to every item's file name, one per line, in
# folder order. Exits 4 on a states/ that is not a readable real folder or
# holds anything but items; dot entries (temp files) are skipped.
collect_items() {
	newest_item='' newest_digits=0 newest_hex=0 newest_id='' items=''
	refuse_link "${states_dir}"
	[ -e "${states_dir}" ] || return 0
	[ -d "${states_dir}" ] && [ -r "${states_dir}" ] && [ -x "${states_dir}" ] ||
		space_fault "${states_dir} is not a readable folder; expected the states folder effort.sh writes; try checking its permissions"
	for item_path in "${states_dir}"/*; do
		[ -e "${item_path}" ] || [ -L "${item_path}" ] || continue
		item_name=${item_path##*/}
		# shellcheck disable=SC2310 # a pure test; its status is the answer
		if ! is_item_name "${item_name}" || [ -L "${item_path}" ] || [ ! -f "${item_path}" ] || [ ! -r "${item_path}" ]; then
			space_fault "${item_path} is not a readable state item named <ID>-<state>.json, or is a symbolic link; expected only the items effort.sh writes in ${states_dir}; try moving it aside"
		fi
		items="${items}${item_name}
"
		keep_if_newest
	done
}

# Succeeds when file name $1 is a state item's, <ID>-<label>.json, and sets
# name_id to its ID.
is_item_name() {
	# shellcheck disable=SC2310 # pure tests; their status is the answer
	crucible_split_id "$1" && [ "${crucible_name_rest%.json}" != "${crucible_name_rest}" ] &&
		crucible_is_label "${crucible_name_rest%.json}" || return 1
	name_id=${crucible_name_id}
}

# Makes item_path the newest item when its ID is later than the newest so
# far. IDs are local time then hex, compared as numbers so the newest needs
# no sort.
keep_if_newest() {
	id_stamp=${name_id%-*}
	id_digits=${id_stamp%T*}${id_stamp#*T}
	id_hex=$((0x${name_id#*-}))
	if [ -z "${newest_item}" ] || [ $((id_digits > newest_digits)) -eq 1 ] ||
		{ [ $((id_digits == newest_digits)) -eq 1 ] && [ $((id_hex > newest_hex)) -eq 1 ]; }; then
		newest_item=${item_path} newest_digits=${id_digits} newest_hex=${id_hex} newest_id=${name_id}
	fi
}

# Sets current_state from the effort's newest item, open when it has none;
# exits 4 when the item is empty or breaks the item shape.
read_newest_state() {
	read_newest_item
	current_state=open
	[ -n "${newest_item}" ] || return 0
	item_states "${newest_item}"
	current_state=${states_read}
}

# Sets states_read to the state of each item path given, one per line, in
# order, each checked against effort-state-validator.jq; exits 4 naming the
# items that break it.
item_states() {
	item_count=0
	for read_path do
		set -- "$@" --arg "p${item_count}" "${read_path}" --rawfile "i${item_count}" "${read_path}"
		shift
		item_count=$((item_count + 1))
	done
	states_read=$(jq -n -r -L "${own_dir}" --argjson count "${item_count}" --argjson max "${MAX_PROBLEMS}" "$@" "${ITEMS_JQ}" </dev/null) ||
		install_fault 'jq failed on the state items; expected jq 1.6+ and effort-state-validator.jq; try jq --version, then rerun'
	case ${states_read} in
		'!'*) ;;
		*) return 0 ;;
	esac
	while IFS= read -r problem; do
		[ "${problem}" = '!' ] || warn "space: ${problem}"
	done <<EOF
${states_read}
EOF
	space_fault 'a state item is broken (named above); expected the items effort.sh writes; check them by hand; no state is guessed'
}

# Adds the item for the move from $2 ("" for the first) to $1, under the lock:
# waits until the clock is past the newest item's second, has crucible.sh
# allocate the file, and fills it through a temp file beside it once the
# content passes the validator. Exits 7 on a move the moves do not allow.
write_item() {
	move=$(jq -n -c -L "${own_dir}" -L "${crucible_lib_dir}" --arg from "$2" --arg to "$1" \
		--arg session "${session}" "${MOVE_JQ}" </dev/null) ||
		install_fault 'jq failed building the state item; expected jq 1.6+, prune.jq and effort-state-validator.jq; try jq --version'
	refusal=$(printf '%s\n' "${move}" | jq -r '.refusal // empty') ||
		install_fault 'jq failed reading the move; expected jq 1.6+; try jq --version'
	if [ -n "${refusal}" ]; then
		warn "${refusal}"
		exit "${BAD_MOVE_EXIT}"
	fi
	wait_past_newest
	allocate_item "$1"
	at=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || install_fault 'date failed; expected the UTC time; try date -u'
	temp_file=$(mktemp "${states_dir}/.${item_file##*/}.XXXXXX") ||
		space_fault "cannot create a temp file in ${states_dir}; expected a writable folder; try checking its permissions and free space"
	printf '%s\n' "${move}" | jq --arg at "${at}" '.item | .at = $at' >"${temp_file}" ||
		space_fault "cannot write the temp file ${temp_file}; expected the item written; try checking free space"
	check_written_item
	mv -f "${temp_file}" "${item_file}" ||
		space_fault "cannot move the temp file onto ${item_file}; expected the item in place; try checking the permissions of ${states_dir}"
	temp_file='' allocated_item=''
}

# Waits, at most MAX_CLOCK_WAIT_SECONDS, until the local time is past the
# newest item's second, so the new item's ID sorts after it.
wait_past_newest() {
	[ -n "${newest_item}" ] || return 0
	waited=0
	while :; do
		set_clock_digits
		[ $((clock_digits > newest_digits)) -eq 0 ] || return 0
		[ "${waited}" -lt "${MAX_CLOCK_WAIT_SECONDS}" ] ||
			space_fault "the local clock reads ${clock_stamp}, not past the newest state item ${newest_item}; expected a later time; try again once the clock has passed ${newest_id%-*}"
		sleep 1
		waited=$((waited + 1))
	done
}

# Sets clock_stamp to the local time as an ID holds it and clock_digits to its digits.
set_clock_digits() {
	clock_stamp=$(date '+%Y%m%dT%H%M%S') || install_fault 'date failed; expected the local time; try a POSIX date on PATH'
	case ${clock_stamp} in
		[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]) ;;
		*) install_fault 'date printed no YYYYMMDDTHHMMSS time; expected a POSIX date; try a POSIX date on PATH' ;;
	esac
	clock_digits=${clock_stamp%T*}${clock_stamp#*T}
}

# Sets item_file to a new empty item of state $1 that crucible.sh new creates
# in states/, and checks its ID is later than the newest item's.
allocate_item() {
	if item_file=$(sh "${crucible_script}" new --kind "${KIND}" --effort "${effort}" --label "$1" </dev/null); then
		crucible_status=0
	else
		crucible_status=$?
	fi
	case ${crucible_status} in
		0) ;;
		2 | 5) install_fault "crucible.sh new refused the states kind (its stderr is above); expected a crucible skill that knows it; try reinstalling the ${CRUCIBLE_SKILL} skill" ;;
		*) space_fault "crucible.sh new failed (its stderr is above); expected a new empty item in ${states_dir}/; try the fix it names, then rerun" ;;
	esac
	# shellcheck disable=SC2310 # a pure test; its status is the answer
	case ${item_file} in
		"${states_dir}/"*.json) is_item_name "${item_file##*/}" || item_file='' ;;
		*) item_file='' ;;
	esac
	[ -n "${item_file}" ] ||
		install_fault "crucible.sh new printed no item in ${states_dir}/; expected the path of a new item; try reinstalling the ${CRUCIBLE_SKILL} skill"
	allocated_item=${item_file}
	[ -n "${newest_item}" ] || return 0
	previous_item=${newest_item}
	item_path=${item_file}
	keep_if_newest
	[ "${newest_item}" = "${item_file}" ] ||
		space_fault "the new item ${item_file} sorts before the newest ${previous_item}; expected a later ID; the clock was set back: try again once it has passed ${newest_id%-*}"
}

# Exits 5 when the temp file breaks the item shape: the item is built from
# checked values, so a problem is a fault of the installed scripts.
check_written_item() {
	written_problems=$(jq -r -L "${own_dir}" 'include "effort-state-validator"; effort_state_item_problems' "${temp_file}" </dev/null) ||
		install_fault 'jq failed on the state item written; expected jq 1.6+ and effort-state-validator.jq; try jq --version'
	[ -n "${written_problems}" ] || return 0
	while IFS= read -r problem; do
		warn "install: the item built: ${problem}"
	done <<EOF
${written_problems}
EOF
	install_fault 'the state item built breaks effort-state-validator.jq; expected matching effort.sh and validator; try reinstalling procedure-effort'
}

run_state() {
	parse_effort_option "$@"
	read_newest_item
	[ -n "${newest_item}" ] || {
		printf 'STATE: open\n'
		return 0
	}
	# Item names lead with their ID and hold no newline, so a byte-order sort
	# is oldest first.
	sorted_items=$(printf '%s' "${items}" | LC_ALL=C sort) ||
		install_fault 'sort failed; expected a POSIX sort; try a POSIX sort on PATH'
	set --
	while IFS= read -r item_name; do
		set -- "$@" "${states_dir}/${item_name}"
	done <<EOF
${sorted_items}
EOF
	item_states "$@"
	printf 'STATE: %s\n' "${states_read##*
}"
	for listed_item do
		printf 'ITEM: %s\n' "${listed_item}"
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
	total=0 shown_efforts=''
	while IFS= read -r entry; do
		total=$((total + 1))
		if [ "${show_all}" = true ] || [ "${total}" -le "${LIST_LIMIT}" ]; then
			shown_efforts="${shown_efforts}${entry}
"
		fi
	done <<EOF
${efforts_found}
EOF
	print_efforts
	if [ "${show_all}" = false ] && [ "${total}" -gt "${LIST_LIMIT}" ]; then
		warn "showing ${LIST_LIMIT} of ${total}; add --all for every effort"
	fi
}

# Prints each shown effort with its state, read in one pass over the newest
# item of every effort that has one. An effort whose states/ or newest item
# is broken lists as unknown, with one stderr line naming it; a broken space
# or efforts/ still exits.
print_efforts() {
	newest_items=''
	set --
	while IFS= read -r entry; do
		[ -n "${entry}" ] || continue
		effort="${efforts_dir}/${entry}"
		states_dir="${effort}/${KIND}"
		# shellcheck disable=SC2310 # its exit 4 marks this effort unknown; its stderr line names why
		if newest_item=$(newest_item_alone); then
			[ -z "${newest_item}" ] || set -- "$@" "${newest_item}"
		else
			read_status=$?
			[ "${read_status}" -eq 4 ] || exit "${read_status}"
			newest_item=unknown
		fi
		newest_items="${newest_items}${newest_item}
"
	done <<EOF
${shown_efforts}
EOF
	states_read=''
	[ "$#" -eq 0 ] || list_states "$@"
	# The states are single words of the validator's list, so splitting them
	# is safe.
	set -f
	# shellcheck disable=SC2086 # split on purpose: one word per state
	set -- ${states_read}
	set +f
	while IFS= read -r entry <&3 && IFS= read -r listed_item; do
		[ -n "${entry}" ] || continue
		case ${listed_item} in
			'') listed_state=open ;;
			unknown) listed_state=unknown ;;
			*)
				listed_state=$1
				shift
				;;
		esac
		printf '%s %s\n' "${entry}" "${listed_state}"
	done 3<<EOF3 <<EOF
${shown_efforts}
EOF3
${newest_items}
EOF
}

# list: prints the effort's newest item path, nothing when it has none, in a
# subshell, so a broken states/ or item exits 4 for this effort alone.
newest_item_alone() {
	(
		read_newest_item
		printf '%s' "${newest_item}"
	)
}

# list: sets states_read to one word per item path given, in order: its state,
# or unknown with a stderr line naming it and why.
list_states() {
	item_count=0
	for read_path do
		set -- "$@" --arg "p${item_count}" "${read_path}" --rawfile "i${item_count}" "${read_path}"
		shift
		item_count=$((item_count + 1))
	done
	list_out=$(jq -n -r -L "${own_dir}" --argjson count "${item_count}" "$@" "${LIST_JQ}" </dev/null) ||
		install_fault 'jq failed on the state items; expected jq 1.6+ and effort-state-validator.jq; try jq --version, then rerun'
	states_read='' problem_next=false
	while IFS= read -r list_line; do
		if [ "${problem_next}" = true ]; then
			warn "space: ${list_line}"
			problem_next=false
			continue
		fi
		[ "${list_line}" != unknown ] || problem_next=true
		states_read="${states_read} ${list_line}"
	done <<EOF
${list_out}
EOF
}

# Sets newest_item and the rest collect_items sets for effort, exiting 4 when
# the newest item is empty. Outside the lock an empty newest item may be one a
# writer is filling, so it is read again while that writer holds the lock.
read_newest_item() {
	waits=0
	while :; do
		collect_items
		[ -n "${newest_item}" ] && [ ! -s "${newest_item}" ] || return 0
		if [ -z "${lock_dir}" ] && [ -d "${effort}/.${KIND}.lock" ] && [ "${waits}" -lt "${MAX_EMPTY_ITEM_WAITS}" ]; then
			sleep 1
			waits=$((waits + 1))
			continue
		fi
		space_fault "${newest_item} is empty; expected the newest state item, whole; a killed state change can leave one: check the effort and remove it, then rerun"
	done
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

# Sets efforts_found to the effort folder names, newest first, one per line;
# empty when the space or efforts/ does not exist yet.
collect_efforts() {
	efforts_found=''
	[ -e "${root}" ] || return 0
	[ -d "${root}" ] || space_fault "${root} is not a folder; expected the space folder; try pointing CRUCIBLE_HOME elsewhere"
	refuse_link "${efforts_dir}"
	[ -e "${efforts_dir}" ] || return 0
	[ -d "${efforts_dir}" ] || space_fault "${efforts_dir} is not a folder; expected the efforts folder; try moving it aside"
	entries=$(ls "${efforts_dir}" 2>/dev/null) ||
		space_fault "cannot read ${efforts_dir}; expected a readable folder; try checking its permissions"
	newline='
'
	accepted=''
	while IFS= read -r entry; do
		split_entry "${entry}"
		[ -n "${entry_id}" ] || continue
		[ -d "${efforts_dir}/${entry}" ] && [ ! -L "${efforts_dir}/${entry}" ] || continue
		accepted="${accepted}${entry}${newline}"
	done <<EOF
${entries}
EOF
	[ -n "${accepted}" ] || return 0
	# Effort names are ASCII and lead with their timestamp, so a byte-order
	# sort, reversed, is newest first.
	efforts_found=$(printf '%s' "${accepted}" | LC_ALL=C sort -r) ||
		install_fault 'sort failed; expected a POSIX sort; try a POSIX sort on PATH'
}

# Sets entry_id, entry_hex and entry_name from an effort folder name
# <id>-<name>; all empty when the entry is not shaped like one.
split_entry() {
	entry_id='' entry_hex='' entry_name=''
	# shellcheck disable=SC2310 # a pure test; its status is the answer
	crucible_is_effort_name "$1" || return 0
	entry_id=${crucible_name_id}
	entry_hex=${entry_id##*-}
	entry_name=${crucible_name_rest}
}

# Removes this run's temp file and, on a failing exit, the empty item it
# allocated and, for start, what start made; last the lock it took. Only
# rmdir removes a folder, so nothing it did not make goes.
# shellcheck disable=SC2329 # invoked by the EXIT trap
clean_up() {
	exit_status=$?
	[ -z "${temp_file}" ] || rm -f "${temp_file}"
	if [ "${exit_status}" -ne 0 ] && [ -n "${allocated_item}" ]; then
		rm -f "${allocated_item}" || warn "could not remove the empty item ${allocated_item}, made by this run; remove it by hand"
	fi
	if [ -n "${lock_dir}" ]; then
		rmdir "${lock_dir}" 2>/dev/null ||
			warn "could not remove the lock ${lock_dir}; expected it gone; try rmdir '${lock_dir}'"
	fi
	if [ "${exit_status}" -ne 0 ] && [ -n "${started_folder}" ]; then
		rmdir "${started_folder}/${KIND}" 2>/dev/null || true
		if rmdir "${started_folder}" 2>/dev/null; then
			warn "removed ${started_folder}, made by this run"
		else
			warn "left ${started_folder}, made by this run with no state item; it reads as open"
		fi
	fi
}

temp_file='' allocated_item='' lock_dir='' started_folder='' session=''
trap clean_up EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

main "$@"
