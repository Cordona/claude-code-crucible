#!/usr/bin/env sh
# Renders the "what next?" gate after a build card, so the main thread never
# hand-formats it, or with --question the gate's question: live validation
# first when the change has behaviour to trigger and watch, tests otherwise, a change when
# the build is blocked, and the tester's repair of the tests it turned red
# when every blocker of the seat's newest build.committed is gate_red. A
# plan file with no title takes the seat's title as its build card shows
# it. views/what-next.jq lays the gate out and human-view's show.sh renders
# it. Pipe its stdout into procedure-approval-gate's open-gate.sh, which
# shows the gate.
# shellcheck source-path=SCRIPTDIR source-path=SCRIPTDIR/lib
set -eu
umask 077

readonly PROG='render-what-next.sh'
readonly VIEW_LIB='human-view'
readonly RENDER_LIB='scripts/lib/render.sh'
readonly VIEW_NAME='what-next'
readonly SEATS_LIB='procedure-seat-run/scripts/seats'
readonly TITLE_LIB='lib/seat-title.sh'
readonly EVENTS='crucible/scripts/events.sh'
readonly BUILD_TYPE='build.committed'
readonly ROLE_WORD='build agent'
# A title is one TITLE: line, and the action one clause of an option's
# description; past these they are no line the human reads at a glance.
readonly MAX_TITLE_CHARS=200
readonly MAX_ACTION_CHARS=200
readonly newline='
'
# The shell's pattern checks stay byte-wise on macOS and Linux; jq reads the
# plan file as UTF-8 whatever the locale.
LC_ALL=C
export LC_ALL

# Prints one line per problem of the slurped plan file; nothing when it is one
# object holding a build seat name, a known case, when given a title naming
# the build agent and, only with case live, the action.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly PLAN_CHECK_JQ='
include "seats";
def expected_plan: "expected one JSON object {\"seat\": SEAT[, \"title\": TITLE], \"case\": \"live\" | \"not_live\" | \"blocked\"[, \"action\": TEXT]}";
def string_problem($name; $what):
	if has($name) | not then "\($name) missing; expected \($what)"
	elif (.[$name] | type) != "string" then "\($name) is a JSON \(.[$name] | type); expected \($what)"
	elif .[$name] | test("^[[:space:]]*$") then "\($name) is empty; expected \($what)"
	elif .[$name] | test("[[:cntrl:]  ]") then "\($name) holds a control character or a line or paragraph separator; expected one line"
	else empty end;
def seat_problem:
	string_problem("seat"; "the build seat") //
	(.seat | seats_name_problem | "seat \(.)") //
	(if .seat | startswith("\(seats_prefixes.builder)-") then empty
	 else "seat \(.seat | tojson) is no build seat; expected \(seats_prefixes.builder)-<letter>" end);
def title_problem:
	if has("title") | not then empty
	else
		string_problem("title"; "the TITLE: line'\''s title, such as \"Kotlin \($role) with Spring\"") //
		(if (.title | length) > $max_title then "title is \(.title | length) characters; expected at most \($max_title), the TITLE: line as printed"
		 elif .title | contains($role) | not then "title \(.title | tojson) names no \($role); expected the build seat'\''s TITLE: line"
		 else empty end)
	end;
def action_problem:
	if .case == "live" then
		string_problem("action"; "what main does to show the build working, such as \"Call POST /orders and show you the status\"") //
		(if (.action | length) > $max_action then "action is \(.action | length) characters; expected at most \($max_action); try a shorter action" else empty end)
	elif has("action") then "action is given with case \(.case | tojson); expected it only with case \"live\""
	else empty end;
if length != 1 then "the plan file holds \(length) JSON values; \(expected_plan)"
elif (.[0] | type) != "object" then "the plan file holds a JSON \(.[0] | type); \(expected_plan)"
else .[0]
	| ((keys - ["seat", "title", "case", "action"])[] | "\(tojson) is an unknown field; expected only seat, title, case and action"),
	  seat_problem,
	  title_problem,
	  (if has("case") | not then "case missing; \(expected_plan)"
	   elif .case as $case | ["live", "not_live", "blocked"] | index([$case]) | not then "case is \(.case | tojson); expected \"live\", \"not_live\" or \"blocked\""
	   else action_problem end)
end
'

# Prints the AskUserQuestion fields of the gate as one JSON object. Input: the
# slurped plan file, checked; $blockers: the blockers of the seat's newest
# build.committed with case blocked, else []. Review is offered before its
# flow exists; picking it says so.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly QUESTION_JQ='
include "title";
def option($label; $description): {label: $label, description: $description};
def recommended: .label += " (Recommended)";
def seat_who: . as $plan | .title | split($role) as $parts | $parts[0] + $role + " " + ($plan.seat | seat_letter) + ($parts[1:] | join($role));
def keep_building($description): option("Keep building"; $description);
def clause: sub("^[[:space:]]+"; "") | sub("[[:space:].]+$"; "");
def only_red: length > 0 and all(.[]; type == "object" and .kind == "gate_red");
# A detail in words. A ref is a path:line, path:line:column or bare :line
# (a time like 10:30 has no path and stays); a ref list goes with the word
# that only leads to it (also, at, after, see ...), and with the comma or
# semicolon before it when it ends its clause. A bracket left empty goes, and
# an unmatched bracket never stays.
def ref_pat: "(?:[^\\s:();,]*[/.][^\\s:();,]*)?:[0-9]+(?::[0-9]+)?(?![0-9A-Za-z_])";
def ref_list: "(?<![^\\s(])\(ref_pat)(?:\\s*(?:,|and|or)\\s*\(ref_pat))*";
def ref_lead: "(?:\\b(?:also|at|after|before|on|in|from|near|see|lines?)\\s+)?";
def reversed: explode | reverse | implode;
# Drops each $close with no $open before it to match.
def drop_unmatched($open; $close):
	reduce (explode[] | [.] | implode) as $c ({out: "", depth: 0};
		if $c == $open then .out += $c | .depth += 1
		elif $c == $close then (if .depth > 0 then .out += $c | .depth -= 1 else . end)
		else .out += $c end)
	| .out;
def balanced: drop_unmatched("("; ")") | reversed | drop_unmatched(")"; "(") | reversed;
def unref:
	gsub("\\s*[;,]?\\s*\(ref_lead)\(ref_list)(?=\\s*(?:$|[;,()]))"; "")
	| gsub("\\s*\(ref_lead)\(ref_list)"; "")
	| gsub("\\(\\s*\\)"; "") | gsub("\\(\\s+"; "(") | gsub("\\s+(?<mark>[;,.)])(?![^\\s;,.)])"; .mark)
	| gsub("(?<mark>[;,])[;,]+"; .mark) | gsub("\\s{2,}"; " ") | sub("^[\\s;,]+"; "")
	| balanced;
def red_tests: map(.detail | strings | unref | clause | select(. != "")) | join("; ");
.[0]
| option("Review"; "Not available yet: it shows so and asks again.") as $review
| "No tests or review yet; give the builder its next work in your next message." as $not_yet
| option("Change something"; "Say what; the builder does another round and you get a new card.") as $change
| keep_building("Nothing is sent now; give the builder its next work in your next message.") as $hold
| {header: "Next", question: "What next for \(seat_who)?",
   options: (if .case == "live" then
		[(option("Live-validate"; "\(.action | clause); you confirm what you see, and the tester then plans tests.") | recommended),
		 option("Write tests"; "Skip live validation; the tester drafts a test plan."),
		 $review,
		 keep_building($not_yet)]
	elif .case == "not_live" then
		[(option("Write tests"; "The tester drafts a test plan.") | recommended), $review, keep_building($not_yet)]
	elif $blockers | only_red then
		[(option("Fix failing tests"; "The tester updates the tests the build turned red to the new behaviour\($blockers | red_tests | if . == "" then "" else ": \(.)" end).") | recommended),
		 $change,
		 $hold]
	else
		[($change | recommended), $hold]
	end)}
'

# The gate's data for views/what-next.jq: the question, its first letter in
# lower case, and the build seat. Input: the question object.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly VIEW_DATA_JQ='{ask: ((.question[:1] | ascii_downcase) + .question[1:]), seat: $seat}'

usage() {
	print_page <<EOF
usage: sh ${PROG} --plan-file PATH [--effort FOLDER] | sh <skills>/procedure-approval-gate/scripts/open-gate.sh --label build-next --effort FOLDER
       sh ${PROG} --plan-file PATH [--effort FOLDER] --question
       sh ${PROG} --help | -h

Prints the "what next?" gate after a build card as Markdown naming the
build seat, or with --question its question. stdin is never read; the plan
file, and without a title the effort's events, only read; no file written.

Options:
  --plan-file PATH  one JSON object, no other field, written with the Write
                    tool:
                    seat: the build seat, build-agent-<letter>
                    title: optional, its TITLE: line's title, naming the
                      build agent, at most ${MAX_TITLE_CHARS} characters;
                      without it, the title the seat's build card shows
                    case: live (the change has behaviour main or the
                      human can trigger and watch), not_live, or blocked
                      (LAST_REPORT_STATE: blocked)
                    action: with live only, one line of at most
                      ${MAX_ACTION_CHARS} characters: what main does and
                      shows the human
  --effort FOLDER   the effort folder, absolute; needed when the plan file
                    has no title or its case is blocked
  --question        print the gate's question, not the gate
  CLAUDE_CONFIG_DIR  holds skills/; default \$HOME/.claude
  CRUCIBLE_HOME     the space (default \$HOME/.crucible)

stdout on exit 0 only:
  a gate: its Markdown, no gate marker
  --question: one JSON object {"header": "Next", "question": str,
    "options": [{"label": str, "description": str}, ...]}, the first
    option marked (Recommended):
    live: Live-validate / Write tests / Review / Keep building
    not_live: Write tests / Review / Keep building
    blocked: Change something / Keep building; when every blocker of
      the seat's newest ${BUILD_TYPE} is gate_red: Fix failing tests /
      Change something / Keep building, Fix failing tests naming each
      blocker's detail without its path:line refs
stderr on exits 2 and 3: one "${PROG}: <what>; expected <x>[; try <y>]"
  line per problem; a plan field is named seat, title, case or action
stderr on exit 5: "${PROG}: install:", a prefix no other exit
  prints; do not rerun; stop

Exit codes:
  0  printed; pipe a gate into open-gate.sh, copy a question into one
     AskUserQuestion
  2  usage error; fix the call and rerun once, else show the human stderr
  3  invalid plan file, or with no title or case blocked the effort
     refused or the seat with no build.committed; fix what stderr names
     and rerun once, else show the human stderr
  4  stdout closed; stop and show the exit code
  5  an install fault
  129, 130, 143  stopped by HUP, INT or TERM

Dependencies: POSIX sh, jq 1.6+, awk; ${TITLE_LIB} beside this script;
  ${VIEW_LIB}'s title.jq; a gate: its scripts/show.sh and ${RENDER_LIB}
  and views/${VIEW_NAME}.jq; procedure-seat-run's scripts/seats/seats.jq;
  with no title or case blocked, the crucible skill's events.sh.
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

# Sets slurped to the plan file read into one array, its title filled in from
# the seat when it has none, or exits 3 naming each problem of it.
load_plan() {
	[ -f "${plan_file}" ] && [ -r "${plan_file}" ] ||
		refuse_problems "plan file not readable: ${plan_file}; expected a readable JSON file"
	slurped=$(jq -s '.' "${plan_file}" </dev/null 2>/dev/null) ||
		refuse_problems 'the plan file is not valid JSON; expected one JSON object; try checking its quotes, commas and brackets, then rerun'
	problems=$(printf '%s' "${slurped}" | jq -r -L "${seats_dir}" --arg role "${ROLE_WORD}" \
		--argjson max_title "${MAX_TITLE_CHARS}" --argjson max_action "${MAX_ACTION_CHARS}" "${PLAN_CHECK_JQ}") ||
		install_fault 'jq failed on valid JSON; expected jq 1.6+; try jq --version, then rerun'
	refuse_problems "${problems}"
	plan_seat=$(printf '%s' "${slurped}" | jq -r '.[0] | if has("title") then "" else .seat end') ||
		install_fault 'jq failed on valid JSON; expected jq 1.6+; try jq --version, then rerun'
	[ -n "${plan_seat}" ] || return 0
	require_effort
	st_derive_title "${effort_folder}" "${plan_seat}" "${ROLE_WORD}"
	slurped=$(printf '%s' "${slurped}" | jq -c --arg title "${st_title}" '.[0].title = $title') ||
		install_fault 'jq failed on valid JSON; expected jq 1.6+; try jq --version, then rerun'
}

# Refuses a missing --effort, which a plan file with no title or with case
# blocked needs.
require_effort() {
	[ -n "${effort_folder}" ] ||
		usage_error '--effort FOLDER missing; expected it when the plan file has no title or its case is blocked'
}

# Sets blockers to the JSON list of blockers of the seat's newest
# build.committed when the case is blocked, else []; exits 3 when events.sh
# refuses the effort or the seat has no build.committed, 5 on a tool fault.
load_blockers() {
	blockers='[]'
	fields=$(printf '%s' "${slurped}" | jq -r '.[0] | .case, .seat') ||
		install_fault 'jq failed on valid JSON; expected jq 1.6+; try jq --version, then rerun'
	plan_case=${fields%%"${newline}"*} blocked_seat=${fields#*"${newline}"}
	[ "${plan_case}" = blocked ] || return 0
	require_effort
	events_script="${skills_dir}/${EVENTS}"
	require_skill_file "${events_script}" "${EVENTS%%/*}" 'events.sh'
	events_rc=0
	# The seat passed seats_name_problem, so it is safe in a jq string.
	build_event=$(sh "${events_script}" latest --effort "${effort_folder}" --type "${BUILD_TYPE}" \
		--where ".seat == \"${blocked_seat}\"" </dev/null) || events_rc=$?
	case ${events_rc} in
		0) ;;
		2 | 3) refuse_problems "events.sh refused --effort (exit ${events_rc}, its stderr is above); expected the effort folder, absolute" ;;
		*) install_fault "events.sh latest failed (exit ${events_rc}, its stderr is above)" ;;
	esac
	[ -n "${build_event}" ] ||
		refuse_problems "seat ${blocked_seat} has no ${BUILD_TYPE} event in ${effort_folder}; expected the blocked build its card showed"
	blockers=$(jq -c '.body.blockers | if type == "array" then . else [] end' "${build_event}" </dev/null) ||
		install_fault "jq could not read the event ${build_event}; expected the JSON events.sh wrote"
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
	seat=$(printf '%s' "${slurped}" | jq -r '.[0].seat') ||
		install_fault 'jq failed on valid JSON; expected jq 1.6+; try jq --version, then rerun'
	view_data=$(printf '%s' "${question}" | jq -c --arg seat "${seat}" "${VIEW_DATA_JQ}") ||
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
load_blockers
question=$(printf '%s' "${slurped}" | jq -c -L "${title_dir}" --arg role "${ROLE_WORD}" \
	--argjson blockers "${blockers}" "${QUESTION_JQ}") ||
	install_fault 'jq failed on valid JSON; expected jq 1.6+; try jq --version, then rerun'
if [ "${mode}" = question ]; then
	print_output "${question}"
else
	render_gate
fi
