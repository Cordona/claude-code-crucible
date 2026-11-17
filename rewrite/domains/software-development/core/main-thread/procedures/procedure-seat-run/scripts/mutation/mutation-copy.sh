#!/usr/bin/env sh
# Opens and removes a tester seat's mutation copy: a copy of its build seat's
# worktree as it is now, where the tester breaks production code on purpose
# to see each new test go red, so the real worktree is never broken.
# The copy has no .git, so no git command and no worktree rule reaches it;
# the stop hook refuses a tester's stop while it exists
# (../hooks/rules/stop/mutation-copy.sh).
set -eu
umask 077

readonly PROG='mutation-copy.sh'
readonly COPY_FOLDER='mutation'
LC_ALL=C
export LC_ALL

usage() {
	cat <<EOF
usage: sh ${PROG} open --effort FOLDER --seat S
       sh ${PROG} remove --effort FOLDER --seat S
       sh ${PROG} --help | -h

Opens or removes tester seat S's mutation copy,
<effort>/drafts/agents/<S>/${COPY_FOLDER}/.

open    copies the worktree seats.sh get names for S (its build seat's)
        as it is now: everything in it but .git, at any depth; uncommitted
        changes and ignored files (installed dependencies such as
        node_modules or .venv) included, symbolic links as links, modes
        and times kept; a clone where the file system allows (cp -c on
        macOS, cp --reflink=auto elsewhere), else a plain copy; made whole
        beside the copy's place, then moved there
remove  deletes the copy; no copy: nothing to do

--effort FOLDER  the effort folder, absolute
--seat S         a tester seat, like test-agent-alpha

stdout of open: the copy's absolute path; of remove: nothing
Nothing is read or written through a symbolic link at the copy or a
folder from the effort to it.

exit codes:
  0  done
  2  wrong command line: an unknown command or option, a repeated or
     missing option or value
  3  input: the effort is not absolute, S is no tester seat of it (seats.sh
     get's own lines first), its worktree is no folder, or a symbolic link
     lies on the copy's path; nothing changed
  4  environment: jq, cp or seats.sh missing or failed, or the copy could
     not be made or removed (stderr says what); open leaves no copy
  5  open: a copy is open already; remove it first

needs: POSIX sh, jq 1.6+, cp with -R, -P and -p; ../seats/seats.sh from
this script's folder
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

# Sets $option_value from "$1 $2", refusing a repeat or a missing value.
take_value() {
	[ -n "$3" ] || usage_error "$1 needs a value; expected $1 $4"
	[ -z "$2" ] || usage_error "$1 given twice; expected one"
	option_value=$3
}

parse_args() {
	case ${1-} in
		-h | --help)
			usage
			exit 0
			;;
		open | remove) command=$1 ;;
		'') usage_error 'command missing; expected open or remove' ;;
		*)
			shown_command=$(printable "$1")
			usage_error "unknown command: ${shown_command}; expected open or remove"
			;;
	esac
	shift
	effort_folder='' seat=''
	while [ "$#" -gt 0 ]; do
		case $1 in
			-h | --help)
				usage
				exit 0
				;;
			--effort)
				take_value "$1" "${effort_folder}" "${2-}" FOLDER
				effort_folder=${option_value}
				;;
			--seat)
				take_value "$1" "${seat}" "${2-}" S
				seat=${option_value}
				;;
			*)
				shown_option=$(printable "$1")
				usage_error "unknown option: ${shown_option}; expected --effort, --seat or --help"
				;;
		esac
		shift 2
	done
	[ -n "${effort_folder}" ] || usage_error '--effort missing; expected --effort FOLDER'
	[ -n "${seat}" ] || usage_error '--seat missing; expected --seat S'
}

script_dir() {
	case $0 in
		*/*) printf '%s' "${0%/*}" ;;
		*) printf '.' ;;
	esac
}

load_dependencies() {
	command -v jq >/dev/null 2>&1 || die 4 'jq not found; expected jq 1.6+ on PATH'
	own_path=$(script_dir)
	own_dir=$(cd -P -- "${own_path}" && pwd -P) || die 4 "this script's folder could not be entered"
	seats_script="${own_dir}/../seats/seats.sh"
	[ -f "${seats_script}" ] || die 4 '../seats/seats.sh not found from this script'\''s folder; expected procedure-seat-run whole'
	[ "${command}" = remove ] ||
		command -v cp >/dev/null 2>&1 || die 4 'cp not found; expected cp on PATH'
}

# Sets copy, the copy's path, refusing an effort path that is not absolute
# and a seat name that could leave the seat's drafts folder.
check_paths() {
	shown_effort=$(printable "${effort_folder}")
	case ${effort_folder} in
		*[[:cntrl:]]*) die 3 "--effort ${shown_effort} holds a control character; expected a plain path" ;;
		/*) ;;
		*) die 3 "--effort ${shown_effort} is not absolute; expected an absolute path" ;;
	esac
	while [ "${effort_folder}" != "${effort_folder%/}" ]; do effort_folder=${effort_folder%/}; done
	shown_seat=$(printable "${seat}")
	case ${seat} in
		*[!a-z0-9-]* | -*) die 3 "--seat ${shown_seat} is no seat name; expected one like test-agent-alpha" ;;
		*) ;;
	esac
	copy="${effort_folder}/drafts/agents/${seat}/${COPY_FOLDER}"
	# shellcheck disable=SC2310 # its status is the answer; it checks each step itself
	no_link_below "${effort_folder}" "${copy}" ||
		die 3 "a symbolic link lies on the copy's path ${copy}; expected real folders"
}

# Succeeds when neither path $2 nor a folder between folder $1 and it is a
# symbolic link; a missing level ends the walk: nothing below it exists.
no_link_below() {
	level_path=$1
	levels_left=${2#"$1"/}
	while [ -n "${levels_left}" ]; do
		level=${levels_left%%/*}
		case ${levels_left} in
			*/*) levels_left=${levels_left#*/} ;;
			*) levels_left='' ;;
		esac
		level_path="${level_path}/${level}"
		[ ! -L "${level_path}" ] || return 1
		[ -e "${level_path}" ] || return 0
	done
}

# Sets worktree from seats.sh get, refusing a seat that is not a tester's.
read_seat() {
	seat_rc=0
	seat_json=$(sh "${seats_script}" get --effort "${effort_folder}" --seat "${seat}" </dev/null) || seat_rc=$?
	case ${seat_rc} in
		0) ;;
		2 | 3 | 6) die 3 "seats.sh get refused seat ${shown_seat} (exit ${seat_rc}); expected a tester seat of --effort" ;;
		*) die 4 "seats.sh get failed (exit ${seat_rc})" ;;
	esac
	fields=$(printf '%s\n' "${seat_json}" | jq -r '.role // "", .worktree // ""') ||
		die 4 'jq could not read the seat seats.sh get printed'
	role='' worktree=''
	{
		IFS= read -r role || :
		IFS= read -r worktree || :
	} <<EOF
${fields}
EOF
	[ "${role}" = tester ] || die 3 "seat ${shown_seat} is a ${role:-seat with no role}; expected a tester seat"
	shown_worktree=$(printable "${worktree}")
	[ -n "${worktree}" ] && [ -d "${worktree}" ] ||
		die 3 "seat ${shown_seat}'s worktree ${shown_worktree} is not a folder; expected its build seat's worktree"
}

# Makes the copy whole in a folder beside its place, then moves it there.
open_copy() {
	[ ! -e "${copy}" ] || die 5 "the mutation copy ${copy} is open already; expected it removed first (${PROG} remove)"
	mkdir -p -- "${copy%/*}" || die 4 "could not make the folder ${copy%/*}"
	clone=$(clone_option)
	# shellcheck disable=SC2310 # its status picks the fallback; it checks each step itself
	copy_worktree "${clone}" || {
		discard_staging
		copy_worktree '' || {
			first_line=$(head -n 1 "${work_dir}/stderr" | tr '[:cntrl:]' '?') || first_line=''
			die 4 "cp could not copy ${shown_worktree}: ${first_line}"
		}
	}
	mv -- "${staging}" "${copy}" || die 4 "could not move the copy into ${copy}"
	staging=''
	printf '%s\n' "${copy}"
}

# Prints cp's clone option: macOS's cp -c clones on APFS and copies
# elsewhere; GNU cp's --reflink=auto clones where the file system can.
clone_option() {
	case $(uname -s) in
		Darwin) printf '%s' -c ;;
		*) printf '%s' --reflink=auto ;;
	esac
}

# Copies the worktree's top-level entries but .git into a new staging folder
# with cp's extra option $1 (none when empty), then deletes every nested .git.
copy_worktree() {
	clone_flag=$1
	staging=$(mktemp -d "${copy}.XXXXXX") || die 4 "mktemp could not make a folder beside ${copy}"
	set --
	for entry in "${worktree}"/* "${worktree}"/.[!.]* "${worktree}"/..?*; do
		[ -e "${entry}" ] || [ -L "${entry}" ] || continue
		[ "${entry##*/}" != .git ] || continue
		set -- "$@" "${entry}"
	done
	[ "$#" -gt 0 ] || return 0
	cp ${clone_flag:+"${clone_flag}"} -R -P -p -- "$@" "${staging}/" 2>"${work_dir}/stderr" || return 1
	find "${staging}" -name .git -prune -exec rm -rf -- {} + 2>"${work_dir}/stderr" || return 1
}

# Deletes a failed attempt's staging folder, read-only folders included.
discard_staging() {
	chmod -R u+w -- "${staging}" 2>/dev/null || :
	rm -rf -- "${staging}"
	staging=''
}

remove_copy() {
	[ -e "${copy}" ] || return 0
	# A test run may leave read-only folders, which rm can't empty.
	chmod -R u+w -- "${copy}" 2>/dev/null || :
	rm -rf -- "${copy}" || die 4 "could not remove the mutation copy ${copy}"
}

# shellcheck disable=SC2329 # invoked by the EXIT trap
on_exit() {
	[ -z "${staging}" ] || discard_staging
	[ -z "${work_dir}" ] || rm -rf -- "${work_dir}"
}

work_dir='' staging=''
trap on_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

parse_args "$@"
load_dependencies
check_paths
read_seat
if [ "${command}" = remove ]; then
	remove_copy
	exit 0
fi
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/crucible-mutation.XXXXXX") || {
	work_dir=''
	die 4 'mktemp could not create a work folder; expected a writable TMPDIR'
}
open_copy
