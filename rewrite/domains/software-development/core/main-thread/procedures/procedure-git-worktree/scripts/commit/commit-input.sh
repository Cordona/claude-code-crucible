#!/usr/bin/env sh
# Prints the commit-message.sh input for one writer seat's current work: the
# kind from the seat's mode, the count and the report from iteration.sh, the
# text from that report, the trailers from seats.json, the seat and its
# dispatch file. It reads only; commit-message.sh checks what it prints.
set -eu
umask 077

readonly PROG='commit-input.sh'
# The C locale keeps the shell byte-wise; jq writes the JSON as UTF-8.
LC_ALL=C
export LC_ALL

# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly INPUT_JQ='$dispatch_json[0].plugins as $plugins
| {kind: $kind, text: $report[0].summary,
	trailers: ({($count_key): $count, effort: $effort, dispatch: $seat.dispatch, "agent-seat": $seat.seat,
		"agent-id": $seat.agent_id, language: $plugins.language.name?,
		frameworks: [$plugins.frameworks[]?.name], standards: [$plugins.standards[]?.name]}
		| with_entries(select(.value != null and .value != [])))}'

usage() {
	cat <<EOF
usage: sh ${PROG} --seats FILE --seat S [--out FILE]
       sh ${PROG} --help | -h

Prints the commit-message.sh input JSON for seat S's current work. Reads
only; checks no value commit-message.sh checks.

--seats FILE   absolute path of the effort's seats.json; its folder is the
               effort folder
--seat S       a developer or tester seat with an agent bound
--out FILE     write the JSON there, whole through a temp file beside it,
               instead of printing it

the input:
  kind      dev for mode BUILD, test for mode TEST
  text      the summary of iteration.sh's REPORT file, one JSON object
  trailers  build-iteration (dev) or test-iteration (test): iteration.sh's
            ITERATION; effort (seats.json's effort), dispatch, agent-seat,
            agent-id (the seat's); language, frameworks (left out when
            none) and standards: the plugin names in the seat's one
            dispatch file, <effort folder>/dispatches/<dispatch>-*-dispatch.json

exit codes:
  0  printed (or written); with --out nothing is printed
  2  wrong command line: a missing, repeated or unknown option, or a
     missing value
  3  input: seats.json, the seat, the report, the dispatch file or the
     worktree does not fit; one stderr line per problem (seats.sh's or
     iteration.sh's own lines first when it refused)
  4  environment: jq, seats.sh or iteration.sh missing or failed, or --out
     could not be written

needs: POSIX sh, jq 1.6+; ../seats/seats.sh and ../seats/iteration.sh (git 2.26+)
from this script's folder
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
	seats_file='' seat='' out=''
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
			--out)
				take_value "$1" "${out}" "${2-}" FILE
				out=${option_value}
				;;
			*)
				shown_option=$(printable "$1")
				usage_error "unknown option: ${shown_option}; expected --seats, --seat, --out or --help"
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
	command -v jq >/dev/null 2>&1 || die 4 'jq not found; expected jq 1.6+ on PATH'
	own_path=$(script_dir)
	own_dir=$(cd -P -- "${own_path}" && pwd -P) || die 4 "this script's folder could not be entered"
	for neighbour in ../seats/seats.sh ../seats/iteration.sh; do
		[ -f "${own_dir}/${neighbour}" ] || {
			shown_neighbour=$(printable "${own_dir}/${neighbour}")
			die 4 "${shown_neighbour} not found; expected the procedure's scripts folders whole"
		}
	done
}

# Sets effort_dir and effort from seats.json.
read_effort() {
	shown_seats=$(printable "${seats_file}")
	case ${seats_file} in
		/*) ;;
		*) die 3 "--seats ${shown_seats} is not absolute; expected an absolute path" ;;
	esac
	[ -f "${seats_file}" ] && [ -r "${seats_file}" ] || die 3 "--seats ${shown_seats} is not a readable file; expected the effort's seats.json"
	effort_dir=${seats_file%/*}
	effort=$(jq -r '.effort | strings' "${seats_file}" 2>/dev/null) ||
		die 3 "--seats ${shown_seats} is not JSON; expected the effort's seats.json"
	[ -n "${effort}" ] || die 3 "--seats ${shown_seats} has no effort; expected a non-empty effort string"
}

# Sets seat_json, kind, count_key and dispatch from seats.sh get; seats.sh's
# own lines say why it refused.
read_seat() {
	seat_rc=0
	seat_json=$(sh "${own_dir}/../seats/seats.sh" get --seats "${seats_file}" --seat "${seat}") || seat_rc=$?
	case ${seat_rc} in
		0) ;;
		2 | 3 | 6)
			shown_seat=$(printable "${seat}")
			die 3 "seats.sh get refused seat ${shown_seat} (exit ${seat_rc}); expected a seat in --seats"
			;;
		*) die 4 "seats.sh get failed (exit ${seat_rc})" ;;
	esac
	fields=$(printf '%s\n' "${seat_json}" | jq -r '.mode // "", .status // "", .dispatch // ""') ||
		die 4 'jq could not read the seat seats.sh get printed'
	mode='' status='' dispatch=''
	{
		IFS= read -r mode || :
		IFS= read -r status || :
		IFS= read -r dispatch || :
	} <<EOF
${fields}
EOF
	case ${mode} in
		BUILD) kind=dev count_key=build-iteration ;;
		TEST) kind=test count_key=test-iteration ;;
		*) die 3 "seat ${seat} has no mode; expected a developer or tester seat" ;;
	esac
	[ -n "${dispatch}" ] || die 3 "seat ${seat} is ${status}; expected an agent and its dispatch bound"
}

# Sets dispatch_file to the seat's one dispatch file.
find_dispatch_file() {
	set -- "${effort_dir}/dispatches/${dispatch}"-*-dispatch.json
	[ "$#" -eq 1 ] && [ -f "$1" ] && dispatch_file=$1 && return 0
	# An unmatched glob stays as written, so only existing files count.
	files=0
	for path in "$@"; do
		[ ! -f "${path}" ] || files=$((files + 1))
	done
	die 3 "expected one dispatches/${dispatch}-*-dispatch.json in the effort folder, found ${files}"
}

# Sets count and report from iteration.sh; iteration.sh's own lines say why
# it refused.
read_iteration() {
	iteration_rc=0
	iteration_out=$(sh "${own_dir}/../seats/iteration.sh" --seats "${seats_file}" --seat "${seat}") || iteration_rc=$?
	case ${iteration_rc} in
		0) ;;
		3) die 3 "iteration.sh refused seat ${seat} (exit 3); expected a seat with a worktree and its base" ;;
		*) die 4 "iteration.sh failed (exit ${iteration_rc})" ;;
	esac
	count='' report=''
	while IFS= read -r line; do
		case ${line} in
			'ITERATION: '*) count=${line#ITERATION: } ;;
			'REPORT: '*) report=${line#REPORT: } ;;
			*) ;;
		esac
	done <<EOF
${iteration_out}
EOF
	[ -n "${count}" ] && [ -n "${report}" ] || die 4 'iteration.sh printed no ITERATION or REPORT line'
}

check_report() {
	shown_report=$(printable "${report}")
	[ -f "${report}" ] && [ -r "${report}" ] || die 3 "the report ${shown_report} is not a readable file; expected the agent's report for this iteration"
	jq -e 'type == "object"' "${report}" >/dev/null 2>&1 ||
		die 3 "the report ${shown_report} is not one JSON object; expected the agent's report"
}

build_input() {
	shown_dispatch=$(printable "${dispatch_file}")
	input=$(jq -nc --slurpfile report "${report}" --slurpfile dispatch_json "${dispatch_file}" \
		--argjson seat "${seat_json}" --arg kind "${kind}" --arg count_key "${count_key}" \
		--argjson count "${count}" --arg effort "${effort}" "${INPUT_JQ}" 2>/dev/null) ||
		die 3 "the dispatch file ${shown_dispatch} is not one JSON object; expected the seat's dispatch"
}

write_input() {
	if [ -z "${out}" ]; then
		printf '%s\n' "${input}"
		return 0
	fi
	shown_out=$(printable "${out}")
	case ${out} in
		*/) die 4 "--out ${shown_out} names a folder; expected a file path" ;;
		*/*) out_dir=${out%/*} ;;
		*) out_dir=. ;;
	esac
	[ -n "${out_dir}" ] || out_dir=/
	shown_out_dir=$(printable "${out_dir}")
	[ -d "${out_dir}" ] || die 4 "--out folder ${shown_out_dir} does not exist; expected an existing folder"
	temp_file=$(mktemp "${out_dir}/.${out##*/}.XXXXXX") ||
		die 4 "mktemp could not create a temp file beside ${shown_out}; expected a writable folder"
	printf '%s\n' "${input}" >"${temp_file}" || die 4 "could not write the temp file beside ${shown_out}"
	mv -f "${temp_file}" "${out}" || die 4 "mv could not move the temp file onto ${shown_out}"
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
load_dependencies
read_effort
read_seat
find_dispatch_file
read_iteration
check_report
build_input
write_input
