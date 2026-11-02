#!/usr/bin/env sh
# Checks the developer's report JSON, stamps what its dispatch file knows into
# it on a pass, and prints the human's card for that one report. The jq
# validator below owns the report's shape (there is no schema file): the
# report standard's field table documents it, --help points there, the
# validator wins where they differ, and doc-check compares the table with it.
# The card goes through human-view's view.jq, paths.jq and title.jq.
set -eu

readonly PROG='report.sh'
readonly VIEW_LIB='human-view'
readonly CRUCIBLE_SKILL='crucible'
readonly newline='
'
# A LABELS line names one language, its frameworks and a handful of standards
# and procedures, well under this; a bigger file is not the hand-back's line.
readonly MAX_LABELS_BYTES=1000
# Definitions the check and the card share: how git's changes compare with
# the report's files lists (the card reads only the lists). $git and $baseline hold `git status --porcelain -z`
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
# $round_created: in an iteration, the paths an earlier one created and this
# one edited, still untracked or added (each ending in \u0001); git shows
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
# The keys check --dispatch writes into the report on a pass; the agent never
# does. plugins is left out when the dispatch loaded no plugin.
# shellcheck disable=SC2016 # a jq program: its $ signs are jq's
readonly STAMP_JQ='include "dispatch-names";
def stamp_id_ok: type == "string" and test(crucible_id_pattern);
def stamp_time_ok: type == "string" and test(local_time_pattern);
def stamp_keys: ["dispatch", "started", "finished", "mode", "plugins"];
def required_stamp_keys: stamp_keys - ["plugins"];
def stamped: type == "object" and (. as $report | all(required_stamp_keys[]; . as $key | $report | has($key)));
'

# The shape check, whose problems check and card print: `problems` is an array
# of "<field>: <what>; expected <x>" lines. Every value taken from the report
# goes through `shown`, so a problem line never holds a newline. $findings_mode
# is "given" (an iteration given findings, IDs in $findings_text), "none" (review_responses is
# refused) or "unchecked" (card, which has no findings file). $round is check's
# --round ("" when not given). $write_rules is false only for card on a stamped
# report: the text, word and item caps and the at of a found item bind when a
# report is written, so a rule changed later never refuses a report that met
# it then.
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
# The problem line of a value past its cap ends with how to shorten it (length_hint):
# these prose fields, each one item a reader takes in whole, are rewritten as
# one shorter sentence; a location (at, location, ref) or a verification
# command is written shorter.
def sentence_fields: ["deviations.what", "deviations.why", "noticed.what", "open.text", "blockers.detail", "review_responses.note"];
def shorter_fields: location_fields + ["open.ref", "verification.command"];

def among($list): . as $value | any($list[]; . == $value);
def names: join(", ");
# A value quoted whole up to 60 characters, a longer one named by its length
# (for a string its characters, not its JSON quotes), so a problem line stays one
# readable line and never holds a cut value. An unknown key is named the same
# way; a finding ID, which check holds to 200 characters, is quoted whole.
def shown: if (tojson | length) <= 60 then tojson
	elif type == "string" then "(a value of \(length) characters)"
	else "(a JSON \(type) of \(tojson | length) characters)" end;
def shown_key: if (tojson | length) <= 60 then tojson else "(a key of \(length) characters)" end;
def shown_name: tojson;
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
	elif $write_rules and length > max_text then "\(length) characters"
	elif ($name | among(location_fields)) and absolute then "an absolute path"
	else empty end;
def length_hint($name):
	if test("^[0-9]+ characters$") | not then ""
	elif $name | among(sentence_fields) then "; rewrite it as one shorter sentence"
	elif $name | among(shorter_fields) then "; write it shorter"
	else "" end;
def field_line($loc; $name): value_problem($name) | "\($loc): \(.); expected \(expected($name))\(length_hint($name))";

def cross_problems($list; $loc):
	if $list == "verification" then
		(if .result == "pass" and (has("command") | not) then "\($loc).command: missing on a pass; expected the command as run" else empty end),
		(if (.result | among(enums["verification.result"])) and .result != "pass" and (has("note") | not)
		 then "\($loc).note: missing on result \(.result); expected why it did not pass (for narrowed, the words of the first message quoted and the coverage given up)" else empty end),
		(.command | strings | chain_operators | select(length > 0)
		 | "\($loc).command: chains commands with \(join(" and ")); expected one command per item")
	elif $list == "open" and .kind == "could_not" and (has("ref") | not) then
		"\($loc).ref: missing on kind could_not; expected the context entry it names"
	elif $write_rules and $list == "open" and (.kind | among(uncapped_kinds)) and (has("at") | not) then
		"\($loc).at: missing on kind \(.kind); expected where it appeared, in a location form"
	elif $list == "review_responses" and .status == "not_fixed" and (has("note") | not) then
		"\($loc).note: missing on not_fixed; expected why it was not fixed"
	else empty end;
def item_problems($list):
	item_fields[$list] as $spec
	| .[$list] | to_entries[] | .key as $index | .value | "\($list)[\($index)]" as $loc
	| if type != "object" then "\($loc): a JSON \(type); expected an object with \($spec.required | names)"
	  else . as $item
		| ((keys - $spec.required - $spec.optional)[] | "\($loc).\(shown_key): unknown key; expected only \($spec.required + $spec.optional | names)"),
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
		  elif $key | among(never_written_keys) then "\($key): written into the report; expected it left out: never write round or LABELS (check takes the round as --round, and LABELS comes from the hand-back)"
		  else "\($key | shown_key): unknown key; expected only \($known | names)" end),
	  (required_keys[] as $key | select(has($key) | not) | "\($key): missing; expected the key, as the report standard\u0027s field table shows");
# check ($stamp_check "check") refuses every stamp key a report holds: the flow
# checks a report before stamping it and never checks a stamped one again, so a
# stamp key at a check was written by the agent. card ("card") takes the set
# (plugins optional) when each key has the shape of a stamp, and refuses a part
# set.
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
	  elif $stamp_check == "card" and all(required_stamp_keys[]; among($present)) then stamp_shape_problems
	  else $present[] | "\(.): written into the report; expected it left out: \(stamp_rule)" end;

# A stamped report was written through prune, which left out a required key
# that held only empty lists; card reads such a key as empty again.
def as_written:
	if $stamp_check == "card" and stamped
	then {files: {created: [], modified: [], deleted: []}, deviations: []} * .
	else . end;

def summary_problems:
	if has("summary") | not then empty
	elif .summary | text_ok | not then "summary: not a non-empty string; expected what changed, in at most \(max_words) words"
	elif $write_rules and (.summary | word_count) > max_words then "summary: \(.summary | word_count) words; expected at most \(max_words)"
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
			| "files.\(shown_key): unknown key; expected only created, modified and deleted"),
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
		(caps[$key] as $cap | select($write_rules and $cap != null)
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
		"review_responses: missing on an iteration given findings; expected one item per finding ID given: \(findings_list | names)"
	elif (.review_responses | type) != "array" then empty
	else findings_list as $findings
		| .blockers as $blockers
		| [.review_responses[] | objects | .id | strings] as $ids
		| ($findings[] as $id | [$ids[] | select(. == $id)] | length
			| if . == 0 then "review_responses: \($id | shown_name) missing; expected each finding ID given exactly once"
			  elif . > 1 then "review_responses: \($id | shown_name) given \(.) times; expected it exactly once"
			  else empty end),
		  ($ids | unique[] | select(among($findings) | not)
			| "review_responses: \(shown_name) is not a finding ID given; expected only \($findings | names)"),
		  (.review_responses | to_entries[] | .key as $index | .value
			| select(type == "object" and .status == "blocked" and (.id | type) == "string") | .id as $id
			| select([$blockers | arrays | .[] | objects | select(.kind == "finding_blocked" and (.detail | type) == "string" and (.detail | names_token($id)))] | length == 0)
			| "review_responses[\($index)]: \($id | shown_name) is blocked but in no blockers item; expected a blockers item of kind finding_blocked whose detail names \($id | shown_name) as a whole word")
	end;

def context_refs:
	($context.paths // [] | arrays) as $paths
	| ($context.links // [] | arrays) as $links
	| ($context.notes // [] | arrays) as $notes
	| [($paths[] | objects | .path | strings), ($links[] | objects | .url | strings),
	   ($paths | keys[] | "paths[\(. + 1)]"), ($links | keys[] | "links[\(. + 1)]"), ($notes | keys[] | "notes[\(. + 1)]")];
# An iteration never extends the context, so work it skipped from its change
# list is named by the CHANGES field of the first message instead.
def iteration_ref: "message: CHANGES";
def context_problems:
	($round | startswith("iteration ")) as $iteration
	| if $context == null or (.open | type) != "array" then empty
	else (context_refs + (if $iteration then [iteration_ref] else [] end)) as $refs
		| .open | to_entries[] | .key as $index | .value
		| select(type == "object" and .kind == "could_not" and (.ref | type) == "string" and (.ref | among($refs) | not))
		| "open[\($index)].ref: \(.ref | shown) names no context entry; expected a paths[].path or links[].url of the context file, or \(context_positions)"
			+ (if $iteration then ", or \(iteration_ref) for work skipped from the iteration\u0027s change list" else " (\(iteration_ref) only in an iteration, check --round)" end)
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

# An iteration's baseline, which `baseline` writes and check reads:
#   {"repo_root": <the repo>, "entries": [<git status entry, "XY <path>">, ...],
#    "fingerprints": {"<path>": <git hash-object of it>, ...},
#    "dispatch": <dispatch file>, "report": <the iteration's report>,
#    "round": "iteration <N>"}
# The last three are given together or not at all; they name the iteration
# the baseline was taken for. A path has a fingerprint when it was a regular
# file at the time; a deleted one has none. Prints one "<field> <problem>;
# expected <x>" line per way the input differs from that shape for repo root
# $repo_root, or from the --round $round, --report $report and --dispatch
# $dispatch given ("" when not given).
# shellcheck disable=SC2016
readonly ROUND_BASELINE_JQ='
def round_baseline_keys: ["repo_root", "entries", "fingerprints"];
def iteration_keys: ["dispatch", "report", "round"];
def iteration_problems($round; $report; $dispatch):
	[iteration_keys[] as $key | select(has($key)) | $key] as $present
	| if ($present | length) == 0 then empty
	  elif ($present | length) < (iteration_keys | length) then
		"\(iteration_keys - $present | join(", ")) missing; expected \(iteration_keys | join(", ")) together, or none of them"
	  else
		(("dispatch", "report") as $key | select(.[$key] | type != "string" or (startswith("/") | not))
			| "\($key) is not an absolute path; expected the \($key) path baseline was given"),
		(if (.round | type) == "string" and (.round | test("\\Aiteration [1-9][0-9]*\\z")) then empty
		 else "round \(.round | tojson) is not an iteration; expected \"iteration <N>\"" end),
		(if .round == $round then empty else "round \(.round | tojson) is not --round; expected \($round | tojson)" end),
		(if .report == $report then empty else "report \(.report | tojson) is not --report; expected \($report | tojson)" end),
		(if $dispatch == "" or .dispatch == $dispatch then empty else "dispatch \(.dispatch | tojson) is not --dispatch; expected \($dispatch | tojson)" end)
	  end;
def round_baseline_problems($repo_root; $round; $report; $dispatch):
	if type != "object" then "a JSON \(type); expected an object with \(round_baseline_keys | join(", "))"
	else ((keys - round_baseline_keys - iteration_keys)[] | "\(tojson): unknown field; expected only \(round_baseline_keys + iteration_keys | join(", "))"),
		iteration_problems($round; $report; $dispatch),
		(round_baseline_keys[] as $key | select(has($key) | not) | "\($key) missing; expected every one of \(round_baseline_keys | join(", "))"),
		(select(has("repo_root")) | if .repo_root == $repo_root then empty
		 else "repo_root \(.repo_root | tojson) is not --repo; expected \($repo_root | tojson)" end),
		(select(has("entries")) | if (.entries | type) == "array" and all(.entries[]; type == "string" and length > 3 and (contains("\u0001") | not)) then empty
		 else "entries is not an array of git status entries; expected [\"XY <path>\", ...] ([] for a clean tree)" end),
		(select(has("fingerprints")) | if (.fingerprints | type) == "object" and all(.fingerprints[]; type == "string" and test("\\A[0-9a-f]{40}([0-9a-f]{24})?\\z")) then empty
		 else "fingerprints is not an object of git object IDs; expected {\"<path>\": \"<40 or 64 hex digits>\", ...}" end)
	end;
'

# The comparison's inputs for an iteration, from its baseline ($round), the
# fingerprints of its paths now ($now) and the git status now ($git, entries
# joined by \u0001). $part "unchanged" prints the baseline entries the
# iteration left alone (the same status line, and the same fingerprint or
# none both times), which COMMON_JQ leaves out like a dispatch baseline's;
# "reverted" prints an entry for each baseline path git no longer lists,
# labelled as the change the iteration made to put it back; "created" prints
# the paths an earlier iteration created that git still shows created and
# this one changed (each ending in \u0001), which the report may list as
# created or modified. A file changed again in the iteration has a new
# fingerprint, so it is compared like any other change.
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

# The card's own rules for the main thread's lines: each is the text of one
# Markdown list item, so it may never open a block of its own; bold (**) is
# inline, not a list mark.
# shellcheck disable=SC2016
readonly CARD_RULES_JQ='
def card_keys: ["do", "decide"];
# A handful of lines stays one glance; more belongs in a conversation.
def card_max_lines: 5;
# About two lines of a terminal: one instruction or one question with its stake.
def card_max_text: 240;
def card_line_expected: "one line of at most \(card_max_text) characters, not starting with #, -, >, a * list mark or a number and a dot";
def card_line_problem:
	if type != "string" then "a JSON \(type)"
	elif text_ok | not then "empty"
	elif test("[[:cntrl:]\u0085  ]") then "holds a line break, tab or other control character"
	elif length > card_max_text then "\(length) characters"
	elif test("^[[:space:]]*([#>-]|[0-9]+[.]|[*]([[:space:]]|[*]*[[:space:]]*$))") then "starts with a heading, list or quote mark"
	else empty end;
def card_list_problems($key):
	if has($key) | not then "\($key): missing; expected an array of 0 to \(card_max_lines) lines ([] when none)"
	elif (.[$key] | type) != "array" then "\($key): a JSON \(.[$key] | type); expected an array of 0 to \(card_max_lines) lines"
	else (.[$key] | length | select(. > card_max_lines) | "\($key): \(.) lines; expected at most \(card_max_lines)"),
		(.[$key] | to_entries[] | .key as $index | .value | card_line_problem
			| "\($key)[\($index)]: \(.); expected \(card_line_expected)")
	end;
def card_problems($blockers):
	if type != "object" then "card: a JSON \(type); expected {\"do\": [lines], \"decide\": [lines]}"
	else ((keys - card_keys)[] | "\(shown_key): unknown key; expected only do and decide"),
		(card_keys[] as $key | card_list_problems($key)),
		(if $blockers > 0 and .do == [] and .decide == []
		 then "do/decide: both empty while the report has \($blockers) blocker\(if $blockers == 1 then "" else "s" end); expected at least one line telling the human what to do or decide"
		 else empty end)
	end;
'

# The card of one report that passed the shape check, laid out with
# human-view's helpers: every item on its own line, each value from the report
# with its control characters made spaces so it cannot add one.
# shellcheck disable=SC2016
readonly CARD_VIEW_JQ='
def txt: if type == "string" then . elif . == null then "" else tojson end
	| gsub("[[:cntrl:]\u0085  ]+"; " ") | sub("^ +"; "") | sub(" +$"; "");
def words: txt | gsub("_"; " ");
# A location in the repo-relative path:line form; the other forms (an absolute
# or ~ path, message:, commit, a context ref, a URL, a plugin name and file) are
# not in the repo.
def in_repo_form: (startswith("/") or startswith("~")
	or test("^(message: |commit |(paths|links|notes)\\[)") or contains("://")
	or test("^(language|framework|standard|procedure)-[a-z0-9-]+([ :/]|$)")) | not;
# A location whole, a repo-relative one joined to repo root $repo_root ("" when
# not found: then as written).
def place: txt
	| if $repo_root != "" and in_repo_form then ($repo_root | rtrimstr("/")) + "/" + ltrimstr("./") else . end
	| path_text;
def counted($count; $one; $many): "\($count) \(if $count == 1 then $one else $many end)";
def items: map("- " + .) | join("\n");
def headed($heading; $lines): "**\($heading)**\n" + ($lines | items);
def counted_section($heading; $lines):
	if ($lines | length) == 0 then "" else headed("\($heading) (\($lines | length))"; $lines) end;
def open_kinds: [["assumption", "assumption", "assumptions"], ["could_not", "could not do", "could not do"],
	["missing_plugin", "missing plugin", "missing plugins"], ["contract_break", "contract break", "contract breaks"],
	["gate_refused", "gate refused", "gates refused"]];

def count_lines:
	listed_files as $files
	| ([$files[] | select(.label == "created")] | length) as $created
	| ([$files[] | select(.label == "deleted")] | length) as $deleted
	| [$files | length | select(. > 0) | counted(.; "file changed"; "files changed")
		+ (if $created > 0 then ", \($created) new" else "" end)
		+ (if $deleted > 0 then ", \($deleted) deleted" else "" end)]
	+ [open_kinds[] as [$kind, $one, $many] | open_of($kind) | length | select(. > 0) | counted(.; $one; $many)];
# A gate run more than once is told apart by its command.
def gate_lines:
	objects_of("verification") as $gates
	| [$gates[] | .gate | txt] as $names
	| [$gates[] | (.gate | txt) as $gate
		| (if .result == "pass" then "✅ \($gate)"
		   elif .result == "fail" then "⛔ \($gate)"
		   elif (.note | txt) == "" then "⚠️ \($gate)"
		   else "⚠️ \($gate): \(.note | txt)" end)
		+ (if ([$names[] | select(. == $gate)] | length) > 1 and (.command | txt) != "" then " (\(.command | txt | link_span))" else "" end)];
def warning_lines:
	[objects_of("open")[] | select(.kind | among(uncapped_kinds))
		| (.at // .ref) as $where
		| "⚠️ \(.kind | words)" + (if ($where | txt) == "" then "" else ": \($where | place)" end)];
def card($card; $title; $path):
	(objects_of("blockers") | length > 0) as $blocked
	| ["### \($title | txt) · \(if $blocked then "blocked" else "done" end)",
	   (count_lines | items),
	   headed("Gates"; gate_lines),
	   counted_section("Blockers"; [objects_of("blockers")[] | "⛔ \(.kind | words): \(.location | place)"]),
	   counted_section("Deviations"; [objects_of("deviations")[] | "⚠️ \(.what | txt)"]),
	   counted_section("Warnings"; warning_lines),
	   headed("Do"; if $card.do == [] then ["Nothing for you to do."] else $card.do end),
	   headed("Decide"; if $card.decide == [] then ["Nothing to decide."] else $card.decide end),
	   "**Report:** \($path | path_text)",
	   "_Ask for details: what changed, the decisions, or anything in the report._"]
	| blocks;
'

# Prints "refused" and one problem per line (the report's, then the card
# file's), or "card" and the card. An unstamped report is taken only with
# --dispatch ($dispatch_given).
# shellcheck disable=SC2016
readonly CARD_MAIN_JQ='
$report[0] | as_written
| (objects_of("blockers") | length) as $blockers
| (if $dispatch_given or (. as $written | any(stamp_keys[]; . as $key | $written | has($key))) then []
   else ["report is not stamped; expected a report check stamped, or --dispatch for one it left unstamped"] end) as $unstamped
| (problems + $unstamped + [$card[0] | card_problems($blockers)]) as $refusals
| if ($refusals | length) > 0 then "refused", $refusals[]
  else "card", card($card[0]; $seat | title("developer"); $report_path) end
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

# The top --help page: every usage line, the commands and what no single
# command owns. Each command's own contract is its `<command> --help` page.
usage() {
	usage_prefix='usage: '
	usage_lines check card baseline doc-check
	usage_line 'report.sh <command> --help'
	usage_line 'report.sh --help | -h'
	cat <<'EOF'

Checks the developer's report, one JSON object in PATH, stamps it from its
dispatch file on a pass, and prints the human's card for it as Markdown.
stdin is never read.
With no arguments, prints this page on stderr and exits 2.
EOF
	help_shared shape
	cat <<'EOF'

Commands (each page holds its options, output, exit codes and dependencies):
  check      checks the report's shape; with --dispatch, stamps it on a pass
  card       prints the report's card for the human: state, gates, what to do
             and what to decide
  baseline   writes an iteration's baseline, which check compares with
  doc-check  compares the report standard's field table with the validator
EOF
}

# The `<command> --help` page of command $1.
command_help() {
	usage_prefix='usage: '
	usage_lines "$1"
	case $1 in
		check) check_help ;;
		card) card_help ;;
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
                      --round, --report is the iteration's own report)
EOF
	help_shared report-repo
	cat <<'EOF'
  --mode BUILD        the dispatch mode; only BUILD is taken
  --context FILE      the context file; each could_not ref names an entry;
                      with --round, message: CHANGES also names the work the
                      iteration skipped from its change list
  --findings FILE     an iteration's review finding IDs, one per line;
                      review_responses answers each exactly once
  --round 'iteration N'
                      N a positive integer: the report of iteration N, which
                      covers that iteration alone; --baseline is required.
                      With --dispatch, --report is then required: an existing
                      file in the folder of the dispatch's report, not that
                      report itself, and the stamps still come from the
                      dispatch. Left out on the dispatch's first report
  --baseline FILE     without --dispatch: git status --porcelain=v1 -z
                      --no-renames of --repo from before the dispatch; needs
                      --repo. With --round: the iteration's baseline, the file
                      report.sh baseline wrote before it, naming no other
                      --round, --report or --dispatch. Never with --dispatch
                      alone
EOF
	help_shared skills-dir
	cat <<'EOF'

stdout on exits 0, 1, 3 and 6: one count line, <kind>=<n> per kind
stderr on exit 3: one "<field>: <what>; expected <x>" line per problem, at
  most 30, then a count of the rest.

Writes: with --dispatch, on exit 0 or 1 only, the report into PATH: the
stamps dispatch, started, finished, mode and plugins (the dispatch's plugin
names by kind) first, its own keys after them, a key holding nothing (null,
[] or {}) left out. Any other exit leaves PATH byte for byte as it was.
EOF
	help_shared writes-nothing-else
	cat <<'EOF'

Exit codes:
  0  valid (stamped, with --dispatch); go on
  1  valid with open blockers (stamped, with --dispatch); treat as blocked
EOF
	help_shared exit-usage 'fix the command'
	help_shared exit-dispatch-fault
	echo '  3  invalid; have the fields stderr names fixed, check again'
	help_shared exit-not-a-report 'have the report written again'
	help_shared exit-install
	cat <<'EOF'
  6  --dispatch: valid, the stamping failed; show it with card --dispatch
EOF
	help_shared exit-signal
	help_shared dependencies
	help_shared names-module
	help_shared own-skill
	printf '  with --repo: '
	help_shared git
	cat <<'EOF'
  with --dispatch: flow-agent-initialization's dispatch validator, the
    crucible skill (its scripts/lib/prune.jq), and sha256sum or shasum
    (macOS: shasum -a 256)
EOF
}

card_help() {
	cat <<'EOF'

Prints the report's card for the human as Markdown on stdout: a heading with
the developer title ("Rust developer", "Kotlin developer with Spring";
"Generic developer" with no language) and the state, done or
blocked; the files changed and the open items by kind; each gate; the
blockers, deviations and warnings (instructions and secrets found), each
whole, a repo-relative location joined to the dispatch's repo_root; then the
main thread's Do and Decide lines and the report's path. Every item is on its
own line; no value from the report or the card file adds one.
EOF
	help_shared shape
	help_shared options
	cat <<'EOF'
  --report PATH       the report file, stamped by check --dispatch, or
                      unstamped with --dispatch; it must pass check's shape
                      check (a stamped one: without the text, word and item
                      caps, which bind when a report is written)
  --labels-file FILE  the hand-back's LABELS line, whole, at most 1000 bytes;
                      its Language and Frameworks build the developer title
                      (default: the metadata.label of the language and
                      frameworks in the report's plugins stamp, or for an
                      unstamped report in the --dispatch file's plugins; each
                      plugin's name when it is not installed or has no label)
  --card-file FILE    the main thread's lines, one JSON object
                      {"do": [lines], "decide": [lines]}, each array 0 to 5
                      lines; a line is a non-empty string of at most 240
                      characters with no line break, tab or other control
                      character, not starting with #, -, >, a * list mark
                      ("* " or a rule) or a number and a dot; inline Markdown
                      (bold, backticks) prints as is.
                      Both empty is refused when the report has blockers
  --dispatch FILE     the dispatch of a report check could not stamp: it must
                      pass the dispatch validator and --report must be in the
                      folder of its report (that report or an iteration's); a
                      stamped report must be stamped from it
EOF
	help_shared skills-dir
	cat <<'EOF'

stdout on exit 0: the card; nothing on any other exit.
stderr on exit 3: one "<field>: <what>; expected <x>" line per problem: the
  report's (at most 30, then a count of the rest), then the card file's.
EOF
	echo
	help_shared writes-nothing-else
	cat <<'EOF'

Exit codes:
  0  printed; show it
EOF
	help_shared exit-usage 'fix the command once, else show the human stderr, and stop'
	help_shared exit-dispatch-fault
	echo '  3  refused; fix what stderr names'
	help_shared exit-not-a-report 'show the human stderr, and stop'
	help_shared exit-install
	help_shared exit-signal
	help_shared dependencies
	help_shared names-module
	help_shared own-skill
	help_shared human-view
	help_shared dispatch-validator
	printf '  without --dispatch: the crucible skill (crucible.sh path), for the repo root\n'
}

baseline_help() {
	cat <<'EOF'

Writes an iteration's baseline, taken just before the iteration is sent: the
repo's changes and a content fingerprint of each changed file, so check
--round 'iteration N' can count a file changed in the iteration even when an
earlier one changed it too.
EOF
	help_shared options
	cat <<'EOF'
  --repo DIR          the root of a git work tree
  --out FILE          the iteration's baseline file: an existing, empty regular
                      file, not a symlink; a file holding anything is refused
  --dispatch FILE     the dispatch the iteration is sent in: it must pass the
                      dispatch validator and have --repo as its repo_root.
                      Given with --report and --round, or none of the three
  --report PATH       the iteration's own report: an existing file in the
                      folder of the dispatch's report, not that report itself
  --round 'iteration N'
                      N a positive integer: the iteration
EOF
	help_shared skills-dir
	cat <<'EOF'

Writes: into FILE, on exit 0 only, one JSON object:
  {"repo_root": DIR,
   "entries": [each entry of git status --porcelain=v1 -z --no-renames
     --untracked-files=all, "XY <path>", its NUL taken off],
   "fingerprints": {"<path>": git hash-object --no-filters of it, for each
     listed path that is a regular file},
   with --dispatch: "dispatch": FILE, "report": PATH, "round": "iteration N"}
  check --round refuses a baseline naming another --round, --report or
  --dispatch than it is given.
stdout: nothing.
EOF
	help_shared writes-nothing-else
	cat <<'EOF'

Exit codes:
  0  written; send the iteration
EOF
	help_shared exit-usage 'show the human stderr, and stop'
	help_shared exit-install ' (FILE left empty)'
	help_shared exit-signal
	help_shared dependencies
	printf '  '
	help_shared git
	help_shared dispatch-validator
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
EOF
	help_shared exit-usage 'fix the command'
	cat <<'EOF'
  5  install fault; install what stderr names
EOF
	help_shared exit-signal
	help_shared dependencies
	help_shared names-module
}

# Prints the usage lines of each command named, the first after usage_prefix.
usage_lines() {
	for usage_command in "$@"; do
		case ${usage_command} in
			check)
				usage_line "report.sh check --dispatch FILE [--report PATH] [--repo DIR] [--mode BUILD] [--context FILE] [--findings FILE] [--round 'iteration N' --baseline FILE] [--skills-dir DIR]"
				usage_line "report.sh check --report PATH --repo DIR --mode BUILD [--round 'iteration N'] [--baseline FILE] [--findings FILE] [--context FILE] [--skills-dir DIR]"
				;;
			card) usage_line 'report.sh card --report PATH --card-file FILE [--labels-file FILE] [--dispatch FILE] [--skills-dir DIR]' ;;
			baseline) usage_line "report.sh baseline --repo DIR --out FILE [--dispatch FILE --report PATH --round 'iteration N'] [--skills-dir DIR]" ;;
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
		writes-nothing-else) printf 'Nothing else is left behind (a SIGKILL aside); the repo, its index and its\nobject store are never changed.\n' ;;
		dependencies)
			cat <<'EOF'

Dependencies (other skills in --skills-dir):
  POSIX sh; jq 1.6+ (macOS: brew install jq; Linux: the distro's jq)
  awk, cat, cp, date, grep, mktemp, mv, rm, sed, tr, wc (every macOS and
    Linux base system)
EOF
			;;
		names-module) printf '  the flow-agent-initialization skill (its dispatch-names.jq)\n' ;;
		git) printf "git (macOS: xcode-select --install; Linux: the distro's git)\n" ;;
		exit-usage) printf '  2  usage error; %s\n' "$2" ;;
		exit-dispatch-fault) printf '     report.sh: dispatch:  a dispatch fault; show the human stderr, and stop\n' ;;
		exit-not-a-report) printf '  4  not a report (PATH not one JSON object); %s\n' "$2" ;;
		exit-install) printf '  5  install fault; show the human stderr, and stop%s\n' "${2:-}" ;;
		dispatch-validator) printf "  with --dispatch: flow-agent-initialization's dispatch validator\n" ;;
		exit-signal) printf '  129, 130, 143  stopped by HUP, INT or TERM; show the human stderr, and stop\n' ;;
		own-skill) printf "  this skill's SKILL.md, beside scripts/\n" ;;
		human-view) printf '  the human-view skill\n' ;;
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
		check | card | baseline | doc-check) command=$1 ;;
		*) usage_error "unknown command: $1; expected check, card, baseline, doc-check or --help" ;;
	esac
	shift
	report='' repo='' baseline='' baseline_kind='' dispatch_baseline='' mode='' findings='' context='' labels_file='' card_file='' round='' dispatch_file='' skill_file='' out_file=''
	skills_dir="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/skills"
	while [ "$#" -gt 0 ]; do
		case $1 in
			--help | -h)
				command_help "${command}"
				exit 0
				;;
			--report | --repo | --baseline | --mode | --findings | --context | --labels-file | --card-file | --round | --skills-dir | --dispatch | --skill | --out)
				[ "$#" -ge 2 ] && [ -n "$2" ] || usage_error "$1 needs a value; expected $1 VALUE"
				set_option "$1" "$2"
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
	if [ "${command}" = card ]; then
		check_card_args
		return 0
	fi
	[ -z "${card_file}" ] || usage_error '--card-file is for card only; expected it only with card'
	check_check_round
	[ -z "${dispatch_file}" ] || read_dispatch
	check_common_args
	check_check_args
}

set_option() {
	case $1 in
		--report) report=$2 ;;
		--repo) repo=$2 ;;
		--baseline) baseline=$2 ;;
		--mode) mode=$2 ;;
		--findings) findings=$2 ;;
		--context) context=$2 ;;
		--labels-file) labels_file=$2 ;;
		--card-file) card_file=$2 ;;
		--round) round=$2 ;;
		--dispatch) dispatch_file=$2 ;;
		--skill) skill_file=$2 ;;
		--out) out_file=$2 ;;
		*) skills_dir=$2 ;;
	esac
}

# Checks the --dispatch file against the dispatch validator, takes --report
# (unless an iteration's), --repo, --context and --mode from it, sets stamps to
# the stamps it supplies (finished comes at the pass; plugins by kind, names
# only), dispatch_context_sha256 to the context file's pinned sha256 and
# dispatch_baseline to its baseline file (not read on an iteration, which
# compares with its own --baseline). Exits 2 on a bad file (stderr starting
# "report.sh: dispatch:"), a conflicting flag or a --baseline without --round,
# 5 when the validator is missing.
read_dispatch() {
	[ -n "${round}" ] || [ -z "${baseline}" ] ||
		usage_error "--baseline is not taken with --dispatch: the dispatch's baseline key names the baseline the Agent hook wrote at the call; expected --baseline left out"
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

# An iteration's report is a new file beside the dispatch's own report, in the
# effort's reports/development/ folder, so every iteration keeps its own report
# and the dispatch's first report stays as it was stamped. Exits 2 otherwise.
check_round_report() {
	round_report_expected="expected the iteration's own report file, beside the dispatch's report ${dispatch_report}"
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
		usage_error "--report ${report} is not an existing file; ${round_report_expected}, made before the iteration was sent"
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

# baseline takes --repo and --out, each absolute, --out an existing, empty
# regular file that is not a symlink, so a baseline is written once; and
# --dispatch, --report and --round together or not at all.
check_baseline_args() {
	for other in "${baseline}" "${mode}" "${findings}" "${context}" "${labels_file}" "${card_file}" "${skill_file}"; do
		[ -z "${other}" ] || usage_error "baseline takes only --repo, --out, --dispatch, --report, --round and --skills-dir; expected baseline --repo DIR --out FILE [--dispatch FILE --report PATH --round 'iteration N']"
	done
	if [ -n "${dispatch_file}${report}${round}" ]; then
		[ -n "${dispatch_file}" ] && [ -n "${report}" ] && [ -n "${round}" ] ||
			usage_error "--dispatch, --report and --round go together; expected all three, naming the iteration the baseline is for, or none"
		check_round_value 'the iteration the baseline is for'
	fi
	case ${repo} in
		'') usage_error '--repo DIR missing; expected the absolute path of the repository root' ;;
		/*) ;;
		*) usage_error "--repo ${repo} is not absolute; expected the absolute path of the repository root" ;;
	esac
	out_expected="expected the iteration's baseline file, existing and empty"
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
	for other in "${report}" "${repo}" "${baseline}" "${mode}" "${findings}" "${context}" "${labels_file}" "${card_file}" "${round}" "${dispatch_file}"; do
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
	[ -z "${labels_file}" ] || usage_error 'check takes no --labels-file; expected it only with card'
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

# card takes --report and --card-file, each absolute, and --labels-file,
# --dispatch and --skills-dir. The report path is printed on the card, so it
# may hold no control character.
check_card_args() {
	for check_only in "${repo}" "${baseline}" "${mode}" "${findings}" "${context}" "${round}"; do
		[ -z "${check_only}" ] || usage_error 'card takes only --report, --card-file, --labels-file, --dispatch and --skills-dir; expected card --report PATH --card-file FILE [--labels-file FILE] [--dispatch FILE]'
	done
	check_common_args
	case ${report} in
		*[[:cntrl:]]*) usage_error '--report holds a control character; expected the path of the report file, printed on the card whole' ;;
		*) ;;
	esac
	[ -z "${labels_file}" ] || read_labels_file
	card_file_expected='expected the main thread'"'"'s card file, {"do": [lines], "decide": [lines]}'
	case ${card_file} in
		'') usage_error "--card-file FILE missing; ${card_file_expected}" ;;
		/*) ;;
		*) usage_error "--card-file ${card_file} is not absolute; ${card_file_expected}, by its absolute path" ;;
	esac
	[ -f "${card_file}" ] && [ -r "${card_file}" ] ||
		usage_error "--card-file not readable: ${card_file}; ${card_file_expected}, a regular file"
}

# check takes --round only as 'iteration N', and only with --baseline: the
# dispatch's first report is checked without it.
check_check_round() {
	[ -n "${round}" ] || return 0
	check_round_value "the iteration the report covers; left out on the dispatch's first report"
	[ -n "${baseline}" ] ||
		usage_error "--round ${round} needs --baseline FILE; expected the iteration's baseline, the file report.sh baseline wrote before the iteration"
}

# Exits 2 unless round is 'iteration N' with N a positive integer; $1 says
# what the iteration names.
check_round_value() {
	case ${round} in
		'iteration '*[!0-9]* | 'iteration 0'* | 'iteration ') usage_error "--round ${round} is not 'iteration N' with N a positive integer; expected 'iteration 2'" ;;
		'iteration '*) ;;
		*) usage_error "--round ${round} is unknown; expected 'iteration N', $1" ;;
	esac
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
# left beside a file being written (the stamped report, the iteration baseline).
make_work_dir() {
	partial_file=''
	work_dir=$(mktemp -d "${TMPDIR:-/tmp}/report-sh.XXXXXX") || install_fault 'mktemp -d failed; expected a writable TMPDIR'
	trap 'rm -rf "${work_dir}"; [ -z "${partial_file}" ] || rm -f "${partial_file}"' EXIT
	trap 'exit 129' HUP
	trap 'exit 130' INT
	trap 'exit 143' TERM
}

# Copies the report file once to report_copy, which the check, the card and
# the stamps all read, so what is stamped is what was checked. Exits 4 unless it holds exactly one JSON object
# (or, before stamping, it is a symlink).
check_report() {
	[ -f "${report}" ] && [ -r "${report}" ] ||
		not_a_report "${report} is missing, unreadable or not a regular file; expected the file the first message's REPORT names"
	[ "${command}" != check ] || [ -z "${dispatch_file}" ] || [ ! -L "${report}" ] ||
		not_a_report "${report} is a symlink; expected the report file itself, which check --dispatch stamps"
	report_copy="${work_dir}/report"
	cat "${report}" >"${report_copy}" ||
		not_a_report "${report} cannot be read; expected the file the first message's REPORT names"
	shape=$(jq -rs 'if length == 1 and (.[0] | type) == "object" then "object" elif length == 1 then "a JSON \(.[0] | type)" else "\(length) values" end' "${report_copy}" </dev/null 2>/dev/null) ||
		not_a_report "${report} is not valid JSON; expected one JSON object; try checking its quotes, commas and brackets"
	[ "${shape}" = object ] ||
		not_a_report "${report} holds ${shape}; expected exactly one JSON object"
}

# Writes git status for the repo and the baseline, NULs as \001, to git_file
# and baseline_file; with no repo, empty files and have_git false. The
# baseline is the --baseline file, else the --dispatch file's baseline file.
# An iteration's baseline is turned into the same two files by
# apply_round_baseline.
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
	elif [ -n "${dispatch_baseline}" ]; then
		load_dispatch_baseline
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
# round for an iteration's baseline (one JSON object, which a saved git status
# never is), checked against the shape, --repo and the iteration it names;
# else status, its NULs as \001 into baseline_file. check --round takes only
# an iteration baseline, and one is taken only with --round 'iteration N'.
# Exits 2 otherwise.
read_given_baseline() {
	given_baseline="${work_dir}/baseline.given"
	cat "${baseline}" >"${given_baseline}" ||
		usage_error "--baseline file not readable: ${baseline}; expected the saved git status"
	baseline_kind=status
	if jq -es 'length == 1 and (.[0] | type) == "object"' "${given_baseline}" </dev/null >/dev/null 2>&1; then
		baseline_kind=round
	fi
	round_baseline_expected="expected the file report.sh baseline --repo ${repo} --out FILE wrote before the iteration"
	case ${baseline_kind}:${round} in
		round:'iteration '*) check_round_baseline ;;
		round:*) usage_error "--baseline ${baseline} is an iteration's baseline; expected it only with --round 'iteration N'" ;;
		status:'iteration '*) usage_error "--baseline ${baseline} is not an iteration's baseline; ${round_baseline_expected}" ;;
		*) ;;
	esac
	[ "${baseline_kind}" = round ] || tr '\000' '\001' <"${given_baseline}" >"${baseline_file}" ||
		usage_error "--baseline file not readable: ${baseline}; expected the saved git status"
}

# Exits 2 unless the iteration baseline copy has the shape `baseline` writes,
# for --repo, and names no other iteration than --round, --report and
# --dispatch.
check_round_baseline() {
	# shellcheck disable=SC2016 # jq variables, not shell ones
	round_baseline_problem=$(jq -rs --arg repo_root "${repo}" --arg round "${round}" --arg report "${report}" --arg dispatch "${dispatch_file}" \
		"${ROUND_BASELINE_JQ}"'.[0] | round_baseline_problems($repo_root; $round; $report; $dispatch)' \
		"${given_baseline}" </dev/null) ||
		install_fault 'jq failed on the iteration baseline shape; expected jq 1.6+; try jq --version'
	[ -n "${round_baseline_problem}" ] || return 0
	round_baseline_problem=$(printf '%s\n' "${round_baseline_problem}" | sed -n '1p')
	usage_error "--baseline ${baseline} is not an iteration's baseline: ${round_baseline_problem}; ${round_baseline_expected}"
}

# Sets baseline_file to the iteration baseline's entries the iteration left
# alone and adds to git_file an entry for each path it put back, and writes
# round_created_file, the created paths the report may list as modified
# (ROUND_COMPARE_JQ). Only a path git still lists can be left alone, so the
# fingerprints now are taken of the paths in git_file.
apply_round_baseline() {
	write_fingerprints "${git_file}" "${work_dir}/fingerprints-now"
	for round_part in unchanged reverted created; do
		jq -nj --slurpfile round "${given_baseline}" --slurpfile now "${work_dir}/fingerprints-now" \
			--rawfile git "${git_file}" --arg part "${round_part}" \
			"\$round[0] as \$round | \$now[0] as \$now | ${ROUND_COMPARE_JQ}" </dev/null >"${work_dir}/round-${round_part}" ||
			install_fault 'jq failed comparing the iteration baseline with git; expected jq 1.6+; try jq --version'
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
		--arg mode BUILD --arg stamp_check check --arg findings_mode none --arg findings_text '' --arg round '' \
		"${STAMP_JQ}null as \$context | true as \$write_rules | ${COMMON_JQ}${SHAPE_JQ}${DOC_CHECK_JQ}" </dev/null) ||
		install_fault "jq failed comparing ${1} with the validator; expected jq 1.6+; try jq --version"
}

# check and card first hold this script to its own skill's SKILL.md (the one
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
		--argjson have_git "${have_git}" --arg mode "${mode}" --arg stamp_check check --arg round "${round}" "$@" \
		"${STAMP_JQ}${context_expr} as \$context | true as \$write_rules | ${COMMON_JQ}${SHAPE_JQ}${CHECK_JQ}" </dev/null) ||
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

# Prints the card of report_copy on stdout, or its problems and the card
# file's on stderr with exit 3.
run_card() {
	locate_view_modules
	read_card_file
	dispatch_given=false stamped_id=''
	if [ -n "${dispatch_file}" ]; then
		check_card_dispatch
		dispatch_given=true
	fi
	[ -n "${labels_file}" ] || read_card_seat
	read_card_repo_root
	output=$(jq -nr -L "${skills_dir}/${VIEW_LIB}" -L "${names_module%/*}" --slurpfile report "${report_copy}" --slurpfile card "${card_copy}" \
		--arg git '' --arg baseline '' --arg round_created '' --argjson have_git false \
		--arg mode BUILD --arg findings_mode unchecked --arg findings_text '' --arg stamp_check card --arg round '' \
		--argjson seat "${seat}" --argjson dispatch_given "${dispatch_given}" --arg report_path "${report}" --arg repo_root "${repo_root}" \
		"include \"paths\"; include \"view\"; include \"title\"; ${STAMP_JQ}null as \$context | (\$report[0] | stamped | not) as \$write_rules | ${COMMON_JQ}${SHAPE_JQ}${CARD_RULES_JQ}${CARD_VIEW_JQ}${CARD_MAIN_JQ}" </dev/null) ||
		install_fault 'jq failed on a valid JSON report; expected jq 1.6+; try jq --version'
	verdict=$(printf '%s\n' "${output}" | sed -n '1p')
	if [ "${verdict}" = card ]; then
		printf '%s\n' "${output}" | sed '1d'
		exit 0
	fi
	printf '%s\n' "${output}" | sed '1d' >&2
	exit 3
}

# Exits 5 unless human-view's paths.jq, view.jq and title.jq are installed.
locate_view_modules() {
	for view_module in paths view title; do
		view_module_file="${skills_dir}/${VIEW_LIB}/${view_module}.jq"
		[ -f "${view_module_file}" ] && [ -r "${view_module_file}" ] ||
			install_fault "${VIEW_LIB}'s ${view_module}.jq missing; expected ${view_module_file}; install the ${VIEW_LIB} skill in ${skills_dir}"
	done
}

# Copies the card file once to card_copy, the copy the card reads; exits 3
# unless it holds exactly one JSON value (card_problems judges its shape).
read_card_file() {
	card_copy="${work_dir}/card"
	cat "${card_file}" >"${card_copy}" || usage_error "--card-file not readable: ${card_file}; ${card_file_expected}"
	card_values=$(jq -s 'length' "${card_copy}" </dev/null 2>/dev/null) ||
		card_refused "card: not valid JSON; ${card_file_expected}"
	[ "${card_values}" -eq 1 ] || card_refused "card: ${card_values} JSON values; ${card_file_expected}, one object"
}

# Sets seat, with no --labels-file, from the plugins of an unstamped report's
# --dispatch file, else from the report's plugins stamp.
read_card_seat() {
	if [ "${dispatch_given}" = true ] && [ -z "${stamped_id}" ]; then
		read_seat "${dispatch_file}"
	else
		read_seat "${report_copy}"
	fi
}

# Sets repo_root, which repo-relative locations are joined to: the --dispatch
# file's repo_root (the validator holds it to one absolute line), else that of
# the dispatch the report is stamped with; nothing when it cannot be found.
read_card_repo_root() {
	if [ "${dispatch_given}" = true ]; then
		repo_root=${dispatch_repo}
	else
		read_report_repo
		repo_root=${report_repo}
	fi
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
	report_repo=$(jq -r '.repo_root | strings | select(startswith("/") and (test("[[:cntrl:]]") | not))' "${stamped_dispatch}" </dev/null 2>/dev/null) || report_repo=''
}

card_refused() {
	printf '%s\n' "$1" >&2
	exit 3
}

# Exits 2 unless --dispatch passes the dispatch validator, --report is in the
# folder of its report (that report or an iteration's) and a stamped report
# is stamped from it.
check_card_dispatch() {
	read_dispatch_baseline "${dispatch_file}" --dispatch
	[ "${report%/*}" = "${dispatch_report%/*}" ] ||
		usage_error "--report ${report} is not in the folder of the --dispatch file's report ${dispatch_report}; expected that report or an iteration's beside it"
	read_stamped_id
	[ -z "${stamped_id}" ] || [ "${stamped_id}" = "${dispatch_id}" ] ||
		usage_error "--dispatch ${dispatch_file} is dispatch ${dispatch_id}, but the report is stamped from ${stamped_id}; expected the stamped dispatch, or --dispatch left out"
}

# Sets seat to the {language, frameworks} labels title() takes for the plugins
# of file $1, a stamped report (plugin names) or a dispatch (plugin objects,
# each with its name): each plugin's label, or its name when it has none; {}
# for no language and no framework.
read_seat() {
	# The language, then each framework, one "<kind> <name>" per line.
	# shellcheck disable=SC2016 # a jq program, not shell expansions
	stamped_seat=$(jq -r 'def name: if type == "object" then .name else . end;
		.plugins | objects
		| (.language | name | strings | "language \(.)"), (.frameworks | arrays | .[] | name | strings | "framework \(.)")
		| gsub("[[:cntrl:]]"; "")' "$1" </dev/null) ||
		install_fault 'jq failed reading the plugin names; expected jq 1.6+; try jq --version'
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

# Writes the iteration baseline of repo into out_file: built in the temp
# folder, then moved into place through a temp file beside it that keeps
# out_file's permissions, so out_file is either empty or whole. With
# --dispatch, it also names the iteration: the dispatch, its --report and --round.
run_baseline() {
	[ -z "${dispatch_file}" ] || check_baseline_dispatch
	check_repo_root
	write_git_status "${work_dir}/round-status"
	write_fingerprints "${work_dir}/round-status" "${work_dir}/round-fingerprints"
	# shellcheck disable=SC2016 # jq variables, not shell ones
	jq -n --arg repo_root "${repo}" --rawfile status "${work_dir}/round-status" --slurpfile fingerprints "${work_dir}/round-fingerprints" \
		--arg dispatch "${dispatch_file}" --arg report "${report}" --arg round "${round}" \
		'{repo_root: $repo_root, entries: ($status | split("\u0001") | map(select(length > 3))), fingerprints: $fingerprints[0]}
		+ (if $dispatch == "" then {} else {dispatch: $dispatch, report: $report, round: $round} end)' \
		</dev/null >"${work_dir}/round-baseline" ||
		install_fault 'jq failed building the iteration baseline; expected jq 1.6+; try jq --version'
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

# Exits 2 unless --dispatch passes the dispatch validator, has --repo as its
# repo_root, and --report is the iteration's own report beside the dispatch's.
check_baseline_dispatch() {
	read_dispatch_baseline "${dispatch_file}" --dispatch
	[ "${repo}" = "${dispatch_repo}" ] ||
		usage_error "--repo ${repo} differs from the --dispatch file's repo_root ${dispatch_repo}; expected the same text"
	check_round_report
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
[ "${command}" != check ] || [ -z "${dispatch_file}" ] || pin_context
check_report
[ "${command}" = check ] || run_card
read_git_status
run_check
