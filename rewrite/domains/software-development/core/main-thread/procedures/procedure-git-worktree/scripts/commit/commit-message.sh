#!/usr/bin/env sh
# Writes a Crucible commit message file from one input JSON file, so the
# message is never typed by hand. The shell checks the command line and the
# paths; commit-message.jq checks the input and builds the message. The file
# goes in place through a temp file beside it, so it is whole or absent.
set -eu
umask 077

readonly PROG='commit-message.sh'
readonly MODULE='commit-message'
# Bounds stderr so a refusal stays readable; the last line counts the rest.
readonly MAX_PROBLEMS=20
# The C locale keeps the shell byte-wise; jq writes the message as UTF-8.
LC_ALL=C
export LC_ALL

# Reads the input raw and prints {problems, message}: the problem lines, at
# most $max, and the message, null when any problem holds.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly MESSAGE_JQ='include "commit-message";
[try fromjson] as $parsed
| (if ($parsed | length) == 0 then ["the input is not valid JSON; expected one JSON object"] else $parsed[0] | commit_problems end) as $problems
| {problems: ($problems | if length > $max then .[:$max - 1] + ["\(length - $max + 1) more problems not shown; expected none"] else . end),
	message: (if ($problems | length) == 0 then $parsed[0] | commit_message else null end)}'

usage() {
	cat <<EOF
usage: sh ${PROG} --input FILE --out FILE
       sh ${PROG} --help | -h

Writes one Crucible commit message; runs no git.

--input FILE  a JSON object, no other fields:
                kind      dev, test, fix, review, aggregated-review,
                          fix-choice or import
                text      the subject's text: one line; the whole subject
                          "crucible(<kind>): <text>" at most 72 characters
                trailers  an object; the count a whole number of 1 or more,
                          frameworks and standards arrays of strings, every
                          other trailer a string; each string one line, at
                          most 200 characters; an array item holds no comma
                          or whitespace, joined at most 500 characters
--out FILE    the message file, written whole through a temp file beside it;
              its folder must exist

kinds and their trailers, in message order (all required but frameworks):
  dev                            build-iteration, then the agent trailers
  test                           test-iteration, then the agent trailers
  fix, review                    review-round, then the agent trailers
  aggregated-review, fix-choice  review-round, effort
  import                         effort, imported-from (no count)
  agent trailers: effort, dispatch, agent-slot, agent-id, language,
                  frameworks, standards
A count trailer of another kind is refused.

output: crucible(<kind>): <text>
        then a blank line and one "Key-Name: value" line per trailer given,
        in the order above; an array is one line, items joined by ", "

exit codes:
  0  the message file is written; nothing is printed
  2  wrong command line: a missing or unknown option, or a missing value
  3  the input is invalid; each problem is one stderr line (at most ${MAX_PROBLEMS})
  4  the message file could not be written, or jq is missing or failed
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

parse_args() {
	input='' out=''
	while [ "$#" -gt 0 ]; do
		case $1 in
			-h | --help)
				usage
				exit 0
				;;
			--input | --out)
				[ "$#" -ge 2 ] && [ -n "$2" ] || usage_error "$1 needs a value; expected $1 FILE"
				if [ "$1" = --input ]; then
					[ -z "${input}" ] || usage_error '--input given twice; expected one'
					input=$2
				else
					[ -z "${out}" ] || usage_error '--out given twice; expected one'
					out=$2
				fi
				shift 2
				;;
			*)
				shown_option=$(printable "$1")
				usage_error "unknown option: ${shown_option}; expected --input, --out or --help"
				;;
		esac
	done
	[ -n "${input}" ] || usage_error '--input missing; expected --input FILE'
	[ -n "${out}" ] || usage_error '--out missing; expected --out FILE'
}

script_dir() {
	case $0 in
		*/*) printf '%s' "${0%/*}" ;;
		*) printf '.' ;;
	esac
}

# Sets result to MESSAGE_JQ's output over the input file.
build_message() {
	shown_input=$(printable "${input}")
	[ -f "${input}" ] && [ -r "${input}" ] ||
		die 3 "--input ${shown_input} is not a readable file; expected the input JSON file"
	command -v jq >/dev/null 2>&1 || die 4 'jq not found; expected jq 1.6+ on PATH'
	own_dir=$(script_dir)
	result=$(jq -Rsc -L "${own_dir}" --argjson max "${MAX_PROBLEMS}" "${MESSAGE_JQ}" <"${input}") ||
		die 4 "jq failed; expected jq 1.6+ and ${MODULE}.jq beside ${PROG}"
	problems=$(printf '%s\n' "${result}" | jq -r '.problems[]') ||
		die 4 'jq failed reading the problems; expected jq 1.6+'
	[ -n "${problems}" ] || return 0
	while IFS= read -r problem; do
		warn "${problem}"
	done <<EOF
${problems}
EOF
	exit 3
}

# Writes the message over --out through a temp file in the same folder.
write_message() {
	shown_out=$(printable "${out}")
	case ${out} in
		*/) die 4 "--out ${shown_out} names a folder; expected a file path" ;;
		*/*) out_dir=${out%/*} ;;
		*) out_dir=. ;;
	esac
	[ -n "${out_dir}" ] || out_dir=/
	shown_out_dir=$(printable "${out_dir}")
	[ -d "${out_dir}" ] || die 4 "--out folder ${shown_out_dir} does not exist; expected an existing folder"
	[ ! -d "${out}" ] || die 4 "--out ${shown_out} is a folder; expected a file path"
	temp_file=$(mktemp "${out_dir}/.${out##*/}.XXXXXX") ||
		die 4 "mktemp could not create a temp file beside ${shown_out}; expected a writable folder"
	printf '%s\n' "${result}" | jq -j '.message' >"${temp_file}" ||
		die 4 "could not write the temp file beside ${shown_out}; expected free space"
	mv -f "${temp_file}" "${out}" ||
		die 4 "mv could not move the temp file onto ${shown_out}; expected a writable folder"
	temp_file=''
}

# shellcheck disable=SC2329 # invoked by the EXIT trap
clean_up() {
	[ -z "${temp_file}" ] || rm -f "${temp_file}"
}

temp_file=''
trap clean_up EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

parse_args "$@"
build_message
write_message
