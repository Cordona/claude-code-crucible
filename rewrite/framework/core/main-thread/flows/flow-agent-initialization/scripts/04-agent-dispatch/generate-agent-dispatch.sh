#!/usr/bin/env sh
# Writes one agent dispatch file from the plan the human approved at this
# session's gate, so a dispatch is never assembled by hand. The plan is found
# by its digest among the session's gates records, the plan the human was
# shown; it is checked again by dispatch-plan-validator.jq, its context file by
# procedure-context's agent-context-file-checks.sh, agent-context-validator.jq
# and context-versions.sh and by its digest,
# its plugins resolved to files by plugin-files.sh, and the dispatch checked by
# agent-dispatch-validator.jq before and after it is written. Every problem is
# named by the option behind it; no file is left behind on a problem.
# shellcheck source-path=SCRIPTDIR
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
readonly PLACEHOLDER_REPORT_ITEM='0000/00/00/reports/00000000T000000-0000'
readonly PLACEHOLDER_DAY='0000/00/00'
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
	plan: {path: $plan_path, sha256: $plan_sha256},
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
Usage: sh ${PROG} --session ID --plan-sha256 HEX --task N --repo-root PATH
           [--starting-point REL]... [--skills-dir DIR] [--baseline-from DISPATCH]
       sh ${PROG} --help

Writes one agent dispatch file for task N of the plan the human approved, and
allocates the agent's report file and the dispatch's baseline file. Every
input is checked first; on a problem no file is left behind, though the
index lines crucible.sh new appended stay (see the writes below).

  --session ID       the Claude Code session whose gates records are searched,
                     and the session of the files made.
  --plan-sha256 HEX  the PLAN_SHA256 generate-dispatch-plan.sh printed: 64
                     lowercase hex. The gate record is the session's gates
                     item labelled ${PLAN_RECORD_LABEL} (crucible.sh find,
                     newest first) whose content without its top-level "v"
                     hashes to HEX in canonical form (the one line
                     jq -cS 'del(.v)' prints, its newline included).
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
                     DIR/${PROCEDURE}/scripts/03-dispatch-plan/list-plugins.sh --max-lines 0.
  --baseline-from DISPATCH  an earlier dispatch file of this task, the one a
                     resend replaces (that it is of this task is the
                     caller's to hold: only the checks below are made): the
                     new dispatch's baseline file gets a
                     byte-for-byte copy of DISPATCH's filled baseline, so the
                     baseline stays the tree before the first call. DISPATCH
                     must be absolute, a regular file, not a symlink, pass
                     agent-dispatch-validator.jq and have repo_root PATH; its
                     baseline file must lie inside the Crucible space, be a
                     regular file, not a symlink, not empty, and hold a
                     baseline of PATH (baseline_problems in ${NAMES_MODULE}.jq).

Checks, all before any file is made:
  - the plan: scripts/03-dispatch-plan/dispatch-plan-validator.jq against the
    installed plugins, as generate-dispatch-plan.sh checks it
  - its context file: the path checks of
    DIR/${CONTEXT_PROCEDURE}/scripts/agent-context-file-checks.sh, a readable
    regular file that is not a symlink, at most the size cap, and
    DIR/${CONTEXT_PROCEDURE}/scripts/agent-context-validator.jq; a version file
    in an effort's context/ folder (<...>/efforts/<effort>/context/<id>-v<N>.json)
    must still be that effort's latest version, as
    DIR/${CONTEXT_PROCEDURE}/scripts/context-versions.sh finds it (any other
    context file is not checked for a version); and its sha256 must still be
    the plan's context.sha256
  - the dispatch: scripts/04-agent-dispatch/agent-dispatch-validator.jq, which
    among its rules dispatches only agents code-developer, code-reviewer and
    "main thread" (direct implementation, with no tech plugin), in mode BUILD
    (TEST is refused for now)
A gate record that no longer passes dispatch-plan-validator.jq's current
rules is refused; regenerate the plan at the flow's step 7. Its "v" is not
read.
The loaded plugins' files are scripts/04-agent-dispatch/plugin-files.sh's:
role developer for code-developer and "main thread" (SKILL.md,
references/development.md, each references/*-template.md), role reviewer for
code-reviewer (SKILL.md, references/review.md when readable), the tech
plugin's files first (its base first), then the standard and procedure
plugins in plugin-line order. A based tech plugin's base files form their
own plugins entry, named after the base's folder (tech-<base>), before the
tech plugin's entry, even though the plan lists that base as not loaded.

Then the report file is made by crucible.sh new --kind reports --label
<agent>-report --session ID (<agent> being main-thread for "main thread"),
the baseline file by crucible.sh new --kind baselines --label
<agent>-baseline --session ID (each must be empty, inside the Crucible space
\${CRUCIBLE_HOME:-\$HOME/.crucible}, and not under PATH), and the dispatch file
by crucible.sh new --kind dispatches --label <agent>-dispatch --session ID,
written to a temp file in its folder, moved onto its path and checked again.
Each crucible.sh new also appends the item's line to the day's index.jsonl
in the Crucible space; a file this run removes on a failure keeps its index
line.
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
   "plan": {"path": <the gate record>, "sha256": HEX},
     (kept for audit: the gate record the dispatch came from)
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
A problem of the plan or its context file names --plan-sha256; one of the
report or baseline file's place names CRUCIBLE_HOME. A context file whose
sha256 is no longer the plan's context.sha256 gives this line (sha256s cut to
12 digits):
  ${PROG}: --plan-sha256 "<HEX>": the plan's context file <path>: changed since the plan was shown (sha256 <shown> shown, <now> now); expected it as shown; show the plan again for the changed file
and a version that is no longer its effort's latest gives this one:
  ${PROG}: --plan-sha256 "<HEX>": the plan's context file <path>: is version v<N> of its effort, not the latest (v<M>: <latest path>); expected the latest version; show the plan again at its gate with it
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
     names them); their index lines stay
  2  usage error: an unknown option, an option without its value or with an
     empty one, a second --session, --plan-sha256, --task, --repo-root,
     --skills-dir or --baseline-from, or one of the first four missing.
     --help and usage errors are handled before the tool check below, so
     they need only cat (for --help) and tr (to show an unknown option)
  3  invalid input, one stderr line per problem, a --baseline-from DISPATCH
     that is not a valid dispatch of PATH or whose baseline is empty or not
     a baseline of PATH among them; no file made
  5  a dependency missing or failing, with the fix named: jq 1.6+, git,
     sha256sum or shasum, crucible.sh, list-plugins.sh, the checks and helpers
     named above, a base tool below, or mktemp failing while --baseline-from
     is checked; no file made
  129, 130, 143  stopped by HUP, INT or TERM; the temp files and the files
     this run made are removed (stderr names them); their index lines stay.
     A crucible.sh new still running when the signal lands is not stopped:
     it may still make its empty file and index line after this exit

Dependencies: POSIX sh; jq 1.6+ (--args, \$ARGS; macOS: brew install jq;
Linux: the distro's jq package); git (macOS: xcode-select --install; Linux:
the distro's git package); awk, cat, date (+%z), mktemp, mv, rm, tr, wc, in
every macOS and Linux base system; sha256sum (Linux: coreutils) or shasum
(macOS: built in, run as shasum -a 256); crucible.sh; list-plugins.sh; the
${CONTEXT_PROCEDURE} skill's agent-context-file-checks.sh,
agent-context-validator.jq and context-versions.sh in
DIR/${CONTEXT_PROCEDURE}/scripts/; scripts/03-dispatch-plan/dispatch-plan-validator.jq
and installed-plugins.jq; plugin-files.sh, agent-dispatch-validator.jq and
${NAMES_MODULE}.jq beside this script.
Reads only: the session's gates records and, through crucible.sh find, the
Crucible space's index.jsonl files; the plan's context file and, when it is
a version file in an effort's context/, the names in that folder; git's view of
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
		--session | --plan-sha256 | --task | --repo-root | --starting-point | --skills-dir | --baseline-from) awaited_option=$1 ;;
		*)
			shown_option=$(printable "$1")
			usage_error "unknown option: ${shown_option}; expected --session, --plan-sha256, --task, --repo-root, --starting-point, --skills-dir, --baseline-from or --help"
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
		--session) session=$2 ;;
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
	for required in --session --plan-sha256 --task --repo-root; do
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
	context_dir="${skills_dir}/${CONTEXT_PROCEDURE}/scripts"
	context_lib="${context_dir}/agent-context-file-checks.sh"
	context_validator="${context_dir}/agent-context-validator.jq"
	versions_lib="${context_dir}/context-versions.sh"
	for context_file_needed in "${context_lib}" "${context_validator}" "${versions_lib}"; do
		[ -f "${context_file_needed}" ] && [ -r "${context_file_needed}" ] ||
			die 5 "context check missing; expected ${context_file_needed}; install the ${CONTEXT_PROCEDURE} skill"
	done
	dispatch_dir=$(script_dir)
	plan_validator="${dispatch_dir}/../03-dispatch-plan/dispatch-plan-validator.jq"
	installed_program="${dispatch_dir}/../03-dispatch-plan/installed-plugins.jq"
	plugin_lib="${dispatch_dir}/plugin-files.sh"
	dispatch_validator="${dispatch_dir}/agent-dispatch-validator.jq"
	names_module="${dispatch_dir}/${NAMES_MODULE}.jq"
	for shared_file in "${plan_validator}" "${installed_program}" \
		"${plugin_lib}" "${dispatch_validator}" "${names_module}"; do
		[ -f "${shared_file}" ] && [ -r "${shared_file}" ] ||
			die 5 "shared check or helper missing; expected ${shared_file}; reinstall the ${PROCEDURE} skill"
	done
	DIRECT_AGENT=$(jq -nr -L "${dispatch_dir}" "include \"${NAMES_MODULE}\"; direct_agent" </dev/null) &&
		[ -n "${DIRECT_AGENT}" ] ||
		die 5 "jq could not read direct_agent from ${names_module}; expected jq 1.6+ and the ${PROCEDURE} skill's shared names; try jq --version, or reinstall the skill"
	readonly DIRECT_AGENT
	BASELINE_KIND=$(jq -nr -L "${dispatch_dir}" "include \"${NAMES_MODULE}\"; baseline_kind" </dev/null) &&
		[ -n "${BASELINE_KIND}" ] ||
		die 5 "jq could not read baseline_kind from ${names_module}; expected jq 1.6+ and the ${PROCEDURE} skill's shared names; try jq --version, or reinstall the skill"
	readonly BASELINE_KIND
	# shellcheck source=../../../../procedures/procedure-context/scripts/agent-context-file-checks.sh
	. "${context_lib}"
	# shellcheck source=../../../../procedures/procedure-context/scripts/context-versions.sh
	. "${versions_lib}"
	# shellcheck source=plugin-files.sh
	. "${plugin_lib}"
	# shellcheck disable=SC2310 # its status is the lookup result; errexit adds nothing
	find_context_digest_tool ||
		die 5 'sha256sum and shasum missing; expected one of them on PATH; install coreutils (Linux) or use the system shasum (macOS)'
	crucible_script="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/skills/crucible/scripts/crucible.sh"
	[ -f "${crucible_script}" ] && [ -r "${crucible_script}" ] ||
		die 5 "crucible.sh missing; expected ${crucible_script}; install the crucible skill"
	list_script="${skills_dir}/${PROCEDURE}/scripts/03-dispatch-plan/list-plugins.sh"
	[ -f "${list_script}" ] && [ -r "${list_script}" ] ||
		die 5 "list-plugins.sh missing; expected ${list_script}; install the ${PROCEDURE} skill"
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

# Sets record_path to the session's gates record whose plan hashes to
# plan_sha256, or adds a problem.
find_plan_record() {
	record_path=''
	if ! record_candidates=$(sh "${crucible_script}" find --kind gates --session "${session}" --label "${PLAN_RECORD_LABEL}" </dev/null); then
		die 5 'crucible.sh find failed; its stderr is above; fix what it names, then rerun'
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
	add_problem --plan-sha256 "${plan_sha256}" 'no gate record of this session holds that plan; expected the PLAN_SHA256 of a plan shown and asked about at this session'\''s gate'
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

# Adds a problem for each finding of the context file's checks, and when it
# changed since the plan was shown.
check_context() {
	path_problem=$(context_path_problem "${context_path}")
	if [ -n "${path_problem}" ]; then
		add_context_problem "${path_problem}; expected ${context_path_expected}"
		return 0
	fi
	if [ -L "${context_path}" ] || [ ! -f "${context_path}" ] || [ ! -r "${context_path}" ]; then
		add_context_problem 'is missing, unreadable, a symlink or not a regular file; expected the context file the plan was shown with'
		return 0
	fi
	context_size=$(wc -c <"${context_path}") || die 5 "wc could not count the bytes of ${context_path}; expected a byte count; check wc, then rerun"
	context_size=${context_size##* }
	if [ "${context_size}" -gt "${context_max_bytes}" ]; then
		add_context_problem "is ${context_size} bytes; expected at most ${context_max_bytes} bytes"
		return 0
	fi
	if ! jq empty "${context_path}" </dev/null >/dev/null 2>&1; then
		add_context_problem 'is not valid JSON; expected one JSON object'
		return 0
	fi
	shape_report=$(jq -rs --arg context_path "${context_path}" -f "${context_validator}" "${context_path}" </dev/null) ||
		die 5 'jq failed on the context validator; expected jq 1.6+; try jq --version, then rerun'
	if [ -n "${shape_report}" ]; then
		while IFS= read -r shape_line; do
			add_context_problem "${shape_line}"
		done <<EOF
${shape_report}
EOF
		return 0
	fi
	stale_problem=$(context_stale_version_problem "${context_path}")
	if [ -n "${stale_problem}" ]; then
		add_context_problem "${stale_problem}; expected the latest version; show the plan again at its gate with it"
		return 0
	fi
	# shellcheck disable=SC2310 # its status is the tool's; a failure exits
	compute_context_digest "${context_path}" ||
		die 5 "${context_digest_tool} could not hash ${context_path}; check the tool, then rerun"
	[ "${context_digest}" = "${plan_context_sha256}" ] ||
		add_context_problem "changed since the plan was shown (sha256 $(printf '%.12s' "${plan_context_sha256}") shown, $(printf '%.12s' "${context_digest}") now); expected it as shown; show the plan again for the changed file"
}

add_context_problem() {
	add_problem --plan-sha256 "${plan_sha256}" "the plan's context file ${context_path}: $1"
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

# Sets space_root, agent_label (the agent as it goes into a Crucible label:
# main-thread for "main thread"), and placeholder_report and
# placeholder_baseline, the stand-ins for the two paths crucible.sh new makes.
plan_space_paths() {
	space_root="${CRUCIBLE_HOME:-${HOME:-}/.crucible}"
	while [ "${space_root}" != '/' ] && [ "${space_root%/}" != "${space_root}" ]; do
		space_root=${space_root%/}
	done
	agent_label=${agent}
	[ "${agent}" != "${DIRECT_AGENT}" ] || agent_label=${DIRECT_LABEL}
	placeholder_report="${space_root}/${PLACEHOLDER_REPORT_ITEM}-${agent_label}-report.json"
	placeholder_baseline="${space_root}/${PLACEHOLDER_DAY}/${BASELINE_KIND}/${PLACEHOLDER_ID}-${agent_label}-baseline.json"
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
	case ${earlier_baseline} in
		"${space_root}"/*) ;;
		*)
			add_baseline_from_problem "its baseline file ${earlier_baseline} is not inside the Crucible space ${space_root}; expected the baseline file generate-agent-dispatch.sh made"
			return 0
			;;
	esac
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
		add_baseline_from_problem "its baseline file ${earlier_baseline} is empty: that dispatch never went through the Agent hook or --direct; expected its filled baseline"
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
		--arg plan_path "${record_path}" --arg plan_sha256 "${plan_sha256}" \
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

# Sets created_path to a new empty file crucible.sh made of kind $1 with label $2, or fails the run.
create_item() {
	created_path=$(sh "${crucible_script}" new --kind "$1" --label "$2" --session "${session}" </dev/null) ||
		fail_run "crucible.sh new --kind $1 --label $2 failed; expected it to make an empty file in the Crucible space and print its path; try the crucible.sh error above, check that CRUCIBLE_HOME is writable, then rerun"
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

# Removes and names the files this run made; their index lines stay.
remove_created_files() {
	[ -n "${created_files}" ] || return 0
	while IFS= read -r created_file; do
		rm -f "${created_file}" && warn "removed ${created_file}, made by this run"
	done <<EOF
${created_files}
EOF
	created_files=''
}

# Makes an empty file of kind $1 labelled <agent>-$2 and checks it lies in
# the Crucible space; sets created_path.
make_space_file() {
	create_item "$1" "${agent_label}-$2"
	case ${created_path} in
		"${space_root}"/*) ;;
		*) fail_run "the $2 file ${created_path} is not inside the Crucible space ${space_root}; expected crucible.sh to use the same CRUCIBLE_HOME; try exporting CRUCIBLE_HOME once for both, then rerun" ;;
	esac
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
	create_item dispatches "${agent_label}-dispatch"
	dispatch_path=${created_path}
	dispatch_name=${dispatch_path##*/}
	dispatch_id=$(printf '%.20s' "${dispatch_name}")
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
session='' plan_sha256='' task_number='' repo_root='' skills_dir='' given_skills_dir='' baseline_from='' seen_options='' awaited_option=''
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
check_skills_dir
check_plan_sha256
check_task_number
check_repo_root
# Stand-ins for what the plan gives, so the dispatch check still reports the
# options' own problems when the plan is not found or not valid.
agent=code-developer mode=BUILD tech=none plugin_paths='' labels_line='' context_path=/ plan_context_sha256=''
task=${TASK_STAND_IN} task_known=false
record_path=''
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

make_space_file reports report
report_path=${created_path}
# Left empty without --baseline-from: prepare-agent-prompt.sh writes git
# status into it at the Agent call, which for a dispatch waiting on another's
# result comes much later.
make_space_file "${BASELINE_KIND}" baseline
baseline_path=${created_path}
[ -z "${baseline_from}" ] || copy_earlier_baseline
write_dispatch "$@"
printf 'DISPATCH: %s\n%s\n' "${dispatch_path}" "${labels_line}"
