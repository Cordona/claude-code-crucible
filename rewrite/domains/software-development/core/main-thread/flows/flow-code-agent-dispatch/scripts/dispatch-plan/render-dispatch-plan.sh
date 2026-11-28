#!/usr/bin/env sh
# Renders one dispatch plan, or its approval question, from its JSON file, so
# the main thread never hand-formats either. views/dispatch-plan.jq lays the
# plan out and human-view's show.sh renders it; this script passes it the
# plan, the installed plugins and the Data pairs, which end with what the
# dispatch would cut, as procedure-context's context.sh latest reads the
# effort of the plan.made event --data Plan= names.
# A dispatch plan's rules are
# dispatch-plan-validator.jq's, checked when generate-dispatch-plan.sh writes
# the plan; this script only refuses a plan it can't render. Pipe its stdout
# into procedure-approval-gate's open-gate.sh.
# shellcheck source-path=SCRIPTDIR source-path=SCRIPTDIR/../../../../../../../../framework/core/engine/human-view/scripts/lib
set -eu

readonly PROG='render-dispatch-plan.sh'
readonly PROCEDURE='flow-code-agent-dispatch'
readonly RENDER_LIB='human-view'
readonly SHOW='scripts/show.sh'
readonly CARD_PRINTER_LIB='scripts/lib/render.sh'
readonly VIEW_NAME='dispatch-plan'
readonly COMMON_TEMPLATE='common'
readonly CONTEXT_PROCEDURE='procedure-context'
# context.sh latest's exits: a version and nothing new, nothing yet, and new
# material waiting for the next cut.
readonly LATEST_CONTEXT=0
readonly LATEST_NONE=1
readonly LATEST_DOCS=7
# The pending entries of the next context version, in the effort folder.
readonly PENDING_FILE='drafts/main-thread/context/entries.json'

# Definitions every program below starts with. The programs are single-quoted
# on purpose: their $ signs are jq's.
# shellcheck disable=SC2016
readonly COMMON_JQ='
def option($label; $description): {label: $label, description: $description};
def checked_object(problems):
	if length != 1 then "expected exactly one JSON object, got \(length) values"
	elif (.[0] | type) != "object" then "input is a JSON \(.[0] | type); expected an object"
	else .[0] | problems end;
'

# The plan's data for views/dispatch-plan.jq: the plan, the installed plugins
# and the Data pairs, the --data KIND=PATH lines in the order given, then what
# the dispatch would cut.
# shellcheck disable=SC2016
readonly VIEW_DATA_JQ='
def pairs_of($lines): [$lines | split("\n")[] | select(. != "") | index("=") as $at | [.[:$at], .[($at + 1):]]];
{plan: .[0], installed: $installed, data: (pairs_of($data_lines) + pairs_of($context_lines))}
'

# Prints one line per field a printed plan (want "plan") or its question
# (want "question") reads that does not have the type it needs; nothing when
# the plan can be rendered. No plan rule is checked here.
# shellcheck disable=SC2016
readonly RENDERABLE_JQ='
def written_by: "expected the plan generate-dispatch-plan.sh writes";
def is_strings: type == "array" and all(.[]; type == "string");
def is_plugin_item: type == "object" and (.plugin | type) == "string";
def is_plugin_items: type == "array" and all(.[]; is_plugin_item);
def is_list_or_absent: . == null or is_plugin_items;
def is_plugins:
	type == "object"
	and ((.load // {}) | type == "object" and (.language == null or (.language | is_plugin_item))
		and all(.frameworks, .standards, .procedures; is_list_or_absent))
	and ((.skip // {}) | type == "object" and all(.standards, .procedures; is_list_or_absent));
def field_problem($field; ok; $type): if ok then empty else "\($field) is not \($type); \(written_by)" end;
def question_fields:
	field_problem("tasks"; .tasks | is_strings; "an array of strings");
def plan_fields:
	question_fields,
	field_problem("agent"; .agent | type == "string"; "a string"),
	field_problem("plugins"; (.plugins | is_plugins) or (.agent == "code-reviewer" and .plugins == null);
		"an object {\"load\": {...}, \"skip\": {...}} of {\"plugin\": str, ...} entries"),
	field_problem("context_fingerprint"; .context_fingerprint | type == "string"; "a string");
checked_object(if $want == "question" then question_fields else plan_fields end)
'

# Prints the AskUserQuestion fields for the plan, or nothing for replan
# "invalid" (that plan is shown with no question). $plans is how many plans
# this run of step 7 shows, one after another.
# shellcheck disable=SC2016
readonly QUESTION_JQ='
.[0]
| (.tasks | length) as $count
| " To change the plugins, choose \"Type something\" and write what to add or drop." as $change
| "Dispatch with the plugins shown." as $approve
| "Nothing is dispatched." as $stop
| if .replan == "invalid" then empty
  else {
	header: (if $count > 1 then "Dispatch ×\($count)" else "Dispatch" end),
	question: ((if $count > 1 then "Approve these \($count) dispatches with the plugins shown?"
		else "Approve this dispatch with the plugins shown?" end) + $change),
	options: (if .replan == "stop-recommended" then
			[option("Stop (Recommended)"; "Nothing is dispatched; reinstall the dropped plugin, then rerun."),
			 option("Approve"; $approve)]
		elif $plans > 1 then
			[option("Approve (Recommended)"; $approve),
			 option("Skip"; "This plan does not run; the next plan is still shown."),
			 option("Stop all"; "No further plan is shown and nothing is dispatched, including plans already approved.")]
		else
			[option("Approve (Recommended)"; $approve), option("Stop"; $stop)]
		end)
  } end
'

usage() {
	cat <<EOF
usage: sh ${PROG} --plan-file PATH [--data KIND=PATH]... [--skills-dir DIR]
       sh ${PROG} --plan-file PATH --question --plans N [--skills-dir DIR]
       sh ${PROG} --help | -h

Renders a dispatch plan, or its question.

Options:
  --plan-file PATH    the plan JSON, required (stdin is not read)
  --data KIND=PATH    printing a plan only, repeatable: one line of its Data
                      section, in the order given, before the context lines;
                      KIND letters, digits, space or -, PATH absolute
  --question          print the plan's question instead of the plan
  --plans N           with --question, then required: how many plans are
                      asked one after another, 1 or more
  --skills-dir DIR    default \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/skills

stdout, a plan: its Markdown from views/${VIEW_NAME}.jq, rendered by
  ${RENDER_LIB}'s show.sh render, without the gate marker; its Data section
  ends with what the dispatch would cut, by context.sh latest --effort of
  the effort of the plan.made event --data Plan= names (required:
  <effort>/events/<seq>-plan.made.json): "Docs folder" (DOCS_FOLDER) and,
  when the file exists, "Pending entries" (<effort>/${PENDING_FILE})
  for new material, or "Context" (CONTEXT_FILE) when nothing is new;
  a plan whose replan is "invalid" prints as blocked, showing the plugins
    with state "invalid"; it has no question
stdout, --question: one JSON object {"header": str, "question": str,
  "options": [{"label": str, "description": str}, ...]}; nothing for a
  dispatch plan whose replan is "invalid"
  option labels: Approve (Recommended) / Stop; with --plans > 1
  Approve (Recommended) / Skip / Stop all; replan "stop-recommended"
  Stop (Recommended) / Approve
stderr on exits 1, 3, 4, 5 and 6: a line starting "${PROG}:
  install:" is an install or host fault; show it to the human at once

Checks no plan rule; refuses only input it can't render.

Exit codes:
  0  printed; pipe a plan into open-gate.sh, copy a question into one
     AskUserQuestion; nothing printed: ask nothing
  1  a tool missing; install what stderr names
  2  the call or its input is wrong, a plan's effort with no context yet
     included; show stderr and stop
  3  a tool failed (its stderr is above)
  4  list-plugins.sh missing from the --skills-dir; install
     ${PROCEDURE} there; or stdout closed before the plan was printed
  5  a shared file missing; install the skill stderr names
  129, 130, 143  stopped by HUP, INT or TERM; show the human the exit code
  6  list-plugins.sh or context.sh failed (its stderr and exit are printed)

Dependencies (skills in the --skills-dir):
  POSIX sh; jq 1.6+ (macOS: brew install jq; Linux: the distro's jq)
  to print a plan: the ${RENDER_LIB} skill's ${SHOW} and ${CARD_PRINTER_LIB},
    the ${CONTEXT_PROCEDURE} skill's context.sh (it reads CRUCIBLE_HOME), and
    this skill's list-plugins.sh, installed-plugins.jq and
    views/${VIEW_NAME}.jq and views/${COMMON_TEMPLATE}.jq
EOF
}

warn() {
	printf '%s: %s\n' "${PROG}" "$1" >&2
}

# Prints an install or host fault (a missing or failing tool or shared file,
# never a problem of the input) with the "install:" prefix and exits $1.
install_fault() {
	warn "install: $2"
	exit "$1"
}

usage_error() {
	warn "$1"
	printf "Try '%s --help'.\n" "${PROG}" >&2
	exit 2
}

# Sets plan_file, skills_dir, want_question, plans and data_lines from the
# arguments, and refuses a combination the modes don't take.
parse_args() {
	plan_file=''
	data_lines=''
	skills_dir="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/skills"
	want_question=0
	plans=''
	while [ "$#" -gt 0 ]; do
		case $1 in
			--help | -h)
				usage
				exit 0
				;;
			--question)
				want_question=1
				shift
				;;
			--plan-file | --plans | --skills-dir | --data)
				[ "$#" -ge 2 ] && [ -n "$2" ] || usage_error "$1 needs a value; expected $1 VALUE"
				set_option "$1" "$2"
				shift 2
				;;
			*) usage_error "unknown argument: $1; expected --plan-file PATH, --skills-dir DIR, --question, --plans N, --data KIND=PATH or --help" ;;
		esac
	done
	[ -n "${plan_file}" ] || usage_error '--plan-file PATH missing; expected --plan-file PATH naming the JSON file; stdin is not read'
	[ "${want_question}" -eq 0 ] || [ -z "${data_lines}" ] ||
		usage_error '--data is not used with --question; expected it only when printing a plan'
	check_plan_args
}

set_option() {
	case $1 in
		--plan-file) plan_file=$2 ;;
		--plans) plans=$2 ;;
		--data) add_data "$2" ;;
		*) skills_dir=$2 ;;
	esac
}

# Appends KIND=PATH $1 to data_lines, one per line, or exits 2.
add_data() {
	case $1 in
		*[[:cntrl:]]*) usage_error '--data holds a control character; expected --data KIND=PATH on one line' ;;
		[[:alpha:]]*=/*) ;;
		*) usage_error "--data value '$1' is not KIND=PATH; expected a KIND such as Plan, then =, then an absolute path" ;;
	esac
	case ${1%%=*} in
		*[![:alnum:]\ -]*) usage_error "--data kind '${1%%=*}' holds a character outside letters, digits, space and -; expected a KIND such as Plan" ;;
		*) ;;
	esac
	data_lines="${data_lines}$1
"
}

check_plan_args() {
	if [ "${want_question}" -eq 1 ]; then
		case ${plans} in
			'') usage_error '--question needs --plans N; expected --question --plans N, N how many plans this run of step 7 shows, one after another' ;;
			*[!0-9]* | 0*) usage_error "--plans value '${plans}' is not a positive integer; expected --plans N such as 1 or 3" ;;
			*) ;;
		esac
	elif [ -n "${plans}" ]; then
		usage_error '--plans is used only with --question; expected --question --plans N'
	fi
}

# Prints the plan file slurped into one array, or exits 2 when it is
# unreadable or not JSON.
read_input() {
	[ -f "${plan_file}" ] && [ -r "${plan_file}" ] ||
		usage_error "plan file not readable: ${plan_file}; expected a readable JSON file"
	jq -s '.' "${plan_file}" </dev/null 2>/dev/null && return 0
	warn 'input is not valid JSON; expected one JSON object; try checking its quotes, commas and brackets, then rerun'
	exit 2
}

# Sets views_dir and show_script and sources human-view's card printer lib,
# which checks that show.sh and the plan's templates are in place; exits 5
# when one of them is missing.
load_card_printer() {
	case $0 in
		*/*) own_dir=${0%/*} ;;
		*) own_dir='.' ;;
	esac
	views_dir="${own_dir}/../../views"
	card_printer="${skills_dir}/${RENDER_LIB}/${CARD_PRINTER_LIB}"
	[ -f "${card_printer}" ] && [ -r "${card_printer}" ] ||
		install_fault 5 "card printer lib missing; expected ${card_printer}; install the ${RENDER_LIB} skill in ${skills_dir}"
	# shellcheck source=../../../../../../../../framework/core/engine/human-view/scripts/lib/render.sh
	. "${card_printer}"
	# shellcheck disable=SC2310 # its status is the answer; set -e is not relied on inside
	hv_check_printer "${skills_dir}/${RENDER_LIB}/scripts" "${views_dir}" "${VIEW_NAME}" "${COMMON_TEMPLATE}" ||
		install_fault 5 "${hv_printer_problem}"
	show_script=${hv_show}
}

# Sets installed to the installed plugins, installed-plugins.jq's map of
# list-plugins.sh's plugin lines, its stderr passed through; exits 4 when the
# script is missing, 5 when installed-plugins.jq is, 6 when the script fails
# and 3 when jq does. Its exit 1 (no plugin) is an empty map; its exit 3
# (invalid plugins) leaves them out.
read_installed() {
	plan_scripts_dir="${skills_dir}/${PROCEDURE}/scripts/dispatch-plan"
	list_script="${plan_scripts_dir}/list-plugins.sh"
	installed_program="${plan_scripts_dir}/installed-plugins.jq"
	[ -f "${list_script}" ] && [ -r "${list_script}" ] ||
		install_fault 4 "list-plugins.sh missing; expected ${list_script}; install the ${PROCEDURE} skill or pass the right --skills-dir"
	[ -f "${installed_program}" ] && [ -r "${installed_program}" ] ||
		install_fault 5 "installed-plugins.jq missing; expected ${installed_program}; install the ${PROCEDURE} skill or pass the right --skills-dir"
	if listing=$(sh "${list_script}" --max-lines 0 --skills-dir "${skills_dir}" </dev/null); then
		list_status=0
	else
		list_status=$?
	fi
	case ${list_status} in
		0 | 1 | 3) ;;
		*) install_fault 6 "list-plugins.sh failed (exit ${list_status}); expected exit 0, 1 or 3; fix what its stderr above names, or reinstall ${PROCEDURE}" ;;
	esac
	installed=$(jq -nc --arg listing "${listing}" -f "${installed_program}" </dev/null) ||
		install_fault 3 'jq failed reading the plugin list; expected jq 1.6+; try jq --version, then rerun'
}

# Sets context_lines to the KIND=PATH lines of what the dispatch would cut,
# from context.sh latest on the plan's effort; exits 2 when the effort has no
# context yet, 5 when context.sh is missing and 6 when it fails.
read_context_lines() {
	context_script="${skills_dir}/${CONTEXT_PROCEDURE}/scripts/context.sh"
	[ -f "${context_script}" ] && [ -r "${context_script}" ] ||
		install_fault 5 "context.sh missing; expected ${context_script}; install the ${CONTEXT_PROCEDURE} skill in ${skills_dir}"
	read_plan_effort
	if latest_out=$(sh "${context_script}" latest --effort "${plan_effort}" </dev/null); then
		latest_status=0
	else
		latest_status=$?
	fi
	case ${latest_status} in
		"${LATEST_CONTEXT}") context_lines="Context=$(latest_value CONTEXT_FILE)" ;;
		"${LATEST_DOCS}")
			context_lines="Docs folder=$(latest_value DOCS_FOLDER)"
			pending_path="${plan_effort}/${PENDING_FILE}"
			[ ! -f "${pending_path}" ] || context_lines="${context_lines}
Pending entries=${pending_path}"
			;;
		"${LATEST_NONE}") usage_error "the plan's effort has no context yet (context.sh latest exit ${LATEST_NONE}); expected a plan made after context.sh freeze --dry-run printed its fingerprint" ;;
		*) install_fault 6 "context.sh latest failed (exit ${latest_status}); expected exit ${LATEST_CONTEXT}, ${LATEST_NONE} or ${LATEST_DOCS}; fix what its stderr above names, or reinstall ${CONTEXT_PROCEDURE}" ;;
	esac
}

# Sets plan_effort to the effort folder of the plan.made event the --data
# Plan= line names, <effort>/events/<seq>-plan.made.json; exits 2 without one.
read_plan_effort() {
	plan_event=''
	while IFS= read -r data_line; do
		case ${data_line} in
			Plan=/*/events/[0-9][0-9][0-9][0-9][0-9][0-9]-plan.made.json) plan_event=${data_line#Plan=} ;;
			*) ;;
		esac
	done <<EOF
${data_lines}
EOF
	[ -n "${plan_event}" ] ||
		usage_error "no --data Plan= names a plan.made event; expected --data 'Plan=<effort>/events/<seq>-plan.made.json', the PLAN_RECORD generate-dispatch-plan.sh printed"
	plan_effort=${plan_event%/events/*}
}

# Prints the value of context.sh latest's "$1: <value>" line, or exits 6 when
# it printed none.
latest_value() {
	while IFS= read -r latest_line; do
		case ${latest_line} in
			"$1: "?*)
				printf '%s' "${latest_line#"$1: "}"
				return 0
				;;
			*) ;;
		esac
	done <<EOF
${latest_out}
EOF
	install_fault 6 "context.sh latest printed no $1 line; expected one on exit ${latest_status}; reinstall ${CONTEXT_PROCEDURE}"
}

# Runs jq program $1 over the slurped input; a jq failure exits 3.
run_jq() {
	printf '%s' "${slurped}" | jq -rc --arg want "${want}" \
		--argjson installed "${installed}" --argjson plans "${plans:-1}" \
		--arg data_lines "${data_lines}" --arg context_lines "${context_lines}" \
		"$1" || {
		install_fault 3 'jq failed on valid JSON; expected jq 1.6+; try jq --version, then rerun'
	}
}

parse_args "$@"
command -v jq >/dev/null 2>&1 ||
	install_fault 1 'jq missing; expected jq 1.6+ on PATH; try installing jq (macOS: brew install jq; Linux: the distro'\''s jq package)'

# One slurped value so an empty file and several values are caught as one problem.
slurped=$(read_input)
want=plan
[ "${want_question}" -eq 0 ] || want=question
installed='{}' context_lines=''
if [ "${want}" = plan ]; then
	load_card_printer
	read_installed
fi
check_program=${COMMON_JQ}${RENDERABLE_JQ}
question_program=${COMMON_JQ}${QUESTION_JQ}
problems=$(run_jq "${check_program}")
if [ -n "${problems}" ]; then
	printf '%s\n' "${problems}" | while IFS= read -r problem; do warn "${problem}"; done
	exit 2
fi
[ "${want}" != plan ] || read_context_lines
if [ "${want_question}" -eq 1 ]; then
	run_jq "${question_program}"
	exit 0
fi
view_data=$(run_jq "${VIEW_DATA_JQ}")
# shellcheck disable=SC2310 # its status names the fault; set -e is not relied on inside
hv_render_gate "${show_script}" "${views_dir}" "${VIEW_NAME}" "${view_data}" && exit 0
[ "${hv_render_status}" != 5 ] || install_fault 5 "${hv_render_problem}; expected the ${RENDER_LIB} skill installed whole"
install_fault 3 "${hv_render_problem}; expected the plan rendered from views/${VIEW_NAME}.jq; try reinstalling ${PROCEDURE} and ${RENDER_LIB}"
