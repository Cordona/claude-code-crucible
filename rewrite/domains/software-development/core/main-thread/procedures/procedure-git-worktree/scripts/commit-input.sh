#!/usr/bin/env sh
# Prints the commit-message.sh input for one writer seat's current work: the
# kind from the seat's mode, the count and the report from iteration.sh, the
# text from that report, the trailers from slots.json, the seat and its
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
	trailers: ({($count_key): $count, effort: $effort, dispatch: $seat.dispatch, "agent-slot": $seat.slot,
		"agent-id": $seat.agent_id, language: $plugins.language.name?,
		frameworks: [$plugins.frameworks[]?.name], standards: [$plugins.standards[]?.name]}
		| with_entries(select(.value != null and .value != [])))}'

usage() {
	cat <<EOF
usage: sh ${PROG} --slots FILE --slot S [--out FILE]
       sh ${PROG} --help | -h

Prints the commit-message.sh input JSON for seat S's current work. Reads
only; checks no value commit-message.sh checks.

--slots FILE   absolute path of the effort's slots.json; its folder is the
               effort folder
--slot S       a developer or tester seat with an agent bound
--out FILE     write the JSON there, whole through a temp file beside it,
               instead of printing it

the input:
  kind      dev for mode BUILD, test for mode TEST
  text      the summary of iteration.sh's REPORT file, one JSON object
  trailers  build-iteration (dev) or test-iteration (test): iteration.sh's
            ITERATION; effort (slots.json's effort), dispatch, agent-slot,
            agent-id (the seat's); language, frameworks (left out when
            none) and standards: the plugin names in the seat's one
            dispatch file, <effort folder>/dispatches/<dispatch>-*-dispatch.json

exit codes:
  0  printed (or written); with --out nothing is printed
  2  wrong command line: a missing, repeated or unknown option, or a
     missing value
  3  input: slots.json, the seat, the report, the dispatch file or the
     worktree does not fit; one stderr line per problem (slots.sh's or
     iteration.sh's own lines first when it refused)
  4  environment: jq, slots.sh or iteration.sh missing or failed, or --out
     could not be written

needs: POSIX sh, jq 1.6+; slots.sh and iteration.sh (git 2.26+) beside
this script
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
	slots_file='' slot='' out=''
	while [ "$#" -gt 0 ]; do
		case $1 in
			-h | --help)
				usage
				exit 0
				;;
			--slots)
				take_value "$1" "${slots_file}" "${2-}" FILE
				slots_file=${option_value}
				;;
			--slot)
				take_value "$1" "${slot}" "${2-}" S
				slot=${option_value}
				;;
			--out)
				take_value "$1" "${out}" "${2-}" FILE
				out=${option_value}
				;;
			*)
				shown_option=$(printable "$1")
				usage_error "unknown option: ${shown_option}; expected --slots, --slot, --out or --help"
				;;
		esac
		shift 2
	done
	[ -n "${slots_file}" ] || usage_error '--slots missing; expected --slots FILE'
	[ -n "${slot}" ] || usage_error '--slot missing; expected --slot S'
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
	for sibling in slots.sh iteration.sh; do
		[ -f "${own_dir}/${sibling}" ] || die 4 "${sibling} not found beside this script; expected it in this folder"
	done
}

# Sets effort_dir and effort from slots.json.
read_effort() {
	shown_slots=$(printable "${slots_file}")
	case ${slots_file} in
		/*) ;;
		*) die 3 "--slots ${shown_slots} is not absolute; expected an absolute path" ;;
	esac
	[ -f "${slots_file}" ] && [ -r "${slots_file}" ] || die 3 "--slots ${shown_slots} is not a readable file; expected the effort's slots.json"
	effort_dir=${slots_file%/*}
	effort=$(jq -r '.effort | strings' "${slots_file}" 2>/dev/null) ||
		die 3 "--slots ${shown_slots} is not JSON; expected the effort's slots.json"
	[ -n "${effort}" ] || die 3 "--slots ${shown_slots} has no effort; expected a non-empty effort string"
}

# Sets seat_json, kind, count_key and dispatch from slots.sh get; slots.sh's
# own lines say why it refused.
read_seat() {
	seat_rc=0
	seat_json=$(sh "${own_dir}/slots.sh" get --slots "${slots_file}" --slot "${slot}") || seat_rc=$?
	case ${seat_rc} in
		0) ;;
		2 | 3 | 6)
			shown_slot=$(printable "${slot}")
			die 3 "slots.sh get refused seat ${shown_slot} (exit ${seat_rc}); expected a seat in --slots"
			;;
		*) die 4 "slots.sh get failed (exit ${seat_rc})" ;;
	esac
	fields=$(printf '%s\n' "${seat_json}" | jq -r '.mode // "", .dispatch // ""') ||
		die 4 'jq could not read the seat slots.sh get printed'
	mode='' dispatch=''
	{
		IFS= read -r mode || :
		IFS= read -r dispatch || :
	} <<EOF
${fields}
EOF
	case ${mode} in
		BUILD) kind=dev count_key=build-iteration ;;
		TEST) kind=test count_key=test-iteration ;;
		*) die 3 "seat ${slot} has no mode; expected a developer or tester seat" ;;
	esac
	[ -n "${dispatch}" ] || die 3 "seat ${slot} is open; expected an agent and its dispatch bound"
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
	iteration_out=$(sh "${own_dir}/iteration.sh" --slots "${slots_file}" --slot "${slot}") || iteration_rc=$?
	case ${iteration_rc} in
		0) ;;
		3) die 3 "iteration.sh refused seat ${slot} (exit 3); expected a seat with a worktree and its base" ;;
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
