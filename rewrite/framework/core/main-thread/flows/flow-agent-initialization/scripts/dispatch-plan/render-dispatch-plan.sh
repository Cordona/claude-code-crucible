#!/usr/bin/env sh
# Renders one dispatch plan, or its approval question, from its JSON file, so
# the main thread never hand-formats either. This script owns the wording; the
# layout is human-view's view.jq. A dispatch plan's rules are
# dispatch-plan-validator.jq's, checked when generate-dispatch-plan.sh writes
# the plan; this script only refuses a plan it can't render. Pipe its stdout
# into procedure-approval-gate's open-gate.sh.
set -eu

readonly PROG='render-dispatch-plan.sh'
readonly PROCEDURE='flow-agent-initialization'
readonly RENDER_LIB='human-view'

# Definitions every program below starts with. The programs are single-quoted
# on purpose: their $ signs are jq's.
# shellcheck disable=SC2016
readonly COMMON_JQ='
def clean: gsub("[[:cntrl:]]+"; " ") | sub("^ +"; "") | sub(" +$"; "");
def option($label; $description): {label: $label, description: $description};
def checked_object(problems):
	if length != 1 then "expected exactly one JSON object, got \(length) values"
	elif (.[0] | type) != "object" then "input is a JSON \(.[0] | type); expected an object"
	else .[0] | problems end;
'

# A printed plan starts with human-view's layout and title modules: jq takes an
# include only at the start of the program, before the common definitions and these.
readonly VIEW_INCLUDE='include "view"; include "title";'
# shellcheck disable=SC2016
readonly PRINTED_JQ='
# A task keeps its own lines (a numbered list in it stays as written); any
# other control character prints as a space.
def task_text: gsub("\r"; "") | split("\n") | map(gsub("[[:cntrl:]]+"; " ") | sub(" +$"; "")) | join("\n")
	| sub("\\A\n+"; "") | sub("\n+\\z"; "");
# The later lines of a numbered item are indented under it; a blank line stays empty.
def list_item_lines: split("\n") | .[:1] + (.[1:] | map(if . == "" then . else "   " + . end)) | join("\n");
def task_section: section("Task"; "Tasks"; .tasks | map(task_text | list_item_lines));
# The --data pairs in the order given, then the context file.
def data_pairs($context_path):
	[$data_lines | split("\n")[] | select(. != "") | index("=") as $at | [.[:$at], .[($at + 1):]]]
	+ [["Context", $context_path | clean]];
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
	field_problem("mode"; .mode | type == "string"; "a string"),
	field_problem("plugins"; .plugins | is_plugins;
		"an object {\"load\": {...}, \"skip\": {...}} of {\"plugin\": str, ...} entries"),
	field_problem("context"; (.context | type) == "object" and (.context.path | type) == "string" and (.context.sha256 | type) == "string";
		"an object {\"path\": str, \"sha256\": str}");
checked_object(if $want == "question" then question_fields else plan_fields end)
'

# The slim plan, plugins by label (a plugin list-plugins.sh no longer prints
# shows its name), every reason staying in the plan JSON. A code-developer plan:
# the Developer title from its valid language and frameworks, then Load and Skip with
# its standards, then procedures, in plan order. A code-reviewer plan holds one
# lens and shows only the Reviewer line: the reviewer title for a language
# seat, the standard's label for a standard seat. A replan "invalid" plan shows
# only the plugins it names as invalid, and no question.
# shellcheck disable=SC2016
readonly RENDER_JQ='
def plugin_label: $installed[.plugin].label // .plugin | clean;
def kind_labels($group): (($group.standards // []) + ($group.procedures // [])) | map(plugin_label);
def installed_only: .plugin as $name | select($installed | has($name));
# A plugin installed and not named invalid by the plan.
def valid_only: installed_only | select(.reason != "invalid");
# The title input, from the valid plugins only (an invalid one shows only
# under Invalid): the language label and the framework labels in plugin-name order.
def seat_labels: {language: (first(.language // empty | valid_only | plugin_label) // null),
	frameworks: [.frameworks // [] | sort_by(.plugin)[] | valid_only | plugin_label]};
def role_section:
	(.plugins.load // {}) as $load
	| [$load.standards // [] | .[] | installed_only | plugin_label] as $lenses
	| if .agent == "code-reviewer" then
		section("Reviewer"; if $load.language == null and $lenses != [] then $lenses
			else [$load | seat_labels | title("reviewer")] end)
	  else section("Developer"; [$load | seat_labels | title("developer")]) end;
def invalid_labels:
	[(.plugins.load.language // empty), (.plugins.load.frameworks // [])[], (.plugins.skip.standards // [])[], (.plugins.skip.procedures // [])[]
	 | select(.reason == "invalid") | plugin_label];
.[0]
| .context.path as $plan_context
| if .replan == "invalid" then
	[status_line("blocked"; "Blocked · this plan names an invalid plugin: fix it, then rerun"),
	 role_section,
	 task_section,
	 section("Invalid"; invalid_labels)]
  elif .agent == "code-reviewer" then
	[status_line("decision"; "Decision needed · approve this dispatch?"),
	 role_section,
	 task_section]
  else
	[status_line("decision"; "Decision needed · approve this dispatch?"),
	 role_section,
	 task_section,
	 section("Load"; kind_labels(.plugins.load // {})),
	 section("Skip"; kind_labels(.plugins.skip // {}))]
  end
| . + [data_section(data_pairs($plan_context))]
| blocks
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
			[option("Stop (Recommended)"; "Nothing is dispatched; reinstall the dropped plugin (faulty files: fix it), then rerun."),
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
  --plan-file PATH    the plan JSON, required (stdin is not read); dispatch
                      plan shape: see dispatch-plan-validator.jq
  --data KIND=PATH    printing a plan only, repeatable: one line of its Data
                      section, in the order given, before the context file;
                      KIND letters, digits, space or -, PATH absolute
  --question          print the plan's question instead of the plan
  --plans N           with --question, then required: how many plans are
                      asked one after another, 1 or more
  --skills-dir DIR    default \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/skills

stdout, a plan: its Markdown, without the gate marker:
  a code-developer plan: Developer, the title from its language and
    frameworks ("Generic developer" with no language), Task, Load and Skip
    (its standards, then procedures, by label), Data
  a code-reviewer plan: Reviewer, the reviewer title for a language seat
    ("Generic reviewer" with no lens) or the standard's label for a
    standard seat, Task, Data
  a plan whose replan is "invalid" prints as blocked: the Developer or
    Reviewer line from the installed plugins not named invalid, Task,
    Invalid (the plugins named with reason "invalid"), Data
stdout, --question: one JSON object {"header": str, "question": str,
  "options": [{"label": str, "description": str}, ...]}; nothing for a
  dispatch plan whose replan is "invalid"
  option labels: Approve (Recommended) / Stop; with --plans > 1
  Approve (Recommended) / Skip / Stop all; replan "stop-recommended"
  Stop (Recommended) / Approve
stderr on exits 1, 3, 4, 5 and 6: a line starting "${PROG}:
  install:" is an install or host fault; show it to the human at once

Checks no plan rule (generate-dispatch-plan.sh does); refuses only input it
can't render. Writes no file.

Exit codes:
  0  printed; pipe a plan into open-gate.sh, copy a question into one
     AskUserQuestion; nothing printed: ask nothing
  1  a tool missing; install what stderr names
  2  the call or its input is wrong; show stderr and stop
  3  a tool failed (its stderr is above)
  4  list-plugins.sh missing from the --skills-dir; install
     ${PROCEDURE} there
  5  a shared file missing; install the skill stderr names
  6  list-plugins.sh failed (its stderr and exit are printed)

Dependencies (skills in the --skills-dir):
  POSIX sh; jq 1.6+ (macOS: brew install jq; Linux: the distro's jq)
  to print a plan: the ${RENDER_LIB} skill's view.jq and title.jq, and this
    skill's list-plugins.sh and installed-plugins.jq
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

# Exits 5 when human-view's layout or title module, which a printed plan
# includes, is not a readable file in the skills folder.
check_render_lib() {
	for view_module in "${render_lib_dir}/view.jq" "${render_lib_dir}/title.jq"; do
		[ -f "${view_module}" ] && [ -r "${view_module}" ] ||
			install_fault 5 "human-view module missing; expected ${view_module}; install the ${RENDER_LIB} skill in ${skills_dir}"
	done
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

# Runs jq program $1 over the slurped input, with human-view on jq's module
# path; a jq failure exits 3.
run_jq() {
	printf '%s' "${slurped}" | jq -rc -L "${render_lib_dir}" --arg want "${want}" \
		--argjson installed "${installed}" --argjson plans "${plans:-1}" \
		--arg data_lines "${data_lines}" \
		"$1" || {
		install_fault 3 'jq failed on valid JSON; expected jq 1.6+; try jq --version, then rerun'
	}
}

parse_args "$@"
command -v jq >/dev/null 2>&1 ||
	install_fault 1 'jq missing; expected jq 1.6+ on PATH; try installing jq (macOS: brew install jq; Linux: the distro'\''s jq package)'

# One slurped value so an empty file and several values are caught as one problem.
slurped=$(read_input)
render_lib_dir="${skills_dir}/${RENDER_LIB}"
want=plan
[ "${want_question}" -eq 0 ] || want=question
installed='{}'
if [ "${want}" = plan ]; then
	check_render_lib
	read_installed
fi
check_program=${COMMON_JQ}${RENDERABLE_JQ}
render_program=${VIEW_INCLUDE}${COMMON_JQ}${PRINTED_JQ}${RENDER_JQ}
question_program=${COMMON_JQ}${QUESTION_JQ}
problems=$(run_jq "${check_program}")
if [ -n "${problems}" ]; then
	printf '%s\n' "${problems}" | while IFS= read -r problem; do warn "${problem}"; done
	exit 2
fi
if [ "${want_question}" -eq 1 ]; then
	run_jq "${question_program}"
else
	run_jq "${render_program}"
fi
