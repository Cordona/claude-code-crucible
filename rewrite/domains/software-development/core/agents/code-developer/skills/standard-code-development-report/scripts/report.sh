#!/usr/bin/env sh
# Checks the developer's report JSON, stamps what its dispatch file knows into
# it on a pass, and renders it for the human (one developer's summary, or a
# run's over several reports). The jq
# validator below owns the report's shape (there is no schema file): the
# report standard's field table documents it, --help points there, the
# validator wins where they differ, and doc-check compares the table with it.
# The human views go through human-view's view.jq and paths.jq.
set -eu

readonly PROG='report.sh'
readonly RENDER_LIB='human-view'
readonly CRUCIBLE_SKILL='crucible'
readonly newline='
'
# A LABELS line names one language, its frameworks and a handful of standards
# and procedures, well under this; a bigger file is not the hand-back's line.
readonly MAX_LABELS_BYTES=1000
# Definitions the check and the render share: how git's changes compare with
# the report's files lists. $git and $baseline hold `git status --porcelain -z`
# output with each NUL turned into \u0001 ($have_git false when no repo was
# given); $baseline is the tree before the dispatch, and a path changed there
# (or under a folder it lists, ending in /) is left out of the comparison.
# A mismatch is counted as unlisted, never a problem: parallel dispatches
# share the tree. The programs are single-quoted on purpose: their $ signs are jq's.
# shellcheck disable=SC2016
readonly COMMON_JQ='
def git_label:
	if . == "??" then "created"
	elif . == "!!" then null
	elif startswith("A") then (if .[1:2] == "D" then null else "created" end)
	elif test("D") then "deleted"
	else "modified" end;
def status_entries: split("\u0001") | map(select(length > 3));
def baseline_paths: $baseline | status_entries | map(.[3:]);
def in_baseline($paths): . as $path | any($paths[]; . as $base | $path == $base or (($base | endswith("/")) and ($path | startswith($base))));
def all_git_changes: $git | status_entries | map({path: .[3:], label: (.[:2] | git_label)} | select(.label != null));
def git_changes: baseline_paths as $before | all_git_changes | map(select(.path | in_baseline($before) | not));
def listed_files:
	(.files // {}) as $files
	| if ($files | type) != "object" then []
	  else [("created", "modified", "deleted") as $label
		| ($files[$label] // []) | if type == "array" then .[] else empty end
		| strings | ltrimstr("./") | {path: ., label: $label}] end;
# $round_created: in a fix round, the paths an earlier round created and this
# round edited, still untracked or added (each ending in \u0001); git shows
# them created, and the report may list them created or modified.
def label_matches($change; $round_created):
	.label == $change.label or ($change.label == "created" and .label == "modified" and ($change.path | IN($round_created[])));
def file_mismatches:
	if $have_git | not then []
	else git_changes as $changes
		| baseline_paths as $before
		| ($round_created | split("\u0001") | map(select(length > 0))) as $round_created_paths
		| [listed_files[] | select(.path | in_baseline($before) | not)] as $listed
		| [($changes[] | . as $change
			| [$listed[] | select(.path == $change.path)] as $matches
			| if ($matches | length) == 0 then {path: $change.path, note: null}
			  elif any($matches[]; label_matches($change; $round_created_paths)) then empty
			  else {path: $change.path, note: "listed as \($matches[0].label), git shows \($change.label)"} end),
		   ($listed[] | . as $entry | select(any($changes[]; .path == $entry.path) | not)
			| {path: $entry.path, note: "listed as \($entry.label), git shows no change"})]
	end;
def objects_of($key): .[$key] | if type == "array" then map(select(type == "object")) else [] end;
def open_of($kind): [objects_of("open")[] | select(.kind == $kind)];
'

# The stamp shapes, from flow-agent-initialization's dispatch-names.jq (-L its
# folder): the dispatch stamp is a Crucible ID, started and finished local times.
readonly STAMP_JQ='include "dispatch-names";
def stamp_id_ok: type == "string" and test(crucible_id_pattern);
def stamp_time_ok: type == "string" and test(local_time_pattern);
'

# The shape check, which check prints and render shows: `problems` is an array
# of "<field>: <what>; expected <x>" lines. Every value taken from the report
# goes through `shown`, so a problem line never holds a newline. $findings_mode
# is "given" (a fix round, IDs in $findings_text), "none" (review_responses is
# refused) or "unchecked" (render, which has no findings file).
# shellcheck disable=SC2016
readonly SHAPE_JQ='
# One sentence or a path:line with context fits; more is copied text, not a report.
def max_text: 200;
# One sentence: what changed, never the diff file by file.
def max_words: 25;
# Enough for every field of a full report; more lines would bury the fix.
def max_problems: 30;
# Each list holds what a reader acts on, not everything seen:
#   behavior 8: the cases a reviewer and a TEST dispatch need, not every input
#   focus 3: the riskiest spots; a longer list stops being a priority
#   decisions 8: room for the entries the standard plugins each require there
#   noticed 5: side findings, outside the task, kept short so they stay read
#   open 6: the gaps a human can follow up in one pass
def caps: {behavior: 8, focus: 3, decisions: 8, noticed: 5, open: 6};
def uncapped_kinds: ["instruction_found", "secret_found"];
def required_keys: ["summary", "toolchain", "files", "deviations", "behavior", "verification"];
def optional_keys: ["focus", "decisions", "noticed", "open", "blockers", "review_responses"];
def reserved_keys: ["untested", "repaired", "mutation"];
def never_written_keys: ["round", "labels", "LABELS"];
# The keys check --dispatch writes into the report on a pass; the agent never
# does. plugins is left out when the dispatch loaded no plugin.
def stamp_keys: ["dispatch", "started", "finished", "mode", "plugins"];
def required_stamp_keys: stamp_keys - ["plugins"];
def plugin_kinds: ["language", "frameworks", "standards", "procedures"];
def item_fields: {
	deviations: {required: ["from", "what", "why"], optional: []},
	behavior: {required: ["what", "at", "checked"], optional: ["guard", "fix"]},
	verification: {required: ["gate", "result"], optional: ["command", "note"]},
	focus: {required: ["at", "question"], optional: []},
	decisions: {required: ["choice", "why"], optional: ["commit"]},
	noticed: {required: ["at", "what"], optional: []},
	open: {required: ["kind", "text"], optional: ["at", "ref"]},
	blockers: {required: ["kind", "location", "detail"], optional: []},
	review_responses: {required: ["id", "status"], optional: ["note"]}};
def enums: {
	"behavior.guard": ["security", "persisted_data", "concurrency", "auth"],
	"verification.gate": ["format", "lint", "typecheck", "test", "build", "scan", "manual"],
	"verification.result": ["pass", "fail", "not_run", "narrowed"],
	"open.kind": ["assumption", "could_not", "missing_plugin", "instruction_found", "secret_found", "contract_break", "gate_refused"],
	"blockers.kind": ["test_compile_broken", "gate_red", "finding_blocked", "code_untestable", "tests_red_before_refactor", "request_unclear"],
	"review_responses.status": ["fixed", "not_fixed", "blocked"]};
def bool_fields: ["behavior.checked", "behavior.fix"];
def location_fields: ["behavior.at", "focus.at", "noticed.at", "open.at", "blockers.location"];

def among($list): . as $value | any($list[]; . == $value);
def names: join(", ");
# A quoted value is cut at 60 characters so a problem line stays one readable line.
def shown: tojson | if length > 60 then .[:60] + "…" else . end;
def text_ok: type == "string" and test("[^[:space:]]");
def absolute: startswith("/") or startswith("~") or test("^[A-Za-z]:[\\\\/]");
def word_count: [splits("[[:space:]]+") | select(length > 0)] | length;
# The &&, || and ; a shell command holds outside quotes and backslash escapes,
# so a quoted awk or jq program, or the \; of find -exec, is not taken for a chain.
def chain_operators:
	gsub("\\\\.|\u0027[^\u0027]*\u0027|\"(\\\\.|[^\"\\\\])*\""; "") as $bare
	| [("&&", "||", ";") | select(. as $operator | $bare | contains($operator))
		| if . == ";" then "a semicolon" else . end];
def context_positions: "paths[<n>], links[<n>] or notes[<n>], counted from 1";
def location_expected: "a repo-relative path:line, message: <FIELD>, a plugin name and file, a context entry (\(context_positions), or its URL) or commit <sha>";

def expected($name):
	if enums[$name] then "one of \(enums[$name] | names)"
	elif $name | among(bool_fields) then "true or false"
	elif $name | among(location_fields) then "\(location_expected), at most \(max_text) characters"
	else "a non-empty string of at most \(max_text) characters" end;
def value_problem($name):
	if enums[$name] then (if type == "string" and among(enums[$name]) then empty else "\(shown) is not a known value" end)
	elif $name | among(bool_fields) then (if type == "boolean" then empty else "a JSON \(type)" end)
	elif text_ok | not then (if type == "string" then "empty" else "a JSON \(type)" end)
	elif length > max_text then "\(length) characters"
	elif ($name | among(location_fields)) and absolute then "an absolute path"
	else empty end;
def field_line($loc; $name): value_problem($name) | "\($loc): \(.); expected \(expected($name))";

def cross_problems($list; $loc):
	if $list == "verification" then
		(if .result == "pass" and (has("command") | not) then "\($loc).command: missing on a pass; expected the command as run" else empty end),
		(if (.result | among(enums["verification.result"])) and .result != "pass" and (has("note") | not)
		 then "\($loc).note: missing on result \(.result); expected why it did not pass (for narrowed, the words of the first message quoted and the coverage given up)" else empty end),
		(.command | strings | chain_operators | select(length > 0)
		 | "\($loc).command: chains commands with \(join(" and ")); expected one command per item")
	elif $list == "open" and .kind == "could_not" and (has("ref") | not) then
		"\($loc).ref: missing on kind could_not; expected the context entry it names"
	elif $list == "review_responses" and .status == "not_fixed" and (has("note") | not) then
		"\($loc).note: missing on not_fixed; expected why it was not fixed"
	else empty end;
def item_problems($list):
	item_fields[$list] as $spec
	| .[$list] | to_entries[] | .key as $index | .value | "\($list)[\($index)]" as $loc
	| if type != "object" then "\($loc): a JSON \(type); expected an object with \($spec.required | names)"
	  else . as $item
		| ((keys - $spec.required - $spec.optional)[] | "\($loc).\(shown): unknown key; expected only \($spec.required + $spec.optional | names)"),
		  ($spec.required[] as $field
			| if $item | has($field) then $item[$field] | field_line("\($loc).\($field)"; "\($list).\($field)")
			  else "\($loc).\($field): missing; expected \(expected("\($list).\($field)"))" end),
		  ($spec.optional[] as $field | select($item | has($field))
			| $item[$field] | field_line("\($loc).\($field)"; "\($list).\($field)")),
		  cross_problems($list; $loc)
	  end;

def key_problems:
	(required_keys + optional_keys) as $known
	| ((keys - $known - stamp_keys)[] as $key
		| if $key | among(reserved_keys) then "\($key): reserved for the TEST mode; expected it left out on BUILD"
		  elif $key | among(never_written_keys) then "\($key): written into the report; expected it left out: never write round or LABELS (the script stamps the round into the render, and LABELS comes from the hand-back)"
		  else "\($key | shown): unknown key; expected only \($known | names)" end),
	  (required_keys[] as $key | select(has($key) | not) | "\($key): missing; expected the key, as the report standard\u0027s field table shows");
# check ($stamp_check "check") refuses every stamp key a report holds: the flow
# checks a report before stamping it and never checks a stamped one again, so a
# stamp key at a check was written by the agent. render ("render") takes the
# set (plugins optional) when each key has the shape of a stamp, and refuses a
# part set.
def stamp_rule: "the agent never writes \(stamp_keys | names); report.sh check --dispatch stamps them on a pass, and a stamped report is never checked again";
def plugin_names_ok($kind):
	if $kind == "language" then text_ok
	else type == "array" and length > 0 and all(.[]; text_ok) end;
def plugins_stamp_ok:
	type == "object" and length > 0
	and all(to_entries[]; .key as $kind | ($kind | among(plugin_kinds)) and (.value | plugin_names_ok($kind)));
def stamp_shape_problems:
	(if has("plugins") | not then empty
	 elif .plugins | plugins_stamp_ok then empty
	 else "plugins: \(.plugins | shown) is not a stamp; expected the dispatch\u0027s plugin names by kind, {\"language\": name, \"frameworks\": [names], \"standards\": [names], \"procedures\": [names]}, empty kinds left out" end),
	(if .mode | text_ok then empty else "mode: \(.mode | shown) is not a stamp; expected the dispatch mode" end),
	(if .dispatch | stamp_id_ok then empty else "dispatch: \(.dispatch | shown) is not a stamp; expected the dispatch Crucible ID" end),
	(("started", "finished") as $key | select(.[$key] | stamp_time_ok | not)
		| "\($key): \(.[$key] | shown) is not a stamp; expected YYYY-MM-DDTHH:MM:SS+HH:MM");
def stamp_problems:
	. as $report
	| [stamp_keys[] | select(. as $key | $report | has($key))] as $present
	| if ($present | length) == 0 then empty
	  elif $stamp_check == "render" and all(required_stamp_keys[]; among($present)) then stamp_shape_problems
	  else $present[] | "\(.): written into the report; expected it left out: \(stamp_rule)" end;

# A stamped report was written through prune, which left out a required key
# that held only empty lists; render reads such a key as empty again.
def as_written:
	if $stamp_check == "render" and type == "object" and (. as $report | all(required_stamp_keys[]; . as $key | $report | has($key)))
	then {files: {created: [], modified: [], deleted: []}, deviations: []} * .
	else . end;

def summary_problems:
	if has("summary") | not then empty
	elif .summary | text_ok | not then "summary: not a non-empty string; expected what changed, in at most \(max_words) words"
	elif (.summary | word_count) > max_words then "summary: \(.summary | word_count) words; expected at most \(max_words)"
	else empty end;
def toolchain_problems: select(has("toolchain")) | .toolchain | field_line("toolchain"; "toolchain");
def file_path_problems($loc):
	(if type == "string" and absolute then "an absolute path"
	 elif type == "string" and (split("/") | any(. == "..")) then "outside the repo (a .. segment)"
	 else value_problem("files") end)
	| "\($loc): \(.); expected a repo-relative path of at most \(max_text) characters";
def files_problems:
	if has("files") | not then empty
	elif (.files | type) != "object" then "files: a JSON \(.files | type); expected {\"created\": [...], \"modified\": [...], \"deleted\": [...]}"
	else .files as $files
		| (($files | keys - ["created", "modified", "deleted"])[]
			| "files.\(shown): unknown key; expected only created, modified and deleted"),
		  (("created", "modified", "deleted") as $label
			| if $files | has($label) | not then "files.\($label): missing; expected an array of repo-relative paths ([] when none)"
			  elif ($files[$label] | type) != "array" then "files.\($label): a JSON \($files[$label] | type); expected an array of repo-relative paths ([] when none)"
			  else $files[$label] | to_entries[] | .key as $index | .value | file_path_problems("files.\($label)[\($index)]") end),
		  ([("created", "modified", "deleted") as $label | $files[$label] | arrays | .[] | strings | ltrimstr("./")]
			| group_by(.)[] | select(length > 1)
			| "files: \(.[0] | shown) listed \(length) times; expected each path once, in one list")
	end;
def list_problems($key):
	if has($key) | not then empty
	elif (.[$key] | type) != "array" then "\($key): a JSON \(.[$key] | type); expected an array of objects"
	else
		(if (.[$key] | length) == 0 and ($key | among(optional_keys)) then "\($key): empty; expected the key left out when it has no item" else empty end),
		(caps[$key] as $cap | select($cap != null)
			| [.[$key][] | select($key != "open" or (type != "object" or (.kind | among(uncapped_kinds) | not)))] | length
			| select(. > $cap)
			| "\($key): \(.) items\(if $key == "open" then " (instruction_found and secret_found not counted)" else "" end); expected at most \($cap)"),
		item_problems($key)
	end;
def minimum_problems:
	(if $mode == "BUILD" and (.behavior | type) == "array" and (.behavior | length) == 0 then "behavior: empty; expected at least one item on BUILD" else empty end),
	(if (.verification | type) == "array" and (.verification | length) == 0 then "verification: empty; expected at least one gate" else empty end);

def findings_list:
	$findings_text | split("\n") | map(sub("\r$"; "") | sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; "") | select(length > 0))
	| reduce .[] as $id ([]; if any(.[]; . == $id) then . else . + [$id] end);
def token_char: test("^[A-Za-z0-9_-]$");
# True when $id appears in the input as a whole token, not inside a longer one.
def names_token($id):
	($id | length) > 0 and (split($id) as $parts
		| any(range(0; ($parts | length) - 1);
			($parts[.] | length == 0 or (.[-1:] | token_char | not))
			and ($parts[. + 1] | length == 0 or (.[:1] | token_char | not))));
def findings_problems:
	if $findings_mode == "unchecked" then empty
	elif $findings_mode == "none" then
		(if has("review_responses") then "review_responses: given with no findings; expected it left out (only a check run with --findings takes it)" else empty end)
	elif has("review_responses") | not then
		"review_responses: missing on a fix round; expected one item per finding ID given: \(findings_list | names)"
	elif (.review_responses | type) != "array" then empty
	else findings_list as $findings
		| .blockers as $blockers
		| [.review_responses[] | objects | .id | strings] as $ids
		| ($findings[] as $id | [$ids[] | select(. == $id)] | length
			| if . == 0 then "review_responses: \($id | shown) missing; expected each finding ID given exactly once"
			  elif . > 1 then "review_responses: \($id | shown) given \(.) times; expected it exactly once"
			  else empty end),
		  ($ids | unique[] | select(among($findings) | not)
			| "review_responses: \(shown) is not a finding ID given; expected only \($findings | names)"),
		  (.review_responses | to_entries[] | .key as $index | .value
			| select(type == "object" and .status == "blocked" and (.id | type) == "string") | .id as $id
			| select([$blockers | arrays | .[] | objects | select(.kind == "finding_blocked" and (.detail | type) == "string" and (.detail | names_token($id)))] | length == 0)
			| "review_responses[\($index)]: \($id | shown) is blocked but in no blockers item; expected a blockers item of kind finding_blocked whose detail names \($id | shown) as a whole word")
	end;

def context_refs:
	($context.paths // [] | arrays) as $paths
	| ($context.links // [] | arrays) as $links
	| ($context.notes // [] | arrays) as $notes
	| [($paths[] | objects | .path | strings), ($links[] | objects | .url | strings),
	   ($paths | keys[] | "paths[\(. + 1)]"), ($links | keys[] | "links[\(. + 1)]"), ($notes | keys[] | "notes[\(. + 1)]")];
def context_problems:
	if $context == null or (.open | type) != "array" then empty
	else context_refs as $refs
		| .open | to_entries[] | .key as $index | .value
		| select(type == "object" and .kind == "could_not" and (.ref | type) == "string" and (.ref | among($refs) | not))
		| "open[\($index)].ref: \(.ref | shown) names no context entry; expected a paths[].path or links[].url of the context file, or \(context_positions)"
	end;

def count_line:
	"blockers=\(objects_of("blockers") | length) instruction_found=\(open_of("instruction_found") | length) secret_found=\(open_of("secret_found") | length) missing_plugin=\(open_of("missing_plugin") | length) could_not=\(open_of("could_not") | length) deviations=\(objects_of("deviations") | length) unlisted=\(file_mismatches | length)";

def all_problems:
	[key_problems, stamp_problems, summary_problems, toolchain_problems, files_problems,
	 (("deviations", "behavior", "verification", "focus", "decisions", "noticed", "open", "blockers", "review_responses") as $key | list_problems($key)),
	 minimum_problems, findings_problems, context_problems];
def problems:
	all_problems
	| .[:max_problems] + (if length > max_problems then ["report: \(length - max_problems) more problems not shown (showing \(max_problems) of \(length)); expected none"] else [] end);
'

# Prints the count line, then the shape problems, one per line.
# shellcheck disable=SC2016
readonly CHECK_JQ='
$report[0] | count_line, problems[]
'

# The stamped report check --dispatch writes: the stamps, then the report's
# keys in key_order (a key the validator does not know, which a passing report
# never holds, after them), every key holding nothing left out.
# shellcheck disable=SC2016
readonly STAMPED_REPORT_JQ='
include "prune";
def key_order: ["dispatch", "started", "finished", "mode", "plugins", "toolchain", "summary", "files", "behavior",
	"verification", "deviations", "decisions", "focus", "noticed", "open", "blockers", "review_responses"];
(. + $stamps + {finished: $finished}) as $report
| reduce (key_order[], ($report | keys_unsorted[] | select(IN(key_order[]) | not))) as $key
	({}; if $report | has($key) then .[$key] = $report[$key] else . end)
| prune
'

# A fix round's baseline, which `baseline` writes and check and render read:
#   {"repo_root": <the repo>, "entries": [<git status entry, "XY <path>">, ...],
#    "fingerprints": {"<path>": <git hash-object of it>, ...}}
# A path has a fingerprint when it was a regular file at the time; a deleted
# one has none. Prints one "<field> <problem>; expected <x>" line per way the
# input differs from that shape for repo root $repo_root.
# shellcheck disable=SC2016
readonly ROUND_BASELINE_JQ='
def round_baseline_keys: ["repo_root", "entries", "fingerprints"];
def round_baseline_problems($repo_root):
	if type != "object" then "a JSON \(type); expected an object with \(round_baseline_keys | join(", "))"
	else ((keys - round_baseline_keys)[] | "\(tojson): unknown field; expected only \(round_baseline_keys | join(", "))"),
		(round_baseline_keys[] as $key | select(has($key) | not) | "\($key) missing; expected every one of \(round_baseline_keys | join(", "))"),
		(select(has("repo_root")) | if .repo_root == $repo_root then empty
		 else "repo_root \(.repo_root | tojson) is not --repo; expected \($repo_root | tojson)" end),
		(select(has("entries")) | if (.entries | type) == "array" and all(.entries[]; type == "string" and length > 3 and (contains("\u0001") | not)) then empty
		 else "entries is not an array of git status entries; expected [\"XY <path>\", ...] ([] for a clean tree)" end),
		(select(has("fingerprints")) | if (.fingerprints | type) == "object" and all(.fingerprints[]; type == "string" and test("\\A[0-9a-f]{40}([0-9a-f]{24})?\\z")) then empty
		 else "fingerprints is not an object of git object IDs; expected {\"<path>\": \"<40 or 64 hex digits>\", ...}" end)
	end;
'

# The comparison's inputs for a fix round, from its baseline ($round), the
# fingerprints of its paths now ($now) and the git status now ($git, entries
# joined by \u0001). $part "unchanged" prints the baseline entries the round
# left alone (the same status line, and the same fingerprint or none both
# times), which COMMON_JQ leaves out like a dispatch baseline's; "reverted"
# prints an entry for each baseline path git no longer lists, labelled as the
# change the round made to put it back; "created" prints the paths an earlier
# round created that git still shows created and this round changed (each
# ending in \u0001), which the report may list as created or modified. A file
# changed again in the round has a new fingerprint, so it is compared like
# any other change.
# shellcheck disable=SC2016
readonly ROUND_COMPARE_JQ='
def entry_path: .[3:];
def entries_of: split("\u0001") | map(select(length > 3));
def set_of(f): map({(f): true}) | add // {};
def created_status: . == "??" or startswith("A");
($git | entries_of) as $current
| ($current | set_of(.)) as $current_lines
| ($current | set_of(entry_path)) as $current_paths
| $round.fingerprints as $then
| if $part == "unchanged" then
	[$round.entries[] | select($current_lines[.] and $then[entry_path] == $now[entry_path]) | ., "\u0001"]
  elif $part == "reverted" then
	[$round.entries[] | select($current_paths[entry_path] | not) | .[:2] as $status
		| (if $status | created_status then " D "
		   elif $status | test("D") then "?? "
		   else " M " end) + entry_path, "\u0001"]
  else
	($current | map({(entry_path): .[:2]}) | add // {}) as $current_status
	| [$round.entries[] | entry_path as $path
		| select((.[:2] | created_status) and ($current_status[$path] // "" | created_status) and $then[$path] != $now[$path])
		| $path, "\u0001"]
  end
| add // ""
'

# Turns the paths in the input, each ending in \001, into git hash-object
# --stdin-paths lines. A path git would misread as a line (one holding a line
# feed or carriage return, or starting with a double quote) is C-quoted, as
# git unquotes it; every other path goes as is, byte for byte.
# The program is single-quoted on purpose: its $0 is awk's, not the shell's.
# shellcheck disable=SC2016
readonly STDIN_PATHS_AWK='
function c_quoted(path,    quoted, i, char) {
	quoted = ""
	for (i = 1; i <= length(path); i++) {
		char = substr(path, i, 1)
		if (char == "\\") char = "\\\\"
		else if (char == "\"") char = "\\\""
		else if (char == "\n") char = "\\n"
		else if (char == "\r") char = "\\r"
		quoted = quoted char
	}
	return "\"" quoted "\""
}
BEGIN { RS = "\001" }
{ if ($0 ~ /[\n\r]/ || substr($0, 1, 1) == "\"") print c_quoted($0); else print }
'

# doc-check: compares the report standard's text ($doc) with the definitions
# above, so the field table is checked against the validator, not against a
# second list. A field-table row is a line starting "| `<key>`"; its Key cell
# runs to the next |; a value is named when it is a backticked token. Each
# output line is one difference, so a reworded table never passes.
# shellcheck disable=SC2016
readonly DOC_CHECK_JQ='
def doc_lines: $doc | split("\n") | map(sub("\r$"; ""));
def identifiers: [scan("`([^`]*)`")[0] | select(test("^[a-z][a-z0-9_]*$"))] | unique;
def quoted: "`\(.)`";
def known_keys: required_keys + optional_keys;
def table_rows:
	[doc_lines[] | select(test("^\\|[[:space:]]*`[a-z_]+`"))
		| {key: capture("^\\|[[:space:]]*`(?<key>[a-z_]+)`").key, cell: capture("^\\|(?<cell>[^|]*)").cell, line: .}];
def row_enums($key): enums | to_entries | map(select(.key | startswith("\($key).")));
# What a row may name in backticks: its own key and item fields, the other
# report keys, the stamp keys, true and false, and the values of its enums.
def allowed($key):
	[$key, "true", "false"] + known_keys + stamp_keys
	+ (item_fields[$key] // {required: [], optional: []} | .required + .optional)
	+ (if $key == "files" then ["created", "modified", "deleted"] else [] end)
	+ [row_enums($key)[].value[]];
def missing_and_extra($named; $expected; $where; $what):
	($expected - $named | .[] | "\($where): \(quoted) is \($what) in the validator; the text does not name it"),
	($named - $expected | .[] | "\($where): \(quoted) is named; the validator has no such \($what)");

def required_difference:
	(.cell | test("\\(required")) as $says
	| (.key | among(required_keys)) as $is
	| if $is and ($says | not) then "\(.key | quoted) row: required in the validator; its Key cell does not say (required"
	  elif $says and ($is | not) then "\(.key | quoted) row: optional in the validator; its Key cell says (required"
	  else empty end;
# The cap is the largest number in the Key cell (behavior: 1-8 items).
def cap_difference:
	caps[.key] as $cap
	| [.cell | scan("[0-9]+") | tonumber] as $numbers
	| (if ($numbers | length) == 0 then null else $numbers | max end) as $named
	| if $named == $cap then empty
	  else "\(.key | quoted) row: the validator caps it at \($cap // "no number"); its Key cell names \($named // "no number")" end;
# An item field is named as `f` or `f: <value>`, and called required when
# "(required" follows its token or "required " comes right before it.
def names_field($field): any(.[]; . == $field or startswith("\($field): "));
def calls_required($field): test("`\($field)(: [^`]*)?`[[:space:]]*\\(required|required[[:space:]]+`\($field)(: [^`]*)?`");
def item_differences:
	.key as $key
	| .line as $line
	| [$line | scan("`([^`]*)`")[0]] as $tokens
	| item_fields[$key] // empty
	| ((.required + .optional)[] | select(. as $field | $tokens | names_field($field) | not)
		| "\($key | quoted) row: \(quoted) is an item field in the validator; the row does not name it"),
	  (.optional[] | select(. as $field | ($tokens | names_field($field)) and ($line | calls_required($field)))
		| "\($key | quoted) row: \(quoted) is optional in the validator; the row calls it required"),
	  (.required[] | select(. as $field | ($tokens | names_field($field)) and ($line | calls_required($field) | not))
		| "\($key | quoted) row: \(quoted) is required in the validator; the row does not call it required");
def row_differences:
	.key as $key
	| (.line | identifiers) as $named
	| required_difference,
	  cap_difference,
	  missing_and_extra(.cell | identifiers - [$key]; if $key == "open" then uncapped_kinds else [] end; "\($key | quoted) Key cell"; "an uncapped kind"),
	  (row_enums($key)[] as $enum | $enum.value - $named | .[] | "\($enum.key): \(quoted) is a value in the validator; the \($key | quoted) row does not name it"),
	  ($named - allowed($key) | .[] | "\($key | quoted) row: \(quoted) is named; the validator has no such value, field or key"),
	  (if $key == "summary" and (.line | contains("\(max_words) words") | not) then "`summary` row: the validator caps it at \(max_words) words; the row does not say \"\(max_words) words\"" else empty end),
	  item_differences;

def table_differences:
	table_rows as $rows
	| ($rows | map(.key)) as $row_keys
	| (known_keys[] | select(among($row_keys) | not) | "\(quoted): a key in the validator; no field-table row names it"),
	  ($rows[] | select(.key | among(known_keys) | not) | "\(.key | quoted): a field-table row; the validator has no such key"),
	  ($row_keys | group_by(.)[] | select(length > 1) | "\(.[0] | quoted): \(length) field-table rows; expected one"),
	  ($rows | unique_by(.key)[] | select(.key | among(known_keys)) | row_differences);
def stamp_differences:
	[doc_lines[] | select(ascii_downcase | contains("stamped keys"))] as $lines
	| if ($lines | length) == 0 then "stamp keys: no line says \"Stamped keys\"; expected one naming \(stamp_keys | map(quoted) | names)"
	  else missing_and_extra($lines[0] | identifiers; stamp_keys; "Stamped keys line"; "a stamp key") end;
def text_differences:
	if $doc | contains("at most \(max_text) characters") then empty
	else "text cap: the validator caps a text value at \(max_text) characters; the text does not say \"at most \(max_text) characters\"" end;

table_differences, stamp_differences, text_differences
'

# Text helpers. Tolerant of a broken shape, since the main thread renders an
# invalid report once the resends run out: its problems show as report
# problems, a value of the wrong type prints as its JSON, a list of the wrong
# type as no items.
# shellcheck disable=SC2016
readonly RENDER_JQ='
def txt: if type == "string" then . elif . == null then "" else tojson end
	| gsub("[[:cntrl:]]+"; " ") | sub("^ +"; "") | sub(" +$"; "");
def bare: txt | sub("[.]+$"; "");
# A command shown inside prose is cut in the middle past 80 characters, the
# home folder as ~ (paths.jq); the report file holds it whole.
def short_text: txt | short_path($home);
def span: short_text | code_span;
# A location in the repo-relative path:line form; the other forms (an absolute
# or ~ path, message:, commit, a context ref, a URL, a plugin name and file) are
# not in the repo.
def in_repo_form: (startswith("/") or startswith("~")
	or test("^(message: |commit |(paths|links|notes)\\[)") or contains("://")
	or test("^(language|framework|standard|procedure)-[a-z0-9-]+([ :/]|$)")) | not;
# A location as the human may open it: a repo-relative one joined to repo root
# $root, every one whole, never cut or shortened.
def whole_location($root): txt
	| if $root != "" and in_repo_form then ($root | rtrimstr("/")) + "/" + ltrimstr("./") else . end
	| link_span;
'

# The human views, laid out with human-view's view.jq: the developer summary
# of one report, and the run summary of several. Needs you holds what the
# human acts on, by kind in a fixed order; every kind is cut to its first items
# so the view stays one screen, and the report file holds the rest.
# shellcheck disable=SC2016
readonly VIEW_JQ='
def item_cap: 160;
def kind_cap: 5;
def cut($limit): if length > $limit then .[:($limit - 1)] + "…" else . end;
# A location, whole (joined to repo root $root when repo-relative), then the
# text, cut so the item fits item_cap; the location is never cut, and a long
# one still leaves the text 40 characters.
def item($at; $text; $root):
	(if ($at | txt) == "" then "" else "\($at | whole_location($root)): " end) as $lead
	| $lead + ($text | txt | cut([item_cap - ($lead | length), 40] | max));
# A gate that failed without blocking: short, its command shown for recognition.
def failed_gate: "check failed: \(.gate | txt | cut(40))" + (if (.command | txt) == "" then "" else " (\(.command | span))" end);
# The summary as shown; "" for a report whose summary is not a string.
def summary_text: .summary | if type == "string" then txt else "" end;
def noted($label; $text): if ($text | txt) == "" then $label else "\($label): \($text | txt)" end;

# Each kind: its singular and plural heading, what follows its cut list,
# whether it is uncapped, and its items.
def needs_groups($problems; $root):
	[{one: "Report problem", many: "Report problems", rest: "more",
	  items: [$problems[] | item(null; .; $root)]},
	 {one: "Blocked", many: "Blocked", blocked: true,
	  items: [objects_of("blockers")[] | item(.location; .detail; $root)]},
	 {one: "Instruction found", many: "Instructions found", uncapped: true,
	  items: [open_of("instruction_found")[] | item(.at; .text; $root)]},
	 {one: "Secret found", many: "Secrets found", uncapped: true,
	  items: [open_of("secret_found")[] | item(.at; .text; $root)]},
	 {one: "Deviation", many: "Deviations",
	  items: [objects_of("deviations")[] | item(null; (.what | bare) + (if (.why | txt) == "" then "" else " (\(.why | bare))" end); $root)]
		+ [open_of("gate_refused")[] | item(.at; noted("gate kept"; .text); $root)]
		+ [open_of("contract_break")[] | item(.at; noted("contract break"; .text); $root)]
		+ [objects_of("review_responses")[] | select(.status == "not_fixed") | item(null; noted("\(.id | txt) not fixed"; .note); $root)]
		+ [objects_of("verification")[] | select(.result == "fail") | failed_gate]},
	 {one: "Assumption", many: "Assumptions",
	  items: [open_of("assumption")[] | item(null; .text; $root)]},
	 {one: "Not read or not done", many: "Not read or not done",
	  items: [open_of("could_not")[] | item(.ref // .at; .text; $root)]},
	 {one: "Missing plugin", many: "Missing plugins",
	  items: [open_of("missing_plugin")[] | item(.at; .text; $root)]},
	 {one: "Noticed", many: "Noticed",
	  items: [objects_of("noticed")[] | item(.at; .what | bare; $root)]
		+ [file_mismatches[] | item(.path; .note // "changed, not in the report"; $root)]}];
def item_count: map(.items | length) | add // 0;
# $spec is the kind: an uncapped one (the report standard never caps
# instructions or secrets found) lists every item.
def kind_section($name; $plural; $items; $spec):
	($items | length) as $count
	| (if $spec.uncapped then $count else kind_cap end) as $cap
	| section($name; $plural; $items[:$cap])
	  + (if $count > $cap then "\n+\($count - $cap) \($spec.rest // "more in the report")" else "" end);
def need_tail($count; $blocked):
	if $count == 0 then ""
	elif $count == 1 then (if $blocked then "needs you" else "1 item needs you" end)
	else "\($count) items need you" end;

def is_blocked: objects_of("blockers") | length > 0;
def file_counts:
	listed_files as $files
	| [["created", "Created"], ["modified", "Modified"], ["deleted", "Deleted"]]
	| map(.[0] as $label | [.[1], ([$files[] | select(.label == $label)] | length)]);
def changed_count: map(.[1]) | add;

def developer_view($problems; $title; $repo; $path):
	needs_groups($problems; $repo) as $groups
	| ($groups | item_count) as $count
	| is_blocked as $blocked
	| file_counts as $counts
	| [status_line(if $blocked then "blocked" elif $count > 0 then "attention" else "done" end;
		"\($title | txt) · \(if $blocked then "blocked" else "done" end)"; need_tail($count; $blocked)),
	   (if $blocked and ($counts | changed_count) == 0 then "" else section("Achieved"; [summary_text | select(. != "")]) end),
	   (if $count == 0 then "" else "**Needs you**" end),
	   ($groups[] | kind_section(.one; .many; .items; .)),
	   field_section("**Files**" + (if $repo == "" then "" else " · repo \($repo | txt | link_span)" end); $counts),
	   data_section([["Report", $path | txt]])]
	| blocks;

def repos_text($count): "\($count) repo\(if $count == 1 then "" else "s" end)";
# Each dispatch is one developer, its reports in round order. Two dispatches
# of one title are told apart by their order: Shell script developer 1, Shell
# script developer 2. A fix round report carries the round summary was given
# for it: Shell script developer 1 · fix 1. Its Needs-you items carry the
# same title, so each reads with its round.
def round_label: if .round == null then "" else " · \(.round | txt)" end;
def distinct_titles:
	. as $runs
	| [range(length) as $index | $runs[$index] | .title as $title | .dispatch as $dispatch
		| (reduce ($runs[] | select(.title == $title) | .dispatch) as $seen ([]; if index([$seen]) == null then . + [$seen] else . end)) as $dispatches
		| .title = $title
			+ (if ($dispatches | length) > 1 then " \($dispatches | index([$dispatch]) + 1)" else "" end)
			+ round_label];
# The last report of each dispatch, which says whether its developer is done.
def latest_rounds: group_by(.dispatch) | map(last);
def run_entry($meta):
	{title: ($meta.title | txt), path: $meta.path, dispatch: $meta.dispatch, round: $meta.round, blocked: is_blocked, summary: summary_text,
	 groups: needs_groups(all_problems; $meta.repo // ""), counts: file_counts,
	 repo: (if ($meta.repo // "") == "" then "report \($meta.path)" else $meta.repo end)};
def developer_state: "\(.title) · \(if .blocked then "blocked" else "done" end)";
def developer_text:
	if .blocked and (.counts | changed_count) == 0 then "nothing changed"
	elif .summary == "" then "no summary in the report"
	else .summary end;
# One developer is its own bold label; two or more, a numbered list of them.
def developers_section($runs):
	if ($runs | length) == 1 then $runs[0] | section("Developer · \(developer_state)"; [developer_text])
	else section("Developers"; [$runs[] | "**\(developer_state):** \(developer_text)"]) end;
# Needs you by kind, then by developer under the kind heading; a blocker
# carries its developer in its own heading.
def kind_blocks($runs):
	range($runs[0].groups | length) as $kind
	| $runs[0].groups[$kind] as $spec
	| [$runs[] | {title, items: .groups[$kind].items} | select(.items | length > 0)] as $owners
	| ($owners | map(.items | length) | add // 0) as $count
	| if $count == 0 then empty
	  elif $spec.blocked then $owners[] | kind_section("Blocked · \(.title)"; "Blocked · \(.title)"; .items; $spec)
	  else (if $count == 1 then "**\($spec.one)**" else "**\($spec.many)**" end),
		($owners[] | kind_section(.title; .title; .items; $spec)) end;
def run_files($runs):
	[$runs[] | select(.counts | changed_count > 0) | .repo] | unique | length as $repos
	| field_section("**Files** · \(repos_text($repos))";
		[range(3) as $field
		 | [$runs[] | select(.counts[$field][1] > 0)] as $changed
		 | [$runs[0].counts[$field][0], ($changed | map(.counts[$field][1]) | add // 0), repos_text($changed | map(.repo) | unique | length)]]);
def run_view($runs; $not_done; $context):
	($runs | latest_rounds) as $developers
	| ($developers | length) as $total
	| ([$developers[] | select(.blocked)] | length) as $blocked
	| ([$runs[].groups | item_count] | add) as $count
	| [status_line(if $blocked > 0 then "blocked" elif $count > 0 then "attention" else "done" end;
		"Run finished · " + (if $total == 1 then "1 developer" else "\($total) developers" end | . as $developers
			| if $blocked > 0 then "\($blocked) of \($developers) blocked" else "\($developers) done" end);
		need_tail($count; false)),
	   developers_section($runs),
	   (if $count == 0 then "" else "**Needs you**" end),
	   kind_blocks($runs),
	   section("Not done"; [$not_done[] | txt | select(. != "") | cut(item_cap)]),
	   run_files($runs),
	   data_section([$runs[] | ["Report (\(.title))", .path | txt]] + (if $context == "" then [] else [["Context", $context | txt]] end))]
	| blocks;
'

# shellcheck disable=SC2016
readonly RENDER_MAIN_JQ='
$report[0] | as_written | developer_view(all_problems; $seat | title("developer"); $location_root; $report_path)
'

# The {language, frameworks} labels title() takes, from the LABELS line in
# $labels: "LABELS:", then its parts Language, Frameworks, Standards and
# Procedures, each at most once and in that order, joined by " · ". Prints
# nothing for any other line.
# shellcheck disable=SC2016
readonly LABELS_SEAT_JQ='
["Language", "Frameworks", "Standards", "Procedures"] as $order
| if $labels == "LABELS:" then {}
  elif $labels | startswith("LABELS: ") then
	($labels | ltrimstr("LABELS: ") | split(" · ")) as $parts
	| [$parts[] | capture("^(?<kind>[A-Za-z]+): (?<labels>.*[^ ].*)$")] as $found
	| [$found[].kind as $kind | $order | index($kind)] as $positions
	| if ($found | length) == ($parts | length) and all($positions[]; . != null) and $positions == ($positions | unique) then
		($found | map({(.kind): .labels}) | add) as $by_kind
		| {language: $by_kind.Language, frameworks: ($by_kind.Frameworks // "" | if . == "" then [] else split(", ") end)}
	  else empty end
  else empty end
'

# Prints a plugin SKILL.md's metadata.label by flow-agent-initialization's
# list-plugins.sh rules: the frontmatter opens on line 1 and is closed by
# ---; a "  label:" line under a "metadata:" line (a trailing comment
# allowed), the last one counting; a ` # comment` after an unquoted value
# dropped, one pair of quotes removed and tabs made spaces. Exits 2, printing
# nothing, when the frontmatter is not closed.
# The program is single-quoted on purpose: its $0 is awk's, not the shell's.
# shellcheck disable=SC2016
readonly PLUGIN_LABEL_AWK='
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
/^[^ \t#]/ { in_metadata = ($0 ~ /^metadata:[ \t]*(#.*)?$/); next }
in_metadata && /^  label:/ { label = clean(substr($0, index($0, ":") + 1)) }
END {
	if (!closed) exit 2
	print label
}
'

# One report and no --not-done prints its developer summary; no report, the
# run that built nothing; otherwise the run summary.
# shellcheck disable=SC2016
readonly SUMMARY_MAIN_JQ='
($reports | map(as_written)) as $reports
| if ($reports | length) == 0 then
	[status_line("blocked"; "Run finished · nothing was built"),
	 section("Not done"; [$not_done[] | txt | select(. != "") | cut(item_cap)]),
	 data_section(if $context_path == "" then [] else [["Context", $context_path | txt]] end)]
	| blocks
elif ($reports | length) == 1 and ($not_done | length) == 0 then
	$reports[0] | developer_view(all_problems; $meta[0].title + ($meta[0] | round_label); $meta[0].repo; $meta[0].path)
else
	[range($reports | length) as $index | $reports[$index]
		| run_entry($meta[$index] + {dispatch: (if .dispatch | stamp_id_ok then .dispatch else "report \($index + 1)" end)})]
	| distinct_titles
	| run_view(.; $not_done; $context_path)
end
'

# The top --help page: every usage line, the commands and what no single
# command owns. Each command's own contract is its `<command> --help` page.
usage() {
	usage_prefix='usage: '
	usage_lines check render summary baseline doc-check
	usage_line 'report.sh <command> --help'
	usage_line 'report.sh --help | -h'
	cat <<'EOF'

Checks the developer's report, one JSON object in PATH, stamps it from its
dispatch file on a pass, and renders it as Markdown. stdin is never read.
With no arguments, prints this page on stderr and exits 2.
EOF
	help_shared shape
	cat <<'EOF'

Commands (each page holds its options, output, exit codes and dependencies):
  check      checks the report's shape; with --dispatch, stamps it on a pass
  render     prints the report's developer summary for the human
  summary    prints the run summary of the reports of one run for the human
  baseline   writes a fix round's baseline, which check and render compare with
  doc-check  compares the report standard's field table with the validator
EOF
}

# The `<command> --help` page of command $1.
command_help() {
	usage_prefix='usage: '
	usage_lines "$1"
	case $1 in
		check) check_help ;;
		render) render_help ;;
		summary) summary_help ;;
		baseline) baseline_help ;;
		*) doc_check_help ;;
	esac
}

check_help() {
	cat <<'EOF'

Checks the report's shape; with --dispatch, stamps it on a pass. A stamped
report is refused: it is never checked again.
EOF
	help_shared shape
	help_shared options
	cat <<'EOF'
  --dispatch FILE     the dispatch file; supplies --report, --repo, --context
                      and --mode: leave them out, or give the same text (with
                      --round, --report is the round's own report)
EOF
	help_shared report-repo
	cat <<'EOF'
  --mode BUILD        the dispatch mode; only BUILD is taken
  --context FILE      the context file; each could_not ref names an entry
  --findings FILE     a fix round's finding IDs, one per line; review_responses
                      answers each exactly once
  --round 'fix N'     with --dispatch, N a positive integer: the report of fix
                      round N, which covers that round alone. --report is then
                      required: an existing file in the folder of the
                      dispatch's report, not that report itself. --baseline is
                      required. The stamps still come from the dispatch.
                      Left out on the dispatch's first report
  --baseline FILE     without --dispatch: git status --porcelain=v1 -z
                      --no-renames of --repo from before the dispatch; needs
                      --repo. With --round: the round's baseline, the file
                      report.sh baseline wrote before the round; a file then
                      counts as changed in the round when its status line
                      differs from the baseline's, or when the baseline lists
                      it and its fingerprint differs now. Never with
                      --dispatch alone
EOF
	help_shared skills-dir
	cat <<'EOF'

stdout on exits 0, 1, 3 and 6: one count line, <kind>=<n> per kind
stderr on exit 3: one "<field>: <what>; expected <x>" line per problem, at
  most 30, then a count of the rest.

Writes: with --dispatch, on exit 0 or 1 only, the report into PATH with the
stamps dispatch, started, finished, mode and plugins (the dispatch's plugin
names by kind: language, frameworks, standards, procedures) first, then
toolchain, summary, files, behavior, verification, deviations, decisions,
focus, noticed, open, blockers, review_responses; a key holding nothing
(null, [] or {}) is left out. Any other exit leaves PATH byte for byte as it
was.
EOF
	help_shared writes-nothing-else
	cat <<'EOF'

Exit codes:
  0  valid (stamped, with --dispatch); go on
  1  valid with open blockers (stamped, with --dispatch); treat as blocked
EOF
	cat <<'EOF'
  2  usage error; fix the command; stderr starting "report.sh: dispatch:":
     a dispatch fault, stop
  3  invalid; have the fields stderr names fixed, check again
  4  not a report (PATH not one JSON object); write the report again
  5  install fault; show stderr as is, the report unchecked
  6  --dispatch: valid, but the stamp step failed; render --dispatch; in a
     fix round, render --round 'fix N' --baseline FILE
  129, 130, 143  stopped by HUP, INT or TERM; the report unchecked
EOF
	help_shared dependencies
	help_shared dependencies-check-render
	cat <<'EOF'
  with --dispatch: flow-agent-initialization's dispatch validator, the
    crucible skill (its scripts/lib/prune.jq), and sha256sum or shasum
    (macOS: shasum -a 256)
EOF
}

render_help() {
	cat <<'EOF'

Prints the report's developer summary as Markdown on stdout. Its title is the developer title from the
language and frameworks ("Shell script developer", "Next.js and React
developer with TypeScript"; "Generic developer" with no language), then done
or blocked.
EOF
	help_shared shape
	help_shared options
	help_shared report-repo
	cat <<'EOF'
  --labels-file FILE  the hand-back's LABELS line, whole, at most 1000 bytes;
                      its Language and Frameworks build the developer title
                      (default: the metadata.label of the stamped language
                      and frameworks, each plugin's name when it has none)
  --round ROUND       initial or 'fix N'; initial shows review_responses as a
                      report problem, 'fix N' takes it or its absence
  --baseline FILE     git status --porcelain=v1 -z --no-renames of --repo from
                      before the dispatch; needs --repo, never with
                      --dispatch. With --round 'fix N', it may instead be the
                      round's baseline report.sh baseline wrote, compared as
                      check --round compares it
EOF
	cat <<'EOF'
  --dispatch FILE     the dispatch of a report check could not stamp, for its
                      baseline; a stamped report needs neither this nor
                      --baseline. Needs --repo
EOF
	help_shared skills-dir
	help_shared view-exits
	help_shared dependencies
	help_shared dependencies-check-render
	help_shared human-view
	cat <<'EOF'
  with --dispatch, or --repo on a stamped report: flow-agent-initialization's
    dispatch validator
  with --repo on a stamped report and neither --baseline nor --dispatch: the
    crucible skill
EOF
}

summary_help() {
	cat <<'EOF'

Prints the run summary as Markdown on stdout; with one --report and no
--not-done, that report's developer summary as render prints it. Each
dispatch is one developer, named by its title, as render builds it from the
stamped plugins; two dispatches of the same title are numbered in run order
("Shell script developer 1", "Shell script developer 2"). A report given a
--round carries it ("Shell script developer 1 · fix 1"), and so does each of
its Needs-you items; a report with no dispatch stamp is a dispatch of its
own. The status line counts developers by dispatch, blocked when the last
report given for the dispatch is; Files adds up each report's own lists.
EOF
	help_shared options
	cat <<'EOF'
  --report PATH       a developer's report file; repeat it for each, in run
                      order, each dispatch's first report, then its fix
                      rounds' in round order; none, with --not-done, for a
                      run that built nothing
  --round 'fix N'     right after a --report, N a positive integer: that
                      report is fix round N's; left out for a dispatch's
                      first report
  --context FILE      the run's context file, listed under Data; ignored
                      by a developer summary
  --not-done TEXT     one line: a part of the run that did not run, and why;
                      repeat it for each
EOF
	help_shared skills-dir
	help_shared view-exits
	help_shared dependencies
	help_shared own-skill
	help_shared human-view
	cat <<'EOF'
  the crucible skill, for the repo of each stamped report (one it cannot
    find counts as a repo of its own)
EOF
}

baseline_help() {
	cat <<'EOF'

Writes a fix round's baseline, taken just before the round is sent: the
repo's changes and a content fingerprint of each changed file, so check and
render --round 'fix N' can count a file changed in the round even when an
earlier round changed it too.

Options (every FILE and DIR absolute):
  --repo DIR          the root of a git work tree
  --out FILE          the round's baseline file: an existing, empty regular
                      file, not a symlink; a file holding anything is refused

Writes: into FILE, on exit 0 only, one JSON object:
  {"repo_root": DIR,
   "entries": [each entry of git status --porcelain=v1 -z --no-renames
     --untracked-files=all, "XY <path>", its NUL taken off],
   "fingerprints": {"<path>": git hash-object --no-filters of it, for each
     listed path that is a regular file}}
stdout: nothing.
Nothing else is left behind (a SIGKILL aside); the repo, its index and its
object store are never changed.

Exit codes:
  0  written; send the round
  2  usage error; fix the command
  5  install fault; show stderr as is, FILE left empty
  129, 130, 143  stopped by HUP, INT or TERM; FILE left empty

Dependencies:
  POSIX sh; jq 1.6+ (macOS: brew install jq; Linux: the distro's jq)
  awk, cat, cp, date, grep, mktemp, mv, rm, sed, tr, wc (every macOS and
    Linux base system)
  git (macOS: xcode-select --install; Linux: the distro's git)
EOF
}

doc_check_help() {
	cat <<'EOF'

Compares the report standard's field table with the validator. Writes nothing.
EOF
	help_shared options
	cat <<'EOF'
  --skill PATH        the report standard's SKILL.md
EOF
	help_shared skills-dir
	cat <<'EOF'

stdout: one line per difference.

Exit codes:
  0  the table agrees with the validator; go on
  1  differences; fix the table
  2  usage error; fix the command
  5  install fault; install what stderr names
  129, 130, 143  stopped by HUP, INT or TERM; rerun
EOF
	help_shared dependencies
}

# Prints the usage lines of each command named, the first after usage_prefix.
usage_lines() {
	for usage_command in "$@"; do
		case ${usage_command} in
			check)
				usage_line "report.sh check --dispatch FILE [--report PATH] [--repo DIR] [--mode BUILD] [--context FILE] [--findings FILE] [--round 'fix N' --baseline FILE] [--skills-dir DIR]"
				usage_line 'report.sh check --report PATH --repo DIR --mode BUILD [--baseline FILE] [--findings FILE] [--context FILE] [--skills-dir DIR]'
				;;
			render)
				usage_line "report.sh render --report PATH [--labels-file FILE] [--round initial|'fix N'] [--repo DIR [--baseline FILE | --dispatch FILE]] [--skills-dir DIR]"
				;;
			summary)
				usage_line "report.sh summary --report PATH [--round 'fix N'] [--report PATH [--round 'fix N']]... [--context FILE] [--not-done TEXT]... [--skills-dir DIR]"
				usage_line 'report.sh summary --not-done TEXT [--not-done TEXT]... [--context FILE] [--skills-dir DIR]'
				;;
			baseline) usage_line 'report.sh baseline --repo DIR --out FILE' ;;
			*) usage_line 'report.sh doc-check --skill PATH [--skills-dir DIR]' ;;
		esac
	done
}

usage_line() {
	printf '%s%s\n' "${usage_prefix}" "$1"
	usage_prefix='       '
}

# The help text more than one page prints, item $1, so it is written once.
help_shared() {
	case $1 in
		shape)
			cat <<'EOF'
shape: see this skill's SKILL.md field table; the validator here wins where
they differ.
EOF
			;;
		options) printf '\nOptions (every FILE, PATH and DIR absolute):\n' ;;
		report-repo)
			cat <<'EOF'
  --report PATH       the report file
  --repo DIR          the root of a git work tree; a changed file the report
                      does not list is counted as unlisted
EOF
			;;
		skills-dir)
			cat <<'EOF'
  --skills-dir DIR    default ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills
EOF
			;;
		writes-nothing-else) printf 'Nothing else is left behind (a SIGKILL aside); the repo and its index are\nnever changed.\n' ;;
		dependencies)
			cat <<'EOF'

Dependencies (other skills in --skills-dir):
  POSIX sh; jq 1.6+ (macOS: brew install jq; Linux: the distro's jq)
  awk, cat, cp, date, grep, mktemp, mv, rm, sed, tr, wc (every macOS and
    Linux base system)
  the flow-agent-initialization skill (its dispatch-names.jq)
EOF
			;;
		dependencies-check-render)
			help_shared own-skill
			printf "  with --repo: git (macOS: xcode-select --install; Linux: the distro's git)\n"
			;;
		own-skill) printf "  this skill's SKILL.md, beside scripts/\n" ;;
		human-view) printf '  the human-view skill\n' ;;
		view-exits)
			echo
			help_shared writes-nothing-else
			cat <<'EOF'

Exit codes:
  0  printed, an invalid report included; show it
  2  usage error; treat it as not rendered
  4  not a report (a PATH not one JSON object); treat it as not rendered
  5  install fault; treat it as not rendered
  129, 130, 143  stopped by HUP, INT or TERM; treat it as not rendered
EOF
			;;
		*) ;;
	esac
}

warn() {
	printf '%s: %s\n' "${PROG}" "$1" >&2
}

usage_error() {
	warn "$1"
	printf "Try '%s%s --help'.\n" "${PROG}" "${command:+ ${command}}" >&2
	exit 2
}

install_fault() {
	warn "install: $1"
	exit 5
}

not_a_report() {
	warn "not a report: $1"
	exit 4
}

# Sets command, the option values and their defaults from the arguments.
parse_args() {
	[ "$#" -gt 0 ] || {
		usage >&2
		exit 2
	}
	case $1 in
		--help | -h)
			usage
			exit 0
			;;
		check | render | summary | baseline | doc-check) command=$1 ;;
		*) usage_error "unknown command: $1; expected check, render, summary, baseline, doc-check or --help" ;;
	esac
	shift
	report='' repo='' baseline='' baseline_kind='' dispatch_baseline='' mode='' findings='' context='' labels_file='' labels='' seat='{}' round='' dispatch_file='' skill_file='' out_file=''
	report_list='' report_rounds='' not_done_list='' previous_option=''
	skills_dir="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/skills"
	while [ "$#" -gt 0 ]; do
		case $1 in
			--help | -h)
				command_help "${command}"
				exit 0
				;;
			--report | --repo | --baseline | --mode | --findings | --context | --labels-file | --round | --not-done | --skills-dir | --dispatch | --skill | --out)
				[ "$#" -ge 2 ] && [ -n "$2" ] || usage_error "$1 needs a value; expected $1 VALUE"
				set_option "$1" "$2"
				previous_option=$1
				shift 2
				;;
			*) usage_error "unknown argument: $1; expected the options '${PROG} ${command} --help' lists" ;;
		esac
	done
	check_jq
	check_base_tools
	if [ "${command}" = baseline ]; then
		check_baseline_args
		return 0
	fi
	[ -z "${out_file}" ] || usage_error '--out is for baseline only; expected it only with baseline'
	if [ "${command}" = doc-check ]; then
		check_doc_check_args
		return 0
	fi
	[ -z "${skill_file}" ] || usage_error '--skill is for doc-check only; expected it only with doc-check'
	[ -z "${not_done_list}" ] || [ "${command}" = summary ] || usage_error '--not-done is for summary only; expected it only with summary'
	if [ "${command}" = summary ]; then
		check_summary_args
		return 0
	fi
	[ -z "${round}" ] || check_round_value
	[ "${command}" != check ] || check_check_round
	[ "${command}" != check ] || [ -z "${dispatch_file}" ] || read_dispatch
	check_common_args
	if [ "${command}" = check ]; then check_check_args; else check_render_args; fi
}

set_option() {
	case $1 in
		--report)
			report=$2
			report_list="${report_list}${report_list:+${newline}}$2"
			report_rounds="${report_rounds}${report_rounds:+${newline}}-"
			;;
		--repo) repo=$2 ;;
		--baseline) baseline=$2 ;;
		--mode) mode=$2 ;;
		--findings) findings=$2 ;;
		--context) context=$2 ;;
		--labels-file) labels_file=$2 ;;
		--round)
			round=$2
			[ "${command}" != summary ] || set_report_round "$2"
			;;
		--not-done)
			case $2 in
				*"${newline}"*) usage_error '--not-done holds a line break; expected one line per --not-done' ;;
				*) not_done_list="${not_done_list}${not_done_list:+${newline}}$2" ;;
			esac
			;;
		--dispatch) dispatch_file=$2 ;;
		--skill) skill_file=$2 ;;
		--out) out_file=$2 ;;
		*) skills_dir=$2 ;;
	esac
}

# summary: a --round names the round of the --report right before it, so
# report_rounds holds one line per report, "-" for a dispatch's first report.
set_report_round() {
	[ "${previous_option}" = --report ] ||
		usage_error "--round $1 follows no --report; expected --report PATH --round 'fix N', the round right after its report"
	case $1 in
		*"${newline}"*) usage_error "--round holds a line break; expected 'fix N'" ;;
		*) report_rounds="${report_rounds%-}$1" ;;
	esac
}

# Checks the --dispatch file against the dispatch validator, takes --report
# (unless a fix round's), --repo, --context and --mode from it, sets stamps to
# the stamps it supplies (finished comes at the pass; plugins by kind, names
# only), dispatch_context_sha256 to the context file's pinned sha256 and
# dispatch_baseline to its baseline file (not read on a fix round, which
# compares with its own --baseline). Exits 2 on a bad file (stderr starting
# "report.sh: dispatch:"), a conflicting flag, a --baseline without --round or
# a fix round without one, 5 when the validator is missing.
read_dispatch() {
	if [ -z "${round}" ]; then
		[ -z "${baseline}" ] ||
			usage_error "--baseline is not taken with --dispatch: the dispatch's baseline key names the baseline the Agent hook wrote at the call; expected --baseline left out"
	else
		[ -n "${baseline}" ] ||
			usage_error "--round ${round} needs --baseline FILE; expected the round's baseline, the file report.sh baseline wrote before the round"
	fi
	validate_dispatch_file "${dispatch_file}" --dispatch
	# The validator holds these to absolute paths without a control character,
	# the sha256 to 64 hex digits and mode to BUILD, so each is one line.
	dispatch_fields=$(jq -r '.report, .repo_root, .context.path, .context.sha256, .mode, .baseline' "${dispatch_file}" </dev/null) ||
		dispatch_fault "${dispatch_file} cannot be read; ${dispatch_expected}"
	{
		IFS= read -r dispatch_report
		IFS= read -r dispatch_repo
		IFS= read -r dispatch_context
		IFS= read -r dispatch_context_sha256
		IFS= read -r dispatch_mode
		IFS= read -r dispatch_baseline
	} <<EOF
${dispatch_fields}
EOF
	if [ -z "${round}" ]; then
		same_as_dispatch --report "${report}" "${dispatch_report}" report
		report=${dispatch_report}
	else
		check_round_report
	fi
	same_as_dispatch --repo "${repo}" "${dispatch_repo}" repo_root
	same_as_dispatch --context "${context}" "${dispatch_context}" context.path
	same_as_dispatch --mode "${mode}" "${dispatch_mode}" mode
	repo=${dispatch_repo} context=${dispatch_context} mode=${dispatch_mode}
	# shellcheck disable=SC2016 # jq variables, not shell ones
	stamps=$(jq -c '(.plugins // {}) as $plugins
		| {dispatch: .id, started, mode,
		   plugins: {language: $plugins.language.name, frameworks: [$plugins.frameworks[]?.name],
			standards: [$plugins.standards[]?.name], procedures: [$plugins.procedures[]?.name]}}' "${dispatch_file}" </dev/null) ||
		dispatch_fault "${dispatch_file} cannot be read; ${dispatch_expected}"
	locate_prune_module
}

# A fix round's report is a new file beside the dispatch's own report, in the
# effort's reports/development/ folder, so every round keeps its own report
# and the dispatch's first report stays as it was stamped. Exits 2 otherwise.
check_round_report() {
	round_report_expected="expected the round's own report file, beside the dispatch's report ${dispatch_report}"
	case ${report} in
		'') usage_error "--round ${round} needs --report PATH; ${round_report_expected}" ;;
		/*) ;;
		*) usage_error "--report ${report} is not absolute; ${round_report_expected}, by its absolute path" ;;
	esac
	[ "${report}" != "${dispatch_report}" ] ||
		usage_error "--report ${report} is the dispatch's own report; ${round_report_expected}"
	case ${report##*/} in
		'' | . | ..) usage_error "--report ${report} names no file; ${round_report_expected}" ;;
		*) ;;
	esac
	[ "${report%/*}" = "${dispatch_report%/*}" ] ||
		usage_error "--report ${report} is not in the folder of the dispatch's report, ${dispatch_report%/*}; ${round_report_expected}"
	[ -f "${report}" ] ||
		usage_error "--report ${report} is not an existing file; ${round_report_expected}, made before the round was sent"
}

# Exits 5 unless crucible's prune.jq, which the stamped report is written
# through, is installed.
locate_prune_module() {
	prune_module="${skills_dir}/${CRUCIBLE_SKILL}/scripts/lib/prune.jq"
	[ -f "${prune_module}" ] && [ -r "${prune_module}" ] ||
		install_fault "${CRUCIBLE_SKILL}'s prune.jq missing; expected ${prune_module}; install the ${CRUCIBLE_SKILL} skill in ${skills_dir}"
}

# Exits 2 unless file $1 (named by option $2 in the messages) is an absolute,
# regular, readable dispatch file, not a symlink, passing the dispatch
# validator; 5 when the validator is missing. Sets dispatch_expected.
validate_dispatch_file() {
	dispatch_expected='expected the dispatch file generate-agent-dispatch.sh wrote'
	case $1 in
		/*) ;;
		*) usage_error "$2 $1 is not absolute; ${dispatch_expected}, by its absolute path" ;;
	esac
	[ ! -L "$1" ] || dispatch_fault "$1 is a symlink; ${dispatch_expected}, not a link to it"
	[ -f "$1" ] && [ -r "$1" ] ||
		dispatch_fault "$1 is missing, unreadable or not a regular file; ${dispatch_expected}"
	jq -s 'length' "$1" </dev/null >/dev/null 2>&1 ||
		dispatch_fault "$1 is not JSON; ${dispatch_expected}"
	dispatch_scripts="${skills_dir}/flow-agent-initialization/scripts/agent-dispatch"
	validator="${dispatch_scripts}/agent-dispatch-validator.jq"
	[ -f "${validator}" ] && [ -r "${validator}" ] ||
		install_fault "dispatch validator missing; expected ${validator}; install the flow-agent-initialization skill in ${skills_dir}"
	dispatch_problems=$(jq -rs -f "${validator}" "$1" </dev/null) ||
		install_fault "the dispatch validator failed to run: ${validator}; expected jq 1.6+ and the skill's dispatch-names.jq beside it; try reinstalling flow-agent-initialization"
	[ -n "${dispatch_problems}" ] || return 0
	printf '%s\n' "${dispatch_problems}" | sed "s/^/${PROG}: dispatch: /" >&2
	dispatch_fault "$1 fails the dispatch validator, each problem above; ${dispatch_expected}, unchanged since"
}

# A fault of the dispatch file itself: exit 2, the line starting
# "report.sh: dispatch:" so a caller can tell it from a usage error.
dispatch_fault() {
	warn "dispatch: $1"
	exit 2
}

# Exits 2 when option $1 was given a value $2 other than the dispatch's $3
# (its field $4).
same_as_dispatch() {
	[ -z "$2" ] || [ "$2" = "$3" ] ||
		usage_error "$1 $2 differs from the dispatch's $4 $3; expected $1 left out, or the same text"
}

# baseline takes --repo and --out alone, each absolute; --out an existing,
# empty regular file that is not a symlink, so a baseline is written once.
check_baseline_args() {
	for other in "${report}" "${baseline}" "${mode}" "${findings}" "${context}" "${labels_file}" "${round}" "${dispatch_file}" "${skill_file}" "${not_done_list}"; do
		[ -z "${other}" ] || usage_error 'baseline takes only --repo and --out; expected baseline --repo DIR --out FILE'
	done
	case ${repo} in
		'') usage_error '--repo DIR missing; expected the absolute path of the repository root' ;;
		/*) ;;
		*) usage_error "--repo ${repo} is not absolute; expected the absolute path of the repository root" ;;
	esac
	out_expected="expected the round's baseline file, existing and empty"
	case ${out_file} in
		'') usage_error "--out FILE missing; ${out_expected}" ;;
		/*) ;;
		*) usage_error "--out ${out_file} is not absolute; ${out_expected}, by its absolute path" ;;
	esac
	[ ! -L "${out_file}" ] || usage_error "--out ${out_file} is a symlink; ${out_expected}, not a link to it"
	[ -f "${out_file}" ] || usage_error "--out ${out_file} is missing or not a regular file; ${out_expected}"
	[ ! -s "${out_file}" ] || usage_error "--out ${out_file} holds data; ${out_expected}: a baseline is never overwritten"
}

# doc-check takes --skill, an absolute path to a regular, readable file, and
# --skills-dir alone.
check_doc_check_args() {
	for other in "${report}" "${repo}" "${baseline}" "${mode}" "${findings}" "${context}" "${labels_file}" "${round}" "${dispatch_file}"; do
		[ -z "${other}" ] || usage_error 'doc-check takes only --skill and --skills-dir; expected doc-check --skill PATH [--skills-dir DIR]'
	done
	case ${skill_file} in
		'') usage_error '--skill PATH missing; expected the absolute path of the report standard'"'"'s SKILL.md' ;;
		/*) ;;
		*) usage_error "--skill ${skill_file} is not absolute; expected the absolute path of the report standard's SKILL.md" ;;
	esac
	[ -f "${skill_file}" ] && [ -r "${skill_file}" ] ||
		usage_error "--skill file not readable: ${skill_file}; expected the report standard's SKILL.md, a regular file"
}

check_common_args() {
	case ${report} in
		'') usage_error '--report PATH missing; expected the absolute path of the report file' ;;
		/*) ;;
		*) usage_error "--report ${report} is not absolute; expected an absolute path" ;;
	esac
	case ${repo} in
		'' | /*) ;;
		*) usage_error "--repo ${repo} is not absolute; expected the absolute path of the repository root" ;;
	esac
	[ -z "${baseline}" ] || check_baseline_file
}

check_baseline_file() {
	[ -n "${repo}" ] || usage_error '--baseline needs --repo; expected --repo DIR --baseline FILE'
	case ${baseline} in
		/*) ;;
		*) usage_error "--baseline ${baseline} is not absolute; expected the absolute path of the saved git status" ;;
	esac
	[ -f "${baseline}" ] && [ -r "${baseline}" ] ||
		usage_error "--baseline file not readable: ${baseline}; expected git status --porcelain=v1 -z --no-renames of the repo, saved before the dispatch"
}

check_check_args() {
	[ -z "${labels_file}" ] || usage_error 'check takes no --labels-file; expected it only with render'
	[ -n "${repo}" ] || usage_error '--repo DIR missing; expected the absolute path of the repository root'
	case ${mode} in
		BUILD) ;;
		TEST) usage_error '--mode TEST is refused until the testing flow exists; expected --mode BUILD' ;;
		'') usage_error '--mode missing; expected --mode BUILD' ;;
		*) usage_error "--mode ${mode} is unknown; expected --mode BUILD" ;;
	esac
	if [ -n "${findings}" ]; then
		[ -f "${findings}" ] && [ -r "${findings}" ] ||
			usage_error "--findings file not readable: ${findings}; expected a file with one finding ID per line"
		grep -q '[^[:space:]]' "${findings}" ||
			usage_error "--findings file holds no ID: ${findings}; expected one finding ID per line"
	fi
	[ -z "${context}" ] || check_context_file
}

check_context_file() {
	[ -f "${context}" ] && [ -r "${context}" ] ||
		dispatch_value_fault CONTEXT --context "${context} is missing, unreadable or not a regular file; expected the context file {\"paths\", \"links\", \"notes\"}"
	jq -e 'type == "object"' "${context}" </dev/null >/dev/null 2>&1 ||
		dispatch_value_fault CONTEXT --context "${context} is not one JSON object; expected the context file {\"paths\", \"links\", \"notes\"}"
}

# Exits 2 with message $3 about the value of option $2. Under check --dispatch
# that value is the dispatch's field $1, which no flag fixes, so the fault is
# reported as the dispatch's ("report.sh: dispatch:"); otherwise as a usage error.
dispatch_value_fault() {
	[ "${command}" != check ] || [ -z "${dispatch_file}" ] || dispatch_fault "$1 $3"
	usage_error "$2 $3"
}

check_render_args() {
	for check_only in "${mode}" "${findings}" "${context}"; do
		[ -z "${check_only}" ] || usage_error 'render takes no --mode, --findings or --context; expected them only with check'
	done
	[ -z "${dispatch_file}" ] || check_render_dispatch_args
	check_view_args
}

# render --dispatch names the baseline through that dispatch, so it needs
# --repo and takes no --baseline.
check_render_dispatch_args() {
	[ -z "${baseline}" ] ||
		usage_error '--dispatch and --baseline both name a baseline; expected one of them: --dispatch for a report check --dispatch could not stamp'
	[ -n "${repo}" ] || usage_error '--dispatch needs --repo; expected --repo DIR --dispatch FILE'
}

# Checks --labels-file, which sets the title.
check_view_args() {
	[ -z "${labels_file}" ] || read_labels_file
}

check_round_value() {
	case ${round} in
		initial) ;;
		'fix '*[!0-9]* | 'fix 0'* | 'fix ') usage_error "--round ${round} is not 'fix N' with N a positive integer; expected initial or 'fix 2'" ;;
		'fix '*) ;;
		*) usage_error "--round ${round} is unknown; expected initial or 'fix N'" ;;
	esac
}

# check takes --round only as a fix round's, and only with --dispatch: the
# dispatch's first report is checked without it.
check_check_round() {
	case ${round} in
		'') return 0 ;;
		initial) usage_error "check takes --round only as 'fix N'; expected --round left out on the dispatch's first report" ;;
		*) ;;
	esac
	[ -n "${dispatch_file}" ] ||
		usage_error "--round ${round} needs --dispatch; expected check --dispatch FILE --report PATH --round '${round}' --baseline FILE"
}

# Sets seat to {language, frameworks} of the one LABELS line in labels_file;
# exits 2 when the file is missing, too big, or holds anything else.
read_labels_file() {
	labels_expected="expected a file holding the hand-back's LABELS line exactly as given"
	case ${labels_file} in
		/*) ;;
		*) usage_error "--labels-file ${labels_file} is not absolute; ${labels_expected}, by its absolute path" ;;
	esac
	[ -f "${labels_file}" ] && [ -r "${labels_file}" ] ||
		usage_error "--labels-file not readable: ${labels_file}; ${labels_expected}"
	labels_size=$(wc -c <"${labels_file}") || usage_error "--labels-file cannot be measured: ${labels_file}; ${labels_expected}"
	labels_size=${labels_size##* }
	[ "${labels_size}" -le "${MAX_LABELS_BYTES}" ] ||
		usage_error "--labels-file is ${labels_size} bytes: ${labels_file}; expected at most ${MAX_LABELS_BYTES} bytes, the LABELS line alone"
	labels=$(cat "${labels_file}") || usage_error "--labels-file not readable: ${labels_file}; ${labels_expected}"
	case ${labels} in
		*"${newline}"*) usage_error "--labels-file holds more than one line: ${labels_file}; ${labels_expected}, one line" ;;
		*) ;;
	esac
	seat=$(jq -nc --arg labels "${labels}" "${LABELS_SEAT_JQ}" </dev/null) ||
		install_fault 'jq failed reading the LABELS line; expected jq 1.6+; try jq --version'
	[ -n "${seat}" ] ||
		usage_error "--labels-file holds no LABELS line: ${labels_file}; expected 'LABELS:[ Language: <label>][ · Frameworks: <labels>][ · Standards: <labels>][ · Procedures: <labels>]', each part only when it names a plugin, copied whole from the hand-back"
}

# summary takes one or more --report (each with an optional --round),
# --context, --not-done and --skills-dir; a report path is one line, since
# report_list holds one per line.
check_summary_args() {
	for other in "${repo}" "${baseline}" "${mode}" "${findings}" "${labels_file}" "${dispatch_file}"; do
		[ -z "${other}" ] || usage_error 'summary takes only --report, --round, --context, --not-done and --skills-dir; expected them alone'
	done
	while IFS= read -r round; do
		case ${round} in
			'' | -) ;;
			'fix '*[!0-9]* | 'fix 0'* | 'fix ') usage_error "--round ${round} is not 'fix N' with N a positive integer; expected 'fix 2'" ;;
			'fix '*) ;;
			*) usage_error "summary takes --round only as 'fix N'; expected it left out for a dispatch's first report" ;;
		esac
	done <<EOF
${report_rounds}
EOF
	[ -n "${report_list}${not_done_list}" ] ||
		usage_error '--report PATH missing; expected the absolute path of each report file, or --not-done TEXT for a run that built nothing'
	while IFS= read -r listed_report; do
		case ${listed_report} in
			'') ;;
			*[[:cntrl:]]*) usage_error '--report holds a control character; expected the absolute path of a report file' ;;
			/*) ;;
			*) usage_error "--report ${listed_report} is not absolute; expected an absolute path" ;;
		esac
	done <<EOF
${report_list}
EOF
	case ${context} in
		'') ;;
		*[[:cntrl:]]*) usage_error '--context holds a control character; expected the absolute path of the context file' ;;
		/*) [ -f "${context}" ] && [ -r "${context}" ] || usage_error "--context file not readable: ${context}; expected the run's context file" ;;
		*) usage_error "--context ${context} is not absolute; expected the absolute path of the context file" ;;
	esac
}

check_jq() {
	command -v jq >/dev/null 2>&1 || install_fault 'jq missing; expected jq 1.6+ on PATH; try brew install jq (macOS) or the distro jq package'
	jq_version=$(jq --version 2>/dev/null) || install_fault 'jq --version failed; expected jq 1.6+; try reinstalling jq'
	case ${jq_version} in
		jq-1.[6-9]* | jq-1.[1-9][0-9]* | jq-[2-9]*) ;;
		*) install_fault "jq is ${jq_version}; expected jq 1.6+ (--rawfile, \$ARGS); try upgrading jq" ;;
	esac
}

check_base_tools() {
	for tool in awk cat cp date grep mktemp mv rm sed tr wc; do
		command -v "${tool}" >/dev/null 2>&1 && continue
		case ${tool} in
			awk) package=gawk ;;
			grep | sed) package=${tool} ;;
			*) package=coreutils ;;
		esac
		install_fault "${tool} missing; expected ${tool} on PATH, part of every macOS and Linux base system; try restoring PATH (macOS: /usr/bin) or installing the distro ${package} package"
	done
}

# Makes the temp folder every run uses, removed on exit with any temp file
# left beside a file being written (the stamped report, the round baseline).
make_work_dir() {
	partial_file=''
	work_dir=$(mktemp -d "${TMPDIR:-/tmp}/report-sh.XXXXXX") || install_fault 'mktemp -d failed; expected a writable TMPDIR'
	trap 'rm -rf "${work_dir}"; [ -z "${partial_file}" ] || rm -f "${partial_file}"' EXIT
	trap 'exit 129' HUP
	trap 'exit 130' INT
	trap 'exit 143' TERM
}

# Copies the report file once to report_copy (its name ending in $1, when
# given), which the check, the render and the stamps all read, so what is
# stamped is what was checked. Exits 4 unless it holds exactly one JSON object
# (or, before stamping, it is a symlink).
check_report() {
	[ -f "${report}" ] && [ -r "${report}" ] ||
		not_a_report "${report} is missing, unreadable or not a regular file; expected the file the first message's REPORT names"
	[ "${command}" != check ] || [ -z "${dispatch_file}" ] || [ ! -L "${report}" ] ||
		not_a_report "${report} is a symlink; expected the report file itself, which check --dispatch stamps"
	report_copy="${work_dir}/report${1:-}"
	cat "${report}" >"${report_copy}" ||
		not_a_report "${report} cannot be read; expected the file the first message's REPORT names"
	shape=$(jq -rs 'if length == 1 and (.[0] | type) == "object" then "object" elif length == 1 then "a JSON \(.[0] | type)" else "\(length) values" end' "${report_copy}" </dev/null 2>/dev/null) ||
		not_a_report "${report} is not valid JSON; expected one JSON object; try checking its quotes, commas and brackets"
	[ "${shape}" = object ] ||
		not_a_report "${report} holds ${shape}; expected exactly one JSON object"
}

# Writes git status for the repo and the baseline, NULs as \001, to git_file
# and baseline_file; with no repo, empty files and have_git false. The
# baseline is the --baseline file, else the dispatch's baseline file: the
# --dispatch file's (check, and render), or the one of the dispatch the report
# is stamped with (render); a render of an unstamped report without
# --dispatch has none. A fix round's baseline is turned into the same two
# files by apply_round_baseline.
read_git_status() {
	git_file="${work_dir}/status"
	baseline_file="${work_dir}/baseline"
	round_created_file="${work_dir}/created-paths"
	have_git=false
	: >"${git_file}"
	: >"${baseline_file}"
	: >"${round_created_file}"
	[ -n "${repo}" ] || return 0
	if [ -n "${baseline}" ]; then
		read_given_baseline
	else
		[ "${command}" != render ] || find_render_baseline
		[ -z "${dispatch_baseline}" ] || load_dispatch_baseline
	fi
	check_repo_root
	write_git_status "${git_file}"
	have_git=true
	[ "${baseline_kind}" != round ] || apply_round_baseline
}

# Exits 2 unless repo is the root of a git work tree, 5 when git is missing.
check_repo_root() {
	command -v git >/dev/null 2>&1 || install_fault 'git missing; expected git on PATH; try installing git'
	[ -d "${repo}" ] || dispatch_value_fault repo_root --repo "${repo} is not a folder; expected the repository root"
	top=$(git -C "${repo}" rev-parse --show-toplevel 2>/dev/null) ||
		dispatch_value_fault repo_root --repo "${repo} is not in a git work tree; expected the repository root"
	physical=$(cd "${repo}" && pwd -P) || dispatch_value_fault repo_root --repo "${repo} cannot be entered; expected a readable folder"
	[ "${top}" = "${physical}" ] || dispatch_value_fault repo_root --repo "${repo} is not the root of its work tree; expected ${top}"
}

# Writes the repo's git status, its NULs as \001, to file $1.
write_git_status() {
	# GIT_OPTIONAL_LOCKS=0: status reads only, never refreshing the index
	# under a dispatch that is still writing to the tree.
	GIT_OPTIONAL_LOCKS=0 git -C "${repo}" status --porcelain -z --untracked-files=all --no-renames >"${work_dir}/raw" ||
		install_fault "git status failed in ${repo}; expected it to list the changes; fix what git printed above"
	tr '\000' '\001' <"${work_dir}/raw" >"$1"
}

# Reads the --baseline file once into the temp folder and sets baseline_kind:
# round for a fix round's baseline (one JSON object, which a saved git status
# never is), checked against the shape and --repo; else status, its NULs as
# \001 into baseline_file. check --round takes only a round baseline, and a
# round baseline is taken only with --round 'fix N'. Exits 2 otherwise.
read_given_baseline() {
	given_baseline="${work_dir}/baseline.given"
	cat "${baseline}" >"${given_baseline}" ||
		usage_error "--baseline file not readable: ${baseline}; expected the saved git status"
	baseline_kind=status
	if jq -es 'length == 1 and (.[0] | type) == "object"' "${given_baseline}" </dev/null >/dev/null 2>&1; then
		baseline_kind=round
	fi
	round_baseline_expected="expected the file report.sh baseline --repo ${repo} --out FILE wrote before the round"
	case ${baseline_kind}:${round} in
		round:'fix '*) check_round_baseline ;;
		round:*) usage_error "--baseline ${baseline} is a fix round's baseline; expected it only with --round 'fix N'" ;;
		status:'fix '*)
			[ "${command}" != check ] ||
				usage_error "--baseline ${baseline} is not a fix round's baseline; ${round_baseline_expected}"
			;;
		*) ;;
	esac
	[ "${baseline_kind}" = round ] || tr '\000' '\001' <"${given_baseline}" >"${baseline_file}" ||
		usage_error "--baseline file not readable: ${baseline}; expected the saved git status"
}

# Exits 2 unless the round baseline copy has the shape `baseline` writes, for
# --repo.
check_round_baseline() {
	# shellcheck disable=SC2016 # jq variables, not shell ones
	round_baseline_problem=$(jq -rs --arg repo_root "${repo}" "${ROUND_BASELINE_JQ}"'.[0] | round_baseline_problems($repo_root)' \
		"${given_baseline}" </dev/null) ||
		install_fault 'jq failed on the round baseline shape; expected jq 1.6+; try jq --version'
	[ -n "${round_baseline_problem}" ] || return 0
	round_baseline_problem=$(printf '%s\n' "${round_baseline_problem}" | sed -n '1p')
	usage_error "--baseline ${baseline} is not a fix round's baseline: ${round_baseline_problem}; ${round_baseline_expected}"
}

# Sets baseline_file to the round baseline's entries the round left alone and
# adds to git_file an entry for each path the round put back, and writes
# round_created_file, the created paths the report may list as modified
# (ROUND_COMPARE_JQ). Only a path git still lists can be left alone, so the
# fingerprints now are taken of the paths in git_file.
apply_round_baseline() {
	write_fingerprints "${git_file}" "${work_dir}/fingerprints-now"
	for round_part in unchanged reverted created; do
		jq -nj --slurpfile round "${given_baseline}" --slurpfile now "${work_dir}/fingerprints-now" \
			--rawfile git "${git_file}" --arg part "${round_part}" \
			"\$round[0] as \$round | \$now[0] as \$now | ${ROUND_COMPARE_JQ}" </dev/null >"${work_dir}/round-${round_part}" ||
			install_fault 'jq failed comparing the round baseline with git; expected jq 1.6+; try jq --version'
	done
	cat "${work_dir}/round-unchanged" >"${baseline_file}" ||
		install_fault "cannot write in ${work_dir}; expected a writable TMPDIR"
	cat "${work_dir}/round-reverted" >>"${git_file}" ||
		install_fault "cannot write in ${work_dir}; expected a writable TMPDIR"
	cat "${work_dir}/round-created" >"${round_created_file}" ||
		install_fault "cannot write in ${work_dir}; expected a writable TMPDIR"
}

# Writes to file $2 one JSON object, {"<path>": "<git hash-object>"}, for each
# path among the git status entries in file $1 (each ending in \001) that is a
# regular file in the repo now. --no-filters hashes the bytes as they are, and
# without -w git writes nothing to its object store.
write_fingerprints() {
	fingerprints_out=$2
	fingerprint_paths="${work_dir}/fingerprint-paths"
	fingerprint_lines="${work_dir}/fingerprint-lines"
	fingerprint_hashes="${work_dir}/fingerprint-hashes"
	# Each entry ends in a separator, so splitting on it gives the entries whole,
	# a path holding spaces or line feeds included; globbing is off meanwhile.
	# The split is on \002: Bash 3.2, the sh of macOS, mis-splits on \001, which
	# it uses internally.
	entries_text=$(tr '\001' '\002' <"$1") || install_fault "cannot read ${1}; expected a readable TMPDIR"
	saved_ifs=${IFS}
	IFS=$(printf '\002')
	set -f
	# shellcheck disable=SC2086 # split on \002 on purpose, globbing off
	for fingerprint_entry in ${entries_text}; do
		fingerprint_path=${fingerprint_entry#???}
		[ ! -f "${repo}/${fingerprint_path}" ] || printf '%s\001' "${fingerprint_path}"
	done >"${fingerprint_paths}"
	set +f
	IFS=${saved_ifs}
	: >"${fingerprint_hashes}"
	if [ -s "${fingerprint_paths}" ]; then
		LC_ALL=C awk "${STDIN_PATHS_AWK}" "${fingerprint_paths}" >"${fingerprint_lines}" ||
			install_fault 'awk failed listing the paths to fingerprint; expected a POSIX awk; try awk --version'
		GIT_OPTIONAL_LOCKS=0 git -C "${repo}" hash-object --no-filters --stdin-paths <"${fingerprint_lines}" >"${fingerprint_hashes}" ||
			install_fault "git hash-object failed in ${repo}; expected it to fingerprint each changed file; fix what git printed above, or run again if a file was removed meanwhile"
	fi
	# shellcheck disable=SC2016 # jq variables, not shell ones
	jq -n --rawfile paths "${fingerprint_paths}" --rawfile hashes "${fingerprint_hashes}" '
		($paths | split("\u0001") | map(select(length > 0))) as $paths
		| ($hashes | split("\n") | map(select(length > 0))) as $hashes
		| if ($paths | length) != ($hashes | length) then error("\($paths | length) paths, \($hashes | length) hashes")
		  else [range($paths | length) as $index | {($paths[$index]): $hashes[$index]}] | add // {} end' \
		</dev/null >"${fingerprints_out}" ||
		install_fault 'jq failed pairing the paths with their fingerprints; expected one git hash-object line per path; try jq --version'
}

# Sets dispatch_baseline for render: the baseline file of the --dispatch file,
# else of the dispatch whose Crucible ID the report's dispatch stamp holds;
# leaves it empty for a report with no dispatch stamp of that shape rendered
# without --dispatch. The dispatch must pass the dispatch validator and have
# the --repo given as its repo_root.
find_render_baseline() {
	read_stamped_id
	if [ -n "${dispatch_file}" ]; then
		take_given_dispatch
		return 0
	fi
	[ -n "${stamped_id}" ] || return 0
	find_stamped_dispatch
	read_dispatch_baseline "${stamped_dispatch}" "the stamped dispatch"
	[ "${repo}" = "${dispatch_repo}" ] ||
		usage_error "--repo ${repo} differs from the stamped dispatch's repo_root ${dispatch_repo}; expected the same text, or --baseline FILE for another repository"
}

# Sets stamped_id to the report's dispatch stamp when it has the shape of a
# Crucible ID (the validator's stamp_id_ok), else to nothing.
read_stamped_id() {
	stamped_id=$(jq -r -L "${names_module%/*}" "${STAMP_JQ}"'.dispatch | select(stamp_id_ok)' "${report_copy}" </dev/null) ||
		install_fault "jq failed on the dispatch stamp with ${names_module}; expected jq 1.6+; try jq --version"
}

# Sets names_module to the shared names of flow-agent-initialization, the
# baseline shape and the stamp patterns; exits 5 when it is missing.
locate_names_module() {
	names_module="${skills_dir}/flow-agent-initialization/scripts/agent-dispatch/dispatch-names.jq"
	[ -f "${names_module}" ] && [ -r "${names_module}" ] ||
		install_fault "the shared dispatch names are missing; expected ${names_module}; install the flow-agent-initialization skill in ${skills_dir}"
}

# Takes the --dispatch file's baseline for render: exits 2 unless its
# repo_root is --repo, its report --report and, for a stamped report, its id
# the stamp.
take_given_dispatch() {
	read_dispatch_baseline "${dispatch_file}" --dispatch
	[ "${repo}" = "${dispatch_repo}" ] ||
		usage_error "--repo ${repo} differs from the --dispatch file's repo_root ${dispatch_repo}; expected the same text"
	[ "${report}" = "${dispatch_report}" ] ||
		usage_error "--report ${report} differs from the --dispatch file's report ${dispatch_report}; expected the report file of that dispatch"
	[ -z "${stamped_id}" ] || [ "${stamped_id}" = "${dispatch_id}" ] ||
		usage_error "--dispatch ${dispatch_file} is dispatch ${dispatch_id}, but the report is stamped from ${stamped_id}; expected the stamped dispatch, or --dispatch left out"
}

# Sets stamped_dispatch to the path crucible.sh path finds for stamped_id.
find_stamped_dispatch() {
	crucible_script="${skills_dir}/crucible/scripts/crucible.sh"
	[ -f "${crucible_script}" ] && [ -r "${crucible_script}" ] ||
		install_fault "crucible.sh missing; expected ${crucible_script} to find the stamped dispatch ${stamped_id}; install the crucible skill in ${skills_dir}"
	lookup_status=0
	stamped_dispatch=$(sh "${crucible_script}" path "${stamped_id}" </dev/null 2>"${work_dir}/crucible.err") || lookup_status=$?
	case ${lookup_status} in
		0) ;;
		1)
			lookup_message=$(sed -n '1p' "${work_dir}/crucible.err")
			dispatch_fault "the report's dispatch stamp ${stamped_id} names no dispatch file crucible.sh can find (${lookup_message}); expected the dispatch the report was stamped from; give --baseline FILE, or leave out --repo"
			;;
		*)
			lookup_message=$(sed -n '1p' "${work_dir}/crucible.err")
			install_fault "crucible.sh path ${stamped_id} failed (exit ${lookup_status}: ${lookup_message}); expected it to print the stamped dispatch's path; fix what it names"
			;;
	esac
	case ${stamped_dispatch} in
		*/efforts/*/dispatches/"${stamped_id}"-*.json) ;;
		*) dispatch_fault "the report's dispatch stamp ${stamped_id} names ${stamped_dispatch}, which is not a dispatch file; expected a file in an effort's dispatches/; give --baseline FILE, or leave out --repo" ;;
	esac
}

# Checks dispatch file $1 (named $2 in the messages) with validate_dispatch_file
# and sets dispatch_id, dispatch_report, dispatch_repo and dispatch_baseline
# from it.
read_dispatch_baseline() {
	validate_dispatch_file "$1" "$2"
	# The validator holds each of these to one line.
	dispatch_fields=$(jq -r '.id, .report, .repo_root, .baseline' "$1" </dev/null) ||
		dispatch_fault "$1 cannot be read; ${dispatch_expected}"
	{
		IFS= read -r dispatch_id
		IFS= read -r dispatch_report
		IFS= read -r dispatch_repo
		IFS= read -r dispatch_baseline
	} <<EOF
${dispatch_fields}
EOF
}

# Writes the dispatch's baseline file (dispatch_baseline) as the comparison's
# baseline, its entries joined by \001 into baseline_file. Exits 2 with a
# dispatch fault when it is missing, a symlink, unreadable, still empty or not
# a baseline of the dispatch's repo_root; 5 when the shared shape is missing.
load_dispatch_baseline() {
	baseline_expected='expected the git status prepare-agent-prompt.sh writes into it at the Agent call'
	[ ! -L "${dispatch_baseline}" ] || dispatch_fault "baseline ${dispatch_baseline} is a symlink; ${baseline_expected}"
	[ -f "${dispatch_baseline}" ] && [ -r "${dispatch_baseline}" ] ||
		dispatch_fault "baseline ${dispatch_baseline} is missing, unreadable or not a regular file; ${baseline_expected}"
	[ -s "${dispatch_baseline}" ] ||
		dispatch_fault "baseline ${dispatch_baseline} is empty: the dispatch was never sent through the Agent hook; ${baseline_expected}; send the dispatch through it before the work starts"
	baseline_copy="${work_dir}/baseline.json"
	cat "${dispatch_baseline}" >"${baseline_copy}" ||
		dispatch_fault "baseline ${dispatch_baseline} cannot be read; ${baseline_expected}"
	jq empty "${baseline_copy}" </dev/null >/dev/null 2>&1 ||
		dispatch_fault "baseline ${dispatch_baseline} is not JSON; ${baseline_expected}"
	# shellcheck disable=SC2016 # jq variables, not shell ones
	baseline_problems=$(jq -rs -L "${names_module%/*}" --arg repo_root "${dispatch_repo}" \
		'include "dispatch-names"; if length == 1 then .[0] | baseline_problems($repo_root) else "\(length) JSON values; expected one object" end' \
		"${baseline_copy}" </dev/null) ||
		install_fault "jq failed on the baseline shape in ${names_module}; expected jq 1.6+; try jq --version"
	if [ -n "${baseline_problems}" ]; then
		printf '%s\n' "${baseline_problems}" | sed "s/^/${PROG}: dispatch: baseline: /" >&2
		dispatch_fault "baseline ${dispatch_baseline} is not a baseline of this dispatch, each problem above; ${baseline_expected}"
	fi
	jq -j '.entries[] | ., "\u0001"' "${baseline_copy}" </dev/null >"${baseline_file}" ||
		install_fault 'jq failed writing the baseline entries; expected jq 1.6+; try jq --version'
}

# Copies the dispatch's context file once into the temp folder, the copy the
# check reads, and exits 2 unless its sha256 is the context.sha256 the
# dispatch pinned: a context changed since then is not what was approved.
pin_context() {
	context_copy="${work_dir}/context"
	cat "${context}" >"${context_copy}" ||
		dispatch_fault "CONTEXT ${context} cannot be read; expected the context file the dispatch names"
	sha256_of "${context_copy}"
	[ "${digest}" = "${dispatch_context_sha256}" ] ||
		dispatch_fault "CONTEXT ${context} changed since the dispatch was written: its sha256 is ${digest}, the dispatch pinned ${dispatch_context_sha256}; expected the context file as approved; try a new dispatch on the changed context"
}

# Sets digest to the sha256 of file $1, 64 lowercase hex digits; exits 5 when
# neither sha256sum (Linux, newer macOS) nor shasum (macOS) works.
sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		digest_line=$(sha256sum <"$1") || install_fault 'sha256sum failed; expected it to print the context file'"'"'s sha256; try sha256sum by hand'
	elif command -v shasum >/dev/null 2>&1; then
		digest_line=$(shasum -a 256 <"$1") || install_fault 'shasum -a 256 failed; expected it to print the context file'"'"'s sha256; try shasum -a 256 by hand'
	else
		install_fault 'sha256sum and shasum missing; expected one of them on PATH; install coreutils (Linux) or use the system shasum (macOS)'
	fi
	digest=${digest_line%% *}
	case ${digest} in
		*[!0-9a-f]* | '') install_fault "the sha256 tool printed ${digest_line}; expected 64 lowercase hex digits first" ;;
		*) ;;
	esac
	[ "${#digest}" -eq 64 ] || install_fault "the sha256 tool printed ${digest_line}; expected 64 lowercase hex digits first"
}

# Prints one line per difference between the --skill file and the validator;
# exits 0 when they agree, 1 on a difference. Writes nothing.
run_doc_check() {
	doc_differences "${skill_file}"
	[ -n "${differences}" ] || exit 0
	printf '%s\n' "${differences}"
	exit 1
}

# Sets differences to one line per difference between file $1 and the validator.
doc_differences() {
	differences=$(jq -nr -L "${names_module%/*}" --rawfile doc "$1" --arg git '' --arg baseline '' --arg round_created '' --argjson have_git false \
		--arg mode BUILD --arg stamp_check check --arg findings_mode none --arg findings_text '' \
		"${STAMP_JQ}null as \$context | ${COMMON_JQ}${SHAPE_JQ}${DOC_CHECK_JQ}" </dev/null) ||
		install_fault "jq failed comparing ${1} with the validator; expected jq 1.6+; try jq --version"
}

# check and render first hold this script to its own skill's SKILL.md (the one
# beside its scripts/ folder): a field table that disagrees with the validator
# is a broken install, exit 5.
check_own_skill() {
	case $0 in
		*/*) script_dir=${0%/*} ;;
		*) script_dir=. ;;
	esac
	own_skill_dir=$(cd "${script_dir}/.." && pwd -P) ||
		install_fault "the folder above ${script_dir} cannot be entered; expected report.sh in its skill's scripts/ folder; try reinstalling standard-code-development-report"
	own_skill="${own_skill_dir}/SKILL.md"
	[ -f "${own_skill}" ] && [ -r "${own_skill}" ] ||
		install_fault "${own_skill} missing or unreadable; expected the report standard's SKILL.md beside scripts/; try reinstalling standard-code-development-report"
	doc_differences "${own_skill}"
	[ -n "${differences}" ] || return 0
	first_difference=$(printf '%s\n' "${differences}" | sed -n '1p')
	install_fault "the field table in ${own_skill} and the validator disagree: ${first_difference}; run doc-check --skill ${own_skill} for all"
}

run_check() {
	if [ -n "${findings}" ]; then
		set -- --rawfile findings_text "${findings}" --arg findings_mode given
	else
		set -- --arg findings_text '' --arg findings_mode none
	fi
	if [ -n "${context}" ]; then
		set -- "$@" --slurpfile context_file "${context_copy:-${context}}"
		# shellcheck disable=SC2016 # a jq variable, not a shell one
		context_expr='$context_file[0]'
	else
		set -- "$@" --argjson context_file '[]'
		context_expr='null'
	fi
	output=$(jq -nr -L "${names_module%/*}" --slurpfile report "${report_copy}" --rawfile git "${git_file}" --rawfile baseline "${baseline_file}" --rawfile round_created "${round_created_file}" \
		--argjson have_git "${have_git}" --arg mode "${mode}" --arg stamp_check check "$@" \
		"${STAMP_JQ}${context_expr} as \$context | ${COMMON_JQ}${SHAPE_JQ}${CHECK_JQ}" </dev/null) ||
		install_fault 'jq failed on a valid JSON report; expected jq 1.6+; try jq --version'
	count_line=$(printf '%s\n' "${output}" | sed -n '1p')
	problems=$(printf '%s\n' "${output}" | sed '1d')
	printf '%s\n' "${count_line}"
	if [ -n "${problems}" ]; then
		printf '%s\n' "${problems}" >&2
		exit 3
	fi
	[ -z "${dispatch_file}" ] || write_stamps
	blockers=${count_line#blockers=}
	[ "${blockers%% *}" -eq 0 ] || exit 1
}

# Writes report_copy with the stamps onto the report file through a temp file
# beside it, as STAMPED_REPORT_JQ lays it out. Exits 6 when a step fails, the report unchanged.
write_stamps() {
	date_expected='expected date +%Y-%m-%dT%H:%M:%S%z to print the local time; try it by hand'
	raw_time=$(date +%Y-%m-%dT%H:%M:%S%z) || stamp_fault "date failed; ${date_expected}"
	case ${raw_time} in
		[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9][+-][0-9][0-9][0-9][0-9]) ;;
		*) stamp_fault "date printed ${raw_time}; ${date_expected}" ;;
	esac
	# The dispatch's started form: the offset as +HH:MM.
	finished="${raw_time%??}:${raw_time#"${raw_time%??}"}"
	report_dir=${report%/*}
	partial_file=$(mktemp "${report_dir:-/}/.report-stamps.XXXXXX") ||
		stamp_fault "mktemp failed in ${report_dir:-/}; expected the report's folder writable"
	cp -p "${report}" "${partial_file}" || stamp_fault "cp -p ${report} failed; expected the report's permissions copied to ${partial_file}"
	jq -L "${prune_module%/*}" --argjson stamps "${stamps}" --arg finished "${finished}" \
		"${STAMPED_REPORT_JQ}" "${report_copy}" </dev/null >"${partial_file}" ||
		stamp_fault "jq failed writing ${partial_file}; expected the stamped report written; try jq --version"
	mv -f "${partial_file}" "${report}" || stamp_fault "mv onto ${report} failed; expected the stamped report moved into place"
	partial_file=''
}

stamp_fault() {
	warn "stamps not written, the report unchanged: $1"
	exit 6
}

run_render() {
	locate_view_modules
	# Only a first round can refuse review_responses: render gets no findings file.
	findings_mode=unchecked
	[ "${round}" != initial ] || findings_mode=none
	[ -n "${labels_file}" ] || read_seat
	# Locations print joined to --repo, else to the stamped dispatch's repo_root.
	location_root=${repo}
	if [ -z "${location_root}" ]; then
		read_report_repo
		location_root=${report_repo}
	fi
	jq -nr -L "${skills_dir}/${RENDER_LIB}" -L "${names_module%/*}" --slurpfile report "${report_copy}" --rawfile git "${git_file}" \
		--rawfile baseline "${baseline_file}" --rawfile round_created "${round_created_file}" --argjson have_git "${have_git}" \
		--arg mode BUILD --arg findings_mode "${findings_mode}" --arg findings_text '' --arg stamp_check render \
		--argjson seat "${seat}" --arg round "${round}" \
		--arg home "${HOME:-}" --arg location_root "${location_root}" --arg report_path "${report}" \
		"include \"paths\"; include \"view\"; include \"title\"; ${STAMP_JQ}null as \$context | ${COMMON_JQ}${SHAPE_JQ}${RENDER_JQ}${VIEW_JQ}${RENDER_MAIN_JQ}" </dev/null ||
		install_fault 'jq failed on a valid JSON report; expected jq 1.6+; try jq --version'
}

# Exits 5 unless human-view's paths.jq, view.jq and title.jq are installed.
locate_view_modules() {
	for render_module in paths view title; do
		render_module_file="${skills_dir}/${RENDER_LIB}/${render_module}.jq"
		[ -f "${render_module_file}" ] && [ -r "${render_module_file}" ] ||
			install_fault "${RENDER_LIB}'s ${render_module}.jq missing; expected ${render_module_file}; install the ${RENDER_LIB} skill in ${skills_dir}"
	done
}

# Sets seat to the {language, frameworks} labels title() takes for the plugins
# report_copy is stamped with: each plugin's label, or its name when it has
# none; {} for a report stamped with no language and no framework.
read_seat() {
	# The stamp's language, then each framework, one "<kind> <name>" per line.
	stamped_seat=$(jq -r '.plugins | objects
		| (.language | strings | "language \(.)"), (.frameworks | arrays | .[] | strings | "framework \(.)")
		| gsub("[[:cntrl:]]"; "")' "${report_copy}" </dev/null) ||
		install_fault 'jq failed reading the plugins stamp; expected jq 1.6+; try jq --version'
	seat_language='' seat_frameworks=''
	while IFS=' ' read -r seat_kind seat_name; do
		[ -n "${seat_name}" ] || continue
		read_plugin_label "${seat_name}"
		if [ "${seat_kind}" = language ]; then
			seat_language=${plugin_label:-${seat_name}}
		else
			seat_frameworks="${seat_frameworks}${seat_frameworks:+${newline}}${plugin_label:-${seat_name}}"
		fi
	done <<EOF
${stamped_seat}
EOF
	# shellcheck disable=SC2016 # jq variables, not shell ones
	seat=$(jq -nc --arg language "${seat_language}" --arg frameworks "${seat_frameworks}" \
		'{language: $language, frameworks: ($frameworks | split("\n") | map(select(. != "")))}' </dev/null) ||
		install_fault 'jq failed building the developer title; expected jq 1.6+; try jq --version'
}

# Sets plugin_label to the metadata.label in the SKILL.md frontmatter of
# plugin $1 in the skills dir, read by flow-agent-initialization's
# list-plugins.sh rules, or to nothing when it is not installed, has no closed
# frontmatter or has no label. The name must be one folder name (no "/", not
# "." or "..", no comma or control character, as list-plugins.sh accepts), so
# the report cannot point the read outside the skills dir.
read_plugin_label() {
	plugin_label=''
	case $1 in
		'' | . | .. | */* | *,* | *[[:cntrl:]]*) return 0 ;;
		*) ;;
	esac
	plugin_skill="${skills_dir}/$1/SKILL.md"
	[ -f "${plugin_skill}" ] && [ -r "${plugin_skill}" ] || return 0
	# The C locale keeps awk byte-wise, as list-plugins.sh runs it.
	plugin_label=$(LC_ALL=C awk "${PLUGIN_LABEL_AWK}" "${plugin_skill}") || plugin_label=''
}

# Sets report_repo to the repo_root of the dispatch report_copy is stamped
# with, as crucible.sh path finds it, or to nothing when it cannot be found.
read_report_repo() {
	report_repo=''
	read_stamped_id
	[ -n "${stamped_id}" ] || return 0
	crucible_script="${skills_dir}/crucible/scripts/crucible.sh"
	[ -f "${crucible_script}" ] && [ -r "${crucible_script}" ] || return 0
	stamped_dispatch=$(sh "${crucible_script}" path "${stamped_id}" </dev/null 2>/dev/null) || return 0
	case ${stamped_dispatch} in
		*"${newline}"*) return 0 ;;
		*/efforts/*/dispatches/"${stamped_id}"-*.json) ;;
		*) return 0 ;;
	esac
	report_repo=$(jq -r '.repo_root | strings | select(startswith("/"))' "${stamped_dispatch}" </dev/null 2>/dev/null) || report_repo=''
}

# Writes the round baseline of repo into out_file: built in the temp folder,
# then moved into place through a temp file beside it that keeps out_file's
# permissions, so out_file is either empty or whole.
run_baseline() {
	check_repo_root
	write_git_status "${work_dir}/round-status"
	write_fingerprints "${work_dir}/round-status" "${work_dir}/round-fingerprints"
	# shellcheck disable=SC2016 # jq variables, not shell ones
	jq -n --arg repo_root "${repo}" --rawfile status "${work_dir}/round-status" --slurpfile fingerprints "${work_dir}/round-fingerprints" \
		'{repo_root: $repo_root, entries: ($status | split("\u0001") | map(select(length > 3))), fingerprints: $fingerprints[0]}' \
		</dev/null >"${work_dir}/round-baseline" ||
		install_fault 'jq failed building the round baseline; expected jq 1.6+; try jq --version'
	out_dir=${out_file%/*}
	partial_file=$(mktemp "${out_dir:-/}/.${out_file##*/}.XXXXXX") ||
		install_fault "mktemp failed in ${out_dir:-/}; expected the folder of --out writable"
	cp -p "${out_file}" "${partial_file}" ||
		install_fault "cp -p ${out_file} failed; expected its permissions copied to ${partial_file}"
	cat "${work_dir}/round-baseline" >"${partial_file}" ||
		install_fault "cannot write ${partial_file}; expected the folder of --out writable, with free space"
	# A call racing this one may have filled it since the argument check; its
	# baseline is kept.
	[ ! -s "${out_file}" ] || usage_error "--out ${out_file} holds data; ${out_expected}: a baseline is never overwritten"
	mv -f "${partial_file}" "${out_file}" || install_fault "mv onto ${out_file} failed; expected the baseline moved into place"
	partial_file=''
}

# Checks each --report, then prints one developer summary or the run summary.
# meta.json holds, per report in order, its path, developer title, repo and
# round (null for a dispatch's first report).
run_summary() {
	locate_view_modules
	report_index=0
	: >"${work_dir}/reports.json"
	: >"${work_dir}/meta.json"
	while IFS= read -r report && IFS= read -r report_round <&3; do
		[ -n "${report}" ] || continue
		report_index=$((report_index + 1))
		check_report "${report_index}"
		read_seat
		read_report_repo
		cat "${report_copy}" >>"${work_dir}/reports.json" ||
			install_fault "cannot write in ${work_dir}; expected a writable TMPDIR"
		jq -n -L "${skills_dir}/${RENDER_LIB}" --arg path "${report}" --argjson seat "${seat}" --arg repo "${report_repo}" --arg round "${report_round}" \
			'include "title"; {path: $path, title: ($seat | title("developer")), repo: $repo, round: (if $round == "-" then null else $round end)}' </dev/null >>"${work_dir}/meta.json" ||
			install_fault 'jq failed writing the report list; expected jq 1.6+; try jq --version'
	done <<EOF 3<<ROUNDS
${report_list}
EOF
${report_rounds}
ROUNDS
	if [ -n "${not_done_list}" ]; then printf '%s\n' "${not_done_list}"; fi >"${work_dir}/not-done"
	jq -nr -L "${skills_dir}/${RENDER_LIB}" -L "${names_module%/*}" --slurpfile reports "${work_dir}/reports.json" \
		--slurpfile meta "${work_dir}/meta.json" --rawfile not_done_text "${work_dir}/not-done" \
		--arg git '' --arg baseline '' --arg round_created '' --argjson have_git false \
		--arg mode BUILD --arg findings_mode unchecked --arg findings_text '' --arg stamp_check render \
		--arg home "${HOME:-}" --arg context_path "${context}" \
		"include \"paths\"; include \"view\"; ${STAMP_JQ}null as \$context | (\$not_done_text | split(\"\\n\") | map(select(. != \"\"))) as \$not_done | ${COMMON_JQ}${SHAPE_JQ}${RENDER_JQ}${VIEW_JQ}${SUMMARY_MAIN_JQ}" </dev/null ||
		install_fault 'jq failed on valid JSON reports; expected jq 1.6+; try jq --version'
}

parse_args "$@"
if [ "${command}" = baseline ]; then
	make_work_dir
	run_baseline
	exit 0
fi
locate_names_module
if [ "${command}" = doc-check ]; then run_doc_check; fi
check_own_skill
make_work_dir
if [ "${command}" = summary ]; then
	run_summary
	exit 0
fi
[ "${command}" != check ] || [ -z "${dispatch_file}" ] || pin_context
check_report
read_git_status
if [ "${command}" = check ]; then run_check; else run_render; fi
