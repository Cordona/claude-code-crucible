#!/usr/bin/env sh
# PreToolUse hook on Agent. A dispatch of a listed agent must carry, as its
# whole prompt, the one line "DISPATCH: <path>" naming a dispatch file that
# generate-agent-dispatch.sh wrote; the hook checks that file, the context file
# and the plugin files it names, and replaces the prompt with the agent's
# message built from them, the seat the dispatch's seat field names and
# procedure-context's context-handling template, sent word for word. Any
# problem denies the dispatch. Every other Agent call passes untouched. The
# decision is the only output, so a listed agent is denied on any unexpected
# exit (fail closed).
# A listed agent runs in the background only: procedure-git-worktree's seat bind hook
# links it to its seat from PostToolUse, which for a foreground agent comes
# only after it has finished. Once every check passes, the hook writes
# <effort>/pending/<tool_use_id> holding the dispatch path, the link the bind
# hook reads, since both events of one Agent call carry that id.
# Each checked file is read once, into a private temp copy that the checks and
# the message all read, so the checked bytes are the sent bytes.
# Known gap: the path checks (not a symlink or resolving inside its plugin
# folder, regular, readable) run on the path just before the copy, since POSIX
# sh can't test an open file, so a path swapped in between (such as for a
# symlink or a FIFO) is copied unchecked, or blocks until the hook times out.
# Swapping it takes write access to the plugin folder or the Crucible space.
# No crucible-context or crucible-plugin marker is stripped from the message,
# because everything it embeds is trusted: the human's request, the notes and
# whys, as procedure-context sets what notes and whys may hold, and the template
# and plugins the human installed.
# shellcheck source-path=SCRIPTDIR source-path=SCRIPTDIR/../../../../../../../../framework/core/engine/crucible/scripts/lib source-path=SCRIPTDIR/../../../../../../../../framework/core/main-thread/procedures/procedure-context/scripts
set -eu

readonly PROG='prepare-agent-prompt.sh'
readonly REASON_PREFIX='flow-code-agent-dispatch:'
# The agents whose dispatches carry a DISPATCH line. The no-jq path needs them
# without jq, so they stay here; the hook faults unless they match the listed
# agents of the shared names module, the list to edit first.
readonly LISTED_AGENTS='code-developer code-reviewer'
readonly NAMES_MODULE='dispatch-names'
readonly RENDER_LIB='human-view'
readonly CRUCIBLE_SKILL='crucible'
readonly VIEW_NAME='view'
readonly PRUNE_NAME='prune'
# The seat list's reader and the seat's iteration reader, relative to the
# skills folder.
readonly SEATS_SCRIPT='procedure-git-worktree/scripts/seats/seats.sh'
readonly ITERATION_SCRIPT='procedure-git-worktree/scripts/seats/iteration.sh'
# The skill that owns the context: its validator, its path checks and the file
# sent under "# Handling your context" (TEMPLATE_FILE, relative to its folder).
readonly CONTEXT_PROCEDURE='procedure-context'
readonly TEMPLATE_FILE='references/agent-context-rules.md'
# Bounds the symlink chain followed for one file, so a link loop ends in a deny.
readonly MAX_LINK_HOPS=40
readonly DISPATCH_HINT='The expected prompt is exactly one line "DISPATCH: <absolute path>", the DISPATCH line generate-agent-dispatch.sh printed for this dispatch (flow-code-agent-dispatch).'
# The cache kind and label of the file a deny's Data · Denial line names.
readonly DENIAL_KIND='cache/denials'
readonly DENIAL_LABEL='denial'
# A deny shows this many problems at most, each cut to this many characters,
# so the reason stays a short view; the details file holds them all.
readonly DENIAL_MAX_SHOWN=8
readonly DENIAL_LINE_CAP=200
# The words that start a problem; the flow's step 10 routes on them.
# CONTEXT-STALE is a context version no longer its effort's latest, every
# other context problem CONTEXT; BACKGROUND is a dispatch not run in the
# background; SEAT is a seat missing, unreadable or not open; SKILL is a
# skill the agent's frontmatter preloads that is not installed, which Claude
# Code would drop without a word.
readonly PROBLEM_KINDS='DISPATCH AGENT CONTEXT CONTEXT-STALE PLUGIN SEAT BACKGROUND SKILL'
readonly BACKGROUND_PROBLEM='BACKGROUND the dispatch runs in the foreground; expected run_in_background: true; dispatch it again in the background'
# The deny when jq is missing, printed as is: a fixed text, built without jq.
readonly NO_JQ_DENY='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"flow-code-agent-dispatch: jq is missing from PATH; the hook needs jq 1.6+."}}'
# The reasons of the deny when stdin can't be read and of the deny when the hook
# stops before deciding. Both denies are built with jq; the fixed texts below
# are printed instead only when jq is missing. A jq that is present but fails
# to build a deny makes the hook print nothing, write the reason to stderr and
# exit 2, which blocks the call, so a listed agent never passes with no output.
# Neither reason holds a character JSON escapes, so each fixed text is the
# reason between the deny's fixed ends.
readonly STDIN_REASON="${REASON_PREFIX} the hook input on stdin could not be read; the hook expects the PreToolUse hook JSON on stdin; the cause is on the hook's stderr."
readonly INTERNAL_REASON="${REASON_PREFIX} the hook stopped before deciding; the cause is on the hook's stderr."
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
# Prints each name of an agent file's frontmatter "skills:" block list, one per
# line: the "  - <name>" lines after a bare "skills:" key, up to the next key or
# the closing --- line, each name unquoted.
# The program is single-quoted on purpose: its $0 is awk's, not the shell's.
# shellcheck disable=SC2016
readonly AGENT_SKILLS_AWK='
{ sub(/\r$/, "") }
NR == 1 { if ($0 != "---") exit; next }
$0 == "---" { exit }
/^[^ \t#-]/ { in_skills = ($0 ~ /^skills:[ \t]*(#.*)?$/); next }
in_skills && /^[ \t]*-[ \t]/ {
	name = $0
	sub(/^[ \t]*-[ \t]+/, "", name)
	quote = substr(name, 1, 1)
	if (quote == "\"" || quote == "\047") {
		name = substr(name, 2)
		sub(quote ".*$", "", name)
	} else {
		sub(/[ \t]+#.*$/, "", name)
		sub(/[ \t]+$/, "", name)
	}
	if (name != "") print name
}
'

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

# Prints one "PLUGIN plugin folder <name>: <problem>: <file>" line per SKILL.md
# without a closed frontmatter. It reads the temp copies; the environment's
# PREPARE_PROMPT_SCAN_PATHS and PREPARE_PROMPT_SCAN_NAMES hold each copy's
# checked path and plugin name, one per line in operand order, and every line
# names that path. A "---" line may end in a CR,
# as in the frontmatter read and the message.
# The program is single-quoted on purpose: its $0 is awk's, not the shell's.
# shellcheck disable=SC2016
readonly SCAN_AWK='
function is_fence(line) { sub(/\r$/, "", line); return line == "---" }
function add(problem, file) { printf "PLUGIN plugin folder %s: %s: %s\n", current_name, problem, file }
function finish_file() {
	if (current == "") return
	if (is_skill && !closed) add("SKILL.md has no frontmatter closed by a --- line; expected a frontmatter opened and closed by --- lines", current)
}
BEGIN {
	split(ENVIRON["PREPARE_PROMPT_SCAN_PATHS"], checked_paths, "\n")
	split(ENVIRON["PREPARE_PROMPT_SCAN_NAMES"], checked_names, "\n")
	for (i = 1; i < ARGC; i++) { checked_path[ARGV[i]] = checked_paths[i]; checked_name[ARGV[i]] = checked_names[i] }
}
FNR == 1 {
	finish_file()
	current = checked_path[FILENAME]
	current_name = checked_name[FILENAME]
	is_skill = (current ~ /\/SKILL\.md$/)
	closed = 0
	opened = is_fence($0)
}
is_skill && FNR > 1 && opened && !closed && is_fence($0) { closed = 1 }
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
# pretty-printed context copy ($context), the template copy ($template), the
# seat's $mode ("" for none) and $worktree, the $report path and the plugin
# files, the item list build_message puts between the two halves:
# [plugin name, "skill"|"reference", file text] triples in the dispatch's
# order.
# The programs are single-quoted on purpose: their $ signs are jq's.
# shellcheck disable=SC2016
readonly MESSAGE_JQ_HEAD='
# A "---" line may end in a CR, as in the frontmatter read and the plugin scan.
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
# A repo-relative entry point joined to the worktree, so it prints whole and
# absolute; "." and "./" are the worktree itself.
def in_tree($root): ($root | rtrimstr("/")) as $base
	| ltrimstr("./") | if . == "" or . == "." then $base else "\($base)/\(.)" end;
def work($dispatch):
	"# Your work\n\n"
	+ (if $mode == "" then "" else "- **MODE:** \($mode)\n" end)
	+ "- **TASK:** \($dispatch.task)\n"
	+ "- **WORKTREE:** \($worktree | code)\n"
	+ "- **ENTRY POINTS** (where to begin, not a limit): "
	+ (($dispatch.entry_points // []) | if length == 0 then "none" | code else map(in_tree($worktree) | code) | join(", ") end) + "\n"
	+ "- **REPORT:** \($report | code)\n"
	+ "- **CONTEXT FILE:** \($dispatch.context.path | code)\n"
	+ "\nA marked gap beats a papered-over one: report what you could not read, run or decide.\n"
	+ "Save your plan and progress as you go, in your scratchpad, so a cut-off run leaves them; write the REPORT file last, as your report skill sets, and fix it when your stop is blocked.\n";
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
	call_fields=$(read_call_fields) ||
		fault "jq could not read tool_use_id and tool_input.run_in_background; the hook needs jq 1.6+; the cause is on the hook's stderr."
	run_in_background=${call_fields%%"${NL}"*}
	tool_use_id=${call_fields#*"${NL}"}
	[ "${run_in_background}" = true ] || refuse_now "${BACKGROUND_PROBLEM}"
	case ${tool_use_id} in
		'' | *[!A-Za-z0-9_-]*) fault "the call's tool_use_id is empty or holds a character other than letters, digits, _ and -; the fault is in the host, not in the dispatch." ;;
		*) ;;
	esac
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
	write_pending_link
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
A listed agent's call is allowed only when all of these hold:
  it runs in the background (tool_input.run_in_background not false; an
  interactive session sends no such field and always runs in the background);
  its prompt is exactly one line "DISPATCH: <absolute path>" naming a dispatch
  file generate-agent-dispatch.sh wrote for that agent;
  the dispatch, its context file (its effort's latest version, matching
  context.sha256), its plugin files (each SKILL.md frontmatter valid as
  list-plugins.sh --help sets, the description aside) and its seat (the seat
  in <effort>/seats.json, read with seats.sh get: open, with a worktree) pass
  every check.
Known gap: a path swapped after its check, by someone who can write to the
  plugin folder or the Crucible space, is copied unchecked, or hangs until
  the hook times out.

stdout (one JSON line):
  allow  hookSpecificOutput.updatedInput: tool_input, prompt replaced by
         the message
  deny   permissionDecisionReason "${REASON_PREFIX} <text>"; a reason with no
         KIND is a hook, install or host fault. A failed check: "<prefix> **Blocked · the
         dispatch was denied: <N> problem(s)**", "**Problem:** <p>" or
         "**Problems**" and numbered <p> lines (${DENIAL_MAX_SHOWN} at most, every KIND shown,
         cut to ${DENIAL_LINE_CAP} characters), "+<M> more" past ${DENIAL_MAX_SHOWN}, then, when the effort is known,
         "**Data · Denial:** <path>" (absolute, all as JSON). <p>:
         "<KIND> <problem>; expected <x>", most ending ": <path>"; KIND:
         DISPATCH, AGENT, CONTEXT, CONTEXT-STALE (stale context),
         PLUGIN, SEAT, BACKGROUND (dispatched in the foreground),
         SKILL (a skill the agent file's skills: preloads, not installed)
The message, built from the checked bytes: # Your plugins, # Your context,
  # Handling your context, # Your work (MODE, from the seat, left out when it
  has none; TASK; WORKTREE; ENTRY POINTS, joined to the worktree; REPORT,
  iteration.sh's REPORT path for the seat; CONTEXT FILE), then two closing
  lines. # Your plugins: one block per plugin, in the order language,
  frameworks, standards, procedures, as the dispatch lists them; none when no
  plugin. ENTRY POINTS: none when none. Paths are absolute, in code spans.

Leaves only (a SIGKILL aside): once every check passes,
<effort>/pending/<tool_use_id>, holding the dispatch path and a newline, written
atomically, for procedure-git-worktree's seat bind hook; on a deny, the Denial file.
The repository and seats.json are only read.

Exit codes:
  0  a decision, or none; read stdout
  2  usage error, or a deny that could not be built, so Claude Code blocks
     the call; show stderr and stop
  129, 130, 143  stopped by HUP, INT or TERM before a listed agent was
     known; no output

Dependencies (skills in \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/skills/):
  POSIX sh; jq 1.6+ (--rawfile) (macOS: brew install jq; Linux: the distro's jq)
  awk, cat, date, dd, grep, mkdir, mktemp, mv, readlink, rm, tr, wc, and
    sha256sum or shasum (base system)
  procedure-git-worktree: scripts/seats/seats.sh, scripts/seats/iteration.sh
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
		fault "the hook input is not valid JSON; the hook expects one PreToolUse object on stdin."
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

# Prints whether the call runs in the background, then its tool_use_id. Only an
# explicit false (or "false") is foreground: an interactive session's Agent tool
# has no run_in_background parameter, drops the field before this hook, and
# always runs its agents in the background.
read_call_fields() {
	printf '%s' "${hook_input}" | jq -r '(.tool_input.run_in_background | . != false and . != "false"), (.tool_use_id // "" | strings | gsub("\n"; " "))'
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
	resolve_skills_dir
	check_preloaded_skills "${expected_agent}"
	check_seat
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
	for tool in awk cat date dd grep mkdir mktemp mv readlink rm tr wc; do
		command -v "${tool}" >/dev/null 2>&1 ||
			fault "${tool} missing from PATH; expected it on PATH; the fault is in the host, not in the dispatch."
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
	# shellcheck source=../../../../../../../../framework/core/main-thread/procedures/procedure-context/scripts/agent-context-file-checks.sh
	. "${context_lib}"
	# shellcheck disable=SC2310 # its status says whether the checks loaded; the problem is read here
	context_load_checks "${context_skill_dir%/*}" ||
		fault "${context_load_problem}; ${PROG} needs it; the fault is in the install or the host, not in the dispatch."
}

# Faults unless the shared names module's listed agents are LISTED_AGENTS.
load_shared_names() {
	# shellcheck disable=SC2310 # its status is jq's; a failure faults
	module_listed_agents=$(read_shared_name 'listed_agents | join(" ")') ||
		fault "jq could not read listed_agents from ${names_module}; expected jq 1.6+ and the flow's shared names; the fault is in the flow-code-agent-dispatch install, not in the dispatch."
	[ "${module_listed_agents}" = "${LISTED_AGENTS}" ] ||
		fault "the listed agents differ from ${NAMES_MODULE}.jq (${PROG}: ${LISTED_AGENTS}; module: ${module_listed_agents}); expected the same list; the fault is in the flow-code-agent-dispatch install, not in the dispatch."
}

# Prints the value of jq expression $1 over the shared names module.
read_shared_name() {
	names_dir=$(script_dir)/../agent-dispatch
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
# dispatch_seat and plugin_entries
# (one "<name>\t<path>" line per plugin file: the language, the frameworks,
# the standards, then the procedures, each kind in the dispatch's order) from
# the checked dispatch copy. The validator holds each path to one line.
read_dispatch_fields() {
	dispatch_fields=$(jq -r '.agent, .context.path, .context.sha256, .seat' "${dispatch_copy}" </dev/null) ||
		fault "jq could not read the dispatch copy; the hook needs jq 1.6+; the cause is on stderr."
	{
		IFS= read -r dispatch_agent
		IFS= read -r dispatch_context
		IFS= read -r dispatch_context_sha256
		IFS= read -r dispatch_seat
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
		add_stale_problem
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

# Adds a SKILL problem for each skill agent $1's file preloads (its frontmatter
# skills: list) with no <name>/SKILL.md in the user or the project skills
# folder, since Claude Code drops such a skill without a word. The agent file
# is the project's, else the user's, as Claude Code picks it; none found or
# none readable: nothing to check.
check_preloaded_skills() {
	project_dir=$(printf '%s' "${hook_input}" | jq -r '.cwd // "" | strings') ||
		fault "jq could not read cwd; the hook needs jq 1.6+; the cause is on the hook's stderr."
	case ${project_dir} in
		/*) project_claude_dir="${project_dir%/}/.claude" ;;
		*) project_claude_dir='' ;;
	esac
	agent_file=''
	for agent_dir in ${project_claude_dir:+"${project_claude_dir}/agents"} "${skills_dir%/*}/agents"; do
		[ -f "${agent_dir}/$1.md" ] && [ -r "${agent_dir}/$1.md" ] || continue
		agent_file="${agent_dir}/$1.md"
		break
	done
	[ -n "${agent_file}" ] || return 0
	preloaded_skills=$(awk "${AGENT_SKILLS_AWK}" "${agent_file}") ||
		fault "awk could not read the skills: list of ${agent_file}; the hook expects a readable text file; the cause is on stderr."
	while IFS= read -r skill_name; do
		[ -n "${skill_name}" ] || continue
		# shellcheck disable=SC2310 # a pure test; its status is the answer
		is_skill_installed "${skill_name}" ||
			add_problem SKILL "the agent's preloaded skill ${skill_name} is not installed; expected its SKILL.md in the user or the project skills folder; install it, then dispatch again" "${skills_dir}/${skill_name}/SKILL.md"
	done <<EOF
${preloaded_skills}
EOF
}

# True when skill $1 has a SKILL.md in the user or the project skills folder; a
# name that is not one folder name is never installed.
is_skill_installed() {
	case $1 in
		.* | */*) return 1 ;;
		*) ;;
	esac
	[ -f "${skills_dir}/$1/SKILL.md" ] && return 0
	[ -n "${project_claude_dir}" ] && [ -f "${project_claude_dir}/skills/$1/SKILL.md" ]
}

# Adds a SEAT problem unless the dispatch's seat field names an open seat with a
# worktree in its effort's seats.json, read with seats.sh get; sets
# seat_mode and seat_worktree from it, and report_path with read_report_path.
check_seat() {
	seats_script="${skills_dir}/${SEATS_SCRIPT}"
	[ -f "${seats_script}" ] && [ -r "${seats_script}" ] ||
		fault "the seat reader ${seats_script} is missing or unreadable; ${PROG} needs it; the fault is in the procedure-git-worktree install, not in the dispatch."
	seats_file="${dispatch_effort}/seats.json"
	if [ ! -f "${seats_file}" ]; then
		add_problem SEAT "the effort has no seats.json; expected the seat list procedure-git-worktree's seats.sh writes" "${seats_file}"
		return 0
	fi
	# On exit 0 seats.sh prints only the seat; otherwise only its stderr lines.
	seat_status=0
	seat_out=$(sh "${seats_script}" get --seats "${seats_file}" --seat "${dispatch_seat}" </dev/null 2>&1) || seat_status=$?
	seat_line=$(printf '%s' "${seat_out%%"${NL}"*}" | tr '[:cntrl:]' '?')
	case ${seat_status} in
		0) ;;
		6)
			add_problem SEAT "seat ${dispatch_seat} is not in seats.json; expected a seat procedure-git-worktree's seats.sh choose or add made" "${seats_file}"
			return 0
			;;
		3)
			add_problem SEAT "seats.json can't be read (${seat_line}); expected the effort's seat list as seats.sh --help sets" "${seats_file}"
			return 0
			;;
		*) fault "seats.sh get exited ${seat_status} (${seat_line}); the fault is in the procedure-git-worktree install or the host, not in the dispatch." ;;
	esac
	seat_fields=$(printf '%s\n' "${seat_out}" | jq -r '.status // "", .mode // "", .worktree // ""') ||
		fault "jq could not read the seat seats.sh get printed; the hook needs jq 1.6+; the cause is on stderr."
	{
		IFS= read -r seat_state
		IFS= read -r seat_mode
		IFS= read -r seat_worktree
	} <<EOF
${seat_fields}
EOF
	if [ "${seat_state}" != open ]; then
		add_problem SEAT "seat ${dispatch_seat} is ${seat_state}; expected an open seat" "${seats_file}"
		return 0
	fi
	case ${seat_worktree} in
		'') add_problem SEAT "seat ${dispatch_seat} has no worktree; expected a developer or tester seat" "${seats_file}" ;;
		*'`'*) add_problem SEAT "seat ${dispatch_seat}'s worktree holds a backtick; expected a path without one, so the agent's message prints it unchanged" "${seats_file}" ;;
		*) read_report_path ;;
	esac
}

# Sets report_path from iteration.sh's REPORT line for the seat. A seat whose
# mode, worktree or base does not fit (exit 3) is a SEAT problem; any other
# failure is a fault.
read_report_path() {
	iteration_script="${skills_dir}/${ITERATION_SCRIPT}"
	[ -f "${iteration_script}" ] && [ -r "${iteration_script}" ] ||
		fault "the iteration reader ${iteration_script} is missing or unreadable; ${PROG} needs it; the fault is in the procedure-git-worktree install, not in the dispatch."
	iteration_status=0
	iteration_out=$(sh "${iteration_script}" --seats "${seats_file}" --seat "${dispatch_seat}" </dev/null 2>&1) || iteration_status=$?
	iteration_line=$(printf '%s' "${iteration_out##*"${NL}"}" | tr '[:cntrl:]' '?')
	case ${iteration_status} in
		0) ;;
		3)
			add_problem SEAT "seat ${dispatch_seat}'s iteration can't be counted (${iteration_line}); expected a developer or tester seat whose base is a commit in its worktree" "${seats_file}"
			return 0
			;;
		*) fault "iteration.sh exited ${iteration_status} (${iteration_line}); the fault is in the procedure-git-worktree install or the host, not in the dispatch." ;;
	esac
	report_path=''
	while IFS= read -r iteration_entry; do
		case ${iteration_entry} in
			'REPORT: '*) report_path=${iteration_entry#REPORT: } ;;
			*) ;;
		esac
	done <<EOF
${iteration_out}
EOF
	case ${report_path} in
		/*) ;;
		*) fault "iteration.sh printed no absolute REPORT line; the fault is in the procedure-git-worktree install, not in the dispatch." ;;
	esac
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
			path_problem="plugin folder ${plugin_name} holds the path, but it is listed under plugin ${listed_name}; expected it listed under plugin ${plugin_name}"
		[ -n "${path_problem}" ] || check_run_order
		if [ -n "${path_problem}" ]; then
			add_plugin_problem "${plugin_name:-${listed_name}}" "${path_problem}" "${path}"
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
	path_problem='' plugin_name=''
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
		*)
			plugin_name=''
			path_problem="path is not in a plugin folder; expected a path in a language-*, framework-*, standard-* or procedure-* folder of ${skills_dir}/"
			return 0
			;;
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
		path_problem="plugin folder ${plugin_name} has a first path that is not ${plugin_name}/SKILL.md; expected its SKILL.md before its references"
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

# Adds a PLUGIN problem whose text starts "plugin folder <name>", $1 the
# plugin's install name, so the name survives the line cap; $2 the problem,
# kept as it is when it already starts so; $3 the path.
add_plugin_problem() {
	case $2 in
		"plugin folder $1 "*) add_problem PLUGIN "$2" "$3" ;;
		*) add_problem PLUGIN "plugin folder $1: $2" "$3" ;;
	esac
}

# Adds the CONTEXT-STALE problem with the shared read check's text, its path
# the effort's latest version (context_read_latest), or the dispatch's
# context file when the check gave none.
add_stale_problem() {
	add_problem CONTEXT-STALE "${context_read_text}" "${context_read_latest:-${context_path}}"
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
			add_plugin_problem "${name}" 'file is missing, unreadable or not a regular file; expected a readable regular file' "${path}"
			continue
		}
		if [ "${kind}" = skill ]; then
			plugin_test "${name}" "${copy}"
			[ -z "${not_plugin_reason}" ] || {
				add_plugin_problem "${name}" "not a plugin (${not_plugin_reason})" "${path}"
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

# Prints the frontmatter problems of the copied files, one per line.
# The copies' paths are absolute, so awk never reads one as a var=value operand.
scan_files() {
	set --
	checked_paths='' checked_names=''
	while IFS= read -r name && IFS= read -r kind && IFS= read -r path && IFS= read -r copy; do
		set -- "$@" "${copy}"
		checked_paths="${checked_paths}${path}
"
		checked_names="${checked_names}${name}
"
	done <<EOF
${copy_args}
EOF
	PREPARE_PROMPT_SCAN_PATHS=${checked_paths} PREPARE_PROMPT_SCAN_NAMES=${checked_names} awk "${SCAN_AWK}" "$@"
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
		--arg mode "${seat_mode}" --arg worktree "${seat_worktree}" --arg report "${report_path}" \
		"$@" "${MESSAGE_JQ_HEAD} [${items}] ${MESSAGE_JQ_TAIL}" </dev/null >"${message_file}" ||
		fault "jq could not build the message; the hook needs jq 1.6+ (--rawfile); the cause is on stderr."
}

# Writes <effort>/pending/<tool_use_id> holding the dispatch path, through a
# temp file in that folder moved onto it, for the seat bind hook.
write_pending_link() {
	pending_dir="${dispatch_effort}/pending"
	mkdir -p -- "${pending_dir}" || link_failed "mkdir could not create ${pending_dir}"
	temp_file=$(mktemp "${pending_dir}/.${tool_use_id}.XXXXXX") || {
		temp_file=''
		link_failed "mktemp could not create a temp file in ${pending_dir}"
	}
	printf '%s\n' "${dispatch_path}" >"${temp_file}" || link_failed "could not write ${temp_file}"
	mv -f -- "${temp_file}" "${pending_dir}/${tool_use_id}" ||
		link_failed "mv could not move ${temp_file} onto ${pending_dir}/${tool_use_id}"
	temp_file=''
}

# The pending link can't be written ($1): a deny, since the seat bind hook could
# not link the agent to its seat.
link_failed() {
	fault "$1, so the seat bind hook could not link the agent to its seat; expected a writable effort folder; the dispatch can be sent again once it is."
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
