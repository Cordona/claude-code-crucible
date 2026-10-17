#!/usr/bin/env sh
# PreToolUse hook on Agent. For a dispatch of a listed agent it validates the
# brief's CONTEXT and PLUGIN lines, appends the context file, then each named
# plugin file built as Claude Code builds a preloaded skill, to the prompt; any
# problem denies the dispatch. Every other Agent call passes untouched. The
# decision is the only output, so a listed agent is denied on any unexpected
# exit (fail closed).
# Each checked file is read once, into a private temp copy that the checks and
# the injection all read, so the checked bytes are the injected bytes. One
# window stays open, since POSIX sh can't test an open file: the path checks
# (not a symlink or resolving inside its plugin folder, regular, readable) run
# on the path just before the copy, so a path swapped in between, such as for a
# symlink or a FIFO, is copied unchecked or blocks until the hook times out.
# Swapping it takes write access to the plugin folder or the context file's folder.
# shellcheck source-path=SCRIPTDIR
set -eu

readonly PROG='inject-plugins.sh'
readonly REASON_PREFIX='procedure-agent-initialization:'
# The agents whose dispatches carry a PLUGIN line; add an agent here when it starts loading plugins.
readonly LISTED_AGENTS='code-developer code-reviewer'
# Stands for an empty list entry; it is not absolute, so it can't name a real file.
readonly EMPTY_ENTRY='<empty>'
# Bounds the symlink chain followed for one file, so a link loop ends in a deny.
readonly MAX_LINK_HOPS=40
readonly PATH_HINT='The expected form is "PLUGIN: none" or "PLUGIN: <path>, <path>" with absolute paths, as render-plugin-line.sh prints it from the approved plan (procedure-agent-initialization steps 7 and 9).'
# A context file holds references and a few notes, far below this; a bigger
# file means text was copied in rather than referenced.
readonly CONTEXT_MAX_BYTES=65536
readonly CONTEXT_HINT="The expected form is \"CONTEXT: <absolute path> sha256=<64 lowercase hex>\", the line render-plugin-line.sh --context-file prints for the approved context file (procedure-agent-initialization step 7), naming one JSON object of at most ${CONTEXT_MAX_BYTES} bytes with exactly the keys paths (null or [{\"path\": absolute path, \"why\": one line}]), links (null or [{\"url\": http(s) URL, \"why\": one line}]) and notes ([string, ...], [] for none), no value holding a <crucible-context> or <untrusted-data> tag or the brief's closing line."
# Fixed texts, built without jq: the deny when jq is missing, the deny when stdin
# can't be read, and the deny when the hook stops before deciding or jq fails to
# build a deny.
readonly NO_JQ_DENY='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"procedure-agent-initialization: jq is missing from PATH, so this dispatch is denied; the hook needs jq 1.6+."}}'
readonly STDIN_DENY='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"procedure-agent-initialization: the hook input on stdin could not be read, so this dispatch is denied; the hook expects the PreToolUse hook JSON on stdin; the cause is on the hook'\''s stderr."}}'
readonly INTERNAL_DENY='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"procedure-agent-initialization: the hook stopped before deciding, so this dispatch is denied; the cause is on the hook'\''s stderr."}}'
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

# The opening words of the line that ends every brief (flow-code-development's
# Brief fields); code-developer keys on them, so a plugin file holding them could
# fake the end of the brief. Change it together with that flow, the agent and
# lib/context-shape.jq's forbidden texts.
readonly BRIEF_CLOSING_LINE='A marked gap beats a papered-over one:'

# Prints one "PLUGIN <problem>: <file>" item per expansion token found in a file,
# per file holding the brief's closing line (passed as closing) and per SKILL.md
# without a closed frontmatter, all joined by "; ". It reads the temp copies; the
# environment's INJECT_PLUGINS_SCAN_PATHS holds each copy's checked path, one per
# line in operand order, and every item names that path. A "---" line may end in
# a CR, as in the frontmatter read and the injection.
# The program is single-quoted on purpose: its $ signs are awk's or literal text.
# shellcheck disable=SC2016
readonly SCAN_AWK='
function is_fence(line) { sub(/\r$/, "", line); return line == "---" }
function add(problem, file) { report = report (report == "" ? "" : "; ") "PLUGIN " problem ": " file }
function finish_file() {
	if (current == "") return
	if (is_skill && !closed) add("SKILL.md has no frontmatter closed by a --- line", current)
}
BEGIN {
	split(ENVIRON["INJECT_PLUGINS_SCAN_PATHS"], checked_paths, "\n")
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
	seen_closing = 0
}
is_skill && FNR > 1 && opened && !closed && is_fence($0) { closed = 1 }
{
	for (i = 1; i <= fixed_count; i++)
		if (!seen[fixed[i]] && index($0, fixed[i])) { seen[fixed[i]] = 1; add("file holds the expansion token " fixed[i], current) }
	if (!seen_digit && match($0, /\$[0-9]/)) { seen_digit = 1; add("file holds the expansion token " substr($0, RSTART, RLENGTH), current) }
	if (!seen_closing && index($0, closing)) { seen_closing = 1; add("file holds the brief\047s closing line \"" closing "\"", current) }
}
END { finish_file(); printf "%s", report }
'

# The allow-output program, split around the item list build_allow puts between
# them: [plugin name, "skill"|"reference", file text] triples in PLUGIN order.
# The programs are single-quoted on purpose: their $ signs are jq's.
# shellcheck disable=SC2016
readonly BUILD_JQ_HEAD='
# A "---" line may end in a CR, as in the frontmatter read and the token scan.
def is_fence: rtrimstr("\r") == "---";
def strip_frontmatter:
	split("\n") as $lines
	| ([range(1; $lines | length) | select($lines[.] | is_fence)] | first) as $close
	| if ($lines[0] | is_fence | not) or $close == null then error("SKILL.md has no frontmatter") else . end
	| $lines[$close + 1:] | join("\n")
	| if startswith("\n") then .[1:] elif startswith("\r\n") then .[2:] else . end;
def body: if .[1] == "skill" then .[2] | strip_frontmatter else .[2] end;
# Joins texts with one empty line between them; the last text keeps its own ending.
def join_with_empty_line:
	(.[:-1] | map(if endswith("\n") then . else . + "\n" end)) + .[-1:] | join("\n");
def block:
	"<command-message>\(.name)</command-message>\n<command-name>\(.name)</command-name>\n<skill-format>true</skill-format>\nBase directory for this skill: \($skills)/\(.name)\n\n\(.bodies | join_with_empty_line)";
def context_block:
	"<crucible-context path=\"\($context_path)\">\n\($context | if endswith("\n") then . else . + "\n" end)</crucible-context>";
. as $hook
|'
# shellcheck disable=SC2016
readonly BUILD_JQ_TAIL='
| reduce .[] as $item ([];
	if length > 0 and .[length - 1].name == $item[0]
	then .[length - 1].bodies += [$item | body]
	else . + [{name: $item[0], bodies: [$item | body]}]
	end)
| ("\n\n" + ([context_block] + map(block) | join_with_empty_line)) as $blocks
| {hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "allow",
	updatedInput: ($hook.tool_input + {prompt: ($hook.tool_input.prompt + $blocks)})}}
'

main() {
	case ${1-} in
		'') ;;
		--help | -h)
			usage
			exit 0
			;;
		*)
			printf "%s: unknown option: %s; expected no arguments (hook input on stdin) or --help; try '%s --help'\n" "${PROG}" "$1" "${PROG}" >&2
			exit 2
			;;
	esac

	decided=false
	is_listed_agent=false
	snapshot_dir=''
	trap on_exit EXIT
	# A signal exits through the EXIT trap: the temp copies go and a listed agent is denied.
	trap 'exit 129' HUP
	trap 'exit 130' INT
	trap 'exit 143' TERM

	# shellcheck disable=SC2310 # its status is the probe result; errexit adds nothing
	if ! stdin_is_open || ! hook_input=$(cat); then
		is_listed_agent=true
		emit "${STDIN_DENY}"
	fi
	classify_call
	[ "${is_listed_agent}" = true ] || pass

	# shellcheck disable=SC2310 # the function's status is its final jq's; a failure denies
	plugin_value=$(read_plugin_line) ||
		deny "${REASON_PREFIX} jq could not read tool_input.prompt; the hook needs jq 1.6+ and a string prompt; the cause is on the hook's stderr."
	plugin_status=${plugin_value%%
*}
	plugin_paths=''
	copy_args=''
	case ${plugin_status} in
		none) ;;
		absent) deny "${REASON_PREFIX} PLUGIN line missing: no prompt line starts with \"PLUGIN:\". ${PATH_HINT}" ;;
		empty) deny "${REASON_PREFIX} PLUGIN value is empty. ${PATH_HINT}" ;;
		control) deny "${REASON_PREFIX} PLUGIN value holds a control character. ${PATH_HINT}" ;;
		paths) plugin_paths=${plugin_value#paths
} ;;
		*) deny "${REASON_PREFIX} the PLUGIN line parsed to an unknown status (${plugin_status}); the fault is in ${PROG}, not in the brief." ;;
	esac

	make_snapshot_dir
	check_context
	resolve_skills_dir
	[ -z "${plugin_paths}" ] || check_plugins

	# shellcheck disable=SC2310 # the function's status is its final jq's; a failure denies
	decision=$(build_allow) ||
		deny "${REASON_PREFIX} jq could not build the new prompt; the hook needs jq 1.6+ (--rawfile); the cause is on the hook's stderr."
	emit "${decision}"
}

usage() {
	cat <<EOF
Usage: sh ${PROG} [--help|-h] < PreToolUse-JSON

A Claude Code PreToolUse hook (matcher Agent); it reads one hook input on stdin.
Acts only when tool_name is Agent and tool_input.subagent_type is one of:
${LISTED_AGENTS}. Every other call: no output, exit 0.

For a listed agent, the first prompt line starting with "CONTEXT:" holds
  CONTEXT: <absolute path> sha256=<64 lowercase hex>
as render-plugin-line.sh --context-file prints it for the approved context
file (the brief puts it right after the PLUGIN line). Before the file is
opened, the path must be absolute and hold no control character, no double
quote (it is written into the block's path attribute) and no .. segment, and
must not name a sensitive file in any letter case: a basename .env*, *.pem,
*.key or id_*, or a .git component. It must name a readable regular file
that is not a symlink (its folders may be), of at most ${CONTEXT_MAX_BYTES} bytes,
whose sha256 is the line's digest, holding valid JSON: exactly one object
with exactly these keys:
  {"paths": null | [{"path": str, "why": str}, ...],
   "links": null | [{"url": str, "why": str}, ...],
   "notes": [str, ...]}
where path is absolute (starts with /), url is http:// or https:// with a
host of letters, digits, dots and hyphens and an optional :port, then
optionally a path, query or fragment of letters, digits and
. _ ~ / ? # = % : + , @ - only (no space, quote, ; \$ \` ( ) & | < or >),
why is one non-empty line, notes may be [], no entry has another
key, and no value but a note holds a control character. No value, and not
the path, may hold, in any letter case, "<crucible-context",
"</crucible-context", "<untrusted-data", "</untrusted-data" or the brief's
closing line "${BRIEF_CLOSING_LINE}". The path checks are
scripts/lib/context-file.sh and the shape check scripts/lib/context-shape.jq,
both shared with render-dispatch-plan.sh.

The first prompt line starting with "PLUGIN:" holds "none"
or a comma-separated list of absolute paths. Each path must have no .. segment
and lie under \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/skills/ (compared as text).
Its folder there must be a plugin: named tech-* or standard-*, holding a SKILL.md
whose frontmatter has name: <the folder name> and disable-model-invocation: true.
The path must be that SKILL.md or a file under the folder's references/, be a
readable regular file, resolve (symlinks followed) inside the real path of its
plugin folder (the folder itself may be a symlink), and hold none of Claude
Code's expansion tokens (\$ARGUMENTS, \$<digit>, \${CLAUDE_SKILL_DIR},
\${CLAUDE_PROJECT_DIR}, \${CLAUDE_SESSION_ID}, \${CLAUDE_EFFORT}, !\`, \`\`\`!),
nor the brief's closing line "${BRIEF_CLOSING_LINE}".
A folder's paths form one run of adjacent entries, its SKILL.md first.
A frontmatter "---" line may end in a CR (fence lines and the blank line after
the frontmatter tolerate CR; the body keeps its CRs).

Output (stdout, one JSON line):
  allow  hookSpecificOutput.updatedInput = tool_input with the prompt followed
         by "\n\n", the context block, then one block per plugin folder, in
         PLUGIN order (none for PLUGIN: none). The context block:
         <crucible-context path="PATH">
         the context file's JSON as read (a newline added if it has none)
         </crucible-context>
         A plugin block:
         <command-message>NAME</command-message>
         <command-name>NAME</command-name>
         <skill-format>true</skill-format>
         Base directory for this skill: SKILLS/NAME

         the files (SKILL.md without its frontmatter)
         Files in a block, and blocks, are separated by one empty line: each
         keeps its final newline (one is added where it is missing, except the
         last file of the last block), then "\n".
  deny   permissionDecisionReason =
         "${REASON_PREFIX} PLUGIN <problem>: <path>[; PLUGIN ...]. <hint>"
         (a folder that fails the plugin test: "not a plugin (<why>)"), or
         "${REASON_PREFIX} CONTEXT <problem>: <path>. <hint>", the problem
         one of: line has no sha256 digest (<path> is then the whole value);
         path is not absolute; path holds a control character; path holds a
         double quote; path has a .. segment; path names a sensitive file;
         file is a symlink; file is missing, unreadable or not a regular file;
         file is larger than ${CONTEXT_MAX_BYTES} bytes; file changed since it was
         approved (sha256 <12 hex> approved, <12 hex> now); file is not valid
         JSON; file does not have the context shape (<what>; expected <x>[;
         ...], at most 20 listed)
         and, without a path: "CONTEXT line missing", "CONTEXT value is
         empty", "CONTEXT value holds a control character".
         Every reason about the CONTEXT line or its file starts
         "${REASON_PREFIX} CONTEXT"; a fault of this script, its install or
         the host (jq, wc, a sha256 tool, mktemp) never does.
  none   not a listed agent: no output.
A listed agent is denied when CONTEXT or PLUGIN is missing, empty or holds a
control character, when scripts/lib/context-file.sh or context-shape.jq is
missing beside this script, when neither sha256sum nor shasum is on PATH, or
jq is missing or fails; other agents pass then, unless jq can't
read the input and its subagent_type text holds an escape (the agent can't be
known without decoding it). A closed or unreadable stdin denies every call at
once, listed agent or not, since the agent can't be known.

Exit codes: 0 every hook decision (read stdout); 2 usage error.
Each checked file is read once into a private temp folder, removed on exit;
the checks and the injected text all come from that copy.
Dependencies: POSIX sh, jq 1.6+ (--rawfile, \$ARGS), awk, cat, dd, mktemp,
readlink, rm, wc, and sha256sum or shasum (macOS: shasum -a 256);
scripts/lib/context-file.sh and context-shape.jq beside this script.
Runtime: about 10 ms for an agent not listed, 45 ms injecting the context file
alone, 80 ms with it and 4 plugin files; measured on macOS (average of 5 runs).
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
		deny "${REASON_PREFIX} the hook input is not valid JSON, so this dispatch is denied; the hook expects one PreToolUse object on stdin, as Claude Code sends it to a registered hook entry."
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

# Prints the PLUGIN value as lines: a status (absent, empty, control, none or
# paths) and then one trimmed path per line, an empty entry as EMPTY_ENTRY.
read_plugin_line() {
	printf '%s' "${hook_input}" | jq -r --arg empty "${EMPTY_ENTRY}" '
		def trim: sub("^[ \t]+"; "") | sub("[ \t\r]+$"; "");
		(.tool_input.prompt | if type == "string" then split("\n") else [] end
			| map(select(startswith("PLUGIN:"))) | first) as $line
		| if $line == null then "absent"
		else ($line[7:] | trim) as $value
			| if $value == "" then "empty"
			elif $value == "none" then "none"
			elif ($value | explode | any(. < 32 or . == 127)) then "control"
			else "paths", ($value | split(",") | map(trim | if . == "" then $empty else . end) | .[])
			end
		end'
}

# Creates the private temp folder that holds every checked file's copy.
make_snapshot_dir() {
	snapshot_dir=$(mktemp -d "${TMPDIR:-/tmp}/${PROG}.XXXXXX") ||
		deny "${REASON_PREFIX} mktemp could not create a temp folder; the hook needs a writable \${TMPDIR:-/tmp}; the cause is on the hook's stderr."
	case ${snapshot_dir} in
		/*) ;;
		*) snapshot_dir="${PWD}/${snapshot_dir}" ;;
	esac
}

# Sets context_path and context_copy from the brief's CONTEXT line once the
# file passes every check, or denies.
check_context() {
	load_context_lib
	# shellcheck disable=SC2310 # the function's status is its final jq's; a failure denies
	context_value=$(read_context_line) ||
		deny "${REASON_PREFIX} jq could not read tool_input.prompt; the hook needs jq 1.6+ and a string prompt; the cause is on the hook's stderr."
	context_status=${context_value%%"${NL}"*}
	context_fields=${context_value#*"${NL}"}
	case ${context_status} in
		path)
			context_path=${context_fields%%"${NL}"*}
			approved_digest=${context_fields#*"${NL}"}
			;;
		nodigest)
			context_path=${context_fields}
			deny_context 'line has no sha256 digest'
			;;
		absent) deny "${REASON_PREFIX} CONTEXT line missing: no prompt line starts with \"CONTEXT:\". ${CONTEXT_HINT}" ;;
		empty) deny "${REASON_PREFIX} CONTEXT value is empty. ${CONTEXT_HINT}" ;;
		control) deny "${REASON_PREFIX} CONTEXT value holds a control character. ${CONTEXT_HINT}" ;;
		*) deny "${REASON_PREFIX} the line parser returned an unknown status (${context_status}); the fault is in ${PROG}, not in the brief." ;;
	esac
	check_context_path
	copy_context
	check_context_digest
	check_context_shape
}

# Sources the shared path checks and finds the sha256 tool, or denies: either
# missing is an install or host fault, not the brief's.
load_context_lib() {
	context_lib=$(script_dir)/lib/context-file.sh
	[ -f "${context_lib}" ] && [ -r "${context_lib}" ] ||
		deny "${REASON_PREFIX} the shared path check ${context_lib} is missing or unreadable; the hook needs it beside ${PROG}; the fault is in the ${REASON_PREFIX%:} install, not in the brief."
	# shellcheck source=lib/context-file.sh
	. "${context_lib}"
	# shellcheck disable=SC2310 # its status is the lookup result; errexit adds nothing
	find_context_digest_tool ||
		deny "${REASON_PREFIX} neither sha256sum nor shasum is on PATH, so the brief's digest can't be checked; the fault is in the host, not in the brief; install coreutils (Linux) or use the system shasum (macOS)."
}

# Prints the CONTEXT value as lines: a status (absent, empty, control,
# nodigest or path), then for nodigest the trimmed value, and for path the
# path and the digest the line ends in.
read_context_line() {
	printf '%s' "${hook_input}" | jq -r '
		(.tool_input.prompt | if type == "string" then split("\n") else [] end
			| map(select(startswith("CONTEXT:"))) | first) as $line
		| if $line == null then "absent"
		else ($line[8:] | sub("^[ \t]+"; "") | sub("[ \t\r]+$"; "")) as $value
			| ($value | capture("^(?<path>.+) sha256=(?<digest>[0-9a-f]{64})$")? // null) as $parts
			| if $value == "" then "empty"
			elif ($value | explode | any(. < 32 or . == 127)) then "control"
			elif $parts == null then "nodigest", $value
			else "path", $parts.path, $parts.digest
			end
		end'
}

# Denies when context_path fails the shared path checks (run on the text,
# before the file is opened) or is not a readable regular file of its own.
check_context_path() {
	path_problem=$(context_path_problem "${context_path}")
	[ -z "${path_problem}" ] || deny_context "${path_problem}"
	[ ! -L "${context_path}" ] || deny_context 'file is a symlink'
	[ -f "${context_path}" ] && [ -r "${context_path}" ] ||
		deny_context 'file is missing, unreadable or not a regular file'
}

# Copies at most one byte over the cap, so an oversized file is never read whole.
copy_context() {
	context_copy="${snapshot_dir}/context"
	dd if="${context_path}" of="${context_copy}" bs="$((CONTEXT_MAX_BYTES + 1))" count=1 2>/dev/null ||
		deny_context 'file is missing, unreadable or not a regular file'
	context_size=$(wc -c <"${context_copy}") ||
		deny "${REASON_PREFIX} wc could not count the bytes of the hook's temp copy; the fault is in the host, not in the brief; the cause is on the hook's stderr."
	context_size=${context_size##* }
	case ${context_size} in
		'' | *[!0-9]*) deny "${REASON_PREFIX} wc printed no byte count for the hook's temp copy; the fault is in the host's wc, not in the brief." ;;
		*) ;;
	esac
	[ "${context_size}" -le "${CONTEXT_MAX_BYTES}" ] ||
		deny_context "file is larger than ${CONTEXT_MAX_BYTES} bytes"
}

# Denies when the copy's sha256 is not the digest the CONTEXT line carries, the
# one render-plugin-line.sh printed for the approved file.
check_context_digest() {
	# shellcheck disable=SC2310 # its status is the tool's; a failure denies
	compute_context_digest "${context_copy}" ||
		deny "${REASON_PREFIX} ${context_digest_tool} could not hash the hook's temp copy; the fault is in the host, not in the brief; the cause is on the hook's stderr."
	# 12 hex, as the approved plan's Context section shows them, so the two can be matched by eye.
	[ "${context_digest}" = "${approved_digest}" ] ||
		deny_context "file changed since it was approved (sha256 $(printf '%.12s' "${approved_digest}") approved, $(printf '%.12s' "${context_digest}") now)"
}

# Denies when the copy is not valid JSON or not the context shape; the shape
# check also refuses the forbidden texts in the path.
check_context_shape() {
	jq empty "${context_copy}" </dev/null >/dev/null 2>&1 || deny_context 'file is not valid JSON'
	shape_program=$(script_dir)/lib/context-shape.jq
	[ -f "${shape_program}" ] && [ -r "${shape_program}" ] ||
		deny "${REASON_PREFIX} the shape check ${shape_program} is missing or unreadable; the hook needs it beside ${PROG}; the fault is in the ${REASON_PREFIX%:} install, not in the brief."
	shape_report=$(jq -rs --arg context_path "${context_path}" -f "${shape_program}" "${context_copy}" </dev/null) ||
		deny "${REASON_PREFIX} jq could not run the shape check ${shape_program}; the hook needs jq 1.6+; the fault is in the host or the install, not in the brief; the cause is on the hook's stderr."
	[ -n "${shape_report}" ] || return 0
	shape_problems=$(join_lines "${shape_report}")
	deny_context "file does not have the context shape (${shape_problems})"
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

# Denies with "CONTEXT <problem $1>: <context_path>" and the context hint.
deny_context() {
	deny "${REASON_PREFIX} CONTEXT $1: ${context_path}. ${CONTEXT_HINT}"
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

# Checks, copies and scans the files in plugin_paths, or denies.
check_plugins() {
	check_paths
	[ -z "${problems}" ] || deny "${REASON_PREFIX} ${problems}. ${PATH_HINT}"
	snapshot_files
	[ -z "${problems}" ] || deny "${REASON_PREFIX} ${problems}. ${PATH_HINT}"

	# shellcheck disable=SC2310 # the function's status is its final awk's; a failure denies
	scan_report=$(scan_files) ||
		deny "${REASON_PREFIX} awk could not scan the plugin files; the hook expects readable text files; the cause is on the hook's stderr."
	[ -z "${scan_report}" ] || deny "${REASON_PREFIX} ${scan_report}. The hook expects plugin files without expansion tokens or the brief's closing line, and each SKILL.md with a closed frontmatter; the fault is in the named plugin's installed files."
}

# Validates every path in plugin_paths; sets problems and the per-file jq
# arguments in build_args, one name, kind and path line per file.
check_paths() {
	problems=''
	build_args=''
	judged_plugin=''
	run_plugin=''
	run_plugins='
'
	while IFS= read -r path; do
		check_path "${path}"
		[ -n "${path_problem}" ] || check_run_order
		if [ -n "${path_problem}" ]; then
			add_problem "${path_problem}" "${path}"
		else
			build_args="${build_args}${plugin_name}
${file_kind}
${path}
"
		fi
	done <<EOF
${plugin_paths}
EOF
}

# Sets path_problem, plugin_name and file_kind for path $1 (every path check, then containment).
check_path() {
	path_problem=''
	case $1 in
		"${EMPTY_ENTRY}") path_problem='list has an empty entry'; return 0 ;;
		/*) ;;
		*) path_problem='path is not absolute'; return 0 ;;
	esac
	case $1 in
		*/../* | */..) path_problem='path has a .. segment'; return 0 ;;
		*) ;;
	esac
	case $1 in
		"${skills_dir}"/*) ;;
		*) path_problem="path is outside the skills folder ${skills_dir}/"; return 0 ;;
	esac
	path_in_skills=${1#"${skills_dir}"/}
	plugin_name=${path_in_skills%%/*}
	case ${plugin_name} in
		tech-?* | standard-?*) ;;
		*) path_problem='path is not in a tech-* or standard-* plugin folder'; return 0 ;;
	esac
	[ -f "${skills_dir}/${plugin_name}/SKILL.md" ] || {
		path_problem="plugin folder ${plugin_name} has no SKILL.md"
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
		*) path_problem="path is not ${plugin_name}/SKILL.md or a file under ${plugin_name}/references/"; return 0 ;;
	esac
	[ -f "$1" ] && [ -r "$1" ] || {
		path_problem='file is missing, unreadable or not a regular file'
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
		path_problem='plugin folder can not be resolved to a real path'
		return 0
	}
	real_plugin_dir=${resolved_dir}
	# shellcheck disable=SC2310 # its status is the resolve result; errexit adds nothing
	resolve_file "$1" || {
		path_problem="file can not be resolved to a real path (more than ${MAX_LINK_HOPS} symlinks, or a broken link)"
		return 0
	}
	case ${resolved_file} in
		"${real_plugin_dir%/}"/*) ;;
		*) path_problem="file resolves outside its plugin folder ${real_plugin_dir} (to ${resolved_file})" ;;
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
		not_plugin_reason="$1/SKILL.md has no frontmatter closed by a --- line"
		return 0
	fi
	frontmatter_name=${frontmatter%%"${TAB}"*}
	frontmatter_disabled=${frontmatter#*"${TAB}"}
	[ "${frontmatter_name}" = "$1" ] ||
		not_plugin_reason="$1/SKILL.md has name: '${frontmatter_name}'; expected name: $1"
	[ "${frontmatter_disabled}" = true ] ||
		not_plugin_reason="${not_plugin_reason}${not_plugin_reason:+, }$1/SKILL.md lacks disable-model-invocation: true"
}

# Appends "PLUGIN <problem>: <subject>" to problems.
add_problem() {
	problems="${problems}${problems:+; }PLUGIN $1: $2"
}

# Copies each file in build_args once into the private temp folder and sets
# copy_args to its name, kind, path and copy lines; re-runs the plugin test on
# each SKILL.md copy. Adds a problem for a file that can't be copied or fails it.
snapshot_files() {
	copy_args=''
	copy_index=0
	while IFS= read -r name && IFS= read -r kind && IFS= read -r path; do
		copy_index=$((copy_index + 1))
		copy="${snapshot_dir}/${copy_index}"
		cat -- "${path}" >"${copy}" || {
			add_problem 'file is missing, unreadable or not a regular file' "${path}"
			continue
		}
		if [ "${kind}" = skill ]; then
			plugin_test "${name}" "${copy}"
			[ -z "${not_plugin_reason}" ] || {
				add_problem "not a plugin (${not_plugin_reason})" "${path}"
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

# Prints the token, closing-line and frontmatter problems of the copied files (empty when none).
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
	INJECT_PLUGINS_SCAN_PATHS=${checked_paths} awk -v closing="${BRIEF_CLOSING_LINE}" "${SCAN_AWK}" "$@"
}

# Prints the allow decision for the context copy and the files in copy_args,
# each copy read byte for byte by jq.
build_allow() {
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
	printf '%s' "${hook_input}" |
		jq -c --arg skills "${skills_dir}" --arg context_path "${context_path}" --rawfile context "${context_copy}" \
			"$@" "${BUILD_JQ_HEAD} [${items}] ${BUILD_JQ_TAIL}"
}

# Prints a deny decision with reason $1 and exits 0.
deny() {
	decision=$(jq -nc --arg reason "$1" \
		'{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}') ||
		decision=${INTERNAL_DENY}
	emit "${decision}"
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

# Removes the temp copies, and denies a listed agent's dispatch when the hook
# dies before deciding.
# shellcheck disable=SC2329 # invoked by the EXIT trap
on_exit() {
	exit_status=$?
	[ -z "${snapshot_dir}" ] || rm -rf -- "${snapshot_dir}"
	if [ "${decided}" = false ] && [ "${is_listed_agent}" = true ]; then
		printf '%s: stopped before deciding (exit %s); denying the dispatch\n' "${PROG}" "${exit_status}" >&2
		printf '%s\n' "${INTERNAL_DENY}"
		exit 0
	fi
}

main "$@"
