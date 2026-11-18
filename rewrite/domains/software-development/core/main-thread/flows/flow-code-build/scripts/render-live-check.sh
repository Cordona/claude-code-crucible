#!/usr/bin/env sh
# Renders the live check's gate once main has shown the human the build
# working, so the main thread never hand-formats it, or with --question the
# gate's question: confirmed, or not as asked. The seat's title is the one
# its build card shows. views/live-check.jq lays the gate out and
# human-view's show.sh renders it. Pipe its stdout into
# procedure-approval-gate's open-gate.sh, which shows the gate.
# shellcheck source-path=SCRIPTDIR source-path=SCRIPTDIR/lib
set -eu
umask 077

readonly PROG='render-live-check.sh'
readonly VIEW_LIB='human-view'
readonly RENDER_LIB='scripts/lib/render.sh'
readonly VIEW_NAME='live-check'
readonly SEATS_LIB='procedure-seat-run/scripts/seats'
readonly TITLE_LIB='lib/seat-title.sh'
readonly ROLE_WORD='build agent'
# The action is one line the human reads at a glance.
readonly MAX_ACTION_CHARS=200
# The shell's pattern checks stay byte-wise on macOS and Linux; jq reads the
# plan file and the events as UTF-8 whatever the locale.
LC_ALL=C
export LC_ALL

# Prints one line per problem of the slurped plan file; nothing when it is one
# object holding a build seat name and the action main ran.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly PLAN_CHECK_JQ='
include "seats";
def expected_plan: "expected one JSON object {\"seat\": SEAT, \"action\": TEXT}";
def string_problem($name; $what):
	if has($name) | not then "\($name) missing; expected \($what)"
	elif (.[$name] | type) != "string" then "\($name) is a JSON \(.[$name] | type); expected \($what)"
	elif .[$name] | test("^[[:space:]]*$") then "\($name) is empty; expected \($what)"
	elif .[$name] | test("[[:cntrl:]\u2028\u2029]") then "\($name) holds a control character or a line or paragraph separator; expected one line"
	else empty end;
def seat_problem:
	string_problem("seat"; "the build seat") //
	(.seat | seats_name_problem | "seat \(.)") //
	(if .seat | startswith("\(seats_prefixes.builder)-") then empty
	 else "seat \(.seat | tojson) is no build seat; expected \(seats_prefixes.builder)-<letter>" end);
def action_problem:
	string_problem("action"; "what main did to show the build working, such as \"Called POST /orders and showed you the status\"") //
	(if (.action | length) > $max_action then "action is \(.action | length) characters; expected at most \($max_action); try a shorter action" else empty end);
if length != 1 then "the plan file holds \(length) JSON values; \(expected_plan)"
elif (.[0] | type) != "object" then "the plan file holds a JSON \(.[0] | type); \(expected_plan)"
else .[0]
	| ((keys - ["seat", "action"])[] | "\(tojson) is an unknown field; expected only seat and action"),
	  seat_problem,
	  action_problem
end
'

# Prints the AskUserQuestion fields of the gate as one JSON object. Input:
# the slurped plan file, checked; $title: the seat's title.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly QUESTION_JQ='
include "title";
def option($label; $description): {label: $label, description: $description};
def recommended: .label += " (Recommended)";
def seat_who($seat): split($role) as $parts | $parts[0] + $role + " " + ($seat | seat_letter) + ($parts[1:] | join($role));
.[0].seat as $seat
| {header: "Live check", question: "Does \($title | seat_who($seat)) do what was asked?",
   options: [
	(option("Confirmed"; "What you saw is what was asked; it goes into the context and the tester plans tests.") | recommended),
	option("Not as asked: say what"; "Type what'\''s wrong; the build agent gets it as a change.")]}
'

# The gate's data for views/live-check.jq: the question, its first letter in
# lower case, the action on one line, and the build seat. Input: the question
# object.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly VIEW_DATA_JQ='{ask: ((.question[:1] | ascii_downcase) + .question[1:]), action: $action, seat: $seat}'

usage() {
	print_page <<EOF
usage: sh ${PROG} --plan-file PATH --effort FOLDER | sh <skills>/procedure-approval-gate/scripts/open-gate.sh --label live-check
       sh ${PROG} --plan-file PATH --effort FOLDER --question
       sh ${PROG} --help | -h

Prints the live check's gate as Markdown naming the action and the build
seat, or with --question its question. stdin is never read; the plan file
and the effort's events only read; no file is written.

Options:
  --plan-file PATH  one JSON object, no other field, written with the Write
                    tool:
                    seat: the build seat, build-agent-<letter>
                    action: one line of at most ${MAX_ACTION_CHARS}
                      characters: what main did and showed the human
  --effort FOLDER   the effort folder, absolute; the seat's title is the
                    one its newest build.committed's card shows
  --question        print the gate's question, not the gate
  CLAUDE_CONFIG_DIR  holds skills/; default \$HOME/.claude
  CRUCIBLE_HOME     the space (default \$HOME/.crucible)

stdout on exit 0 only:
  a gate: its Markdown, no gate marker
  --question: one JSON object {"header": "Live check", "question": str,
    "options": [{"label": str, "description": str}, ...]}:
    Confirmed (Recommended) / Not as asked: say what
stderr on exits 2 and 3: one "${PROG}: <what>; expected <x>[; try <y>]"
  line per problem; a plan field is named seat or action
stderr on exit 5: "${PROG}: install:", a prefix no other exit
  prints; do not rerun; stop

Exit codes:
  0  printed; pipe a gate into open-gate.sh, copy a question into one
     AskUserQuestion
  2  usage error; fix the call and rerun once, else show the human stderr
  3  invalid plan file, the effort refused, or the seat with no
     build.committed; fix what stderr names and rerun once, else show the
     human stderr
  4  stdout closed; stop and show the exit code
  5  an install fault
  129, 130, 143  stopped by HUP, INT or TERM

Dependencies: POSIX sh, jq 1.6+, awk; ${TITLE_LIB} beside this script;
  ${VIEW_LIB}'s title.jq; a gate: its scripts/show.sh and ${RENDER_LIB}
  and views/${VIEW_NAME}.jq; procedure-seat-run's scripts/seats/seats.jq;
  the crucible skill's events.sh.
EOF
}

# Prints stdin with builtins only, so the help page prints with cat missing.
print_page() {
	while IFS= read -r page_line; do
		printf '%s\n' "${page_line}"
	done
}

warn() {
	printf '%s: %s\n' "${PROG}" "$1" >&2
}

# Prints an install or host fault (a missing or failing tool, never a problem
# of the input) with the "install:" prefix and exits 5.
install_fault() {
	warn "install: $1"
	exit 5
}

usage_error() {
	warn "$1"
	printf "Try '%s --help'.\n" "${PROG}" >&2
	exit 2
}

# Prints problem lines $1, when any, to stderr and exits 3.
refuse_problems() {
	[ -n "$1" ] || return 0
	printf '%s\n' "$1" | while IFS= read -r problem; do warn "${problem}"; done
	exit 3
}

# Sets mode (gate or question), plan_file and effort_folder from the
# arguments.
parse_args() {
	plan_file='' effort_folder='' mode=gate
	while [ "$#" -gt 0 ]; do
		case $1 in
			--help | -h)
				usage
				exit 0
				;;
			--question)
				mode=question
				shift
				;;
			--plan-file)
				[ "$#" -ge 2 ] && [ -n "$2" ] || usage_error '--plan-file needs a value; expected --plan-file PATH'
				plan_file=$2
				shift 2
				;;
			--effort)
				[ "$#" -ge 2 ] && [ -n "$2" ] || usage_error '--effort needs a value; expected --effort FOLDER'
				effort_folder=$2
				shift 2
				;;
			*) usage_error 'unknown argument; expected --plan-file PATH, --effort FOLDER, --question or --help' ;;
		esac
	done
	[ -n "${plan_file}" ] || usage_error '--plan-file PATH missing; expected --plan-file PATH naming the JSON file; stdin is not read'
	[ -n "${effort_folder}" ] || usage_error '--effort FOLDER missing; expected the effort folder the seat belongs to'
}

# Prints the folder this script was run from (".", when run by a bare name).
script_dir() {
	case $0 in
		*/*) printf '%s' "${0%/*}" ;;
		*) printf '.' ;;
	esac
}

# Exits 5 unless file $1 is readable, naming skill $2 to install.
require_skill_file() {
	[ -f "$1" ] && [ -r "$1" ] || install_fault "$3 missing; expected $1; install the $2 skill"
}

# Exits 5 unless jq, the seat and title rules and, for a gate, human-view's
# lib/render.sh, the template and show.sh are in place; sets views_dir and
# show_script.
load_dependencies() {
	command -v jq >/dev/null 2>&1 ||
		install_fault 'jq missing; expected jq 1.6+ on PATH; try installing jq (macOS: brew install jq; Linux: the distro'\''s jq package)'
	skills_dir="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/skills"
	views_dir="$(script_dir)/../views"
	seats_dir="${skills_dir}/${SEATS_LIB}"
	title_dir="${skills_dir}/${VIEW_LIB}"
	require_skill_file "${seats_dir}/seats.jq" procedure-seat-run 'seat name rules'
	require_skill_file "${title_dir}/title.jq" "${VIEW_LIB}" 'title rules'
	title_lib="$(script_dir)/${TITLE_LIB}"
	[ -f "${title_lib}" ] && [ -r "${title_lib}" ] ||
		install_fault "seat title rules missing; expected ${title_lib}; reinstall the flow-code-build skill"
	st_skills_dir=${skills_dir}
	# shellcheck source=lib/seat-title.sh
	. "${title_lib}"
	[ "${mode}" = gate ] || return 0
	render_lib="${title_dir}/${RENDER_LIB}"
	require_skill_file "${render_lib}" "${VIEW_LIB}" 'gate printer'
	# shellcheck source=../../../../../../../framework/core/engine/human-view/scripts/lib/render.sh
	. "${render_lib}"
	# shellcheck disable=SC2310 # its status is the answer; set -e is not relied on inside
	hv_check_printer "${title_dir}/scripts" "${views_dir}" "${VIEW_NAME}" || install_fault "${hv_printer_problem}"
	show_script=${hv_show}
}

# Sets slurped to the plan file read into one array, and seat and action from
# it, or exits 3 naming each problem of it.
load_plan() {
	[ -f "${plan_file}" ] && [ -r "${plan_file}" ] ||
		refuse_problems "plan file not readable: ${plan_file}; expected a readable JSON file"
	slurped=$(jq -s '.' "${plan_file}" </dev/null 2>/dev/null) ||
		refuse_problems 'the plan file is not valid JSON; expected one JSON object; try checking its quotes, commas and brackets, then rerun'
	problems=$(printf '%s' "${slurped}" | jq -r -L "${seats_dir}" \
		--argjson max_action "${MAX_ACTION_CHARS}" "${PLAN_CHECK_JQ}") ||
		install_fault 'jq failed on valid JSON; expected jq 1.6+; try jq --version, then rerun'
	refuse_problems "${problems}"
	seat=$(printf '%s' "${slurped}" | jq -r '.[0].seat') ||
		install_fault 'jq failed on valid JSON; expected jq 1.6+; try jq --version, then rerun'
}

# Prints $1 to stdout; exits 4 when stdout is closed. Ignoring SIGPIPE turns a
# closed reader into a failed write this script can tell apart from a jq
# fault, rather than a silent kill.
print_output() {
	trap '' PIPE
	printf '%s\n' "$1" 2>/dev/null || exit 4
}

# Renders the gate through views/VIEW_NAME.jq to stdout; a show.sh fault is
# an install fault.
render_gate() {
	action=$(printf '%s' "${slurped}" | jq -r '.[0].action | sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; "")') ||
		install_fault 'jq failed on valid JSON; expected jq 1.6+; try jq --version, then rerun'
	view_data=$(printf '%s' "${question}" | jq -c --arg action "${action}" --arg seat "${seat}" "${VIEW_DATA_JQ}") ||
		install_fault 'jq failed on valid JSON; expected jq 1.6+; try jq --version, then rerun'
	# shellcheck disable=SC2310 # its status names the fault; set -e is not relied on inside
	hv_render_gate "${show_script}" "${views_dir}" "${VIEW_NAME}" "${view_data}" ||
		install_fault "${hv_render_problem}; expected the gate rendered from views/${VIEW_NAME}.jq; try reinstalling flow-code-build and ${VIEW_LIB}"
}

trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
parse_args "$@"
load_dependencies
load_plan
st_derive_title "${effort_folder}" "${seat}" "${ROLE_WORD}"
question=$(printf '%s' "${slurped}" | jq -c -L "${title_dir}" --arg role "${ROLE_WORD}" --arg title "${st_title}" "${QUESTION_JQ}") ||
	install_fault 'jq failed on valid JSON; expected jq 1.6+; try jq --version, then rerun'
if [ "${mode}" = question ]; then
	print_output "${question}"
else
	render_gate
fi
