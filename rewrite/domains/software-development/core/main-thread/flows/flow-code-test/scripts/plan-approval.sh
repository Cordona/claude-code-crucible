#!/usr/bin/env sh
# Prints whether a tester seat's newest test plan draft is approved: the
# newest answer to its plan gate, recorded after the draft, whose gate plan
# (the answer's view: the plan file render-plan-gate.sh read) names that
# draft's event. An answer about an older draft never approves a newer one,
# and only an Approve option's label approves: a typed answer never does.
# It reads only.
set -eu

readonly PROG='plan-approval.sh'
readonly PLAN_TYPE='test-plan.made'
readonly ANSWER_TYPE='gate.test-plan.answered'
readonly EVENTS='crucible/scripts/events.sh'
readonly SEATS_LIB='procedure-seat-run/scripts/seats'
# The C locale keeps the shell byte-wise; jq reads the events as UTF-8.
LC_ALL=C
export LC_ALL

# The four lines from the slurped plan and answer events: the seat's newest
# plan, the newest answer after it whose view, the gate's plan file, names
# that seat and that plan's path, whether that answer approved it, and the
# plan's seq.
# Prints nothing when the seat has no plan.
# approve_option: the Approve option labels render-plan-gate.sh builds, as
# the dialog records a click on one; "Approve" is always the recommended one.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly APPROVAL_JQ='
def event_path: "\($effort)/events/\(("00000" + (.seq | tostring))[-6:])-\(.type).json";
def one_line: gsub("[[:cntrl:]  ]+"; " ");
def approve_option: type == "string"
	and test("^Approve( [(]Recommended[)]|, (and test (it|them)|leave (it|them) untested)( [(]Recommended[)])?)$");
add | sort_by(.seq)
| (map(select(.type == $plan_type and .seat == $seat)) | last) as $plan
| select($plan != null)
| ($plan | event_path) as $path
| (map(select(.type == $answer_type and .seq > $plan.seq
	and (.body.view | objects | .seat == $seat and .event == $path))) | last) as $answer
| "PLAN: \($path)",
  "ANSWER: \($answer.body.answer // null | if type == "string" and . != "" then one_line else "none" end)",
  "APPROVED: \(if $answer.body.answer // null | approve_option then "yes" else "no" end)",
  "SEQ: \($plan.seq)"
'

usage() {
	cat <<EOF
usage: sh ${PROG} --effort FOLDER --seat S
       sh ${PROG} --help | -h

Prints whether tester seat S's newest test plan draft is approved; reads
only.

--effort FOLDER  the effort folder, absolute
--seat S         a tester seat, test-agent-<letter>

stdout, four lines:
  PLAN: <path>       the seat's newest ${PLAN_TYPE} event, absolute
  ANSWER: <text> | none
                     the newest ${ANSWER_TYPE} after that event whose
                     view (the gate's plan file) holds seat S and event
                     <path>: the human's answer, on one line; none while
                     that draft's gate is unanswered
  APPROVED: yes | no
                     yes when that answer is exactly the label of one
                     of the plan gate's Approve options, as
                     render-plan-gate.sh --question builds them; no for
                     any other answer, typed text included
  SEQ: <n>           the seq of the PLAN: event, the approved plan's when
                     APPROVED: yes

exit codes:
  0  printed
  2  wrong command line: a missing, repeated or unknown option, or a
     missing value
  3  input: S is no tester seat name, events.sh refused the effort, or the
     seat has no ${PLAN_TYPE} event; one stderr line
  4  environment: jq, events.sh or seats.jq missing or failed (nothing
     printed)

needs: POSIX sh, jq 1.6+; in \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/skills:
the crucible skill's events.sh and procedure-seat-run's
scripts/seats/seats.jq
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

load_dependencies() {
	command -v jq >/dev/null 2>&1 || die 4 'jq not found; expected jq 1.6+ on PATH'
	skills_dir="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/skills"
	events_script="${skills_dir}/${EVENTS}"
	seats_dir="${skills_dir}/${SEATS_LIB}"
	[ -f "${events_script}" ] || die 4 "events.sh not found; expected the ${EVENTS%%/*} skill installed"
	[ -f "${seats_dir}/seats.jq" ] || die 4 "seats.jq not found; expected the ${SEATS_LIB%%/*} skill installed"
}

# Refuses a seat that is no tester seat name by seats.jq, so it is safe in
# a path and a jq argument.
check_seat_name() {
	name_problem=$(jq -nr -L "${seats_dir}" --arg name "${seat}" 'include "seats";
		($name | seats_name_problem)
		// (if $name | startswith("\(seats_prefixes.tester)-") then empty
			else "\($name | tojson) is no tester seat; expected \(seats_prefixes.tester)-<letter>" end)' </dev/null) ||
		die 4 "jq failed checking the seat name; expected jq 1.6+ and ${SEATS_LIB}/seats.jq"
	[ -n "${name_problem}" ] || return 0
	shown_problem=$(printable "${name_problem}")
	die 3 "--seat ${shown_problem}"
}

# Sets slurped_events to events.sh slurp's array of type $1; its refusal of
# the effort is an input problem, any other failure the environment's.
slurp() {
	slurp_rc=0
	slurped_events=$(sh "${events_script}" slurp --effort "${effort_folder}" --type "$1" </dev/null) || slurp_rc=$?
	case ${slurp_rc} in
		0) ;;
		2 | 3) die 3 "events.sh refused --effort (exit ${slurp_rc}, its stderr is above); expected an effort folder" ;;
		*) die 4 "events.sh slurp failed (exit ${slurp_rc}, its stderr is above)" ;;
	esac
}

# Sets lines to the four output lines, refusing a seat with no plan.
read_approval() {
	slurp "${PLAN_TYPE}"
	plans=${slurped_events}
	slurp "${ANSWER_TYPE}"
	answers=${slurped_events}
	lines=$(printf '%s\n%s\n' "${plans}" "${answers}" | jq -rs --arg seat "${seat}" --arg effort "${effort_folder}" \
		--arg plan_type "${PLAN_TYPE}" --arg answer_type "${ANSWER_TYPE}" "${APPROVAL_JQ}") ||
		die 4 'jq could not read the events events.sh slurp printed'
	[ -n "${lines}" ] || die 3 "seat ${seat} has no ${PLAN_TYPE} event; expected a plan the stop hook recorded"
}

parse_args "$@"
load_dependencies
check_seat_name
read_approval
printf '%s\n' "${lines}"
