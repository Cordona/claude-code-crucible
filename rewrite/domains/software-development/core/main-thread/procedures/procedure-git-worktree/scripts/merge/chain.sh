#!/usr/bin/env sh
# Says whether the seats a developer seat was cut from have work it lacks:
# every seat its base_seats name, followed through every level, with that
# seat's worktree HEAD and whether the seat's own HEAD already holds it. It
# reads only.
set -eu
umask 077

readonly PROG='chain.sh'
readonly tab='	'
# The C locale keeps the shell byte-wise.
LC_ALL=C
export LC_ALL
GIT_OPTIONAL_LOCKS=0
GIT_TERMINAL_PROMPT=0
export GIT_OPTIONAL_LOCKS GIT_TERMINAL_PROMPT
# An inherited repository override would make git read outside the seats'
# worktrees.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
	GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_PREFIX

usage() {
	cat <<EOF
usage: sh ${PROG} --effort DIR --seat S
       sh ${PROG} --help | -h

Lists every seat that developer seat S was cut from: the seats its base_seats
name in seats.json, theirs, and so on, each once (a cycle ends the walk).
For each, its worktree HEAD now and whether S's worktree HEAD holds it.
Reads only.

--effort DIR  absolute path of the effort folder (it holds seats.json)
--seat S      a developer seat with a worktree (not chosen)

stdout, one JSON line:
  {"seat":S,"head":<sha>,"parents":[{"seat":P,"via":V,"head":<sha>|null,
   "in_seat":bool}...],"moved":bool}
  via: the seat of S's own base_seats P was reached through (P itself
  for a direct parent); head null and in_seat true when P has no
  worktree or HEAD (nothing to take from it); moved: any in_seat false

exit codes:
  0  printed
  2  wrong command line: a missing, repeated or unknown option, or a
     missing value
  3  input: a bad option value, seats.json or the seat does not fit
     (seats.sh's own lines first), or the seat is no developer with a
     worktree (a chosen seat has none yet)
  4  environment: git, jq or seats.sh missing or failed

needs: POSIX sh, git 2.26+, jq 1.6+; ../seats/seats.sh and chain.jq from
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
	for neighbour in ../seats/seats.sh chain.jq; do
		[ -f "${own_dir}/${neighbour}" ] || {
			shown_neighbour=$(printable "${own_dir}/${neighbour}")
			die 4 "${shown_neighbour} not found; expected the procedure's scripts folders whole"
		}
	done
}

# Sets effort_dir (physical) and seats_file.
check_effort() {
	shown_effort=$(printable "${effort}")
	case ${effort} in
		/*) ;;
		*) die 3 "--effort ${shown_effort} is not absolute; expected an absolute path" ;;
	esac
	effort_dir=$(cd -P -- "${effort}" 2>/dev/null && pwd -P) ||
		die 3 "--effort ${shown_effort} is not a folder; expected the effort folder"
	seats_file="${effort_dir}/seats.json"
}

# Sets worktree and seat_head from seats.sh get, which also checks the whole
# file against its contract; seats.sh's own lines say why it refused.
read_seat() {
	seat_rc=0
	seat_json=$(sh "${own_dir}/../seats/seats.sh" get --seats "${seats_file}" --seat "${seat}") || seat_rc=$?
	shown_seat=$(printable "${seat}")
	case ${seat_rc} in
		0) ;;
		2 | 3 | 6) die 3 "seats.sh get refused seat ${shown_seat} (exit ${seat_rc}); expected a seat in --effort's seats.json" ;;
		*) die 4 "seats.sh get failed (exit ${seat_rc})" ;;
	esac
	fields=$(printf '%s\n' "${seat_json}" | jq -r '.role // "", .status // "", .worktree // ""') ||
		die 4 'jq could not read the seat seats.sh get printed'
	role='' status='' worktree=''
	{
		IFS= read -r role || :
		IFS= read -r status || :
		IFS= read -r worktree || :
	} <<EOF
${fields}
EOF
	[ "${role}" = developer ] || die 3 "seat ${shown_seat} is a ${role} seat; expected a developer seat"
	[ "${status}" != chosen ] || die 3 "seat ${shown_seat} is chosen: its worktree is not made yet; expected a seat with a worktree"
	shown_worktree=$(printable "${worktree}")
	[ -d "${worktree}" ] || die 3 "seat ${shown_seat}'s worktree ${shown_worktree} is not a folder; expected its git worktree"
	seat_head=$(git -C "${worktree}" -c core.fsmonitor=false rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null) ||
		die 3 "seat ${shown_seat}'s worktree ${shown_worktree} has no HEAD commit; expected its git worktree"
}

# Writes work_dir/parents, "<seat><TAB><via><TAB><head><TAB><in seat>" per
# seat the seat was cut from; head is empty when it has no worktree or HEAD.
list_parents() {
	# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
	jq -r -L "${own_dir}" --arg seat "${seat}" 'include "chain"; ancestors($seat) | [.seat, .via, .worktree] | join("\t")' \
		"${seats_file}" >"${work_dir}/ancestors" 2>"${work_dir}/stderr" || git_failed 'jq walking the base seats of seats.json'
	while IFS= read -r ancestor_line; do
		parent=${ancestor_line%%"${tab}"*}
		ancestor_rest=${ancestor_line#*"${tab}"}
		via=${ancestor_rest%%"${tab}"*}
		parent_worktree=${ancestor_rest#*"${tab}"}
		parent_head=''
		[ -z "${parent_worktree}" ] || [ ! -d "${parent_worktree}" ] ||
			parent_head=$(git -C "${parent_worktree}" -c core.fsmonitor=false rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null) ||
			parent_head=''
		in_seat=true
		[ -z "${parent_head}" ] || is_in_seat "${parent_head}"
		printf '%s\t%s\t%s\t%s\n' "${parent}" "${via}" "${parent_head}" "${in_seat}"
	done <"${work_dir}/ancestors" >"${work_dir}/parents"
}

# Sets in_seat to whether commit $1 is an ancestor of the seat's HEAD.
is_in_seat() {
	ancestor_rc=0
	git -C "${worktree}" -c core.fsmonitor=false merge-base --is-ancestor "$1" "${seat_head}" 2>"${work_dir}/stderr" ||
		ancestor_rc=$?
	case ${ancestor_rc} in
		0) in_seat=true ;;
		1) in_seat=false ;;
		*) git_failed 'git merge-base --is-ancestor' ;;
	esac
}

# Exits 4 naming step $1 and the first line of work_dir/stderr.
git_failed() {
	first_line=$(head -n 1 "${work_dir}/stderr" 2>/dev/null) || first_line=''
	shown_line=$(printable "${first_line}")
	die 4 "$1 failed: ${shown_line}"
}

# shellcheck disable=SC2329 # invoked by the EXIT trap
clean_up() {
	[ -z "${work_dir}" ] || rm -rf -- "${work_dir}"
}

work_dir=''
trap clean_up EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

parse_args "$@"
load_dependencies
check_effort
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/crucible-chain.XXXXXX") ||
	die 4 'mktemp could not create a work folder; expected a writable TMPDIR'
read_seat
list_parents
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
jq -nc --arg seat "${seat}" --arg head "${seat_head}" --rawfile parents "${work_dir}/parents" '
	($parents | rtrimstr("\n") | if . == "" then [] else split("\n") end
		| map(split("\t") | {seat: .[0], via: .[1], head: (if .[2] == "" then null else .[2] end), in_seat: (.[3] == "true")})) as $found
	| {seat: $seat, head: $head, parents: $found, moved: any($found[]; .in_seat | not)}' ||
	die 4 'jq could not print the result'
