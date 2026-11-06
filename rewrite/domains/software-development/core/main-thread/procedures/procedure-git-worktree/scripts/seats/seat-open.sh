#!/usr/bin/env sh
# Opens one writer seat: a detached worktree of the main checkout at the base,
# the checkout's dependency folders copied into it, and the seat added to the
# effort's slots.json. It only runs worktree-create.sh, worktree-setup.sh and
# slots.sh in order; a failure after the worktree exists removes it again, so
# a rerun starts clean.
set -eu
# worktree-create.sh checks the worktree out under the caller's umask.
caller_umask=$(umask)
umask 077

readonly PROG='seat-open.sh'
# The C locale keeps the shell byte-wise.
LC_ALL=C
export LC_ALL
GIT_TERMINAL_PROMPT=0
export GIT_TERMINAL_PROMPT

usage() {
	cat <<EOF
usage: sh ${PROG} --effort DIR --repo DIR --slot S --role developer|tester --base SHA
          [--base-slot S]...
       sh ${PROG} --help | -h

Opens a developer seat, stopping at the first failing step:
  ../worktree/worktree-create.sh --repo DIR --base SHA --path <effort>/worktrees/S
  ../worktree/worktree-setup.sh --from DIR --to <the new worktree>
  slots.sh add --slots <effort>/slots.json --slot S --role ROLE
               --worktree <the new worktree> --repo DIR --base <full sha>
               [--base-slot S]...
and prints the seat as slots.sh get does. A failure after the worktree
exists removes it (git worktree remove --force) and says so.

--effort DIR  absolute path of the effort folder (it holds slots.json)
--repo DIR    absolute path of the main checkout's top folder
--slot S      a new slot name like dev-1: a lowercase word, a dash and a
              number of 1 or more
--role ROLE   developer; tester (sharing a developer's worktree) is not yet
              supported and refused
--base SHA    the commit the worktree starts at, like snapshot.sh's sha
--base-slot S a developer seat in slots.json the base was cut from;
              repeatable, each once; checked before anything is created

The steps' own stderr lines come first; this script adds one line saying
which step failed.

exit codes:
  0  the seat is open; its JSON line is printed
  2  wrong command line: a missing, repeated or unknown option, or a
     missing value
  3  input: a refused option, the slot already in slots.json, a base slot
     not a developer seat in it, or a step refused its input (exit 3)
  4  a step failed otherwise, or a dependency is missing

needs: POSIX sh, git 2.26+, jq 1.6+; ../worktree/worktree-create.sh,
../worktree/worktree-setup.sh and slots.sh from this script's folder
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

# Prints $1 with each control character as "?", so a value can't split a stderr line.
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
	effort='' repo='' slot='' role='' base=''
	while [ "$#" -gt 0 ]; do
		case $1 in
			-h | --help)
				usage
				exit 0
				;;
			--effort)
				take_value "$1" "${effort}" "${2-}" DIR
				effort=${option_value}
				;;
			--repo)
				take_value "$1" "${repo}" "${2-}" DIR
				repo=${option_value}
				;;
			--slot)
				take_value "$1" "${slot}" "${2-}" S
				slot=${option_value}
				;;
			--role)
				take_value "$1" "${role}" "${2-}" 'developer|tester'
				role=${option_value}
				;;
			--base)
				take_value "$1" "${base}" "${2-}" SHA
				base=${option_value}
				;;
			--base-slot)
				take_value "$1" '' "${2-}" S
				;;
			*)
				shown_option=$(printable "$1")
				usage_error "unknown option: ${shown_option}; expected --effort, --repo, --slot, --role, --base, --base-slot or --help"
				;;
		esac
		shift 2
	done
	[ -n "${effort}" ] || usage_error '--effort missing; expected --effort DIR'
	[ -n "${repo}" ] || usage_error '--repo missing; expected --repo DIR'
	[ -n "${slot}" ] || usage_error '--slot missing; expected --slot S'
	[ -n "${role}" ] || usage_error '--role missing; expected --role developer|tester'
	[ -n "${base}" ] || usage_error '--base missing; expected --base SHA'
}

script_dir() {
	case $0 in
		*/*) printf '%s' "${0%/*}" ;;
		*) printf '.' ;;
	esac
}

load_dependencies() {
	command -v git >/dev/null 2>&1 || die 4 'git not found; expected git 2.26+ on PATH'
	command -v jq >/dev/null 2>&1 || die 4 'jq not found; expected jq 1.6+ on PATH'
	own_path=$(script_dir)
	own_dir=$(cd -P -- "${own_path}" && pwd -P) || die 4 "this script's folder could not be entered"
	for step in ../worktree/worktree-create.sh ../worktree/worktree-setup.sh slots.sh; do
		[ -f "${own_dir}/${step}" ] || {
			shown_step=$(printable "${own_dir}/${step}")
			die 4 "${shown_step} not found; expected the procedure's scripts folders whole"
		}
	done
}

# Refuses a role, slot or effort the steps can't take; sets effort_dir (the
# physical effort folder) and slots_file.
check_inputs() {
	case ${role} in
		developer) ;;
		tester) die 3 '--role tester is not yet supported: a tester shares a developer'\''s worktree; expected developer' ;;
		*)
			shown_role=$(printable "${role}")
			die 3 "--role ${shown_role} is not allowed; expected developer"
			;;
	esac
	# Checked here because the slot names a folder before slots.sh sees it.
	check_slot_name --slot "${slot}"
	shown_effort=$(printable "${effort}")
	case ${effort} in
		/*) ;;
		*) die 3 "--effort ${shown_effort} is not absolute; expected an absolute path" ;;
	esac
	effort_dir=$(cd -P -- "${effort}" 2>/dev/null && pwd -P) ||
		die 3 "--effort ${shown_effort} is not a folder; expected the effort folder"
	slots_file="${effort_dir}/slots.json"
	shown_slots=$(printable "${slots_file}")
}

# Refuses option $1's value $2 when it is no lowercase word, a dash and a
# number of 1 or more.
check_slot_name() {
	case $2 in
		[a-z]*-[1-9]*)
			case ${2%-*}/${2##*-} in
				*[!a-z0-9]*/* | */*[!0-9]*) ;;
				*) return 0 ;;
			esac
			;;
		*) ;;
	esac
	shown_slot=$(printable "$2")
	die 3 "$1 ${shown_slot} is not allowed; expected a slot name like dev-1"
}

# Refuses a slot slots.json already holds, before anything is created;
# slots.sh's "not in the file" is the expected answer, so its lines show
# only on another outcome.
check_slot_free() {
	step_rc=0
	get_lines=$(sh "${own_dir}/slots.sh" get --slots "${slots_file}" --slot "${slot}" 2>&1 >/dev/null) || step_rc=$?
	case ${step_rc} in
		0) die 3 "slot ${slot} is already in ${shown_slots}; expected a new slot" ;;
		6) ;;
		*)
			[ -z "${get_lines}" ] || printf '%s\n' "${get_lines}" >&2
			step_failed 'slots.sh get'
			;;
	esac
}

# Refuses a --base-slot of the checked command line ("$@") that is given twice
# or is no developer seat in slots.json, before anything is created.
check_base_slots() {
	seen_base_slots=' '
	while [ "$#" -gt 0 ]; do
		[ "$1" != --base-slot ] || check_base_slot "$2"
		shift 2
	done
}

check_base_slot() {
	check_slot_name --base-slot "$1"
	case ${seen_base_slots} in
		*" $1 "*) die 3 "--base-slot $1 is given twice; expected each base slot once" ;;
		*) seen_base_slots="${seen_base_slots}$1 " ;;
	esac
	# On exit 0 slots.sh prints only the seat; otherwise only its stderr lines.
	step_rc=0
	base_seat=$(sh "${own_dir}/slots.sh" get --slots "${slots_file}" --slot "$1" 2>&1) || step_rc=$?
	case ${step_rc} in
		0) ;;
		6) die 3 "--base-slot $1 is not in ${shown_slots}; expected an existing developer seat" ;;
		*)
			printf '%s\n' "${base_seat}" >&2
			step_failed 'slots.sh get'
			;;
	esac
	base_role=$(printf '%s\n' "${base_seat}" | jq -r '.role') || die 4 'jq could not read the seat slots.sh get printed'
	[ "${base_role}" = developer ] ||
		die 3 "--base-slot $1 is a ${base_role} seat in ${shown_slots}; expected a developer seat"
}

# Runs step $1, a path from this script's folder, with the rest as
# arguments; its stdout in step_out, its exit code in step_rc; its stderr
# passes through.
run_step() {
	step_rc=0
	step_script=$1
	shift
	step_out=$(sh "${own_dir}/${step_script}" "$@") || step_rc=$?
}

# Exits naming failed step $1: 3 when it refused its input, else 4.
step_failed() {
	case ${step_rc} in
		3) step_exit=3 ;;
		*) step_exit=4 ;;
	esac
	remove_worktree
	die "${step_exit}" "$1 failed (exit ${step_rc}); expected it to succeed${removal_note}"
}

# Removes the worktree this run created, if any, and sets removal_note.
remove_worktree() {
	removal_note=''
	[ -n "${worktree}" ] || return 0
	shown_worktree=$(printable "${worktree}")
	if git -C "${repo}" worktree remove --force "${worktree}" >/dev/null 2>&1; then
		removal_note="; removed the worktree ${shown_worktree} so a rerun starts clean"
	else
		removal_note="; could not remove the worktree ${shown_worktree}: remove it with git worktree remove --force"
	fi
	worktree=''
}

# Adds the seat with slots.sh, passing each --base-slot of the checked
# command line ("$@") on in order.
add_seat() {
	left=$#
	set -- "$@" add --slots "${slots_file}" --slot "${slot}" --role "${role}" \
		--worktree "${worktree}" --repo "${repo}" --base "${full_base}"
	while [ "${left}" -gt 0 ]; do
		[ "$1" != --base-slot ] || set -- "$@" --base-slot "$2"
		shift 2
		left=$((left - 2))
	done
	run_step slots.sh "$@"
	[ "${step_rc}" -eq 0 ] || step_failed 'slots.sh add'
}

create_worktree() {
	mkdir -p -- "${effort_dir}/worktrees" || die 4 "could not create the worktrees folder in ${shown_effort}"
	umask "${caller_umask}"
	run_step ../worktree/worktree-create.sh --repo "${repo}" --base "${base}" --path "${effort_dir}/worktrees/${slot}"
	umask 077
	[ "${step_rc}" -eq 0 ] || step_failed 'worktree-create.sh'
	created_path='' full_base=''
	while IFS= read -r line; do
		case ${line} in
			'worktree '*) created_path=${line#worktree } ;;
			'base '*) full_base=${line#base } ;;
			*) ;;
		esac
	done <<EOF
${step_out}
EOF
	worktree=${created_path}
	[ -n "${worktree}" ] && [ -n "${full_base}" ] || {
		worktree="${effort_dir}/worktrees/${slot}"
		step_rc=4
		step_failed 'worktree-create.sh printed no worktree and base line'
	}
}

parse_args "$@"
load_dependencies
worktree=''
check_inputs
check_slot_free
check_base_slots "$@"
create_worktree
run_step ../worktree/worktree-setup.sh --from "${repo}" --to "${worktree}"
[ "${step_rc}" -eq 0 ] || step_failed 'worktree-setup.sh'
add_seat "$@"
run_step slots.sh get --slots "${slots_file}" --slot "${slot}"
[ "${step_rc}" -eq 0 ] || die 4 "slots.sh get failed (exit ${step_rc}) after the seat was added; the seat is open"
printf '%s\n' "${step_out}"
