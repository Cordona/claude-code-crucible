#!/usr/bin/env sh
# Renders the "what next?" gate after a test report card, so the main thread
# never hand-formats it, or with --question the gate's question, built from
# the report's blocker kinds. The plan file names the seat's newest
# test.committed event; an older report is refused. views/test-next.jq lays
# the gate out and human-view's show.sh renders it. Pipe its stdout into
# procedure-approval-gate's open-gate.sh, which shows the gate.
# shellcheck source-path=SCRIPTDIR source-path=SCRIPTDIR/lib
set -eu
umask 077

readonly PROG='render-test-next.sh'
readonly VIEW_LIB='human-view'
readonly RENDER_LIB='scripts/lib/render.sh'
readonly VIEW_NAME='test-next'
readonly GATE_LIB='lib/seat-event-gate.sh'
# The shell's pattern checks stay byte-wise on macOS and Linux; jq reads the
# plan file and the events as UTF-8 whatever the locale.
LC_ALL=C
export LC_ALL

# Prints the AskUserQuestion fields of the gate as one JSON object. Input:
# {who, body: the test report}. Blockers that are all production bugs go to
# the builder; any other blocker, beside a bug or not, asks for changed tests
# first; no blocker is done.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly QUESTION_JQ='
def option($label; $description): {label: $label, description: $description};
def recommended: .label += " (Recommended)";
(.body.blockers | if type == "array" then . else [] end) as $blockers
| option("Change the tests"; "Type what; it becomes a new test plan, with its own plan card.") as $change
| {header: "Next", question: "What next for \(.who)?",
   options: (if $blockers == [] then
		[(option("Done"; "The tests are committed on the seat. To change them in this plan, type it in Other.") | recommended), $change]
	elif all($blockers[]; type == "object" and .kind == "production_bug") then
		[(option("Send the bug to the builder"; "The builder fixes it in a build round; the red test turns green in its gate, and you get a build card.") | recommended),
		 option("Stop"; "The red test stays committed on the seat.")]
	else [($change | recommended), option("Stop"; "The tests stay committed on the seat as they are.")] end)}
'

# The gate's data for views/test-next.jq: the question, its first letter in
# lower case, and the test.committed event's path. Input: the question object.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly VIEW_DATA_JQ='{ask: ((.question[:1] | ascii_downcase) + .question[1:]), report: $report}'

usage() {
	print_page <<EOF
usage: sh ${PROG} --plan-file PATH | sh <skills>/procedure-approval-gate/scripts/open-gate.sh --label test-next --effort FOLDER
       sh ${PROG} --plan-file PATH --question
       sh ${PROG} --help | -h

Prints the "what next?" gate after a test report card as Markdown naming
its test.committed event, or with --question its question. stdin is never
read; the plan file and the effort's events only read; no file is written.

Options:
  --plan-file PATH  one JSON object, no other field, written with the Write
                    tool:
                    seat: the tester seat, test-agent-<letter>
                    title: optional, its TITLE: line's title, naming the
                      test agent; without it, the title the event's card
                      shows
                    event: the seat's newest test.committed, as
                      iteration.sh's LAST_REPORT: printed it: absolute,
                      <effort>/events/<seq>-test.committed.json, no folder
                      of it a symbolic link
  --question        print the gate's question, not the gate
  CLAUDE_CONFIG_DIR  holds skills/; default \$HOME/.claude
  CRUCIBLE_HOME     the space (default \$HOME/.crucible)

stdout on exit 0 only:
  a gate: its Markdown, no gate marker
  --question: one JSON object {"header": "Next", "question": str,
    "options": [{"label": str, "description": str}, ...]}, the first
    option marked (Recommended), from the report's blockers[].kind:
    none: Done / Change the tests
    production_bug only: Send the bug to the builder / Stop
    any other, a bug beside it or not: Change the tests / Stop
stderr on exits 2 and 3: one "${PROG}: <what>; expected <x>[; try <y>]"
  line per problem; a plan field is named seat, title or event
stderr on exit 5: "${PROG}: install:", a prefix no other exit
  prints; do not rerun; stop

Exit codes:
  0  printed; pipe a gate into open-gate.sh, copy a question into one
     AskUserQuestion
  2  usage error; fix the call and rerun once, else show the human stderr
  3  invalid plan file or event; fix what stderr names and rerun once, else
     show the human stderr. "a newer test.committed event": write the plan
     file again with the seat's newest
  4  stdout closed; stop and show the exit code
  5  an install fault
  129, 130, 143  stopped by HUP, INT or TERM

Dependencies: POSIX sh, jq 1.6+, awk; ${GATE_LIB} beside this script;
  ${VIEW_LIB}'s title.jq; a gate: its scripts/show.sh and ${RENDER_LIB}
  and views/${VIEW_NAME}.jq; procedure-seat-run's scripts/seats/seats.jq;
  the crucible skill's events.sh and lib/crucible-space.sh.
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

# Sets mode (gate or question) and seg_plan_file from the arguments.
parse_args() {
	seg_plan_file='' mode=gate
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
				seg_plan_file=$2
				shift 2
				;;
			*) usage_error 'unknown argument; expected --plan-file PATH, --question or --help' ;;
		esac
	done
	[ -n "${seg_plan_file}" ] || usage_error '--plan-file PATH missing; expected --plan-file PATH naming the JSON file; stdin is not read'
}

# Prints the folder this script was run from (".", when run by a bare name).
script_dir() {
	case $0 in
		*/*) printf '%s' "${0%/*}" ;;
		*) printf '.' ;;
	esac
}

# Exits 5 unless jq, the shared checks and, for a gate, human-view's
# lib/render.sh, the template and show.sh are in place; sets views_dir and
# show_script.
load_dependencies() {
	command -v jq >/dev/null 2>&1 ||
		install_fault 'jq missing; expected jq 1.6+ on PATH; try installing jq (macOS: brew install jq; Linux: the distro'\''s jq package)'
	seg_skills_dir="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/skills"
	own_dir=$(script_dir)
	views_dir="${own_dir}/../views"
	gate_lib="${own_dir}/${GATE_LIB}"
	[ -f "${gate_lib}" ] && [ -r "${gate_lib}" ] ||
		install_fault "plan checks missing; expected ${gate_lib}; reinstall the flow-code-test skill"
	# shellcheck source=lib/seat-event-gate.sh
	. "${gate_lib}"
	seg_load_tools
	[ "${mode}" = gate ] || return 0
	render_lib="${seg_skills_dir}/${VIEW_LIB}/${RENDER_LIB}"
	[ -f "${render_lib}" ] && [ -r "${render_lib}" ] ||
		install_fault "gate printer missing; expected ${render_lib}; install the ${VIEW_LIB} skill"
	# shellcheck source=../../../../../../../framework/core/engine/human-view/scripts/lib/render.sh
	. "${render_lib}"
	# shellcheck disable=SC2310 # its status is the answer; set -e is not relied on inside
	hv_check_printer "${seg_skills_dir}/${VIEW_LIB}/scripts" "${views_dir}" "${VIEW_NAME}" || install_fault "${hv_printer_problem}"
	show_script=${hv_show}
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
	view_data=$(printf '%s' "${question}" | jq -c --arg report "${seg_event}" "${VIEW_DATA_JQ}") ||
		install_fault 'jq failed on valid JSON; expected jq 1.6+; try jq --version, then rerun'
	# shellcheck disable=SC2310 # its status names the fault; set -e is not relied on inside
	hv_render_gate "${show_script}" "${views_dir}" "${VIEW_NAME}" "${view_data}" ||
		install_fault "${hv_render_problem}; expected the gate rendered from views/${VIEW_NAME}.jq; try reinstalling flow-code-test and ${VIEW_LIB}"
}

trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
seg_type='test.committed'
parse_args "$@"
load_dependencies
seg_load_plan
seg_load_event
question=$(printf '%s' "${seg_facts}" | jq -c "${QUESTION_JQ}") ||
	install_fault 'jq failed on valid JSON; expected jq 1.6+; try jq --version, then rerun'
if [ "${mode}" = question ]; then
	print_output "${question}"
else
	render_gate
fi
