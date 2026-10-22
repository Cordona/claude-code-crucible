#!/usr/bin/env sh
# Renders one dispatch plan with its context file's path, or its approval
# question, from JSON files, so the main thread never hand-formats either; --no-plugin-fits
# does the same for a part no installed tech plugin fits. This script owns the
# layout and the question wording. A dispatch plan's rules are
# dispatch-plan-validator.jq's, checked when generate-dispatch-plan.sh
# writes the plan; this script only
# refuses a plan it can't render. The path display helpers are lib-render's
# paths.jq. Pipe its stdout into procedure-approval-gate's open-gate.sh.
# shellcheck source-path=SCRIPTDIR
set -eu

readonly PROG='render-dispatch-plan.sh'
readonly PROCEDURE='flow-agent-initialization'
readonly RENDER_LIB='lib-render'
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

# A printed plan of either kind starts with lib-render's path helpers, and a
# dispatch plan or its question with the flow's shared names (direct_agent):
# jq takes an include only at the start of the program, before the common
# definitions and these.
readonly PATHS_INCLUDE='include "paths";'
readonly NAMES_INCLUDE="include \"${NAMES_MODULE}\";"
# shellcheck disable=SC2016
readonly PRINTED_JQ='
# A task keeps its own lines (a numbered list in it stays as written); any
# other control character prints as a space.
def task_text: gsub("\r"; "") | split("\n") | map(gsub("[[:cntrl:]]+"; " ") | sub(" +$"; "")) | join("\n")
	| sub("\\A\n+"; "") | sub("\n+\\z"; "");
# The later lines of a numbered item are indented under it; a blank line stays empty.
def list_item_lines: split("\n") | .[:1] + (.[1:] | map(if . == "" then . else "   " + . end)) | join("\n");
def task_section:
	if (.tasks | length) == 1 then "### Task\n\n" + (.tasks[0] | task_text)
	else "### Tasks\n\n" + ([.tasks | to_entries[] | "\(.key + 1). " + (.value | task_text | list_item_lines)] | join("\n")) end;
def context_section($path; $digest): "### Context\n\n- \($path | clean | link_span) (sha256 \($digest[:12]))";
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
# plugin is the Tech line), standard-* first, then procedure-*, then any other
# kind, each group in plan order; a plugin list-plugins.sh no longer prints
# shows its name. Every reason stays in the plan JSON.
# shellcheck disable=SC2016
readonly RENDER_JQ='
def name_group: if startswith("standard-") then 0 elif startswith("procedure-") then 1 else 2 end;
def plugin_labels($list; $installed):
	[$list[] | select($installed[.plugin].kind != "tech")]
	| map(select(.plugin | name_group == 0)) + map(select(.plugin | name_group == 1)) + map(select(.plugin | name_group == 2))
	| map($installed[.plugin].label // .plugin | clean);
def labels_item($title; $labels):
	if ($labels | length) == 0 then "- \($title): none" else "- \($title):\n" + ($labels | map("  - \(.)") | join("\n")) end;
.[0]
| installed as $installed
| "## Dispatch Plan\n\n"
	+ "- Tech: \(.technology | clean)\n"
	+ "- Mode: \(.mode | clean)\(if .agent == direct_agent then " (direct implementation)" else "" end)\n\n"
	+ task_section
	+ "\n\n"
	+ labels_item("Loaded"; plugin_labels(.loaded; $installed)) + "\n"
	+ labels_item("Not loaded"; plugin_labels(.not_loaded; $installed))
	+ "\n\n### Context\n\n- \(.context.path | clean | link_span)"
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
| "## No Plugin Fits\n\n"
	+ "- Stack: \(.stack | clean)\n\n"
	+ task_section
	+ "\n\n### Files\n\n" + (.files | map("- \(clean | short_path($home) | code_span)") | join("\n"))
	+ "\n\n" + context_section($context_file; $context_digest)
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
Usage: sh ${PROG} --plan-file PATH [--skills-dir DIR] | sh <skills>/procedure-approval-gate/scripts/open-gate.sh
       sh ${PROG} --plan-file PATH --question --plans N
       sh ${PROG} --no-plugin-fits --plan-file PATH --context-file CTX
       sh ${PROG} --no-plugin-fits --plan-file PATH --question

Reads one plan as a JSON object from PATH, and prints the plan Markdown headed
by "## Dispatch Plan", ending in its Context section. PATH is required
in every mode; stdin is not read. A dispatch plan names its context file in
its context field; CTX is only for --no-plugin-fits, required when printing
its plan and refused with --question. It prints no gate marker; open-gate.sh
adds it.

Input shape, as generate-dispatch-plan.sh writes it:
  {"agent": str, "mode": "BUILD"|"TEST", "technology": str,
   "tasks": [str, ...],
   "loaded": [{"plugin": str, "reason": str}, ...],
   "loaded_reason": str,
   "not_loaded": [{"plugin": str, "reason": str}, ...],
   "replan": "invalid"|"stop-recommended",
   "context": {"path": str, "sha256": str}}
Its rules are dispatch-plan-validator.jq's, checked when the
generator writes the plan; this script checks none of them. It only refuses
input it can't render, one stderr line each, exit 2: not exactly one JSON
object, or a field it reads that does not have the type it needs ("<field> is
not <type>; expected the plan generate-dispatch-plan.sh writes"): tasks an
array of strings; for a printed plan also agent, mode and technology strings,
loaded and not_loaded arrays of objects with a string plugin, and context an
object with string path and sha256.
The installed plugins, which a printed plan reads to leave the tech plugin out
of the Loaded and Not loaded lists, are the plugin lines of
DIR/${PROCEDURE}/scripts/03-dispatch-plan/list-plugins.sh --max-lines 0, run with
--skills-dir DIR; its stderr is passed through. Its exit 1 (no plugin) is an
empty list, and its exit 3 (invalid plugins) leaves them out of the list.
  DIR  the skills folder, as list-plugins.sh's --skills-dir; defaults to
       \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/skills. A printed plan of either
       kind also loads DIR/${RENDER_LIB}/paths.jq, the path display helpers.
Layout, every item on its own line (agent, reasons, loaded_reason and the
context file's content stay in the JSON files and are not printed):
  ## Dispatch Plan
  - Tech: <technology>
  - Mode: <mode>, with " (direct implementation)" for the direct agent,
                   ${NAMES_MODULE}.jq's direct_agent
  ### Task         the task as written, its own line breaks kept; a group
                   prints "### Tasks" and a numbered list, one task each
  - Loaded:        then one "  - <label>" line per loaded plugin, or
                   "- Loaded: none"
  - Not loaded:    the same for not_loaded
                   A label is list-plugins.sh's label field, as
                   the dispatch's LABELS line uses it; a plugin
                   list-plugins.sh no longer prints shows its name. A plugin
                   list-plugins.sh prints as tech is left out (the Tech line
                   names it). Each list has the standard-* plugins first,
                   then the procedure-* plugins, then any other kind, each
                   group in plan order.
  ### Context
  - \`<path>\`     context.path, whole (lib-render's link_span)
Any other control character in a value prints as a space, and a backtick in
a code span as '.

With --no-plugin-fits, the context file CTX, checked as prepare-agent-prompt.sh
checks it, apart from the digest the hook compares (the path checks are
scripts/02-agent-context/agent-context-file-checks.sh and the shape check
scripts/02-agent-context/agent-context-validator.jq). Before it is opened, CTX
must be absolute and hold no control character, no double
quote and no .. segment, and must not name a sensitive file in any letter
case (a basename .env*, *.pem, *.key or id_*, or a .git component). It must
be a readable regular file, not a symlink, no bigger than the size cap of
agent-context-file-checks.sh,
holding exactly one JSON object
  {"paths": null | [{"path": str, "why": str}, ...],
   "links": null | [{"url": str, "why": str}, ...],
   "notes": [str, ...]}
with no other key in it or its entries; path absolute (starts with /), url
http:// or https:// (in any letter case) with a host of letters, digits, dots
and hyphens and an optional :port, then optionally a path, query or fragment
of letters, digits and . _ ~ / ? # = % : + , @ - only (no space, quote,
; $ \` ( ) & | < or >),
why one non-empty line, notes may be []. Each problem prints as
"context file: <what>; expected <x>" (the shape problems at most 20, then a
count), exit 2; every line about a problem of CTX itself starts
"context file:", and no other line does. The plan shows only its path and
digest.

--question --plans N prints the plan's AskUserQuestion fields instead, as one
JSON object to copy as is (no context and no plugin list is read):
  {"header": str, "question": str, "options": [{"label": str, "description": str}, ...]}
N is how many plans this run of step 7 shows, one after another (1 or more).
  - header "Dispatch", or "Dispatch ×<count>" for a group of <count> tasks
  - question: direct implementation, a group, or one dispatch, each with
    how to change the plugins ("Type something")
  - options: one plan, Approve (Recommended) / Stop; N > 1, Approve
    (Recommended) / Skip / Stop all; replan "stop-recommended", Stop
    (Recommended) / Approve
  - replan "invalid": prints nothing, exit 0 (the plan is shown, nothing asked)

--no-plugin-fits reads a part no installed tech plugin fits instead:
  {"stack": str, "files": [str, ...], "tasks": [str, ...]}
with no other field; each array holds one or more strings. It reads no
plugin list, and takes neither --plans nor --skills-dir (its paths.jq is the
default DIR's). It prints a plan headed by "## No Plugin Fits": "- Stack: <stack>", the
task or tasks as above, "### Files" with one "- \`<file>\`" line each (\$HOME
as ~, cut in the middle past 80 characters), then "### Context" with
"- \`<CTX>\` (sha256 <hex>)": CTX whole, then the first 12 hex of its
sha256.
With --question it prints the question JSON instead:
header "No plugin", options "Stop (Recommended)", then "Implement directly"
(the main thread writes the code, with the standard and procedure plugins
the next plan settles).

Every install or host fault, a missing or failing tool or shared file (the
exits 1, 3, 4, 5 and 6 below), prints one line starting
"${PROG}: install:", after any stderr of the failing tool;
no other line starts with it. A problem of the plan file or the arguments
starts with neither "install:" nor "context file:".

Exit codes:
  0  the plan or question printed (nothing for --question with replan "invalid")
  1  jq missing, or, when printing a --no-plugin-fits plan, both sha256sum
     and shasum missing
  2  usage error (--plan-file missing, or --context-file missing or given
     where it is not taken, included), an unreadable plan or context file, or
     input it can't render (one stderr line per problem, nothing on stdout)
  3  jq failed while checking or rendering valid JSON, or wc or the sha256
     tool failed (its stderr is printed)
  4  list-plugins.sh missing from DIR, when printing a dispatch plan
  5  scripts/02-agent-context/agent-context-file-checks.sh or agent-context-validator.jq
     missing, when printing a --no-plugin-fits plan,
     DIR/${RENDER_LIB}/paths.jq missing, when printing a plan, or
     scripts/04-agent-dispatch/${NAMES_MODULE}.jq missing, for a dispatch plan
     or its question
  6  list-plugins.sh failed with an exit other than 0, 1 or 3, such as 2
     (skills folder missing or unreadable); its stderr and exit are printed

Dependencies: POSIX sh, jq 1.6+ (macOS: brew install jq; Linux: the distro's
jq package); for a printed plan the ${RENDER_LIB} skill's
paths.jq; for a dispatch plan list-plugins.sh, and for it or its question
scripts/04-agent-dispatch/${NAMES_MODULE}.jq; for a --no-plugin-fits plan
wc, sha256sum (Linux: coreutils) or shasum (macOS: built in, run as
shasum -a 256),
scripts/02-agent-context/agent-context-file-checks.sh and agent-context-validator.jq.
Runtime: about 80 ms for a plan with 8 plugins installed, 70 ms for its question,
30 ms for --no-plugin-fits; measured on macOS (average of 5 runs).
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

# Sets plan_file, context_file, skills_dir, want_question, no_plugin_fits and
# plans from the arguments, and refuses a combination the modes don't take.
parse_args() {
	plan_file=''
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
			--plan-file | --context-file | --plans | --skills-dir)
				[ "$#" -ge 2 ] && [ -n "$2" ] || usage_error "$1 needs a value; expected $1 VALUE"
				set_option "$1" "$2"
				shift 2
				;;
			*) usage_error "unknown argument: $1; expected --plan-file PATH, --skills-dir DIR, --question, --plans N, --no-plugin-fits, --context-file PATH (with --no-plugin-fits) or --help" ;;
		esac
	done
	[ -n "${plan_file}" ] || usage_error '--plan-file PATH missing; expected --plan-file PATH naming the JSON file; stdin is not read'
	check_context_arg
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
		*)
			skills_dir=$2
			skills_dir_given=1
			;;
	esac
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

# Checks the context file as prepare-agent-prompt.sh does, apart from the digest,
# and sets context_digest to its sha256; exits 2 with one "context file:"
# stderr line per problem, or with an "install:" line 1 when no sha256 tool is
# on PATH, 3 when jq, wc or the tool fails, 5 when a shared check is missing.
read_context() {
	load_context_checks
	path_problem=$(context_path_problem "${context_file}")
	[ -z "${path_problem}" ] || context_error "${path_problem}: ${context_file}; expected ${context_path_expected}"
	[ ! -L "${context_file}" ] ||
		context_error "file is a symlink: ${context_file}; expected the regular file the main thread wrote"
	[ -f "${context_file}" ] && [ -r "${context_file}" ] ||
		context_error "file is missing, unreadable or not a regular file: ${context_file}; expected a readable regular JSON file"
	context_size=$(wc -c <"${context_file}") || install_fault 3 "wc could not count the bytes of ${context_file}; expected a byte count; check wc, then rerun"
	context_size=${context_size##* }
	[ "${context_size}" -le "${context_max_bytes}" ] ||
		context_error "file is ${context_size} bytes: ${context_file}; expected at most ${context_max_bytes} bytes, references and short notes rather than copied text"
	jq empty "${context_file}" </dev/null >/dev/null 2>&1 ||
		context_error "file is not valid JSON: ${context_file}; expected one JSON object; try checking its quotes, commas and brackets, then rerun"
	shape_report=$(jq -rs --arg context_path "${context_file}" -f "${shape_program}" "${context_file}" </dev/null) || {
		install_fault 3 'jq failed on the shape check; expected jq 1.6+; try jq --version, then rerun'
	}
	if [ -n "${shape_report}" ]; then
		printf '%s\n' "${shape_report}" | while IFS= read -r problem; do warn "context file: ${problem}"; done
		exit 2
	fi
	# shellcheck disable=SC2310 # its status is the tool's; a failure exits
	compute_context_digest "${context_file}" ||
		install_fault 3 "${context_digest_tool} could not hash ${context_file}; expected 64 hex digits; check the tool, then rerun"
}

# Sources the shared path checks, finds the shape check and the sha256 tool;
# exits 5 when a shared check is missing, 1 when no sha256 tool is on PATH.
load_context_checks() {
	context_lib=$(script_dir)/../02-agent-context/agent-context-file-checks.sh
	shape_program=$(script_dir)/../02-agent-context/agent-context-validator.jq
	[ -f "${context_lib}" ] && [ -r "${context_lib}" ] ||
		install_fault 5 "shared path check missing; expected ${context_lib}; reinstall the ${PROCEDURE} skill"
	[ -f "${shape_program}" ] && [ -r "${shape_program}" ] ||
		install_fault 5 "shape check missing; expected ${shape_program}; reinstall the ${PROCEDURE} skill"
	# shellcheck source=../02-agent-context/agent-context-file-checks.sh
	. "${context_lib}"
	# shellcheck disable=SC2310 # its status is the lookup result; errexit adds nothing
	find_context_digest_tool ||
		install_fault 1 'sha256sum and shasum missing; expected one of them on PATH; install coreutils (Linux) or use the system shasum (macOS)'
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

# Exits 5 when lib-render's path helpers, which a printed plan includes, are
# not a readable file in the skills folder.
check_render_lib() {
	paths_module="${render_lib_dir}/paths.jq"
	[ -f "${paths_module}" ] && [ -r "${paths_module}" ] ||
		install_fault 5 "path helpers missing; expected ${paths_module}; install the ${RENDER_LIB} skill in ${skills_dir}"
}

# Exits 5 when the flow's shared names, which a dispatch plan and its question
# include, are not a readable file beside this script's folder.
check_names_module() {
	names_module="${names_dir}/${NAMES_MODULE}.jq"
	[ -f "${names_module}" ] && [ -r "${names_module}" ] ||
		install_fault 5 "shared names missing; expected ${names_module}; reinstall the ${PROCEDURE} skill"
}

# Sets listing to list-plugins.sh's plugin lines, its stderr passed through;
# exits 4 when the script is missing and 6 when it fails.
read_listing() {
	list_script="${skills_dir}/${PROCEDURE}/scripts/03-dispatch-plan/list-plugins.sh"
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

# Runs jq program $1 over the slurped input, with lib-render and the shared
# names on jq's module path; a jq failure exits 3.
run_jq() {
	printf '%s' "${slurped}" | jq -rc -L "${render_lib_dir}" -L "${names_dir}" --arg want "${want}" \
		--arg listing "${listing}" --argjson plans "${plans:-1}" \
		--arg context_file "${context_file}" --arg context_digest "${context_digest}" --arg home "${HOME:-}" \
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
names_dir=$(script_dir)/../04-agent-dispatch
want=plan
[ "${want_question}" -eq 0 ] || want=question
[ "${want}" = question ] || check_render_lib
context_digest=''
[ -z "${context_file}" ] || read_context
listing=''
if [ "${no_plugin_fits}" -eq 1 ]; then
	check_program=${COMMON_JQ}${NO_FIT_CHECK_JQ}
	render_program=${PATHS_INCLUDE}${COMMON_JQ}${PRINTED_JQ}${NO_FIT_RENDER_JQ}
	question_program=${COMMON_JQ}${NO_FIT_QUESTION_JQ}
else
	check_names_module
	[ "${want}" = question ] || read_listing
	check_program=${COMMON_JQ}${RENDERABLE_JQ}
	render_program=${PATHS_INCLUDE}${NAMES_INCLUDE}${COMMON_JQ}${PRINTED_JQ}${RENDER_JQ}
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
