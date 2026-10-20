#!/usr/bin/env sh
# PreToolUse hook on Agent. A dispatch of a listed agent must carry, as its
# whole prompt, the one line "DISPATCH: <path>" naming a dispatch file that
# generate-agent-dispatch.sh wrote; the hook checks that file, the context file
# and the plugin files it names, and replaces the prompt with the agent's
# message built from them. Any problem denies the dispatch. Every other Agent
# call passes untouched. The decision is the only output, so a listed agent is
# denied on any unexpected exit (fail closed). --direct builds the same message
# for the main thread's own direct implementation and writes it to a file.
# Each checked file is read once, into a private temp copy that the checks and
# the message all read, so the checked bytes are the sent bytes. One window
# stays open, since POSIX sh can't test an open file: the path checks (not a
# symlink or resolving inside its plugin folder, regular, readable) run on the
# path just before the copy, so a path swapped in between, such as for a
# symlink or a FIFO, is copied unchecked or blocks until the hook times out.
# Swapping it takes write access to the plugin folder or the Crucible space.
# The message embeds only trusted text (the human's notes and request, the whys,
# paths and links written from them, and the text of plugins the human
# installed), so no crucible-context or crucible-plugin marker is stripped from
# it; repository text, web pages and seat output go in only as a path or link.
# shellcheck source-path=SCRIPTDIR
set -eu

readonly PROG='prepare-agent-prompt.sh'
readonly REASON_PREFIX='flow-agent-initialization:'
# The agents whose dispatches carry a DISPATCH line. The no-jq path needs them
# without jq, so they stay here; the hook faults unless they match the listed
# agents of the shared names module, the list to edit first.
readonly LISTED_AGENTS='code-developer code-reviewer'
readonly NAMES_MODULE='dispatch-names'
readonly DIRECT_PROMPT_LABEL='main-thread-prompt'
# Bounds the symlink chain followed for one file, so a link loop ends in a deny.
readonly MAX_LINK_HOPS=40
readonly DISPATCH_HINT='The expected prompt is exactly one line "DISPATCH: <absolute path>", the DISPATCH line generate-agent-dispatch.sh printed for this dispatch (flow-agent-initialization).'
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

# Prints "<name>\t<disable-model-invocation>" from a SKILL.md frontmatter, read
# the way list-plugins.sh reads it; exits 2 when there is no closed frontmatter.
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
END {
	if (!closed) exit 2
	printf "%s\t%s\n", name, model_invocation_disabled
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

# Builds the agent's message from the dispatch copy ($dispatch), the
# pretty-printed context copy ($context) and the plugin files, the item list
# build_message puts between the two halves: [plugin name, "skill"|"reference",
# file text] triples in the dispatch's order. $run_mode is hook or direct: only
# a dispatched agent replies with a REPORT line, so only its message asks for one.
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
def work($dispatch; $run_mode):
	"# Your work\n\n"
	+ "- **MODE:** \($dispatch.mode)\n"
	+ "- **TASK:** \($dispatch.task)\n"
	+ "- **REPO ROOT:** \($dispatch.repo_root | code)\n"
	+ "- **STARTING POINTS** (where to begin, not a limit): "
	+ (if ($dispatch.starting_points | length) == 0 then "none" | code else $dispatch.starting_points | map(code) | join(", ") end) + "\n"
	+ "- **REPORT:** \($dispatch.report | code)\n"
	+ "- **CONTEXT FILE:** \($dispatch.context.path | code)\n"
	+ (if $run_mode == "hook" then "- **RETURN:** \("REPORT: " + $dispatch.report | code) alone\n" else "" end)
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
	+ "# Before you start\n\n"
	+ "1. Read the notes in the context above.\n"
	+ "2. Read every file it lists, guided by its why.\n"
	+ "3. Follow every link it lists.\n\n"
	+ work($parsed; $run_mode)
'

main() {
	mode=hook
	direct_dispatch=''
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
	if [ "${mode}" = direct ]; then
		run_direct
	else
		run_hook
	fi
}

parse_args() {
	case ${1-} in
		'') return 0 ;;
		--help | -h)
			usage
			exit 0
			;;
		--direct)
			[ "$#" -eq 3 ] && [ "$2" = --dispatch ] && [ -n "$3" ] ||
				usage_error '--direct takes exactly --dispatch PATH; expected --direct --dispatch PATH'
			mode=direct
			direct_dispatch=$3
			;;
		*) usage_error "unknown option: $1; expected no arguments (hook input on stdin), --direct --dispatch PATH or --help" ;;
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
	# shellcheck disable=SC2310 # the function's status is its final jq's; a failure denies
	decision=$(printf '%s' "${hook_input}" | jq -c --rawfile message "${message_file}" \
		'{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "allow",
			updatedInput: (.tool_input + {prompt: $message})}}') ||
		fault "jq could not build the allow decision; the hook needs jq 1.6+ (--rawfile); the cause is on the hook's stderr."
	emit "${decision}"
}

run_direct() {
	command -v jq >/dev/null 2>&1 || fault 'jq is missing from PATH; the script needs jq 1.6+.'
	dispatch_path=${direct_dispatch}
	load_dependencies
	prepare_message "${DIRECT_AGENT}"
	write_direct_prompt
	decided=true
	printf 'PROMPT: %s\nREPORT: %s\n' "${prompt_path}" "${dispatch_report}"
}

usage() {
	# shellcheck disable=SC2310 # its status picks the fallback text; errexit adds nothing
	help_direct_agent=$(read_shared_name 'direct_agent | tojson' 2>/dev/null) && [ -n "${help_direct_agent}" ] ||
		help_direct_agent="the direct_agent of scripts/04-agent-dispatch/${NAMES_MODULE}.jq"
	cat <<EOF
Usage: sh ${PROG} [--help|-h] < PreToolUse-JSON
       sh ${PROG} --direct --dispatch PATH

A Claude Code PreToolUse hook (matcher Agent); it reads one hook input on stdin.
Acts only when tool_name is Agent and tool_input.subagent_type is one of:
${LISTED_AGENTS}. Every other call: no output, exit 0.

For a listed agent, tool_input.prompt must be exactly one line (one trailing
newline allowed)
  DISPATCH: <absolute path>
naming a dispatch file generate-agent-dispatch.sh wrote. Checks, every
problem named in one deny reason:
  - the dispatch path: the path checks of
    scripts/02-agent-context/agent-context-file-checks.sh (absolute, no
    control character, double quote or .. segment, no sensitive name), a
    regular file that is not a symlink, directly in a Crucible dispatches
    folder \${CRUCIBLE_HOME:-\$HOME/.crucible}/YYYY/MM/DD/dispatches/ (no
    folder of that path a symlink), valid JSON passing
    scripts/04-agent-dispatch/agent-dispatch-validator.jq
  - its agent: subagent_type (${help_direct_agent} with --direct)
  - its context file: the same path checks, a readable regular file that is
    not a symlink, at most the size cap of agent-context-file-checks.sh, its
    sha256 equal to the dispatch's context.sha256, valid JSON passing
    scripts/02-agent-context/agent-context-validator.jq
  - each plugin path: absolute, no .. segment, under
    \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/skills/ (compared as text), in the
    folder of the plugin it is listed under; that folder a plugin (named
    tech-* or standard-*, holding a SKILL.md whose frontmatter has name: <the
    folder name> and disable-model-invocation: true); the path its SKILL.md or
    a file under its references/, a readable regular file, resolving
    (symlinks followed) inside the real path of its plugin folder; a folder's
    paths one run, its SKILL.md first; no file holding an expansion token
    (\$ARGUMENTS, \$<digit>, \${CLAUDE_SKILL_DIR}, \${CLAUDE_PROJECT_DIR},
    \${CLAUDE_SESSION_ID}, \${CLAUDE_EFFORT}, !\`, \`\`\`!)
  - its report: the same path checks, an empty regular file, not a symlink,
    inside the Crucible space

The message (one per dispatch; no absolute path in a tag):
  # Your plugins
  <crucible-plugin name="<name>">           one block per plugin, in the
  (blank)                                   dispatch's order, blocks
  <SKILL.md without its frontmatter>        separated by one empty line;
  <each further file of the plugin>         files in a block too, each
  (blank)                                   given a final newline; "none"
  </crucible-plugin>                        for no plugin
  # Your context
  <crucible-context>, then a json fence holding the context file
  pretty-printed by jq ., then </crucible-context>
  # Before you start
  1. Read the notes ... 2. Read every file ... 3. Follow every link ...
  # Your work
  - **MODE:** <mode>
  - **TASK:** <task, verbatim>
  - **REPO ROOT:** \`<repo_root>\`
  - **STARTING POINTS** (where to begin, not a limit): \`<p1>\`, ... or \`none\`
  - **REPORT:** \`<report>\`
  - **CONTEXT FILE:** \`<the dispatch's context.path>\`
  - **RETURN:** \`REPORT: <report>\` alone     (not with --direct)
  (blank)
  A marked gap beats a papered-over one: report what you could not read, run or decide.
  Save your plan and progress as you go, in your scratchpad, so a cut-off
  run leaves them; the REPORT file is written once, as your report skill sets.
Headings and blocks are separated by one empty line; a backtick in a code
span prints as '.

Output (stdout, one JSON line):
  allow  hookSpecificOutput.updatedInput = tool_input with prompt replaced by
         the message; every other field unchanged
  deny   permissionDecisionReason =
         "${REASON_PREFIX} <KIND> <problem>: <path>[; <KIND> ...]. <hint>",
         KIND one of DISPATCH, AGENT, CONTEXT, PLUGIN, REPORT, each problem
         naming its expected value ("<problem>; expected <x>"); or a fault of this
         script, its install or the host (jq, awk, cat, dd, mktemp, mv,
         readlink, rm, wc, a sha256 tool, the shared checks and names), which
         names no KIND
  none   not a listed agent: no output.
A dispatch file written before a change to agent-dispatch-validator.jq's
contract is refused (DISPATCH); regenerate it at the flow's step 8.
A closed or unreadable stdin denies every call at once, listed agent or not,
since the agent can't be known; so does input jq can't read whose
subagent_type text names a listed agent or holds an escape.

--direct --dispatch PATH runs every check above for a dispatch of agent
${help_direct_agent}, then writes the message to a new file made by
  \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/skills/crucible/scripts/crucible.sh
  new --kind prompts --label ${DIRECT_PROMPT_LABEL} [--session <id>]
(the session of the dispatch's index line, when it has one), through a temp
file in its folder moved onto its path, and prints two lines
  PROMPT: <absolute path of the message file, ending .md>
  REPORT: <the dispatch's report path>

Exit codes: hook: 0 every decision (read stdout); 2 a usage error, or jq
present but failing to build a deny (the reason on stderr; Claude Code blocks
the call).
--direct: 0 the message written; 1 crucible.sh new or the write failed (the
file it made is removed); 2 usage error; 3 a check failed (one stderr line per
problem); 5 an install or host fault.
Each checked file is read once into a private temp folder, removed on exit;
the checks and the message all come from that copy.
Dependencies: POSIX sh, jq 1.6+ (--rawfile), awk, cat, dd, mktemp, mv,
readlink, rm, wc, and sha256sum or shasum (macOS: shasum -a 256);
scripts/02-agent-context/agent-context-file-checks.sh and
agent-context-validator.jq; scripts/04-agent-dispatch/agent-dispatch-validator.jq
and ${NAMES_MODULE}.jq (the direct agent, and the listed agents, which must
match the list above); crucible.sh for --direct.
Runtime: about 265 ms for a hook allow with 3 plugins, 245 ms for a deny,
250 ms for --direct; measured on macOS (average of 5 runs).
EOF
}

# Succeeds when stdin (fd 0) is open. On a closed stdin, $(cat) reads the
# command substitution's own pipe, which lands on the free fd 0, and blocks
# forever. stderr is closed rather than sent to /dev/null for the probe, since
# opening a file would take fd 0 and hide the closed stdin.
stdin_is_open() {
	true 2>&- 3<&0 && return 0
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
	make_snapshot_dir
	resolve_space_root
	check_dispatch_file
	read_dispatch_fields
	[ "${dispatch_agent}" = "${expected_agent}" ] ||
		add_problem AGENT "the dispatch is for \"${dispatch_agent}\"; expected \"${expected_agent}\"" "${dispatch_path}"
	check_context
	check_report
	resolve_skills_dir
	check_plugins
	[ -z "${problems}" ] || refuse_all
	build_message
}

# Checks the base tools, the shared checks and the shared names once jq is
# known present, or faults: any missing is an install or host fault, not the dispatch's.
load_dependencies() {
	check_base_tools
	load_shared_checks
	load_shared_names
}

# Faults unless every base tool the checks and the message use is on PATH.
check_base_tools() {
	for tool in awk cat dd mktemp mv readlink rm wc; do
		command -v "${tool}" >/dev/null 2>&1 ||
			fault "${tool} missing from PATH; expected it on PATH; install your base system's ${tool}"
	done
}

# Sources the shared path checks and finds the sha256 tool and the validators.
load_shared_checks() {
	shared_dir=$(script_dir)/..
	context_lib="${shared_dir}/02-agent-context/agent-context-file-checks.sh"
	context_validator="${shared_dir}/02-agent-context/agent-context-validator.jq"
	dispatch_validator="${shared_dir}/04-agent-dispatch/agent-dispatch-validator.jq"
	names_module="${shared_dir}/04-agent-dispatch/${NAMES_MODULE}.jq"
	for shared_file in "${context_lib}" "${context_validator}" "${dispatch_validator}" "${names_module}"; do
		[ -f "${shared_file}" ] && [ -r "${shared_file}" ] ||
			fault "the shared check ${shared_file} is missing or unreadable; ${PROG} needs it; the fault is in the ${REASON_PREFIX%:} install, not in the dispatch."
	done
	# shellcheck source=../02-agent-context/agent-context-file-checks.sh
	. "${context_lib}"
	# shellcheck disable=SC2310 # its status is the lookup result; errexit adds nothing
	find_context_digest_tool ||
		fault "neither sha256sum nor shasum is on PATH, so the context digest can't be checked; the fault is in the host, not in the dispatch; install coreutils (Linux) or use the system shasum (macOS)."
}

# Sets DIRECT_AGENT from the shared names module, and faults unless its listed
# agents are LISTED_AGENTS.
load_shared_names() {
	# shellcheck disable=SC2310 # its status is jq's; a failure faults
	DIRECT_AGENT=$(read_shared_name direct_agent) && [ -n "${DIRECT_AGENT}" ] ||
		fault "jq could not read direct_agent from ${names_module}; expected jq 1.6+ and the flow's shared names; reinstall flow-agent-initialization."
	readonly DIRECT_AGENT
	# shellcheck disable=SC2310 # its status is jq's; a failure faults
	module_listed_agents=$(read_shared_name 'listed_agents | join(" ")') ||
		fault "jq could not read listed_agents from ${names_module}; expected jq 1.6+ and the flow's shared names; reinstall flow-agent-initialization."
	[ "${module_listed_agents}" = "${LISTED_AGENTS}" ] ||
		fault "the listed agents differ from ${NAMES_MODULE}.jq (${PROG}: ${LISTED_AGENTS}; module: ${module_listed_agents}); expected the same list; reinstall flow-agent-initialization."
}

# Prints the value of jq expression $1 over the shared names module.
read_shared_name() {
	names_dir=$(script_dir)/../04-agent-dispatch
	jq -nr -L "${names_dir}" "include \"${NAMES_MODULE}\"; $1" </dev/null
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

# Sets space_root to the Crucible space, without trailing slashes.
resolve_space_root() {
	space_root="${CRUCIBLE_HOME:-${HOME:-}/.crucible}"
	while [ "${space_root}" != '/' ] && [ "${space_root%/}" != "${space_root}" ]; do
		space_root=${space_root%/}
	done
}

# Refuses unless dispatch_path is a regular file directly in a Crucible
# dispatches folder holding a valid dispatch; sets dispatch_copy.
check_dispatch_file() {
	path_problem=$(context_path_problem "${dispatch_path}")
	[ -z "${path_problem}" ] || refuse_now "DISPATCH ${path_problem}; expected ${context_path_expected}: ${dispatch_path}"
	# shellcheck disable=SC2310 # its status is the test result; errexit adds nothing
	in_dispatches_folder "${dispatch_path}" ||
		refuse_now "DISPATCH path is not a file in a Crucible dispatches folder; expected a file directly in ${space_root}/YYYY/MM/DD/dispatches/, no folder of it a symlink: ${dispatch_path}"
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
	refuse_now "DISPATCH file does not have the dispatch shape (${shape_problems}); expected the shape agent-dispatch-validator.jq checks; regenerate the dispatch at the flow's step 8: ${dispatch_path}"
}

# Succeeds when path $1 is <space_root>/YYYY/MM/DD/dispatches/<name>, none of
# those folders a symlink.
in_dispatches_folder() {
	case $1 in
		"${space_root}"/[0-9][0-9][0-9][0-9]/[0-9][0-9]/[0-9][0-9]/dispatches/?*) ;;
		*) return 1 ;;
	esac
	dispatch_name=${1#"${space_root}"/????/??/??/dispatches/}
	case ${dispatch_name} in
		*/*) return 1 ;;
		*) ;;
	esac
	dispatches_dir=${1%/*}
	day_dir=${dispatches_dir%/*}
	month_dir=${day_dir%/*}
	year_dir=${month_dir%/*}
	for layout_dir in "${space_root}" "${year_dir}" "${month_dir}" "${day_dir}" "${dispatches_dir}"; do
		[ -d "${layout_dir}" ] && [ ! -L "${layout_dir}" ] || return 1
	done
}

# Sets dispatch_agent, dispatch_context, dispatch_context_sha256, dispatch_report
# and plugin_entries (one "<name>\t<path>" line per plugin file, in order) from
# the checked dispatch copy.
read_dispatch_fields() {
	dispatch_fields=$(jq -r '.agent, .context.path, .context.sha256, .report' "${dispatch_copy}" </dev/null) ||
		fault "jq could not read the dispatch copy; the hook needs jq 1.6+; the cause is on stderr."
	{
		IFS= read -r dispatch_agent
		IFS= read -r dispatch_context
		IFS= read -r dispatch_context_sha256
		IFS= read -r dispatch_report
	} <<EOF
${dispatch_fields}
EOF
	plugin_entries=$(jq -r '.plugins[] | (.name | gsub("[[:cntrl:]]"; "?")) as $name | .paths[] | "\($name)\t\(.)"' "${dispatch_copy}" </dev/null) ||
		fault "jq could not read the dispatch copy; the hook needs jq 1.6+; the cause is on stderr."
}

# Adds a problem for the first failing check of the context file, and sets
# context_pretty to its pretty-printed copy when every check passes.
check_context() {
	context_path=${dispatch_context}
	path_problem=$(context_path_problem "${context_path}")
	if [ -n "${path_problem}" ]; then
		add_problem CONTEXT "${path_problem}; expected ${context_path_expected}" "${context_path}"
		return 0
	fi
	if [ -L "${context_path}" ]; then
		add_problem CONTEXT 'file is a symlink; expected a regular file' "${context_path}"
		return 0
	fi
	if [ ! -f "${context_path}" ] || [ ! -r "${context_path}" ]; then
		add_problem CONTEXT 'file is missing, unreadable or not a regular file; expected a readable regular file' "${context_path}"
		return 0
	fi
	# One byte over the cap is copied, so an oversized file is never read whole.
	context_copy="${snapshot_dir}/context"
	if ! dd if="${context_path}" of="${context_copy}" bs="$((context_max_bytes + 1))" count=1 2>/dev/null; then
		add_problem CONTEXT 'file is missing, unreadable or not a regular file; expected a readable regular file' "${context_path}"
		return 0
	fi
	context_size=$(wc -c <"${context_copy}") ||
		fault "wc could not count the bytes of the temp copy; the fault is in the host, not in the dispatch; the cause is on stderr."
	context_size=${context_size##* }
	case ${context_size} in
		'' | *[!0-9]*) fault "wc printed no byte count for the temp copy; the fault is in the host's wc, not in the dispatch." ;;
		*) ;;
	esac
	if [ "${context_size}" -gt "${context_max_bytes}" ]; then
		add_problem CONTEXT "file is larger than ${context_max_bytes} bytes; expected at most ${context_max_bytes} bytes" "${context_path}"
		return 0
	fi
	# shellcheck disable=SC2310 # its status is the tool's; a failure faults
	compute_context_digest "${context_copy}" ||
		fault "${context_digest_tool} could not hash the temp copy; the fault is in the host, not in the dispatch; the cause is on stderr."
	if [ "${context_digest}" != "${dispatch_context_sha256}" ]; then
		add_problem CONTEXT "file changed since the dispatch was written (sha256 $(printf '%.12s' "${dispatch_context_sha256}") written, $(printf '%.12s' "${context_digest}") now); expected the sha256 the dispatch holds; run the flow's step 3 again and re-plan (step 10)" "${context_path}"
		return 0
	fi
	if ! jq empty "${context_copy}" </dev/null >/dev/null 2>&1; then
		add_problem CONTEXT 'file is not valid JSON; expected one JSON object' "${context_path}"
		return 0
	fi
	context_report=$(jq -rs --arg context_path "${context_path}" -f "${context_validator}" "${context_copy}" </dev/null) ||
		fault "jq could not run the context check ${context_validator}; the hook needs jq 1.6+; the cause is on stderr."
	if [ -n "${context_report}" ]; then
		context_problems=$(join_lines "${context_report}")
		add_problem CONTEXT "file does not have the context shape (${context_problems}); expected the shape agent-context-validator.jq checks; regenerate the context at the flow's step 3" "${context_path}"
		return 0
	fi
	context_pretty="${snapshot_dir}/context.pretty"
	jq . "${context_copy}" </dev/null >"${context_pretty}" ||
		fault "jq could not print the context copy; the hook needs jq 1.6+; the cause is on stderr."
}

# Adds a problem when the report path fails the context path checks, or is not
# an empty regular file inside the Crucible space.
check_report() {
	path_problem=$(context_path_problem "${dispatch_report}")
	if [ -n "${path_problem}" ]; then
		add_problem REPORT "${path_problem}; expected ${context_path_expected}" "${dispatch_report}"
		return 0
	fi
	case ${dispatch_report} in
		"${space_root}"/*) ;;
		*)
			add_problem REPORT "file is not inside the Crucible space; expected a path under ${space_root}/" "${dispatch_report}"
			return 0
			;;
	esac
	if [ -L "${dispatch_report}" ] || [ ! -f "${dispatch_report}" ]; then
		add_problem REPORT 'file is missing, a symlink or not a regular file; expected the empty regular file made for this dispatch' "${dispatch_report}"
	elif [ -s "${dispatch_report}" ]; then
		add_problem REPORT 'file is not empty; expected the empty report file made for this dispatch' "${dispatch_report}"
	fi
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
		tech-?* | standard-?*) ;;
		*) path_problem="path is not in a plugin folder; expected a path in a tech-* or standard-* folder of ${skills_dir}/"; return 0 ;;
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
# SKILL.md frontmatter in file $2.
plugin_test() {
	not_plugin_reason=''
	if ! frontmatter=$(awk "${PLUGIN_FRONTMATTER_AWK}" "$2"); then
		not_plugin_reason="$1/SKILL.md has no frontmatter closed by a --- line; expected a frontmatter opened and closed by --- lines"
		return 0
	fi
	frontmatter_name=${frontmatter%%"${TAB}"*}
	frontmatter_disabled=${frontmatter#*"${TAB}"}
	[ "${frontmatter_name}" = "$1" ] ||
		not_plugin_reason="$1/SKILL.md has name: '${frontmatter_name}'; expected name: $1"
	[ "${frontmatter_disabled}" = true ] ||
		not_plugin_reason="${not_plugin_reason}${not_plugin_reason:+, }$1/SKILL.md has disable-model-invocation: '${frontmatter_disabled}'; expected disable-model-invocation: true"
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
	jq -nj --rawfile dispatch "${dispatch_copy}" --rawfile context "${context_pretty}" --arg run_mode "${mode}" \
		"$@" "${MESSAGE_JQ_HEAD} [${items}] ${MESSAGE_JQ_TAIL}" </dev/null >"${message_file}" ||
		fault "jq could not build the message; the hook needs jq 1.6+ (--rawfile); the cause is on stderr."
}

# Writes the message to a new Crucible prompts file (Markdown, .md); sets
# prompt_path. On a failure after crucible.sh made the file, removes it and exits 1.
write_direct_prompt() {
	crucible_script="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/skills/crucible/scripts/crucible.sh"
	[ -f "${crucible_script}" ] && [ -r "${crucible_script}" ] ||
		fault "crucible.sh missing; expected ${crucible_script}; install the crucible skill."
	dispatch_session=$(dispatch_index_session)
	if [ -n "${dispatch_session}" ]; then
		prompt_path=$(sh "${crucible_script}" new --kind prompts --label "${DIRECT_PROMPT_LABEL}" --session "${dispatch_session}" </dev/null) ||
			write_failed 'crucible.sh new failed; its stderr is above'
	else
		prompt_path=$(sh "${crucible_script}" new --kind prompts --label "${DIRECT_PROMPT_LABEL}" </dev/null) ||
			write_failed 'crucible.sh new failed; its stderr is above'
	fi
	case ${prompt_path} in
		/*.md) ;;
		*) write_failed 'crucible.sh new printed no file path' ;;
	esac
	temp_file=$(mktemp "${prompt_path%/*}/.${prompt_path##*/}.XXXXXX") || write_failed "mktemp could not create a temp file beside ${prompt_path}"
	cat -- "${message_file}" >"${temp_file}" || write_failed "could not write the temp file ${temp_file}"
	mv -f "${temp_file}" "${prompt_path}" || write_failed "mv could not move the temp file onto ${prompt_path}"
	temp_file=''
}

# Prints the session of the dispatch's index line in its day's index.jsonl, or nothing.
dispatch_index_session() {
	day_index="${dispatch_path%/dispatches/*}/index.jsonl"
	[ -f "${day_index}" ] && [ ! -L "${day_index}" ] || return 0
	dispatch_id=$(printf '%.20s' "${dispatch_path##*/}")
	jq -rRn --arg id "${dispatch_id}" \
		'first(inputs | fromjson? | select(type == "object" and .id == $id and .kind == "dispatches") | .session | strings) // empty' \
		"${day_index}" 2>/dev/null || true
}

# Exits 1 with $1, removing the file crucible.sh made for this run.
write_failed() {
	case ${prompt_path:-} in
		/*.md) rm -f "${prompt_path}" && printf '%s: removed %s, made by this run\n' "${PROG}" "${prompt_path}" >&2 ;;
		*) ;;
	esac
	printf '%s: %s\n' "${PROG}" "$1" >&2
	decided=true
	exit 1
}

# Refuses with problem $1 alone, when the later checks can't run without it passing.
refuse_now() {
	problems="$1${NL}"
	refuse_all
}

# Refuses with every problem: a deny naming them all (hook), or one stderr line
# each and exit 3 (--direct).
refuse_all() {
	if [ "${mode}" = direct ]; then
		while IFS= read -r problem_line; do
			[ -z "${problem_line}" ] || printf '%s: %s\n' "${PROG}" "${problem_line}" >&2
		done <<EOF
${problems}
EOF
		decided=true
		exit 3
	fi
	joined_problems=$(join_lines "${problems%"${NL}"}")
	deny "${REASON_PREFIX} ${joined_problems}. ${DISPATCH_HINT}"
}

# A fault of this script, its install or the host: a deny (hook), or stderr and exit 5 (--direct).
fault() {
	if [ "${mode}" = direct ]; then
		printf '%s: %s\n' "${PROG}" "$1" >&2
		decided=true
		exit 5
	fi
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
