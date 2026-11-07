#!/usr/bin/env sh
# Prints the next free seat name of a role in an effort, so no caller builds a
# seat name itself. The names and the letters come from seats.jq, which also
# checks the file. It reads only, without seats.sh's lock: a name is taken
# only when seats.sh writes it.
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
usage: sh ${PROG} --seats FILE --role developer|tester
       sh ${PROG} --seats FILE --role reviewer --lens L
       sh ${PROG} --help | -h

Prints the next free seat name of the role: its prefix, a dash and the
first of alpha, beta ... omega that no seat in FILE uses with that prefix.
Reads only; a missing FILE means no name is used yet.

--seats FILE  absolute path of the effort's seats.json; its folder must
              exist
--role ROLE   developer (software-developer-...), tester
              (software-tester-...) or reviewer (<L>-reviewer-...)
--lens L      the reviewer's lens, lowercase words joined by dashes, like
              security; a reviewer only

stdout: the name, like software-developer-alpha or security-reviewer-alpha

exit codes:
  0  printed
  2  wrong command line: a missing, repeated or unknown option, a missing
     value, --lens without --role reviewer or missing with it
  3  input: a bad --seats path, role or lens, seats.json does not fit
     (one stderr line per problem), or all 24 names of the prefix are taken
  4  environment: jq missing or failed, or ${MODULE}.jq not beside ${PROG}

needs: POSIX sh, jq 1.6+; ${MODULE}.jq beside this script
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
	seats_file='' role='' lens=''
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
				usage_error "unknown option: ${shown_option}; expected --seats, --role, --lens or --help"
				;;
		esac
		shift 2
	done
	[ -n "${seats_file}" ] || usage_error '--seats missing; expected --seats FILE'
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

# Sets exists and current_file, refusing a path that can't be the file.
check_seats_path() {
	shown_seats=$(printable "${seats_file}")
	case ${seats_file} in
		*[[:cntrl:]]*) die 3 "--seats ${shown_seats} holds a control character; expected a plain path" ;;
		*/) die 3 "--seats ${shown_seats} names a folder; expected the seats.json path" ;;
		/*) ;;
		*) die 3 "--seats ${shown_seats} is not absolute; expected an absolute path" ;;
	esac
	seats_dir=${seats_file%/*}
	[ -n "${seats_dir}" ] || seats_dir=/
	shown_dir=$(printable "${seats_dir}")
	[ -d "${seats_dir}" ] || die 3 "--seats folder ${shown_dir} does not exist; expected the effort folder"
	if [ -e "${seats_file}" ]; then
		[ -f "${seats_file}" ] && [ -r "${seats_file}" ] ||
			die 3 "--seats ${shown_seats} is not a readable file; expected the seats JSON file"
		exists=yes current_file=${seats_file}
	else
		exists=no current_file=/dev/null
	fi
}

# Prints the problems to stderr and the name to stdout; exits with the code.
print_name() {
	result=$(jq -nc -L "${own_dir}" --rawfile current "${current_file}" --arg exists "${exists}" \
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
check_seats_path
print_name
