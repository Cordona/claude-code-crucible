#!/usr/bin/env sh
# Starts, lists and finds the effort folders of the Crucible space: one empty
# folder per effort, <space>/efforts/<id>-<name>/. It never deletes, renames
# or writes inside one, except that start removes its own just-created empty
# folder on an ID clash or when it cannot set its mode.
set -eu
umask 077

readonly PROG='effort.sh'
# The effort name rule: words of a-z and 0-9 joined by single dashes, 1 to 40
# characters, so a name never looks like a flag.
readonly MAX_NAME_CHARS=40
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

help_text() {
	usage
	print_block <<'EOF'

Owns the effort folders of the Crucible space. An effort is one piece of work
with one ID and one folder. The effort's context is written under its folder;
its other artifacts still go to the Crucible space's day folders until they
move in. No record file is written in the folder.

The space: ${CRUCIBLE_HOME:-$HOME/.crucible}, an absolute path, trailing
slashes removed. Efforts live in <space>/efforts/<id>-<name>/, flat. The
space and efforts/ must be real folders: a symbolic link at either is
refused (exit 4) by every command. Folders it creates are mode 700.

ID:   <YYYYMMDDTHHMMSS>-<hex>, the local time of the start and 4 random
      lowercase hex digits. Unique across names; never reused.
NAME: words of a-z and 0-9 joined by single dashes, 1 to 40 characters: no
      leading, trailing or double dash, so '--all', '-x' and 'a--b' are
      refused.
An entry of efforts/ counts as an effort only when it is a real folder (not
a symbolic link) named <id>-<name> with a NAME that keeps the rule above;
every other entry is ignored.

Commands:
  start --name NAME
         mints a new ID and creates <space>/efforts/<id>-<name>/ (mode 700)
         with one mkdir, never over an existing folder. A missing space is
         created together with any missing parent folders (mkdir -p), and so
         is a missing efforts/, each mode 700, never over a symbolic link.
         When another folder already holds the ID, its own new folder is
         removed and a fresh ID drawn, up to 5 attempts. When chmod fails on
         its new folder, it removes that folder and exits 4. Prints exactly
         one line:
           EFFORT: <absolute folder path>
  list [--all]
         prints the effort folder names, one <id>-<name> per line, newest
         first (efforts of the same second in reverse hex order); at most 20
         unless --all; when more are cut off, stderr says
           effort.sh: showing 20 of <N>; add --all for every effort
         Prints nothing when there is no effort yet (no space or efforts/).
  path VALUE
         VALUE: a full ID, its 4 hex digits, or an exact name; words of
         a-z, 0-9 and T joined by single dashes. Every effort whose ID, hex or name equals VALUE
         matches. One match: prints its absolute path. None: stderr says so.
         Several: stderr lists each <id>-<name> (no prefix), in list's order,
         then a summary line.
  --help, -h
         prints this contract; with any argument after it, exits 2.

Output: results on stdout; diagnostics on stderr only. Each diagnostic line
but path's list of matches starts "effort.sh: ", then "space: " for exit 4
or "install: " for exit 5, then "<what failed>; expected <x>; try <y>" (a
usage error may omit the try part). A bad NAME (start, including an empty
one) exits 2 with one stderr line starting "effort.sh: bad name: "; no
other line starts so. A bad VALUE (path) exits 2 with one stderr line
starting "effort.sh: VALUE is empty", "effort.sh: VALUE holds a character"
or "effort.sh: bad VALUE: ". Neither prints the usage block; every other
exit 2 also prints the usage block above to stderr. No temp files. Nothing
is deleted except start's own just-created empty folder on an ID clash or
a failed chmod.

Exit codes:
  0  ok
  1  path: no effort matches VALUE, or several do
  2  usage error (no command, an unknown command or argument, a missing or
     repeated value), a bad NAME or VALUE (stderr says why), a CRUCIBLE_HOME
     that is not absolute or is /, or, when CRUCIBLE_HOME is unset or empty,
     a HOME that is not absolute
  4  the space or efforts/ cannot be created, read or written, or is not a
     folder, including mkdir, chmod, rmdir or ls failing on it; a symbolic
     link at either; neither CRUCIBLE_HOME nor HOME set; or no free ID
     after 5 attempts
  5  install fault: a tool below missing, or date, od or sort failing.
     Checked after the command word and before its arguments, so a missing
     tool exits 5 for every command, ahead of a usage error in them

Dependencies: POSIX sh; date, od (with /dev/urandom), mkdir, chmod, rmdir,
ls and sort, all in the macOS and Linux base systems (on Linux, the
coreutils package). No jq.

Runtime: about 0.02 s a command: start, and list, list --all and path over
26 efforts; --help about 0.01 s (mean wall time of 20 runs, sh startup
included; macOS 26.7 on an Apple M1 Max). One mkdir, or one ls of efforts/.
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
	check_tools
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

# Sets root from CRUCIBLE_HOME or the home folder, without trailing slashes.
resolve_root() {
	if [ -n "${CRUCIBLE_HOME:-}" ]; then
		root=${CRUCIBLE_HOME}
		root_source=CRUCIBLE_HOME
	elif [ -n "${HOME:-}" ]; then
		root="${HOME}/.crucible"
		root_source=HOME
	else
		space_fault 'neither CRUCIBLE_HOME nor HOME is set; expected one of them to name the space; try setting CRUCIBLE_HOME'
	fi
	case ${root} in
		/*) ;;
		*) usage_error "${root_source} is not absolute; expected an absolute path; try a path that starts with /" ;;
	esac
	while [ "${root}" != "${root%/}" ]; do root=${root%/}; done
	[ -n "${root}" ] || usage_error 'CRUCIBLE_HOME is /; expected a folder of its own; try unsetting it for the default'
	refuse_link "${root}"
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

check_name() {
	case ${name} in
		*[!abcdefghijklmnopqrstuvwxyz0123456789-]*)
			describe_first_bad_char
			bad_value "bad name: it holds ${bad_char}; expected only a-z, 0-9 and - (the effort name rule); try a lowercase slug such as prune-dry-run"
			;;
		*) ;;
	esac
	if [ "${#name}" -lt 1 ] || [ "${#name}" -gt "${MAX_NAME_CHARS}" ]; then
		bad_value "bad name: it is ${#name} characters; expected 1 to ${MAX_NAME_CHARS} (the effort name rule); try a slug of up to 3 words"
	fi
	describe_dash_fault "${name}"
	[ -z "${dash_fault}" ] ||
		bad_value "bad name: ${dash_fault}; expected words of a-z and 0-9 joined by single - (the effort name rule); try a slug such as prune-dry-run"
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
		mint_id
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

# Sets id to a fresh <YYYYMMDDTHHMMSS>-<hex> in local time.
mint_id() {
	stamp=$(date +%Y%m%dT%H%M%S 2>/dev/null) || install_fault 'date failed; expected the local time; try a POSIX date on PATH'
	case ${stamp} in
		[0123456789][0123456789][0123456789][0123456789][0123456789][0123456789][0123456789][0123456789]T[0123456789][0123456789][0123456789][0123456789][0123456789][0123456789]) ;;
		*) install_fault 'date printed no YYYYMMDDTHHMMSS time; expected a POSIX date; try a POSIX date on PATH' ;;
	esac
	random_hex
	id="${stamp}-${hex}"
}

# Sets hex to 4 random lowercase hex digits.
random_hex() {
	bytes=$(od -An -N2 -tx1 /dev/urandom 2>/dev/null) ||
		install_fault 'reading /dev/urandom failed; expected a random source; try od and /dev/urandom'
	high='' low=''
	read -r high low <<EOF || true
${bytes}
EOF
	hex="${high}${low}"
	case ${hex} in
		[0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef]) ;;
		*) install_fault 'od printed no 2 hex bytes; expected 4 lowercase hex digits; try a POSIX od' ;;
	esac
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
	case $1 in
		[0123456789][0123456789][0123456789][0123456789][0123456789][0123456789][0123456789][0123456789]T[0123456789][0123456789][0123456789][0123456789][0123456789][0123456789]-[0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef]-?*) ;;
		*) return 0 ;;
	esac
	after_id=${1#????????????????????-}
	case ${after_id} in
		*[!abcdefghijklmnopqrstuvwxyz0123456789-]*) return 0 ;;
		*) ;;
	esac
	[ "${#after_id}" -le "${MAX_NAME_CHARS}" ] || return 0
	describe_dash_fault "${after_id}"
	[ -z "${dash_fault}" ] || return 0
	entry_id=${1%-"${after_id}"}
	entry_hex=${entry_id##*-}
	entry_name=${after_id}
}

main "$@"
