#!/usr/bin/env sh
# Checks the developer's report JSON, stamps what its dispatch file knows into
# it on a pass, and renders it for the human, the reviewer and a TEST
# dispatch. The jq validator below owns the report's
# shape (there is no schema file): the report standard's field table and
# --help document it, the validator wins where they differ, and doc-check
# compares the table with it. Path display
# goes through lib-render's paths.jq.
set -eu

readonly PROG='report.sh'
readonly RENDER_LIB='lib-render'
# The render lists at most this many files where the report and git disagree:
# an un-ignored build folder can add thousands, which would bury the report.
readonly MAX_MISMATCHES=20
# A LABELS line names one technology and a handful of standards and
# procedures, well under this; a bigger file is not the hand-back's line.
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
# The keys check --dispatch writes into the report on a pass; the agent never does.
def stamp_keys: ["tech", "plugins", "mode", "dispatch", "started", "finished"];
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
# whole set when each key has the shape of a stamp, and refuses a part set.
def stamp_rule: "the agent never writes \(stamp_keys | names); report.sh check --dispatch stamps all six on a pass, and a stamped report is never checked again";
def stamp_shape_problems:
	(if .tech | text_ok then empty else "tech: \(.tech | shown) is not a stamp; expected the tech plugin name, or none" end),
	(if (.plugins | type) == "array" and all(.plugins[]; text_ok) then empty else "plugins: \(.plugins | shown) is not a stamp; expected an array of plugin names" end),
	(if .mode | text_ok then empty else "mode: \(.mode | shown) is not a stamp; expected the dispatch mode" end),
	(if .dispatch | stamp_id_ok then empty else "dispatch: \(.dispatch | shown) is not a stamp; expected the dispatch Crucible ID" end),
	(("started", "finished") as $key | select(.[$key] | stamp_time_ok | not)
		| "\($key): \(.[$key] | shown) is not a stamp; expected YYYY-MM-DDTHH:MM:SS+HH:MM");
def stamp_problems:
	. as $report
	| [stamp_keys[] | select(. as $key | $report | has($key))] as $present
	| if ($present | length) == 0 then empty
	  elif $stamp_check == "render" and ($present | length) == (stamp_keys | length) then stamp_shape_problems
	  else $present[] | "\(.): written into the report; expected it left out: \(stamp_rule)" end;

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
		(if has("review_responses") then "review_responses: given outside a fix round; expected it left out (only a check run with --findings takes it)" else empty end)
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

# doc-check: compares the report standard's text ($doc) with the definitions
# above, so the field table is checked against the validator, not against a
# second list. A field-table row is a line starting "| `<key>`"; its Key cell
# runs to the next |. Each output line is one difference.
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

# The full human view (render --full) and the --for slice; the summary below
# reuses its definitions. Tolerant of a broken shape, since the main
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
	group("Gates the first message tried to suspend:"; [open_of("gate_refused")[] | located(.at; .text | txt)]);
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
def labels: if $labels == "" then null else $labels | capture("^LABELS: Technology: (?<technology>.*) · Standards: (?<standards>.*?)(?: · Procedures: (?<procedures>.*))?$") end;
def technology_line:
	(.toolchain | txt) as $toolchain
	| (labels.technology // "none" | txt) as $label
	| if $label == "none" or $label == "" then "Technology: \($toolchain)" else "Technology: \($label) (\($toolchain))" end;
def stamped: has("dispatch");
def plugin_names: strings_of(.plugins) | if length == 0 then "none" else join(", ") end;
def stamp_group:
	if stamped | not then empty
	else group("Dispatch:"; ["- Tech plugin: \(.tech | txt)", "- Plugins: \(plugin_names | txt)", "- Mode: \(.mode | txt)",
		"- Dispatch: \(.dispatch | txt)", "- Started: \(.started | txt)", "- Finished: \(.finished | txt)"]) end;
def label_group($heading; $list):
	($list // "none" | txt) as $names
	| if $names == "none" or $names == "" then empty
	  else group($heading; [$names | split(", ")[] | txt | select(. != "") | "- \(.)"]) end;
def plugin_label_groups: label_group("Standards:"; labels.standards), label_group("Procedures:"; labels.procedures);

def summary_section($invalid):
	section("Summary"; ["Status: \(status_line($invalid))", (.summary | txt), technology_line, stamp_group, plugin_label_groups]);
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
'

# shellcheck disable=SC2016
readonly FULL_MAIN_JQ='
$report[0] | problems as $problems | if $for == "" then human_view($problems) else slice_view($problems) end | join("\n\n")
'

# The default render: the summary the main thread shows the human. Counts, the
# items to act on (a group past max_per_group ends in a count of the rest, which
# render --full shows; problems, blockers, secrets, instructions found and
# deviations are never cut) and the report file's path as a link.
# shellcheck disable=SC2016
readonly SUMMARY_JQ='
def max_per_group: 3;
def counted($count; $one; $many): "\($count) \(if $count == 1 then $one else $many end)";
def capped_group($lines; $one; $many):
	($lines | length) as $count
	| $lines[:max_per_group]
	  + (if $count > max_per_group then ["- \(counted($count - max_per_group; "more \($one)"; "more \($many)")) in the full report"] else [] end);
def at_line($label; $at; $text): "- \($label): " + (if ($at | txt) == "" then "" else "\($at | span): " end) + ($text | txt);
def text_lines($kind; $label): [open_of($kind)[] | "- \($label): \(.text | txt)"];
def could_not_line:
	[(.ref, .at) | select(txt != "") | span] as $spans
	| ($spans | if length == 2 and .[0] == .[1] then .[:1] else . end) as $where
	| "- Not read: " + (if ($where | length) == 0 then "" else "\($where | join(", ")): " end) + (.text | txt);

# The Technology label, else the stamped tech plugin, else the toolchain.
def summary_tech:
	(labels.technology // "none" | txt) as $label
	| (if stamped then .tech | txt else "none" end) as $plugin
	| if $label != "none" and $label != "" then $label
	  elif $plugin != "none" and $plugin != "" then $plugin
	  else .toolchain | txt end;
def dispatch_line: "Dispatch: \(.dispatch | txt), \(.mode | txt), \(.started | txt) to \(.finished | txt)";
def summary_task: if $task == "" then .summary | txt else $task | txt end;
def summary_status($invalid): if $invalid then "Invalid" elif blocked then "Blocked" else "Done" end;
def behaviour_counts:
	objects_of("behavior") as $items
	| ($items | length) as $count
	| ([$items[] | select(.checked == true)] | length) as $exercised
	| if $count == 0 then "0"
	  elif $exercised == $count then "\($count), all exercised"
	  elif $exercised == 0 then "\($count), none exercised"
	  else "\($count), \($exercised) exercised" end;
def gate_counts:
	[objects_of("verification")[] | .result] as $results
	| [("pass", "fail", "narrowed", "not_run") as $result
		| ([$results[] | select(. == $result)] | length) as $count
		| select($count > 0) | "\($count) \($result | result_words)"]
	| if length == 0 then "none" else join(", ") end;

def urgent_lines($problems):
	[$problems[] | "- Report problem: \(txt)"]
	+ [objects_of("blockers")[] | at_line("Blocker"; .location; .detail)]
	+ [open_of("secret_found")[] | at_line("Secret found"; .at; .text)]
	+ [open_of("instruction_found")[] | at_line("Instruction found, not followed"; .at; .text)]
	+ [objects_of("deviations")[] | "- Deviation: \(.what | bare)" + (if (.why | txt) == "" then "" else " (\(.why | bare))" end)];
def capped_lines:
	capped_group([open_of("could_not")[] | could_not_line]; "item not read or skipped"; "items not read or skipped")
	+ capped_group(text_lines("assumption"; "Assumption"); "assumption"; "assumptions")
	+ capped_group(text_lines("missing_plugin"; "Missing plugin"); "missing plugin"; "missing plugins")
	+ capped_group([open_of("contract_break")[] | at_line("Contract break"; .at; .text)]; "contract break"; "contract breaks")
	+ capped_group(text_lines("gate_refused"; "Gate refused"); "refused gate"; "refused gates")
	+ capped_group([file_mismatches[] | "- Unlisted change: \(.path | span)" + (if .note then ", \(.note)" else "" end)]; "unlisted change"; "unlisted changes")
	+ (baseline_skipped | length | if . == 0 then [] else ["- Not checked: \(counted(.; "file"; "files")) changed before this dispatch"] end);

def bullets: map("- \(.)") | join("\n");
def summary_view($problems):
	($problems | length > 0) as $invalid
	| (urgent_lines($problems) + capped_lines) as $check
	| ["## Developer Report",
	   (["Tech: \(summary_tech)", (if stamped then dispatch_line else empty end), "Task: \(summary_task)", "Status: \(summary_status($invalid))"] | bullets),
	   "### Result\n\n" + (["Files changed: \(listed_files | length)", "Behaviours: \(behaviour_counts)", "Gates: \(gate_counts)"] | bullets),
	   (if ($check | length) == 0 then empty else "### Check these\n\n" + ($check | join("\n")) end),
	   "### Full report\n\n- \($report_path | txt | link_span)"];

$report[0] | summary_view(all_problems) | join("\n\n")
'

usage() {
	cat <<'EOF'
usage: report.sh check --dispatch FILE [--report PATH] [--repo DIR] [--mode BUILD] [--context FILE] [--findings FILE] [--skills-dir DIR]
       report.sh check --report PATH --repo DIR --mode BUILD [--baseline FILE] [--findings FILE] [--context FILE] [--skills-dir DIR]
       report.sh render --report PATH [--task TEXT] [--labels-file FILE] [--round initial|'fix N'] [--repo DIR [--baseline FILE | --dispatch FILE]] [--skills-dir DIR]
       report.sh render --full --report PATH [--labels-file FILE] [--round initial|'fix N'] [--repo DIR [--baseline FILE | --dispatch FILE]] [--skills-dir DIR]
       report.sh render --report PATH --for reviewer|test [--repo DIR [--baseline FILE | --dispatch FILE]] [--skills-dir DIR]
       report.sh doc-check --skill PATH [--skills-dir DIR]
       report.sh --help

Checks the developer's report, one JSON object in the file PATH (absolute;
normally in the Crucible space, ${CRUCIBLE_HOME:-$HOME/.crucible}, which is
not enforced), stamps what the dispatch file knows into it on a pass, and
renders it. stdin is never read. With no arguments it prints this help on
stderr and exits 2.
The validator in this script owns the shape; there is no schema file. This
--help and the report standard's field table document it (the main thread
reads this, the developer the field table), and the validator wins where
they differ; doc-check compares the field table with it.

Which keys the agent writes, which are required, the six stamp keys and the
reserved keys are in the report standard's field table, checked against the
validator by doc-check; the validator wins. Each key's item fields, enum
values and caps are there too; a loc is a location, in one of the forms the
standard lists. check --dispatch adds the stamps on a pass, after the
agent's keys: each is taken from the dispatch file, except finished, the
time the check passed (times are YYYY-MM-DDTHH:MM:SS+HH:MM, local time).
Rules the validator enforces (check, and render before it prints):
  - no key but the field table's; the reserved keys are for the TEST mode;
    round and LABELS are never written into the file
  - every required key is present, toolchain among them: a report written
    before toolchain existed is refused (check exit 3; render shows it
    Invalid)
  - stamps: check, with or without --dispatch, refuses a report holding any
    stamp key, each key named: a report is checked before it is stamped and
    a stamped one is never checked again, so a stamp key at a check is one
    the agent wrote. Only render takes a stamped report: all six keys, each
    with the shape of a stamp (the two times as above, dispatch a Crucible
    ID); it refuses a part set
  - a text value holds a non-space character and fits the text caps the
    field table states; a path or loc is never absolute (/, ~ or a drive
    letter); a files path has no .. segment and is listed once
  - loc: a repo-relative path:line, message: <FIELD>, a plugin name and file, a
    context entry (paths[<n>], links[<n>] or notes[<n>], counted from 1, or
    its URL) or commit <sha>; only "never absolute" is enforced
  - verification: a pass has its command; any other result has its note.
    Only that the note is there is checked: a narrowed note's quote of the
    first message is not verified
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
    render, since parallel dispatches share the tree. The baseline is git's
    view of DIR before the dispatch: every path in it, and every path under
    a folder it lists, is left out of this comparison. render shows how many
    changed files that leaves unchecked, under "Changed before this
    dispatch, not checked:", naming at most 5; check's count line does not
    count them. Where it comes from:
      check --dispatch: the dispatch's baseline key, the file
        prepare-agent-prompt.sh wrote at the Agent call (or at --direct);
        --baseline is refused
      render --repo DIR without --baseline or --dispatch: the baseline key
        of the dispatch the report's dispatch stamp names (found with
        crucible.sh path <ID>); a report with no dispatch stamp has no
        baseline
      render --repo DIR --dispatch FILE: the baseline key of FILE, for a
        report check --dispatch could not stamp (exit 3 at the resend cap,
        or exit 6). FILE is checked as check --dispatch checks it (absolute,
        a regular file, not a symlink, passing the dispatch validator); its
        repo_root must be DIR, its report PATH, and, for a stamped report,
        its id the report's dispatch stamp. --dispatch takes no --baseline
      --baseline FILE (absolute; check without --dispatch, or render): FILE
        holds `git status --porcelain=v1 -z --no-renames` of DIR saved
        before the dispatch, and wins over the stamp
    A dispatch's baseline file is one JSON object, {"repo_root", "taken",
    "entries"}, its entries that git status output's entries
    (flow-agent-initialization's dispatch-names.jq holds the shape); its
    repo_root must be the dispatch's

check --dispatch FILE: FILE (absolute, a regular file, not a symlink) is the
dispatch file generate-agent-dispatch.sh wrote, for the agent or for direct
implementation alike; it must pass DIR/flow-agent-initialization/scripts/
agent-dispatch/agent-dispatch-validator.jq (DIR: --skills-dir), its
problems listed one per line. It also supplies --report (its report),
--repo (its repo_root), --context (its context.path) and --mode (its mode):
leave them out, or give the same text; a different value is refused. The
context file is read once and its sha256 must still be the dispatch's
context.sha256: a context changed since the dispatch was written is refused.
A fault of that context file or of the repo_root folder is reported as the
dispatch's (exit 2, "report.sh: dispatch:"), since no flag fixes it.
The baseline comes from the dispatch's baseline key, never from --baseline
(given with --dispatch, a usage error), and must be a regular file, not a
symlink, holding a baseline of the dispatch's repo_root: a file still empty
(the dispatch never went through the Agent hook or --direct) is refused.
The report must then be a regular file, not a symlink. On a valid report (exit 0
or 1) the six stamps are written: the report as checked, read once into a
temp file, plus the stamps, written to a temp file beside PATH (its
permissions copied) and moved onto PATH. Any other exit writes nothing, and
the file stays byte for byte as it was.

check stdout, one line, on exits 0, 1, 3 and 6:
  blockers=<n> instruction_found=<n> secret_found=<n> missing_plugin=<n> could_not=<n> deviations=<n> unlisted=<n>
check stderr: one line per problem, "<field>: <what>; expected <x>", at most
30, then a count of the rest.
--mode TEST is refused until the testing flow exists.

render prints the report as Markdown on stdout. It runs the shape check
first and still prints an invalid report, as far as its shape allows. A
report holding a blocker of any kind, request_unclear among them, shows as
blocked.

render (the default) prints the summary the main thread shows the human,
every item on its own line:
  ## Developer Report
  - Tech: the labels FILE's Technology label (else the stamped tech when it
    is not none, else the report's toolchain), Dispatch: <dispatch>, <mode>,
    <started> to <finished> (a stamped report only), Task: TEXT (the
    report's summary without --task), Status: Done, Blocked or
    Invalid
  ### Result
  - Files changed: <n>, Behaviours: <n>, all|none|<k> exercised (checked
    true), Gates: <n> pass, <n> fail, <n> narrowed, <n> not run (zero counts
    left out; none when there is no gate)
  ### Check these   (left out when it has nothing)
  - in full, never cut: every validation problem of an invalid report
    ("Report problem: <line>", all of them, not the 30 check prints),
    blockers, secrets found, instructions found and deviations
  - at most 3 lines each, then "<n> more <items> in the full report": not
    read (could_not, "Not read: <ref>, <at>: <text>", at only when present),
    assumptions, missing plugins, contract breaks, gates refused, unlisted
    changes (with --repo; the count covers every one, while render --full
    lists at most 20 of them, then a count of the rest)
  - "Not checked: <n> files changed before this dispatch" (with a baseline)
  ### Full report
  - the absolute PATH, whole, in a code span (lib-render's link_span)
No standards, procedures, decisions, focus, noticed items or review
responses show there; render --full shows them. --task TEXT is one line (a
control character prints as a space).

render --full prints the full human view. Its Summary shows "Status: Done",
"Blocked" or "Invalid" (with " · Initial implementation" or " · Fix round N"
after it when --round is given), then "Technology: <label> (<toolchain>)",
or "Technology: <toolchain>" alone without a labels file or when its
Technology is none, and, for a stamped report, a "Dispatch:"
group with all six stamps (Tech plugin, Plugins, Mode, Dispatch, Started,
Finished). The full view of an
invalid report shows "Status: Invalid", its problems under
"Report problems:" at the top of Check these, which then follows Summary.
"None: did what was asked." shows only for a valid report with no blocker and
no deviation, otherwise "None.". A decision's commit text shows as
"Commit: <text>". The labels FILE (absolute, at most 1000 bytes) holds the
hand-back's LABELS line exactly as given, one line,
"LABELS: Technology: <label|none> · Standards: <labels|none>", with
" · Procedures: <labels>" after it when a procedure plugin was loaded, so
label text never sits on a command line; render --full shows the standards
and the procedures as their own groups under Summary. --round is initial or
'fix N' with N a positive integer without leading zeros; it shows only in
render --full's Status line, and initial makes the summary and render --full
show a review_responses key as a report problem. With --repo, files that git
and the report disagree on show
under "Changed but not reported" (at most 20, then a count). Paths and
verification commands shown as text go through DIR/lib-render/paths.jq:
cut in the middle past 80 characters (a cut command cannot be copied and
run; the report file holds it whole), the home folder in a path as ~.

render --for reviewer|test prints a slice for that reader: the heading
"## Implementation report: for the reviewer" (or "for the test dispatch"),
the problems of an invalid report under "Report problems:", then behavior,
deviations, open, decisions and focus. It takes neither --full nor --task
and ignores --labels-file and --round (neither is checked). --repo,
--baseline and --dispatch are checked, and git status and the baseline read,
as for the other renders, with the same exits 2 and 5, but they change
nothing it prints: the slice shows no "Changed but not reported" or
"Changed before this dispatch" group.
  DIR (--skills-dir) defaults to ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills.

doc-check --skill PATH [--skills-dir DIR]: PATH (absolute) is the report
standard's SKILL.md.
Read-only: it compares the text with the validator's own definitions, never
with a second list, and prints one line per difference on stdout. Matching
rule: a field-table row is a line starting "| `<key>`" and its Key cell runs
to the next |; a value is named when it appears as a backticked token.
  - each report key has one row, and no row names a key the validator lacks
  - a required key's Key cell says "(required", an optional one's does not
  - the largest number in a Key cell is that key's cap (none when uncapped);
    open's Key cell names, in backticks, exactly the kinds its cap skips
  - each value of every enum the validator holds is named in its key's row
    (blockers.kind's values in the blockers row); a row names no backticked
    identifier (lowercase, digits, _) that is not one of its enum values, its
    item fields, a report or stamp key, true or false
  - each row of a key with items names every item field the validator holds
    for it, as `<field>` or `<field>: <value>`; a field is called required
    when "(required" follows its token or "required " comes right before
    it; an optional field is never called required, and a required one
    always is
  - the summary row says "<cap> words"; the text says "at most <cap>
    characters" for the text cap
  - the first line holding "stamped keys" (any case) names exactly the six
    stamp keys
A table reworded so these no longer hold shows as differences, never as a
pass. check and render first run the same comparison on their own skill's
SKILL.md, the one beside this script's scripts/ folder: a difference, or
that file missing, exits 5 with "report.sh: install: the field table in
<path> and the validator disagree: <first difference>; run doc-check
--skill <path> for all". doc-check itself still exits 0 or 1 (2 on a
usage error, 5 on an install fault).

Writes: check --dispatch writes the six stamps into the report file, on a
pass only, and nothing else; check without --dispatch and render write
nothing but their own temp folder, removed on exit; doc-check writes nothing.
Only a SIGKILL leaves the temp folder, or the .report-stamps.* temp file
beside PATH, behind. git status runs with GIT_OPTIONAL_LOCKS=0, so the repo
and its index are never changed.

Exit codes:
  0  check: valid (stamped, with --dispatch) · render: printed, an invalid
     report included · doc-check: the text agrees with the validator
  1  check: valid, with open blockers (stamped, with --dispatch) ·
     doc-check: a difference, one line each on stdout
  2  usage error (no arguments among them: this help on stderr), --mode
     TEST, a missing or unreadable --findings, --context, --labels-file,
     --baseline or --skill file, a --findings file holding no ID, a
     --context file that is not one JSON object, a --labels-file over 1000
     bytes, of more than one line or holding no LABELS line, a --round that
     is neither initial nor 'fix N', --baseline without --repo, --baseline
     with --dispatch, render --dispatch without --repo, a --repo that is not
     a folder ("--repo <dir> is not a folder"), cannot be entered ("--repo
     <dir> cannot be entered"), is not in a git work tree or is not the root
     of one, a --report, --repo, --context
     or --mode that differs from the dispatch's, a render --repo that
     differs from the stamped dispatch's repo_root, or a render --dispatch
     whose repo_root is not --repo, whose report is not --report or whose id
     is not the report's dispatch stamp. A fault of the dispatch file itself starts stderr with
     "report.sh: dispatch:", so a caller can tell it from a usage error: the
     file missing, a symlink, not JSON or failing the dispatch validator
     (each problem named); under check --dispatch its CONTEXT file missing,
     unreadable, not a regular file or not one JSON object, or changed since
     the dispatch was written (its sha256 is not the dispatch's
     context.sha256), and its repo_root not a folder, not enterable, not in
     a git work tree or not the root of one; its baseline
     file missing, a symlink, unreadable, still empty, not JSON or not a
     baseline of its repo_root (each problem named), or, for render, the
     report's dispatch stamp naming no dispatch crucible.sh path finds
  3  check: invalid (stderr names each problem); nothing written
  4  not a report: PATH missing, unreadable, not JSON, or not one object;
     with --dispatch also a symlink
  5  install fault, its stderr line starting "report.sh: install:": jq
     missing or older than 1.6, a base tool missing, git missing, git status
     failing in DIR, DIR/flow-agent-initialization/scripts/agent-dispatch/
     dispatch-names.jq missing (every command), DIR/lib-render/paths.jq
     missing (render only), the dispatch validator or both sha256sum and
     shasum missing (check --dispatch only), the dispatch validator or
     crucible.sh missing when a dispatch's baseline is read, the dispatch
     validator failing to run (dispatch-names.jq missing beside it),
     crucible.sh path exiting other than 0 or 1, mktemp -d failing in
     ${TMPDIR:-/tmp}, the sha256 tool printing no 64-digit digest, jq
     failing at run time, or this skill's
     SKILL.md missing or its field table disagreeing with the validator
     (check and render)
  6  check --dispatch: valid, but the stamps could not be written; the
     report is unchanged and stderr names the step that failed
  129, 130, 143  stopped by HUP, INT or TERM; temp files are removed

Dependencies: POSIX sh, jq 1.6+ (macOS: brew install jq; Linux: the distro's
jq), git (check, and render with --repo; macOS: xcode-select --install;
Linux: the distro's git), the base tools cat, cp, date (+%z),
grep, mktemp, mv, rm, sed, tr and wc (in every macOS and Linux base system;
Linux: the distro's coreutils, grep and sed packages); the lib-render skill
for render; this skill's own SKILL.md, beside scripts/, for check and
render; the flow-agent-initialization skill's dispatch validator for check
--dispatch and render --dispatch, and sha256sum or shasum (macOS: shasum -a
256) for check --dispatch; its dispatch-names.jq (the baseline shape and the
stamp patterns crucible_id_pattern and local_time_pattern) for every
command, and the crucible skill's crucible.sh for render --repo of a stamped
report without --baseline or --dispatch; doc-check needs no git. jq, the
base tools and dispatch-names.jq are checked after the arguments parse
(dispatch-names.jq once they pass), git when --repo is given; a missing one
exits 5 and names it.
Runtime: about 90 ms for check, 120 ms for check --dispatch, 60 ms for
render and 90 ms for render --repo (each including the 20 to 30 ms check of
its own SKILL.md) and 30 ms for doc-check on a small repo, measured on
macOS (average of 5 runs); git status grows with the repo's size.
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
		check | render | doc-check) command=$1 ;;
		*) usage_error "unknown command: $1; expected check, render, doc-check or --help" ;;
	esac
	shift
	report='' repo='' baseline='' dispatch_baseline='' mode='' findings='' context='' labels_file='' labels='' round='' for_reader='' task='' full='' dispatch_file='' skill_file=''
	skills_dir="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/skills"
	while [ "$#" -gt 0 ]; do
		case $1 in
			--help | -h)
				usage
				exit 0
				;;
			--full)
				full=yes
				shift
				;;
			--report | --repo | --baseline | --mode | --findings | --context | --labels-file | --round | --for | --task | --skills-dir | --dispatch | --skill)
				[ "$#" -ge 2 ] && [ -n "$2" ] || usage_error "$1 needs a value; expected $1 VALUE"
				set_option "$1" "$2"
				shift 2
				;;
			*) usage_error "unknown argument: $1; expected the options --help lists for ${command}" ;;
		esac
	done
	check_jq
	check_base_tools
	if [ "${command}" = doc-check ]; then
		check_doc_check_args
		return 0
	fi
	[ -z "${skill_file}" ] || usage_error '--skill is for doc-check only; expected it only with doc-check'
	[ "${command}" != check ] || [ -z "${dispatch_file}" ] || read_dispatch
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
		--task) task=$2 ;;
		--dispatch) dispatch_file=$2 ;;
		--skill) skill_file=$2 ;;
		*) skills_dir=$2 ;;
	esac
}

# Checks the --dispatch file against the dispatch validator, takes --report,
# --repo, --context and --mode from it, sets stamps to the five stamps it
# supplies (finished comes at the pass), dispatch_context_sha256 to the
# context file's pinned sha256 and dispatch_baseline to its baseline file.
# Exits 2 on a bad file (stderr starting "report.sh: dispatch:"), a
# conflicting flag or --baseline, 5 when the validator is missing.
read_dispatch() {
	[ -z "${baseline}" ] ||
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
	same_as_dispatch --report "${report}" "${dispatch_report}" report
	same_as_dispatch --repo "${repo}" "${dispatch_repo}" repo_root
	same_as_dispatch --context "${context}" "${dispatch_context}" context.path
	same_as_dispatch --mode "${mode}" "${dispatch_mode}" mode
	report=${dispatch_report} repo=${dispatch_repo} context=${dispatch_context} mode=${dispatch_mode}
	stamps=$(jq -c '{tech, plugins: [.plugins[].name], mode, dispatch: .id, started}' "${dispatch_file}" </dev/null) ||
		dispatch_fault "${dispatch_file} cannot be read; ${dispatch_expected}"
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

# doc-check takes --skill, an absolute path to a regular, readable file, and
# --skills-dir alone.
check_doc_check_args() {
	for other in "${report}" "${repo}" "${baseline}" "${mode}" "${findings}" "${context}" "${labels_file}" "${round}" "${for_reader}" "${task}" "${full}" "${dispatch_file}"; do
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
	for render_only in "${labels_file}" "${round}" "${for_reader}" "${task}" "${full}"; do
		[ -z "${render_only}" ] || usage_error 'check takes no --labels-file, --round, --for, --task or --full; expected them only with render'
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
	case ${for_reader} in
		'' | reviewer | test) ;;
		*) usage_error "--for ${for_reader} is unknown; expected --for reviewer or --for test" ;;
	esac
	[ -z "${for_reader}" ] || [ -z "${full}${task}" ] ||
		usage_error '--for takes no --full or --task; expected --for reviewer|test without them'
	[ -z "${full}" ] || [ -z "${task}" ] ||
		usage_error '--full takes no --task; expected --task only with the summary render'
	[ -n "${for_reader}" ] || check_view_args
}

# render --dispatch names the baseline through that dispatch, so it needs
# --repo and takes no --baseline.
check_render_dispatch_args() {
	[ -z "${baseline}" ] ||
		usage_error '--dispatch and --baseline both name a baseline; expected one of them: --dispatch for a report check --dispatch could not stamp'
	[ -n "${repo}" ] || usage_error '--dispatch needs --repo; expected --repo DIR --dispatch FILE'
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
		'LABELS: Technology: '*' · Standards: '*) ;;
		*) usage_error "--labels-file holds no LABELS line: ${labels_file}; expected 'LABELS: Technology: <label|none> · Standards: <labels|none>[ · Procedures: <labels>]', copied whole from the hand-back" ;;
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
	for tool in cat cp date grep mktemp mv rm sed tr wc; do
		command -v "${tool}" >/dev/null 2>&1 && continue
		case ${tool} in
			grep | sed) package=${tool} ;;
			*) package=coreutils ;;
		esac
		install_fault "${tool} missing; expected ${tool} on PATH, part of every macOS and Linux base system; try restoring PATH (macOS: /usr/bin) or installing the distro ${package} package"
	done
}

# Makes the temp folder every run uses, removed on exit with any stamp temp file.
make_work_dir() {
	stamp_tmp=''
	work_dir=$(mktemp -d "${TMPDIR:-/tmp}/report-sh.XXXXXX") || install_fault 'mktemp -d failed; expected a writable TMPDIR'
	trap 'rm -rf "${work_dir}"; [ -z "${stamp_tmp}" ] || rm -f "${stamp_tmp}"' EXIT
	trap 'exit 129' HUP
	trap 'exit 130' INT
	trap 'exit 143' TERM
}

# Copies the report file once to report_copy, which the check, the render and
# the stamps all read, so what is stamped is what was checked. Exits 4 unless
# it holds exactly one JSON object (or, before stamping, it is a symlink).
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
# baseline is the --baseline file, else the dispatch's baseline file: the
# --dispatch file's (check, and render), or the one of the dispatch the report
# is stamped with (render); a render of an unstamped report without
# --dispatch has none.
read_git_status() {
	git_file="${work_dir}/status"
	baseline_file="${work_dir}/baseline"
	have_git=false
	: >"${git_file}"
	: >"${baseline_file}"
	[ -n "${repo}" ] || return 0
	if [ -n "${baseline}" ]; then
		tr '\000' '\001' <"${baseline}" >"${baseline_file}" ||
			usage_error "--baseline file not readable: ${baseline}; expected the saved git status"
	else
		[ "${command}" != render ] || find_render_baseline
		[ -z "${dispatch_baseline}" ] || load_dispatch_baseline
	fi
	command -v git >/dev/null 2>&1 || install_fault 'git missing; expected git on PATH; try installing git'
	[ -d "${repo}" ] || dispatch_value_fault repo_root --repo "${repo} is not a folder; expected the repository root"
	top=$(git -C "${repo}" rev-parse --show-toplevel 2>/dev/null) ||
		dispatch_value_fault repo_root --repo "${repo} is not in a git work tree; expected the repository root"
	physical=$(cd "${repo}" && pwd -P) || dispatch_value_fault repo_root --repo "${repo} cannot be entered; expected a readable folder"
	[ "${top}" = "${physical}" ] || dispatch_value_fault repo_root --repo "${repo} is not the root of its work tree; expected ${top}"
	# GIT_OPTIONAL_LOCKS=0: status reads only, never refreshing the index
	# under a dispatch that is still writing to the tree.
	GIT_OPTIONAL_LOCKS=0 git -C "${repo}" status --porcelain -z --untracked-files=all --no-renames >"${work_dir}/raw" ||
		install_fault "git status failed in ${repo}; expected it to list the changes; fix what git printed above"
	tr '\000' '\001' <"${work_dir}/raw" >"${git_file}"
	have_git=true
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
	baseline_expected='expected the git status prepare-agent-prompt.sh writes into it at the Agent call or at --direct'
	[ ! -L "${dispatch_baseline}" ] || dispatch_fault "baseline ${dispatch_baseline} is a symlink; ${baseline_expected}"
	[ -f "${dispatch_baseline}" ] && [ -r "${dispatch_baseline}" ] ||
		dispatch_fault "baseline ${dispatch_baseline} is missing, unreadable or not a regular file; ${baseline_expected}"
	[ -s "${dispatch_baseline}" ] ||
		dispatch_fault "baseline ${dispatch_baseline} is empty: the dispatch was never sent through the Agent hook or --direct; ${baseline_expected}; send the dispatch through one of them before the work starts"
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
	differences=$(jq -nr -L "${names_module%/*}" --rawfile doc "$1" --arg git '' --arg baseline '' --argjson have_git false \
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
	output=$(jq -nr -L "${names_module%/*}" --slurpfile report "${report_copy}" --rawfile git "${git_file}" --rawfile baseline "${baseline_file}" \
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

# Writes report_copy plus the six stamps onto the report file through a temp
# file beside it. Exits 6 when a step fails, the report unchanged.
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
	stamp_tmp=$(mktemp "${report_dir:-/}/.report-stamps.XXXXXX") ||
		stamp_fault "mktemp failed in ${report_dir:-/}; expected the report's folder writable"
	cp -p "${report}" "${stamp_tmp}" || stamp_fault "cp -p ${report} failed; expected the report's permissions copied to ${stamp_tmp}"
	jq --argjson stamps "${stamps}" --arg finished "${finished}" '. + $stamps + {finished: $finished}' "${report_copy}" </dev/null >"${stamp_tmp}" ||
		stamp_fault "jq failed writing ${stamp_tmp}; expected the stamped report written; try jq --version"
	mv -f "${stamp_tmp}" "${report}" || stamp_fault "mv onto ${report} failed; expected the stamped report moved into place"
	stamp_tmp=''
}

stamp_fault() {
	warn "stamps not written, the report unchanged: $1"
	exit 6
}

run_render() {
	paths_module="${skills_dir}/${RENDER_LIB}/paths.jq"
	[ -f "${paths_module}" ] && [ -r "${paths_module}" ] ||
		install_fault "path helpers missing; expected ${paths_module}; install the ${RENDER_LIB} skill in ${skills_dir}"
	# Only a first round can refuse review_responses: render gets no findings file.
	findings_mode=unchecked
	[ "${round}" != initial ] || [ -n "${for_reader}" ] || findings_mode=none
	if [ -n "${full}${for_reader}" ]; then main_program=${FULL_MAIN_JQ}; else main_program=${SUMMARY_JQ}; fi
	jq -nr -L "${skills_dir}/${RENDER_LIB}" -L "${names_module%/*}" --slurpfile report "${report_copy}" --rawfile git "${git_file}" \
		--rawfile baseline "${baseline_file}" --argjson have_git "${have_git}" --argjson max_mismatches "${MAX_MISMATCHES}" \
		--argjson max_baseline_shown "${MAX_BASELINE_SHOWN}" \
		--arg mode BUILD --arg findings_mode "${findings_mode}" --arg findings_text '' --arg stamp_check render \
		--arg labels "${labels}" --arg round "${round}" --arg for "${for_reader}" --arg home "${HOME:-}" \
		--arg task "${task}" --arg report_path "${report}" \
		"include \"paths\"; ${STAMP_JQ}null as \$context | ${COMMON_JQ}${SHAPE_JQ}${RENDER_JQ}${main_program}" </dev/null ||
		install_fault 'jq failed on a valid JSON report; expected jq 1.6+; try jq --version'
}

parse_args "$@"
locate_names_module
if [ "${command}" = doc-check ]; then run_doc_check; fi
check_own_skill
make_work_dir
[ "${command}" != check ] || [ -z "${dispatch_file}" ] || pin_context
check_report
read_git_status
if [ "${command}" = check ]; then run_check; else run_render; fi
