#!/usr/bin/env sh
# Prints the iteration a seat is working on, where its report draft goes and
# the event of its newest recorded report. The iteration is derived from git:
# the seat's next build is 1 + its own build commits since its base. It reads
# only.
set -eu

readonly PROG='iteration.sh'
readonly CRUCIBLE_SKILL='crucible'
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
usage: sh ${PROG} --effort FOLDER --seat S
       sh ${PROG} --help | -h

Prints the iteration seat S is working on, its report draft's path and
its newest recorded report; reads only.

--effort FOLDER  the effort folder, absolute
--seat S      a seat with a worktree; it may be open or bound, not chosen
              (no worktree yet)

stdout, three lines:
  ITERATION: <N>   1 + the crucible(build) commits in <base>..HEAD of the
                   worktree whose Agent-Seat trailer is S, the iteration its
                   next build commit opens
  REPORT: <path>   <effort>/drafts/agents/<S>/report.json, absolute
  LAST_REPORT: <path> | none
                   the seat's newest build.committed event, absolute; none
                   when there is none

exit codes:
  0  printed
  2  wrong command line: a missing, repeated or unknown option, or a
     missing value
  3  input: the effort, the seat, its worktree or its base does not fit,
     or the seat is chosen;
     one stderr line per problem (seats.sh's own lines first when it
     refused)
  4  environment: git, jq, seats.sh or events.sh missing or failed

needs: POSIX sh, git 2.26+, jq 1.6+; seats.sh beside this script; the
${CRUCIBLE_SKILL} skill's events.sh
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
	while [ "${effort_folder}" != "${effort_folder%/}" ]; do effort_folder=${effort_folder%/}; done
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
	events_script="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/skills/${CRUCIBLE_SKILL}/scripts/events.sh"
	[ -f "${events_script}" ] || die 4 "events.sh not found; expected the ${CRUCIBLE_SKILL} skill installed"
}

# Sets worktree and base from seats.sh get, refusing a chosen seat;
# seats.sh's own lines say why it refused.
read_seat() {
	seat_rc=0
	seat_json=$(sh "${own_dir}/seats.sh" get --effort "${effort_folder}" --seat "${seat}") || seat_rc=$?
	shown_seat=$(printable "${seat}")
	case ${seat_rc} in
		0) ;;
		2 | 3 | 6) die 3 "seats.sh get refused seat ${shown_seat} (exit ${seat_rc}); expected a seat of --effort" ;;
		*) die 4 "seats.sh get failed (exit ${seat_rc})" ;;
	esac
	fields=$(printf '%s\n' "${seat_json}" | jq -r '.status // "", .worktree // "", .base // ""') ||
		die 4 'jq could not read the seat seats.sh get printed'
	status='' worktree='' base=''
	{
		IFS= read -r status || :
		IFS= read -r worktree || :
		IFS= read -r base || :
	} <<EOF
${fields}
EOF
	[ "${status}" != chosen ] || die 3 "seat ${shown_seat} is chosen: its worktree is not made yet; expected an open or bound seat"
	[ -n "${worktree}" ] || die 3 "seat ${shown_seat} has no worktree; expected a seat with a worktree"
}

# Sets iteration from the seat's own build commits in the worktree's
# base..HEAD.
count_iteration() {
	shown_worktree=$(printable "${worktree}")
	[ -d "${worktree}" ] || die 3 "seat ${shown_seat}'s worktree ${shown_worktree} is not a folder; expected its git worktree"
	git -c core.fsmonitor=false -C "${worktree}" rev-parse --verify --quiet "${base}^{commit}" >/dev/null ||
		die 3 "seat ${shown_seat}'s base ${base} is not a commit in ${shown_worktree}; expected the seat's base"
	build_lines=$(git -c core.fsmonitor=false -C "${worktree}" log \
		--format='%s%x09%(trailers:key=Agent-Seat,valueonly,separator=%x2C)' "${base}..HEAD") ||
		die 4 "git log failed in ${shown_worktree}"
	own_builds=0
	tab=$(printf '\t')
	while IFS= read -r line; do
		case ${line} in
			"crucible(build): "*) ;;
			*) continue ;;
		esac
		[ "${line#*"${tab}"}" != "${seat}" ] || own_builds=$((own_builds + 1))
	done <<EOF
${build_lines}
EOF
	iteration=$((own_builds + 1))
}

# Sets last_report to the seat's newest build.committed event.
find_last_report() {
	last_report=$(sh "${events_script}" latest --effort "${effort_folder}" --type build.committed \
		--where ".seat == \"${seat}\"" </dev/null) ||
		die 4 'events.sh latest failed (its stderr is above)'
}

parse_args "$@"
load_dependencies
read_seat
count_iteration
find_last_report
printf 'ITERATION: %s\nREPORT: %s/drafts/agents/%s/report.json\n' \
	"${iteration}" "${effort_folder}" "${seat}"
printf 'LAST_REPORT: %s\n' "${last_report:-none}"
