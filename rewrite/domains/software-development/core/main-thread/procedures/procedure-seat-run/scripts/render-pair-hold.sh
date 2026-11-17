#!/usr/bin/env sh
# Renders the pair hold's gate, so the main thread never hand-formats it, or
# with --question the gate's question: resume the agent that left its work
# uncommitted in the shared worktree, or discard that work. One agent works
# in a worktree at a time, so the held seat waits on the answer.
# views/pair-hold.jq lays the gate out and human-view's show.sh renders it.
# Pipe its stdout into procedure-approval-gate's open-gate.sh, which shows
# the gate.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077

readonly PROG='render-pair-hold.sh'
readonly VIEW_LIB='human-view'
readonly RENDER_LIB='scripts/lib/render.sh'
readonly VIEW_NAME='pair-hold'
readonly SEATS_LIB='procedure-seat-run/scripts/seats'
# The shell's pattern checks stay byte-wise on macOS and Linux; jq reads the
# plan file as UTF-8 whatever the locale.
LC_ALL=C
export LC_ALL

# Prints one line per problem of the slurped plan file; nothing when it is one
# object holding two seat names of one pair, a build seat and the tester of
# its letter, and the worktree's absolute path.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly PLAN_CHECK_JQ='
include "seats";
def expected_plan: "expected one JSON object {\"seat\": SEAT, \"pair\": SEAT, \"worktree\": PATH}";
def string_problem($name; $what):
	if has($name) | not then "\($name) missing; expected \($what)"
	elif (.[$name] | type) != "string" then "\($name) is a JSON \(.[$name] | type); expected \($what)"
	elif .[$name] | test("^[[:space:]]*$") then "\($name) is empty; expected \($what)"
	elif .[$name] | test("[[:cntrl:]\u2028\u2029]") then "\($name) holds a control character or a line or paragraph separator; expected one line"
	else empty end;
def role_of: . as $name | [seats_prefixes | to_entries[] | select(.value as $prefix | $name | startswith($prefix + "-")) | .key] | .[0];
def letter_of: . as $name | seats_prefixes[$name | role_of] as $prefix | $name | ltrimstr("\($prefix)-");
def seat_problem($name; $what):
	string_problem($name; $what) //
	(.[$name] | seats_name_problem | "\($name) \(.)") //
	(if .[$name] | role_of then empty
	 else "\($name) \(.[$name] | tojson) is no build or tester seat; expected \(seats_prefixes.builder)-<letter> or \(seats_prefixes.tester)-<letter>" end);
def pair_problem:
	if (.seat | role_of) == (.pair | role_of) then "pair \(.pair | tojson) has the role of seat \(.seat | tojson); expected the other seat of its pair, a build seat and the tester of its letter"
	elif (.seat | letter_of) != (.pair | letter_of) then "pair \(.pair | tojson) does not end in the letter of seat \(.seat | tojson); expected the other seat of its pair"
	else empty end;
def worktree_problem:
	string_problem("worktree"; "the shared worktree'\''s absolute path, as seats.sh get prints it") //
	(if .worktree | startswith("/") then empty else "worktree is not absolute: \(.worktree | tojson); expected the path seats.sh get prints" end);
if length != 1 then "the plan file holds \(length) JSON values; \(expected_plan)"
elif (.[0] | type) != "object" then "the plan file holds a JSON \(.[0] | type); \(expected_plan)"
else .[0]
	| ((keys - ["seat", "pair", "worktree"])[] | "\(tojson) is an unknown field; expected only seat, pair and worktree"),
	  ([seat_problem("seat"; "the held seat"), seat_problem("pair"; "the seat whose agent left its work")] as $seats
	   | if $seats == [] then pair_problem else $seats[] end),
	  worktree_problem
end
'

# Prints the AskUserQuestion fields of the gate as one JSON object. Input:
# the slurped plan file, checked.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly QUESTION_JQ='
include "title";
def option($label; $description): {label: $label, description: $description};
def recommended: .label += " (Recommended)";
.[0]
| {header: "Pair hold", question: "Resume \(.pair | seat_display), or discard its changes?",
   options: [
	(option("Resume the agent"; "The agent that left the work continues it.") | recommended),
	option("Discard (I cleaned the worktree)"; "You removed its changes; its seat is marked idle and the other agent'\''s work goes ahead.")]}
'

# The gate's data for views/pair-hold.jq: the question, its first letter in
# lower case, and the shared worktree. Input: the question object.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly VIEW_DATA_JQ='{ask: ((.question[:1] | ascii_downcase) + .question[1:]), worktree: $worktree}'

usage() {
	print_page <<EOF
usage: sh ${PROG} --plan-file PATH | sh <skills>/procedure-approval-gate/scripts/open-gate.sh --label pair-hold --effort FOLDER
       sh ${PROG} --plan-file PATH --question
       sh ${PROG} --help | -h

Prints the pair hold's gate as Markdown naming the shared worktree, or
with --question its question. stdin is never read; the plan file only
read; no file is written.

Options:
  --plan-file PATH  one JSON object, no other field, written with the Write
                    tool:
                    seat: the held seat, whose work waits
                    pair: the other seat of its pair, whose agent left
                      its work uncommitted: a build seat and the tester of
                      its letter, either way round
                    worktree: the shared worktree, absolute, as seats.sh
                      get prints it
  --question        print the gate's question, not the gate
  CLAUDE_CONFIG_DIR  holds skills/; default \$HOME/.claude

stdout on exit 0 only:
  a gate: its Markdown, no gate marker
  --question: one JSON object {"header": "Pair hold", "question": str,
    "options": [{"label": str, "description": str}, ...]}:
    Resume the agent (Recommended) / Discard (I cleaned the worktree)
stderr on exits 2 and 3: one "${PROG}: <what>; expected <x>[; try <y>]"
  line per problem; a plan field is named seat, pair or worktree
stderr on exit 5: "${PROG}: install:", a prefix no other exit
  prints; do not rerun; stop

Exit codes:
  0  printed; pipe a gate into open-gate.sh, copy a question into one
     AskUserQuestion
  2  usage error; fix the call and rerun once, else show the human stderr
  3  invalid plan file; fix what stderr names and rerun once, else show
     the human stderr
  4  stdout closed; stop and show the exit code
  5  an install fault
  129, 130, 143  stopped by HUP, INT or TERM

Dependencies: POSIX sh, jq 1.6+; ${VIEW_LIB}'s title.jq; a gate: its
  scripts/show.sh and ${RENDER_LIB} and views/${VIEW_NAME}.jq; this
  skill's scripts/seats/seats.jq.
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

# Sets mode (gate or question) and plan_file from the arguments.
parse_args() {
	plan_file='' mode=gate
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
			*) usage_error 'unknown argument; expected --plan-file PATH, --question or --help' ;;
		esac
	done
	[ -n "${plan_file}" ] || usage_error '--plan-file PATH missing; expected --plan-file PATH naming the JSON file; stdin is not read'
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
	[ "${mode}" = gate ] || return 0
	render_lib="${title_dir}/${RENDER_LIB}"
	require_skill_file "${render_lib}" "${VIEW_LIB}" 'gate printer'
	# shellcheck source=../../../../../../../framework/core/engine/human-view/scripts/lib/render.sh
	. "${render_lib}"
	# shellcheck disable=SC2310 # its status is the answer; set -e is not relied on inside
	hv_check_printer "${title_dir}/scripts" "${views_dir}" "${VIEW_NAME}" || install_fault "${hv_printer_problem}"
	show_script=${hv_show}
}

# Sets slurped to the plan file read into one array, or exits 3 naming each
# problem of it.
load_plan() {
	[ -f "${plan_file}" ] && [ -r "${plan_file}" ] ||
		refuse_problems "plan file not readable: ${plan_file}; expected a readable JSON file"
	slurped=$(jq -s '.' "${plan_file}" </dev/null 2>/dev/null) ||
		refuse_problems 'the plan file is not valid JSON; expected one JSON object; try checking its quotes, commas and brackets, then rerun'
	problems=$(printf '%s' "${slurped}" | jq -r -L "${seats_dir}" "${PLAN_CHECK_JQ}") ||
		install_fault 'jq failed on valid JSON; expected jq 1.6+; try jq --version, then rerun'
	refuse_problems "${problems}"
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
	worktree=$(printf '%s' "${slurped}" | jq -r '.[0].worktree') ||
		install_fault 'jq failed on valid JSON; expected jq 1.6+; try jq --version, then rerun'
	view_data=$(printf '%s' "${question}" | jq -c --arg worktree "${worktree}" "${VIEW_DATA_JQ}") ||
		install_fault 'jq failed on valid JSON; expected jq 1.6+; try jq --version, then rerun'
	# shellcheck disable=SC2310 # its status names the fault; set -e is not relied on inside
	hv_render_gate "${show_script}" "${views_dir}" "${VIEW_NAME}" "${view_data}" ||
		install_fault "${hv_render_problem}; expected the gate rendered from views/${VIEW_NAME}.jq; try reinstalling procedure-seat-run and ${VIEW_LIB}"
}

trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
parse_args "$@"
load_dependencies
load_plan
question=$(printf '%s' "${slurped}" | jq -c -L "${title_dir}" "${QUESTION_JQ}") ||
	install_fault 'jq failed on valid JSON; expected jq 1.6+; try jq --version, then rerun'
if [ "${mode}" = question ]; then
	print_output "${question}"
else
	render_gate
fi
