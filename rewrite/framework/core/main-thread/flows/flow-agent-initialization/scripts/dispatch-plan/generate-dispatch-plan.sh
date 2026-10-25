#!/usr/bin/env sh
# Writes one dispatch plan from the main thread's choices, so the plan JSON is
# never typed by hand, to the gate's plan file and as a plans item of the
# context file's effort. The plan is built, its context file checked by
# procedure-context's agent-context-file-checks.sh, agent-context-validator.jq
# and context-versions.sh, and the plan
# checked by dispatch-plan-validator.jq against the installed plugins; every
# problem is named by the option behind it, and nothing is written until there
# is none.
# shellcheck source-path=SCRIPTDIR source-path=SCRIPTDIR/../../../../../engine/crucible/scripts/lib source-path=SCRIPTDIR/../../../../procedures/procedure-context/scripts
set -eu
umask 077

readonly PROG='generate-dispatch-plan.sh'
readonly PROCEDURE='flow-agent-initialization'
readonly CONTEXT_PROCEDURE='procedure-context'
readonly CRUCIBLE_SKILL='crucible'
readonly REQUIRED_TOOLS='cat mktemp mv rm tr wc'
# Leads the problem of a context version no longer its effort's latest, so a
# caller matches it exactly: the Agent hook's KIND word for the same problem.
readonly CONTEXT_STALE_TOKEN='CONTEXT-STALE'
readonly RECORD_KIND='plans'
readonly RECORD_LABEL='dispatch-plan'
# The C locale keeps the shell's pattern checks byte-wise on macOS and Linux.
LC_ALL=C
export LC_ALL

# Builds the plan from the options (mode "plan"), or names each validator
# problem by its option (mode "report": one stderr line each). The options
# arrive as positional triples in the order given: kind (agent, mode, task,
# language, framework, load, skip, load_reason or replan), value, reason (""
# but for language, framework, load and skip). The plan goes through
# crucible's prune, so a key with nothing in it is left out.
# The program is single-quoted on purpose: its $ signs are jq's.
# shellcheck disable=SC2016
readonly PLAN_JQ='
include "prune";
def entries: $ARGS.positional | [range(0; length / 3) as $n
	| {kind: .[$n * 3], value: .[$n * 3 + 1], reason: .[$n * 3 + 2]}];
def of_kind($kind): [entries[] | select(.kind == $kind)];
def value_of($kind): of_kind($kind)[0].value;
def item: {plugin: .value, reason};
# A --load or --skip plugin installed or named as a procedure goes under
# procedures, any other under standards, where the validator names a wrong kind.
def slot: ($installed[.value].kind // (if .value | startswith("procedure-") then "procedure" else "standard" end))
	| if . == "procedure" then "procedures" else "standards" end;
def listed($kind; $key): [of_kind($kind)[] | select(slot == $key)];
def frameworks: of_kind("framework") | sort_by(.value);
def plan:
	{agent: value_of("agent"), mode: value_of("mode"), tasks: of_kind("task") | map(.value),
	 plugins: {
		load: {language: (of_kind("language") | if . == [] then null else .[0] | item end),
			frameworks: frameworks | map(item),
			standards: listed("load"; "standards") | map(item),
			procedures: listed("load"; "procedures") | map(item)},
		skip: {standards: listed("skip"; "standards") | map(item),
			procedures: listed("skip"; "procedures") | map(item)},
		load_reason: value_of("load_reason")},
	 replan: value_of("replan"),
	 context: {path: $context_path, sha256: $context_digest}}
	| prune;

# A long value keeps its start and end, where a path differs most; an option
# not given shows as (not given).
def max_shown_chars: 80;
def shown: if . == null then "(not given)"
	else tojson | gsub("[[:cntrl:]]"; "?") | if length > max_shown_chars then .[:40] + "…" + .[-39:] else . end end;
def line($option; $value; $problem): "\($prog): \($option) \($value | shown): \($problem)";
def option: {agent: "--agent", mode: "--mode", replan: "--replan"}[.];
# The option behind a plugin entry at plugins.<list>.<slot>[<n>] (language: no
# index), and its --reason when the problem is the reason.
def plugin_line($at; $problem):
	(if $at[2] == "language" then ["--language", of_kind("language")[0]]
	 elif $at[2] == "frameworks" then ["--framework", frameworks[$at[3]]]
	 else ["--\($at[1])", listed($at[1]; $at[2])[$at[3]]] end) as [$option, $entry]
	| if $at[-1] == "reason" then line("--reason"; $entry.reason; $problem)
	  else line($option; $entry.value; $problem) end;
def named_line:
	.at as $at | .problem as $problem
	| if $at[0] == "installed" then line("--load or --skip"; $at[1]; $problem)
	  elif $at[0] == "context" then line("--context-file"; $context_path; $problem)
	  elif $at[0] == "tasks" then line("--task"; of_kind("task")[$at[1] // -1].value; $problem)
	  elif $at[:2] == ["plugins", "load_reason"] then line("--load-reason"; value_of("load_reason"); $problem)
	  elif $at[0] == "plugins" and ($at[2] == "language" or ($at[3] | type) == "number") then plugin_line($at; $problem)
	  elif ($at[0] | option) != null then line($at[0] | option; value_of($at[0]); $problem)
	  else "\($prog): plan \($at | tojson): \($problem)" end;
def report: $validator_problem_lines | split("\n")[] | select(. != "") | fromjson | named_line;

if $mode == "report" then report else plan end
'

usage() {
	print_page <<EOF
usage: sh ${PROG} --plan-file PATH --agent AGENT --mode BUILD|TEST --context-file CTX
           --task TEXT [--task TEXT]... [--language NAME --reason LINE]
           [--framework NAME --reason LINE]... [--load NAME --reason LINE]...
           [--skip NAME --reason LINE]... [--load-reason LINE]
           [--replan KIND] [--skills-dir DIR]
       sh ${PROG} --help | -h

Writes one dispatch plan to --plan-file and a new ${RECORD_KIND} item of the
context file's effort.
Keys in order: agent, mode, tasks, plugins {load {language, frameworks,
standards, procedures}, skip {standards, procedures}, load_reason}, replan,
context; each plugin {plugin, reason}; empty keys left out.
Rules (dispatch-plan-validator.jq): at most one --language; --framework
needs --language; every installed standard and procedure in --load or --skip,
once; no language or framework in --skip; code-reviewer: one lens, the
--language with its --framework plugins, one standard --load, or neither.

Options:
  --plan-file PATH    the gate's session plan file, overwritten; folder writable
  --agent AGENT       a dispatched agent of ../agent-dispatch/dispatch-names.jq
  --mode BUILD|TEST   the dispatch mode
  --context-file CTX  the effort's latest context file, in its folder, passing
                      procedure-context's checks; path + sha256 go in the plan
  --task TEXT         one task, in order; two or more make a group
  --language NAME     the code's language plugin, a list-plugins.sh name
  --framework NAME    a framework plugin, repeatable, needs --language;
                      written in plugin-name order
  --load NAME         a standard or procedure plugin to load, in order
  --skip NAME         an installed standard or procedure not loaded, in order
  --reason LINE       why; exactly one right after each --language,
                      --framework, --load and --skip
  --load-reason LINE  why nothing loads: required with no --language,
                      --framework or --load, refused with one
  --replan KIND       a step-10 re-plan: invalid or stop-recommended
  --skills-dir DIR    default \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/skills;
                      installed: the valid plugins its list-plugins.sh lists
  CRUCIBLE_HOME       the space, as crucible.sh --help sets

stdout on exit 0, in order:
  PLAN_FILE: <the --plan-file as given>
  PLAN_SHA256: <64 lowercase hex>, for generate-agent-dispatch.sh --plan-sha256
  PLAN_RECORD: <absolute path>, the ${RECORD_KIND} item, for
    render-dispatch-plan.sh --data Plan=
stderr on exit 3: one line per problem, all listed:
  "${PROG}: <option> <value>: <problem>; expected <x>"
list-plugins.sh's stderr passes through, to relay

Exit 0: --plan-file and the item hold the plan; 1: only --plan-file may have
changed; others: nothing changed. Else only crucible.sh new changes the space;
nothing is left behind (a SIGKILL aside). Reads only the context file, its
folder's names for a version file, the plan it wrote, and list-plugins.sh's.

Exit codes:
  0  written; keep PLAN_SHA256 and go on
  1  the write or digest failed, stderr saying if the plan is written;
     show stderr and stop
  2  usage error: fix the command
  3  invalid input; fix what each stderr line names, then rerun
     ${CONTEXT_STALE_TOKEN}  leads a problem: a newer context version exists;
       rerun with it as --context-file
  5  a dependency missing or failing; show stderr and stop
  129, 130, 143  stopped by HUP, INT or TERM; show it and stop

Dependencies (skills in --skills-dir):
  POSIX sh; jq 1.6+ (macOS: brew install jq; Linux: the distro's jq)
  cat, mktemp, mv, rm, tr, wc (base system); sha256sum (Linux: coreutils)
    or shasum (macOS: built in)
  this skill's list-plugins.sh; beside this script: dispatch-plan-validator.jq,
    installed-plugins.jq, ../agent-dispatch/dispatch-names.jq
  ${CONTEXT_PROCEDURE}: agent-context-file-checks.sh, agent-context-validator.jq,
    agent-context-url.jq, context-versions.sh
  ${CRUCIBLE_SKILL}: crucible.sh, lib/crucible-space.sh, lib/prune.jq
EOF
}

# Prints stdin with builtins only, so the page prints with cat missing.
print_page() {
	while IFS= read -r page_line; do
		printf '%s\n' "${page_line}"
	done
}

warn() {
	printf '%s: %s\n' "${PROG}" "$1" >&2
}

die() {
	warn "$2"
	exit "$1"
}

# Exits 5 naming the first of REQUIRED_TOOLS missing from PATH; checks once.
require_tools() {
	[ -z "${tools_checked}" ] || return 0
	for tool in ${REQUIRED_TOOLS}; do
		command -v "${tool}" >/dev/null 2>&1 ||
			die 5 "${tool} missing; expected it on PATH; install your base system's ${tool}"
	done
	tools_checked=true
}

usage_error() {
	warn "$1"
	printf "Try '%s --help'.\n" "${PROG}" >&2
	exit 2
}

# Prints $1 with each control character as "?", so a value can't split a stderr line.
# A usage error can reach it before the tool check, so it checks the tools first.
printable() {
	require_tools
	printf '%s' "$1" | tr '[:cntrl:]' '?'
}

# Removes the temp file, and the plan record on a failed or stopped run.
# shellcheck disable=SC2329 # invoked by the EXIT trap
remove_partial_files() {
	exit_status=$?
	[ -z "${temp_file}" ] || rm -f "${temp_file}"
	[ "${exit_status}" -eq 0 ] || [ -z "${record_file}" ] || rm -f "${record_file}"
}

# Handles option $1 when no option value is awaited: sets awaited_option, or exits 2.
take_option() {
	case $1 in
		--help | -h)
			usage
			exit 0
			;;
		--reason)
			[ -n "${entry_kind}" ] ||
				usage_error '--reason without a --language, --framework, --load or --skip before it; expected each --reason right after one of their values'
			;;
		--plan-file | --agent | --mode | --context-file | --task | --language | --framework | --load | --skip | --load-reason | --replan | --skills-dir)
			[ -z "${entry_kind}" ] || missing_reason_error
			;;
		*)
			shown_option=$(printable "$1")
			usage_error "unknown option: ${shown_option}; expected --plan-file, --agent, --mode, --context-file, --task, --language, --framework, --load, --skip, --reason, --load-reason, --replan, --skills-dir or --help"
			;;
	esac
	awaited_option=$1
}

# Exits 2 naming the pending --language, --framework, --load or --skip, which has no --reason.
missing_reason_error() {
	shown_entry=$(printable "${entry_value}")
	usage_error "--${entry_kind} ${shown_entry} has no --reason; expected --reason LINE right after it"
}

# Takes value $2 of option $1. Sets is_entry_complete=true when the value
# completes a triple, with entry_kind, entry_value and entry_reason holding it.
take_value() {
	is_entry_complete=false
	case $1 in
		--plan-file | --context-file | --skills-dir)
			check_single_value "$1" "$2"
			case $1 in
				--plan-file) plan_file=$2 ;;
				--context-file) context_file=$2 ;;
				*) skills_dir=$2 ;;
			esac
			;;
		--agent | --mode | --load-reason | --replan)
			mark_seen "$1"
			case $1 in
				--load-reason) option_kind=load_reason ;;
				*) option_kind=${1#--} ;;
			esac
			finish_entry "${option_kind}" "$2" ''
			;;
		--task)
			task_count=$((task_count + 1))
			finish_entry task "$2" ''
			;;
		--language | --framework | --load | --skip)
			[ "$1" != --language ] || mark_language
			entry_kind=${1#--}
			entry_value=$2
			;;
		*) finish_entry "${entry_kind}" "${entry_value}" "$2" ;;
	esac
}

# Records --language in seen_options, or exits 2 on a second one.
mark_language() {
	case " ${seen_options} " in
		*' --language '*) usage_error '--language given twice; expected one --language: a plan loads at most one language, its frameworks as --framework' ;;
		*) seen_options="${seen_options} --language" ;;
	esac
}

# Exits 2 when option $1 was given before, or its value $2 is empty.
check_single_value() {
	mark_seen "$1"
	[ -n "$2" ] || usage_error "$1 is empty; expected $1 VALUE"
}

# Records option $1 in seen_options, or exits 2 when it is there already.
mark_seen() {
	case " ${seen_options} " in
		*" $1 "*) usage_error "$1 given twice; expected at most one $1" ;;
		*) seen_options="${seen_options} $1" ;;
	esac
}

finish_entry() {
	entry_kind=$1
	entry_value=$2
	entry_reason=$3
	is_entry_complete=true
}

# Exits 2 on an option left without its value or its --reason, or a required option missing.
finish_parse() {
	[ -z "${awaited_option}" ] || usage_error "${awaited_option} needs a value; expected ${awaited_option} VALUE"
	[ -z "${entry_kind}" ] || missing_reason_error
	[ -n "${plan_file}" ] || usage_error '--plan-file missing; expected --plan-file PATH, the approval gate'\''s session plan file'
	case " ${seen_options} " in
		*' --agent '*) ;;
		*) usage_error '--agent missing; expected --agent AGENT' ;;
	esac
	case " ${seen_options} " in
		*' --mode '*) ;;
		*) usage_error '--mode missing; expected --mode BUILD or --mode TEST' ;;
	esac
	[ -n "${context_file}" ] || usage_error '--context-file missing; expected --context-file CTX, the effort'\''s context file'
	[ "${task_count}" -gt 0 ] || usage_error '--task missing; expected at least one --task TEXT'
	[ -n "${skills_dir}" ] || skills_dir="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/skills"
}

# Exits 5 unless jq, a sha256 tool, list-plugins.sh, the context checks, the
# plan checks, the validator's names module and crucible's prune module are
# in place; loads the context read checks and sets the plan checks' paths,
# prune_lib_dir and list_script.
load_dependencies() {
	command -v jq >/dev/null 2>&1 ||
		die 5 'jq missing; expected jq 1.6+ on PATH; install it (macOS: brew install jq; Linux: the distro'\''s jq package)'
	context_lib="${skills_dir}/${CONTEXT_PROCEDURE}/scripts/agent-context-file-checks.sh"
	[ -f "${context_lib}" ] && [ -r "${context_lib}" ] ||
		die 5 "context check missing; expected ${context_lib}; install the ${CONTEXT_PROCEDURE} skill or pass the right --skills-dir"
	plan_dir=$(script_dir)
	plan_validator="${plan_dir}/dispatch-plan-validator.jq"
	installed_program="${plan_dir}/installed-plugins.jq"
	# dispatch-plan-validator.jq includes it; a missing copy would read as a jq fault.
	dispatch_names="${plan_dir}/../agent-dispatch/dispatch-names.jq"
	for shared_file in "${plan_validator}" "${installed_program}" "${dispatch_names}"; do
		[ -f "${shared_file}" ] && [ -r "${shared_file}" ] ||
			die 5 "shared check missing; expected ${shared_file}; reinstall the ${PROCEDURE} skill"
	done
	prune_lib_dir="${skills_dir}/${CRUCIBLE_SKILL}/scripts/lib"
	[ -f "${prune_lib_dir}/prune.jq" ] && [ -r "${prune_lib_dir}/prune.jq" ] ||
		die 5 "prune module missing; expected ${prune_lib_dir}/prune.jq; install the ${CRUCIBLE_SKILL} skill or pass the right --skills-dir"
	# shellcheck source=../../../../procedures/procedure-context/scripts/agent-context-file-checks.sh
	. "${context_lib}"
	# shellcheck disable=SC2310 # its status says whether the checks loaded; the problem is read here
	context_load_checks "${skills_dir}" || die 5 "${context_load_problem}"
	list_script="${skills_dir}/${PROCEDURE}/scripts/dispatch-plan/list-plugins.sh"
	[ -f "${list_script}" ] && [ -r "${list_script}" ] ||
		die 5 "list-plugins.sh missing; expected ${list_script}; install the ${PROCEDURE} skill or pass the right --skills-dir"
	crucible_script="${skills_dir}/${CRUCIBLE_SKILL}/scripts/crucible.sh"
	[ -f "${crucible_script}" ] && [ -r "${crucible_script}" ] ||
		die 5 "crucible.sh missing; expected ${crucible_script}; install the ${CRUCIBLE_SKILL} skill or pass the right --skills-dir"
}

# Prints the folder this script was run from (".", when run by a bare name).
script_dir() {
	case $0 in
		*/*) printf '%s' "${0%/*}" ;;
		*) printf '.' ;;
	esac
}

# Sets installed to the installed plugins as JSON; list-plugins.sh's stderr is
# passed through, its exit 1 (no plugin) is an empty list, its exit 3 leaves
# the invalid plugins out, and any other exit but 0 exits 5.
read_installed() {
	if listing=$(sh "${list_script}" --max-lines 0 --skills-dir "${skills_dir}" </dev/null); then
		list_status=0
	else
		list_status=$?
	fi
	case ${list_status} in
		0 | 1 | 3) ;;
		*) die 5 "list-plugins.sh failed (exit ${list_status}); expected exit 0, 1 or 3; fix what its stderr above names, or reinstall ${PROCEDURE}" ;;
	esac
	installed=$(jq -nc --arg listing "${listing}" -f "${installed_program}") ||
		die 5 'jq failed reading the plugin list; expected jq 1.6+; try jq --version, then rerun'
}

# Sets context_problems to one problem line per finding of the context file's
# checks, and context_digest to its sha256 when they pass.
check_context_file() {
	context_problems=''
	context_digest=''
	path_problem=$(context_path_problem "${context_file}")
	if [ -n "${path_problem}" ]; then
		add_context_problem "${path_problem}; expected ${context_path_expected}"
		return 0
	fi
	# shellcheck disable=SC2310 # its status is a tool's; a failure has printed its cause
	context_read_problem "${context_file}" ||
		die 5 'a tool failed on the context read checks (its stderr is above); expected jq 1.6+ and wc; try jq --version, then rerun'
	if [ "${context_read_fault}" = stale ]; then
		add_context_problem "${CONTEXT_STALE_TOKEN} ${context_read_text}; plan with it"
		return 0
	fi
	if [ -n "${context_read_fault}" ]; then
		add_context_problem "${context_read_text}"
		return 0
	fi
	# shellcheck disable=SC2310 # its status is the tool's; a failure exits
	compute_context_digest "${context_file}" ||
		die 5 "${context_digest_tool} could not hash ${context_file}; expected 64 hex digits; check the tool, then rerun"
	find_record_effort
}

# Sets record_effort to the effort folder the context file lies in, or adds a
# context problem; exits 5 when the space root is unusable.
find_record_effort() {
	# shellcheck disable=SC2310 # its status says whether the root is usable; the problem is read here
	crucible_resolve_root || die 5 "space: ${crucible_root_problem}"
	# shellcheck disable=SC2310 # its status says whether the path is in an effort
	if crucible_effort_of "${context_file}"; then
		record_effort=${crucible_effort}
		return 0
	fi
	add_context_problem "not in an effort folder; expected the context file of an effort in ${crucible_root}/efforts/"
}

# Appends problem $1 of the context file to context_problems as a stderr line,
# the path shown as the plan problems show a value.
add_context_problem() {
	shown_context=$(jq -nr --arg value "${context_file}" \
		'$value | tojson | gsub("[[:cntrl:]]"; "?") | if length > 80 then .[:40] + "…" + .[-39:] else . end') ||
		die 5 'jq failed showing the context path; expected jq 1.6+; try jq --version, then rerun'
	context_problems="${context_problems}${PROG}: --context-file ${shown_context}: $1
"
}

# Adds a problem line when the plan file's folder is missing or not writable, or PATH is a folder.
check_plan_file() {
	plan_problem=''
	case ${plan_file} in
		*/*) plan_folder=${plan_file%/*} ;;
		*) plan_folder=. ;;
	esac
	[ -n "${plan_folder}" ] || plan_folder=/
	if [ -d "${plan_file}" ]; then
		plan_problem='is a folder; expected the plan file'\''s path'
	elif [ ! -d "${plan_folder}" ] || [ ! -w "${plan_folder}" ]; then
		plan_problem='has no writable folder; expected a path in an existing, writable folder'
	fi
	if [ -z "${plan_problem}" ]; then
		return 0
	fi
	shown_plan=$(jq -nr --arg value "${plan_file}" \
		'$value | tojson | gsub("[[:cntrl:]]"; "?") | if length > 80 then .[:40] + "…" + .[-39:] else . end') ||
		die 5 'jq failed showing the plan path; expected jq 1.6+; try jq --version, then rerun'
	plan_problem="${PROG}: --plan-file ${shown_plan}: ${plan_problem}"
}

# Runs PLAN_JQ in mode $1 over the option triples after it.
run_plan_jq() {
	run_mode=$1
	shift
	jq -nr -L "${prune_lib_dir}" --arg prog "${PROG}" --arg mode "${run_mode}" --argjson installed "${installed}" \
		--arg context_path "${context_file}" --arg context_digest "${digest_in_plan}" \
		--arg validator_problem_lines "${validator_problems}" \
		"${PLAN_JQ}" --args -- "$@" </dev/null
}

# Sets plan_json to the plan, or exits 3 after printing every problem the
# context file, the plan file path and the validator find.
build_plan() {
	# A context file that failed its checks has no digest; a stand-in keeps the
	# plan checks to the plan, the context problems being reported already.
	digest_in_plan=${context_digest:-0000000000000000000000000000000000000000000000000000000000000000}
	# shellcheck disable=SC2310 # its status is jq's; a failure exits
	plan_json=$(run_plan_jq plan "$@") ||
		die 5 "jq failed building the plan; expected jq 1.6+ (--args, \$ARGS); try jq --version, then rerun"
	validator_problems=$(printf '%s\n' "${plan_json}" |
		jq -cs --arg format json --argjson installed "${installed}" -f "${plan_validator}") ||
		die 5 'jq failed on the plan validator; expected jq 1.6+; try jq --version, then rerun'
	# shellcheck disable=SC2310 # its status is jq's; a failure exits
	plan_problems=$(run_plan_jq report "$@") ||
		die 5 "jq failed reporting the plan's problems; expected jq 1.6+ (--args, \$ARGS); try jq --version, then rerun"
	all_problems="${context_problems}${plan_problem:+${plan_problem}
}${plan_problems}"
	[ -n "${all_problems}" ] || return 0
	printf '%s' "${all_problems}" >&2
	[ -z "${plan_problems}" ] || printf '\n' >&2
	exit 3
}

# Writes plan_json to plan_file through a temp file in its folder, or exits 1.
write_plan() {
	temp_file=$(mktemp "${plan_folder}/.${plan_file##*/}.XXXXXX") ||
		die 1 "mktemp could not create a temp file in ${plan_folder}; nothing was written; expected a writable folder ${plan_folder}; try checking its permissions and free space, then rerun"
	printf '%s\n' "${plan_json}" >"${temp_file}" ||
		die 1 "could not write the temp file ${temp_file}; nothing was written; expected a writable folder ${plan_folder}; try checking its free space, then rerun"
	mv -f "${temp_file}" "${plan_file}" || die 1 "mv could not move the temp file onto ${plan_file}; nothing was written; expected a writable folder ${plan_folder}; try checking its permissions and free space, then rerun"
	temp_file=''
}

# Writes plan_json to a new plans item of the context file's effort, through
# crucible.sh new, and sets record_file to it; or exits 1, nothing written.
write_record() {
	new_record=$(sh "${crucible_script}" new --kind "${RECORD_KIND}" --effort "${record_effort}" --label "${RECORD_LABEL}" </dev/null) ||
		die 1 "crucible.sh new --kind ${RECORD_KIND} failed (its stderr is above); nothing was written; expected an empty file in ${record_effort}/${RECORD_KIND}/; fix what it names, then rerun"
	case ${new_record} in
		"${record_effort}/${RECORD_KIND}/"*.json) record_file=${new_record} ;;
		*) die 1 "crucible.sh new printed no file of ${record_effort}/${RECORD_KIND}/; nothing was written; expected crucible.sh to use the same CRUCIBLE_HOME; try exporting CRUCIBLE_HOME once for both, then rerun" ;;
	esac
	printf '%s\n' "${plan_json}" >"${record_file}" ||
		die 1 "could not write the plan record ${record_file}; nothing was written; expected a writable folder ${record_effort}/${RECORD_KIND}; try checking its free space, then rerun"
}

# Sets context_digest to the sha256 of the written plan in canonical form, the
# one line jq -cS . prints for it, its newline included; or exits 1. The gate
# record is the plan with "v": 1 added, so jq -cS 'del(.v)' of it hashes the same.
digest_written_plan() {
	canonical_plan=$(jq -cS . "${plan_file}" </dev/null) ||
		die 1 "jq could not read the written plan ${plan_file}; it is written, but its digest is not printed; expected the JSON this run wrote; try checking that nothing else writes to ${plan_folder}, then rerun"
	# shellcheck disable=SC2310 # its status is the tool's; a failure exits
	compute_stdin_digest <<EOF || die 1 "${context_digest_tool} could not hash the plan ${plan_file}; it is written, but its digest is not printed; expected ${context_digest_tool} to print a sha256; try ${context_digest_tool} on a small file by hand, fix or reinstall it, then rerun"
${canonical_plan}
EOF
}

temp_file='' tools_checked='' record_file='' record_effort=''
trap remove_partial_files EXIT
# A signal exits through the EXIT trap, so the temp file goes on every path.
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

[ "$#" -gt 0 ] || {
	usage >&2
	exit 2
}
plan_file='' context_file='' skills_dir='' seen_options='' task_count=0
awaited_option='' entry_kind='' entry_value='' entry_reason='' validator_problems=''
# Each completed option is appended to the positional parameters as a triple
# (kind, value, reason); "for" walks the original arguments only, which are
# shifted away after the loop.
argument_count=$#
for argument do
	if [ -z "${awaited_option}" ]; then
		take_option "${argument}"
		continue
	fi
	take_value "${awaited_option}" "${argument}"
	awaited_option=''
	[ "${is_entry_complete}" = true ] || continue
	set -- "$@" "${entry_kind}" "${entry_value}" "${entry_reason}"
	entry_kind='' entry_value='' entry_reason=''
done
finish_parse
shift "${argument_count}"

require_tools
load_dependencies
read_installed
check_context_file
check_plan_file
build_plan "$@"
write_record
write_plan
digest_written_plan
printf 'PLAN_FILE: %s\nPLAN_SHA256: %s\nPLAN_RECORD: %s\n' "${plan_file}" "${context_digest}" "${record_file}"
