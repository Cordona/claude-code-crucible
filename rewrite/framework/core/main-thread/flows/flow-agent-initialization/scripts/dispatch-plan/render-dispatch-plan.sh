#!/usr/bin/env sh
# Renders one dispatch plan, or its approval question, from JSON files, so the
# main thread never hand-formats either; --no-plugin-fits does the same for a
# part no installed tech plugin fits. This script owns the wording; the layout
# is human-view's view.jq. A dispatch plan's rules are
# dispatch-plan-validator.jq's, checked when generate-dispatch-plan.sh writes
# the plan; this script only refuses a plan it can't render. Pipe its stdout
# into procedure-approval-gate's open-gate.sh.
# shellcheck source-path=SCRIPTDIR source-path=SCRIPTDIR/../../../../../engine/crucible/scripts/lib source-path=SCRIPTDIR/../../../../procedures/procedure-context/scripts
set -eu

readonly PROG='render-dispatch-plan.sh'
readonly PROCEDURE='flow-agent-initialization'
readonly RENDER_LIB='human-view'
readonly CONTEXT_PROCEDURE='procedure-context'
readonly NAMES_MODULE='dispatch-names'

# Definitions every program below starts with. The programs are single-quoted
# on purpose: their $ signs are jq's.
# shellcheck disable=SC2016
readonly COMMON_JQ='
def text_ok: type == "string" and (gsub("[[:cntrl:][:space:]]"; "") | length > 0);
def clean: gsub("[[:cntrl:]]+"; " ") | sub("^ +"; "") | sub(" +$"; "");
def option($label; $description): {label: $label, description: $description};
def checked_object(problems):
	if length != 1 then "expected exactly one JSON object, got \(length) values"
	elif (.[0] | type) != "object" then "input is a JSON \(.[0] | type); expected an object"
	else .[0] | problems end;
def unknown_keys($allowed): (keys - $allowed)[] | "\(.): unknown field; expected one of \($allowed | join(", "))";
def strings_problems($key):
	if (.[$key] | type) != "array" or (.[$key] | length) == 0 then "\($key) missing or empty; expected an array of one or more strings"
	else .[$key] | to_entries[] | select(.value | text_ok | not) | "\($key)[\(.key)] is not a non-empty string; expected a non-empty string" end;
def installed:
	$listing | split("\n") | map(split("\t") | select(length >= 3 and .[0] != "")
		| {key: .[1], value: {kind: .[0], label: .[2]}}) | from_entries;
'

# A printed plan of either kind starts with human-view's layout module, and a
# dispatch plan or its question with the flow's shared names (direct_agent):
# jq takes an include only at the start of the program, before the common
# definitions and these.
readonly VIEW_INCLUDE='include "view";'
readonly NAMES_INCLUDE="include \"${NAMES_MODULE}\";"
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
def is_plugin_items: type == "array" and all(.[]; type == "object" and (.plugin | type) == "string");
def field_problem($field; ok; $type): if ok then empty else "\($field) is not \($type); \(written_by)" end;
def question_fields:
	field_problem("tasks"; .tasks | is_strings; "an array of strings");
def plan_fields:
	question_fields,
	field_problem("agent"; .agent | type == "string"; "a string"),
	field_problem("mode"; .mode | type == "string"; "a string"),
	field_problem("technology"; .technology | type == "string"; "a string"),
	field_problem("loaded"; .loaded | is_plugin_items; "an array of {\"plugin\": str, ...} objects"),
	field_problem("not_loaded"; .not_loaded | is_plugin_items; "an array of {\"plugin\": str, ...} objects"),
	field_problem("context"; (.context | type) == "object" and (.context.path | type) == "string" and (.context.sha256 | type) == "string";
		"an object {\"path\": str, \"sha256\": str}");
checked_object(if $want == "question" then question_fields else plan_fields end)
'

# The slim plan: the plugins other than the tech plugin by label (the tech
# plugin is the Developer line), standard-* first, then procedure-*, then any
# other kind, each group in plan order; a plugin list-plugins.sh no longer
# prints shows its name. Every reason stays in the plan JSON. A replan
# "invalid" plan shows only the plugins it dropped as invalid, and no question.
# shellcheck disable=SC2016
readonly RENDER_JQ='
def name_group: if startswith("standard-") then 0 elif startswith("procedure-") then 1 else 2 end;
def plugin_labels($list; $installed):
	[$list[] | select($installed[.plugin].kind != "tech")]
	| map(select(.plugin | name_group == 0)) + map(select(.plugin | name_group == 1)) + map(select(.plugin | name_group == 2))
	| map($installed[.plugin].label // .plugin | clean);
def developer: if .agent == direct_agent then "main thread (direct implementation)" else .technology | clean end;
.[0]
| installed as $installed
| (.agent == direct_agent) as $is_direct
| .context.path as $plan_context
| if .replan == "invalid" then
	[status_line("blocked"; "Blocked · this plan names an invalid plugin: fix it, then rerun"),
	 section("Developer"; [developer]),
	 task_section,
	 section("Invalid"; plugin_labels(.not_loaded | map(select(.reason == "invalid")); $installed))]
  else
	[status_line("decision"; if $is_direct then "Decision needed · approve implementing this directly?"
		else "Decision needed · approve this dispatch?" end),
	 section("Developer"; [developer]),
	 task_section,
	 section("Loaded"; plugin_labels(.loaded; $installed)),
	 section("Not loaded"; plugin_labels(.not_loaded; $installed))]
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
| (.agent == direct_agent) as $is_direct
| " To change the plugins, choose \"Type something\" and write what to add or drop." as $change
| (if $is_direct then "Implement with the plugins shown." else "Dispatch with the plugins shown." end) as $approve
| (if $is_direct then "Nothing is implemented." else "Nothing is dispatched." end) as $stop
| if .replan == "invalid" then empty
  else {
	header: (if $count > 1 then "Dispatch ×\($count)" else "Dispatch" end),
	question: ((if $is_direct then "Approve implementing directly with the plugins shown?"
		elif $count > 1 then "Approve these \($count) dispatches with the plugins shown?"
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

# shellcheck disable=SC2016
readonly NO_FIT_CHECK_JQ='
checked_object(
	unknown_keys(["stack", "files", "tasks"]),
	(if (.stack | text_ok) then empty else "stack missing or empty; expected a non-empty string" end),
	strings_problems("files"),
	strings_problems("tasks"))
'

# shellcheck disable=SC2016
readonly NO_FIT_RENDER_JQ='
.[0]
| [status_line("decision"; "Decision needed · no plugin fits \(.stack | clean): implement it directly?"),
   task_section,
   section("File"; "Files"; .files | map(clean | path_text)),
   data_section(data_pairs($context_file))]
| blocks
'

# shellcheck disable=SC2016
readonly NO_FIT_QUESTION_JQ='
.[0]
| {header: "No plugin",
   question: "No installed tech plugin fits \(.stack | clean). Stop, or implement directly?",
   options: [option("Stop (Recommended)"; "build the tech plugin first; nothing runs for this part"),
	option("Implement directly"; "the main thread writes the code, with the standard and procedure plugins the next plan settles")]}
'

usage() {
	cat <<EOF
usage: sh ${PROG} --plan-file PATH [--data KIND=PATH]... [--skills-dir DIR]
       sh ${PROG} --plan-file PATH --question --plans N [--skills-dir DIR]
       sh ${PROG} --no-plugin-fits --plan-file PATH --context-file CTX
           [--data KIND=PATH]...
       sh ${PROG} --no-plugin-fits --plan-file PATH --question
       sh ${PROG} --help | -h

Renders a dispatch plan, or a part no tech plugin fits, or its question.

Options:
  --plan-file PATH    the plan JSON, required (stdin is not read); dispatch
                      plan shape: see dispatch-plan-validator.jq
  --no-plugin-fits    the --plan-file is a part no installed tech plugin fits:
                      exactly {"stack": str, "files": [str, ...],
                      "tasks": [str, ...]}, each array one or more strings
  --context-file CTX  only to print a --no-plugin-fits plan, then required:
                      the effort's latest context file
  --data KIND=PATH    printing a plan only, repeatable: one line of its Data
                      section, in the order given, before the context file;
                      KIND letters, digits, space or -, PATH absolute
  --question          print the plan's question instead of the plan
  --plans N           with --question on a dispatch plan, then required: how
                      many plans are asked one after another, 1 or more
  --skills-dir DIR    default \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/skills; not
                      taken with --no-plugin-fits (it uses the default)

stdout, a plan: its Markdown, without the gate marker; a dispatch plan whose
  replan is "invalid" prints as blocked, naming its invalid plugins
stdout, --question: one JSON object {"header": str, "question": str,
  "options": [{"label": str, "description": str}, ...]}; nothing for a
  dispatch plan whose replan is "invalid"
  option labels: Approve (Recommended) / Stop; with --plans > 1
  Approve (Recommended) / Skip / Stop all; replan "stop-recommended"
  Stop (Recommended) / Approve; --no-plugin-fits Stop (Recommended) /
  Implement directly
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
  to print a plan: the ${RENDER_LIB} skill's view.jq
  a dispatch plan or its question: this skill's
    scripts/agent-dispatch/${NAMES_MODULE}.jq
  to print a dispatch plan: this skill's list-plugins.sh
  to print a --no-plugin-fits plan: wc; sha256sum (Linux: coreutils) or
    shasum (macOS: built in); the ${CONTEXT_PROCEDURE} skill's
    agent-context-file-checks.sh, context-versions.sh,
    agent-context-validator.jq and agent-context-url.jq; the crucible
    skill's scripts/lib/crucible-space.sh
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

# Sets plan_file, context_file, skills_dir, want_question, no_plugin_fits,
# plans and data_lines from the arguments, and refuses a combination the modes
# don't take.
parse_args() {
	plan_file=''
	data_lines=''
	context_file=''
	skills_dir="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/skills"
	skills_dir_given=0
	want_question=0
	no_plugin_fits=0
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
			--no-plugin-fits)
				no_plugin_fits=1
				shift
				;;
			--plan-file | --context-file | --plans | --skills-dir | --data)
				[ "$#" -ge 2 ] && [ -n "$2" ] || usage_error "$1 needs a value; expected $1 VALUE"
				set_option "$1" "$2"
				shift 2
				;;
			*) usage_error "unknown argument: $1; expected --plan-file PATH, --skills-dir DIR, --question, --plans N, --no-plugin-fits, --context-file PATH (with --no-plugin-fits), --data KIND=PATH or --help" ;;
		esac
	done
	[ -n "${plan_file}" ] || usage_error '--plan-file PATH missing; expected --plan-file PATH naming the JSON file; stdin is not read'
	check_context_arg
	[ "${want_question}" -eq 0 ] || [ -z "${data_lines}" ] ||
		usage_error '--data is not used with --question; expected it only when printing a plan'
	if [ "${no_plugin_fits}" -eq 1 ]; then
		check_no_fit_args
	else
		check_plan_args
	fi
}

set_option() {
	case $1 in
		--plan-file) plan_file=$2 ;;
		--context-file) context_file=$2 ;;
		--plans) plans=$2 ;;
		--data) add_data "$2" ;;
		*)
			skills_dir=$2
			skills_dir_given=1
			;;
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

# A --no-plugin-fits plan shows CTX; its question does not, and a dispatch
# plan names its context file itself.
check_context_arg() {
	if [ "${no_plugin_fits}" -eq 0 ]; then
		[ -z "${context_file}" ] ||
			usage_error '--context-file is used only with --no-plugin-fits; expected a dispatch plan to name its context file in its context field'
	elif [ "${want_question}" -eq 1 ]; then
		[ -z "${context_file}" ] ||
			usage_error '--context-file is not used with --question; expected it only when printing the plan'
	else
		[ -n "${context_file}" ] ||
			usage_error '--context-file PATH missing; expected --context-file PATH naming the effort'\''s context file, required when printing a --no-plugin-fits plan'
	fi
}

check_no_fit_args() {
	[ -z "${plans}" ] || usage_error '--plans is not used with --no-plugin-fits; expected --no-plugin-fits --plan-file PATH --context-file CTX, or --no-plugin-fits --plan-file PATH --question'
	[ "${skills_dir_given}" -eq 0 ] ||
		usage_error '--skills-dir is not used with --no-plugin-fits; expected --no-plugin-fits --plan-file PATH --context-file CTX, or --no-plugin-fits --plan-file PATH --question'
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

# Checks the context file as prepare-agent-prompt.sh does, apart from the
# digest; exits 2 with one "context file:" stderr line for the first problem,
# or with an "install:" line 1 when no sha256 tool is on PATH, 3 when jq or wc
# fails, 5 when a shared check is missing.
read_context() {
	load_context_checks
	path_problem=$(context_path_problem "${context_file}")
	[ -z "${path_problem}" ] || context_error "${path_problem}: ${context_file}; expected ${context_path_expected}"
	# shellcheck disable=SC2310 # its status is a tool's; a failure has printed its cause
	context_read_problem "${context_file}" ||
		install_fault 3 'jq or wc failed on the context read checks (its stderr is above); expected jq 1.6+; try jq --version, then rerun'
	[ -z "${context_read_fault}" ] || context_error "${context_file}: ${context_read_text}"
}

# Sources the shared path checks and loads the read checks; exits 5 when a
# shared check is missing, 1 when no sha256 tool is on PATH.
load_context_checks() {
	context_lib="${skills_dir}/${CONTEXT_PROCEDURE}/scripts/agent-context-file-checks.sh"
	[ -f "${context_lib}" ] && [ -r "${context_lib}" ] ||
		install_fault 5 "shared context check missing; expected ${context_lib}; install the skill it is in"
	# shellcheck source=../../../../procedures/procedure-context/scripts/agent-context-file-checks.sh
	. "${context_lib}"
	# shellcheck disable=SC2310 # its status says whether the checks loaded; the fault is read here
	if ! context_load_checks "${skills_dir}"; then
		[ "${context_load_fault}" != host ] || install_fault 1 "${context_load_problem}"
		install_fault 5 "${context_load_problem}"
	fi
}

# Prints "context file: $1" on stderr and exits 2.
context_error() {
	warn "context file: $1"
	exit 2
}

# Prints the folder this script was run from (".", when run by a bare name).
script_dir() {
	case $0 in
		*/*) printf '%s' "${0%/*}" ;;
		*) printf '.' ;;
	esac
}

# Exits 5 when human-view's layout module, which a printed plan includes, is
# not a readable file in the skills folder.
check_render_lib() {
	view_module="${render_lib_dir}/view.jq"
	[ -f "${view_module}" ] && [ -r "${view_module}" ] ||
		install_fault 5 "layout module missing; expected ${view_module}; install the ${RENDER_LIB} skill in ${skills_dir}"
}

# Exits 5 when the flow's shared names, which a dispatch plan and its question
# include, are not a readable file beside this script's folder.
check_names_module() {
	names_module="${names_dir}/${NAMES_MODULE}.jq"
	[ -f "${names_module}" ] && [ -r "${names_module}" ] ||
		install_fault 5 "shared names missing; expected ${names_module}; reinstall the ${PROCEDURE} skill"
}

# Sets listing to list-plugins.sh's plugin lines, its stderr passed through;
# exits 4 when the script is missing and 6 when it fails. Its exit 1 (no
# plugin) is an empty list; its exit 3 (invalid plugins) leaves them out.
read_listing() {
	list_script="${skills_dir}/${PROCEDURE}/scripts/dispatch-plan/list-plugins.sh"
	[ -f "${list_script}" ] && [ -r "${list_script}" ] ||
		install_fault 4 "list-plugins.sh missing; expected ${list_script}; install the ${PROCEDURE} skill or pass the right --skills-dir"
	if listing=$(sh "${list_script}" --max-lines 0 --skills-dir "${skills_dir}" </dev/null); then
		list_status=0
	else
		list_status=$?
	fi
	case ${list_status} in
		0 | 1 | 3) ;;
		*) install_fault 6 "list-plugins.sh failed (exit ${list_status}); expected exit 0, 1 or 3; fix what its stderr above names, or reinstall ${PROCEDURE}" ;;
	esac
}

# Runs jq program $1 over the slurped input, with human-view and the shared
# names on jq's module path; a jq failure exits 3.
run_jq() {
	printf '%s' "${slurped}" | jq -rc -L "${render_lib_dir}" -L "${names_dir}" --arg want "${want}" \
		--arg listing "${listing}" --argjson plans "${plans:-1}" \
		--arg context_file "${context_file}" --arg data_lines "${data_lines}" \
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
names_dir=$(script_dir)/../agent-dispatch
want=plan
[ "${want_question}" -eq 0 ] || want=question
[ "${want}" = question ] || check_render_lib
[ -z "${context_file}" ] || read_context
listing=''
if [ "${no_plugin_fits}" -eq 1 ]; then
	check_program=${COMMON_JQ}${NO_FIT_CHECK_JQ}
	render_program=${VIEW_INCLUDE}${COMMON_JQ}${PRINTED_JQ}${NO_FIT_RENDER_JQ}
	question_program=${COMMON_JQ}${NO_FIT_QUESTION_JQ}
else
	check_names_module
	[ "${want}" = question ] || read_listing
	check_program=${COMMON_JQ}${RENDERABLE_JQ}
	render_program=${VIEW_INCLUDE}${NAMES_INCLUDE}${COMMON_JQ}${PRINTED_JQ}${RENDER_JQ}
	question_program=${NAMES_INCLUDE}${COMMON_JQ}${QUESTION_JQ}
fi
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
