#!/usr/bin/env sh
# Starts, lists and finds the effort folders of the Crucible space: one empty
# folder per effort, <space>/efforts/<id>-<name>/. It never deletes, renames
# or writes inside one, except that start removes its own just-created empty
# folder on an ID clash or when it cannot set its mode.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077

readonly PROG='effort.sh'
# The default list keeps the newest efforts on one screen; --all lifts it.
readonly LIST_LIMIT=20
# A clash needs the same second and the same 4 random hex digits; a handful of
# fresh draws makes a repeat practically impossible.
readonly MAX_START_ATTEMPTS=5
# Unknown arguments are echoed back only up to this length, so a long or
# hostile value never floods a diagnostic.
readonly MAX_SHOWN_CHARS=40

usage() {
	print_block <<'EOF'
usage: effort.sh start --name NAME
       effort.sh list [--all]
       effort.sh path VALUE
       effort.sh --help | -h
EOF
}

# NAME's rule and its 40 mirror crucible_effort_name_max_chars and
# crucible_effort_name_rule (lib/crucible-space.sh); --help prints before the
# lib loads, so update this when they change.
help_text() {
	usage
	print_block <<'EOF'

Starts, lists and finds the Crucible space's effort folders,
<space>/efforts/<id>-<name>/, the space being ${CRUCIBLE_HOME:-$HOME/.crucible}.

  ID    <YYYYMMDDTHHMMSS>-<hex>: the local start time and 4 random lowercase
        hex digits; never reused
  NAME  words of a-z and 0-9 joined by single dashes, 1 to 40 characters
        (the crucible skill's space rules own it)
  --name NAME  start: the new effort's NAME
  --all        list: every effort, not only the newest 20
  VALUE        path: a full ID, its 4 hex digits or an exact NAME

stdout on exit 0:
  start: EFFORT: <folder>, the new effort's folder, absolute
  list:  one <id>-<name> per line, newest first; no line when no effort exists
  path:  the matching effort's folder, absolute, one line
stderr:
  list, more than 20 and no --all: "effort.sh: showing 20 of <N>; add --all
    for every effort"
  path, exit 1 with several matches: each <id>-<name>, unprefixed, on its own
    line, newest first, then one "effort.sh:" summary line
  else: "effort.sh:" diagnostic lines, to show the human

start creates one new empty effort folder, mode 700, never over an existing
one, plus the space (with any missing parents) and efforts/ when missing, each
mode 700; these stay after exit. A failed start leaves no new effort folder
unless stderr names it. No command writes through a symbolic link at the space
or efforts/, or deletes, renames or writes inside an existing effort
folder; list and path write nothing.

Exit codes:
  0  done; read stdout
  1  path: no effort matches VALUE, or several do; with matches on stderr,
     ask which one is meant; with none, run list
  2  usage error, or a CRUCIBLE_HOME or HOME that is not usable as the space;
     show the human stderr, and stop
     effort.sh: bad name:  start: NAME breaks the rule; pick another name
  4  the space or efforts/ is unusable; show the human stderr, and stop
  5  install fault; show the human stderr, and stop

Dependencies (a missing one exits 5):
  POSIX sh; date, od (with /dev/urandom), mkdir, chmod, rmdir, ls, sort (macOS
    and Linux base systems; coreutils on Linux)
  the crucible skill's space rules,
    ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/crucible/scripts/lib/crucible-space.sh
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
	[ "$#" -gt 0 ] || usage_error 'a command is missing; expected start, list, path or --help'
	command=$1
	shift
	case ${command} in
		--help | -h)
			[ "$#" -eq 0 ] || usage_error "${command} takes no arguments; expected ${command} alone"
			help_text
			exit 0
			;;
		start | list | path) ;;
		*)
			show_safely "${command}"
			usage_error "unknown command: ${shown}; expected start, list, path or --help"
			;;
	esac
	# Checked before a command's arguments, so a missing tool or space rules
	# exit 5 ahead of any usage error in them.
	check_tools
	load_space_lib
	resolve_root
	efforts_dir="${root}/efforts"
	case ${command} in
		start) run_start "$@" ;;
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
	for tool in date od mkdir chmod rmdir ls sort; do
		command -v "${tool}" >/dev/null 2>&1 ||
			install_fault "${tool} missing; expected it on PATH; try installing the base-system tools (coreutils on Linux)"
	done
}

# Sources the crucible skill's space rules, or exits 5.
load_space_lib() {
	space_lib="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/skills/crucible/scripts/lib/crucible-space.sh"
	[ -f "${space_lib}" ] && [ -r "${space_lib}" ] ||
		install_fault "space rules missing; expected ${space_lib}; try installing the crucible skill"
	# shellcheck source=../../../../engine/crucible/scripts/lib/crucible-space.sh
	. "${space_lib}"
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
	refuse_link "${efforts_dir}"
	create_space_folder "${root}"
	create_space_folder "${efforts_dir}"
	start_effort
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
	printf 'EFFORT: %s\n' "${folder}"
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
		if [ "${show_all}" = true ] || [ "${total}" -le "${LIST_LIMIT}" ]; then
			printf '%s\n' "${entry}"
		fi
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

main "$@"
