#!/usr/bin/env sh
# Writes one agent dispatch file from the plan the human approved at its
# effort's gate, so a dispatch is never assembled by hand. The plan is found
# by its digest among the effort's gate records, the plan the human was
# shown, and the plan's context version must be in that effort; it is checked again by dispatch-plan-validator.jq, its
# context file by procedure-context's agent-context-file-checks.sh,
# agent-context-validator.jq and context-versions.sh and by its digest,
# its plugins resolved to files by plugin-files.sh, and the dispatch checked by
# agent-dispatch-validator.jq before and after it is written. Every problem is
# named by the option behind it; no file is left behind on a problem.
# shellcheck source-path=SCRIPTDIR source-path=SCRIPTDIR/../../../../../engine/crucible/scripts/lib source-path=SCRIPTDIR/../../../../procedures/procedure-context/scripts
set -eu
umask 077

readonly PROG='generate-agent-dispatch.sh'
readonly PROCEDURE='flow-agent-initialization'
readonly CONTEXT_PROCEDURE='procedure-context'
readonly REQUIRED_TOOLS='awk cat date git mktemp mv rm tr wc'
readonly PLAN_RECORD_LABEL='dispatch-plan'
readonly NAMES_MODULE='dispatch-names'
readonly DIRECT_LABEL='main-thread'
# Stand for the parts only crucible.sh new and the clock know, so the dispatch
# is checked whole before any file exists.
readonly PLACEHOLDER_ID='00000000T000000-0000'
readonly PLACEHOLDER_STARTED='0000-00-00T00:00:00+00:00'
# Stands for the effort folder while no plan is found, so the dispatch is
# still checked.
readonly PLACEHOLDER_EFFORT='00000000T000000-0000-effort'
readonly PLAN_RECORD_KIND='cache/gates'
readonly DISPATCH_KIND='dispatches'
# Stands for the report kind of an agent the shared names give none: such an
# agent is no dispatched agent, so the dispatch check refuses it and no file
# is made.
readonly PLACEHOLDER_REPORT_KIND='reports/no-report-kind'
# Lead the problems a caller acts on, so it matches the token exactly, never
# the sentence after it: a plan no gate record of the effort holds, a context
# file changed since the plan was shown or no longer its effort's latest
# version (the Agent hook's KIND word for it), and an earlier dispatch whose
# baseline was never filled.
readonly NO_GATE_RECORD_TOKEN='NO-GATE-RECORD'
readonly CONTEXT_CHANGED_TOKEN='CONTEXT-CHANGED'
readonly CONTEXT_STALE_TOKEN='CONTEXT-STALE'
readonly BASELINE_EMPTY_TOKEN='BASELINE-EMPTY'
readonly TASK_STAND_IN='(no task chosen)'
NL='
'
readonly NL
# The C locale keeps the shell's pattern checks byte-wise on macOS and Linux.
LC_ALL=C
export LC_ALL

# Builds the dispatch JSON (mode "dispatch") from the named values and the
# starting points as positional arguments, or names each validator problem by
# its option (mode "report": one stderr line each).
# The program is single-quoted on purpose: its $ signs are jq's.
# shellcheck disable=SC2016
readonly DISPATCH_JQ='
def plugins: $plugin_paths | split("\n") | map(select(. != ""))
	| reduce .[] as $path ([];
		($path | ltrimstr($skills_dir + "/") | split("/")[0]) as $name
		| if (.[-1].name // null) == $name then .[-1].paths += [$path] else . + [{name: $name, paths: [$path]}] end);
def dispatch: {
	id: $id, started: $started, agent: $agent, mode: $mode, tech: $tech,
	plugins: plugins,
	plan: {sha256: $plan_sha256},
	context: {path: $context_path, sha256: $context_sha256},
	task: $task, repo_root: $repo_root, starting_points: $ARGS.positional, report: $report, baseline: $baseline};

# A long value keeps its start and end, where a path differs most.
def max_shown_chars: 80;
def shown: tojson | gsub("[[:cntrl:]]"; "?") | if length > max_shown_chars then .[:40] + "…" + .[-39:] else . end;
def line($option; $value; $problem): "\($prog): \($option) \($value | shown): \($problem)";
def field_name: map(if type == "number" then "[\(.)]" else "." + . end) | join("") | ltrimstr(".");
# Fields whose value is a stand-in (the plan not found or not valid, or no
# task chosen) are not reported again: their problem is reported already.
def stood_in: (.at[0] | IN("agent", "mode", "tech", "plugins", "plan", "context", "report", "baseline")) and $plan_known == "false"
	or .at[0] == "task" and $task_known == "false";
def named_line:
	.at as $at | .problem as $problem
	| if stood_in then empty
	  elif $at[0] == "starting_points" and ($at | length) > 1 then line("--starting-point"; $ARGS.positional[$at[1]]; $problem)
	  elif $at[0] == "repo_root" then line("--repo-root"; $repo_root; $problem)
	  elif $at[0] == "task" then line("--task"; $task_number; "the task \($problem)")
	  elif $at[0] == "report" then line("CRUCIBLE_HOME"; $space_root; "the report file \($problem)")
	  elif $at[0] == "baseline" then line("CRUCIBLE_HOME"; $space_root; "the baseline file \($problem)")
	  elif ($at[0] | IN("agent", "mode", "tech", "plugins", "plan", "context")) then
		line("--plan-sha256"; $plan_sha256; "the plan'"'"'s \($at | field_name) \($problem)")
	  else "\($prog): dispatch \($at | field_name): \($problem)" end;
def report: $validator_problem_lines | split("\n")[] | select(. != "") | fromjson | named_line;

if $mode_of_run == "report" then report else dispatch end
'

usage() {
	cat <<EOF
Usage: sh ${PROG} --effort FOLDER --plan-sha256 HEX --task N --repo-root PATH
           [--starting-point REL]... [--skills-dir DIR] [--baseline-from DISPATCH]
       sh ${PROG} --help

Writes one agent dispatch file for task N of the plan the human approved, and
allocates the agent's report file and the dispatch's baseline file, all in
the effort folder FOLDER. Every input is checked first; on a problem no file
is left behind.

  --effort FOLDER    the effort the plan was approved in, the folder its gate
                     was opened with: a real effort folder of the Crucible
                     space, as crucible.sh new takes --effort (crucible.sh
                     --help states the rule; trailing slashes dropped).
  --plan-sha256 HEX  the PLAN_SHA256 generate-dispatch-plan.sh printed: 64
                     lowercase hex. The gate record is the ${PLAN_RECORD_KIND} item
                     labelled ${PLAN_RECORD_LABEL} of FOLDER (crucible.sh find
                     --effort FOLDER, newest first) whose content without its
                     top-level "v" hashes to HEX in canonical form (the one
                     line jq -cS 'del(.v)' prints, its newline included); the
                     first found wins. No other effort is read. The plan's
                     context file must be a file directly in FOLDER's
                     context/.
  --task N           which of the plan's tasks: a decimal integer from 1, no
                     leading zero.
  --repo-root PATH   the repository's git work-tree root: absolute, an existing
                     folder, and what git -C PATH rev-parse --show-toplevel
                     prints.
  --starting-point REL  a repo-relative path the task starts from, kept in
                     order; it need not exist (a task may create it). None is
                     allowed.
  --skills-dir DIR   the skills folder, which must be
                     \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/skills, the default
                     (compared as text, trailing slashes dropped): the Agent
                     hook, prepare-agent-prompt.sh, takes plugin paths only
                     under that folder, so any other DIR is refused (exit 3).
                     The installed plugins are the plugin lines of
                     DIR/${PROCEDURE}/scripts/dispatch-plan/list-plugins.sh --max-lines 0.
  --baseline-from DISPATCH  an earlier dispatch file of this task, the one a
                     resend replaces (that it is of this task is the
                     caller's to hold: only the checks below are made): the
                     new dispatch's baseline file gets a
                     byte-for-byte copy of DISPATCH's filled baseline, so the
                     baseline stays the tree before the first call. DISPATCH
                     must be absolute, a file directly in FOLDER's
                     ${DISPATCH_KIND}/ (no folder of that path a symbolic
                     link), a regular file, not a symlink, pass
                     agent-dispatch-validator.jq and have repo_root PATH; its
                     baseline file must be a file directly in FOLDER's
                     baselines/ (no folder of that path a symbolic link), a
                     regular file, not a symlink, not empty, and hold a
                     baseline of PATH (baseline_problems in ${NAMES_MODULE}.jq).
                     Both are checked before the baseline is read.

Checks, all before any file is made:
  - the plan: scripts/dispatch-plan/dispatch-plan-validator.jq against the
    installed plugins, as generate-dispatch-plan.sh checks it
  - its context file: directly in the effort's context/; the path checks of
    DIR/${CONTEXT_PROCEDURE}/scripts/agent-context-file-checks.sh; then its
    read checks, context_read_problem, the one copy every script that reads
    a context file applies: a readable regular file that is not a symlink,
    at most the size cap, valid JSON passing
    DIR/${CONTEXT_PROCEDURE}/scripts/agent-context-validator.jq, and still
    its effort's latest version, as
    DIR/${CONTEXT_PROCEDURE}/scripts/context-versions.sh finds it; and its
    sha256 must still be the plan's context.sha256
  - the dispatch: scripts/agent-dispatch/agent-dispatch-validator.jq, which
    among its rules dispatches only the agents of report_kinds in
    ${NAMES_MODULE}.jq (direct implementation, "main thread", with no tech
    plugin), in mode BUILD (TEST is refused for now); an agent with no
    report kind there is refused with it, the plan's agent problem
A gate record that no longer passes dispatch-plan-validator.jq's current
rules is refused; regenerate the plan at the flow's step 7. Its "v" is not
read.
The loaded plugins' files are scripts/agent-dispatch/plugin-files.sh's:
role developer for code-developer and "main thread" (SKILL.md,
references/development.md, each references/*-template.md), role reviewer for
code-reviewer (SKILL.md, references/review.md when readable), the tech
plugin's files first (its base first), then the standard and procedure
plugins in plugin-line order. A based tech plugin's base files form their
own plugins entry, named after the base's folder (tech-<base>), before the
tech plugin's entry, even though the plan lists that base as not loaded.

Then, each with crucible.sh new --effort <the effort folder>, the report
file is made with --kind <the agent's report_kind in ${NAMES_MODULE}.jq> and
--label <agent>-report (<agent> being main-thread for "main thread"), the
baseline file with --kind baselines --label <agent>-baseline (each must be
empty, inside its kind folder of the effort, and not under PATH), and the
dispatch file with --kind ${DISPATCH_KIND} --label <agent>-dispatch, written
to a temp file in its folder, moved onto its path and checked again.
The baseline file is left empty: this script writes no git status, since a
dispatch may be sent long after it is written. prepare-agent-prompt.sh
writes it at the Agent call (or at --direct), before the agent or the main
thread changes the tree, and the developer's report.sh (the one for
code-developer and "main thread") reads it through the dispatch; the
reviewer's report.sh does not read it. With
--baseline-from, the file instead gets the earlier baseline's bytes, read
once and checked before any file is made, through a temp file in its folder
moved onto its path; the hook then keeps it as a resend's.

The dispatch file (one JSON object, exactly these keys):
  {"id": <the dispatch file's Crucible ID>, (*)
   "started": <local time, YYYY-MM-DDTHH:MM:SS+HH:MM>, (*)
   "agent": str,
   "mode": str, (*)
   "tech": <the loaded tech plugin's name, or "none">, (*)
   "plugins": [{"name": <the plugin folder>, "paths": [absolute path, ...]}, ...], (*)
   "plan": {"sha256": HEX},
     (the approved plan the dispatch came from, by its digest: the gate
     record itself is a cache item and expires, so no path to it is kept)
   "context": {"path": str, "sha256": str},
   "task": <the N-th task, exact>, "repo_root": PATH,
   "starting_points": [REL, ...], "report": <the report file>,
   "baseline": <the baseline file, empty until the call>}
  (*) stamped at the top level of the agent's report on a passing
      report.sh check --dispatch, the developer's and the reviewer's alike:
      id as "dispatch", started, mode and tech under their own names, and
      plugins as their names only ("plugins": [<name>, ...]). report.sh
      adds its own "finished", the local time its check passed. The
      reviewer's report.sh also stamps "plugin" on each finding: the one
      tech-* or standard-* plugin's name, or "correctness" when none is
      loaded.

Output (stdout, exactly two lines, on exit 0):
  DISPATCH: <absolute path of the dispatch file>
  LABELS: Technology: <tech label, or none> · Standards: <labels, or none> · Procedures: <labels>
the plugins' labels, as plugin-files.sh builds the line; the
" · Procedures: <labels>" segment is there only when a procedure plugin is
loaded (never "Procedures: none")
Problems (stderr, one line each; every problem is listed):
  ${PROG}: <option> <value as a JSON string, its middle cut past 80 characters>: <problem>; expected <x>
A problem of the plan or its context file names --plan-sha256; one of FOLDER
names --effort; one of the report or baseline file's place, or of the
Crucible space itself (a CRUCIBLE_HOME the crucible skill's space rules
refuse), names CRUCIBLE_HOME.
Four problems lead with a token, which no other line holds, so a caller
matches the token, never the text after it:
  ${NO_GATE_RECORD_TOKEN}   a plan no gate record of FOLDER holds (its record
                   expired or gone, or never shown at FOLDER's gate):
  ${PROG}: --plan-sha256 "<HEX>": ${NO_GATE_RECORD_TOKEN} no gate record of the effort holds that plan; expected the PLAN_SHA256 of a plan shown and asked about at the gate of --effort
  ${CONTEXT_CHANGED_TOKEN}  a context file whose sha256 is no longer the plan's
                   context.sha256 (sha256s cut to 12 digits):
  ${PROG}: --plan-sha256 "<HEX>": ${CONTEXT_CHANGED_TOKEN} the plan's context file <path>: changed since the plan was shown (sha256 <shown> shown, <now> now); expected it as shown; show the plan again for the changed file
  ${CONTEXT_STALE_TOKEN}    a context version no longer its effort's latest (the
                   Agent hook's KIND word for the same problem):
  ${PROG}: --plan-sha256 "<HEX>": ${CONTEXT_STALE_TOKEN} the plan's context file <path>: is version v<N> of its effort, not the latest (v<M>: <latest path>); expected the latest version; show the plan again at its gate with it
  ${BASELINE_EMPTY_TOKEN}   a --baseline-from DISPATCH whose baseline file is
                   empty (that dispatch never reached the tree):
  ${PROG}: --baseline-from "<DISPATCH>": ${BASELINE_EMPTY_TOKEN} its baseline file <path> is empty: that dispatch never went through the Agent hook or --direct; expected its filled baseline
Other stderr lines:
  - ${PROG}: <message>; expected <x>...: a usage error (then a
    "Try ..." line), a dependency fault, a failure after the checks, or
    "removed <file>, made by this run"
  - list-plugins.sh: <name>: <reason>, passed through: an invalid plugin it
    leaves out; the run goes on
  - ${PROG}: name <name> given twice ... or name <name> is not
    an installed plugin ..., from plugin-files.sh, before the problem line
    naming the plan's plugins
  - crucible.sh's own lines, when crucible.sh find or new fails

Exit codes:
  0  the dispatch file written; its path and the LABELS line printed
  1  making, writing or checking a file failed after the inputs passed; the
     files this run made (report, baseline, dispatch) are removed (stderr
     names them)
  2  usage error: an unknown option (--session among them: the record is
     found by its digest alone), an option without its value or with an
     empty one, a second --effort, --plan-sha256, --task, --repo-root,
     --skills-dir or --baseline-from, or one of the first four missing.
     --help and usage errors are handled before the tool check below, so
     they need only cat (for --help) and tr (to show an unknown option)
  3  invalid input, one stderr line per problem (a FOLDER that breaks its
     rule, missing or a symbolic link included), a --baseline-from DISPATCH
     that is not a valid dispatch of PATH, or it or its baseline file not in
     FOLDER, or whose baseline is empty or not a baseline of PATH among
     them; no file made
  5  a dependency missing or failing, with the fix named: jq 1.6+, git,
     sha256sum or shasum, crucible.sh, the crucible skill's
     scripts/lib/crucible-space.sh, list-plugins.sh, the checks and helpers
     named above (${NAMES_MODULE}.jq giving no report kind for an agent
     its dispatch check passed among them), a base tool below,
     crucible.sh find failing on FOLDER
     (such as for a FOLDER/cache/ that is a symbolic link), or mktemp
     failing while --baseline-from is checked; no file made
  129, 130, 143  stopped by HUP, INT or TERM; the temp files and the files
     this run made are removed (stderr names them). A crucible.sh new still
     running when the signal lands is not stopped: it may still make its
     empty file after this exit

Dependencies: POSIX sh; jq 1.6+ (--args, \$ARGS; macOS: brew install jq;
Linux: the distro's jq package); git (macOS: xcode-select --install; Linux:
the distro's git package); awk, cat, date (+%z), mktemp, mv, rm, tr, wc, in
every macOS and Linux base system; sha256sum (Linux: coreutils) or shasum
(macOS: built in, run as shasum -a 256); crucible.sh and the crucible
skill's space rules, \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/skills/crucible/scripts/lib/crucible-space.sh;
list-plugins.sh; the
${CONTEXT_PROCEDURE} skill's agent-context-file-checks.sh,
agent-context-validator.jq, agent-context-url.jq and context-versions.sh in
DIR/${CONTEXT_PROCEDURE}/scripts/; scripts/dispatch-plan/dispatch-plan-validator.jq
and installed-plugins.jq; plugin-files.sh, agent-dispatch-validator.jq and
${NAMES_MODULE}.jq beside this script.
Reads only: FOLDER's gate records (through crucible.sh find) until the
plan's is found; the plan's
context file and the names in its context/ folder; git's view of
PATH; what list-plugins.sh reads; the loaded plugins' folders (whether
references/review.md is readable, and the references/*-template.md files);
and with --baseline-from that dispatch and its baseline file.
Runtime: about 600 ms for a dispatch with 3 plugins; measured on macOS
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

# Removes the temp files; on a failing exit, a signal included, also the
# files this run made, so no partial dispatch is left behind.
# shellcheck disable=SC2329 # invoked by the EXIT trap
clean_up() {
	exit_status=$?
	[ -z "${temp_file}" ] || rm -f "${temp_file}"
	[ -z "${earlier_baseline_copy}" ] || rm -f "${earlier_baseline_copy}"
	[ "${exit_status}" -eq 0 ] || remove_created_files
}

# Handles option $1 when no option value is awaited: sets awaited_option, or exits 2.
take_option() {
	case $1 in
		--help | -h)
			usage
			exit 0
			;;
		--effort | --plan-sha256 | --task | --repo-root | --starting-point | --skills-dir | --baseline-from) awaited_option=$1 ;;
		*)
			shown_option=$(printable "$1")
			usage_error "unknown option: ${shown_option}; expected --effort, --plan-sha256, --task, --repo-root, --starting-point, --skills-dir, --baseline-from or --help"
			;;
	esac
}

# Takes value $2 of option $1 but --starting-point, which the caller collects.
take_value() {
	case " ${seen_options} " in
		*" $1 "*) usage_error "$1 given twice; expected at most one $1" ;;
		*) seen_options="${seen_options} $1" ;;
	esac
	[ -n "$2" ] || usage_error "$1 is empty; expected $1 VALUE"
	case $1 in
		--effort) given_effort=$2 ;;
		--plan-sha256) plan_sha256=$2 ;;
		--task) task_number=$2 ;;
		--repo-root) repo_root=$2 ;;
		--baseline-from) baseline_from=$2 ;;
		*) given_skills_dir=$2 ;;
	esac
}

# Exits 2 on an option left without its value or a required option missing.
finish_parse() {
	[ -z "${awaited_option}" ] || usage_error "${awaited_option} needs a value; expected ${awaited_option} VALUE"
	for required in --effort --plan-sha256 --task --repo-root; do
		case " ${seen_options} " in
			*" ${required} "*) ;;
			*) usage_error "${required} missing; expected ${required} VALUE" ;;
		esac
	done
	skills_dir="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/skills"
}

# Adds a problem when --skills-dir is not the skills folder the Agent hook
# takes plugin paths under; the run always uses that folder.
check_skills_dir() {
	[ -n "${given_skills_dir}" ] || return 0
	trim_trailing_slashes "${skills_dir}"
	hook_skills_dir=${trimmed}
	trim_trailing_slashes "${given_skills_dir}"
	[ "${trimmed}" != "${hook_skills_dir}" ] || return 0
	add_problem --skills-dir "${given_skills_dir}" "not the skills folder the Agent hook takes plugin paths under; expected ${skills_dir}; drop --skills-dir, or set CLAUDE_CONFIG_DIR"
}

# Sets trimmed to $1 without its trailing slashes ("/" stays "/").
trim_trailing_slashes() {
	trimmed=$1
	while [ "${trimmed}" != '/' ] && [ "${trimmed%/}" != "${trimmed}" ]; do
		trimmed=${trimmed%/}
	done
}

# Exits 5 unless jq, a sha256 tool, crucible.sh, list-plugins.sh and every
# shared check and helper are in place; sources the two shell helpers and
# reads DIRECT_AGENT and BASELINE_KIND from the shared names.
load_dependencies() {
	command -v jq >/dev/null 2>&1 ||
		die 5 'jq missing; expected jq 1.6+ on PATH; install it (macOS: brew install jq; Linux: the distro'\''s jq package)'
	context_lib="${skills_dir}/${CONTEXT_PROCEDURE}/scripts/agent-context-file-checks.sh"
	[ -f "${context_lib}" ] && [ -r "${context_lib}" ] ||
		die 5 "context check missing; expected ${context_lib}; install the ${CONTEXT_PROCEDURE} skill"
	dispatch_dir=$(script_dir)
	plan_validator="${dispatch_dir}/../dispatch-plan/dispatch-plan-validator.jq"
	installed_program="${dispatch_dir}/../dispatch-plan/installed-plugins.jq"
	plugin_lib="${dispatch_dir}/plugin-files.sh"
	dispatch_validator="${dispatch_dir}/agent-dispatch-validator.jq"
	names_module="${dispatch_dir}/${NAMES_MODULE}.jq"
	for shared_file in "${plan_validator}" "${installed_program}" \
		"${plugin_lib}" "${dispatch_validator}" "${names_module}"; do
		[ -f "${shared_file}" ] && [ -r "${shared_file}" ] ||
			die 5 "shared check or helper missing; expected ${shared_file}; reinstall the ${PROCEDURE} skill"
	done
	# shellcheck disable=SC2310 # its status is jq's; a failure exits
	DIRECT_AGENT=$(read_shared_name direct_agent) &&
		[ -n "${DIRECT_AGENT}" ] ||
		die 5 "jq could not read direct_agent from ${names_module}; expected jq 1.6+ and the ${PROCEDURE} skill's shared names; try jq --version, or reinstall the skill"
	readonly DIRECT_AGENT
	# shellcheck disable=SC2310 # its status is jq's; a failure exits
	BASELINE_KIND=$(read_shared_name baseline_kind) &&
		[ -n "${BASELINE_KIND}" ] ||
		die 5 "jq could not read baseline_kind from ${names_module}; expected jq 1.6+ and the ${PROCEDURE} skill's shared names; try jq --version, or reinstall the skill"
	readonly BASELINE_KIND
	# shellcheck source=../../../../procedures/procedure-context/scripts/agent-context-file-checks.sh
	. "${context_lib}"
	# shellcheck disable=SC2310 # its status says whether the checks loaded; the problem is read here
	context_load_checks "${skills_dir}" || die 5 "${context_load_problem}"
	# shellcheck source=plugin-files.sh
	. "${plugin_lib}"
	crucible_script="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/skills/crucible/scripts/crucible.sh"
	[ -f "${crucible_script}" ] && [ -r "${crucible_script}" ] ||
		die 5 "crucible.sh missing; expected ${crucible_script}; install the crucible skill"
	list_script="${skills_dir}/${PROCEDURE}/scripts/dispatch-plan/list-plugins.sh"
	[ -f "${list_script}" ] && [ -r "${list_script}" ] ||
		die 5 "list-plugins.sh missing; expected ${list_script}; install the ${PROCEDURE} skill"
}

# Prints the value of jq expression $1 over the shared names module, with
# $agent set to $2 (empty when not given).
read_shared_name() {
	jq -nr -L "${dispatch_dir}" --arg agent "${2-}" "include \"${NAMES_MODULE}\"; $1" </dev/null
}

# Prints the folder this script was run from (".", when run by a bare name).
script_dir() {
	case $0 in
		*/*) printf '%s' "${0%/*}" ;;
		*) printf '.' ;;
	esac
}

# Appends a problem line for option $1, value $2 and problem $3.
add_problem() {
	problem_line=$(jq -nr --arg prog "${PROG}" --arg option "$1" --arg value "$2" --arg problem "$3" \
		'"\($prog): \($option) \($value | tojson | gsub("[[:cntrl:]]"; "?") | if length > 80 then .[:40] + "…" + .[-39:] else . end): \($problem)"') ||
		die 5 'jq failed formatting a problem; expected jq 1.6+; try jq --version, then rerun'
	problems="${problems}${problem_line}${NL}"
}

# Tests plan_sha256 against the shared names' sha256_pattern; jq -e exits 1
# when the value does not match it.
check_plan_sha256() {
	sha256_status=0
	jq -ne --arg h "${plan_sha256}" -L "${dispatch_dir}" "include \"${NAMES_MODULE}\"; \$h | test(sha256_pattern)" \
		</dev/null >/dev/null || sha256_status=$?
	case ${sha256_status} in
		0) return 0 ;;
		1) ;;
		*) die 5 "jq failed testing --plan-sha256 against sha256_pattern in ${names_module} (exit ${sha256_status}); expected jq 1.6+ and the ${PROCEDURE} skill's shared names; try jq --version, or reinstall the skill" ;;
	esac
	add_problem --plan-sha256 "${plan_sha256}" 'not 64 lowercase hex digits; expected the PLAN_SHA256 generate-dispatch-plan.sh printed'
	plan_sha256_ok=false
}

check_task_number() {
	case ${task_number} in
		0* | *[!0-9]*) ;;
		*) return 0 ;;
	esac
	add_problem --task "${task_number}" 'not a positive integer; expected the task'\''s number in the plan, from 1'
	task_number_ok=false
}

# Adds a problem when repo_root is an absolute path that is not an existing
# folder or not git's work-tree root; the validator owns the path's shape.
check_repo_root() {
	case ${repo_root} in
		/*) ;;
		*) return 0 ;;
	esac
	if [ ! -d "${repo_root}" ]; then
		add_problem --repo-root "${repo_root}" 'not an existing folder; expected the repository'\''s git work-tree root'
		return 0
	fi
	if git_root=$(GIT_TERMINAL_PROMPT=0 GIT_OPTIONAL_LOCKS=0 GIT_CONFIG_NOSYSTEM=1 \
		git -c core.fsmonitor=false -C "${repo_root}" rev-parse --show-toplevel 2>/dev/null </dev/null); then
		[ "${git_root}" = "${repo_root}" ] && return 0
		add_problem --repo-root "${repo_root}" "not the git work-tree root; expected ${git_root}"
	else
		add_problem --repo-root "${repo_root}" 'not in a git work tree; expected the repository'\''s git work-tree root'
	fi
}

# Sets effort_dir to --effort without trailing slashes when it names a real
# effort folder of the space, or adds its problem and leaves effort_dir empty.
check_effort_option() {
	effort_dir=''
	[ "${space_ok}" = true ] || return 0
	# shellcheck disable=SC2310 # its status says whether the folder passed; the problem is read below
	if crucible_check_effort_folder "${given_effort}"; then
		effort_dir=${crucible_effort}
		return 0
	fi
	add_problem --effort "${given_effort}" "${crucible_effort_problem}"
}

# Sets record_path to the gate record of the effort whose plan hashes to
# plan_sha256, or adds a problem.
find_plan_record() {
	record_path=''
	[ -n "${effort_dir}" ] || return 0
	# shellcheck disable=SC2310 # its status says whether the record is in the effort
	find_record_in "${effort_dir}" && return 0
	add_problem --plan-sha256 "${plan_sha256}" "${NO_GATE_RECORD_TOKEN} no gate record of the effort holds that plan; expected the PLAN_SHA256 of a plan shown and asked about at the gate of --effort"
}

# Sets record_path to the gate record of effort folder $1 whose plan hashes
# to plan_sha256; fails when it holds none.
find_record_in() {
	if ! record_candidates=$(sh "${crucible_script}" find --effort "$1" --kind "${PLAN_RECORD_KIND}" --label "${PLAN_RECORD_LABEL}" </dev/null); then
		die 5 'crucible.sh find failed on --effort; its stderr is above; fix what it names, then rerun'
	fi
	while IFS= read -r candidate; do
		[ -n "${candidate}" ] || continue
		canonical_record=$(jq -cS 'del(.v)' "${candidate}" </dev/null 2>/dev/null) || continue
		# shellcheck disable=SC2310 # its status is the tool's; a failure exits
		compute_stdin_digest <<EOF || die 5 "${context_digest_tool} could not hash ${candidate}; check the tool, then rerun"
${canonical_record}
EOF
		if [ "${context_digest}" = "${plan_sha256}" ]; then
			record_path=${candidate}
			return 0
		fi
	done <<EOF
${record_candidates}
EOF
	return 1
}

# Sets installed to the installed plugins as JSON and listing to their lines;
# list-plugins.sh's stderr is passed through, and an exit other than 0, 1 or 3 exits 5.
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

# Checks the record's plan; when it fits, sets agent, mode, task_count,
# loaded_names, context_path and plan_context_sha256, and plan_ok=true.
check_plan() {
	plan_ok=false
	plan_report=$(jq -c 'del(.v)' "${record_path}" </dev/null |
		jq -rs --argjson installed "${installed}" -f "${plan_validator}") ||
		die 5 'jq failed on the plan validator; expected jq 1.6+; try jq --version, then rerun'
	if [ -n "${plan_report}" ]; then
		while IFS= read -r plan_line; do
			add_problem --plan-sha256 "${plan_sha256}" "the plan's ${plan_line}"
		done <<EOF
${plan_report}
EOF
		return 0
	fi
	plan_fields=$(jq -r '.agent, .mode, (.tasks | length), .context.path, .context.sha256' "${record_path}" </dev/null) ||
		die 5 'jq failed reading the plan; expected jq 1.6+; try jq --version, then rerun'
	{
		IFS= read -r agent
		IFS= read -r mode
		IFS= read -r task_count
		IFS= read -r context_path
		IFS= read -r plan_context_sha256
	} <<EOF
${plan_fields}
EOF
	loaded_names=$(jq -r '.loaded[].plugin' "${record_path}" </dev/null) ||
		die 5 'jq failed reading the plan; expected jq 1.6+; try jq --version, then rerun'
	plan_ok=true
}

# Sets task to the task_number-th task of the plan and task_known=true, or
# adds a problem and leaves the stand-in.
pick_task() {
	[ "${task_number_ok}" = true ] || return 0
	if [ "${task_number}" -gt "${task_count}" ]; then
		add_problem --task "${task_number}" "the plan has ${task_count} task(s); expected 1 to ${task_count}"
		return 0
	fi
	task_known=true
	task=$(jq -j --argjson n "${task_number}" '.tasks[$n - 1]' "${record_path}" </dev/null) ||
		die 5 'jq failed reading the task; expected jq 1.6+; try jq --version, then rerun'
}

# Adds a problem when the context file is not in the effort's context/, fails
# its path or read checks, or changed since the plan was shown.
check_context() {
	# shellcheck disable=SC2310 # its status is the test result; the problem is read below
	if ! crucible_check_effort_item "${context_path}" context; then
		add_context_problem "is ${crucible_item_problem}"
		return 0
	fi
	if [ "${crucible_effort}" != "${effort_dir}" ]; then
		add_context_problem "is in effort ${crucible_effort}; expected a context version in ${effort_dir}/context/, the effort whose gate the plan was approved at"
		return 0
	fi
	path_problem=$(context_path_problem "${context_path}")
	if [ -n "${path_problem}" ]; then
		add_context_problem "${path_problem}; expected ${context_path_expected}"
		return 0
	fi
	# shellcheck disable=SC2310 # its status is a tool's; a failure has printed its cause
	context_read_problem "${context_path}" ||
		die 5 'a tool failed on the context read checks (its stderr is above); expected jq 1.6+ and wc; try jq --version, then rerun'
	if [ "${context_read_fault}" = stale ]; then
		add_context_problem "${context_read_text}; show the plan again at its gate with it" "${CONTEXT_STALE_TOKEN} "
		return 0
	fi
	if [ -n "${context_read_fault}" ]; then
		add_context_problem "${context_read_text}"
		return 0
	fi
	# shellcheck disable=SC2310 # its status is the tool's; a failure exits
	compute_context_digest "${context_path}" ||
		die 5 "${context_digest_tool} could not hash ${context_path}; check the tool, then rerun"
	[ "${context_digest}" = "${plan_context_sha256}" ] ||
		add_context_problem "changed since the plan was shown (sha256 $(printf '%.12s' "${plan_context_sha256}") shown, $(printf '%.12s' "${context_digest}") now); expected it as shown; show the plan again for the changed file" "${CONTEXT_CHANGED_TOKEN} "
}

# Adds problem $1 of the plan's context file, led by token $2 and its space
# when given.
add_context_problem() {
	add_problem --plan-sha256 "${plan_sha256}" "${2-}the plan's context file ${context_path}: $1"
}

# Sets plugin_paths, tech and labels_line for the plan's loaded plugins,
# resolved by plugin-files.sh for the agent's role; adds a problem when they
# can't be resolved. An agent with no role is left to the validator.
resolve_plugins() {
	plugin_paths='' tech=none labels_line=''
	case ${agent} in
		code-developer | "${DIRECT_AGENT}") role=developer ;;
		code-reviewer) role=reviewer ;;
		*) return 0 ;;
	esac
	set --
	while IFS= read -r loaded_name; do
		[ -n "${loaded_name}" ] || continue
		set -- "$@" "${loaded_name}"
		case ${loaded_name} in
			tech-*) [ "${tech}" != none ] || tech=${loaded_name} ;;
			*) ;;
		esac
	done <<EOF
${loaded_names}
EOF
	# shellcheck disable=SC2310 # its status is awk's; it is acted on below
	if ! selected=$(select_plugin_lines paths "${PROG}" "${listing}" "$@"); then
		add_problem --plan-sha256 "${plan_sha256}" "the plan's plugins can't be resolved (the lines above name why); expected installed plugins"
		return 0
	fi
	# shellcheck disable=SC2310 # its status is the template check; it is acted on below
	if ! resolve_role_paths "${role}" "${selected}"; then
		add_problem --plan-sha256 "${plan_sha256}" "the plan's plugins: ${plugin_problem}"
		return 0
	fi
	# shellcheck disable=SC2310 # its status is awk's; a failure exits
	labels_line=$(select_plugin_lines labels "${PROG}" "${listing}" "$@") ||
		die 5 'awk failed building the LABELS line; expected a POSIX awk; check the awk on PATH'
}

# Sets space_root by the space rules and space_ok=true, or adds the
# CRUCIBLE_HOME problem they name and sets space_ok=false.
resolve_space_root() {
	space_ok=true
	# shellcheck disable=SC2310 # its status says whether the root is usable; the problem is read below
	if crucible_resolve_root; then
		space_root=${crucible_root}
		return 0
	fi
	space_ok=false
	space_root="${CRUCIBLE_HOME:-${HOME:-}/.crucible}"
	add_problem CRUCIBLE_HOME "${space_root}" "${crucible_root_problem}"
}

# Sets agent_label (the agent as it goes into a Crucible label: main-thread
# for "main thread"), report_kind (the agent's reports folder, empty for an
# agent the shared names give none), and placeholder_report and
# placeholder_baseline, the stand-ins for the two paths crucible.sh new makes
# in the effort.
plan_space_paths() {
	agent_label=${agent}
	[ "${agent}" != "${DIRECT_AGENT}" ] || agent_label=${DIRECT_LABEL}
	# shellcheck disable=SC2016,SC2310 # $agent is jq's; a failure exits
	report_kind=$(read_shared_name '$agent | report_kind' "${agent}") ||
		die 5 "jq could not read report_kind from ${names_module}; expected jq 1.6+ and the ${PROCEDURE} skill's shared names; try jq --version, or reinstall the skill"
	planned_effort=${effort_dir:-${space_root}/efforts/${PLACEHOLDER_EFFORT}}
	placeholder_report="${planned_effort}/${report_kind:-${PLACEHOLDER_REPORT_KIND}}/${PLACEHOLDER_ID}-${agent_label}-report.json"
	placeholder_baseline="${planned_effort}/${BASELINE_KIND}/${PLACEHOLDER_ID}-${agent_label}-baseline.json"
}

# Adds a problem unless the --baseline-from dispatch is a valid dispatch of
# repo_root whose baseline file holds a baseline of it; on a pass, that
# baseline is read once into earlier_baseline_copy, the bytes the new
# dispatch's baseline file gets.
check_baseline_from() {
	case ${baseline_from} in
		/*) ;;
		*)
			add_baseline_from_problem 'not an absolute path; expected the DISPATCH path of the earlier dispatch'
			return 0
			;;
	esac
	# shellcheck disable=SC2310 # its status says whether the path is the effort's; the problem is added inside
	in_effort_folder "${baseline_from}" "${DISPATCH_KIND}" 'is' 'the earlier dispatch' || return 0
	if [ -L "${baseline_from}" ] || [ ! -f "${baseline_from}" ] || [ ! -r "${baseline_from}" ]; then
		add_baseline_from_problem 'missing, unreadable, a symlink or not a regular file; expected the earlier dispatch file generate-agent-dispatch.sh wrote'
		return 0
	fi
	if ! earlier_problems=$(jq -rs -f "${dispatch_validator}" "${baseline_from}" </dev/null 2>/dev/null); then
		add_baseline_from_problem 'not JSON; expected the earlier dispatch file generate-agent-dispatch.sh wrote'
		return 0
	fi
	if [ -n "${earlier_problems}" ]; then
		earlier_problems=$(joined_lines "${earlier_problems}")
		add_baseline_from_problem "fails the dispatch validator (${earlier_problems}); expected a dispatch generate-agent-dispatch.sh wrote"
		return 0
	fi
	earlier_fields=$(jq -r '.repo_root, .baseline' "${baseline_from}" </dev/null) ||
		die 5 'jq failed reading the --baseline-from dispatch; expected jq 1.6+; try jq --version, then rerun'
	{
		IFS= read -r earlier_repo_root
		IFS= read -r earlier_baseline
	} <<EOF
${earlier_fields}
EOF
	if [ "${earlier_repo_root}" != "${repo_root}" ]; then
		add_baseline_from_problem "a dispatch of repo_root ${earlier_repo_root}; expected a dispatch of --repo-root ${repo_root}"
		return 0
	fi
	read_earlier_baseline
}

add_baseline_from_problem() {
	add_problem --baseline-from "${baseline_from}" "$1"
}

# Succeeds when path $1 is a file directly in kind folder $2 of the --effort
# folder; otherwise adds a --baseline-from problem, its subject $3 ("is", or
# "its baseline file <path> is") and the expected file $4, and fails, so
# nothing outside that folder is read. With the space refused nothing is
# checked, and with --effort refused only the space rules' layout: their
# problem is reported already, and it fails all the same.
in_effort_folder() {
	[ "${space_ok}" = true ] || return 1
	# shellcheck disable=SC2310 # its status is the test result; the problem is read below
	if ! crucible_check_effort_item "$1" "$2"; then
		add_baseline_from_problem "$3 ${crucible_item_problem}"
		return 1
	fi
	[ -n "${effort_dir}" ] || return 1
	[ "${crucible_effort}" != "${effort_dir}" ] || return 0
	add_baseline_from_problem "$3 in effort ${crucible_effort}; expected $4 in ${effort_dir}/$2/, the folder of --effort"
	return 1
}

# Prints the lines of $1 joined by "; ".
joined_lines() {
	joined=''
	while IFS= read -r joined_line; do
		joined="${joined}${joined:+; }${joined_line}"
	done <<EOF
$1
EOF
	printf '%s' "${joined}"
}

# Copies the earlier dispatch's baseline file once into earlier_baseline_copy
# and adds a problem unless that copy is a baseline of repo_root.
read_earlier_baseline() {
	# shellcheck disable=SC2310 # its status says whether the path is the effort's; the problem is added inside
	in_effort_folder "${earlier_baseline}" "${BASELINE_KIND}" "its baseline file ${earlier_baseline} is" 'the baseline file generate-agent-dispatch.sh made' || return 0
	if [ -L "${earlier_baseline}" ] || [ ! -f "${earlier_baseline}" ] || [ ! -r "${earlier_baseline}" ]; then
		add_baseline_from_problem "its baseline file ${earlier_baseline} is missing, unreadable, a symlink or not a regular file; expected the regular file the Agent hook or --direct filled"
		return 0
	fi
	earlier_baseline_copy=$(mktemp "${TMPDIR:-/tmp}/${PROG}.XXXXXX") ||
		die 5 "mktemp could not create a temp file in \${TMPDIR:-/tmp}; expected a writable temp folder; try checking its permissions and free space, then rerun"
	if ! cat -- "${earlier_baseline}" >"${earlier_baseline_copy}"; then
		add_baseline_from_problem "its baseline file ${earlier_baseline} cannot be read; expected the regular file the Agent hook or --direct filled"
		return 0
	fi
	if [ ! -s "${earlier_baseline_copy}" ]; then
		add_baseline_from_problem "${BASELINE_EMPTY_TOKEN} its baseline file ${earlier_baseline} is empty: that dispatch never went through the Agent hook or --direct; expected its filled baseline"
		return 0
	fi
	if ! jq empty "${earlier_baseline_copy}" </dev/null >/dev/null 2>&1; then
		add_baseline_from_problem "its baseline file ${earlier_baseline} is not JSON; expected a baseline of ${repo_root}"
		return 0
	fi
	earlier_shape=$(jq -rs -L "${dispatch_dir}" --arg repo_root "${repo_root}" \
		"include \"${NAMES_MODULE}\"; if length == 1 then .[0] | baseline_problems(\$repo_root) else \"\\(length) JSON values; expected one object\" end" \
		"${earlier_baseline_copy}" </dev/null) ||
		die 5 "jq failed on the baseline shape in ${names_module}; expected jq 1.6+; try jq --version, then rerun"
	[ -n "${earlier_shape}" ] || return 0
	earlier_shape=$(joined_lines "${earlier_shape}")
	add_baseline_from_problem "its baseline file ${earlier_baseline} holds no baseline of ${repo_root} (${earlier_shape}); expected the baseline the Agent hook or --direct wrote"
}

# Runs DISPATCH_JQ in mode $1 with id $2, started $3, report $4 and baseline
# $5, over the starting points after them.
run_dispatch_jq() {
	run_mode=$1 run_id=$2 run_started=$3 run_report=$4 run_baseline=$5
	shift 5
	jq -n --arg prog "${PROG}" --arg mode_of_run "${run_mode}" --arg id "${run_id}" --arg started "${run_started}" \
		--arg agent "${agent}" --arg mode "${mode}" --arg tech "${tech}" \
		--arg plugin_paths "${plugin_paths}" --arg skills_dir "${skills_dir}" \
		--arg plan_sha256 "${plan_sha256}" \
		--arg context_path "${context_path}" --arg context_sha256 "${plan_context_sha256}" \
		--arg task "${task}" --arg task_number "${task_number}" --arg repo_root "${repo_root}" \
		--arg report "${run_report}" --arg baseline "${run_baseline}" --arg space_root "${space_root}" \
		--arg validator_problem_lines "${validator_problems}" \
		--arg plan_known "${plan_ok}" --arg task_known "${task_known}" \
		-r "${DISPATCH_JQ}" --args -- "$@" </dev/null
}

# Adds the problems the dispatch validator finds in the dispatch built with
# the stand-ins, named by option.
check_planned_dispatch() {
	# shellcheck disable=SC2310 # its status is jq's; a failure exits
	planned_dispatch=$(run_dispatch_jq dispatch "${PLACEHOLDER_ID}" "${PLACEHOLDER_STARTED}" "${placeholder_report}" "${placeholder_baseline}" "$@") ||
		die 5 "jq failed building the dispatch; expected jq 1.6+ (--args, \$ARGS); try jq --version, then rerun"
	validator_problems=$(printf '%s\n' "${planned_dispatch}" | jq -cs --arg format json -f "${dispatch_validator}") ||
		die 5 'jq failed on the dispatch validator; expected jq 1.6+; try jq --version, then rerun'
	# shellcheck disable=SC2310 # its status is jq's; a failure exits
	named_problems=$(run_dispatch_jq report '' '' '' '' "$@") ||
		die 5 "jq failed naming the dispatch problems; expected jq 1.6+; try jq --version, then rerun"
	[ -z "${named_problems}" ] || problems="${problems}${named_problems}${NL}"
}

# Sets created_path to a new empty file crucible.sh made of kind $1 with
# label $2 in the effort, or fails the run.
create_item() {
	created_path=$(sh "${crucible_script}" new --kind "$1" --label "$2" --effort "${effort_dir}" </dev/null) ||
		fail_run "crucible.sh new --kind $1 --label $2 failed; expected it to make an empty file in ${effort_dir}/$1/ and print its path; try the crucible.sh error above, check that the effort folder is writable, then rerun"
	case ${created_path} in
		/*.json) ;;
		*) fail_run "crucible.sh new --kind $1 printed no file path; expected one absolute path ending in .json; try sh ${crucible_script} --help to check its install, reinstall the crucible skill if that fails, then rerun" ;;
	esac
	created_files="${created_files}${created_files:+${NL}}${created_path}"
	[ -f "${created_path}" ] && [ ! -L "${created_path}" ] && [ ! -s "${created_path}" ] ||
		fail_run "crucible.sh new printed ${created_path}, which is not an empty regular file; expected a new empty file in the Crucible space; try checking that nothing else writes to ${created_path%/*}, then rerun"
}

# Removes the files this run made, names them, and exits 1 with $1.
fail_run() {
	remove_created_files
	die 1 "$1"
}

# Removes and names the files this run made.
remove_created_files() {
	[ -n "${created_files}" ] || return 0
	while IFS= read -r created_file; do
		rm -f "${created_file}" && warn "removed ${created_file}, made by this run"
	done <<EOF
${created_files}
EOF
	created_files=''
}

# Makes an empty file of kind $1 labelled <agent>-$2 and checks it lies
# directly in that kind folder of the effort; sets created_path.
make_space_file() {
	create_item "$1" "${agent_label}-$2"
	# shellcheck disable=SC2310 # its status is the test result; a failure fails the run
	crucible_check_effort_item "${created_path}" "$1" && [ "${crucible_effort}" = "${effort_dir}" ] ||
		fail_run "the $2 file ${created_path} is not in ${effort_dir}/$1/; expected crucible.sh to use the same CRUCIBLE_HOME; try exporting CRUCIBLE_HOME once for both, then rerun"
}

# Writes the earlier baseline's checked bytes into the new baseline file,
# through a temp file in its folder moved onto it.
copy_earlier_baseline() {
	temp_file=$(mktemp "${baseline_path%/*}/.${baseline_path##*/}.XXXXXX") ||
		fail_run "mktemp could not create a temp file beside ${baseline_path}; expected a writable folder ${baseline_path%/*}; try checking its permissions and free space, then rerun"
	cat -- "${earlier_baseline_copy}" >"${temp_file}" ||
		fail_run "could not write the temp file ${temp_file}; expected a writable folder ${baseline_path%/*}; try checking its free space, then rerun"
	mv -f "${temp_file}" "${baseline_path}" ||
		fail_run "mv could not move the temp file onto ${baseline_path}; expected a writable folder ${baseline_path%/*}; try checking its permissions, then rerun"
	temp_file=''
}

# Makes, writes and checks the dispatch file; sets dispatch_path.
write_dispatch() {
	create_item "${DISPATCH_KIND}" "${agent_label}-dispatch"
	dispatch_path=${created_path}
	dispatch_name=${dispatch_path##*/}
	# shellcheck disable=SC2310 # a pure test; a failure fails the run
	crucible_split_id "${dispatch_name}" ||
		fail_run "crucible.sh new printed ${dispatch_path}, whose name holds no Crucible ID; expected <ID>-<label>.json; try reinstalling the crucible skill, then rerun"
	dispatch_id=${crucible_name_id}
	started_raw=$(date +%Y-%m-%dT%H:%M:%S%z) || fail_run 'date failed; expected it to print the local time as +%Y-%m-%dT%H:%M:%S%z; try date +%Y-%m-%dT%H:%M:%S%z by hand, fix your system date tool, then rerun'
	started="${started_raw%??}:${started_raw#"${started_raw%??}"}"
	# shellcheck disable=SC2310 # its status is jq's; a failure fails the run
	dispatch_json=$(run_dispatch_jq dispatch "${dispatch_id}" "${started}" "${report_path}" "${baseline_path}" "$@") ||
		fail_run "jq failed building the dispatch; expected jq 1.6+ (--args, \$ARGS); try jq --version, then rerun"
	final_problems=$(printf '%s\n' "${dispatch_json}" | jq -rs -f "${dispatch_validator}") ||
		fail_run 'jq failed on the dispatch validator; expected jq 1.6+; try jq --version, then rerun'
	[ -z "${final_problems}" ] || fail_run "the dispatch would fail its validator: ${final_problems}"
	temp_file=$(mktemp "${dispatch_path%/*}/.${dispatch_name}.XXXXXX") ||
		fail_run "mktemp could not create a temp file beside ${dispatch_path}; expected a writable folder ${dispatch_path%/*}; try checking its permissions and free space, then rerun"
	printf '%s\n' "${dispatch_json}" >"${temp_file}" ||
		fail_run "could not write the temp file ${temp_file}; expected a writable folder ${dispatch_path%/*}; try checking its free space, then rerun"
	mv -f "${temp_file}" "${dispatch_path}" ||
		fail_run "mv could not move the temp file onto ${dispatch_path}; expected a writable folder ${dispatch_path%/*}; try checking its permissions and free space, then rerun"
	temp_file=''
	written_problems=$(jq -rs -f "${dispatch_validator}" "${dispatch_path}" </dev/null) ||
		fail_run "the written dispatch ${dispatch_path} is not valid JSON; expected the JSON this run wrote; try checking that nothing else writes to ${dispatch_path%/*}, then rerun"
	[ -z "${written_problems}" ] || fail_run "the written dispatch fails its validator: ${written_problems}"
}

temp_file=''
earlier_baseline_copy=''
created_files=''
trap clean_up EXIT
# A signal exits through the EXIT trap, so the temp files go on every path.
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

[ "$#" -gt 0 ] || {
	usage >&2
	exit 2
}
given_effort='' plan_sha256='' task_number='' repo_root='' skills_dir='' given_skills_dir='' baseline_from='' seen_options='' awaited_option=''
# Each --starting-point is appended to the positional parameters; "for" walks
# the original arguments only, which are shifted away after the loop.
argument_count=$#
for argument do
	if [ -z "${awaited_option}" ]; then
		take_option "${argument}"
		continue
	fi
	if [ "${awaited_option}" = --starting-point ]; then
		set -- "$@" "${argument}"
	else
		take_value "${awaited_option}" "${argument}"
	fi
	awaited_option=''
done
finish_parse
shift "${argument_count}"

for tool in ${REQUIRED_TOOLS}; do
	command -v "${tool}" >/dev/null 2>&1 && continue
	case ${tool} in
	git) die 5 "git missing; expected it on PATH; install it (macOS: xcode-select --install; Linux: the distro's git package)" ;;
	*) die 5 "${tool} missing; expected it on PATH; install your base system's ${tool}" ;;
	esac
done

problems='' validator_problems='' plan_sha256_ok=true task_number_ok=true plan_ok=false
load_dependencies
resolve_space_root
check_skills_dir
check_plan_sha256
check_task_number
check_repo_root
# Stand-ins for what the plan gives, so the dispatch check still reports the
# options' own problems when the plan is not found or not valid.
agent=code-developer mode=BUILD tech=none plugin_paths='' labels_line='' context_path=/ plan_context_sha256=''
task=${TASK_STAND_IN} task_known=false
record_path=''
check_effort_option
[ "${plan_sha256_ok}" = false ] || find_plan_record
if [ -n "${record_path}" ]; then
	read_installed
	check_plan
fi
if [ "${plan_ok}" = true ]; then
	pick_task
	check_context
	resolve_plugins
fi
plan_space_paths
check_planned_dispatch "$@"
[ -z "${baseline_from}" ] || check_baseline_from
if [ -n "${problems}" ]; then
	printf '%s' "${problems}" >&2
	exit 3
fi

# The dispatch check refuses an agent with no report kind; this guards a
# drift between it and the shared names.
[ -n "${report_kind}" ] ||
	die 5 "${NAMES_MODULE}.jq names no report kind for agent \"${agent}\", which its dispatch check passed; expected one for every dispatched agent; reinstall the ${PROCEDURE} skill"
make_space_file "${report_kind}" report
report_path=${created_path}
# Left empty without --baseline-from: prepare-agent-prompt.sh writes git
# status into it at the Agent call, which for a dispatch waiting on another's
# result comes much later.
make_space_file "${BASELINE_KIND}" baseline
baseline_path=${created_path}
[ -z "${baseline_from}" ] || copy_earlier_baseline
write_dispatch "$@"
printf 'DISPATCH: %s\n%s\n' "${dispatch_path}" "${labels_line}"
