#!/usr/bin/env sh
# Opens one chosen writer seat: a detached worktree of the main checkout at
# the seat's base, at the path seats.json records, the checkout's dependency
# folders copied into it, and the seat's status set to open. It only runs
# seats.sh, worktree-create.sh and worktree-setup.sh in order; a failure after
# the worktree exists removes it again and leaves the seat chosen, so a rerun
# starts clean.
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
usage: sh ${PROG} --effort DIR --seat S
       sh ${PROG} --help | -h

Opens a chosen developer seat, stopping at the first failing step:
  seats.sh get --seats <effort>/seats.json --seat S   (its repo, base and worktree)
  ../worktree/worktree-create.sh --repo <repo> --base <base> --path <worktree>
  ../worktree/worktree-setup.sh --from <repo> --to <worktree>
  seats.sh opened --seats <effort>/seats.json --seat S
and prints the seat as seats.sh get does. A failure after the worktree
exists removes it (git worktree remove --force), says so, and leaves the
seat chosen.

--effort DIR  absolute path of the effort folder (it holds seats.json)
--seat S      a seat seats.sh choose recorded, status chosen; a developer
              (a tester shares a developer's worktree: not yet supported
              and refused)

The steps' own stderr lines come first; this script adds one line saying
which step failed.

exit codes:
  0  the seat is open; its JSON line is printed
  2  wrong command line: a missing, repeated or unknown option, or a
     missing value
  3  input: a refused option, the seat not in seats.json, a seat that is
     no developer's (checked before its status), or a step refused its
     input (exit 3)
  4  a step failed otherwise, or a dependency is missing
  5  the seat is not chosen: it is open already or has an agent

needs: POSIX sh, git 2.26+, jq 1.6+; seats.sh, ../worktree/worktree-create.sh
and ../worktree/worktree-setup.sh from this script's folder
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
	effort='' seat=''
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
	[ -n "${effort}" ] || usage_error '--effort missing; expected --effort DIR'
	[ -n "${seat}" ] || usage_error '--seat missing; expected --seat S'
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
	for step in ../worktree/worktree-create.sh ../worktree/worktree-setup.sh seats.sh; do
		[ -f "${own_dir}/${step}" ] || {
			shown_step=$(printable "${own_dir}/${step}")
			die 4 "${shown_step} not found; expected the procedure's scripts folders whole"
		}
	done
}

# Sets effort_dir (the physical effort folder) and seats_file.
check_inputs() {
	shown_effort=$(printable "${effort}")
	case ${effort} in
		/*) ;;
		*) die 3 "--effort ${shown_effort} is not absolute; expected an absolute path" ;;
	esac
	effort_dir=$(cd -P -- "${effort}" 2>/dev/null && pwd -P) ||
		die 3 "--effort ${shown_effort} is not a folder; expected the effort folder"
	seats_file="${effort_dir}/seats.json"
	shown_seats=$(printable "${seats_file}")
}

# Sets role, repo, base and worktree from the chosen seat, before anything is
# created; seats.sh's own lines say why it refused.
read_chosen_seat() {
	step_rc=0
	seat_json=$(sh "${own_dir}/seats.sh" get --seats "${seats_file}" --seat "${seat}") || step_rc=$?
	shown_seat=$(printable "${seat}")
	case ${step_rc} in
		0) ;;
		6) die 3 "seat ${shown_seat} is not in ${shown_seats}; expected a seat seats.sh choose recorded" ;;
		2 | 3) die 3 "seats.sh get refused seat ${shown_seat} (exit ${step_rc}); expected a seat in ${shown_seats}" ;;
		*) die 4 "seats.sh get failed (exit ${step_rc})" ;;
	esac
	fields=$(printf '%s\n' "${seat_json}" | jq -r '.role // "", .status // "", .repo // "", .base // "", .worktree // ""') ||
		die 4 'jq could not read the seat seats.sh get printed'
	role='' status='' repo='' base='' worktree=''
	{
		IFS= read -r role || :
		IFS= read -r status || :
		IFS= read -r repo || :
		IFS= read -r base || :
		IFS= read -r worktree || :
	} <<EOF
${fields}
EOF
	case ${role} in
		developer) ;;
		tester) die 3 "seat ${shown_seat} is a tester seat, not yet supported: a tester shares a developer's worktree; expected a developer seat" ;;
		*) die 3 "seat ${shown_seat} is a ${role} seat; expected a developer seat" ;;
	esac
	[ "${status}" = chosen ] || die 5 "seat ${shown_seat} is ${status}; expected a chosen seat: only a chosen seat has no worktree yet"
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
	[ "${created}" = yes ] || return 0
	shown_worktree=$(printable "${worktree}")
	if git -C "${repo}" worktree remove --force "${worktree}" >/dev/null 2>&1; then
		removal_note="; removed the worktree ${shown_worktree} so a rerun starts clean; the seat is still chosen"
	else
		removal_note="; could not remove the worktree ${shown_worktree}: remove it with git worktree remove --force; the seat is still chosen"
	fi
	created=no
}

create_worktree() {
	mkdir -p -- "${worktree%/*}" || die 4 "could not create the worktrees folder in ${shown_effort}"
	umask "${caller_umask}"
	run_step ../worktree/worktree-create.sh --repo "${repo}" --base "${base}" --path "${worktree}"
	umask 077
	[ "${step_rc}" -eq 0 ] || step_failed 'worktree-create.sh'
	created=yes
}

parse_args "$@"
load_dependencies
created=no
check_inputs
read_chosen_seat
create_worktree
run_step ../worktree/worktree-setup.sh --from "${repo}" --to "${worktree}"
[ "${step_rc}" -eq 0 ] || step_failed 'worktree-setup.sh'
run_step seats.sh opened --seats "${seats_file}" --seat "${seat}"
[ "${step_rc}" -eq 0 ] || step_failed 'seats.sh opened'
run_step seats.sh get --seats "${seats_file}" --seat "${seat}"
[ "${step_rc}" -eq 0 ] || die 4 "seats.sh get failed (exit ${step_rc}) after the seat was opened; the seat is open"
printf '%s\n' "${step_out}"
