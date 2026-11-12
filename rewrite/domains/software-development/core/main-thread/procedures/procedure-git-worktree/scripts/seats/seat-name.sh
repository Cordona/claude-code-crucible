#!/usr/bin/env sh
# Prints the next free seat name of a role in an effort, so no caller builds a
# seat name itself. The names and the letters come from seats.jq, over the
# seat list seats.sh list replays. It reads only: a name is taken only when
# seats.sh records it.
set -eu

readonly PROG='seat-name.sh'
readonly MODULE='seats'
# The C locale keeps the shell byte-wise; jq reads the file as UTF-8.
LC_ALL=C
export LC_ALL

# Prints {exit, problems, out}, as seats.sh's program does.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly NAME_JQ='include "seats";
seats_name_run($role; $lens; if $exists == "yes" then $current else null end)'

usage() {
	cat <<EOF
usage: sh ${PROG} --effort FOLDER --role developer|tester
       sh ${PROG} --effort FOLDER --role reviewer --lens L
       sh ${PROG} --help | -h

Prints the next free seat name of the role: its prefix, a dash and the
first letter no seat of the effort uses with that prefix, in the order
alpha, beta ... omega, then alpha-2 ... omega-2, alpha-3 and on, with no
limit. Reads only.

--effort FOLDER  the effort folder, absolute
--role ROLE   developer (build-agent-...), tester (test-agent-...) or
              reviewer (<L>-reviewer-agent-...)
--lens L      the reviewer's lens, lowercase words joined by dashes, like
              security; a reviewer only

stdout: the name, like build-agent-alpha, build-agent-alpha-2 or
        security-reviewer-agent-alpha

exit codes:
  0  printed
  2  wrong command line: a missing, repeated or unknown option, a missing
     value, --lens without --role reviewer or missing with it
  3  input: a bad --effort folder, role or lens, or the seat list does not
     fit (one stderr line per problem)
  4  environment: jq missing or failed, or seats.sh or ${MODULE}.jq not
     beside ${PROG}

needs: POSIX sh, jq 1.6+; seats.sh and ${MODULE}.jq beside this script
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
	effort_folder='' role='' lens=''
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
			--role)
				take_value "$1" "${role}" "${2-}" 'developer|tester|reviewer'
				role=${option_value}
				;;
			--lens)
				take_value "$1" "${lens}" "${2-}" L
				lens=${option_value}
				;;
			*)
				shown_option=$(printable "$1")
				usage_error "unknown option: ${shown_option}; expected --effort, --role, --lens or --help"
				;;
		esac
		shift 2
	done
	[ -n "${effort_folder}" ] || usage_error '--effort missing; expected --effort FOLDER'
	[ -n "${role}" ] || usage_error '--role missing; expected --role developer|tester|reviewer'
	if [ "${role}" = reviewer ]; then
		[ -n "${lens}" ] || usage_error '--lens missing; expected --lens L for a reviewer'
	else
		[ -z "${lens}" ] || usage_error '--lens is given without --role reviewer; expected it only for a reviewer'
	fi
}

script_dir() {
	case $0 in
		*/*) printf '%s' "${0%/*}" ;;
		*) printf '.' ;;
	esac
}

load_dependencies() {
	command -v jq >/dev/null 2>&1 || die 4 'jq not found; expected jq 1.6+ on PATH'
	own_dir=$(script_dir)
	[ -f "${own_dir}/${MODULE}.jq" ] || die 4 "${MODULE}.jq not found beside ${PROG}; expected both in one folder"
}

# Sets current to the effort's seat list, as seats.sh list replays it, and
# exists to yes when it holds a seat.
read_seats() {
	shown_effort=$(printable "${effort_folder}")
	[ -f "${own_dir}/seats.sh" ] || die 4 "seats.sh not found beside ${PROG}; expected both in one folder"
	if current=$(sh "${own_dir}/seats.sh" list --effort "${effort_folder}" </dev/null); then
		:
	else
		list_status=$?
		[ "${list_status}" -ne 3 ] || die 3 "--effort ${shown_effort} is no effort folder (seats.sh stderr above)"
		die 4 "seats.sh list exited ${list_status} (its stderr is above); expected the seat list"
	fi
	exists=yes
	case ${current} in
		*'"seats":[]'*) exists=no ;;
		*) ;;
	esac
}

# Prints the problems to stderr and the name to stdout; exits with the code.
print_name() {
	result=$(jq -nc -L "${own_dir}" --arg current "${current}" --arg exists "${exists}" \
		--arg role "${role}" --arg lens "${lens}" "${NAME_JQ}") ||
		die 4 "jq failed; expected jq 1.6+ and ${MODULE}.jq beside ${PROG}"
	outcome=$(printf '%s\n' "${result}" | jq -r '.exit') || die 4 'jq failed reading the result; expected jq 1.6+'
	problems=$(printf '%s\n' "${result}" | jq -r '.problems[]') || die 4 'jq failed reading the problems; expected jq 1.6+'
	if [ -n "${problems}" ]; then
		while IFS= read -r problem; do
			warn "${problem}"
		done <<EOF
${problems}
EOF
	fi
	name=$(printf '%s\n' "${result}" | jq -r '.out') || die 4 'jq failed reading the name; expected jq 1.6+'
	[ -z "${name}" ] || printf '%s\n' "${name}"
	exit "${outcome}"
}

parse_args "$@"
load_dependencies
read_seats
print_name
