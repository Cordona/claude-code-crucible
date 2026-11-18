#!/usr/bin/env sh
# Writes one dispatch plan from the main thread's choices, so the plan JSON is
# never typed by hand, to the gate's plan file and as a plan.made event of its
# effort. The plan pins the fingerprint of the context version
# the approved dispatch cuts; it is checked by dispatch-plan-validator.jq
# against the installed plugins; every problem is named by the option behind
# it, and nothing is written until there is none.
# shellcheck source-path=SCRIPTDIR source-path=SCRIPTDIR/../../../../../../../../framework/core/engine/crucible/scripts/lib source-path=SCRIPTDIR/../../../../../../../../framework/core/main-thread/procedures/procedure-context/scripts
set -eu
umask 077

readonly PROG='generate-dispatch-plan.sh'
readonly PROCEDURE='flow-code-agent-dispatch'
readonly CONTEXT_PROCEDURE='procedure-context'
readonly CRUCIBLE_SKILL='crucible'
readonly EFFORT_SKILL='procedure-effort'
# The exit of a write refused because the effort is not open.
readonly NOT_OPEN_EXIT=6
readonly REQUIRED_TOOLS='cat mktemp mv rm tr wc'
readonly EVENT_TYPE='plan.made'
NL='
'
readonly NL
# The C locale keeps the shell's pattern checks byte-wise on macOS and Linux.
LC_ALL=C
export LC_ALL

# Builds the plan from the options (mode "plan"), or names each validator
# problem by its option (mode "report": one stderr line each). The options
# arrive as positional triples in the order given: kind (agent, task,
# language, framework, load, skip or replan), value, state ("" unless a
# --state followed the plugin). The plan goes through
# crucible's prune, so a key with nothing in it is left out.
# The program is single-quoted on purpose: its $ signs are jq's.
# shellcheck disable=SC2016
readonly PLAN_JQ='
include "prune";
def entries: $ARGS.positional | [range(0; length / 3) as $n
	| {kind: .[$n * 3], value: .[$n * 3 + 1], state: .[$n * 3 + 2]}];
def of_kind($kind): [entries[] | select(.kind == $kind)];
def value_of($kind): of_kind($kind)[0].value;
def item: {plugin: .value} + (if .state == "" then {} else {state} end);
# A --load or --skip plugin installed or named as a procedure goes under
# procedures, any other under standards, where the validator names a wrong kind.
def list_key: ($installed[.value].kind // (if .value | startswith("procedure-") then "procedure" else "standard" end))
	| if . == "procedure" then "procedures" else "standards" end;
def listed($kind; $key): [of_kind($kind)[] | select(list_key == $key)];
def frameworks: of_kind("framework") | sort_by(.value);
def plan:
	{agent: value_of("agent"), tasks: of_kind("task") | map(.value),
	 plugins: {
		load: {language: (of_kind("language") | if . == [] then null else .[0] | item end),
			frameworks: frameworks | map(item),
			standards: listed("load"; "standards") | map(item),
			procedures: listed("load"; "procedures") | map(item)},
		skip: {standards: listed("skip"; "standards") | map(item),
			procedures: listed("skip"; "procedures") | map(item)}},
	 replan: value_of("replan"),
	 context_fingerprint: $context_fingerprint}
	| prune;

# A long value keeps its start and end, where a path differs most; an option
# not given shows as (not given).
def max_shown_chars: 80;
def shown: if . == null then "(not given)"
	else tojson | gsub("[[:cntrl:]]"; "?") | if length > max_shown_chars then .[:40] + "…" + .[-39:] else . end end;
def line($option; $value; $problem): "\($prog): \($option) \($value | shown): \($problem)";
def option: {agent: "--agent", replan: "--replan"}[.];
# The option behind a plugin entry at plugins.<list>.<key>[<n>] (language: no
# index), and its --state when the problem is the state.
def plugin_line($at; $problem):
	(if $at[2] == "language" then ["--language", of_kind("language")[0]]
	 elif $at[2] == "frameworks" then ["--framework", frameworks[$at[3]]]
	 else ["--\($at[1])", listed($at[1]; $at[2])[$at[3]]] end) as [$option, $entry]
	| if $at[-1] == "state" then line("--state"; $entry.state; $problem)
	  else line($option; $entry.value; $problem) end;
def named_line:
	.at as $at | .problem as $problem
	| if $at[0] == "installed" then line("--load or --skip"; $at[1]; $problem)
	  elif $at[0] == "context_fingerprint" then line("--fingerprint"; $context_fingerprint; $problem)
	  elif $at[0] == "tasks" then line("--task"; of_kind("task")[$at[1] // -1].value; $problem)
	  elif $at[0] == "plugins" and ($at[2] == "language" or ($at[3] | type) == "number") then plugin_line($at; $problem)
	  elif ($at[0] | option) != null then line($at[0] | option; value_of($at[0]); $problem)
	  else "\($prog): plan \($at | tojson): \($problem)" end;
def report: $validator_problem_lines | split("\n")[] | select(. != "") | fromjson | named_line;

if $mode == "report" then report else plan end
'

usage() {
	print_page <<EOF
usage: sh ${PROG} --plan-file PATH --agent AGENT --effort FOLDER
           --fingerprint HEX --task TEXT [--task TEXT]... [--language NAME]
           [--framework NAME [--state STATE]]... [--load NAME]...
           [--skip NAME [--state STATE]]... [--replan KIND] [--skills-dir DIR]
       sh ${PROG} --help | -h

Writes one dispatch plan to --plan-file and as a ${EVENT_TYPE} event of the
effort, its body the plan.
Rules: at most one --language; --framework
needs --language; every installed standard and procedure in --load or --skip,
once; no language or framework in --skip; code-reviewer: one lens, the
--language with its --framework plugins, one standard --load, or neither;
code-builder: a --language and a standard --load, never standard-testing;
code-tester: a --language and a standard --load, standard-testing among them.

Options:
  --plan-file PATH    the gate's session plan file, overwritten; folder writable
  --agent AGENT       a dispatched agent of ../agent-dispatch/dispatch-names.jq
  --effort FOLDER     the effort folder, as effort.sh start printed it
  --fingerprint HEX   the FINGERPRINT ${CONTEXT_PROCEDURE}'s context.sh freeze
      --dry-run printed for the effort; the dispatch cuts that version
  --task TEXT         one task, in order; two or more make a group
  --language NAME     the code's language plugin, a list-plugins.sh name
  --framework NAME    a framework plugin, repeatable, needs --language;
      written in plugin-name order
  --load NAME         a standard or procedure plugin to load, in order
  --skip NAME         an installed standard or procedure not loaded, in order
  --state STATE       a step-10 re-plan's plugin list-plugins.sh no longer
      lists, right after its --framework or --skip: invalid or uninstalled
  --replan KIND       a step-10 re-plan: invalid or stop-recommended
  --skills-dir DIR    default \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/skills;
      installed: the valid plugins its list-plugins.sh lists
  CRUCIBLE_HOME       the space, as crucible.sh --help sets
  CLAUDE_CODE_SESSION_ID  required; a lowercase UUID with a session transcript

stdout on exit 0, in order:
  PLAN_FILE: <the --plan-file, absolute>
  PLAN_SHA256: <64 lowercase hex>, for generate-agent-dispatch.sh --plan-sha256
  PLAN_RECORD: <absolute path>, the ${EVENT_TYPE} event, for
    render-dispatch-plan.sh --data Plan=
stderr on exit 3, one line per problem:
  "${PROG}: <option> <value>: <problem>; expected <x>"
list-plugins.sh's stderr passes through; relay it

Exit 1 may leave only --plan-file changed; other failures change nothing.

Exit codes (1, 5, 6, a bad CLAUDE_CODE_SESSION_ID: show stderr and stop):
  0  written; keep PLAN_SHA256, go on
  1  write or digest failed; stderr says if the plan is written
  2  usage error: fix the command; or a bad CLAUDE_CODE_SESSION_ID
  3  invalid input; fix what each stderr line names, rerun
  5  a dependency missing or failing
  ${NOT_OPEN_EXIT}  the effort is not open or its state unknown; nothing written
  129, 130, 143  stopped by HUP, INT or TERM; show it and stop

Dependencies (skills in --skills-dir):
  POSIX sh; jq 1.6+ (macOS: brew install jq; Linux: the distro's jq); base
    system cat, mktemp, mv, rm, tr, wc; sha256sum (Linux: coreutils) or shasum
  this skill's list-plugins.sh; beside this script: dispatch-plan-validator.jq,
    installed-plugins.jq, ../agent-dispatch/dispatch-names.jq
  ${CONTEXT_PROCEDURE}: agent-context-file-checks.sh and what it loads
  ${CRUCIBLE_SKILL}: events.sh, lib/crucible-space.sh, lib/prune.jq
  ${EFFORT_SKILL}: effort.sh
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

# Removes the temp file on every exit.
# shellcheck disable=SC2329 # invoked by the EXIT trap
remove_partial_files() {
	[ -z "${temp_file}" ] || rm -f "${temp_file}"
}

# Handles option $1 when no option value is awaited: sets awaited_option, or exits 2.
take_option() {
	case $1 in
		--help | -h)
			usage
			exit 0
			;;
		--state)
			[ -n "${entry_kind}" ] ||
				usage_error '--state without a --framework or --skip before it; expected each --state right after the --framework or --skip value it marks'
			;;
		--plan-file | --agent | --effort | --fingerprint | --task | --language | --framework | --load | --skip | --replan | --skills-dir) ;;
		*)
			shown_option=$(printable "$1")
			usage_error "unknown option: ${shown_option}; expected --plan-file, --agent, --effort, --fingerprint, --task, --language, --framework, --load, --skip, --state, --replan, --skills-dir or --help"
			;;
	esac
	awaited_option=$1
}

# Takes value $2 of option $1. Sets is_entry_complete=true when the value
# completes a triple, with entry_kind, entry_value and entry_state holding it.
# A --language, --framework, --load or --skip value stays pending for a --state.
take_value() {
	is_entry_complete=false
	case $1 in
		--plan-file | --effort | --fingerprint | --skills-dir)
			check_single_value "$1" "$2"
			case $1 in
				--plan-file) plan_file=$2 ;;
				--effort) given_effort=$2 ;;
				--fingerprint) fingerprint=$2 ;;
				*) skills_dir=$2 ;;
			esac
			;;
		--agent | --replan)
			mark_seen "$1"
			finish_entry "${1#--}" "$2" ''
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
		*)
			[ -n "$2" ] || usage_error '--state is empty; expected --state invalid or --state uninstalled'
			finish_entry "${entry_kind}" "${entry_value}" "$2"
			;;
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
	entry_state=$3
	is_entry_complete=true
}

# Exits 2 on an option left without its value, or a required option missing.
finish_parse() {
	[ -z "${awaited_option}" ] || usage_error "${awaited_option} needs a value; expected ${awaited_option} VALUE"
	[ -n "${plan_file}" ] || usage_error '--plan-file missing; expected --plan-file PATH, the approval gate'\''s session plan file'
	case " ${seen_options} " in
		*' --agent '*) ;;
		*) usage_error '--agent missing; expected --agent AGENT' ;;
	esac
	[ -n "${given_effort}" ] || usage_error '--effort missing; expected --effort FOLDER, the effort folder'
	[ -n "${fingerprint}" ] || usage_error '--fingerprint missing; expected --fingerprint HEX, the FINGERPRINT context.sh freeze --dry-run printed'
	[ "${task_count}" -gt 0 ] || usage_error '--task missing; expected at least one --task TEXT'
	[ -n "${skills_dir}" ] || skills_dir="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/skills"
}

# Exits 5 unless jq, a sha256 tool, list-plugins.sh, the context checks, the
# plan checks, the validator's names module and crucible's prune module are
# in place; loads the context checks (the space rules and the sha256 tool
# among them) and sets the plan checks' paths, prune_lib_dir and list_script.
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
	# shellcheck source=../../../../../../../../framework/core/main-thread/procedures/procedure-context/scripts/agent-context-file-checks.sh
	. "${context_lib}"
	# shellcheck disable=SC2310 # its status says whether the checks loaded; the problem is read here
	context_load_checks "${skills_dir}" || die 5 "${context_load_problem}"
	list_script="${skills_dir}/${PROCEDURE}/scripts/dispatch-plan/list-plugins.sh"
	[ -f "${list_script}" ] && [ -r "${list_script}" ] ||
		die 5 "list-plugins.sh missing; expected ${list_script}; install the ${PROCEDURE} skill or pass the right --skills-dir"
	events_script="${skills_dir}/${CRUCIBLE_SKILL}/scripts/events.sh"
	[ -f "${events_script}" ] && [ -r "${events_script}" ] ||
		die 5 "events.sh missing; expected ${events_script}; install the ${CRUCIBLE_SKILL} skill or pass the right --skills-dir"
	effort_script="${skills_dir}/${EFFORT_SKILL}/scripts/effort.sh"
	[ -f "${effort_script}" ] && [ -r "${effort_script}" ] ||
		die 5 "effort.sh missing; expected ${effort_script}; install the ${EFFORT_SKILL} skill or pass the right --skills-dir"
}

# Sets session_id from CLAUDE_CODE_SESSION_ID by the space rules, or exits 2
# before anything is written.
require_session() {
	# shellcheck disable=SC2310 # its status says whether the session is usable; the problem is read here
	crucible_check_session || usage_error "${crucible_session_problem}"
	session_id=${crucible_session_id}
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

# Sets record_effort to --effort without its trailing slashes when it names an
# effort folder of the space, or sets effort_problem to its stderr line; exits
# 5 when the space root is unusable.
check_effort() {
	effort_problem=''
	# shellcheck disable=SC2310 # its status says whether the root is usable; the problem is read here
	crucible_resolve_root || die 5 "space: ${crucible_root_problem}"
	# shellcheck disable=SC2310 # its status says whether the folder passed; the problem is read below
	if crucible_check_effort_folder "${given_effort}"; then
		record_effort=${crucible_effort}
		return 0
	fi
	record_effort=${given_effort}
	shown_effort=$(jq -nr --arg value "${given_effort}" \
		'$value | tojson | gsub("[[:cntrl:]]"; "?")') ||
		die 5 'jq failed showing the effort path; expected jq 1.6+; try jq --version, then rerun'
	effort_problem="${PROG}: --effort ${shown_effort}: ${crucible_effort_problem}
"
}

# Makes plan_file absolute, so PLAN_FILE prints whole; adds a problem line when
# the plan file's folder is missing or not writable, or PATH is a folder.
check_plan_file() {
	plan_problem=''
	while [ "${plan_file#./}" != "${plan_file}" ]; do plan_file=${plan_file#./}; done
	case ${plan_file} in
		/*) ;;
		*) plan_file="$(pwd)/${plan_file}" ;;
	esac
	plan_folder=${plan_file%/*}
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
		'$value | tojson | gsub("[[:cntrl:]]"; "?")') ||
		die 5 'jq failed showing the plan path; expected jq 1.6+; try jq --version, then rerun'
	plan_problem="${PROG}: --plan-file ${shown_plan}: ${plan_problem}"
}

# Runs PLAN_JQ in mode $1 over the option triples after it.
run_plan_jq() {
	run_mode=$1
	shift
	jq -nr -L "${prune_lib_dir}" --arg prog "${PROG}" --arg mode "${run_mode}" --argjson installed "${installed}" \
		--arg context_fingerprint "${fingerprint}" \
		--arg validator_problem_lines "${validator_problems}" \
		"${PLAN_JQ}" --args -- "$@" </dev/null
}

# Sets plan_json to the plan, or exits 3 after printing every problem the
# effort, the plan file path and the validator find.
build_plan() {
	# shellcheck disable=SC2310 # its status is jq's; a failure exits
	plan_json=$(run_plan_jq plan "$@") ||
		die 5 "jq failed building the plan; expected jq 1.6+ (--args, \$ARGS); try jq --version, then rerun"
	validator_problems=$(printf '%s\n' "${plan_json}" |
		jq -cs --arg format json --argjson installed "${installed}" -f "${plan_validator}") ||
		die 5 'jq failed on the plan validator; expected jq 1.6+; try jq --version, then rerun'
	# shellcheck disable=SC2310 # its status is jq's; a failure exits
	plan_problems=$(run_plan_jq report "$@") ||
		die 5 "jq failed reporting the plan's problems; expected jq 1.6+ (--args, \$ARGS); try jq --version, then rerun"
	all_problems="${effort_problem}${plan_problem:+${plan_problem}
}${plan_problems}"
	[ -n "${all_problems}" ] || return 0
	printf '%s' "${all_problems}" >&2
	[ -z "${plan_problems}" ] || printf '\n' >&2
	exit 3
}

# Exits NOT_OPEN_EXIT unless record_effort is open, as effort.sh state, the
# one owner of the state rule, reads it; a state it cannot read refuses too.
require_open_effort() {
	if effort_state_out=$(sh "${effort_script}" state --effort "${record_effort}" </dev/null); then
		effort_state_status=0
	else
		effort_state_status=$?
	fi
	effort_name=${record_effort##*/}
	# shellcheck disable=SC2310 # the folder passed the space rules, so its name splits
	crucible_split_id "${effort_name}" && effort_name=${crucible_name_rest}
	case ${effort_state_status} in
		0) ;;
		5) die 5 "effort.sh state names a missing dependency above; expected the ${EFFORT_SKILL} skill working; install what it names, then rerun" ;;
		*) die "${NOT_OPEN_EXIT}" "effort ${effort_name}'s state is unknown (effort.sh state exited ${effort_state_status}; its stderr is above); expected an open effort; ask the human to check the effort" ;;
	esac
	effort_state=${effort_state_out%%"${NL}"*}
	case ${effort_state} in
		'STATE: open') ;;
		'STATE: paused' | 'STATE: completed' | 'STATE: dropped')
			die "${NOT_OPEN_EXIT}" "effort ${effort_name} is ${effort_state#STATE: }; expected an open effort; ask the human to reopen it"
			;;
		*) die "${NOT_OPEN_EXIT}" "effort ${effort_name}'s state is unknown (effort.sh state printed no known state); expected an open effort; ask the human to check the effort" ;;
	esac
}

# Writes plan_json to plan_file through a temp file in its folder, or exits 1.
write_plan() {
	temp_file=$(mktemp "${plan_folder}/.${plan_file##*/}.XXXXXX") ||
		die 1 "mktemp could not create a temp file in ${plan_folder}; nothing was written; expected a writable folder ${plan_folder}; check its permissions and free space, then rerun"
	printf '%s\n' "${plan_json}" >"${temp_file}" ||
		die 1 "could not write the temp file ${temp_file}; nothing was written; expected a writable folder ${plan_folder}; check its free space, then rerun"
	mv -f "${temp_file}" "${plan_file}" || die 1 "mv could not move the temp file onto ${plan_file}; nothing was written; expected a writable folder ${plan_folder}; check its permissions and free space, then rerun"
	temp_file=''
}

# Appends the written plan as the effort's plan.made event and sets
# record_file to it; or exits 1. The plan file is written first, so the event
# body is the plan the gate shows.
write_record() {
	if record_file=$(sh "${events_script}" append --effort "${record_effort}" --type "${EVENT_TYPE}" --by "${PROG}" \
		--body-file "${plan_file}" --session "${session_id}" </dev/null); then
		return 0
	fi
	die 1 "events.sh append ${EVENT_TYPE} failed (its stderr is above); the plan file ${plan_file} is written, but no event; fix what it names, then rerun"
}

# Sets context_digest to the sha256 of the written plan in canonical form, the
# one line jq -cS . prints for it, its newline included; or exits 1.
digest_written_plan() {
	canonical_plan=$(jq -cS . "${plan_file}" </dev/null) ||
		die 1 "jq could not read the written plan ${plan_file}; it is written, but its digest is not printed; expected the JSON this run wrote; check that nothing else writes to ${plan_folder}, then rerun"
	# shellcheck disable=SC2310 # its status is the tool's; a failure exits
	compute_stdin_digest <<EOF || die 1 "${context_digest_tool} could not hash the plan ${plan_file}; it is written, but its digest is not printed; expected ${context_digest_tool} to print a sha256; try ${context_digest_tool} on a small file by hand, fix or reinstall it, then rerun"
${canonical_plan}
EOF
}

temp_file='' tools_checked='' record_file='' record_effort='' session_id=''
trap remove_partial_files EXIT
# A signal exits through the EXIT trap, so the temp file goes on every path.
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

[ "$#" -gt 0 ] || {
	usage >&2
	exit 2
}
plan_file='' given_effort='' fingerprint='' skills_dir='' seen_options='' task_count=0
awaited_option='' entry_kind='' entry_value='' entry_state='' validator_problems=''
# Each completed option is appended to the positional parameters as a triple
# (kind, value, state); "for" walks the original arguments only, which are
# shifted away after the loop. A plugin with no --state after it completes
# with state "" at the next option or at the end.
argument_count=$#
for argument do
	if [ -z "${awaited_option}" ]; then
		if [ -n "${entry_kind}" ] && [ "${argument}" != --state ]; then
			set -- "$@" "${entry_kind}" "${entry_value}" ''
			entry_kind='' entry_value=''
		fi
		take_option "${argument}"
		continue
	fi
	take_value "${awaited_option}" "${argument}"
	awaited_option=''
	[ "${is_entry_complete}" = true ] || continue
	set -- "$@" "${entry_kind}" "${entry_value}" "${entry_state}"
	entry_kind='' entry_value='' entry_state=''
done
if [ -n "${entry_kind}" ]; then
	set -- "$@" "${entry_kind}" "${entry_value}" ''
fi
finish_parse
shift "${argument_count}"

require_tools
load_dependencies
require_session
read_installed
check_effort
check_plan_file
build_plan "$@"
require_open_effort
write_plan
digest_written_plan
write_record
printf 'PLAN_FILE: %s\nPLAN_SHA256: %s\nPLAN_RECORD: %s\n' "${plan_file}" "${context_digest}" "${record_file}"
