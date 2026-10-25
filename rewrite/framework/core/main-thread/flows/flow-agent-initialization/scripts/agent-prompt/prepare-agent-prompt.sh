#!/usr/bin/env sh
# PreToolUse hook on Agent. A dispatch of a listed agent must carry, as its
# whole prompt, the one line "DISPATCH: <path>" naming a dispatch file that
# generate-agent-dispatch.sh wrote; the hook checks that file, the context file
# and the plugin files it names, and replaces the prompt with the agent's
# message built from them and procedure-context's context-handling template, sent word
# for word. Any problem denies the dispatch. Every other Agent
# call passes untouched. The decision is the only output, so a listed agent is
# denied on any unexpected exit (fail closed).
# Once every check passes, it writes the dispatch's baseline file (the repo's
# git status before any code changes) when it is still empty, and keeps it on
# a resend. Each checked file is read once, into a private temp copy that the
# checks and the message all read, so the checked bytes are the sent bytes.
# Known gap: the path checks (not a symlink or resolving inside its plugin
# folder, regular, readable) run on the path just before the copy, since POSIX
# sh can't test an open file, so a path swapped in between (such as for a
# symlink or a FIFO) is copied unchecked, or blocks until the hook times out.
# Swapping it takes write access to the plugin folder or the Crucible space.
# No crucible-context or crucible-plugin marker is stripped from the message,
# because everything it embeds is trusted: the human's request, the notes and
# whys, as procedure-context sets what notes and whys may hold, and the template
# and plugins the human installed.
# shellcheck source-path=SCRIPTDIR source-path=SCRIPTDIR/../../../../../engine/crucible/scripts/lib source-path=SCRIPTDIR/../../../../procedures/procedure-context/scripts
set -eu

readonly PROG='prepare-agent-prompt.sh'
readonly REASON_PREFIX='flow-agent-initialization:'
# The agents whose dispatches carry a DISPATCH line. The no-jq path needs them
# without jq, so they stay here; the hook faults unless they match the listed
# agents of the shared names module, the list to edit first.
readonly LISTED_AGENTS='code-developer code-reviewer'
readonly NAMES_MODULE='dispatch-names'
readonly RENDER_LIB='human-view'
readonly CRUCIBLE_SKILL='crucible'
readonly VIEW_NAME='view'
readonly PRUNE_NAME='prune'
# The skill that owns the context: its validator, its path checks and the file
# sent under "# Handling your context" (TEMPLATE_FILE, relative to its folder).
readonly CONTEXT_PROCEDURE='procedure-context'
readonly TEMPLATE_FILE='references/agent-context-rules.md'
# Bounds the symlink chain followed for one file, so a link loop ends in a deny.
readonly MAX_LINK_HOPS=40
readonly DISPATCH_HINT='The expected prompt is exactly one line "DISPATCH: <absolute path>", the DISPATCH line generate-agent-dispatch.sh printed for this dispatch (flow-agent-initialization).'
# The cache kind and label of the file a deny's Data · Denial line names.
readonly DENIAL_KIND='cache/denials'
readonly DENIAL_LABEL='denial'
# A deny shows this many problems at most, each cut to this many characters,
# so the reason stays a short view; the details file holds them all.
readonly DENIAL_MAX_SHOWN=8
readonly DENIAL_LINE_CAP=200
# The words that start a problem; the flow's step 10 routes on them.
# CONTEXT-STALE is a context version no longer its effort's latest, every
# other context problem CONTEXT; BASELINE is a baseline file holding no valid
# baseline; BASELINE-WRITE is a baseline the hook could not write.
readonly PROBLEM_KINDS='DISPATCH AGENT CONTEXT CONTEXT-STALE PLUGIN REPORT BASELINE BASELINE-WRITE'
# The deny when jq is missing, printed as is: a fixed text, built without jq.
readonly NO_JQ_DENY='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"flow-agent-initialization: jq is missing from PATH, so this dispatch is denied; the hook needs jq 1.6+."}}'
# The reasons of the deny when stdin can't be read and of the deny when the hook
# stops before deciding. Both denies are built with jq; the fixed texts below
# are printed instead only when jq is missing. A jq that is present but fails
# to build a deny makes the hook print nothing, write the reason to stderr and
# exit 2, which blocks the call, so a listed agent never passes with no output.
# Neither reason holds a character JSON escapes, so each fixed text is the
# reason between the deny's fixed ends.
readonly STDIN_REASON="${REASON_PREFIX} the hook input on stdin could not be read, so this dispatch is denied; the hook expects the PreToolUse hook JSON on stdin; the cause is on the hook's stderr."
readonly INTERNAL_REASON="${REASON_PREFIX} the hook stopped before deciding, so this dispatch is denied; the cause is on the hook's stderr."
readonly DENY_TEXT_HEAD='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"'
readonly DENY_TEXT_TAIL='"}}'
readonly STDIN_DENY="${DENY_TEXT_HEAD}${STDIN_REASON}${DENY_TEXT_TAIL}"
readonly INTERNAL_DENY="${DENY_TEXT_HEAD}${INTERNAL_REASON}${DENY_TEXT_TAIL}"
TAB=$(printf '\t')
readonly TAB
NL='
'
readonly NL
# The C locale keeps awk byte-wise and identical on macOS and Linux.
LC_ALL=C
export LC_ALL

# Prints "<name>\t<disable-model-invocation>\t<metadata.label>\t<metadata.base>"
# from a SKILL.md frontmatter, read the way list-plugins.sh reads it; exits 2
# when there is no closed frontmatter.
# The program is single-quoted on purpose: its $0 is awk's, not the shell's.
# shellcheck disable=SC2016
readonly PLUGIN_FRONTMATTER_AWK='
function clean(value) {
	sub(/^[ \t]+/, "", value)
	if (value !~ /^["\047]/) sub(/[ \t]+#.*$/, "", value)
	sub(/[ \t]+$/, "", value)
	if (value ~ /^".*"$/ || value ~ /^\047.*\047$/) value = substr(value, 2, length(value) - 2)
	sub(/^[ \t]+/, "", value)
	sub(/[ \t]+$/, "", value)
	gsub(/\t/, " ", value)
	return value
}
{ sub(/\r$/, "") }
NR == 1 { if ($0 != "---") exit; next }
$0 == "---" { closed = 1; exit }
/^name:/ { name = clean(substr($0, index($0, ":") + 1)) }
/^disable-model-invocation:/ { model_invocation_disabled = clean(substr($0, index($0, ":") + 1)) }
/^[^ \t#]/ { in_metadata = ($0 ~ /^metadata:[ \t]*(#.*)?$/); next }
in_metadata && /^  label:/ { label = clean(substr($0, index($0, ":") + 1)) }
in_metadata && /^  base:/ { base = clean(substr($0, index($0, ":") + 1)) }
END {
	if (!closed) exit 2
	printf "%s\t%s\t%s\t%s\n", name, model_invocation_disabled, label, base
}
'

# Succeeds when the input text holds a "subagent_type" key whose string value
# is a listed agent (passed as agents) or holds an escape, so its name can't be
# read without decoding. Both the key and the names match in every JSON
# spelling: each character literal or as a \u00HH escape, either hex case.
# The program is single-quoted on purpose: its $0 is awk's, not the shell's.
# shellcheck disable=SC2016
readonly LISTED_AGENT_TEXT_AWK='
function json_spelling(text,  out, i, c, hex, hex_pattern, j, h) {
	out = ""
	for (i = 1; i <= length(text); i++) {
		c = substr(text, i, 1)
		hex = sprintf("%02x", code[c])
		hex_pattern = ""
		for (j = 1; j <= 2; j++) {
			h = substr(hex, j, 1)
			hex_pattern = hex_pattern (h ~ /[a-f]/ ? "[" h toupper(h) "]" : h)
		}
		out = out "([" c "]|\\\\u00" hex_pattern ")"
	}
	return out
}
BEGIN {
	for (i = 32; i < 127; i++) code[sprintf("%c", i)] = i
	count = split(agents, names, " ")
	listed = ""
	for (i = 1; i <= count; i++) listed = listed (listed == "" ? "" : "|") json_spelling(names[i])
	space = "[ \t\r\n]*"
	pattern = "\"" json_spelling("subagent_type") "\"" space ":" space "\"((" listed ")\"|[^\"\\\\]*\\\\)"
}
{ text = text $0 "\n" }
END { exit !(text ~ pattern) }
'

# Prints one "PLUGIN <problem>: <file>" line per expansion token found in a
# file, and per SKILL.md without a closed frontmatter. It reads
# the temp copies; the environment's PREPARE_PROMPT_SCAN_PATHS holds each
# copy's checked path, one per line in operand order, and every line names that
# path. A "---" line may end in a CR, as in the frontmatter read and the message.
# The program is single-quoted on purpose: its $ signs are awk's or literal text.
# shellcheck disable=SC2016
readonly SCAN_AWK='
function is_fence(line) { sub(/\r$/, "", line); return line == "---" }
function add(problem, file) { printf "PLUGIN %s: %s\n", problem, file }
function finish_file() {
	if (current == "") return
	if (is_skill && !closed) add("SKILL.md has no frontmatter closed by a --- line; expected a frontmatter opened and closed by --- lines", current)
}
BEGIN {
	split(ENVIRON["PREPARE_PROMPT_SCAN_PATHS"], checked_paths, "\n")
	for (i = 1; i < ARGC; i++) checked_path[ARGV[i]] = checked_paths[i]
}
FNR == 1 {
	finish_file()
	current = checked_path[FILENAME]
	is_skill = (current ~ /\/SKILL\.md$/)
	closed = 0
	opened = is_fence($0)
	fixed_count = split("$ARGUMENTS ${CLAUDE_SKILL_DIR} ${CLAUDE_PROJECT_DIR} ${CLAUDE_SESSION_ID} ${CLAUDE_EFFORT} !` ```!", fixed, " ")
	for (i = 1; i <= fixed_count; i++) seen[fixed[i]] = 0
	seen_digit = 0
}
is_skill && FNR > 1 && opened && !closed && is_fence($0) { closed = 1 }
{
	for (i = 1; i <= fixed_count; i++)
		if (!seen[fixed[i]] && index($0, fixed[i])) { seen[fixed[i]] = 1; add("file holds the expansion token " fixed[i] "; expected no expansion token", current) }
	if (!seen_digit && match($0, /\$[0-9]/)) { seen_digit = 1; add("file holds the expansion token " substr($0, RSTART, RLENGTH) "; expected no expansion token", current) }
}
END { finish_file() }
'

# Renders the deny reason from $problems (one per line, KIND first), the KIND
# words $kinds, the reason prefix $prefix, the details file $details ("" for
# none) and the bounds $max_shown and $line_cap, with human-view's view module.
# The first problem of each KIND is always shown (there are fewer KINDs than
# $max_shown), so the reason names every KIND found; the others follow in
# order up to $max_shown, and the rest become "+N more". Claude Code caps a
# hook's text added to the context at 10,000 characters; the bounds keep the
# reason far under it.
# The program is single-quoted on purpose: its $ signs are jq's.
# shellcheck disable=SC2016
readonly DENIAL_JQ='
def cut: if length > $line_cap then .[:$line_cap - 1] + "…" else . end;
($kinds | split(" ")) as $kind_list
| ($problems | split("\n") | map(select(length > 0))) as $all
| ($all | length) as $count
| (reduce range(0; $count) as $i ({seen: {}, firsts: []};
	($all[$i] | split(" ")[0]) as $word
	| if ($kind_list | any(. == $word)) and (.seen[$word] | not)
	  then .seen[$word] = true | .firsts += [$i] else . end)
	| .firsts) as $firsts
| ($firsts + [range(0; $count) | select(. as $i | $firsts | any(. == $i) | not)])[:$max_shown] | sort as $shown
| ($count - ($shown | length)) as $more
| [$prefix + " " + status_line("blocked"; "Blocked · the dispatch was denied: \($count) problem" + (if $count == 1 then "" else "s" end)),
	section("Problem"; "Problems"; $shown | map($all[.] | gsub("[\u0000-\u001f\u007f]"; "?") | cut)),
	(if $more > 0 then "+\($more) more" else "" end),
	data_section(if $details == "" then [] else [["Denial", $details]] end)]
| blocks'
# Builds the details file: every problem in full, its KIND, the dispatch file
# and the hint; prune leaves out a missing KIND and an empty hint.
# shellcheck disable=SC2016
readonly DENIAL_DETAILS_JQ='
($kinds | split(" ")) as $kind_list
| {dispatch: $dispatch, hint: (if $hint == "" then null else $hint end),
	problems: ($problems | split("\n") | map(select(length > 0)
		| (split(" ")[0]) as $word
		| {kind: (if ($kind_list | any(. == $word)) then $word else null end), problem: .}))}
| prune'

# Builds the agent's message from the dispatch copy ($dispatch), the
# pretty-printed context copy ($context), the template copy ($template) and
# the plugin files, the item list build_message puts between the two halves:
# [plugin name, "skill"|"reference", file text] triples in the dispatch's
# order.
# The programs are single-quoted on purpose: their $ signs are jq's.
# shellcheck disable=SC2016
readonly MESSAGE_JQ_HEAD='
# A "---" line may end in a CR, as in the frontmatter read and the token scan.
def is_fence: rtrimstr("\r") == "---";
def strip_frontmatter:
	split("\n") as $lines
	| ([range(1; $lines | length) | select($lines[.] | is_fence)] | first) as $close
	| if ($lines[0] | is_fence | not) or $close == null then error("SKILL.md has no frontmatter") else . end
	| $lines[$close + 1:] | join("\n")
	| if startswith("\n") then .[1:] elif startswith("\r\n") then .[2:] else . end;
def body: if .[1] == "skill" then .[2] | strip_frontmatter else .[2] end;
def with_newline: if endswith("\n") then . else . + "\n" end;
# Files in a block are separated by one empty line.
def block: "<crucible-plugin name=\"\(.name)\">\n\n" + (.bodies | map(with_newline) | join("\n")) + "\n</crucible-plugin>";
# A backtick would end the code span, so it prints as a quote.
def code: "`" + gsub("`"; [39] | implode) + "`";
def work($dispatch):
	"# Your work\n\n"
	+ "- **MODE:** \($dispatch.mode)\n"
	+ "- **TASK:** \($dispatch.task)\n"
	+ "- **REPO ROOT:** \($dispatch.repo_root | code)\n"
	+ "- **ENTRY POINTS** (where to begin, not a limit): "
	+ (($dispatch.entry_points // []) | if length == 0 then "none" | code else map(code) | join(", ") end) + "\n"
	+ "- **REPORT:** \($dispatch.report | code)\n"
	+ "- **CONTEXT FILE:** \($dispatch.context.path | code)\n"
	+ "- **RETURN:** \("REPORT: " + $dispatch.report | code) alone\n"
	+ "\nA marked gap beats a papered-over one: report what you could not read, run or decide.\n"
	+ "Save your plan and progress as you go, in your scratchpad, so a cut-off run leaves them; the REPORT file is written once, as your report skill sets.\n";
($dispatch | fromjson) as $parsed
|'
# shellcheck disable=SC2016
readonly MESSAGE_JQ_TAIL='
| reduce .[] as $item ([];
	if length > 0 and .[length - 1].name == $item[0]
	then .[length - 1].bodies += [$item | body]
	else . + [{name: $item[0], bodies: [$item | body]}]
	end)
| "# Your plugins\n\n"
	+ (if length == 0 then "none" else map(block) | join("\n\n") end)
	+ "\n\n# Your context\n\n<crucible-context>\n\n```json\n" + ($context | with_newline) + "```\n\n</crucible-context>\n\n"
	+ "# Handling your context\n\n" + ($template | with_newline) + "\n"
	+ work($parsed)
'

main() {
	dispatch_effort=''
	parse_args "$@"
	decided=false
	is_listed_agent=false
	snapshot_dir=''
	temp_file=''
	trap on_exit EXIT
	# A signal exits through the EXIT trap: the temp copies go and a listed agent is denied.
	trap 'exit 129' HUP
	trap 'exit 130' INT
	trap 'exit 143' TERM
	run_hook
}

parse_args() {
	case ${1-} in
		'') return 0 ;;
		--help | -h)
			usage
			exit 0
			;;
		*) usage_error "unknown option: $1; expected no arguments (hook input on stdin) or --help" ;;
	esac
}

usage_error() {
	printf "%s: %s; try '%s --help'\n" "${PROG}" "$1" "${PROG}" >&2
	exit 2
}

run_hook() {
	# shellcheck disable=SC2310 # its status is the probe result; errexit adds nothing
	if ! stdin_is_open || ! hook_input=$(cat); then
		is_listed_agent=true
		deny "${STDIN_REASON}" "${STDIN_DENY}"
	fi
	classify_call
	[ "${is_listed_agent}" = true ] || pass
	# shellcheck disable=SC2310 # the function's status is its final jq's; a failure denies
	prompt_value=$(read_dispatch_line) ||
		fault "jq could not read tool_input; the hook needs jq 1.6+; the cause is on the hook's stderr."
	prompt_status=${prompt_value%%"${NL}"*}
	case ${prompt_status} in
		path) dispatch_path=${prompt_value#*"${NL}"} ;;
		notstring) refuse_now 'DISPATCH the prompt is not a string; expected one "DISPATCH: <absolute path>" line' ;;
		lines) refuse_now 'DISPATCH the prompt is more than one line; expected one "DISPATCH: <absolute path>" line' ;;
		form) refuse_now 'DISPATCH the prompt is not a "DISPATCH: <path>" line; expected one "DISPATCH: <absolute path>" line' ;;
		*) fault "the prompt parser returned an unknown status (${prompt_status}); the fault is in ${PROG}, not in the dispatch." ;;
	esac
	subagent_type=$(printf '%s' "${hook_input}" | jq -r '.tool_input.subagent_type') ||
		fault "jq could not read tool_input.subagent_type; the hook needs jq 1.6+; the cause is on the hook's stderr."
	load_dependencies
	prepare_message "${subagent_type}"
	fill_baseline
	# shellcheck disable=SC2310 # the function's status is its final jq's; a failure denies
	decision=$(printf '%s' "${hook_input}" | jq -c --rawfile message "${message_file}" \
		'{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "allow",
			updatedInput: (.tool_input + {prompt: $message})}}') ||
		fault "jq could not build the allow decision; the hook needs jq 1.6+ (--rawfile); the cause is on the hook's stderr."
	emit "${decision}"
}

usage() {
	cat <<EOF
usage: sh ${PROG} < PreToolUse-JSON
       sh ${PROG} --help | -h

The PreToolUse hook on Agent: replaces a listed agent's "DISPATCH: <path>"
  prompt with its first message once the dispatch passes every check.

Hook: acts only on a listed agent (${LISTED_AGENTS}); any other
call: no output. A closed or unreadable stdin denies every call.
A listed agent's call is allowed only when its prompt is exactly one line
  "DISPATCH: <absolute path>" naming a dispatch file generate-agent-dispatch.sh
  wrote for that agent, and the dispatch, its context file (its effort's latest
  version, matching context.sha256), plugin files (each SKILL.md frontmatter
  valid as list-plugins.sh --help sets, the description aside), report file
  (empty) and baseline file (absent, empty or of its repo_root) pass every
  check (a path swapped after its check by someone who can write to the
  plugin folder or the Crucible space aside: it is copied unchecked, or hangs
  until the hook times out).

stdout (one JSON line):
  allow  hookSpecificOutput.updatedInput: tool_input, prompt replaced by
         the message
  deny   permissionDecisionReason "${REASON_PREFIX} <text>"; no KIND: a hook,
         install or host fault. A failed check: "<prefix> 🔴 **Blocked · the
         dispatch was denied: <N> problem(s)**", "**Problem:** <p>" or
         "**Problems**" and numbered <p> lines (${DENIAL_MAX_SHOWN} at most, every KIND shown,
         cut to ${DENIAL_LINE_CAP} characters), "+<M> more" past ${DENIAL_MAX_SHOWN}, then, effort known,
         "**Data · Denial:** <path>" (absolute, all as JSON). <p>:
         "<KIND> <problem>; expected <x>", most ending ": <path>"; KIND:
         DISPATCH, AGENT, CONTEXT, CONTEXT-STALE (stale context),
         PLUGIN, REPORT, BASELINE, BASELINE-WRITE (not written)
The message, built from the checked bytes: # Your plugins, # Your context,
  # Handling your context, # Your work (MODE, TASK, REPO ROOT, ENTRY POINTS,
  REPORT, CONTEXT FILE, RETURN), two closing lines
  (# Your plugins: one block per plugin, in the order language, frameworks,
  standards, procedures, as the dispatch lists them; none when no plugin;
  ENTRY POINTS: none when none; paths absolute, in code spans).

Leaves only (a SIGKILL aside): once every check passes, an absent or empty
baseline file of the dispatch, atomically (shape: see
scripts/agent-dispatch/${NAMES_MODULE}.jq); one holding a baseline is kept.
On a deny, the Denial file.
The repository is only read.

Exit codes:
  0  a decision, or none; read stdout
  2  usage error, or a deny that could not be built, so Claude Code blocks
     the call; show stderr and stop
  129, 130, 143  stopped by HUP, INT or TERM before a listed agent was
     known; no output

Dependencies (skills in \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/skills/):
  POSIX sh; jq 1.6+ (--rawfile) (macOS: brew install jq; Linux: the distro's jq)
  awk, cat, date, dd, grep, mktemp, mv, readlink, rm, tr, wc, and sha256sum
    or shasum (base system)
  git, for the baseline (macOS: xcode-select --install; Linux: the distro's
    git)
  ${CONTEXT_PROCEDURE}: ${TEMPLATE_FILE}, and in scripts/:
    agent-context-file-checks.sh, context-versions.sh,
    agent-context-validator.jq, agent-context-url.jq
  ${CRUCIBLE_SKILL}: scripts/lib/crucible-space.sh, scripts/lib/${PRUNE_NAME}.jq,
    scripts/crucible.sh
  ${RENDER_LIB}: ${VIEW_NAME}.jq
  this skill: scripts/agent-dispatch/agent-dispatch-validator.jq,
    ${NAMES_MODULE}.jq
EOF
}

# Succeeds when stdin (fd 0) is open. On a closed stdin, $(cat) reads the
# command substitution's own pipe, which lands on the free fd 0, and blocks
# forever. stderr is closed rather than sent to /dev/null for the probe, since
# opening a file would take fd 0 and hide the closed stdin; the subshell keeps
# the shell's own "Bad file descriptor" line on that closed stderr too.
stdin_is_open() {
	(exec 3<&0) 2>&- && return 0
	printf '%s: stdin is closed; expected the PreToolUse hook JSON on stdin\n' "${PROG}" >&2
	return 1
}

# Sets is_listed_agent=true when the call is an Agent dispatch of a listed agent.
classify_call() {
	if ! command -v jq >/dev/null 2>&1; then
		# shellcheck disable=SC2310 # its status is the match result; errexit adds nothing
		names_listed_agent_as_text || return 0
		is_listed_agent=true
		emit "${NO_JQ_DENY}"
	fi
	if ! verdict=$(printf '%s' "${hook_input}" | jq -r --arg agents "${LISTED_AGENTS}" '
		(.tool_input.subagent_type? // "") as $agent
		| .tool_name == "Agent" and ($agents | split(" ") | any(. == $agent))'); then
		# shellcheck disable=SC2310 # its status is the match result; errexit adds nothing
		names_listed_agent_as_text || return 0
		is_listed_agent=true
		fault "the hook input is not valid JSON, so this dispatch is denied; the hook expects one PreToolUse object on stdin, as Claude Code sends it to a registered hook entry."
	fi
	[ "${verdict}" = true ] && is_listed_agent=true
	return 0
}

# Succeeds when the raw hook input names a listed agent as subagent_type, or a
# subagent_type it can't read without decoding. Used only when jq can't parse
# the input, so the match is on text, and a doubt counts as a listed agent.
names_listed_agent_as_text() {
	printf '%s' "${hook_input}" | awk -v agents="${LISTED_AGENTS}" "${LISTED_AGENT_TEXT_AWK}"
}

# Prints the prompt's status (notstring, lines, form or path) and, for path,
# the value after "DISPATCH: ".
read_dispatch_line() {
	printf '%s' "${hook_input}" | jq -r '
		.tool_input.prompt as $prompt
		| if ($prompt | type) != "string" then "notstring"
		  else ($prompt | rtrimstr("\n")) as $line
			| if ($line | contains("\n")) then "lines"
			  elif ($line | startswith("DISPATCH: ") | not) then "form"
			  else "path", $line[10:] end
		  end'
}

# Runs every check on dispatch_path for agent $1 and, when all pass, sets
# message_file to the message built from the checked copies; else refuses with
# every problem.
prepare_message() {
	expected_agent=$1
	problems=''
	resolve_space_root
	check_dispatch_file
	read_dispatch_fields
	[ "${dispatch_agent}" = "${expected_agent}" ] ||
		add_problem AGENT "the dispatch is for \"${dispatch_agent}\"; expected \"${expected_agent}\"" "${dispatch_path}"
	check_context
	check_report
	check_baseline
	resolve_skills_dir
	check_plugins
	[ -z "${problems}" ] || refuse_all
	build_message
}

# Checks the base tools, the shared checks, the shared names and the template
# once jq is known present, or faults: any missing is an install or host
# fault, not the dispatch's. Creates the temp folder the template copy goes in.
load_dependencies() {
	context_skill_dir="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/skills/${CONTEXT_PROCEDURE}"
	check_base_tools
	load_shared_checks
	load_shared_names
	make_snapshot_dir
	load_template
}

# Faults unless every base tool the checks and the message use is on PATH.
check_base_tools() {
	for tool in awk cat date dd grep mktemp mv readlink rm tr wc; do
		command -v "${tool}" >/dev/null 2>&1 ||
			fault "${tool} missing from PATH; expected it on PATH; ${tool} is part of the base system, so the fault is in the host, not in the dispatch."
	done
}

# Sources the shared path checks, loads the read checks (the space rules and
# the sha256 tool among them) and finds the validators.
load_shared_checks() {
	shared_dir=$(script_dir)/..
	context_lib="${context_skill_dir}/scripts/agent-context-file-checks.sh"
	dispatch_validator="${shared_dir}/agent-dispatch/agent-dispatch-validator.jq"
	names_module="${shared_dir}/agent-dispatch/${NAMES_MODULE}.jq"
	[ -f "${context_lib}" ] && [ -r "${context_lib}" ] ||
		fault "the shared check ${context_lib} is missing or unreadable; ${PROG} needs it; the fault is in the ${CONTEXT_PROCEDURE} install, not in the dispatch."
	for shared_file in "${dispatch_validator}" "${names_module}"; do
		[ -f "${shared_file}" ] && [ -r "${shared_file}" ] ||
			fault "the shared check ${shared_file} is missing or unreadable; ${PROG} needs it; the fault is in the ${REASON_PREFIX%:} install, not in the dispatch."
	done
	# shellcheck source=../../../../procedures/procedure-context/scripts/agent-context-file-checks.sh
	. "${context_lib}"
	# shellcheck disable=SC2310 # its status says whether the checks loaded; the problem is read here
	context_load_checks "${context_skill_dir%/*}" ||
		fault "${context_load_problem}; ${PROG} needs it; the fault is in the install or the host, not in the dispatch."
}

# Sets BASELINE_KIND from the shared names module, and faults unless its
# listed agents are LISTED_AGENTS.
load_shared_names() {
	# shellcheck disable=SC2310 # its status is jq's; a failure faults
	module_listed_agents=$(read_shared_name 'listed_agents | join(" ")') ||
		fault "jq could not read listed_agents from ${names_module}; expected jq 1.6+ and the flow's shared names; the fault is in the flow-agent-initialization install, not in the dispatch."
	[ "${module_listed_agents}" = "${LISTED_AGENTS}" ] ||
		fault "the listed agents differ from ${NAMES_MODULE}.jq (${PROG}: ${LISTED_AGENTS}; module: ${module_listed_agents}); expected the same list; the fault is in the flow-agent-initialization install, not in the dispatch."
	# shellcheck disable=SC2310 # its status is jq's; a failure faults
	BASELINE_KIND=$(read_shared_name baseline_kind) && [ -n "${BASELINE_KIND}" ] ||
		fault "jq could not read baseline_kind from ${names_module}; expected jq 1.6+ and the flow's shared names; the fault is in the flow-agent-initialization install, not in the dispatch."
	readonly BASELINE_KIND
}

# Prints the value of jq expression $1 over the shared names module, with
# $agent set to $2 (empty when not given).
read_shared_name() {
	names_dir=$(script_dir)/../agent-dispatch
	jq -nr -L "${names_dir}" --arg agent "${2-}" "include \"${NAMES_MODULE}\"; $1" </dev/null
}

# Creates the private temp folder that holds every checked file's copy.
make_snapshot_dir() {
	snapshot_dir=$(mktemp -d "${TMPDIR:-/tmp}/${PROG}.XXXXXX") ||
		fault "mktemp could not create a temp folder; ${PROG} needs a writable \${TMPDIR:-/tmp}; the cause is on stderr."
	case ${snapshot_dir} in
		/*) ;;
		*) snapshot_dir="${PWD}/${snapshot_dir}" ;;
	esac
}

# Copies the template into the temp folder as template_copy, or faults: an
# unusable template is an install fault, so every dispatch is denied until
# procedure-context is reinstalled.
load_template() {
	template_dir=${context_skill_dir}
	real_template_dir=''
	# shellcheck disable=SC2310 # its status is the resolve result; a failure faults below
	resolve_dir "${template_dir}" && real_template_dir=${resolved_dir%/} && template_dir=${real_template_dir}
	template_path="${template_dir}/${TEMPLATE_FILE}"
	template_copy="${snapshot_dir}/template"
	# shellcheck disable=SC2310 # a pure test; its status is the answer
	is_template_usable ||
		fault "the context-handling template ${template_path} is missing or empty; expected a readable regular file inside ${template_dir}/ once symlinks are followed, holding more than whitespace; the fault is in the ${CONTEXT_PROCEDURE} install, not in the dispatch."
}

# True when template_path is a readable regular file that, its symlinks
# followed, lies inside real_template_dir, and its copy holds a character
# other than whitespace: validate-dependencies.sh's test, so the install check
# and the hook agree. The copy is what the message sends.
is_template_usable() {
	[ -n "${real_template_dir}" ] || return 1
	[ -f "${template_path}" ] && [ -r "${template_path}" ] || return 1
	# shellcheck disable=SC2310 # its status is the resolve result; a failure is the answer
	resolve_file "${template_path}" || return 1
	case ${resolved_file} in
		"${real_template_dir}"/*) ;;
		*) return 1 ;;
	esac
	cat -- "${template_path}" >"${template_copy}" 2>/dev/null || return 1
	grep -q '[^[:space:]]' "${template_copy}" 2>/dev/null
}

# Resolves the Crucible space by the space rules, for the path checks, or
# faults: a space they refuse is the install's or the host's, not the dispatch's.
resolve_space_root() {
	# shellcheck disable=SC2310 # its status says whether the root is usable; the problem is read below
	crucible_resolve_root ||
		fault "the Crucible space is unusable (${crucible_root_problem}); the fault is in CRUCIBLE_HOME or HOME, not in the dispatch."
}

# Refuses unless dispatch_path is a regular file directly in an effort's
# dispatches folder holding a valid dispatch; sets dispatch_copy and
# dispatch_effort.
check_dispatch_file() {
	path_problem=$(context_path_problem "${dispatch_path}")
	[ -z "${path_problem}" ] || refuse_now "DISPATCH ${path_problem}; expected ${context_path_expected}: ${dispatch_path}"
	# shellcheck disable=SC2310 # its status is the test result; errexit adds nothing
	crucible_check_effort_item "${dispatch_path}" dispatches ||
		refuse_now "DISPATCH path is ${crucible_item_problem}: ${dispatch_path}"
	dispatch_effort=${crucible_effort}
	[ ! -L "${dispatch_path}" ] || refuse_now "DISPATCH file is a symlink; expected a regular file: ${dispatch_path}"
	[ -f "${dispatch_path}" ] && [ -r "${dispatch_path}" ] ||
		refuse_now "DISPATCH file is missing, unreadable or not a regular file; expected a readable regular file: ${dispatch_path}"
	dispatch_copy="${snapshot_dir}/dispatch"
	cat -- "${dispatch_path}" >"${dispatch_copy}" ||
		refuse_now "DISPATCH file is missing, unreadable or not a regular file; expected a readable regular file: ${dispatch_path}"
	jq empty "${dispatch_copy}" </dev/null >/dev/null 2>&1 || refuse_now "DISPATCH file is not valid JSON; expected one JSON object: ${dispatch_path}"
	shape_report=$(jq -rs -f "${dispatch_validator}" "${dispatch_copy}" </dev/null) ||
		fault "jq could not run the dispatch check ${dispatch_validator}; the hook needs jq 1.6+; the cause is on stderr."
	[ -n "${shape_report}" ] || return 0
	shape_problems=$(join_lines "${shape_report}")
	refuse_now "DISPATCH file does not have the dispatch shape (${shape_problems}); expected the shape agent-dispatch-validator.jq checks; the flow's step 8 writes a new dispatch file: ${dispatch_path}"
}

# Sets dispatch_agent, dispatch_context, dispatch_context_sha256,
# dispatch_report, dispatch_baseline, dispatch_repo_root and plugin_entries
# (one "<name>\t<path>" line per plugin file: the language, the frameworks,
# the standards, then the procedures, each kind in the dispatch's order) from
# the checked dispatch copy. The validator holds each path to one line.
read_dispatch_fields() {
	dispatch_fields=$(jq -r '.agent, .context.path, .context.sha256, .report, .baseline, .repo_root' "${dispatch_copy}" </dev/null) ||
		fault "jq could not read the dispatch copy; the hook needs jq 1.6+; the cause is on stderr."
	{
		IFS= read -r dispatch_agent
		IFS= read -r dispatch_context
		IFS= read -r dispatch_context_sha256
		IFS= read -r dispatch_report
		IFS= read -r dispatch_baseline
		IFS= read -r dispatch_repo_root
	} <<EOF
${dispatch_fields}
EOF
	plugin_entries=$(jq -r '.plugins // {} | (.language // empty), (.frameworks, .standards, .procedures | arrays[])
		| (.name | gsub("[[:cntrl:]]"; "?")) as $name | .paths[] | "\($name)\t\(.)"' "${dispatch_copy}" </dev/null) ||
		fault "jq could not read the dispatch copy; the hook needs jq 1.6+; the cause is on stderr."
}

# Adds a problem for the first failing check of the context file, and sets
# context_pretty to its pretty-printed copy when every check passes. The
# read checks copy the file once (one byte over the cap at most, so an
# oversized file is never read whole); the digest and the message read that copy.
check_context() {
	context_path=${dispatch_context}
	path_problem=$(context_path_problem "${context_path}")
	if [ -n "${path_problem}" ]; then
		add_problem CONTEXT "${path_problem}; expected ${context_path_expected}" "${context_path}"
		return 0
	fi
	context_copy="${snapshot_dir}/context"
	# shellcheck disable=SC2310 # its status is a tool's; a failure faults
	context_read_problem "${context_path}" "${context_copy}" ||
		fault "a tool failed on the context read checks (jq or wc); the fault is in the host, not in the dispatch; the cause is on stderr."
	if [ "${context_read_fault}" = stale ]; then
		add_problem CONTEXT-STALE "${context_read_text}" "${context_path}"
		return 0
	fi
	if [ -n "${context_read_fault}" ]; then
		add_problem CONTEXT "${context_read_text}" "${context_path}"
		return 0
	fi
	# shellcheck disable=SC2310 # its status is the tool's; a failure faults
	compute_context_digest "${context_copy}" ||
		fault "${context_digest_tool} could not hash the temp copy; the fault is in the host, not in the dispatch; the cause is on stderr."
	if [ "${context_digest}" != "${dispatch_context_sha256}" ]; then
		add_problem CONTEXT "file changed since the dispatch was written (sha256 $(printf '%.12s' "${dispatch_context_sha256}") written, $(printf '%.12s' "${context_digest}") now); expected the sha256 the dispatch holds; ${CONTEXT_PROCEDURE}'s context.sh extend writes a new version" "${context_path}"
		return 0
	fi
	context_pretty="${snapshot_dir}/context.pretty"
	jq . "${context_copy}" </dev/null >"${context_pretty}" ||
		fault "jq could not print the context copy; the hook needs jq 1.6+; the cause is on stderr."
}

# Adds a problem when the report path fails the context path checks, is not
# in the reports folder of the dispatch's agent in the dispatch's effort, or
# is not an empty regular file.
check_report() {
	path_problem=$(context_path_problem "${dispatch_report}")
	if [ -n "${path_problem}" ]; then
		add_problem REPORT "${path_problem}; expected ${context_path_expected}" "${dispatch_report}"
		return 0
	fi
	# shellcheck disable=SC2310 # its status is jq's; a failure faults
	# shellcheck disable=SC2016 # $agent is jq's
	report_kind=$(read_shared_name '$agent | report_kind' "${dispatch_agent}") ||
		fault "jq could not read report_kind from ${names_module}; expected jq 1.6+ and the flow's shared names; the fault is in the flow-agent-initialization install, not in the dispatch."
	# The validator admits only the agents of report_kinds; this guards a drift between them.
	[ -n "${report_kind}" ] ||
		fault "${NAMES_MODULE}.jq names no report kind for agent \"${dispatch_agent}\"; expected one for every dispatched agent; the fault is in the flow-agent-initialization install, not in the dispatch."
	# shellcheck disable=SC2310 # its status is the test result; errexit adds nothing
	if ! crucible_check_effort_item "${dispatch_report}" "${report_kind}"; then
		add_problem REPORT "path is ${crucible_item_problem}" "${dispatch_report}"
		return 0
	fi
	if [ "${crucible_effort}" != "${dispatch_effort}" ]; then
		add_problem REPORT "file is in effort ${crucible_effort}, not the dispatch's; expected a file directly in ${dispatch_effort}/${report_kind}/" "${dispatch_report}"
		return 0
	fi
	if [ -L "${dispatch_report}" ] || [ ! -f "${dispatch_report}" ]; then
		add_problem REPORT 'file is missing, a symlink or not a regular file; expected the empty regular file made for this dispatch' "${dispatch_report}"
	elif [ -s "${dispatch_report}" ]; then
		add_problem REPORT 'file is not empty; expected the empty report file made for this dispatch' "${dispatch_report}"
	fi
}

# Adds a problem when the baseline path fails the context path checks, is not
# in the dispatch's effort's baselines folder, or is not an absent or regular file; one that
# already holds text must hold a baseline of the dispatch's repo_root. Sets
# baseline_filled to true for a baseline already written (a resend), which is
# then kept as it is.
check_baseline() {
	baseline_filled=false
	path_problem=$(context_path_problem "${dispatch_baseline}")
	if [ -n "${path_problem}" ]; then
		add_problem BASELINE "${path_problem}; expected ${context_path_expected}" "${dispatch_baseline}"
		return 0
	fi
	# shellcheck disable=SC2310 # its status is the test result; errexit adds nothing
	if ! crucible_check_effort_item "${dispatch_baseline}" "${BASELINE_KIND}"; then
		add_problem BASELINE "path is ${crucible_item_problem}" "${dispatch_baseline}"
		return 0
	fi
	if [ "${crucible_effort}" != "${dispatch_effort}" ]; then
		add_problem BASELINE "file is in effort ${crucible_effort}, not the dispatch's; expected a file directly in ${dispatch_effort}/${BASELINE_KIND}/" "${dispatch_baseline}"
		return 0
	fi
	if [ -L "${dispatch_baseline}" ]; then
		add_problem BASELINE 'file is a symlink; expected the regular file made for this dispatch, or none yet' "${dispatch_baseline}"
		return 0
	fi
	[ -e "${dispatch_baseline}" ] || return 0
	if [ ! -f "${dispatch_baseline}" ] || [ ! -r "${dispatch_baseline}" ]; then
		add_problem BASELINE 'file is unreadable or not a regular file; expected the regular file made for this dispatch' "${dispatch_baseline}"
		return 0
	fi
	[ -s "${dispatch_baseline}" ] || return 0
	baseline_copy="${snapshot_dir}/baseline"
	if ! cat -- "${dispatch_baseline}" >"${baseline_copy}"; then
		add_problem BASELINE 'file is unreadable or not a regular file; expected the regular file made for this dispatch' "${dispatch_baseline}"
		return 0
	fi
	# shellcheck disable=SC2310 # its status is jq's; a failure faults
	baseline_report=$(baseline_shape_problems "${baseline_copy}") ||
		fault "jq could not run the baseline check of ${names_module}; the hook needs jq 1.6+; the cause is on stderr."
	if [ -n "${baseline_report}" ]; then
		baseline_problems=$(join_lines "${baseline_report}")
		add_problem BASELINE "file holds no baseline of this dispatch (${baseline_problems}); expected the git status this hook writes at the first call; the flow stops this dispatch until the human fixes this file" "${dispatch_baseline}"
		return 0
	fi
	baseline_filled=true
}

# Prints the problems of baseline file $1 against the shared baseline shape,
# for the dispatch's repo_root, one per line; fails only when jq does.
baseline_shape_problems() {
	if ! jq empty "$1" </dev/null >/dev/null 2>&1; then
		printf 'not valid JSON; expected one JSON object\n'
		return 0
	fi
	jq -rs -L "${names_module%/*}" --arg repo_root "${dispatch_repo_root}" \
		"include \"${NAMES_MODULE}\"; if length == 1 then .[0] | baseline_problems(\$repo_root) else \"\\(length) JSON values; expected one object\" end" \
		"$1" </dev/null
}

# Writes the repository's git status, as the shared baseline shape, into the
# dispatch's baseline file, unless a resend finds it written already. Runs once
# every check has passed, before the agent can change the tree; never after.
# Written through a temp file in its folder moved onto it.
fill_baseline() {
	[ "${baseline_filled}" = false ] || return 0
	# Missing git: a BASELINE-WRITE deny; any other missing dependency: a deny
	# with no KIND.
	command -v git >/dev/null 2>&1 ||
		baseline_write_failed "git missing from PATH; expected git on PATH to take the dispatch's baseline; the dispatch can be sent again once git is on PATH"
	status_raw="${snapshot_dir}/status.raw"
	status_text="${snapshot_dir}/status.text"
	baseline_built="${snapshot_dir}/baseline.built"
	# The tree is read only: no optional lock, no fsmonitor command, no prompt.
	GIT_TERMINAL_PROMPT=0 GIT_OPTIONAL_LOCKS=0 GIT_CONFIG_NOSYSTEM=1 \
		git -c core.fsmonitor=false -C "${dispatch_repo_root}" status --porcelain=v1 -z --no-renames \
		</dev/null >"${status_raw}" 2>"${snapshot_dir}/status.err" || {
		git_message=$(first_line "${snapshot_dir}/status.err")
		baseline_write_failed "git status failed in repo_root ${dispatch_repo_root} (${git_message}); expected the repository's git work tree; the dispatch can be sent again once the repository is a git work tree"
	}
	tr '\000' '\001' <"${status_raw}" >"${status_text}" ||
		fault "tr could not convert git's NUL-separated output; the fault is in the host, not in the dispatch; the cause is on stderr."
	taken_raw=$(date +%Y-%m-%dT%H:%M:%S%z) ||
		fault "date failed; expected it to print the local time as +%Y-%m-%dT%H:%M:%S%z; the fault is in the host, not in the dispatch."
	taken="${taken_raw%??}:${taken_raw#"${taken_raw%??}"}"
	# repo_root binds the baseline to its dispatch and only the checks read it;
	# taken is kept for audit and not read.
	jq -n --rawfile status "${status_text}" --arg repo_root "${dispatch_repo_root}" --arg taken "${taken}" \
		'{repo_root: $repo_root, taken: $taken, entries: ($status | split("\u0001") | map(select(length > 0)))}' \
		</dev/null >"${baseline_built}" ||
		fault "jq could not build the baseline; the hook needs jq 1.6+ (--rawfile); the cause is on stderr."
	# shellcheck disable=SC2310 # its status is jq's; a failure faults
	built_problems=$(baseline_shape_problems "${baseline_built}") ||
		fault "jq could not run the baseline check of ${names_module}; the hook needs jq 1.6+; the cause is on stderr."
	if [ -n "${built_problems}" ]; then
		built_problems=$(join_lines "${built_problems}")
		fault "the baseline built from git status fails its own shape (${built_problems}); the fault is in ${PROG}, not in the dispatch."
	fi
	baseline_dir=${dispatch_baseline%/*}
	temp_file=$(mktemp "${baseline_dir}/.${dispatch_baseline##*/}.XXXXXX") ||
		baseline_write_failed "mktemp could not create a temp file beside the baseline file; expected a writable folder ${baseline_dir}; the dispatch can be sent again once that folder is writable and has free space"
	cat -- "${baseline_built}" >"${temp_file}" ||
		baseline_write_failed "could not write the temp file ${temp_file}; expected a writable folder ${baseline_dir}; the dispatch can be sent again once that folder has free space"
	# A call racing this one may have written it since the check; its baseline is kept.
	if [ -s "${dispatch_baseline}" ]; then
		rm -f -- "${temp_file}"
		temp_file=''
		return 0
	fi
	mv -f -- "${temp_file}" "${dispatch_baseline}" ||
		baseline_write_failed "mv could not move the temp file onto the baseline file; expected a writable folder ${baseline_dir}; the dispatch can be sent again once that folder is writable"
	temp_file=''
}

# Prints the first line of file $1, control characters as "?", or "no message".
first_line() {
	message=''
	{ IFS= read -r message <"$1"; } 2>/dev/null || true
	message=$(printf '%s' "${message}" | tr '[:cntrl:]' '?')
	printf '%s' "${message:-no message}"
}

# The baseline can't be written: a deny, the problem $1 under KIND
# BASELINE-WRITE with the baseline path.
baseline_write_failed() {
	baseline_line="BASELINE-WRITE $1: ${dispatch_baseline}"
	problems="${baseline_line}${NL}"
	deny_problems ''
}

# Prints the folder this script was run from (".", when run by a bare name).
script_dir() {
	case $0 in
		*/*) printf '%s' "${0%/*}" ;;
		*) printf '.' ;;
	esac
}

# Prints the lines of $1 joined by "; ".
join_lines() {
	joined=''
	while IFS= read -r line; do
		joined="${joined}${joined:+; }${line}"
	done <<EOF
$1
EOF
	printf '%s' "${joined}"
}

# Sets skills_dir to the installed skills folder, absolute, without a trailing slash.
resolve_skills_dir() {
	skills_dir="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/skills"
	case ${skills_dir} in
		/*) ;;
		*) skills_dir="${PWD}/${skills_dir#./}" ;;
	esac
	while [ "${skills_dir}" != '/' ] && [ "${skills_dir%/}" != "${skills_dir}" ]; do
		skills_dir=${skills_dir%/}
	done
}

# Checks, copies and scans the plugin files in plugin_entries, adding a problem for each fault.
check_plugins() {
	copy_args=''
	[ -n "${plugin_entries}" ] || return 0
	check_paths
	snapshot_files
	[ -n "${copy_args}" ] || return 0
	# shellcheck disable=SC2310 # the function's status is its final awk's; a failure faults
	scan_report=$(scan_files) ||
		fault "awk could not scan the plugin files; the hook expects readable text files; the cause is on stderr."
	[ -z "${scan_report}" ] || problems="${problems}${scan_report}${NL}"
}

# Validates every entry in plugin_entries; adds problems, and sets the per-file
# arguments in build_args, one name, kind and path line per file that passed.
check_paths() {
	build_args=''
	judged_plugin=''
	run_plugin=''
	run_plugins='
'
	while IFS="${TAB}" read -r listed_name path; do
		check_path "${path}"
		[ -n "${path_problem}" ] || [ "${plugin_name}" = "${listed_name}" ] ||
			path_problem="path is in plugin folder ${plugin_name}, but listed under plugin ${listed_name}; expected it listed under plugin ${plugin_name}"
		[ -n "${path_problem}" ] || check_run_order
		if [ -n "${path_problem}" ]; then
			add_problem PLUGIN "${path_problem}" "${path}"
		else
			build_args="${build_args}${plugin_name}
${file_kind}
${path}
"
		fi
	done <<EOF
${plugin_entries}
EOF
}

# Sets path_problem, plugin_name and file_kind for path $1 (every path check, then containment).
check_path() {
	path_problem=''
	case $1 in
		/*) ;;
		*) path_problem="path is not absolute; expected a path under ${skills_dir}/"; return 0 ;;
	esac
	case $1 in
		*/../* | */..) path_problem='path has a .. segment; expected a path without .. segments'; return 0 ;;
		*) ;;
	esac
	case $1 in
		"${skills_dir}"/*) ;;
		*) path_problem="path is outside the skills folder; expected a path under ${skills_dir}/"; return 0 ;;
	esac
	path_in_skills=${1#"${skills_dir}"/}
	plugin_name=${path_in_skills%%/*}
	case ${plugin_name} in
		language-?* | framework-?* | standard-?* | procedure-?*) ;;
		*) path_problem="path is not in a plugin folder; expected a path in a language-*, framework-*, standard-* or procedure-* folder of ${skills_dir}/"; return 0 ;;
	esac
	[ -f "${skills_dir}/${plugin_name}/SKILL.md" ] || {
		path_problem="plugin folder ${plugin_name} has no SKILL.md; expected ${skills_dir}/${plugin_name}/SKILL.md"
		return 0
	}
	judge_plugin "${plugin_name}"
	[ -z "${not_plugin_reason}" ] || {
		path_problem="not a plugin (${not_plugin_reason})"
		return 0
	}
	case ${path_in_skills#"${plugin_name}"} in
		/SKILL.md) file_kind=skill ;;
		/references/?*) file_kind=reference ;;
		*) path_problem="path is not a plugin file; expected ${plugin_name}/SKILL.md or a file under ${plugin_name}/references/"; return 0 ;;
	esac
	[ -f "$1" ] && [ -r "$1" ] || {
		path_problem='file is missing, unreadable or not a regular file; expected a readable regular file'
		return 0
	}
	check_containment "$1" "${skills_dir}/${plugin_name}"
}

# Sets path_problem when a checked path starts a run of its plugin folder's
# paths that is not the folder's first run, or that does not open with its SKILL.md.
# run_plugins holds the folders seen so far, one per line; a name holds no newline.
check_run_order() {
	[ "${plugin_name}" != "${run_plugin}" ] || return 0
	run_plugin=${plugin_name}
	case ${run_plugins} in
		*"
${plugin_name}
"*)
			path_problem="plugin folder ${plugin_name} appears in two separate runs; expected all its paths next to each other"
			return 0
			;;
		*) ;;
	esac
	run_plugins="${run_plugins}${plugin_name}
"
	[ "${file_kind}" = skill ] ||
		path_problem="first path of plugin folder ${plugin_name} is not ${plugin_name}/SKILL.md; expected its SKILL.md before its references"
}

# Sets path_problem when file $1, its symlinks followed, resolves outside the
# real path of its plugin folder $2. The folder itself may be a symlink.
check_containment() {
	# shellcheck disable=SC2310 # its status is the resolve result; errexit adds nothing
	resolve_dir "$2" || {
		path_problem='plugin folder can not be resolved to a real path; expected a folder that can be entered'
		return 0
	}
	real_plugin_dir=${resolved_dir}
	# shellcheck disable=SC2310 # its status is the resolve result; errexit adds nothing
	resolve_file "$1" || {
		path_problem="file can not be resolved to a real path; expected at most ${MAX_LINK_HOPS} symlinks and no broken link"
		return 0
	}
	case ${resolved_file} in
		"${real_plugin_dir%/}"/*) ;;
		*) path_problem="file resolves outside its plugin folder (to ${resolved_file}); expected a real path under ${real_plugin_dir%/}/" ;;
	esac
}

# Sets resolved_file to the real path of file $1, following its symlinks.
resolve_file() {
	link_path=$1
	link_hops=0
	while [ -L "${link_path}" ]; do
		link_hops=$((link_hops + 1))
		[ "${link_hops}" -le "${MAX_LINK_HOPS}" ] || return 1
		# The trailing "." keeps a name that ends in a newline intact through $( ).
		link_target=$(readlink -- "${link_path}" && printf .) || return 1
		link_target=${link_target%??}
		case ${link_target} in
			/*) link_path=${link_target} ;;
			*) link_path=${link_path%/*}/${link_target} ;;
		esac
	done
	link_dir=${link_path%/*}
	# shellcheck disable=SC2310 # its status is the resolve result; errexit adds nothing
	resolve_dir "${link_dir:-/}" || return 1
	resolved_file=${resolved_dir%/}/${link_path##*/}
}

# Sets resolved_dir to the real path of directory $1; fails when it can't be entered.
resolve_dir() {
	# The trailing "." keeps a name that ends in a newline intact through $( ).
	resolved_dir=$(cd -P -- "$1" && pwd -P && printf .) || return 1
	resolved_dir=${resolved_dir%??}
}

# Sets not_plugin_reason (empty for a plugin) for the folder $1, judged by its
# SKILL.md frontmatter. Consecutive paths share a folder, so the last verdict is reused.
judge_plugin() {
	[ "$1" != "${judged_plugin}" ] || return 0
	judged_plugin=$1
	plugin_test "$1" "${skills_dir}/$1/SKILL.md"
}

# Sets not_plugin_reason (empty for a plugin) for the folder $1 from the
# SKILL.md frontmatter in file $2, by list-plugins.sh's rules for it.
plugin_test() {
	not_plugin_reason=''
	if ! frontmatter=$(awk "${PLUGIN_FRONTMATTER_AWK}" "$2"); then
		not_plugin_reason="$1/SKILL.md has no frontmatter closed by a --- line; expected a frontmatter opened and closed by --- lines"
		return 0
	fi
	frontmatter_name=${frontmatter%%"${TAB}"*}
	frontmatter_rest=${frontmatter#*"${TAB}"}
	frontmatter_disabled=${frontmatter_rest%%"${TAB}"*}
	frontmatter_rest=${frontmatter_rest#*"${TAB}"}
	frontmatter_label=${frontmatter_rest%%"${TAB}"*}
	frontmatter_base=${frontmatter_rest#*"${TAB}"}
	[ "${frontmatter_name}" = "$1" ] ||
		add_not_plugin_reason "$1/SKILL.md has name: '${frontmatter_name}'; expected name: $1"
	[ "${frontmatter_disabled}" = true ] ||
		add_not_plugin_reason "$1/SKILL.md has disable-model-invocation: '${frontmatter_disabled}'; expected disable-model-invocation: true"
	[ -n "${frontmatter_label}" ] ||
		add_not_plugin_reason "$1/SKILL.md has no metadata.label; expected a \"  label:\" line under \"metadata:\""
	[ -z "${frontmatter_base}" ] ||
		add_not_plugin_reason "$1/SKILL.md sets metadata.base; metadata.base is not supported; remove it"
}

# Appends reason $1 to not_plugin_reason, comma-separated.
add_not_plugin_reason() {
	not_plugin_reason="${not_plugin_reason}${not_plugin_reason:+, }$1"
}

# Appends "<KIND $1> <problem $2>: <subject $3>" to problems, one per line.
add_problem() {
	problems="${problems}$1 $2: $3${NL}"
}

# Copies each file in build_args once into the private temp folder and sets
# copy_args to its name, kind, path and copy lines; re-runs the plugin test on
# each SKILL.md copy. Adds a problem for a file that can't be copied or fails it.
snapshot_files() {
	copy_args=''
	copy_index=0
	while IFS= read -r name && IFS= read -r kind && IFS= read -r path; do
		copy_index=$((copy_index + 1))
		copy="${snapshot_dir}/plugin-${copy_index}"
		cat -- "${path}" >"${copy}" || {
			add_problem PLUGIN 'file is missing, unreadable or not a regular file; expected a readable regular file' "${path}"
			continue
		}
		if [ "${kind}" = skill ]; then
			plugin_test "${name}" "${copy}"
			[ -z "${not_plugin_reason}" ] || {
				add_problem PLUGIN "not a plugin (${not_plugin_reason})" "${path}"
				continue
			}
		fi
		copy_args="${copy_args}${name}
${kind}
${path}
${copy}
"
	done <<EOF
${build_args}
EOF
}

# Prints the token and frontmatter problems of the copied files, one per line.
# The copies' paths are absolute, so awk never reads one as a var=value operand.
scan_files() {
	set --
	checked_paths=''
	while IFS= read -r name && IFS= read -r kind && IFS= read -r path && IFS= read -r copy; do
		set -- "$@" "${copy}"
		checked_paths="${checked_paths}${path}
"
	done <<EOF
${copy_args}
EOF
	PREPARE_PROMPT_SCAN_PATHS=${checked_paths} awk "${SCAN_AWK}" "$@"
}

# Sets message_file to the message built from the checked copies, each read byte for byte by jq.
build_message() {
	set --
	items=''
	item_index=0
	while IFS= read -r name && IFS= read -r kind && IFS= read -r path && IFS= read -r copy; do
		set -- "$@" --arg "n${item_index}" "${name}" --arg "k${item_index}" "${kind}" --rawfile "f${item_index}" "${copy}"
		items="${items}${items:+,}[\$n${item_index},\$k${item_index},\$f${item_index}]"
		item_index=$((item_index + 1))
	done <<EOF
${copy_args}
EOF
	message_file="${snapshot_dir}/message"
	jq -nj --rawfile dispatch "${dispatch_copy}" --rawfile context "${context_pretty}" \
		--rawfile template "${template_copy}" \
		"$@" "${MESSAGE_JQ_HEAD} [${items}] ${MESSAGE_JQ_TAIL}" </dev/null >"${message_file}" ||
		fault "jq could not build the message; the hook needs jq 1.6+ (--rawfile); the cause is on stderr."
}

# Refuses with problem $1 alone, when the later checks can't run without it passing.
refuse_now() {
	problems="$1${NL}"
	refuse_all
}

# Refuses with every problem: a deny.
refuse_all() {
	deny_problems "${DISPATCH_HINT}"
}

# Denies with every problem, the compact reason DENIAL_JQ renders, after
# writing them in full with hint $1 ("" for none) to the details file when the
# dispatch's effort is known.
deny_problems() {
	view_dir="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/skills/${RENDER_LIB}"
	prune_dir="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/skills/${CRUCIBLE_SKILL}/scripts/lib"
	require_denial_module "${view_dir}/${VIEW_NAME}.jq" "${RENDER_LIB}"
	require_denial_module "${prune_dir}/${PRUNE_NAME}.jq" "${CRUCIBLE_SKILL}"
	write_denial_details "$1"
	reason=$(jq -nr -L "${view_dir}" --arg problems "${problems}" --arg kinds "${PROBLEM_KINDS}" \
		--arg prefix "${REASON_PREFIX}" --arg details "${details_path}" \
		--argjson max_shown "${DENIAL_MAX_SHOWN}" --argjson line_cap "${DENIAL_LINE_CAP}" \
		"include \"${VIEW_NAME}\"; ${DENIAL_JQ}" </dev/null) ||
		fault "jq could not render the deny reason with ${view_dir}/${VIEW_NAME}.jq; the hook needs jq 1.6+; the cause is on stderr."
	deny "${reason}"
}

# Faults unless module file $1 of skill $2 is readable.
require_denial_module() {
	[ -f "$1" ] && [ -r "$1" ] ||
		fault "the $2 module $1 is missing or unreadable; ${PROG} needs it; the fault is in the $2 install, not in the dispatch."
}

# Sets details_path to a new file in the dispatch's effort's cache/denials
# holding every problem in full, with hint $1; leaves it empty, a line on
# stderr, when no effort is known or the file can't be written.
write_denial_details() {
	details_path=''
	[ -n "${dispatch_effort}" ] || return 0
	denial_crucible="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/skills/${CRUCIBLE_SKILL}/scripts/crucible.sh"
	if [ ! -f "${denial_crucible}" ] || [ ! -r "${denial_crucible}" ]; then
		details_failed "crucible.sh missing; expected ${denial_crucible}"
		return 0
	fi
	if ! new_path=$(sh "${denial_crucible}" new --kind "${DENIAL_KIND}" --label "${DENIAL_LABEL}" --effort "${dispatch_effort}" </dev/null); then
		details_failed 'crucible.sh new failed; its stderr is above'
		return 0
	fi
	case ${new_path} in
		/*.json) ;;
		*)
			details_failed 'crucible.sh new printed no file path; expected one absolute path ending in .json'
			return 0
			;;
	esac
	if ! temp_file=$(mktemp "${new_path%/*}/.${new_path##*/}.XXXXXX"); then
		temp_file=''
		details_failed "mktemp could not create a temp file beside ${new_path}"
		return 0
	fi
	if jq -n -L "${prune_dir}" --arg problems "${problems}" --arg kinds "${PROBLEM_KINDS}" --arg dispatch "${dispatch_path}" \
		--arg hint "$1" "include \"${PRUNE_NAME}\"; ${DENIAL_DETAILS_JQ}" </dev/null >"${temp_file}" &&
		mv -f -- "${temp_file}" "${new_path}"; then
		temp_file=''
		details_path=${new_path}
		return 0
	fi
	details_failed "could not write ${new_path}"
}

# Writes why the details file is missing to stderr; the deny goes on without it.
details_failed() {
	printf '%s: %s; the deny names no details file\n' "${PROG}" "$1" >&2
}

# A fault of this script, its install or the host: a deny.
fault() {
	deny "${REASON_PREFIX} $1"
}

# Prints a deny decision with reason $1 and exits 0; $2 is the fixed text
# printed when jq is missing (default: the stopped-before-deciding deny). A jq
# that fails to build the deny exits 2 instead, the reason on stderr.
deny() {
	decided=true
	print_deny "$1" "${2:-${INTERNAL_DENY}}"
	exit 0
}

# Prints a deny decision with reason $1, built with jq, or the fixed text $2
# when jq is missing. When jq is present but fails to build it, prints nothing
# to stdout, writes $1 to stderr as one line and exits 2: a PreToolUse exit 2
# blocks the call. stdin is /dev/null, since it may be closed.
print_deny() {
	if ! command -v jq >/dev/null 2>&1; then
		printf '%s\n' "$2"
		return 0
	fi
	if decision=$(jq -nc --arg reason "$1" </dev/null \
		'{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'); then
		printf '%s\n' "${decision}"
		return 0
	fi
	decided=true
	reason_line=$(join_lines "$1")
	printf '%s\n' "${reason_line}" >&2
	exit 2
}

emit() {
	decided=true
	printf '%s\n' "$1"
	exit 0
}

# Lets the call proceed untouched: no output, exit 0.
pass() {
	decided=true
	exit 0
}

# Removes the temp copies and any temp file, and denies a listed agent's
# dispatch when the hook dies before deciding.
# shellcheck disable=SC2329 # invoked by the EXIT trap
on_exit() {
	exit_status=$?
	[ -z "${snapshot_dir}" ] || rm -rf -- "${snapshot_dir}"
	[ -z "${temp_file}" ] || rm -f -- "${temp_file}"
	if [ "${decided}" = false ] && [ "${is_listed_agent}" = true ]; then
		printf '%s: stopped before deciding (exit %s); denying the dispatch\n' "${PROG}" "${exit_status}" >&2
		print_deny "${INTERNAL_REASON}" "${INTERNAL_DENY}"
		exit 0
	fi
}

main "$@"
