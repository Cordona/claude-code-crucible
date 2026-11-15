#!/usr/bin/env sh
# Prints the commit-message.sh input for one developer seat's current work: the
# kind from the seat's mode, the iteration from iteration.sh, the text from
# the seat's report, and the trailers. It reads only; commit-message.sh
# checks what it prints.
set -eu
umask 077

readonly PROG='commit-input.sh'
# The C locale keeps the shell byte-wise; jq writes the JSON as UTF-8.
LC_ALL=C
export LC_ALL

# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly INPUT_JQ='{kind: $kind, text: $report[0].summary,
	trailers: {iteration: $count, effort: $effort, "agent-seat": $seat.seat}}'

usage() {
	cat <<EOF
usage: sh ${PROG} --effort FOLDER --seat S [--report FILE] [--out FILE]
       sh ${PROG} --help | -h

Prints the commit-message.sh input JSON for seat S's current work. Reads
only; checks no value commit-message.sh checks.

--effort FOLDER  the effort folder, absolute
--seat S       a developer seat with an agent bound
--report FILE  the report to take the text from; default iteration.sh's REPORT
--out FILE     write the JSON there, whole through a temp file beside it,
               instead of printing it

the input:
  kind      build for mode BUILD
  text      the summary of the report, one JSON object
  trailers  iteration: iteration.sh's ITERATION; effort: the effort
            folder's name; agent-seat

exit codes:
  0  printed (or written); with --out nothing is printed
  2  wrong command line: a missing, repeated or unknown option, or a
     missing value
  3  input: the effort, the seat or the report does not fit; one stderr
     line per problem (seats.sh's or
     iteration.sh's own lines first when it refused)
  4  environment: jq, seats.sh or iteration.sh missing or failed, or --out
     could not be written

needs: POSIX sh, jq 1.6+; procedure-seat-run's seats/seats.sh and
seats/iteration.sh (git 2.26+) beside procedure-git-worktree
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
	effort_folder='' seat='' out='' report=''
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
			--report)
				take_value "$1" "${report}" "${2-}" FILE
				report=${option_value}
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
				usage_error "unknown option: ${shown_option}; expected --effort, --seat, --report, --out or --help"
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
	for neighbour in ../../../procedure-seat-run/scripts/seats/seats.sh ../../../procedure-seat-run/scripts/seats/iteration.sh; do
		[ -f "${own_dir}/${neighbour}" ] || {
			shown_neighbour=$(printable "${own_dir}/${neighbour}")
			die 4 "${shown_neighbour} not found; expected procedure-seat-run installed beside procedure-git-worktree"
		}
	done
}

# Sets effort, the effort folder's name.
read_effort() {
	while [ "${effort_folder}" != "${effort_folder%/}" ]; do effort_folder=${effort_folder%/}; done
	effort=${effort_folder##*/}
	[ -n "${effort}" ] || die 3 '--effort names no folder; expected the effort folder'
}

# Sets seat_json, kind, dispatch and worktree from seats.sh get;
# seats.sh's own lines say why it refused.
read_seat() {
	seat_rc=0
	seat_json=$(sh "${own_dir}/../../../procedure-seat-run/scripts/seats/seats.sh" get --effort "${effort_folder}" --seat "${seat}") || seat_rc=$?
	case ${seat_rc} in
		0) ;;
		2 | 3 | 6)
			shown_seat=$(printable "${seat}")
			die 3 "seats.sh get refused seat ${shown_seat} (exit ${seat_rc}); expected a seat of --effort"
			;;
		*) die 4 "seats.sh get failed (exit ${seat_rc})" ;;
	esac
	fields=$(printf '%s\n' "${seat_json}" | jq -r '.mode // "", .status // "", .dispatch // "", .worktree // ""') ||
		die 4 'jq could not read the seat seats.sh get printed'
	mode='' status='' dispatch='' worktree=''
	{
		IFS= read -r mode || :
		IFS= read -r status || :
		IFS= read -r dispatch || :
		IFS= read -r worktree || :
	} <<EOF
${fields}
EOF
	case ${mode} in
		BUILD) kind='build' ;;
		*) die 3 "seat ${seat} has no mode; expected a developer seat" ;;
	esac
	[ -n "${dispatch}" ] || die 3 "seat ${seat} is ${status}; expected an agent and its dispatch bound"
	[ -n "${worktree}" ] || die 3 "seat ${seat} has no worktree; expected a developer seat"
}

# Sets count and, without --report, report from iteration.sh;
# iteration.sh's own lines say why it refused.
read_iteration() {
	iteration_rc=0
	iteration_out=$(sh "${own_dir}/../../../procedure-seat-run/scripts/seats/iteration.sh" --effort "${effort_folder}" --seat "${seat}") || iteration_rc=$?
	case ${iteration_rc} in
		0) ;;
		3) die 3 "iteration.sh refused seat ${seat} (exit 3); expected a seat with a worktree and its base" ;;
		*) die 4 "iteration.sh failed (exit ${iteration_rc})" ;;
	esac
	count='' printed_report=''
	while IFS= read -r line; do
		case ${line} in
			'ITERATION: '*) count=${line#ITERATION: } ;;
			'REPORT: '*) printed_report=${line#REPORT: } ;;
			*) ;;
		esac
	done <<EOF
${iteration_out}
EOF
	[ -n "${count}" ] && [ -n "${printed_report}" ] || die 4 'iteration.sh printed no ITERATION or REPORT line'
	[ -n "${report}" ] || report=${printed_report}
}

check_report() {
	shown_report=$(printable "${report}")
	[ -f "${report}" ] && [ -r "${report}" ] || die 3 "the report ${shown_report} is not a readable file; expected the agent's report for this iteration"
	jq -e 'type == "object"' "${report}" >/dev/null 2>&1 ||
		die 3 "the report ${shown_report} is not one JSON object; expected the agent's report"
}

build_input() {
	input=$(jq -nc --slurpfile report "${report}" --argjson seat "${seat_json}" --arg kind "${kind}" \
		--argjson count "${count}" --arg effort "${effort}" "${INPUT_JQ}" 2>/dev/null) ||
		die 4 'jq failed building the commit input; expected jq 1.6+'
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
read_iteration
check_report
build_input
write_input
