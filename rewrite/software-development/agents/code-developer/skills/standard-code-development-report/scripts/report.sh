#!/usr/bin/env sh
# Checks the developer's report JSON and renders it for the human, the
# reviewer and a TEST dispatch. The jq validator below owns the report's
# shape (there is no schema file): the report standard's field table and
# --help document it, and the validator wins where they differ. Path display
# goes through lib-render's paths.jq.
set -eu

readonly PROG='report.sh'
readonly RENDER_LIB='lib-render'
# The render lists at most this many files where the report and git disagree:
# an un-ignored build folder can add thousands, which would bury the report.
readonly MAX_MISMATCHES=20
# A LABELS line names one technology and a handful of standards, well under
# this; a bigger file is not the hand-back's line.
readonly MAX_LABELS_BYTES=1000
# The render names this many of the files the baseline leaves unchecked, as
# examples on one line; the count says how many there are.
readonly MAX_BASELINE_SHOWN=5

# Definitions the check and the render share: how git's changes compare with
# the report's files lists. $git and $baseline hold `git status --porcelain -z`
# output with each NUL turned into \u0001 ($have_git false when no repo was
# given); $baseline is the tree before the dispatch, and a path changed there
# (or under a folder it lists, ending in /) is left out of the comparison.
# The programs are single-quoted on purpose: their $ signs are jq's.
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
# Paths still changed in the repo that the comparison skips for the baseline.
def baseline_skipped: baseline_paths as $before | all_git_changes | map(select(.path | in_baseline($before)) | .path);
def listed_files:
	(.files // {}) as $files
	| if ($files | type) != "object" then []
	  else [("created", "modified", "deleted") as $label
		| ($files[$label] // []) | if type == "array" then .[] else empty end
		| strings | ltrimstr("./") | {path: ., label: $label}] end;
def file_mismatches:
	if $have_git | not then []
	else git_changes as $changes
		| baseline_paths as $before
		| [listed_files[] | select(.path | in_baseline($before) | not)] as $listed
		| [($changes[] | . as $change
			| [$listed[] | select(.path == $change.path)] as $matches
			| if ($matches | length) == 0 then {path: $change.path, note: null}
			  elif any($matches[]; .label == $change.label) then empty
			  else {path: $change.path, note: "listed as \($matches[0].label), git shows \($change.label)"} end),
		   ($listed[] | . as $entry | select(any($changes[]; .path == $entry.path) | not)
			| {path: $entry.path, note: "listed as \($entry.label), git shows no change"})]
	end;
def objects_of($key): .[$key] | if type == "array" then map(select(type == "object")) else [] end;
def open_of($kind): [objects_of("open")[] | select(.kind == $kind)];
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
def required_keys: ["summary", "tech", "files", "deviations", "behavior", "verification"];
def optional_keys: ["focus", "decisions", "noticed", "open", "blockers", "review_responses"];
def reserved_keys: ["untested", "repaired", "mutation"];
def stamped_keys: ["mode", "round", "labels", "LABELS"];
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
	"blockers.kind": ["test_compile_broken", "gate_red", "finding_blocked", "code_untestable", "tests_red_before_refactor"],
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
def location_expected: "a repo-relative path:line, brief: <FIELD>, a plugin name and file, a context entry (paths[<n>], links[<n>] or its URL) or commit <sha>";

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
		 then "\($loc).note: missing on result \(.result); expected why it did not pass (for narrowed, the brief words quoted and the coverage given up)" else empty end),
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
	| ((keys - $known)[] as $key
		| if $key | among(reserved_keys) then "\($key): reserved for the TEST mode; expected it left out on BUILD"
		  elif $key | among(stamped_keys) then "\($key): written into the report; expected it left out: never write mode, round or LABELS (the script stamps the round into the render, the mode goes to check only, and LABELS comes from the hand-back)"
		  else "\($key | shown): unknown key; expected only \($known | names)" end),
	  (required_keys[] as $key | select(has($key) | not) | "\($key): missing; expected the key, as the report standard\u0027s field table shows");
def summary_problems:
	if has("summary") | not then empty
	elif .summary | text_ok | not then "summary: not a non-empty string; expected what changed, in at most \(max_words) words"
	elif (.summary | word_count) > max_words then "summary: \(.summary | word_count) words; expected at most \(max_words)"
	else empty end;
def tech_problems: select(has("tech")) | .tech | field_line("tech"; "tech");
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
		(if has("review_responses") then "review_responses: given outside a fix round; expected it left out (only a check run with --findings takes it)" else empty end)
	elif has("review_responses") | not then
		"review_responses: missing on a fix round; expected one item per brief finding ID: \(findings_list | names)"
	elif (.review_responses | type) != "array" then empty
	else findings_list as $findings
		| .blockers as $blockers
		| [.review_responses[] | objects | .id | strings] as $ids
		| ($findings[] as $id | [$ids[] | select(. == $id)] | length
			| if . == 0 then "review_responses: \($id | shown) missing; expected each brief finding ID exactly once"
			  elif . > 1 then "review_responses: \($id | shown) given \(.) times; expected it exactly once"
			  else empty end),
		  ($ids | unique[] | select(among($findings) | not)
			| "review_responses: \(shown) is not a brief finding ID; expected only \($findings | names)"),
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
		| "open[\($index)].ref: \(.ref | shown) names no context entry; expected a paths[].path or links[].url of the context file, or paths[<n>], links[<n>] or notes[<n>], counted from 1"
	end;

def count_line:
	"blockers=\(objects_of("blockers") | length) instruction_found=\(open_of("instruction_found") | length) secret_found=\(open_of("secret_found") | length) missing_plugin=\(open_of("missing_plugin") | length) could_not=\(open_of("could_not") | length) deviations=\(objects_of("deviations") | length) unlisted=\(file_mismatches | length)";

def problems:
	[key_problems, summary_problems, tech_problems, files_problems,
	 (("deviations", "behavior", "verification", "focus", "decisions", "noticed", "open", "blockers", "review_responses") as $key | list_problems($key)),
	 minimum_problems, findings_problems, context_problems]
	| .[:max_problems] + (if length > max_problems then ["report: \(length - max_problems) more problems not shown (showing \(max_problems) of \(length)); expected none"] else [] end);
'

# Prints the count line, then the shape problems, one per line.
# shellcheck disable=SC2016
readonly CHECK_JQ='
$report[0] | count_line, problems[]
'

# The human view and the --for slice. Tolerant of a broken shape, since the main
# thread renders an invalid report once the resends run out: its problems show
# under Check these, a value of the wrong type prints as its JSON, a list of the
# wrong type as no items.
# shellcheck disable=SC2016
readonly RENDER_JQ='
def txt: if type == "string" then . elif . == null then "" else tojson end
	| gsub("[[:cntrl:]]+"; " ") | sub("^ +"; "") | sub(" +$"; "");
def bare: txt | sub("[.]+$"; "");
def path_text: txt | short_path($home);
def span: path_text | code_span;
def strings_of($list): $list | if type == "array" then map(strings) else [] end;
def group($heading; $lines): if ($lines | length) == 0 then empty else "\($heading)\n" + ($lines | join("\n")) end;
def section($title; $groups): if ($groups | length) == 0 then empty else "### \($title)\n\n" + ($groups | join("\n\n")) end;
def located($at; $rest): if ($at | txt) == "" then "- \($rest)" else "- \($at | path_text): \($rest)" end;
def located_span($at; $rest): if ($at | txt) == "" then "- \($rest)" else "- \($at | span): \($rest)" end;
def because($why): if ($why | txt) == "" then "" else " Why: \($why | bare)." end;
def result_words: txt as $result | ({pass: "pass", fail: "fail", not_run: "not run", narrowed: "narrowed"}[$result] // $result);

def behavior_line:
	[(if (.at | txt) != "" then .at | span else empty end),
	 (if .checked == true then "checked" else empty end),
	 (if .fix == true then "bug fix" else empty end),
	 (if (.guard | txt) != "" then "guard: \(.guard | txt)" else empty end)] as $qualifiers
	| "- \(.what | txt)" + (if ($qualifiers | length) > 0 then " (\($qualifiers | join(", ")))" else "" end);
def verification_line:
	"- \(.gate | txt): \(.result | result_words)"
	+ (if (.command | txt) != "" then ", \(.command | txt | code_span)" else "" end)
	+ (if (.note | txt) != "" then ", \(.note | txt)" else "" end);
def deviation_line:
	"- \(.what | bare)" + (if (.from | txt) != "" then " (\(.from | path_text))" else "" end) + "." + because(.why);
def review_line: "- \(.id | txt): \(.status | txt | gsub("_"; " "))" + (if (.note | txt) != "" then ", \(.note | txt)" else "" end);
def mismatch_lines:
	file_mismatches as $mismatches
	| [$mismatches[:$max_mismatches][] | "- \(.path | span)" + (if .note then ": \(.note)" else "" end)]
	  + (if ($mismatches | length) > $max_mismatches then ["- \($mismatches | length - $max_mismatches) more not shown (showing \($max_mismatches) of \($mismatches | length))"] else [] end);

def skipped_line:
	baseline_skipped as $skipped
	| ($skipped | length) as $count
	| if $count == 0 then []
	  else ["- \($count) file\(if $count == 1 then "" else "s" end) (the baseline lists them): "
		+ ([$skipped[:$max_baseline_shown][] | span] | join(", "))
		+ (if $count > $max_baseline_shown then ", and \($count - $max_baseline_shown) more" else "" end)] end;

def behavior_group: group("Behavior:"; [objects_of("behavior")[] | behavior_line]);
# "did what was asked" only holds for a valid report with no blocker.
def deviations_group($clean):
	group("Deviations from the task:"; [objects_of("deviations")[] | deviation_line]
		| if length > 0 then . elif $clean then ["- None: did what was asked."] else ["- None."] end);
def problems_group($problems): group("Report problems:"; [$problems[] | "- \(txt)"]);
def open_groups:
	group("Instruction found in the context, not followed:"; [open_of("instruction_found")[] | located(.at; .text | txt)]),
	group("Secret found, needs rotation:"; [open_of("secret_found")[] | located_span(.at; .text | txt)]);
def gap_groups:
	group("Not read or not done:"; [open_of("could_not")[] | located(.ref // .at; .text | txt)]),
	group("Assumptions:"; [open_of("assumption")[] | "- \(.text | txt)"]),
	group("Contract breaks:"; [open_of("contract_break")[] | located_span(.at; .text | txt)]),
	group("Gates the brief tried to suspend:"; [open_of("gate_refused")[] | located(.at; .text | txt)]);
def decisions_group: group("Decisions:"; [objects_of("decisions")[]
	| "- \(.choice | bare)." + because(.why) + (if (.commit | txt) != "" then " Commit: \(.commit | txt)" else "" end)]);
def focus_group: group("For the reviewer:"; [objects_of("focus")[] | located_span(.at; .question | txt)]);
def missing_group: group("Missing standards:"; [open_of("missing_plugin")[] | located(.at; .text | txt)]);

def blocked: objects_of("blockers") | length > 0;
def status_line($invalid):
	(if $invalid then "Invalid" elif blocked then "Blocked" else "Done" end)
	+ (if $round == "initial" then " · Initial implementation"
	   elif $round != "" then " · Fix round \($round | ltrimstr("fix "))"
	   else "" end);
def labels: if $labels == "" then null else $labels | capture("^LABELS: Technology: (?<technology>.*) · Used standards: (?<standards>.*)$") end;
def technology_line:
	(.tech | txt) as $tech
	| (labels.technology // "none" | txt) as $label
	| if $label == "none" or $label == "" then "Technology: \($tech)" else "Technology: \($label) (\($tech))" end;
def standards_group:
	(labels.standards // "none" | txt) as $standards
	| if $standards == "none" or $standards == "" then empty
	  else group("Standards:"; [$standards | split(", ")[] | txt | select(. != "") | "- \(.)"]) end;

def summary_section($invalid):
	section("Summary"; ["Status: \(status_line($invalid))", (.summary | txt), technology_line, standards_group]);
def changed_section:
	. as $report
	| section("What changed"; [(("created", "modified", "deleted") as $label
		| group("\($label[:1] | ascii_upcase)\($label[1:]):"; [strings_of($report.files | objects | .[$label])[] | "- \(span)"])),
		behavior_group]);
def verified_section: section("How it was verified"; [objects_of("verification")[] | verification_line] | if length == 0 then [] else [join("\n")] end);
def check_section($problems; $clean):
	section("Check these"; [problems_group($problems),
		group("Review findings:"; [objects_of("review_responses")[] | review_line]),
		group("Blocked:"; [objects_of("blockers")[] | located_span(.location; .detail | txt)]),
		open_groups,
		group("Changed but not reported:"; mismatch_lines),
		group("Changed before this dispatch, not checked:"; skipped_line),
		deviations_group($clean),
		gap_groups]);
def information_section: section("For information"; [decisions_group, group("Noticed along the way:"; [objects_of("noticed")[] | located_span(.at; "\(.what | bare).")]), focus_group, missing_group]);

# Check these comes right after Summary when it holds something to act on
# first: a blocker, or the problems of an invalid report.
def human_view($problems):
	($problems | length > 0) as $invalid
	| ($invalid or blocked) as $urgent
	| ($urgent | not) as $clean
	| ["## Implementation report", summary_section($invalid),
	   (if $urgent then check_section($problems; $clean) else empty end),
	   changed_section, verified_section,
	   (if $urgent then empty else check_section($problems; $clean) end),
	   information_section];
def slice_view($problems):
	(($problems | length) == 0 and (blocked | not)) as $clean
	| ["## Implementation report: for the \(if $for == "test" then "test dispatch" else "reviewer" end)",
	   problems_group($problems), behavior_group, deviations_group($clean), open_groups, gap_groups, missing_group, decisions_group, focus_group];

$report[0] | problems as $problems | if $for == "" then human_view($problems) else slice_view($problems) end | join("\n\n")
'

usage() {
	cat <<'EOF'
usage: report.sh check --report PATH --repo DIR --mode BUILD [--baseline FILE] [--findings FILE] [--context FILE]
       report.sh render --report PATH [--labels-file FILE] [--round initial|'fix N'] [--repo DIR [--baseline FILE]] [--skills-dir DIR]
       report.sh render --report PATH --for reviewer|test [--repo DIR [--baseline FILE]] [--skills-dir DIR]
       report.sh --help

Checks the developer's report, one JSON object in the file PATH (absolute),
and renders it. stdin is never read. The validator in this script owns the
shape; there is no schema file. This --help and the report standard's field
table document it (the main thread reads this, the developer the field
table), and the validator wins where they differ.

The shape (keys marked ? are optional, and left out when empty):
  {"summary": str,                      at most 25 words
   "tech": str,                         language or framework and its version
   "files": {"created": [path], "modified": [path], "deleted": [path]},
   "deviations": [{"from": str, "what": str, "why": str}],      may be []
   "behavior": [{"what": str, "at": loc, "checked": bool,
                 "guard"?: "security"|"persisted_data"|"concurrency"|"auth",
                 "fix"?: bool}],                                1 to 8 items
   "verification": [{"gate": "format"|"lint"|"typecheck"|"test"|"build"|"scan"|"manual",
                     "result": "pass"|"fail"|"not_run"|"narrowed",
                     "command"?: str, "note"?: str}],           at least 1
   "focus"?: [{"at": loc, "question": str}],                    at most 3
   "decisions"?: [{"choice": str, "why": str, "commit"?: str}], at most 8
   "noticed"?: [{"at": loc, "what": str}],                      at most 5
   "open"?: [{"kind": "assumption"|"could_not"|"missing_plugin"|"instruction_found"
                      |"secret_found"|"contract_break"|"gate_refused",
              "text": str, "at"?: loc, "ref"?: str}],
              at most 6, instruction_found and secret_found not counted
   "blockers"?: [{"kind": "test_compile_broken"|"gate_red"|"finding_blocked"
                          |"code_untestable"|"tests_red_before_refactor",
                  "location": loc, "detail": str}],
   "review_responses"?: [{"id": str, "status": "fixed"|"not_fixed"|"blocked",
                          "note"?: str}]}                       fix round only
Rules the validator enforces (check, and render before it prints):
  - no key but those above; untested, repaired and mutation are reserved for
    the TEST mode; mode, round and LABELS are never written into the file
  - a str holds a non-space character and at most 200 characters (summary:
    its 25-word cap instead); a path or loc is never absolute (/, ~ or a
    drive letter); a files path has no .. segment and is listed once
  - loc: a repo-relative path:line, brief: <FIELD>, a plugin name and file, a
    context entry (paths[<n>], links[<n>] or its URL) or commit <sha>; only
    "never absolute" is enforced
  - verification: a pass has its command; any other result has its note
  - verification: a command is one command, no &&, || or ; outside quotes
  - open: a could_not item has its ref
  - with --findings (a fix round): review_responses holds each finding ID of
    FILE (one per line, blank lines ignored) exactly once and no other ID; a
    not_fixed item has its note; a blocked item's ID is named in the detail
    of a blockers item of kind finding_blocked, as a whole word. Without
    --findings, check refuses review_responses; render, which has no
    findings file, refuses it only with --round initial.
  - with --context (the context file, {"paths", "links", "notes"}): each
    could_not ref is a paths[].path or links[].url in it, or paths[<n>],
    links[<n>] or notes[<n>] for an entry it has, counted from 1 (render has
    no context file and skips this)
  - files against git status in DIR, the root of a git work tree: a changed
    file not listed, a file in the wrong list, or a listed file git shows
    unchanged is not a problem: it is counted as unlisted and shown in the
    render, since parallel dispatches share the tree. --baseline FILE
    (absolute) holds `git status --porcelain=v1 -z --no-renames` of DIR saved
    before the dispatch; every path in it, and every path under a folder it
    lists, is left out of this comparison. render shows how many changed
    files that leaves unchecked, under "Changed before this dispatch, not
    checked:", naming at most 5; check's count line does not count them

check stdout, one line, on exits 0, 1 and 3:
  blockers=<n> instruction_found=<n> secret_found=<n> missing_plugin=<n> could_not=<n> deviations=<n> unlisted=<n>
check stderr: one line per problem, "<field>: <what>; expected <x>", at most
30, then a count of the rest.
--mode TEST is refused until the testing flow exists.

render prints the report as Markdown on stdout: the human view, or with --for
only behavior, deviations, open, decisions and focus (--labels-file and --round
are then ignored). It runs the shape check first and still prints an invalid
report, as far as its shape allows: "Status: Invalid", its problems under
"Report problems:" at the top of Check these, which then follows Summary.
"None: did what was asked." shows only for a valid report with no blocker and
no deviation, otherwise "None.". A decision's commit text shows as
"Commit: <text>". The labels FILE (absolute, at most 1000 bytes) holds the
hand-back's LABELS line exactly as given, one line,
"LABELS: Technology: <label|none> · Used standards: <labels|none>", so label
text never sits on a command line; --round is initial or 'fix N' with N a
positive integer. With --repo, files that git and the report disagree on show
under "Changed but not reported" (at most 20, then a count). Paths are shown through DIR/lib-render/paths.jq: cut in the
middle past 80 characters, the home folder as ~.
  DIR (--skills-dir) defaults to ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills.

Exit codes:
  0  check: valid · render: printed, an invalid report included
  1  check: valid, with open blockers
  2  usage error, --mode TEST, a missing or unreadable --findings, --context,
     --labels-file or --baseline file, --baseline without --repo, or a --repo
     that is not the root of a git work tree
  3  check: invalid (stderr names each problem)
  4  not a report: PATH missing, unreadable, not JSON, or not one object
  5  install fault, its stderr line starting "report.sh: install:": jq
     missing or older than 1.6, git missing, git status failing in DIR, or
     DIR/lib-render/paths.jq missing (render only)

Dependencies: POSIX sh, jq 1.6+ (macOS: brew install jq; Linux: the distro's
jq), git (check, and render with --repo), mktemp, tr; the lib-render skill
for render.
Runtime: about 80 ms for check and 70 ms for render on a small repo,
measured on macOS; git status grows with the repo's size.
EOF
}

warn() {
	printf '%s: %s\n' "${PROG}" "$1" >&2
}

usage_error() {
	warn "$1"
	printf "Try '%s --help'.\n" "${PROG}" >&2
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
		check | render) command=$1 ;;
		*) usage_error "unknown command: $1; expected check, render or --help" ;;
	esac
	shift
	report='' repo='' baseline='' mode='' findings='' context='' labels_file='' labels='' round='' for_reader=''
	skills_dir="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/skills"
	while [ "$#" -gt 0 ]; do
		case $1 in
			--help | -h)
				usage
				exit 0
				;;
			--report | --repo | --baseline | --mode | --findings | --context | --labels-file | --round | --for | --skills-dir)
				[ "$#" -ge 2 ] && [ -n "$2" ] || usage_error "$1 needs a value; expected $1 VALUE"
				set_option "$1" "$2"
				shift 2
				;;
			*) usage_error "unknown argument: $1; expected the options --help lists for ${command}" ;;
		esac
	done
	check_jq
	check_common_args
	if [ "${command}" = check ]; then check_check_args; else check_render_args; fi
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
		--round) round=$2 ;;
		--for) for_reader=$2 ;;
		*) skills_dir=$2 ;;
	esac
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
	for render_only in "${labels_file}" "${round}" "${for_reader}"; do
		[ -z "${render_only}" ] || usage_error 'check takes no --labels-file, --round or --for; expected them only with render'
	done
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
		usage_error "--context file not readable: ${context}; expected the dispatch's context file"
	jq -e 'type == "object"' "${context}" </dev/null >/dev/null 2>&1 ||
		usage_error "--context file is not one JSON object: ${context}; expected the context file {\"paths\", \"links\", \"notes\"}"
}

check_render_args() {
	for check_only in "${mode}" "${findings}" "${context}"; do
		[ -z "${check_only}" ] || usage_error 'render takes no --mode, --findings or --context; expected them only with check'
	done
	case ${for_reader} in
		'' | reviewer | test) ;;
		*) usage_error "--for ${for_reader} is unknown; expected --for reviewer or --for test" ;;
	esac
	[ -n "${for_reader}" ] || check_view_args
}

# --labels-file and --round matter only to the human view; --for ignores them.
check_view_args() {
	[ -z "${labels_file}" ] || read_labels_file
	case ${round} in
		'' | initial) ;;
		'fix '*[!0-9]* | 'fix 0'* | 'fix ') usage_error "--round ${round} is not 'fix N' with N a positive integer; expected initial or 'fix 2'" ;;
		'fix '*) ;;
		*) usage_error "--round ${round} is unknown; expected initial or 'fix N'" ;;
	esac
}

# Sets labels to the one LABELS line in labels_file; exits 2 when the file is
# missing, too big, or holds anything else.
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
	newline='
'
	case ${labels} in
		*"${newline}"*) usage_error "--labels-file holds more than one line: ${labels_file}; ${labels_expected}, one line" ;;
		'LABELS: Technology: '*' · Used standards: '*) ;;
		*) usage_error "--labels-file holds no LABELS line: ${labels_file}; expected 'LABELS: Technology: <label|none> · Used standards: <labels|none>', copied whole from the hand-back" ;;
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

# Exits 4 unless the report file holds exactly one JSON object.
check_report() {
	[ -f "${report}" ] && [ -r "${report}" ] ||
		not_a_report "${report} is missing, unreadable or not a regular file; expected the file the brief's REPORT line names"
	shape=$(jq -rs 'if length == 1 and (.[0] | type) == "object" then "object" elif length == 1 then "a JSON \(.[0] | type)" else "\(length) values" end' "${report}" </dev/null 2>/dev/null) ||
		not_a_report "${report} is not valid JSON; expected one JSON object; try checking its quotes, commas and brackets"
	[ "${shape}" = object ] ||
		not_a_report "${report} holds ${shape}; expected exactly one JSON object"
}

# Writes git status for the repo and the --baseline file, NULs as \001, to
# git_file and baseline_file; with no repo, empty files and have_git false.
read_git_status() {
	work_dir=$(mktemp -d "${TMPDIR:-/tmp}/report-sh.XXXXXX") || install_fault 'mktemp -d failed; expected a writable TMPDIR'
	trap 'rm -rf "${work_dir}"' EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM
	git_file="${work_dir}/status"
	baseline_file="${work_dir}/baseline"
	have_git=false
	: >"${git_file}"
	: >"${baseline_file}"
	[ -n "${repo}" ] || return 0
	if [ -n "${baseline}" ]; then
		tr '\000' '\001' <"${baseline}" >"${baseline_file}" ||
			usage_error "--baseline file not readable: ${baseline}; expected the saved git status"
	fi
	command -v git >/dev/null 2>&1 || install_fault 'git missing; expected git on PATH; try installing git'
	[ -d "${repo}" ] || usage_error "--repo ${repo} is not a folder; expected the repository root"
	top=$(git -C "${repo}" rev-parse --show-toplevel 2>/dev/null) ||
		usage_error "--repo ${repo} is not in a git work tree; expected the repository root"
	physical=$(cd "${repo}" && pwd -P) || usage_error "--repo ${repo} cannot be entered; expected a readable folder"
	[ "${top}" = "${physical}" ] || usage_error "--repo ${repo} is not the root of its work tree; expected ${top}"
	# GIT_OPTIONAL_LOCKS=0: status reads only, never refreshing the index
	# under a dispatch that is still writing to the tree.
	GIT_OPTIONAL_LOCKS=0 git -C "${repo}" status --porcelain -z --untracked-files=all --no-renames >"${work_dir}/raw" ||
		install_fault "git status failed in ${repo}; expected it to list the changes; fix what git printed above"
	tr '\000' '\001' <"${work_dir}/raw" >"${git_file}"
	have_git=true
}

run_check() {
	if [ -n "${findings}" ]; then
		set -- --rawfile findings_text "${findings}" --arg findings_mode given
	else
		set -- --arg findings_text '' --arg findings_mode none
	fi
	if [ -n "${context}" ]; then
		set -- "$@" --slurpfile context_file "${context}"
		# shellcheck disable=SC2016 # a jq variable, not a shell one
		context_expr='$context_file[0]'
	else
		set -- "$@" --argjson context_file '[]'
		context_expr='null'
	fi
	output=$(jq -nr --slurpfile report "${report}" --rawfile git "${git_file}" --rawfile baseline "${baseline_file}" \
		--argjson have_git "${have_git}" --arg mode "${mode}" "$@" \
		"${context_expr} as \$context | ${COMMON_JQ}${SHAPE_JQ}${CHECK_JQ}" </dev/null) ||
		install_fault 'jq failed on a valid JSON report; expected jq 1.6+; try jq --version'
	count_line=$(printf '%s\n' "${output}" | sed -n '1p')
	problems=$(printf '%s\n' "${output}" | sed '1d')
	printf '%s\n' "${count_line}"
	if [ -n "${problems}" ]; then
		printf '%s\n' "${problems}" >&2
		exit 3
	fi
	blockers=${count_line#blockers=}
	[ "${blockers%% *}" -eq 0 ] || exit 1
}

run_render() {
	paths_module="${skills_dir}/${RENDER_LIB}/paths.jq"
	[ -f "${paths_module}" ] && [ -r "${paths_module}" ] ||
		install_fault "path helpers missing; expected ${paths_module}; install the ${RENDER_LIB} skill in ${skills_dir}"
	# Only a first round can refuse review_responses: render gets no findings file.
	findings_mode=unchecked
	[ "${round}" != initial ] || [ -n "${for_reader}" ] || findings_mode=none
	jq -nr -L "${skills_dir}/${RENDER_LIB}" --slurpfile report "${report}" --rawfile git "${git_file}" \
		--rawfile baseline "${baseline_file}" --argjson have_git "${have_git}" --argjson max_mismatches "${MAX_MISMATCHES}" \
		--argjson max_baseline_shown "${MAX_BASELINE_SHOWN}" \
		--arg mode BUILD --arg findings_mode "${findings_mode}" --arg findings_text '' \
		--arg labels "${labels}" --arg round "${round}" --arg for "${for_reader}" --arg home "${HOME:-}" \
		"include \"paths\"; null as \$context | ${COMMON_JQ}${SHAPE_JQ}${RENDER_JQ}" </dev/null ||
		install_fault 'jq failed on a valid JSON report; expected jq 1.6+; try jq --version'
}

parse_args "$@"
check_report
read_git_status
if [ "${command}" = check ]; then run_check; else run_render; fi
