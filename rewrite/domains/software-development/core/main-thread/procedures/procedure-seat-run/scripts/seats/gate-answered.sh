#!/usr/bin/env sh
# Prints whether the gate after a seat's newest result is answered, and the
# answer. An answer is a gate.<label>.answered event, recorded after that
# result, whose view (the gate's plan file) names the seat; one from before
# the result never answers the gate after it. It reads only.
set -eu

readonly PROG='gate-answered.sh'
readonly EVENTS='crucible/scripts/events.sh'
# A gate label as the crucible skill's space rules allow it.
readonly LABEL_MAX_CHARS=60
# The C locale keeps the shell byte-wise; jq reads the events as UTF-8.
LC_ALL=C
export LC_ALL

# The three lines from the slurped result and answer events: the seat's
# newest result, whether an answer after it names the seat in its view, and
# the newest such answer.
# Prints nothing when the seat has no result.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly ANSWERED_JQ='
def event_path: "\($effort)/events/\(("00000" + (.seq | tostring))[-6:])-\(.type).json";
def one_line: gsub("[[:cntrl:]  ]+"; " ");
add | sort_by(.seq)
| (map(select(.type != $answer_type and .seat == $seat)) | last) as $result
| select($result != null)
| (map(select(.type == $answer_type and .seq > $result.seq and (.body.view | objects | .seat == $seat))) | last) as $answer
| "RESULT: \($result | event_path)",
  "ANSWERED: \(if $answer != null then "yes" else "no" end)",
  "ANSWER: \($answer.body.answer // null | if type == "string" and . != "" then one_line else "none" end)"
'

usage() {
	cat <<EOF
usage: sh ${PROG} --effort FOLDER --seat S --label L
       sh ${PROG} --help | -h

Prints whether the gate labelled L after seat S's newest result is
answered, and the answer; reads only.

--effort FOLDER  the effort folder, absolute
--seat S         a seat, like build-agent-alpha or test-agent-alpha
--label L        the gate's label, like build-next or test-next

stdout, three lines:
  RESULT: <path>     the seat's newest result event (build.committed,
                     test-plan.made or test.committed), absolute
  ANSWERED: yes | no
                     yes when a gate.L.answered event after that result
                     holds seat S in its view (the gate's plan file)
  ANSWER: <label> | none
                     the newest such answer: the option label it
                     recorded, or the human's typed text, on one line;
                     none while unanswered

exit codes:
  0  printed
  2  wrong command line: a missing, repeated or unknown option, a missing
     value, or L not lowercase a-z, 0-9 and -, 1 to ${LABEL_MAX_CHARS} characters
  3  input: S is no seat name, events.sh refused the effort, or the seat
     has no result event; one stderr line
  4  environment: jq, events.sh, seats.jq or seats-events.jq missing or
     failed (nothing printed)

needs: POSIX sh, jq 1.6+; seats-events.jq and seats.jq beside this
script; in \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/skills: the crucible
skill's events.sh
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
	effort_folder='' seat='' label=''
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
			--label)
				take_value "$1" "${label}" "${2-}" L
				label=${option_value}
				;;
			*)
				shown_option=$(printable "$1")
				usage_error "unknown option: ${shown_option}; expected --effort, --seat, --label or --help"
				;;
		esac
		shift 2
	done
	[ -n "${effort_folder}" ] || usage_error '--effort missing; expected --effort FOLDER'
	while [ "${effort_folder}" != "${effort_folder%/}" ]; do effort_folder=${effort_folder%/}; done
	[ -n "${seat}" ] || usage_error '--seat missing; expected --seat S'
	[ -n "${label}" ] || usage_error '--label missing; expected --label L'
	check_label
}

# Refuses a label events.sh would not take in a type, so it is safe in a
# --type pattern.
check_label() {
	case ${label} in
		*[!abcdefghijklmnopqrstuvwxyz0123456789-]*) label_problem='it holds a character outside a-z, 0-9 and -' ;;
		*)
			[ "${#label}" -gt "${LABEL_MAX_CHARS}" ] || return 0
			label_problem="it is ${#label} characters, over ${LABEL_MAX_CHARS}"
			;;
	esac
	usage_error "bad --label: ${label_problem}; expected lowercase a-z, 0-9 and -, 1 to ${LABEL_MAX_CHARS} characters"
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
	events_script="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/skills/${EVENTS}"
	[ -f "${events_script}" ] || die 4 "events.sh not found; expected the ${EVENTS%%/*} skill installed"
	[ -f "${own_dir}/seats.jq" ] && [ -f "${own_dir}/seats-events.jq" ] ||
		die 4 "seats.jq or seats-events.jq not found; expected them beside ${PROG}"
}

# Refuses a seat that is no seat name by seats.jq, so it is safe in a jq
# argument; sets result_types to the seat result types, one per line.
check_seat_name() {
	seat_check=$(jq -nr -L "${own_dir}" --arg name "${seat}" 'include "seats"; include "seats-events";
		($name | seats_name_problem | "problem \(.)") // seats_result_types[]' </dev/null) ||
		die 4 'jq failed checking the seat name; expected jq 1.6+, seats.jq and seats-events.jq'
	case ${seat_check} in
		problem\ *)
			shown_problem=$(printable "${seat_check#problem }")
			die 3 "--seat ${shown_problem}"
			;;
		*) result_types=${seat_check} ;;
	esac
}

# Appends events.sh slurp's array of type $1 to slurped_events; its refusal
# of the effort is an input problem, any other failure the environment's.
slurp() {
	slurp_rc=0
	type_events=$(sh "${events_script}" slurp --effort "${effort_folder}" --type "$1" </dev/null) || slurp_rc=$?
	case ${slurp_rc} in
		0) ;;
		2 | 3) die 3 "events.sh refused --effort (exit ${slurp_rc}, its stderr is above); expected an effort folder" ;;
		*) die 4 "events.sh slurp failed (exit ${slurp_rc}, its stderr is above)" ;;
	esac
	slurped_events="${slurped_events}${type_events}
"
}

# Sets lines to the three output lines, refusing a seat with no result.
read_answered() {
	answer_type="gate.${label}.answered"
	slurped_events=''
	while IFS= read -r result_type; do
		slurp "${result_type}"
	done <<EOF
${result_types}
EOF
	slurp "${answer_type}"
	lines=$(printf '%s' "${slurped_events}" | jq -rs --arg seat "${seat}" --arg effort "${effort_folder}" \
		--arg answer_type "${answer_type}" "${ANSWERED_JQ}") ||
		die 4 'jq could not read the events events.sh slurp printed'
	[ -n "${lines}" ] || die 3 "seat ${seat} has no result event; expected a build.committed, test-plan.made or test.committed"
}

parse_args "$@"
load_dependencies
check_seat_name
read_answered
printf '%s\n' "${lines}"
