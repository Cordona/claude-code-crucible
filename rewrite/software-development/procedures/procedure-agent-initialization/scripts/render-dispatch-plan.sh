#!/usr/bin/env sh
# Renders one dispatch plan with its context, or its approval question, from
# JSON files, so the main thread never hand-formats either; --no-plugin-fits
# does the same for a part no installed tech plugin fits. This script owns the layout, the question
# wording and the input rules it checks (see --help), including the check of a
# plan against the installed plugins; references/dispatch-plan-rules.md keeps
# only the rules it can't check. Pipe its stdout into procedure-approval-gate's
# open-gate.sh.
# shellcheck source-path=SCRIPTDIR
set -eu

readonly PROG='render-dispatch-plan.sh'
readonly PROCEDURE='procedure-agent-initialization'
readonly DIRECT_AGENT='main thread'
readonly TESTING_PLUGIN='standard-testing'
# The context file's cap, the same as inject-plugins.sh's (change both together):
# references and a few notes fit far below it; a bigger file means text was
# copied in rather than referenced.
readonly CONTEXT_MAX_BYTES=65536

# Definitions every program below starts with. The programs are single-quoted
# on purpose: their $ signs are jq's.
# shellcheck disable=SC2016
readonly COMMON_JQ='
def text_ok: type == "string" and (gsub("[[:cntrl:][:space:]]"; "") | length > 0);
def clean: gsub("[[:cntrl:]]+"; " ") | sub("^ +"; "") | sub(" +$"; "");
def option($label; $description): {label: $label, description: $description};
def checked_object(problems):
	if length != 1 then "expected exactly one JSON object, got \(length) values"
	elif (.[0] | type) != "object" then "input is a JSON \(.[0] | type); expected an object"
	else .[0] | problems end;
def unknown_keys($allowed): (keys - $allowed)[] | "\(.): unknown field; expected one of \($allowed | join(", "))";
def strings_problems($key):
	if (.[$key] | type) != "array" or (.[$key] | length) == 0 then "\($key) missing or empty; expected an array of one or more strings"
	else .[$key] | to_entries[] | select(.value | text_ok | not) | "\($key)[\(.key)] is not a non-empty string" end;
def task_lines:
	(.tasks | length) as $count
	| if $count == 1 then "**Task:** \(.tasks[0] | clean)"
	  else "**Tasks:**\n\n" + ([.tasks | to_entries[] | "\(.key + 1). \(.value | clean)"] | join("\n")) end;
# The context file, slurped into $context, as groups the human scans: each
# path in the first group it fits (saved beside the context file, a task file,
# any other file), then the links, then every note in full. A path or link is
# shown, never run, so a backtick in it becomes a quote to keep its code span.
# The cap keeps every code span on one line beside its bullet.
def span_cap: 80;
def cut_head: 30;
def middle_cut($tail): .[:(span_cap - 1 - $tail)] + "…" + .[(length - $tail):];
def capped: if length > span_cap then middle_cut(span_cap - 1 - cut_head) else . end;
def code_span: "`" + (gsub("`"; [39] | implode) | capped) + "`";
def counted($count; $noun): if $count == 0 then empty elif $count == 1 then "1 \($noun)" else "\($count) \($noun)s" end;
def base_name: sub("^.*/"; "");
def dir_segments: split("/") | .[1:-1];
def home_form: ($home | rtrimstr("/")) as $prefix
	| if $prefix != "" and (. == $prefix or startswith($prefix + "/")) then "~" + .[($prefix | length):] else . end;
# Capped, but with the basename kept whole while one character of the head fits.
def short_path: home_form | (base_name | length) as $base
	| if length <= span_cap or $base > span_cap - 2 then capped
	  else middle_cut([span_cap - 1 - cut_head, $base] | max) end;
def task_file: capture("/tasks/(?<list>[^/]+)/(?<number>[0-9]+)\\.json$");
def shared_start($next): . as $prefix
	| first(range(0; length + 1) | select(. == ($prefix | length) or $prefix[.] != $next[.])) as $count
	| $prefix[:$count];
def item($shown): "- \(.why | clean)\\\n  \($shown | clean | code_span)";
def group($heading; $items): if ($items | length) == 0 then empty else "\($heading)\n" + ($items | join("\n")) end;
def task_groups($entries):
	[$entries[] | . + (.path | task_file)] as $tasks
	| reduce $tasks[].list as $list ([]; if any(.[]; . == $list) then . else . + [$list] end)
	| .[] as $list
	| group("**Tasks** · \($list | clean | code_span)"; [$tasks[] | select(.list == $list) | item("\(.number).json")]);
def file_group($entries):
	if ($entries | length) == 0 then empty
	else ($entries | map(.path | dir_segments) | reduce .[1:][] as $next (.[0]; shared_start($next))) as $root
		| ("/" + ($root | map(. + "/") | join(""))) as $root_dir
		| (if ($root | length) == 0 then "/" else ($root[-2:] | join("/")) + "/" end) as $label
		| group("**Files** · \($label | clean | code_span)"; [$entries[] | .path[($root_dir | length):] as $relative
			| item(if ($root | length) == 0 or ($relative | length) > span_cap then .path | short_path else $relative end)])
	end;
def notes_group($notes):
	group("**Notes** · written by Claude from your words, so check these"; [$notes | to_entries[] | "\(.key + 1). \(.value | clean)"]);
def context_section:
	$context[0] as $file
	| ($file.paths // []) as $paths
	| ($file.links // []) as $links
	| ($file.notes // []) as $notes
	| ($context_file | dir_segments) as $saved_dir
	| [$paths[] | select(.path | dir_segments != $saved_dir)] as $others
	| [([("**Context**", ($context_file | base_name | clean | code_span), "sha256 `\($context_digest[:12])`",
			counted($paths | length; "file"), counted($links | length; "link"), counted($notes | length; "note"))] | join(" · ")),
		group("**Saved by Claude**"; [$paths[] | select(.path | dir_segments == $saved_dir) | item(.path | base_name)]),
		task_groups([$others[] | select([.path | task_file] | length > 0)]),
		file_group([$others[] | select([.path | task_file] | length == 0)]),
		group("**Links**"; [$links[] | item(.url)]),
		notes_group($notes)]
	| join("\n\n");
'

# Prints one line per problem with the slurped plan; nothing when it is valid.
# $listing holds list-plugins.sh's plugin lines.
# shellcheck disable=SC2016
readonly CHECK_JQ='
def top_keys: ["agent", "mode", "technology", "tasks", "loaded", "loaded_reason", "not_loaded", "replan"];
def plugins_problems($key):
	if (.[$key] | type) != "array" then "\($key) missing or not an array; expected [{\"plugin\": str, \"reason\": str}, ...] ([] for none)"
	else .[$key] | to_entries[]
		| if (.value | type) != "object" then "\($key)[\(.key)] is a \(.value | type); expected {\"plugin\": str, \"reason\": str}"
		  else (.key as $index | .value
			| ((keys - ["plugin", "reason"])[] | "\($key)[\($index)].\(.): unknown field; expected only plugin and reason"),
			  (if (.plugin | text_ok) and (.reason | text_ok) then empty
			   else "\($key)[\($index)] is not {\"plugin\": non-empty string, \"reason\": non-empty string}" end))
		  end
	end;
def installed:
	$listing | split("\n") | map(split("\t") | select(length >= 3 and (.[0] == "tech" or .[0] == "standard"))
		| {key: .[1], value: {kind: .[0], label: .[2]}}) | from_entries;
def named_items:
	[("loaded", "not_loaded") as $key
	 | .[$key] | select(type == "array") | to_entries[]
	 | select((.value | type) == "object" and (.value.plugin | text_ok))
	 | {path: "\($key)[\(.key)].plugin", list: $key, plugin: .value.plugin, reason: .value.reason}];
# A step-9 re-plan may list, under not_loaded, a plugin list-plugins.sh no longer prints.
def dropped_reasons: "invalid", "uninstalled after approval", "faulty files";
def installed_problems:
	. as $plan
	| installed as $installed
	| named_items as $items
	| ($items[] | select(.plugin as $name | $installed | has($name) | not)
		| select(.list == "loaded" or (.reason | IN(dropped_reasons) | not))
		| "\(.path): \(.plugin | tojson) is not installed; expected a name list-plugins.sh prints"),
	  ($items | group_by(.plugin)[] | .[1:][]
		| "\(.path): \(.plugin | tojson) listed more than once; expected each plugin once, in loaded or not_loaded"),
	  (if ($plan.loaded | type) == "array" and ($plan.not_loaded | type) == "array" then
		($items | map(.plugin)) as $named
		| $installed | keys[] | select(IN($named[]) | not)
		| "not_loaded: \(tojson) is installed but in neither loaded nor not_loaded; expected every installed plugin in one of them"
	   else empty end),
	  ([$items[] | select(.list == "loaded" and $installed[.plugin].kind == "tech")] as $tech
		| if ($tech | length) > 1 then "loaded: \($tech | map(.plugin) | join(", ")) are all tech plugins; expected at most one"
		  elif ($plan.loaded | type) != "array" or ($plan.technology | text_ok | not) then empty
		  elif ($tech | length) == 1 then
			$installed[$tech[0].plugin].label as $label
			| if $plan.technology == $label then empty
			  else "technology: \($plan.technology | tojson) is not the label of \($tech[0].plugin); expected \($label | tojson)" end
		  elif $plan.technology == "none" then empty
		  else "technology: \($plan.technology | tojson) with no tech plugin loaded; expected \"none\"" end),
	  (if ($plan.loaded | type) != "array" then empty
	   else [$items[] | select(.list == "loaded" and .plugin == $testing)] as $testing_items
		| if $plan.mode == "TEST" and ($testing_items | length) == 0 then
			"loaded: mode \"TEST\" without \($testing); expected \($testing) in loaded"
		  elif $plan.mode == "BUILD" then
			($testing_items[] | "\(.path): \($testing | tojson) in a mode \"BUILD\" plan; expected it only in a TEST plan, under not_loaded here")
		  else empty end
	   end);
checked_object(
	unknown_keys(top_keys),
	(if (.agent | text_ok) then empty else "agent missing or empty; expected a non-empty string" end),
	(if .mode == "BUILD" or .mode == "TEST" then empty else "mode missing or unknown; expected \"BUILD\" or \"TEST\"" end),
	(if (.technology | text_ok) then empty else "technology missing or empty; expected a label or \"none\"" end),
	(if .agent == $direct and (.mode != "BUILD" or .technology != "none")
	 then "agent \"\($direct)\" (direct implementation) needs mode \"BUILD\" and technology \"none\"" else empty end),
	strings_problems("tasks"),
	plugins_problems("loaded"),
	plugins_problems("not_loaded"),
	(if (.loaded | type) != "array" then empty
	 elif (.loaded | length) == 0 then
		(if has("loaded_reason") | not then "loaded_reason missing; expected a non-empty string saying why loaded is []"
		 elif (.loaded_reason | text_ok) | not then "loaded_reason is not a non-empty string"
		 else empty end)
	 elif has("loaded_reason") then "loaded_reason given with a non-empty loaded list; expected it only when loaded is []"
	 else empty end),
	(if has("replan") | not then empty
	 elif .replan == "invalid" or .replan == "stop-recommended" then empty
	 else "replan unknown; expected \"invalid\" or \"stop-recommended\", or no replan field" end),
	installed_problems)
'

# Control characters (a newline in a task) become one space, so every value
# stays on its own line.
# shellcheck disable=SC2016
readonly RENDER_JQ='
def item: (if (.plugin | clean) == "none" then "- none" else "- `\(.plugin | clean)`" end)
	+ "\\\n  *(\(.reason | clean))*";
def section($title; $list):
	"**\($title)**\n\n" + (if ($list | length) == 0 then "- none" else $list | map(item) | join("\n") end);
.[0]
| (.tasks | length) as $count
| "## 🎯 Agent dispatch plan\n\n"
	+ "**Agent:** \(.agent | clean)\(if $count > 1 then " (\($count))" else "" end)\n\n"
	+ "**Mode:** \(.mode)\n\n"
	+ "**Technology:** \(.technology | clean)\n\n"
	+ task_lines
	+ "\n\n" + section("Loaded"; if (.loaded | length) == 0 then [{plugin: "none", reason: .loaded_reason}] else .loaded end)
	+ "\n\n" + section("Not loaded"; .not_loaded)
	+ "\n\n" + context_section
'

# Prints the AskUserQuestion fields for the plan, or nothing for replan
# "invalid" (that plan is shown with no question). $plans is how many plans
# this run of step 6 shows, one after another.
# shellcheck disable=SC2016
readonly QUESTION_JQ='
.[0]
| (.tasks | length) as $count
| (.agent == $direct) as $is_direct
| " To change the plugins, choose \"Type something\" and write what to add or drop." as $change
| (if $is_direct then "Implement with the plugins shown." else "Dispatch with the plugins shown." end) as $approve
| (if $is_direct then "Nothing is implemented." else "Nothing is dispatched." end) as $stop
| if .replan == "invalid" then empty
  else {
	header: (if $count > 1 then "Dispatch ×\($count)" else "Dispatch" end),
	question: ((if $is_direct then "Approve implementing directly with the plugins shown?"
		elif $count > 1 then "Approve these \($count) dispatches with the plugins shown?"
		else "Approve this dispatch with the plugins shown?" end) + $change),
	options: (if .replan == "stop-recommended" then
			[option("Stop (Recommended)"; "Nothing is dispatched; reinstall the dropped plugin (faulty files: fix it), then rerun."),
			 option("Approve"; $approve)]
		elif $plans > 1 then
			[option("Approve (Recommended)"; $approve),
			 option("Skip"; "This plan does not run; the next plan is still shown."),
			 option("Stop all"; "No further plan is shown and nothing is dispatched, including plans already approved.")]
		else
			[option("Approve (Recommended)"; $approve), option("Stop"; $stop)]
		end)
  } end
'

# shellcheck disable=SC2016
readonly NO_FIT_CHECK_JQ='
checked_object(
	unknown_keys(["stack", "files", "tasks"]),
	(if (.stack | text_ok) then empty else "stack missing or empty; expected a non-empty string" end),
	strings_problems("files"),
	strings_problems("tasks"))
'

# shellcheck disable=SC2016
readonly NO_FIT_RENDER_JQ='
.[0]
| "## 🧩 No plugin fits\n\n"
	+ "**Stack:** \(.stack | clean)\n\n"
	+ "**Files:**\n\n" + (.files | map("- `\(clean)`") | join("\n")) + "\n\n"
	+ task_lines
	+ "\n\nNo installed tech plugin fits this stack: the main thread would write the code itself."
	+ "\n\n" + context_section
'

# shellcheck disable=SC2016
readonly NO_FIT_QUESTION_JQ='
.[0]
| {header: "No plugin",
   question: "No installed tech plugin fits \(.stack | clean). Stop, or implement directly?",
   options: [option("Stop (Recommended)"; "build the tech plugin first; nothing runs for this part"),
	option("Implement directly"; "the main thread writes the code, with the standard plugins the next plan settles")]}
'

usage() {
	cat <<EOF
Usage: sh ${PROG} --plan-file PATH --context-file CTX [--skills-dir DIR] | sh <skills>/procedure-approval-gate/scripts/open-gate.sh
       sh ${PROG} --plan-file PATH [--skills-dir DIR] --question --plans N
       sh ${PROG} --no-plugin-fits --plan-file PATH --context-file CTX
       sh ${PROG} --no-plugin-fits --plan-file PATH --question

Reads one plan as a JSON object from PATH, and prints the plan Markdown headed
by "## 🎯 Agent dispatch plan", ending in its Context section. PATH is required
in every mode; stdin is not read. CTX is required when printing a plan (either
kind) and refused with --question. It prints no gate marker; open-gate.sh adds it.

Input shape:
  {"agent": str, "mode": "BUILD"|"TEST", "technology": str,
   "tasks": [str, ...],
   "loaded": [{"plugin": str, "reason": str}, ...],
   "loaded_reason": str,
   "not_loaded": [{"plugin": str, "reason": str}, ...],
   "replan": "invalid"|"stop-recommended"}
Rules it checks (one stderr line per broken rule, exit 2):
  - exactly one JSON object, with no field other than those above; a plugin
    item has no field other than plugin and reason
  - a "string" below holds at least one character that is not a space or a
    control character
  - agent: a string; "${DIRECT_AGENT}" means direct implementation, which needs
    mode "BUILD" and technology "none"
  - mode: "BUILD" or "TEST"
  - technology: a string, the tech plugin's label or "none"
  - tasks: an array of one or more strings; one task is one dispatch, two or
    more a group
  - loaded, not_loaded: arrays, [] for none, of {"plugin", "reason"} strings
  - loaded_reason: a string, required when loaded is [] and refused otherwise
  - replan: optional; "invalid" or "stop-recommended"
Rules checked against the installed plugins, each problem printed as
"<path>: <what>; expected <x>":
  - every loaded and not_loaded plugin is installed; a not_loaded item whose
    reason is exactly "invalid", "uninstalled after approval" or "faulty
    files" may name a plugin list-plugins.sh no longer prints
  - no plugin is named twice across loaded and not_loaded
  - every installed plugin is in loaded or not_loaded
  - at most one tech plugin is loaded; technology is its label, or "none"
    when none is loaded
  - mode "TEST" has ${TESTING_PLUGIN} in loaded; mode "BUILD" doesn't
The installed plugins are the plugin lines of
DIR/${PROCEDURE}/scripts/list-plugins.sh --max-lines 0, run with
--skills-dir DIR; its stderr is passed through. Its exit 1 (no plugin) is an
empty list, and its exit 3 (invalid plugins) leaves them out of the list.
  DIR  the skills folder, as list-plugins.sh's --skills-dir; defaults to
       \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/skills.
Layout: a group prints "**Agent:** <agent> (<count>)" and a numbered task list.
Loaded [] prints "- none" with loaded_reason as its reason; not_loaded []
prints "- none"; a plugin named "none" prints as a bare none with its reason.
A control character in a value prints as a space.

The context file CTX, checked as inject-plugins.sh checks it, apart from the
digest the hook compares (the path checks are scripts/lib/context-file.sh and
the shape check scripts/lib/context-shape.jq, both beside this script). Before
it is opened, CTX must be absolute and hold no control character, no double
quote and no .. segment, and must not name a sensitive file in any letter
case (a basename .env*, *.pem, *.key or id_*, or a .git component). It must
be a readable regular file, not a symlink, of at most ${CONTEXT_MAX_BYTES} bytes,
holding exactly one JSON object
  {"paths": null | [{"path": str, "why": str}, ...],
   "links": null | [{"url": str, "why": str}, ...],
   "notes": [str, ...]}
with no other key in it or its entries; path absolute (starts with /), url
http:// or https:// with a host of letters, digits, dots and hyphens and an
optional :port, then optionally a path, query or fragment of letters, digits
and . _ ~ / ? # = % : + , @ - only (no space, quote, ; $ \` ( ) & | < or >),
why one non-empty line, notes may be []. No value, and not CTX, may hold, in
any letter case, "<crucible-context", "</crucible-context", "<untrusted-data",
"</untrusted-data" or the brief's closing line
"A marked gap beats a papered-over one:". Each problem prints as
"context file: <what>; expected <x>" (the shape problems at most 20, then a
count), exit 2; every line about a problem of CTX itself starts
"context file:", and no other line does. The plan ends with its Context
section, these groups in this order, each in file order and left out when
it has no entry:
  **Context** · \`<CTX basename>\` · sha256 \`<first 12 hex>\` · <P> files · <L> links · <N> notes
                     (a zero count is left out; 1 prints as "1 file")
  **Saved by Claude**  each path in CTX's own folder, as its basename
  **Tasks** · \`<list>\`  each other path ending /tasks/<list>/<n>.json, as
                     <n>.json; one group per list, in first-seen order
  **Files** · \`<root>/\`  every other path, relative to the folder they all
                     share, labelled by its last two segments; under a
                     shared / alone, or past 80 characters, the full path
                     with \$HOME as ~, its basename kept whole when it is
                     at most 78 characters
  **Links**            each url
  **Notes** · written by Claude from your words, so check these
                     each note in full, numbered 1., 2., ...
A path, task or link entry prints as "- <why>\\" then "  \`<shown>\`". Every
code span holds at most 80 characters: a longer text is cut in the middle to
its first 30, …, and its last 49. A backtick in a span prints as '. A control
character prints as a space.

--question --plans N prints the plan's AskUserQuestion fields instead, as one
JSON object to copy as is (no context is read):
  {"header": str, "question": str, "options": [{"label": str, "description": str}, ...]}
N is how many plans this run of step 6 shows, one after another (1 or more).
  - header "Dispatch", or "Dispatch ×<count>" for a group of <count> tasks
  - question: direct implementation, a group, or one dispatch, each with
    how to change the plugins ("Type something")
  - options: one plan, Approve (Recommended) / Stop; N > 1, Approve
    (Recommended) / Skip / Stop all; replan "stop-recommended", Stop
    (Recommended) / Approve
  - replan "invalid": prints nothing, exit 0 (the plan is shown, nothing asked)

--no-plugin-fits reads a part no installed tech plugin fits instead:
  {"stack": str, "files": [str, ...], "tasks": [str, ...]}
with no other field; each array holds one or more strings. It reads no
plugin list, and takes neither --plans nor --skills-dir. It prints a plan
headed by "## 🧩 No plugin fits": the stack, the files, the task or tasks, and
the line "No installed tech plugin fits this stack: the main thread would
write the code itself.", then the Context section. With --question it prints
the question JSON instead:
header "No plugin", options "Stop (Recommended)", then "Implement directly".

Every install or host fault, a missing or failing tool or shared file (the
exits 1, 3, 4, 5 and 6 below), prints one line starting
"${PROG}: install:", after any stderr of the failing tool;
no other line starts with it. A problem of the plan file or the arguments
starts with neither "install:" nor "context file:".

Exit codes:
  0  the plan or question printed (nothing for --question with replan "invalid")
  1  jq missing, or, when printing a plan, both sha256sum and shasum missing
  2  usage error (--plan-file or --context-file missing included), an
     unreadable plan or context file, or bad input (one stderr line per
     problem, nothing on stdout)
  3  jq failed while checking or rendering valid JSON, or wc or the sha256
     tool failed (its stderr is printed)
  4  list-plugins.sh missing from DIR
  5  scripts/lib/context-file.sh or context-shape.jq missing beside this
     script, when printing a plan
  6  list-plugins.sh failed with an exit other than 0, 1 or 3, such as 2
     (skills folder missing or unreadable); its stderr and exit are printed
The codes match render-plugin-line.sh's for list-plugins.sh.

Dependencies: POSIX sh, jq 1.6+ (\$ARGS, --slurpfile), wc; for a plan also
sha256sum or shasum (macOS: shasum -a 256) and scripts/lib/context-file.sh and
context-shape.jq; list-plugins.sh for a plan or its question.
Runtime: about 80 ms for a plan with 8 plugins installed, 70 ms for its question,
30 ms for --no-plugin-fits; measured on macOS (average of 5 runs).
EOF
}

warn() {
	printf '%s: %s\n' "${PROG}" "$1" >&2
}

# Prints an install or host fault (a missing or failing tool or shared file,
# never a problem of the input) with the "install:" prefix and exits $1.
install_fault() {
	warn "install: $2"
	exit "$1"
}

usage_error() {
	warn "$1"
	printf "Try '%s --help'.\n" "${PROG}" >&2
	exit 2
}

# Sets plan_file, context_file, skills_dir, want_question, no_plugin_fits and
# plans from the arguments, and refuses a combination the modes don't take.
parse_args() {
	plan_file=''
	context_file=''
	skills_dir="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/skills"
	skills_dir_given=0
	want_question=0
	no_plugin_fits=0
	plans=''
	while [ "$#" -gt 0 ]; do
		case $1 in
			--help | -h)
				usage
				exit 0
				;;
			--question)
				want_question=1
				shift
				;;
			--no-plugin-fits)
				no_plugin_fits=1
				shift
				;;
			--plan-file | --context-file | --plans | --skills-dir)
				[ "$#" -ge 2 ] && [ -n "$2" ] || usage_error "$1 needs a value; expected $1 VALUE"
				set_option "$1" "$2"
				shift 2
				;;
			*) usage_error "unknown argument: $1; expected --plan-file PATH, --context-file PATH, --skills-dir DIR, --question, --plans N, --no-plugin-fits or --help" ;;
		esac
	done
	[ -n "${plan_file}" ] || usage_error '--plan-file PATH missing; expected --plan-file PATH naming the JSON file; stdin is not read'
	check_context_arg
	if [ "${no_plugin_fits}" -eq 1 ]; then
		check_no_fit_args
	else
		check_plan_args
	fi
}

set_option() {
	case $1 in
		--plan-file) plan_file=$2 ;;
		--context-file) context_file=$2 ;;
		--plans) plans=$2 ;;
		*)
			skills_dir=$2
			skills_dir_given=1
			;;
	esac
}

# A plan shows its context; a question does not.
check_context_arg() {
	if [ "${want_question}" -eq 1 ]; then
		[ -z "${context_file}" ] ||
			usage_error '--context-file is not used with --question; expected it only when printing the plan'
	else
		[ -n "${context_file}" ] ||
			usage_error '--context-file PATH missing; expected --context-file PATH naming the effort'\''s context file, required when printing a plan'
	fi
}

check_no_fit_args() {
	[ -z "${plans}" ] || usage_error '--plans is not used with --no-plugin-fits; expected --no-plugin-fits --plan-file PATH --context-file CTX, or --no-plugin-fits --plan-file PATH --question'
	[ "${skills_dir_given}" -eq 0 ] ||
		usage_error '--skills-dir is not used with --no-plugin-fits; expected --no-plugin-fits --plan-file PATH --context-file CTX, or --no-plugin-fits --plan-file PATH --question'
}

check_plan_args() {
	if [ "${want_question}" -eq 1 ]; then
		case ${plans} in
			'') usage_error '--question needs --plans N; expected --question --plans N, N how many plans this run of step 6 shows, one after another' ;;
			*[!0-9]* | 0*) usage_error "--plans value '${plans}' is not a positive integer; expected --plans N such as 1 or 3" ;;
			*) ;;
		esac
	elif [ -n "${plans}" ]; then
		usage_error '--plans is used only with --question; expected --question --plans N'
	fi
}

# Prints the plan file slurped into one array, or exits 2 when it is
# unreadable or not JSON.
read_input() {
	[ -f "${plan_file}" ] && [ -r "${plan_file}" ] ||
		usage_error "plan file not readable: ${plan_file}; expected a readable JSON file"
	jq -s '.' "${plan_file}" </dev/null 2>/dev/null && return 0
	warn 'input is not valid JSON; expected one JSON object; try checking its quotes, commas and brackets, then rerun'
	exit 2
}

# Checks the context file as inject-plugins.sh does, apart from the digest,
# and sets context_digest to its sha256; exits 2 with one "context file:"
# stderr line per problem, or with an "install:" line 1 when no sha256 tool is
# on PATH, 3 when jq, wc or the tool fails, 5 when a shared check is missing.
read_context() {
	load_context_checks
	path_problem=$(context_path_problem "${context_file}")
	[ -z "${path_problem}" ] || context_error "${path_problem}: ${context_file}; expected ${context_path_expected}"
	[ ! -L "${context_file}" ] ||
		context_error "file is a symlink: ${context_file}; expected the regular file the main thread wrote"
	[ -f "${context_file}" ] && [ -r "${context_file}" ] ||
		context_error "file is missing, unreadable or not a regular file: ${context_file}; expected a readable regular JSON file"
	context_size=$(wc -c <"${context_file}") || install_fault 3 "wc could not count the bytes of ${context_file}; expected a byte count; check wc, then rerun"
	context_size=${context_size##* }
	[ "${context_size}" -le "${CONTEXT_MAX_BYTES}" ] ||
		context_error "file is ${context_size} bytes: ${context_file}; expected at most ${CONTEXT_MAX_BYTES} bytes, references and short notes rather than copied text"
	jq empty "${context_file}" </dev/null >/dev/null 2>&1 ||
		context_error "file is not valid JSON: ${context_file}; expected one JSON object; try checking its quotes, commas and brackets, then rerun"
	shape_report=$(jq -rs --arg context_path "${context_file}" -f "${shape_program}" "${context_file}" </dev/null) || {
		install_fault 3 'jq failed on the shape check; expected jq 1.6+; try jq --version, then rerun'
	}
	if [ -n "${shape_report}" ]; then
		printf '%s\n' "${shape_report}" | while IFS= read -r problem; do warn "context file: ${problem}"; done
		exit 2
	fi
	# shellcheck disable=SC2310 # its status is the tool's; a failure exits
	compute_context_digest "${context_file}" ||
		install_fault 3 "${context_digest_tool} could not hash ${context_file}; expected 64 hex digits; check the tool, then rerun"
}

# Sources the shared path checks, finds the shape check and the sha256 tool;
# exits 5 when a shared check is missing, 1 when no sha256 tool is on PATH.
load_context_checks() {
	context_lib=$(script_dir)/lib/context-file.sh
	shape_program=$(script_dir)/lib/context-shape.jq
	[ -f "${context_lib}" ] && [ -r "${context_lib}" ] ||
		install_fault 5 "shared path check missing; expected ${context_lib}; reinstall the ${PROCEDURE} skill"
	[ -f "${shape_program}" ] && [ -r "${shape_program}" ] ||
		install_fault 5 "shape check missing; expected ${shape_program}; reinstall the ${PROCEDURE} skill"
	# shellcheck source=lib/context-file.sh
	. "${context_lib}"
	# shellcheck disable=SC2310 # its status is the lookup result; errexit adds nothing
	find_context_digest_tool ||
		install_fault 1 'sha256sum and shasum missing; expected one of them on PATH; install coreutils (Linux) or use the system shasum (macOS)'
}

# Prints "context file: $1" on stderr and exits 2.
context_error() {
	warn "context file: $1"
	exit 2
}

# Prints the folder this script was run from (".", when run by a bare name).
script_dir() {
	case $0 in
		*/*) printf '%s' "${0%/*}" ;;
		*) printf '.' ;;
	esac
}

# Sets listing to list-plugins.sh's plugin lines, its stderr passed through;
# exits 4 when the script is missing and 6 when it fails.
read_listing() {
	list_script="${skills_dir}/${PROCEDURE}/scripts/list-plugins.sh"
	[ -f "${list_script}" ] && [ -r "${list_script}" ] ||
		install_fault 4 "list-plugins.sh missing; expected ${list_script}; install the ${PROCEDURE} skill or pass the right --skills-dir"
	if listing=$(sh "${list_script}" --max-lines 0 --skills-dir "${skills_dir}" </dev/null); then
		list_status=0
	else
		list_status=$?
	fi
	case ${list_status} in
		0 | 1 | 3) ;;
		*) install_fault 6 "list-plugins.sh failed (exit ${list_status}); expected exit 0, 1 or 3; fix what its stderr above names, or reinstall ${PROCEDURE}" ;;
	esac
}

# Runs jq program $1, after the common definitions, over the slurped input,
# with the context file read by jq itself (none for a question); a jq failure
# exits 3.
run_jq() {
	if [ -n "${context_file}" ]; then
		set -- "$1" --slurpfile context "${context_file}"
	else
		set -- "$1" --argjson context '[]'
	fi
	program=$1
	shift
	printf '%s' "${slurped}" | jq -rc --arg direct "${DIRECT_AGENT}" --arg testing "${TESTING_PLUGIN}" \
		--arg listing "${listing}" --argjson plans "${plans:-1}" "$@" \
		--arg context_file "${context_file}" --arg context_digest "${context_digest}" --arg home "${HOME:-}" \
		"${COMMON_JQ}${program}" || {
		install_fault 3 'jq failed on valid JSON; expected jq 1.6+; try jq --version, then rerun'
	}
}

parse_args "$@"
command -v jq >/dev/null 2>&1 ||
	install_fault 1 'jq missing; expected jq 1.6+ on PATH; try installing jq (macOS: brew install jq)'

# One slurped value so an empty file and several values are caught as one problem.
slurped=$(read_input)
context_digest=''
[ -z "${context_file}" ] || read_context
listing=''
if [ "${no_plugin_fits}" -eq 1 ]; then
	check_program=${NO_FIT_CHECK_JQ}
	render_program=${NO_FIT_RENDER_JQ}
	question_program=${NO_FIT_QUESTION_JQ}
else
	read_listing
	check_program=${CHECK_JQ}
	render_program=${RENDER_JQ}
	question_program=${QUESTION_JQ}
fi
problems=$(run_jq "${check_program}")
if [ -n "${problems}" ]; then
	printf '%s\n' "${problems}" | while IFS= read -r problem; do warn "${problem}"; done
	exit 2
fi
if [ "${want_question}" -eq 1 ]; then
	run_jq "${question_program}"
else
	run_jq "${render_program}"
fi
