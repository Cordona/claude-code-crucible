#!/usr/bin/env sh
# Writes one dispatch plan from the main thread's choices, so the plan JSON is
# never typed by hand. The plan is built, its context file checked by
# 02-agent-context/agent-context-file-checks.sh and agent-context-validator.jq,
# and the plan
# checked by dispatch-plan-validator.jq against the installed plugins; every
# problem is named by the option behind it, and nothing is written until there
# is none. technology is computed from the loaded tech plugin.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077

readonly PROG='generate-dispatch-plan.sh'
readonly PROCEDURE='flow-agent-initialization'
readonly REQUIRED_TOOLS='cat mktemp mv rm tr wc'
# The C locale keeps the shell's pattern checks byte-wise on macOS and Linux.
LC_ALL=C
export LC_ALL

# Builds the plan from the options (mode "plan"), or names each validator
# problem by its option (mode "report": one stderr line each). The options
# arrive as positional triples in the order given: kind (agent, mode, task,
# load, skip, loaded_reason or replan), value, reason ("" but for load and skip).
# The program is single-quoted on purpose: its $ signs are jq's.
# shellcheck disable=SC2016
readonly PLAN_JQ='
def entries: $ARGS.positional | [range(0; length / 3) as $n
	| {kind: .[$n * 3], value: .[$n * 3 + 1], reason: .[$n * 3 + 2]}];
def of_kind($kind): [entries[] | select(.kind == $kind)];
def value_of($kind): of_kind($kind)[0].value;
def plugins($kind): of_kind($kind) | map({plugin: .value, reason});
def technology($loaded): first($loaded[] | $installed[.plugin] // empty | select(.kind == "tech") | .label) // "none";
def plan:
	plugins("load") as $loaded
	| {agent: value_of("agent"), mode: value_of("mode"), technology: technology($loaded),
	   tasks: of_kind("task") | map(.value), loaded: $loaded}
	+ (if of_kind("loaded_reason") == [] then {} else {loaded_reason: value_of("loaded_reason")} end)
	+ {not_loaded: plugins("skip")}
	+ (if of_kind("replan") == [] then {} else {replan: value_of("replan")} end)
	+ {context: {path: $context_path, sha256: $context_digest}};

# A long value keeps its start and end, where a path differs most; an option
# not given shows as (not given).
def max_shown_chars: 80;
def shown: if . == null then "(not given)"
	else tojson | gsub("[[:cntrl:]]"; "?") | if length > max_shown_chars then .[:40] + "…" + .[-39:] else . end end;
def line($option; $value; $problem): "\($prog): \($option) \($value | shown): \($problem)";
def option: {agent: "--agent", mode: "--mode", task: "--task", load: "--load", skip: "--skip",
	loaded_reason: "--loaded-reason", replan: "--replan"}[.];
def list_kind: {tasks: "task", loaded: "load", not_loaded: "skip"}[.];
def named_line:
	.at as $at | .problem as $problem
	| if $at[0] == "installed" then line("--load or --skip"; $at[1]; $problem)
	  elif $at[0] == "context" then line("--context-file"; $context_path; $problem)
	  elif ($at[0] | list_kind) != null then
		($at[0] | list_kind) as $kind | of_kind($kind)[$at[1] // -1] as $entry
		| if $at[2] == "reason" then line("--reason"; $entry.reason; $problem)
		  else line($kind | option; $entry.value; $problem) end
	  elif ($at[0] | option) != null then line($at[0] | option; value_of($at[0]); $problem)
	  else "\($prog): plan \($at | tojson): \($problem)" end;
def report: $validator_problem_lines | split("\n")[] | select(. != "") | fromjson | named_line;

if $mode == "report" then report else plan end
'

usage() {
	cat <<EOF
Usage: sh ${PROG} --plan-file PATH --agent AGENT --mode BUILD|TEST --context-file CTX
           --task TEXT [--task TEXT]... [--load NAME --reason LINE]...
           [--skip NAME --reason LINE]... [--loaded-reason LINE]
           [--replan invalid|stop-recommended] [--skills-dir DIR]
       sh ${PROG} --help|-h
With no argument it prints this help on stderr and exits 2.

Writes one dispatch plan, the JSON render-dispatch-plan.sh renders, to PATH
(the approval gate's session plan file, overwritten), then prints its path
and its PLAN_SHA256.
Every option is checked first; on any problem nothing is written.

  --plan-file PATH  the file to write; its folder must exist and be writable.
                    It is written to a temp file in that folder, then moved
                    onto PATH.
  --agent AGENT     the agent the plan dispatches; "main thread" means direct
                    implementation.
  --mode MODE       BUILD or TEST.
  --context-file CTX  the effort's context file, checked as prepare-agent-prompt.sh
                    checks it, apart from the digest: the path checks of
                    scripts/02-agent-context/agent-context-file-checks.sh, a readable regular
                    file that is not a symlink, at most the size cap of
                    agent-context-file-checks.sh, and
                    scripts/02-agent-context/agent-context-validator.jq. Its path
                    and sha256 go into the plan's context.
  --task TEXT       one task, kept in order; one task is one dispatch, two or
                    more a group.
  --load NAME       a plugin to load, by its list-plugins.sh name, kept in order.
  --skip NAME       an installed plugin not loaded, kept in order.
  --reason LINE     why: exactly one right after each --load and --skip.
  --loaded-reason LINE  why no plugin is loaded: required with no --load,
                    refused with one.
  --replan KIND     a step-10 re-plan: invalid or stop-recommended.
  --skills-dir DIR  the skills folder; defaults to
                    \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/skills. The installed
                    plugins are the plugin lines of
                    DIR/${PROCEDURE}/scripts/03-dispatch-plan/list-plugins.sh --max-lines 0,
                    of kind tech, standard or procedure (its stderr is passed
                    through; its exit 1, no plugin, is an empty list, and its
                    exit 3 leaves invalid plugins out).

The plan (one JSON object):
  {"agent": str, "mode": "BUILD"|"TEST", "technology": str,
   "tasks": [str, ...],
   "loaded": [{"plugin": str, "reason": str}, ...],
   "loaded_reason": str,             only when given
   "not_loaded": [{"plugin": str, "reason": str}, ...],
   "replan": "invalid"|"stop-recommended",   only when given
   "context": {"path": <CTX>, "sha256": <64 lowercase hex of CTX>}}
technology is computed: the list-plugins.sh label of the loaded tech plugin,
or "none" when none is loaded.
The plan's rules are scripts/03-dispatch-plan/dispatch-plan-validator.jq's: among
them, every installed plugin is loaded or skipped (the main thread gives each
skip its reason; nothing is filled in), none twice, none unknown (a skip whose
reason is exactly "invalid", "uninstalled after approval" or "faulty files"
may name a plugin no longer installed), at most one tech plugin (standard and
procedure plugins have no limit), mode TEST has standard-testing loaded and
BUILD doesn't, and agent "main thread" needs mode BUILD and no tech plugin.

Output (stdout, two lines, on exit 0):
  PLAN_FILE: <PATH>
  PLAN_SHA256: <64 lowercase hex>
the sha256 of the plan in canonical form: the one line jq -cS . prints for
the written file, its newline included. A gate record of the plan is the plan
with "v": 1 added, so jq -cS 'del(.v)' of the record hashes the same.
Problems (stderr, one line each; every problem is listed):
  ${PROG}: <option> <value as a JSON string, its middle cut past 80 characters, or (not given)>: <problem>; expected <x>
An installed plugin the plan leaves out is named as "--load or --skip <name>".

Exit codes:
  0  the plan written; its PLAN_FILE and PLAN_SHA256 lines printed
  1  writing the plan file failed after the checks passed, or its digest
     could not be computed (the file is then written)
  2  usage error: an unknown option, an option without its value, a --reason
     not right after a --load or --skip, a --load or --skip without its
     --reason, a second --plan-file, --agent, --mode, --context-file,
     --loaded-reason, --replan or --skills-dir, an empty --plan-file,
     --context-file or --skills-dir, no argument, or --plan-file, --agent,
     --mode, --context-file or --task missing
  3  invalid input, one stderr line per problem; nothing written
  5  a dependency missing or failing, with the fix named: jq 1.6+, sha256sum
     or shasum, list-plugins.sh, scripts/02-agent-context/agent-context-file-checks.sh,
     agent-context-validator.jq, dispatch-plan-validator.jq,
     installed-plugins.jq or scripts/04-agent-dispatch/dispatch-names.jq,
     or a base tool below
  129, 130, 143  stopped by HUP, INT or TERM; the temp file is removed

Dependencies: POSIX sh; jq 1.6+ (--args, \$ARGS, --argjson; macOS: brew
install jq; Linux: the distro's jq package); cat, mktemp, mv, rm, tr, wc, in
every macOS and Linux base system; sha256sum (Linux: coreutils) or shasum
(macOS: built in, run as shasum -a 256); list-plugins.sh;
scripts/02-agent-context/agent-context-file-checks.sh and agent-context-validator.jq,
dispatch-plan-validator.jq and installed-plugins.jq beside this script, and
scripts/04-agent-dispatch/dispatch-names.jq, which the validator includes.
Reads only: the context file, and what list-plugins.sh reads.
Runtime: about 300 ms for a plan with 8 plugins installed; measured on macOS
(average of 5 runs).
EOF
}

warn() {
	printf '%s: %s\n' "${PROG}" "$1" >&2
}

die() {
	warn "$2"
	exit "$1"
}

usage_error() {
	warn "$1"
	printf "Try '%s --help'.\n" "${PROG}" >&2
	exit 2
}

# Prints $1 with each control character as "?", so a value can't split a stderr line.
printable() {
	printf '%s' "$1" | tr '[:cntrl:]' '?'
}

# shellcheck disable=SC2329 # invoked by the EXIT trap
remove_temp_file() {
	[ -z "${temp_file}" ] || rm -f "${temp_file}"
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
				usage_error '--reason without a --load or --skip before it; expected each --reason right after a --load or --skip value'
			;;
		--plan-file | --agent | --mode | --context-file | --task | --load | --skip | --loaded-reason | --replan | --skills-dir)
			[ -z "${entry_kind}" ] || missing_reason_error
			;;
		*)
			shown_option=$(printable "$1")
			usage_error "unknown option: ${shown_option}; expected --plan-file, --agent, --mode, --context-file, --task, --load, --skip, --reason, --loaded-reason, --replan, --skills-dir or --help"
			;;
	esac
	awaited_option=$1
}

# Exits 2 naming the pending --load or --skip, which has no --reason.
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
		--agent | --mode | --loaded-reason | --replan)
			mark_seen "$1"
			case $1 in
				--loaded-reason) option_kind=loaded_reason ;;
				*) option_kind=${1#--} ;;
			esac
			finish_entry "${option_kind}" "$2" ''
			;;
		--task)
			task_count=$((task_count + 1))
			finish_entry task "$2" ''
			;;
		--load | --skip)
			entry_kind=${1#--}
			entry_value=$2
			;;
		*) finish_entry "${entry_kind}" "${entry_value}" "$2" ;;
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

# Exits 5 unless jq, a sha256 tool, list-plugins.sh, the three checks and the
# validator's names module are in place; sources agent-context-file-checks.sh
# and sets the checks' paths and list_script.
load_dependencies() {
	command -v jq >/dev/null 2>&1 ||
		die 5 'jq missing; expected jq 1.6+ on PATH; install it (macOS: brew install jq; Linux: the distro'\''s jq package)'
	plan_dir=$(script_dir)
	context_lib="${plan_dir}/../02-agent-context/agent-context-file-checks.sh"
	context_validator="${plan_dir}/../02-agent-context/agent-context-validator.jq"
	plan_validator="${plan_dir}/dispatch-plan-validator.jq"
	installed_program="${plan_dir}/installed-plugins.jq"
	# dispatch-plan-validator.jq includes it; a missing copy would read as a jq fault.
	dispatch_names="${plan_dir}/../04-agent-dispatch/dispatch-names.jq"
	for shared_file in "${context_lib}" "${context_validator}" "${plan_validator}" "${installed_program}" "${dispatch_names}"; do
		[ -f "${shared_file}" ] && [ -r "${shared_file}" ] ||
			die 5 "shared check missing; expected ${shared_file}; reinstall the ${PROCEDURE} skill"
	done
	# shellcheck source=../02-agent-context/agent-context-file-checks.sh
	. "${context_lib}"
	# shellcheck disable=SC2310 # its status is the lookup result; errexit adds nothing
	find_context_digest_tool ||
		die 5 'sha256sum and shasum missing; expected one of them on PATH; install coreutils (Linux) or use the system shasum (macOS)'
	list_script="${skills_dir}/${PROCEDURE}/scripts/03-dispatch-plan/list-plugins.sh"
	[ -f "${list_script}" ] && [ -r "${list_script}" ] ||
		die 5 "list-plugins.sh missing; expected ${list_script}; install the ${PROCEDURE} skill or pass the right --skills-dir"
}

# Prints the folder this script was run from (".", when run by a bare name).
script_dir() {
	case $0 in
		*/*) printf '%s' "${0%/*}" ;;
		*) printf '.' ;;
	esac
}

# Sets installed to the installed plugins as JSON; list-plugins.sh's stderr is
# passed through, and an exit other than 0, 1 or 3 exits 5.
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
	if [ -L "${context_file}" ]; then
		add_context_problem 'file is a symlink; expected the regular file the main thread wrote'
		return 0
	fi
	if [ ! -f "${context_file}" ] || [ ! -r "${context_file}" ]; then
		add_context_problem 'file is missing, unreadable or not a regular file; expected the readable context file'
		return 0
	fi
	context_size=$(wc -c <"${context_file}") || die 5 "wc could not count the bytes of ${context_file}; expected a byte count; check wc, then rerun"
	context_size=${context_size##* }
	if [ "${context_size}" -gt "${context_max_bytes}" ]; then
		add_context_problem "file is ${context_size} bytes; expected at most ${context_max_bytes} bytes"
		return 0
	fi
	if ! jq empty "${context_file}" </dev/null >/dev/null 2>&1; then
		add_context_problem 'file is not valid JSON; expected one JSON object'
		return 0
	fi
	shape_report=$(jq -rs --arg context_path "${context_file}" -f "${context_validator}" "${context_file}" </dev/null) ||
		die 5 'jq failed on the context validator; expected jq 1.6+; try jq --version, then rerun'
	if [ -n "${shape_report}" ]; then
		while IFS= read -r shape_line; do
			add_context_problem "${shape_line}"
		done <<EOF
${shape_report}
EOF
		return 0
	fi
	# shellcheck disable=SC2310 # its status is the tool's; a failure exits
	compute_context_digest "${context_file}" ||
		die 5 "${context_digest_tool} could not hash ${context_file}; expected 64 hex digits; check the tool, then rerun"
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
	jq -nr --arg prog "${PROG}" --arg mode "${run_mode}" --argjson installed "${installed}" \
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

# Sets context_digest to the sha256 of the written plan in canonical form, the
# one line jq -cS . prints for it, its newline included; or exits 1.
digest_written_plan() {
	canonical_plan=$(jq -cS . "${plan_file}" </dev/null) ||
		die 1 "jq could not read the written plan ${plan_file}; it is written, but its digest is not printed; expected the JSON this run wrote; try checking that nothing else writes to ${plan_folder}, then rerun"
	# shellcheck disable=SC2310 # its status is the tool's; a failure exits
	compute_stdin_digest <<EOF || die 1 "${context_digest_tool} could not hash the plan ${plan_file}; it is written, but its digest is not printed; expected ${context_digest_tool} to print a sha256; try ${context_digest_tool} on a small file by hand, fix or reinstall it, then rerun"
${canonical_plan}
EOF
}

for tool in ${REQUIRED_TOOLS}; do
	command -v "${tool}" >/dev/null 2>&1 ||
		die 5 "${tool} missing; expected it on PATH; install your base system's ${tool}"
done

temp_file=''
trap remove_temp_file EXIT
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

load_dependencies
read_installed
check_context_file
check_plan_file
build_plan "$@"
write_plan
digest_written_plan
printf 'PLAN_FILE: %s\nPLAN_SHA256: %s\n' "${plan_file}" "${context_digest}"
