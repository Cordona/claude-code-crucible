#!/usr/bin/env sh
# Prints the iteration a writer seat is working on and where its report goes.
# The iteration is 1 + the seat's own commits since its base, so the count
# lives here once and every reader of the report path agrees. It reads only.
set -eu

readonly PROG='iteration.sh'
readonly REPORTS_DIR='.crucible-effort/reports'
# The C locale keeps the shell byte-wise.
LC_ALL=C
export LC_ALL
GIT_OPTIONAL_LOCKS=0
GIT_TERMINAL_PROMPT=0
export GIT_OPTIONAL_LOCKS GIT_TERMINAL_PROMPT
# An inherited repository override would make git read outside the worktree.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
	GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_PREFIX

usage() {
	cat <<EOF
usage: sh ${PROG} --seats FILE --seat S
       sh ${PROG} --help | -h

Prints the iteration seat S is working on and its report's path; reads
only.

--seats FILE  absolute path of the effort's seats.json
--seat S      a developer (mode BUILD) or tester (mode TEST) seat with a
              worktree; it may be open or bound, not chosen (no worktree yet)

stdout, two lines:
  ITERATION: <N>   1 + the commits in <base>..HEAD of the seat's worktree
                   whose Agent-Seat trailer is S
  REPORT: <path>   <worktree>/${REPORTS_DIR}/<S>/<kind>-iteration-<N>.json,
                   absolute; kind build for BUILD, test for TEST

exit codes:
  0  printed
  2  wrong command line: a missing, repeated or unknown option, or a
     missing value
  3  input: seats.json, the seat, its worktree or its base does not fit,
     or the seat is chosen;
     one stderr line per problem (seats.sh's own lines first when it
     refused)
  4  environment: git, jq or seats.sh missing or failed

needs: POSIX sh, git 2.26+, jq 1.6+; seats.sh beside this script
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
	seats_file='' seat=''
	while [ "$#" -gt 0 ]; do
		case $1 in
			-h | --help)
				usage
				exit 0
				;;
			--seats)
				take_value "$1" "${seats_file}" "${2-}" FILE
				seats_file=${option_value}
				;;
			--seat)
				take_value "$1" "${seat}" "${2-}" S
				seat=${option_value}
				;;
			*)
				shown_option=$(printable "$1")
				usage_error "unknown option: ${shown_option}; expected --seats, --seat or --help"
				;;
		esac
		shift 2
	done
	[ -n "${seats_file}" ] || usage_error '--seats missing; expected --seats FILE'
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
	[ -f "${own_dir}/seats.sh" ] || die 4 'seats.sh not found beside this script; expected both in one folder'
}

# Sets kind, worktree and base from seats.sh get, refusing a chosen seat;
# seats.sh's own lines say why it refused.
read_seat() {
	seat_rc=0
	seat_json=$(sh "${own_dir}/seats.sh" get --seats "${seats_file}" --seat "${seat}") || seat_rc=$?
	shown_seat=$(printable "${seat}")
	case ${seat_rc} in
		0) ;;
		2 | 3 | 6) die 3 "seats.sh get refused seat ${shown_seat} (exit ${seat_rc}); expected a seat in --seats" ;;
		*) die 4 "seats.sh get failed (exit ${seat_rc})" ;;
	esac
	fields=$(printf '%s\n' "${seat_json}" | jq -r '.mode // "", .status // "", .worktree // "", .base // ""') ||
		die 4 'jq could not read the seat seats.sh get printed'
	mode='' status='' worktree='' base=''
	{
		IFS= read -r mode || :
		IFS= read -r status || :
		IFS= read -r worktree || :
		IFS= read -r base || :
	} <<EOF
${fields}
EOF
	case ${mode} in
		BUILD) kind='build' ;;
		TEST) kind='test' ;;
		*) die 3 "seat ${shown_seat} has no mode; expected a developer or tester seat" ;;
	esac
	[ "${status}" != chosen ] || die 3 "seat ${shown_seat} is chosen: its worktree is not made yet; expected an open or bound seat"
	[ -n "${worktree}" ] || die 3 "seat ${shown_seat} has no worktree; expected a developer or tester seat"
}

# Sets iteration: 1 + the commits in base..HEAD of the worktree whose
# Agent-Seat trailer is this seat, so another seat sharing the worktree is
# not counted.
count_iteration() {
	shown_worktree=$(printable "${worktree}")
	[ -d "${worktree}" ] || die 3 "seat ${shown_seat}'s worktree ${shown_worktree} is not a folder; expected its git worktree"
	git -c core.fsmonitor=false -C "${worktree}" rev-parse --verify --quiet "${base}^{commit}" >/dev/null ||
		die 3 "seat ${shown_seat}'s base ${base} is not a commit in ${shown_worktree}; expected the seat's base"
	seat_lines=$(git -c core.fsmonitor=false -C "${worktree}" log \
		--format='%(trailers:key=Agent-Seat,valueonly,separator=%x2C)' "${base}..HEAD") ||
		die 4 "git log failed in ${shown_worktree}"
	own_commits=0
	while IFS= read -r line; do
		[ "${line}" != "${seat}" ] || own_commits=$((own_commits + 1))
	done <<EOF
${seat_lines}
EOF
	iteration=$((own_commits + 1))
}

parse_args "$@"
load_dependencies
read_seat
count_iteration
printf 'ITERATION: %s\nREPORT: %s/%s/%s/%s-iteration-%s.json\n' \
	"${iteration}" "${worktree%/}" "${REPORTS_DIR}" "${seat}" "${kind}" "${iteration}"
