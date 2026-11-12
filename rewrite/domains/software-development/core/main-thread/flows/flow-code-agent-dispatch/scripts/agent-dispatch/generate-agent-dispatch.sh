#!/usr/bin/env sh
# Writes one agent dispatch, a dispatch.made event of its effort, from the
# plan the human approved at its effort's gate, so a dispatch is never
# assembled by hand. The plan is the newest plan.made event whose body hashes
# to the digest given; the newest gate.dispatch-plan.answered event of that
# plan must approve it, at most 7 days old; and the context version it pins
# must still be the one its effort's docs and pending entries give. The seat
# --seat names must be one of the effort's seats with the plan's mode, since
# the plugins the plan chose depend on it; procedure-git-worktree's seats.sh
# reads it. The plan is checked again by dispatch-plan-validator.jq; its
# fingerprint against procedure-context's context.sh freeze --dry-run; its
# plugins are resolved to files by plugin-files.sh, and the agent's title is
# built by human-view's title; and the dispatch is checked by
# agent-dispatch-validator.jq, after crucible's prune leaves out each key with
# nothing in it. Only once every check passes and the effort is open does
# context.sh freeze --expect cut the version, or return the one already cut;
# the cut context.cut event passes agent-context-file-checks.sh's checks and
# the dispatch pins it by seq and path. The dispatch, named by an ID
# crucible.sh id hands out, is appended through the crucible skill's
# events.sh; nothing goes into the worktree or git.
# A re-seat (--reseat) needs no plan digest and no gate: once seats.sh
# handover has freed the seat, it repeats the seat's last dispatch.made with
# the same plan and context, a fresh ID, and the re-seat keys. Every problem
# is named by the option behind it.
# shellcheck source-path=SCRIPTDIR source-path=SCRIPTDIR/../../../../../../../../framework/core/engine/crucible/scripts/lib source-path=SCRIPTDIR/../../../../../../../../framework/core/main-thread/procedures/procedure-context/scripts
set -eu
umask 077

readonly PROG='generate-agent-dispatch.sh'
readonly PROCEDURE='flow-code-agent-dispatch'
readonly CONTEXT_PROCEDURE='procedure-context'
# context.sh freeze's refusal exit: nothing was written.
readonly FREEZE_REFUSED_EXIT=3
readonly REQUIRED_TOOLS='awk cat date mktemp rm tr wc'
readonly PLAN_EVENT='plan.made'
readonly GATE_EVENT='gate.dispatch-plan.answered'
readonly DISPATCH_EVENT='dispatch.made'
# An approval older than this many seconds (7 days) no longer dispatches.
readonly APPROVAL_MAX_AGE_SECONDS=604800
readonly NAMES_MODULE='dispatch-names'
readonly VIEW_LIB='human-view'
readonly CRUCIBLE_SKILL='crucible'
readonly EFFORT_SKILL='procedure-effort'
readonly WORKTREE_SKILL='procedure-git-worktree'
# The exit of a write refused because the effort is not open.
readonly NOT_OPEN_EXIT=6
# Stands for the ID crucible.sh id hands out once the effort is known open,
# so the dispatch is checked whole before any file exists.
readonly PLACEHOLDER_ID='00000000T000000-0000'
# Stand for the context.cut and plan.made events, for the same check.
readonly PLACEHOLDER_SEQ=1
readonly PLACEHOLDER_CONTEXT='/000001-context.cut.json'
# Lead the problems a caller acts on, so it matches the token exactly, never
# the sentence after it: a plan no approving gate answer holds, a context
# whose docs or pending entries changed since the plan was shown, an effort
# with no approved spec, a docs file's name or the folder's size the cut
# refuses (context.sh freeze's own words for these four), and a plugin
# the plan names that is no longer installed or no longer valid (the Agent
# hook's KIND word for it).
readonly NO_GATE_RECORD_TOKEN='NO-GATE-RECORD'
readonly CONTEXT_CHANGED_TOKEN='CONTEXT-CHANGED'
readonly NO_SPEC_TOKEN='NO-SPEC'
readonly DOCS_NAME_TOKEN='DOCS-NAME'
readonly DOCS_SIZE_TOKEN='DOCS-SIZE'
readonly PLUGIN_TOKEN='PLUGIN'
readonly TASK_STAND_IN='(no task chosen)'
NL='
'
readonly NL
TAB=$(printf '\t')
readonly TAB
# The C locale keeps the shell's pattern checks byte-wise on macOS and Linux.
LC_ALL=C
export LC_ALL

# Builds the dispatch JSON (mode "dispatch") from the named values and the
# entry points as positional arguments, or names each validator problem by
# its option (mode "report": one stderr line each).
# The program is single-quoted on purpose: its $ signs are jq's.
# shellcheck disable=SC2016
readonly DISPATCH_JQ='
include "prune";
# The plugin files, in load order, as one {name, paths} entry per plugin
# folder, the folder being the plugin name.
def plugin_entries: $plugin_paths | split("\n") | map(select(. != ""))
	| reduce .[] as $path ([];
		($path | ltrimstr($skills_dir + "/") | split("/")[0]) as $name
		| if (.[-1].name // null) == $name then .[-1].paths += [$path] else . + [{name: $name, paths: [$path]}] end);
# The entries by kind, the kind read from the name prefix list-plugins.sh
# installs each kind under.
def plugins: plugin_entries as $entries
	| def of_kind($prefix): [$entries[] | select(.name | startswith($prefix))];
	{language: (of_kind("language-") | first), frameworks: of_kind("framework-"),
	 standards: of_kind("standard-"), procedures: of_kind("procedure-")};
def dispatch: {
	id: $id, agent: $agent, seat: $seat, task: $task,
	entry_points: $ARGS.positional,
	context: {seq: $context_seq, path: $context_path},
	plan: {seq: $plan_seq},
	plugins: plugins}
	| prune;

# A long value keeps its start and end, where a path differs most.
def max_shown_chars: 80;
def shown: tojson | gsub("[[:cntrl:]]"; "?") | if length > max_shown_chars then .[:40] + "…" + .[-39:] else . end;
def line($option; $value; $problem): "\($prog): \($option) \($value | shown): \($problem)";
def field_name: map(if type == "number" then "[\(.)]" else "." + . end) | join("") | ltrimstr(".");
# Fields whose value is a stand-in (the plan not found or not valid, or no
# task chosen) are not reported again: their problem is reported already.
def stood_in: (.at[0] | IN("agent", "plugins", "plan", "context")) and $plan_known == "false"
	or .at[0] == "task" and $task_known == "false";
def named_line:
	.at as $at | .problem as $problem
	| if stood_in then empty
	  elif $at[0] == "entry_points" and ($at | length) > 1 then line("--entry-point"; $ARGS.positional[$at[1]]; $problem)
	  elif $at[0] == "seat" then line("--seat"; $seat; "the seat \($problem)")
	  elif $at[0] == "task" then line("--task"; $task_number; "the task \($problem)")
	  elif ($at[0] | IN("agent", "plugins", "plan", "context")) then
		line("--plan-sha256"; $plan_sha256; "the plan'"'"'s \($at | field_name) \($problem)")
	  else "\($prog): dispatch \($at | field_name): \($problem)" end;
def report: $validator_problem_lines | split("\n")[] | select(. != "") | fromjson | named_line;

if $mode_of_run == "report" then report else dispatch end
'

# Prints the TITLE line from the plan file and the installed plugins: a
# code-reviewer standard seat (a standard and no language) is "<standard label>
# <role>"; any other seat is human-view's title of the language label and the
# framework labels in plugin-name order. Labels' control characters print as
# "?", as on the LABELS line.
# The program is single-quoted on purpose: its $ signs are jq's.
# shellcheck disable=SC2016
readonly TITLE_JQ='
include "title";
def plugin_label: $installed[.plugin].label | gsub("[[:cntrl:]]"; "?");
(.plugins.load // {}) as $load
| ($load.standards // []) as $standards
| if $role == "reviewer" and $load.language == null and $standards != [] then "\($standards[0] | plugin_label) \($role)"
  else {language: ($load.language // null | if . == null then null else plugin_label end),
		frameworks: [$load.frameworks // [] | sort_by(.plugin)[] | plugin_label]}
	| title($role)
  end
| "TITLE: \(.)"
'

# Pairs the plan validator's text lines ($lines) with its JSON problems
# ($objects) from the same plan, one to one in order, over the plan on stdin:
# prints "plugin<TAB><name><TAB><field>" for a plugin the plan names that the
# install no longer holds, and "line<TAB><text line>" for any other problem.
# Only a name in the install's name shape is taken as a plugin, so a name never
# reaches a path unchecked; counts that differ print every text line as is.
# The program is single-quoted on purpose: its $ signs are jq's.
# shellcheck disable=SC2016
readonly PLAN_PROBLEMS_JQ='
def plugin_name_shape: "^(language|framework|standard|procedure)-[A-Za-z0-9][A-Za-z0-9._-]*$";
def field_name: map(if type == "number" then "[\(.)]" else "." + . end) | join("") | ltrimstr(".");
def as_line: "line\t\(.)";
. as $plan
| ($lines | split("\n") | map(select(. != ""))) as $texts
| ($objects | split("\n") | map(select(. != "") | fromjson)) as $problems
| if ($texts | length) != ($problems | length) then $texts[] | as_line
  else range($texts | length) as $i
	| $problems[$i] as $problem
	| (if $problem.at[0] == "plugins" and $problem.at[-1] == "plugin" then (try ($plan | getpath($problem.at)) catch null) else null end) as $name
	| if ($name | type) == "string" and $installed[$name] == null and ($name | test(plugin_name_shape))
		and ($problem.problem | startswith("\($name | tojson) is not installed;"))
	  then "plugin\t\($name)\t\($problem.at | field_name)"
	  else $texts[$i] | as_line end
  end
'

# Builds the re-seat dispatch from the seat's last dispatch body on stdin: a
# fresh $id, the same plan, context, task and plugins, and reseat_of,
# continue_from and the notes ($notes, a JSON array) in place of any the last
# one held.
# The program is single-quoted on purpose: its $ signs are jq's.
# shellcheck disable=SC2016
readonly RESEAT_JQ='
include "prune";
del(.reseat_of, .continue_from, .notes)
| .id = $id
| . + {reseat_of: $last_seq, continue_from: $head, notes: $notes}
| prune
'

usage() {
	cat <<EOF
usage: sh ${PROG} --effort FOLDER --plan-sha256 HEX --task N --seat S
           [--entry-point REL]... [--skills-dir DIR]
       sh ${PROG} --effort FOLDER --seat S --reseat [--note TEXT]...
           [--skills-dir DIR]
       sh ${PROG} --help | -h

Appends the ${DISPATCH_EVENT} event for task N of a plan the human approved
at its gate, for seat S of the effort; nothing goes into the worktree or git.

Options:
  --effort FOLDER     the effort folder (rule: crucible.sh --help)
  --plan-sha256 HEX   the PLAN_SHA256 generate-dispatch-plan.sh printed: the
      newest ${PLAN_EVENT} whose body (jq -cS .body) hashes to it, approved by
      the newest ${GATE_EVENT} of its seq, at most 7 days old
  --task N            the task's place in the plan, from 1
  --seat S            a seat of the effort (seats.sh get), like
      build-agent-alpha, with the plan's mode, status open, working or idle,
      and a worktree folder in FOLDER/worktrees/
  --entry-point REL   a repo-relative path the task starts from; repeatable,
      kept in order (entry_points); it need not exist
  --reseat            re-seat S after seats.sh handover (S open, its last
      agent handed out): repeats the ${DISPATCH_EVENT} of S's last seat.bound
      with a fresh id, the same plan and context, reseat_of (its seq),
      continue_from (the worktree's HEAD) and notes; no plan digest, no gate
  --note TEXT         with --reseat, a line for the agent; repeatable, in order
  --skills-dir DIR    must be \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/skills (the
      default); any other DIR exits 3

stdout on exit 0, in order:
  DISPATCH: <absolute path>  the ${DISPATCH_EVENT} event,
    <effort>/events/<seq>-${DISPATCH_EVENT}.json; the Agent call's whole prompt
  LABELS: <labels>  the loaded plugins' labels, relayed as printed
  TITLE: <title>  the agent's title, relayed as printed
stderr on exit 3: one line per problem; a line a caller routes on reads
  "${PROG}: <option> <value>: <problem>" (<value> as JSON)

Once every check passes and the effort is open, context.sh freeze --expect
cuts the plan's version as a context.cut event (or gives the one cut for
that fingerprint; a refusal is exit 3, nothing written), and the dispatch
pins it as {seq, path}, the plan as {seq}. On a non-zero exit no dispatch
event is written; a cut version stays.

Exit codes (1, 2, 5, 6: show stderr and stop):
  0  written; keep the three stdout lines
  1  the inputs passed but the cut or the event failed; no dispatch written
  2  usage error, or a bad CLAUDE_CODE_SESSION_ID
  3  invalid input, nothing written; fix what stderr names. A problem may
     lead with a token right after "<option> <value>: ":
       ${NO_GATE_RECORD_TOKEN}  no plan.made holds the plan, or no approving gate
         answer of it within 7 days; ask it again at its gate
       ${CONTEXT_CHANGED_TOKEN}  the docs or pending entries changed; re-plan
       ${NO_SPEC_TOKEN}  no approved spec; approve one, then re-plan
       ${DOCS_NAME_TOKEN}, ${DOCS_SIZE_TOKEN}  a docs file's name or the folder's size:
         rename, remove or shorten it, then re-plan
       ${PLUGIN_TOKEN} plugin folder <name> uninstalled|invalid  a plugin the plan
         names; re-plan
  5  a dependency is missing or failed, context.sh's other exits included
  ${NOT_OPEN_EXIT}  the effort is not open, or its state is unknown
  129, 130, 143  stopped by HUP, INT or TERM; show the human the exit code,
     and stop

Environment: CLAUDE_CODE_SESSION_ID, required, a lowercase UUID with a session
  transcript

Dependencies:
  POSIX sh; jq 1.6+ (macOS: brew install jq; Linux: the distro's); git, for
    --reseat; sha256sum (Linux: coreutils) or shasum; awk, cat, date,
    mktemp, rm, tr, wc (base system)
  the ${CRUCIBLE_SKILL} (crucible.sh, events.sh, scripts/lib/prune.jq),
    ${CONTEXT_PROCEDURE} (context.sh, agent-context-file-checks.sh),
    ${EFFORT_SKILL} (effort.sh), ${WORKTREE_SKILL} (scripts/seats/seats.sh)
    and ${VIEW_LIB} (title.jq) skills in the default --skills-dir
  this skill's dispatch-plan/ and agent-dispatch/ scripts
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

# Removes the temp files on every exit, a signal included.
# shellcheck disable=SC2329 # invoked by the EXIT trap
clean_up() {
	for owned_file in "${temp_file}" "${freeze_err_file}" "${plan_body_file}" "${last_body_file}"; do
		[ -z "${owned_file}" ] || rm -f "${owned_file}"
	done
}

# Handles option $1 when no option value is awaited: sets awaited_option, or exits 2.
take_option() {
	case $1 in
		--help | -h)
			usage
			exit 0
			;;
		--reseat)
			reseat=true
			seen_options="${seen_options} $1"
			;;
		--effort | --plan-sha256 | --task | --seat | --entry-point | --note | --skills-dir) awaited_option=$1 ;;
		*)
			shown_option=$(printable "$1")
			usage_error "unknown option: ${shown_option}; expected --effort, --plan-sha256, --task, --seat, --entry-point, --reseat, --note, --skills-dir or --help"
			;;
	esac
}

# Appends note $1 to notes_json, a JSON array of the --note values in order.
take_note() {
	[ -n "$1" ] || usage_error '--note is empty; expected --note TEXT'
	notes_json=$(jq -nc --argjson notes "${notes_json}" --arg note "$1" '$notes + [$note]') ||
		die 5 'jq failed collecting --note; expected jq 1.6+; try jq --version, then rerun'
	seen_options="${seen_options} --note"
}

# Takes value $2 of option $1 but --entry-point and --note, which the caller collects.
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
		--seat) seat=$2 ;;
		*) given_skills_dir=$2 ;;
	esac
}

# Exits 2 on an option left without its value, a required option missing or
# an option the run's form does not take (--reseat or not).
finish_parse() {
	[ -z "${awaited_option}" ] || usage_error "${awaited_option} needs a value; expected ${awaited_option} VALUE"
	if [ "${reseat}" = true ]; then
		required_options='--effort --seat' refused_options='--plan-sha256 --task --entry-point' refused_form='without --reseat'
	else
		required_options='--effort --plan-sha256 --task --seat' refused_options='--note' refused_form='with --reseat'
	fi
	for required in ${required_options}; do
		case " ${seen_options} " in
			*" ${required} "*) ;;
			*) usage_error "${required} missing; expected ${required} VALUE" ;;
		esac
	done
	for refused in ${refused_options}; do
		case " ${seen_options} " in
			*" ${refused} "*) usage_error "${refused} is not taken here; expected it only ${refused_form}" ;;
			*) ;;
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

# Exits 5 unless jq, a sha256 tool, crucible.sh, events.sh, context.sh,
# list-plugins.sh, crucible's prune module, human-view's title module,
# seats.sh and every shared check and helper are in place; sources the two
# shell helpers.
load_dependencies() {
	command -v jq >/dev/null 2>&1 ||
		die 5 'jq missing; expected jq 1.6+ on PATH; install it (macOS: brew install jq; Linux: the distro'\''s jq package)'
	context_lib="${skills_dir}/${CONTEXT_PROCEDURE}/scripts/agent-context-file-checks.sh"
	[ -f "${context_lib}" ] && [ -r "${context_lib}" ] ||
		die 5 "context check missing; expected ${context_lib}; install the ${CONTEXT_PROCEDURE} skill"
	context_script="${skills_dir}/${CONTEXT_PROCEDURE}/scripts/context.sh"
	[ -f "${context_script}" ] && [ -r "${context_script}" ] ||
		die 5 "context.sh missing; expected ${context_script}; install the ${CONTEXT_PROCEDURE} skill"
	crucible_skill_dir="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/skills/${CRUCIBLE_SKILL}"
	prune_lib_dir="${crucible_skill_dir}/scripts/lib"
	[ -f "${prune_lib_dir}/prune.jq" ] && [ -r "${prune_lib_dir}/prune.jq" ] ||
		die 5 "prune module missing; expected ${prune_lib_dir}/prune.jq; install the ${CRUCIBLE_SKILL} skill"
	view_lib_dir="${skills_dir}/${VIEW_LIB}"
	[ -f "${view_lib_dir}/title.jq" ] && [ -r "${view_lib_dir}/title.jq" ] ||
		die 5 "title module missing; expected ${view_lib_dir}/title.jq; install the ${VIEW_LIB} skill"
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
	# shellcheck source=../../../../../../../../framework/core/main-thread/procedures/procedure-context/scripts/agent-context-file-checks.sh
	. "${context_lib}"
	# shellcheck disable=SC2310 # its status says whether the checks loaded; the problem is read here
	context_load_checks "${skills_dir}" || die 5 "${context_load_problem}"
	# shellcheck source=plugin-files.sh
	. "${plugin_lib}"
	crucible_script="${crucible_skill_dir}/scripts/crucible.sh"
	[ -f "${crucible_script}" ] && [ -r "${crucible_script}" ] ||
		die 5 "crucible.sh missing; expected ${crucible_script}; install the ${CRUCIBLE_SKILL} skill"
	events_script="${crucible_skill_dir}/scripts/events.sh"
	[ -f "${events_script}" ] && [ -r "${events_script}" ] ||
		die 5 "events.sh missing; expected ${events_script}; install the ${CRUCIBLE_SKILL} skill"
	effort_script="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/skills/${EFFORT_SKILL}/scripts/effort.sh"
	[ -f "${effort_script}" ] && [ -r "${effort_script}" ] ||
		die 5 "effort.sh missing; expected ${effort_script}; install the ${EFFORT_SKILL} skill"
	list_script="${skills_dir}/${PROCEDURE}/scripts/dispatch-plan/list-plugins.sh"
	[ -f "${list_script}" ] && [ -r "${list_script}" ] ||
		die 5 "list-plugins.sh missing; expected ${list_script}; install the ${PROCEDURE} skill"
	seats_script="${skills_dir}/${WORKTREE_SKILL}/scripts/seats/seats.sh"
	[ -f "${seats_script}" ] && [ -r "${seats_script}" ] ||
		die 5 "seats.sh missing; expected ${seats_script}; install the ${WORKTREE_SKILL} skill"
}

# Sets session_id from CLAUDE_CODE_SESSION_ID by the space rules, or exits 2
# before any file is made.
require_session() {
	# shellcheck disable=SC2310 # its status says whether the session is usable; the problem is read here
	crucible_check_session || usage_error "${crucible_session_problem}"
	session_id=${crucible_session_id}
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

# Sets plan_seq and plan_body_file (the plan, the event's body) from the
# newest plan.made event of the effort whose body hashes to plan_sha256, once
# the newest gate answer of that plan approves it; else adds a problem.
find_plan_record() {
	[ -n "${effort_dir}" ] || return 0
	# shellcheck disable=SC2310 # its status says whether the plan is in the effort
	if ! find_plan_event; then
		add_problem --plan-sha256 "${plan_sha256}" "${NO_GATE_RECORD_TOKEN} no ${PLAN_EVENT} event of the effort holds that plan; expected the PLAN_SHA256 generate-dispatch-plan.sh printed for --effort"
		return 0
	fi
	check_gate_answer
	[ -z "${gate_problem}" ] || {
		add_problem --plan-sha256 "${plan_sha256}" "${NO_GATE_RECORD_TOKEN} ${gate_problem}; expected the human's approval at its gate within 7 days; ask it again at its gate"
		return 0
	}
	plan_body_file=$(mktemp "${TMPDIR:-/tmp}/${PROG}.XXXXXX") ||
		die 5 "mktemp could not create a temp file in \${TMPDIR:-/tmp}; expected a writable temp folder; check it, then rerun"
	jq '.body' "${plan_event}" </dev/null >"${plan_body_file}" ||
		die 5 "jq could not read the body of ${plan_event}; expected jq 1.6+; try jq --version, then rerun"
}

# Sets plan_event and plan_seq to the newest plan.made event of effort_dir
# whose body, in canonical form (the one line jq -cS .body prints with its
# newline), hashes to plan_sha256; fails when none does.
find_plan_event() {
	plan_event='' plan_seq=''
	if ! plan_candidates=$(sh "${events_script}" list --effort "${effort_dir}" --type "${PLAN_EVENT}" </dev/null); then
		die 5 'events.sh list failed on --effort; its stderr is above; fix what it names, then rerun'
	fi
	while IFS= read -r candidate; do
		[ -n "${candidate}" ] || continue
		canonical_body=$(jq -cS '.body' "${candidate}" </dev/null 2>/dev/null) || continue
		# shellcheck disable=SC2310 # its status is the tool's; a failure exits
		compute_stdin_digest <<EOF || die 5 "${context_digest_tool} could not hash ${candidate}; check the tool, then rerun"
${canonical_body}
EOF
		if [ "${context_digest}" = "${plan_sha256}" ]; then
			plan_event=${candidate}
		fi
	done <<EOF
${plan_candidates}
EOF
	[ -n "${plan_event}" ] || return 1
	plan_seq=$(jq -r '.seq | numbers' "${plan_event}" </dev/null) ||
		die 5 "jq could not read the seq of ${plan_event}; expected jq 1.6+; try jq --version, then rerun"
	# shellcheck disable=SC2310 # a pure test; a failure exits
	is_seq "${plan_seq}" || die 5 "${plan_event} holds no seq; expected the event events.sh wrote; ask the human to check the effort"
}

# Succeeds when $1 is a seq: a whole number from 1.
is_seq() {
	case $1 in
		'' | 0* | *[!0-9]*) return 1 ;;
		*) return 0 ;;
	esac
}

# Sets gate_problem to why the newest gate.dispatch-plan.answered event of
# plan_seq does not approve the plan now, or to empty when it does.
check_gate_answer() {
	gate_problem=''
	if ! gate_event=$(sh "${events_script}" latest --effort "${effort_dir}" --type "${GATE_EVENT}" --where ".body.plan == ${plan_seq}" </dev/null); then
		die 5 'events.sh latest failed on --effort; its stderr is above; fix what it names, then rerun'
	fi
	if [ -z "${gate_event}" ]; then
		gate_problem="the plan (${PLAN_EVENT} seq ${plan_seq}) has no ${GATE_EVENT} event"
		return 0
	fi
	gate_verdict=$(jq -r --argjson max_age "${APPROVAL_MAX_AGE_SECONDS}" '
		(try (now - (.at | fromdateiso8601)) catch null) as $age
		| if .body.approved != true then "not approved (answer \(.body.answer // "" | tojson))"
		  elif $age == null then "approved at an unreadable time \(.at | tojson)"
		  elif $age > $max_age then "approved at \(.at), more than 7 days ago"
		  else "" end' "${gate_event}" </dev/null) ||
		die 5 "jq could not read ${gate_event}; expected jq 1.6+; try jq --version, then rerun"
	[ -z "${gate_verdict}" ] || gate_problem="the plan (${PLAN_EVENT} seq ${plan_seq}) was ${gate_verdict} at its gate (${gate_event##*/})"
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

# Checks the plan against the validator's current rules; when it fits, sets
# agent, mode, task_count, loaded_names (the plugin names under plugins.load,
# one per line) and plan_fingerprint, and plan_ok=true.
check_plan() {
	plan_ok=false
	plan_record=$(jq -c '.' "${plan_body_file}" </dev/null) ||
		die 5 'jq failed reading the plan; expected jq 1.6+; try jq --version, then rerun'
	plan_report=$(printf '%s\n' "${plan_record}" |
		jq -rs --argjson installed "${installed}" -f "${plan_validator}") ||
		die 5 'jq failed on the plan validator; expected jq 1.6+; try jq --version, then rerun'
	if [ -n "${plan_report}" ]; then
		add_plan_problems
		return 0
	fi
	plan_fields=$(jq -r '.agent, .mode, (.tasks | length), .context.sha256' "${plan_body_file}" </dev/null) ||
		die 5 'jq failed reading the plan; expected jq 1.6+; try jq --version, then rerun'
	{
		IFS= read -r agent
		IFS= read -r mode
		IFS= read -r task_count
		IFS= read -r plan_fingerprint
	} <<EOF
${plan_fields}
EOF
	loaded_names=$(jq -r '.plugins.load // {} | (.language // empty), (.frameworks, .standards, .procedures | arrays[]) | .plugin' "${plan_body_file}" </dev/null) ||
		die 5 'jq failed reading the plan; expected jq 1.6+; try jq --version, then rerun'
	plan_ok=true
}

# Adds a problem per plan validator line in plan_report: a plugin the plan
# names that is no longer installed or valid leads with PLUGIN_TOKEN, any
# other keeps the validator's line.
add_plan_problems() {
	plan_objects=$(printf '%s\n' "${plan_record}" |
		jq -cs --argjson installed "${installed}" --arg format json -f "${plan_validator}") ||
		die 5 'jq failed on the plan validator; expected jq 1.6+; try jq --version, then rerun'
	plan_rows=$(printf '%s\n' "${plan_record}" |
		jq -r --argjson installed "${installed}" --arg lines "${plan_report}" --arg objects "${plan_objects}" "${PLAN_PROBLEMS_JQ}") ||
		die 5 'jq failed sorting the plan problems; expected jq 1.6+; try jq --version, then rerun'
	while IFS= read -r plan_row; do
		case ${plan_row} in
			plugin"${TAB}"*) add_plugin_problem "${plan_row#plugin"${TAB}"}" ;;
			*) add_problem "${plan_option}" "${plan_value}" "the plan's ${plan_row#line"${TAB}"}" ;;
		esac
	done <<EOF
${plan_rows}
EOF
}

# Adds the PLUGIN problem for "<name><TAB><field>" $1: invalid when a folder of
# that name is still in the skills folder, which list-plugins.sh no longer
# lists as valid, else uninstalled.
add_plugin_problem() {
	missing_plugin=${1%%"${TAB}"*}
	plugin_field=${1#*"${TAB}"}
	if [ -e "${skills_dir}/${missing_plugin}" ]; then
		plugin_state="invalid: the plan's ${plugin_field} is in the skills folder but not a valid plugin; expected it fixed (list-plugins.sh --max-lines 0 names why), or the plan re-planned without it"
	else
		plugin_state="uninstalled: the plan's ${plugin_field} is no longer in the skills folder; expected it reinstalled, or the plan re-planned without it"
	fi
	add_problem "${plan_option}" "${plan_value}" "${PLUGIN_TOKEN} plugin folder ${missing_plugin} ${plugin_state}"
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
	task=$(jq -j --argjson n "${task_number}" '.tasks[$n - 1]' "${plan_body_file}" </dev/null) ||
		die 5 'jq failed reading the task; expected jq 1.6+; try jq --version, then rerun'
}

# Adds a problem unless context.sh freeze --dry-run still gives the plan's
# fingerprint: the docs and pending entries the human approved. A refusal of
# the cut (NO-SPEC, a refused docs file name or size) is a problem; an effort
# not open is left to require_open_effort.
check_context() {
	run_freeze --dry-run
	case ${freeze_status} in
		0) ;;
		"${FREEZE_REFUSED_EXIT}")
			add_freeze_problems "${CONTEXT_PROCEDURE}'s context.sh freeze --dry-run refuses the cut"
			return 0
			;;
		"${NOT_OPEN_EXIT}") return 0 ;;
		*) die 5 "context.sh freeze --dry-run failed (exit ${freeze_status}; its stderr is above); expected exit 0 or ${FREEZE_REFUSED_EXIT}; fix what it names, or reinstall ${CONTEXT_PROCEDURE}" ;;
	esac
	current_fingerprint=$(freeze_value FINGERPRINT)
	[ "${current_fingerprint}" = "${plan_fingerprint}" ] ||
		add_context_problem "the docs or pending entries changed since the plan was shown (fingerprint $(printf '%.12s' "${plan_fingerprint}") shown, $(printf '%.12s' "${current_fingerprint}") now); expected them as shown; show the plan again with a fresh fingerprint" "${CONTEXT_CHANGED_TOKEN} "
}

# Runs context.sh freeze on effort_dir with the options given; sets
# freeze_status, freeze_out (its stdout) and freeze_errors (its stderr). On an
# exit other than the refusal, its stderr is passed through.
run_freeze() {
	[ -n "${freeze_err_file}" ] || freeze_err_file=$(mktemp "${TMPDIR:-/tmp}/${PROG}.XXXXXX") ||
		die 5 "mktemp could not create a temp file in \${TMPDIR:-/tmp}; expected a writable temp folder; check it, then rerun"
	freeze_status=0
	freeze_out=$(sh "${context_script}" freeze --effort "${effort_dir}" "$@" </dev/null 2>"${freeze_err_file}") ||
		freeze_status=$?
	freeze_errors=$(cat "${freeze_err_file}") ||
		die 5 "cat could not read context.sh's stderr from ${freeze_err_file}; expected a readable temp file; check \${TMPDIR:-/tmp}, then rerun"
	[ "${freeze_status}" -eq "${FREEZE_REFUSED_EXIT}" ] || [ -z "${freeze_errors}" ] ||
		printf '%s\n' "${freeze_errors}" >&2
}

# Prints the value of context.sh freeze's "$1: <value>" line, or exits 5 when
# it printed none.
freeze_value() {
	while IFS= read -r freeze_line; do
		case ${freeze_line} in
			"$1: "?*)
				printf '%s' "${freeze_line#"$1: "}"
				return 0
				;;
			*) ;;
		esac
	done <<EOF
${freeze_out}
EOF
	die 5 "context.sh freeze printed no $1 line; expected one on exit 0; reinstall ${CONTEXT_PROCEDURE}"
}

# Adds one problem per line of freeze_errors, led by the freeze token in it
# (CONTEXT-CHANGED when it holds none) and ending in $1: why the cut is refused.
add_freeze_problems() {
	while IFS= read -r freeze_line; do
		[ -n "${freeze_line}" ] || continue
		split_freeze_token "${freeze_line}"
		add_context_problem "${freeze_rest}; $1" "${freeze_token} "
	done <<EOF
${freeze_errors}
EOF
}

# Sets freeze_token to the first freeze token in line $1 and freeze_rest to
# the text after it and its colon; with no token, CONTEXT-CHANGED and the
# whole line.
split_freeze_token() {
	for freeze_token in "${NO_SPEC_TOKEN}" "${CONTEXT_CHANGED_TOKEN}" "${DOCS_NAME_TOKEN}" "${DOCS_SIZE_TOKEN}"; do
		case $1 in
			*"${freeze_token}"*)
				freeze_rest=${1#*"${freeze_token}"}
				freeze_rest=${freeze_rest#:}
				freeze_rest=${freeze_rest# }
				return 0
				;;
			*) ;;
		esac
	done
	freeze_token=${CONTEXT_CHANGED_TOKEN} freeze_rest=$1
}

# Adds problem $1 of the plan's context, led by token $2 and its space when
# given.
add_context_problem() {
	add_problem "${plan_option}" "${plan_value}" "${2-}the plan's context: $1"
}

# Sets plugin_paths and labels_line for the plan's loaded plugins,
# resolved by plugin-files.sh for the agent's role, and title_line; adds a problem when they
# can't be resolved. An agent with no role is left to the validator.
resolve_plugins() {
	plugin_paths='' labels_line='' title_line=''
	case ${agent} in
		code-developer) role=developer ;;
		code-reviewer) role=reviewer ;;
		*) return 0 ;;
	esac
	set --
	while IFS= read -r loaded_name; do
		[ -n "${loaded_name}" ] || continue
		set -- "$@" "${loaded_name}"
	done <<EOF
${loaded_names}
EOF
	# shellcheck disable=SC2310 # its status is awk's; it is acted on below
	if ! selected=$(select_plugin_lines paths "${PROG}" "${listing}" "$@"); then
		add_problem "${plan_option}" "${plan_value}" "the plan's plugins can't be resolved (the lines above name why); expected installed plugins"
		return 0
	fi
	# shellcheck disable=SC2310 # its status is the template check; it is acted on below
	if ! resolve_role_paths "${role}" "${selected}"; then
		add_problem "${plan_option}" "${plan_value}" "the plan's plugins: ${plugin_problem}"
		return 0
	fi
	# shellcheck disable=SC2310 # its status is awk's; a failure exits
	labels_line=$(select_plugin_lines labels "${PROG}" "${listing}" "$@") ||
		die 5 'awk failed building the LABELS line; expected a POSIX awk; check the awk on PATH'
	title_line=$(jq -r -L "${view_lib_dir}" --argjson installed "${installed}" --arg role "${role}" "${TITLE_JQ}" "${plan_body_file}") ||
		die 5 'jq failed building the TITLE line; expected jq 1.6+ and human-view'\''s title.jq; try jq --version, then rerun'
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

# Adds a problem unless the seat --seat names is one of the effort's seats,
# open, working or idle, with the plan's mode and a worktree folder directly
# in the effort's worktrees/; seats.sh get reads it, and seat_worktree is set
# from it. A value that is no seat name is left to the dispatch check, which
# names it.
check_seat() {
	[ -n "${effort_dir}" ] || return 0
	# shellcheck disable=SC2310 # its status is the test result; a jq failure exits inside
	is_seat_name || return 0
	# shellcheck disable=SC2310 # its status says whether the seat was read; the problem is added inside
	read_seat || return 0
	case ${seat_state} in
		open | working | idle) ;;
		*)
			add_problem --seat "${seat}" "the seat is ${seat_state}; expected an open, working or idle seat (a chosen seat is opened by seat-open.sh first)"
			return 0
			;;
	esac
	check_seat_worktree
	[ "${plan_ok}" = true ] || return 0
	[ "${seat_mode}" != "${mode}" ] || return 0
	seat_mode_text="mode ${seat_mode}"
	[ -n "${seat_mode}" ] || seat_mode_text='no mode'
	add_problem --seat "${seat}" "the seat has ${seat_mode_text}, the plan mode ${mode}; expected a seat of the plan's mode"
}

# Sets seat_out (the seat's JSON line), seat_state, seat_mode and
# seat_worktree from seats.sh get, or adds the problem and fails.
read_seat() {
	# On exit 0 seats.sh prints only the seat; otherwise only its stderr lines.
	if seat_out=$(sh "${seats_script}" get --effort "${effort_dir}" --seat "${seat}" </dev/null 2>&1); then
		seat_status=0
	else
		seat_status=$?
	fi
	seats_line=$(printable "${seat_out%%"${NL}"*}")
	case ${seat_status} in
		0) ;;
		6)
			add_problem --seat "${seat}" "no such seat in the effort; expected a seat procedure-git-worktree's seats.sh choose or add made"
			return 1
			;;
		3)
			add_problem --seat "${seat}" "the effort's seats can't be read (${seats_line}); expected the effort's seat list"
			return 1
			;;
		*) die 5 "seats.sh get failed (exit ${seat_status}): ${seats_line}; fix what it names, or reinstall ${WORKTREE_SKILL}" ;;
	esac
	seat_fields=$(printf '%s\n' "${seat_out}" | jq -r '.status // "", .mode // "", .worktree // "" | gsub("\n"; "?")') ||
		die 5 'jq failed reading the seat seats.sh get printed; expected jq 1.6+; try jq --version, then rerun'
	# A seat with no mode or worktree ends early: command substitution drops
	# the empty last lines, so a read past them finds the end.
	{
		IFS= read -r seat_state || :
		IFS= read -r seat_mode || :
		IFS= read -r seat_worktree || :
	} <<EOF
${seat_fields}
EOF
}

# Adds a problem unless seat_worktree is a real folder directly in the
# effort's worktrees/, which the agent's message names as its worktree. Both
# sides compare symlinks resolved: seats.sh choose resolves the worktree's
# path, and --effort may run through a linked parent (/tmp on macOS).
check_seat_worktree() {
	worktrees_dir="${effort_dir}/worktrees"
	shown_worktree=$(printable "${seat_worktree}")
	if [ -z "${seat_worktree}" ]; then
		add_problem --seat "${seat}" "the seat has no worktree; expected a developer or tester seat, which works in a worktree"
		return 0
	fi
	real_worktrees_dir=$(cd -P -- "${worktrees_dir}" 2>/dev/null && pwd -P) || real_worktrees_dir=''
	real_parent=$(cd -P -- "${seat_worktree%/*}/" 2>/dev/null && pwd -P) || real_parent=''
	case ${seat_worktree##*/} in
		'' | . | ..) ;;
		*)
			if [ -n "${real_worktrees_dir}" ] && [ "${real_parent}" = "${real_worktrees_dir}" ]; then
				[ ! -L "${worktrees_dir}" ] && [ ! -L "${seat_worktree}" ] && [ -d "${seat_worktree}" ] ||
					add_problem --seat "${seat}" "the seat's worktree ${shown_worktree} is missing, not a folder or a symbolic link; expected the folder seat-open.sh made"
				return 0
			fi
			;;
	esac
	add_problem --seat "${seat}" "the seat's worktree ${shown_worktree} is not directly in ${worktrees_dir}/; expected ${worktrees_dir}/<letter>, as seats.sh choose sets it"
}

# Succeeds when seat fits the shared names' seat_pattern; jq -e exits 1 when
# it does not.
is_seat_name() {
	seat_name_status=0
	jq -ne --arg s "${seat}" -L "${dispatch_dir}" "include \"${NAMES_MODULE}\"; \$s | test(seat_pattern)" \
		</dev/null >/dev/null || seat_name_status=$?
	case ${seat_name_status} in
		0) return 0 ;;
		1) return 1 ;;
		*) die 5 "jq failed testing --seat against seat_pattern in ${names_module} (exit ${seat_name_status}); expected jq 1.6+ and the ${PROCEDURE} skill's shared names; try jq --version, or reinstall the skill" ;;
	esac
}

# Runs DISPATCH_JQ in mode $1 with id $2, over the entry points after it.
run_dispatch_jq() {
	run_mode=$1 run_id=$2
	shift 2
	jq -n -L "${prune_lib_dir}" --arg prog "${PROG}" --arg mode_of_run "${run_mode}" --arg id "${run_id}" \
		--arg agent "${agent}" --arg seat "${seat}" \
		--arg plugin_paths "${plugin_paths}" --arg skills_dir "${skills_dir}" \
		--arg plan_sha256 "${plan_sha256}" --argjson plan_seq "${plan_seq:-${PLACEHOLDER_SEQ}}" \
		--arg context_path "${context_path}" --argjson context_seq "${context_seq}" \
		--arg task "${task}" --arg task_number "${task_number}" \
		--arg validator_problem_lines "${validator_problems}" \
		--arg plan_known "${plan_ok}" --arg task_known "${task_known}" \
		-r "${DISPATCH_JQ}" --args -- "$@" </dev/null
}

# Adds the problems the dispatch validator finds in the dispatch built with
# the stand-ins, named by option.
check_planned_dispatch() {
	# shellcheck disable=SC2310 # its status is jq's; a failure exits
	planned_dispatch=$(run_dispatch_jq dispatch "${PLACEHOLDER_ID}" "$@") ||
		die 5 "jq failed building the dispatch; expected jq 1.6+ (--args, \$ARGS); try jq --version, then rerun"
	validator_problems=$(printf '%s\n' "${planned_dispatch}" | jq -cs --arg format json -f "${dispatch_validator}") ||
		die 5 'jq failed on the dispatch validator; expected jq 1.6+; try jq --version, then rerun'
	# shellcheck disable=SC2310 # its status is jq's; a failure exits
	named_problems=$(run_dispatch_jq report '' "$@") ||
		die 5 "jq failed naming the dispatch problems; expected jq 1.6+; try jq --version, then rerun"
	[ -z "${named_problems}" ] || problems="${problems}${named_problems}${NL}"
}

# Exits NOT_OPEN_EXIT unless effort_dir is open, as effort.sh state, the one
# owner of the state rule, reads it; a state it cannot read refuses too.
require_open_effort() {
	if effort_state_out=$(sh "${effort_script}" state --effort "${effort_dir}" </dev/null); then
		effort_state_status=0
	else
		effort_state_status=$?
	fi
	effort_name=${effort_dir##*/}
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

# Cuts the plan's version with context.sh freeze --expect, or takes the one
# already cut for that fingerprint, and sets context_path, context_sha256 and
# context_seq to its context.cut event once it passes the shared checks; a
# refusal exits 3, nothing written, and any other failure exits as
# context.sh's exit says.
cut_context() {
	run_freeze --expect "${plan_fingerprint}"
	case ${freeze_status} in
		0) ;;
		"${FREEZE_REFUSED_EXIT}")
			add_freeze_problems "${CONTEXT_PROCEDURE}'s context.sh freeze --expect refused the cut; nothing was written"
			printf '%s' "${problems}" >&2
			exit 3
			;;
		"${NOT_OPEN_EXIT}") die "${NOT_OPEN_EXIT}" "context.sh freeze --expect refused: the effort is not open (its stderr is above); nothing was written; expected an open effort; ask the human to check the effort" ;;
		5) die 5 "context.sh freeze --expect names a missing dependency above; nothing was written; expected the ${CONTEXT_PROCEDURE} skill working; install what it names, then rerun" ;;
		*) die 1 "context.sh freeze --expect failed (exit ${freeze_status}; its stderr is above); no dispatch was written; expected exit 0 with the version cut; fix what it names, then rerun" ;;
	esac
	context_path=$(freeze_value CONTEXT_FILE)
	context_sha256=$(freeze_value CONTEXT_SHA256)
	check_cut_version
	[ -z "${problems}" ] || {
		printf '%s' "${problems}" >&2
		exit 3
	}
}

# Adds a CONTEXT-CHANGED problem unless the cut version is a context.cut
# event of effort_dir that passes the shared path and read checks and hashes
# to the CONTEXT_SHA256 context.sh printed; sets context_seq to its seq.
check_cut_version() {
	context_version_location_problem "${context_path}"
	if [ -n "${context_version_location}" ] || [ "${context_location_effort}" != "${effort_dir}" ]; then
		add_cut_problem "not a context.cut event in ${effort_dir}/events/"
		return 0
	fi
	path_problem=$(context_path_problem "${context_path}")
	if [ -n "${path_problem}" ]; then
		add_cut_problem "${path_problem}"
		return 0
	fi
	# shellcheck disable=SC2310 # its status is a tool's; a failure has printed its cause
	context_read_problem "${context_path}" ||
		die 5 'a tool failed on the context read checks (its stderr is above); expected jq 1.6+ and wc; try jq --version, then rerun'
	case ${context_read_fault} in
		'') ;;
		no-spec)
			add_cut_problem "${context_read_text#"${NO_SPEC_TOKEN}: "}" "${NO_SPEC_TOKEN}"
			return 0
			;;
		*)
			add_cut_problem "${context_read_text#"${CONTEXT_CHANGED_TOKEN}: "}"
			return 0
			;;
	esac
	# shellcheck disable=SC2310 # its status is the tool's; a failure exits
	compute_context_digest "${context_path}" ||
		die 5 "${context_digest_tool} could not hash ${context_path}; check the tool, then rerun"
	if [ "${context_digest}" != "${context_sha256}" ]; then
		add_cut_problem "sha256 $(printf '%.12s' "${context_digest}"), not the $(printf '%.12s' "${context_sha256}") context.sh printed"
		return 0
	fi
	read_context_seq "${context_path}"
	[ -n "${context_seq}" ] || add_cut_problem "its seq is not the one its file name holds"
}

# Sets context_seq to the seq of context.cut event $1 when it is the seq its
# file name holds, or to empty.
read_context_seq() {
	context_seq=$(jq -r '.seq | numbers' "$1" </dev/null) ||
		die 5 "jq could not read $1; expected jq 1.6+; try jq --version, then rerun"
	context_name_seq=${1##*/}
	context_name_seq=${context_name_seq%%-*}
	while [ "${context_name_seq#0}" != "${context_name_seq}" ]; do context_name_seq=${context_name_seq#0}; done
	# shellcheck disable=SC2310 # a pure test; a failure empties the seq
	is_seq "${context_seq}" && [ "${context_seq}" = "${context_name_seq}" ] || context_seq=''
}

# Adds problem $1 of the cut version, led by token $2 (CONTEXT-CHANGED when
# not given): the version stays, and a re-plan takes a fresh fingerprint.
add_cut_problem() {
	add_context_problem "the cut version ${context_path}: $1; expected a version passing ${CONTEXT_PROCEDURE}'s checks; show the plan again with a fresh fingerprint" "${2:-${CONTEXT_CHANGED_TOKEN}} "
}

# Sets dispatch_id to a fresh ID crucible.sh id hands out for the effort.
read_fresh_id() {
	dispatch_id=$(sh "${crucible_script}" id --effort "${effort_dir}" </dev/null) ||
		die 1 "crucible.sh id --effort failed; expected it to print a fresh ID for ${effort_dir}; try the crucible.sh error above, then rerun"
	# shellcheck disable=SC2310 # a pure test; a failure fails the run
	crucible_is_id "${dispatch_id}" ||
		die 1 "crucible.sh id printed no Crucible ID; expected one <YYYYMMDDTHHMMSS>-<4 lowercase hex>; try sh ${crucible_script} --help to check its install, reinstall the crucible skill if that fails, then rerun"
}

# Builds and checks the dispatch, then appends it; sets dispatch_path.
write_dispatch() {
	read_fresh_id
	# shellcheck disable=SC2310 # its status is jq's; a failure fails the run
	dispatch_json=$(run_dispatch_jq dispatch "${dispatch_id}" "$@") ||
		die 1 "jq failed building the dispatch; expected jq 1.6+ (--args, \$ARGS); try jq --version, then rerun"
	append_dispatch
}

# Writes dispatch_json to a temp file, checks those bytes with the dispatch
# validator, and appends them as the effort's dispatch.made event; sets
# dispatch_path to the event.
append_dispatch() {
	temp_file=$(mktemp "${TMPDIR:-/tmp}/${PROG}.XXXXXX") ||
		die 1 "mktemp could not create a temp file in \${TMPDIR:-/tmp}; expected a writable temp folder; check it, then rerun"
	printf '%s\n' "${dispatch_json}" >"${temp_file}" ||
		die 1 "could not write the temp file ${temp_file}; expected a writable temp folder; check its free space, then rerun"
	final_problems=$(jq -rs -f "${dispatch_validator}" "${temp_file}" </dev/null) ||
		die 1 'jq failed on the dispatch validator; expected jq 1.6+; try jq --version, then rerun'
	[ -z "${final_problems}" ] || die 1 "the dispatch would fail its validator: ${final_problems}"
	dispatch_path=$(sh "${events_script}" append --effort "${effort_dir}" --type "${DISPATCH_EVENT}" --by "${PROG}" \
		--body-file "${temp_file}" --session "${session_id}" </dev/null) ||
		die 1 "events.sh append ${DISPATCH_EVENT} failed (its stderr is above); no dispatch was written; fix what it names, then rerun"
}

# The re-seat (--reseat): adds a problem unless the seat is open, its last
# agent handed out, its last seat.bound names a dispatch.made of the effort
# that still fits the validator, its pinned context passes the shared read
# checks (stale aside: a re-seat keeps its version) and its plan resolves to
# the installed plugins; then sets dispatch_json to the re-seat dispatch.
check_reseat() {
	[ -n "${effort_dir}" ] || return 0
	# shellcheck disable=SC2310 # its status is the test result; a jq failure exits inside
	if ! is_seat_name; then
		add_problem --seat "${seat}" 'is not a seat name; expected lowercase words joined by dashes, then alpha ... omega and from the second round -2, -3 ..., like build-agent-alpha'
		return 0
	fi
	# shellcheck disable=SC2310 # its status says whether the seat was read; the problem is added inside
	read_seat || return 0
	if [ "${seat_state}" != open ]; then
		add_problem --seat "${seat}" "the seat is ${seat_state}; expected an open seat, freed by seats.sh handover"
		return 0
	fi
	check_seat_worktree
	[ -z "${problems}" ] || return 0
	# shellcheck disable=SC2310 # its status says whether the last dispatch was found; the problem is added inside
	find_last_dispatch || return 0
	check_pinned_context
	check_reseat_plan
	[ -z "${problems}" ] || return 0
	read_worktree_head
}

# Sets last_event, last_seq and last_body_file from the dispatch.made of the
# seat's last seat.bound, which must be the agent seats.sh handover moved to
# the end of previous_agent_ids; else adds a problem and fails.
find_last_dispatch() {
	last_agent=$(printf '%s\n' "${seat_out}" | jq -r '.previous_agent_ids // [] | last // ""') ||
		die 5 'jq failed reading the seat seats.sh get printed; expected jq 1.6+; try jq --version, then rerun'
	if [ -z "${last_agent}" ]; then
		add_problem --seat "${seat}" 'the seat has no agent handed out; expected a seat freed by seats.sh handover'
		return 1
	fi
	last_bound=$(sh "${events_script}" latest --effort "${effort_dir}" --type seat.bound --where ".body.seat == \"${seat}\"" </dev/null) ||
		die 5 'events.sh latest failed on --effort; its stderr is above; fix what it names, then rerun'
	bound_fields=''
	[ -z "${last_bound}" ] || bound_fields=$(jq -r '(.body.agent_id // "" | strings), (.body.dispatch // "" | strings)' "${last_bound}" </dev/null) ||
		die 5 "jq could not read ${last_bound}; expected jq 1.6+; try jq --version, then rerun"
	bound_agent=${bound_fields%%"${NL}"*}
	bound_dispatch=${bound_fields#*"${NL}"}
	bound_ok=false
	# shellcheck disable=SC2310 # a pure test; its status is the answer
	if [ -n "${last_bound}" ] && [ "${bound_agent}" = "${last_agent}" ] && crucible_is_id "${bound_dispatch}"; then
		bound_ok=true
	fi
	if [ "${bound_ok}" = false ]; then
		shown_agent=$(printable "${last_agent}")
		add_problem --seat "${seat}" "the seat's last seat.bound event is not the bind of its handed-out agent ${shown_agent} with a dispatch ID; expected the bind seat-bind-hook.sh wrote"
		return 1
	fi
	last_event=$(sh "${events_script}" latest --effort "${effort_dir}" --type "${DISPATCH_EVENT}" \
		--where ".body.id == \"${bound_dispatch}\" and .body.seat == \"${seat}\"" </dev/null) ||
		die 5 'events.sh latest failed on --effort; its stderr is above; fix what it names, then rerun'
	if [ -z "${last_event}" ]; then
		add_problem --seat "${seat}" "no ${DISPATCH_EVENT} event holds the seat's last dispatch ${bound_dispatch}; expected the dispatch its agent was bound with"
		return 1
	fi
	last_body_file=$(mktemp "${TMPDIR:-/tmp}/${PROG}.XXXXXX") ||
		die 5 "mktemp could not create a temp file in \${TMPDIR:-/tmp}; expected a writable temp folder; check it, then rerun"
	jq '.body' "${last_event}" </dev/null >"${last_body_file}" ||
		die 5 "jq could not read ${last_event}; expected jq 1.6+; try jq --version, then rerun"
	last_problems=$(jq -rs -f "${dispatch_validator}" "${last_body_file}" </dev/null) ||
		die 5 'jq failed on the dispatch validator; expected jq 1.6+; try jq --version, then rerun'
	if [ -n "${last_problems}" ]; then
		joined_problems=$(join_lines "${last_problems}")
		add_problem --seat "${seat}" "the seat's last dispatch ${last_event##*/} no longer fits the dispatch shape (${joined_problems}); expected a dispatch the plan's gate can make again"
		return 1
	fi
	last_seq=$(jq -r '.seq' "${last_event}" </dev/null) ||
		die 5 "jq could not read ${last_event}; expected jq 1.6+; try jq --version, then rerun"
}

# Adds a problem unless the last dispatch's context.cut event passes the
# shared read checks, a newer version aside, and holds the seq it names.
check_pinned_context() {
	context_fields=$(jq -r '.context.path, .context.seq' "${last_body_file}" </dev/null) ||
		die 5 "jq could not read ${last_body_file}; expected jq 1.6+; try jq --version, then rerun"
	context_path=${context_fields%%"${NL}"*}
	pinned_seq=${context_fields#*"${NL}"}
	plan_option=--seat plan_value=${seat}
	path_problem=$(context_path_problem "${context_path}")
	if [ -n "${path_problem}" ]; then
		add_context_problem "the pinned version ${context_path}: ${path_problem}; expected ${context_path_expected}"
		return 0
	fi
	# shellcheck disable=SC2310 # its status is a tool's; a failure has printed its cause
	context_read_problem "${context_path}" ||
		die 5 'a tool failed on the context read checks (its stderr is above); expected jq 1.6+ and wc; try jq --version, then rerun'
	case ${context_read_fault} in
		'' | stale) ;;
		*)
			add_context_problem "the pinned version ${context_path}: ${context_read_text}" "${CONTEXT_CHANGED_TOKEN} "
			return 0
			;;
	esac
	read_context_seq "${context_path}"
	[ "${context_seq}" = "${pinned_seq}" ] ||
		add_context_problem "the pinned version ${context_path}: its seq is not the ${pinned_seq} the dispatch names; expected the context.cut event of that seq" "${CONTEXT_CHANGED_TOKEN} "
}

# Reads the last dispatch's plan.made event and resolves its plugins for the
# LABELS and TITLE lines, adding a problem for a plan that no longer fits.
check_reseat_plan() {
	plan_seq=$(jq -r '.plan.seq' "${last_body_file}" </dev/null) ||
		die 5 "jq could not read ${last_body_file}; expected jq 1.6+; try jq --version, then rerun"
	plan_option=--seat plan_value=${seat}
	plan_event=$(sh "${events_script}" latest --effort "${effort_dir}" --type "${PLAN_EVENT}" --where ".seq == ${plan_seq}" </dev/null) ||
		die 5 'events.sh latest failed on --effort; its stderr is above; fix what it names, then rerun'
	if [ -z "${plan_event}" ]; then
		add_problem --seat "${seat}" "no ${PLAN_EVENT} event has the seq ${plan_seq} the seat's last dispatch names; expected the plan it was approved with"
		return 0
	fi
	plan_body_file=$(mktemp "${TMPDIR:-/tmp}/${PROG}.XXXXXX") ||
		die 5 "mktemp could not create a temp file in \${TMPDIR:-/tmp}; expected a writable temp folder; check it, then rerun"
	jq '.body' "${plan_event}" </dev/null >"${plan_body_file}" ||
		die 5 "jq could not read ${plan_event}; expected jq 1.6+; try jq --version, then rerun"
	read_installed
	check_plan
	[ "${plan_ok}" = true ] || return 0
	resolve_plugins
}

# Sets worktree_head to the seat's worktree HEAD commit, or adds a problem.
read_worktree_head() {
	command -v git >/dev/null 2>&1 || die 5 'git missing; expected git on PATH for --reseat; install git'
	worktree_head=$(git -C "${seat_worktree}" rev-parse --verify --quiet 'HEAD^{commit}' </dev/null 2>/dev/null) || worktree_head=''
	case ${worktree_head} in
		*[!0-9a-f]* | '') ;;
		*) [ "${#worktree_head}" -ne 40 ] || return 0 ;;
	esac
	shown_worktree=$(printable "${seat_worktree}")
	add_problem --seat "${seat}" "the seat's worktree ${shown_worktree} has no HEAD commit git rev-parse reads; expected the worktree seat-open.sh made"
}

# Builds the re-seat dispatch from the last one and appends it; sets dispatch_path.
write_reseat() {
	read_fresh_id
	dispatch_json=$(jq -c -L "${prune_lib_dir}" --arg id "${dispatch_id}" --argjson last_seq "${last_seq}" \
		--arg head "${worktree_head}" --argjson notes "${notes_json}" "${RESEAT_JQ}" "${last_body_file}" </dev/null) ||
		die 1 'jq failed building the re-seat dispatch; expected jq 1.6+; try jq --version, then rerun'
	append_dispatch
}

# Prints the lines of $1 joined by "; ".
join_lines() {
	joined=''
	while IFS= read -r joined_line; do
		joined="${joined}${joined:+; }${joined_line}"
	done <<EOF
$1
EOF
	printf '%s' "${joined}"
}

temp_file='' freeze_err_file='' plan_body_file='' last_body_file=''
trap clean_up EXIT
# A signal exits through the EXIT trap, so the temp files go on every path.
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

[ "$#" -gt 0 ] || {
	usage >&2
	exit 2
}
given_effort='' plan_sha256='' task_number='' seat='' skills_dir='' given_skills_dir='' seen_options='' awaited_option=''
reseat=false notes_json='[]'
# Each --entry-point is appended to the positional parameters; "for" walks
# the original arguments only, which are shifted away after the loop.
argument_count=$#
for argument do
	if [ -z "${awaited_option}" ]; then
		take_option "${argument}"
		continue
	fi
	case ${awaited_option} in
		--entry-point) set -- "$@" "${argument}" ;;
		--note) take_note "${argument}" ;;
		*) take_value "${awaited_option}" "${argument}" ;;
	esac
	awaited_option=''
done
finish_parse
shift "${argument_count}"

for tool in ${REQUIRED_TOOLS}; do
	command -v "${tool}" >/dev/null 2>&1 ||
		die 5 "${tool} missing; expected it on PATH; install your base system's ${tool}"
done

problems='' validator_problems='' plan_sha256_ok=true task_number_ok=true plan_ok=false session_id=''
plan_option=--plan-sha256 plan_value=${plan_sha256} plan_seq=''
load_dependencies
require_session
resolve_space_root
check_skills_dir
# Stand-ins for what the plan gives, so the dispatch check still reports the
# options' own problems when the plan is not found or not valid.
agent=code-developer mode=BUILD plugin_paths='' labels_line='' title_line=''
plan_fingerprint=''
context_path=${PLACEHOLDER_CONTEXT} context_sha256='' context_seq=${PLACEHOLDER_SEQ}
task=${TASK_STAND_IN} task_known=false
check_effort_option
if [ "${reseat}" = true ]; then
	check_reseat
	if [ -n "${problems}" ]; then
		printf '%s' "${problems}" >&2
		exit 3
	fi
	require_open_effort
	write_reseat
	printf 'DISPATCH: %s\n%s\n%s\n' "${dispatch_path}" "${labels_line}" "${title_line}"
	exit 0
fi
check_plan_sha256
check_task_number
[ "${plan_sha256_ok}" = false ] || find_plan_record
if [ -n "${plan_body_file}" ]; then
	read_installed
	check_plan
fi
if [ "${plan_ok}" = true ]; then
	pick_task
	check_context
	resolve_plugins
fi
check_seat
check_planned_dispatch "$@"
if [ -n "${problems}" ]; then
	printf '%s' "${problems}" >&2
	exit 3
fi
require_open_effort
cut_context
write_dispatch "$@"
printf 'DISPATCH: %s\n%s\n%s\n' "${dispatch_path}" "${labels_line}" "${title_line}"
