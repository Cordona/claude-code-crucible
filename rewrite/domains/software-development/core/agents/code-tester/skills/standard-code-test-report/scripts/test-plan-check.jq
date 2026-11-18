# The tester's test plan: its keys, each list's item keys, and the checks on
# a parsed plan and the path:line locations it points at. A module: load it
# with jq -L <this folder> and include "test-plan-check".
# plan_locations lists the relative paths of the plan's well-formed
# behaviours[].at locations, for the shell to look up in the worktree;
# plan_check prints a list of "<field> <problem>; <how to fix>" lines, empty
# when the plan fits. Each line is all the tester sees, so it names the
# field, the fault and the repair. A key or item key holding null, [] or {}
# counts as left out, as the stop hook's prune drops it.

def plan_keys: ["behaviours", "add", "modify", "remove", "fixtures", "support", "untested", "no_tests", "baseline", "run", "blocker"];
# Keys the plan event derives, or the plan never holds, and why they are not written.
def plan_derived_keys: {
	"seq": "the plan event gives it",
	"seat": "the seat gives it",
	"seats": "the seat gives it",
	"dispatch": "the dispatch gives it",
	"effort": "the seat gives it",
	"summary": "behaviours say what it guards",
	"new_files": "an add entry carries ci",
	"unchanged": "a plan lists only what it changes"
};
# Each list's id prefix (null: no ids), item keys, those always required,
# and the shape a line shows.
def plan_lists: {
	"behaviours": {prefix: "B", keys: ["id", "text", "at", "guarded_by"], required: ["id", "text", "at"],
		shape: "{id, text, at, guarded_by}"},
	"add": {prefix: "T", keys: ["id", "kind", "file", "name", "rows", "level", "why", "guards", "breaks_on", "fixtures", "ci"],
		required: ["id", "kind", "file", "name", "level", "guards", "breaks_on"],
		shape: "{id, kind, file, name, rows, level, why, guards, breaks_on, fixtures, ci}"},
	"modify": {prefix: "M", keys: ["id", "file", "name", "changes", "keeps", "guards", "move", "breaks_on", "fixtures"],
		required: ["id", "file", "name", "changes", "keeps", "guards"],
		shape: "{id, file, name, changes, keeps, guards, move, breaks_on, fixtures}"},
	"remove": {prefix: "R", keys: ["id", "file", "name", "covered_by"], required: ["id", "file", "name", "covered_by"],
		shape: "{id, file, name, covered_by}"},
	"fixtures": {prefix: "F", keys: ["id", "action", "file", "source", "from", "why", "changes"], required: ["id", "action", "file"],
		shape: "{id, action, file, source, from, why, changes}"},
	"support": {prefix: null, keys: ["action", "file", "why"], required: ["action", "file", "why"], shape: "{action, file, why}"},
	"untested": {prefix: "N", keys: ["id", "case", "reason", "risk", "category", "proof", "recommend"],
		required: ["id", "case", "reason", "risk", "category", "proof", "recommend"],
		shape: "{id, case, reason, risk, category, proof, recommend}"},
	"run": {prefix: null, keys: ["where", "command"], required: ["where", "command"],
		shape: "{where, command}"}
};
def plan_blocker_keys: ["kind", "detail"];
# Item keys the plan never holds, and what to do instead.
def plan_dropped_item_keys: {
	"add.new_file": "the card tells a new file from the commit",
	"modify.why": "changes and keeps say it",
	"untested.recommend_why": "reason and risk say it",
	"run.tests": "the command names the tests"
};
def plan_add_kinds: ["new_test", "new_rows"];
def plan_levels: ["e2e", "integration", "unit"];
def plan_fixture_actions: ["add", "modify", "remove"];
def plan_sources: ["captured", "hand-written", "existing"];
def plan_support_actions: ["add", "remove"];
def plan_recommends: ["test", "waive"];
def plan_baseline_results: ["pass", "fail"];
def plan_blocker_kinds: ["request_unclear", "gate_red"];
# The lists whose emptiness means no test changes, so no_tests is given.
def plan_change_lists: ["add", "modify", "remove"];
# Bounds a value echoed in a problem line, so the line stays readable.
def plan_echo_max: 60;

def plan_list: join(", ");
def plan_trim: sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; "");
def plan_is_empty: . == null or . == [] or . == {};
def plan_echo: tojson | if length > plan_echo_max then .[:plan_echo_max - 3] + "..." else . end;
# A plain name as it is, anything else quoted and escaped onto one line.
def plan_name: if test("^[A-Za-z0-9_.:-]{1,60}$") then . else plan_echo end;
def plan_shown: if length > plan_echo_max then .[:plan_echo_max - 3] + "..." else . end;
# Whether . (an object) holds key $key with something in it.
def plan_has($key): has($key) and (.[$key] | plan_is_empty | not);
def plan_items($key): .[$key] | if type == "array" then .[] | objects else empty end;

# The problem of a one-line text, or nothing; plan texts have no length cap.
def plan_text_problem:
	if type != "string" then "is a JSON \(type); write it as a one-line string"
	elif test("[\n\r\u2028\u2029]") then "holds a line break; write it as one line"
	elif test("[[:cntrl:]]") then "holds a control character; remove it"
	elif (plan_trim | length) == 0 then "is blank; write one line of text"
	else empty
	end;

def plan_enum_problem($values; $what):
	if IN($values[]) then empty
	else "\(plan_echo) is not a known \($what); use one of \($values | plan_list)"
	end;

def plan_id_pattern($prefix): "\\A\($prefix)-[1-9][0-9]{0,8}\\z";

# A worktree-relative path's problem, before or without the worktree.
def plan_relative_problem:
	if startswith("/") then "is an absolute path; write it relative to the worktree root"
	elif split("/") | any(.[]; . == "..") then "leaves the worktree with ..; write the path from the worktree root without .."
	elif endswith("/") then "names a folder; name the file"
	else empty
	end;

def plan_is_location: test(":[0-9]+$");
def plan_split_location: capture("^(?<path>.*):(?<line>[0-9]+)$") | .line |= tonumber;

def plan_path_problem:
	if .path == "" then "has no path before the colon; write path:line relative to the worktree, e.g. src/App.kt:12"
	elif .line < 1 then "has line \(.line); lines count from 1"
	else .path | plan_relative_problem
	end;

# $files: {path: {status, lines}} as the shell found each path in the worktree.
def plan_file_problem($files):
	$files[.path] as $file
	| if $file == null then "could not be looked up in the worktree; point at a file inside it"
	elif $file.status == "missing" then "names no file in the worktree; give the path, from the worktree root, of a file that exists"
	elif $file.status == "folder" then "names a folder; point at a file in it"
	elif $file.status == "link" then "is a symbolic link; point at the file it links to"
	elif $file.status == "outside" then "resolves outside the worktree; point at a file inside it"
	elif $file.status == "special" then "is not a regular file; point at a source file"
	elif $file.status == "unreadable" then "names a file this check cannot read; point at a readable file"
	elif .line > $file.lines then "is past the end of the file (\($file.lines) lines); point at a line that exists"
	else empty
	end;

def plan_at_problem($files):
	if plan_is_location then plan_split_location | (plan_path_problem // plan_file_problem($files))
	else "is not path:line; write the production file's path from the worktree root and the line the behaviour lives at, e.g. src/main/App.kt:42"
	end;

# The well-formed relative paths of every behaviours[].at, once each.
def plan_locations:
	if type != "object" then empty
	else
		[plan_items("behaviours") | .at | strings | select([plan_text_problem] == [] and plan_is_location)
			| plan_split_location | select([plan_path_problem] == []) | .path]
		| unique[]
	end;

# An existing test named as "<file>: <test name>".
def plan_is_test_name: test("\\A[^:[:space:]][^:]*: [^[:space:]]");
def plan_test_name_problem:
	if plan_is_test_name then (capture("\\A(?<file>[^:]*):").file | plan_relative_problem)
	else "is not <file>: <test name>; name the existing test by its file from the worktree root and its name, e.g. src/test/AppTest.kt: should_accept_order"
	end;

# $ids: {prefix: [every id the plan gives that prefix]}.
def plan_ref_problem($prefix; $ids; $what):
	if test(plan_id_pattern($prefix)) | not then "is not a \($what) id; use a \($prefix)-<n> id from the plan's \($what) list"
	elif IN($ids[$prefix][]) | not then "names no \($what) entry of this plan; use an id from its \($what) list"
	else empty
	end;

def plan_covered_by_problem($ids):
	if test("\\Anothing:") then
		(if test("\\Anothing: [^[:space:]]") then empty else "gives no reason; write nothing: <why nothing covers it>" end)
	elif test("\\A[TM]-") then plan_ref_problem(.[:1]; $ids; (if startswith("T") then "add" else "modify" end))
	elif plan_is_test_name then plan_test_name_problem
	else "is not a plan id, an existing test or nothing: <why>; write e.g. T-1, src/test/AppTest.kt: should_accept_order, or nothing: the feature is gone"
	end;

# What to add for item key $key of list $list; $item gives the context.
def plan_hint($list; $key; $item):
	{
		"id": "add the id: \(plan_lists[$list].prefix)-<n>, unique in the plan",
		"behaviours.text": "add what will be guarded after this plan, in one line",
		"behaviours.at": "add the production path:line the behaviour lives at, e.g. src/main/App.kt:42",
		"add.kind": "add the kind: one of \(plan_add_kinds | plan_list)",
		"file": "add the test file's path from the worktree root, e.g. src/test/AppTest.kt",
		"name": "add the test's name as the file has it (or will)",
		"add.rows": "add the new rows, one line each, e.g. [\"stock 0, ordered 1\"]",
		"add.level": "add the level: one of \(plan_levels | plan_list)",
		"add.why": "add why no higher level observes the behaviour, in one line (\($item.level) needs it)",
		"guards": "add the behaviours it guards: a list of B-<n> ids",
		"add.breaks_on": "add the change to production code that must turn the test red, e.g. \"remove the stock check at src/main/App.kt:42\"",
		"modify.changes": "add what changes in the test, in one line",
		"modify.keeps": "add what the test still asserts, in one line",
		"remove.covered_by": "add what still covers its behaviour: a plan id (T-1), an existing test (<file>: <name>) or nothing: <why>",
		"fixtures.action": "add the action: one of \(plan_fixture_actions | plan_list)",
		"fixtures.source": "add the source: one of \(plan_sources | plan_list)",
		"fixtures.from": "add which run it was captured from, e.g. \"a local run of T-1 against the containerised database\"",
		"fixtures.why": "add why it is hand-written, in one line",
		"fixtures.changes": "add the entries the fixture adds, changes or removes, in one line",
		"support.action": "add the action: one of \(plan_support_actions | plan_list)",
		"support.why": "add why the helper is added or removed, in one line",
		"untested.case": "add the case left untested, in one line",
		"untested.reason": "add why it stays untested, in one line",
		"untested.risk": "add what could go wrong unseen, in one line",
		"untested.category": "add its category, e.g. concurrency",
		"untested.proof": "add the proof: a test, a path:line, another repo's test, or unproven",
		"untested.recommend": "add the recommendation: one of \(plan_recommends | plan_list)",
		"run.where": "add where the tests run, e.g. \"build seat worktree, database in docker compose\"",
		"run.command": "add the command, naming the tests, never a pattern"
	} as $hints
	| $hints["\($list).\($key)"] // $hints[$key] // "add it";

# The keys an item must hold: some follow its kind, level, action or source.
def plan_required_keys($list; $rule):
	$rule.required + (
		if $list == "add" then
			(if .kind == "new_rows" then ["rows"] else [] end)
			+ (if .level == "integration" or .level == "unit" then ["why"] else [] end)
		elif $list == "fixtures" then
			(if .action == "add" or .action == "modify" then ["source"] else [] end)
			+ (if .source == "captured" then ["from"] elif .source == "hand-written" then ["why"] else [] end)
			+ (if .action == "modify" then ["changes"] else [] end)
		else []
		end);

# The problems of a list value, each item's from each as "[<index>] <problem>".
def plan_list_value_problems(each):
	if type != "array" then "is a JSON \(type); write it as a list"
	else to_entries[] | .key as $index | .value | each | "[\($index)] \(.)"
	end;

# The problems of item key $key's value, which is not empty.
def plan_value_problems($list; $key; $files; $ids):
	if $key == "guards" then plan_list_value_problems(plan_text_problem // plan_ref_problem("B"; $ids; "behaviours"))
	elif $key == "fixtures" then plan_list_value_problems(plan_text_problem // plan_ref_problem("F"; $ids; "fixtures"))
	elif $key == "rows" then plan_list_value_problems(plan_text_problem)
	elif $key == "guarded_by" then plan_list_value_problems(plan_text_problem // plan_test_name_problem)
	elif $key == "move" then
		if type != "object" then "is a JSON \(type); write it as {row, from, to}"
		else
			(keys_unsorted[] | select(IN("row", "from", "to") | not) | "\(plan_name) is not a key of move; remove it. Allowed: row, from, to"),
			(("row", "from", "to") as $part | if has($part) | not then "has no \($part); write {row, from, to}: the row and the tests it moves between"
				else .[$part] | plan_text_problem | "\($part) \(.)" end)
		end
	else
		(plan_text_problem // (
			if $key == "id" then (if test(plan_id_pattern(plan_lists[$list].prefix)) then empty
				else "\(plan_echo) is not a \(plan_lists[$list].prefix)-<n> id; number \($list) entries \(plan_lists[$list].prefix)-1, \(plan_lists[$list].prefix)-2 ..." end)
			elif $key == "at" then plan_shown as $shown | plan_at_problem($files) | "\($shown) \(.)"
			elif $key == "file" then plan_shown as $shown | plan_relative_problem | "\($shown) \(.)"
			elif $key == "kind" then plan_enum_problem(plan_add_kinds; "add kind")
			elif $key == "level" then plan_enum_problem(plan_levels; "level")
			elif $key == "action" and $list == "support" then plan_enum_problem(plan_support_actions; "support action")
			elif $key == "action" then plan_enum_problem(plan_fixture_actions; "fixture action")
			elif $key == "source" then plan_enum_problem(plan_sources; "fixture source")
			elif $key == "recommend" then plan_enum_problem(plan_recommends; "recommendation")
			elif $key == "covered_by" then plan_shown as $shown | plan_covered_by_problem($ids) | "\($shown) \(.)"
			else empty
			end))
	end;

def plan_unknown_item_key($list; $where; $rule):
	plan_dropped_item_keys["\($list).\(.)"] as $why
	| "\($where).\(plan_name) is not a key of \($list) items; remove it\(if $why == null then "" else " (\($why))" end). Allowed: \($rule.keys | plan_list)";

# . is {key: index, value: item}.
def plan_item_problems($list; $rule; $files; $ids):
	.key as $index
	| .value as $item
	| "\($list)[\($index)]" as $where
	| if ($item | type) != "object" then
		"\($where) is \(if $item == null then "null" else "a JSON \($item | type)" end); write it as an object \($rule.shape)"
	else
		($item | plan_required_keys($list; $rule)) as $required
		| ($item | keys_unsorted[] | select(IN($rule.keys[]) | not) | plan_unknown_item_key($list; $where; $rule)),
		($required[] | select(. as $key | $item | plan_has($key) | not)
			| . as $key | "\($where).\($key) is missing; \(plan_hint($list; $key; $item))"),
		($item | to_entries[] | select((.key | IN($rule.keys[])) and (.value | plan_is_empty | not)) | .key as $key | .value
			| if $list == "add" and $key == "rows" and $item.kind == "new_test" then
				"\($where).rows is set but kind is new_test; leave rows out, or make it kind new_rows"
			else plan_value_problems($list; $key; $files; $ids)
				| if startswith("[") then "\($where).\($key)\(.)" else "\($where).\($key) \(.)" end
			end)
	end;

# The list $key as a whole: left out, the wrong type, else each item.
def plan_list_problems($key; $files; $ids):
	plan_lists[$key] as $rule
	| if plan_has($key) | not then empty
	elif (.[$key] | type) != "array" then "\($key) is a JSON \(.[$key] | type); write it as a list of \($rule.shape) objects"
	else .[$key] | to_entries[] | plan_item_problems($key; $rule; $files; $ids)
	end;

# {prefix: [ids]} of every list's items, a duplicate kept, for references and uniqueness.
def plan_ids:
	. as $plan
	| reduce (plan_lists | to_entries[] | select(.value.prefix != null)) as $list ({};
		.[$list.value.prefix] = [$plan | plan_items($list.key) | .id | strings]);

def plan_duplicate_problems($ids):
	$ids | to_entries[] | .value | group_by(.)[] | select(length > 1)
	| "id \(.[0] | plan_echo) is given \(length) times; give each entry its own id, unique in the plan";

def plan_object_problems($key; $keys; $shape):
	if plan_has($key) | not then empty
	elif (.[$key] | type) != "object" then "\($key) is a JSON \(.[$key] | type); write it as an object \($shape)"
	else
		.[$key] as $value
		| ($value | keys_unsorted[] | select(IN($keys[]) | not) | "\($key).\(plan_name) is not a key of \($key); remove it. Allowed: \($keys | plan_list)"),
		($keys[] as $part | if $value | plan_has($part) | not then "\($key).\($part) is missing; write \($key) as \($shape)"
			else $value[$part] | (plan_text_problem // (
				if $part == "kind" then plan_enum_problem(plan_blocker_kinds; "blocker kind")
				else empty
				end)) | "\($key).\($part) \(.)"
			end)
	end;

# no_tests iff add, modify and remove are all empty; a plan with no blocker
# has its behaviours, baseline and run, unless it needs no tests; a failed
# baseline is a gate_red blocker, or has none when modify or remove plans
# the repair of the tests it ran; a gate_red blocker has a failed baseline.
def plan_whole_problems:
	([plan_change_lists[] as $key | select(plan_has($key))] | length > 0) as $changes
	| (plan_has("modify") or plan_has("remove")) as $repairs
	| plan_has("blocker") as $blocked
	| plan_has("no_tests") as $no_tests
	| (if $no_tests and $changes then
		"no_tests is set but the plan lists test changes; leave no_tests out, or empty add, modify and remove"
	elif ($no_tests | not) and ($changes | not) and ($blocked | not) then
		"add, modify and remove are all empty; plan the test changes, or say why none is needed in no_tests"
	else empty
	end),
	(if $no_tests and $blocked then "no_tests and blocker are both set; a blocked plan names only its blocker" else empty end),
	(if $no_tests then .no_tests | plan_text_problem | "no_tests \(.)" else empty end),
	(select(($blocked or $no_tests) | not)
		| ("behaviours", "baseline", "run") as $key | select(plan_has($key) | not)
		| "\($key) is missing; \({
			"behaviours": "add what will be guarded after this plan: {id, text, at} each",
			"baseline": "add the result of your run of the existing tests: pass or fail",
			"run": "add one {where, command} per place the tests run"
		}[$key])"),
	(.baseline as $result
		| (.blocker | if type == "object" then .kind else null end) as $kind
		| if $result == "fail" and $kind != "gate_red" and ($blocked or ($repairs | not)) then
			"baseline is fail but blocker is not gate_red; write blocker {\"kind\": \"gate_red\", \"detail\": \"<what failed>\"}, or, when the change was meant to turn them red, plan their repair in modify or remove with no blocker, or fix the run and rerun it"
		elif $kind == "gate_red" and $result == "pass" then
			"blocker.kind is gate_red but baseline is pass; set the failed run's baseline to fail, or remove the blocker"
		else empty
		end);

# The free texts the human reads, by list, beside blocker.detail and no_tests.
def plan_shown_item_keys: {
	"behaviours": ["text"],
	"add": ["why", "breaks_on"],
	"modify": ["changes", "keeps"],
	"untested": ["case", "reason", "risk", "category"]
};
# An internal item id such as B-1 or M-2: a capital letter, a dash and digits.
def plan_internal_id: "\\b[A-Z]-[0-9]+\\b";

# Each text the human reads that names an id: those texts name items in words.
def plan_id_problems:
	. as $plan
	| ((.blocker | objects | .detail | strings | {field: "blocker.detail", text: .}),
		(.no_tests | strings | {field: "no_tests", text: .}),
		(plan_shown_item_keys | to_entries[] | .key as $list | .value[] as $key
			| $plan[$list] | arrays | to_entries[] | select(.value | type == "object") | .key as $index
			| .value[$key] | strings | {field: "\($list)[\($index)].\($key)", text: .}))
	| . as {$field, $text}
	| [$text | match(plan_internal_id; "g") | .string] | unique
	| select(. != [])
	| "\($field) names \(join(" and ")); the human reads this text, so name the item in words, by what it is or checks";

def plan_unknown_key:
	plan_derived_keys[.] as $why
	| "\(plan_name) is not a plan key; remove it\(if $why == null then "" else " (\($why))" end). Allowed keys: \(plan_keys | plan_list)";

# $hint: where and in what shape the plan is written, for a plan that is no object.
def plan_problems($files; $hint):
	if type != "object" then ["the plan is a JSON \(type); \($hint)"]
	else
		plan_ids as $ids
		| [
			(keys_unsorted[] | select(IN(plan_keys[]) | not) | plan_unknown_key),
			((plan_lists | keys_unsorted[]) as $key | plan_list_problems($key; $files; $ids)),
			(if plan_has("baseline") then .baseline
				| if type != "string" then "baseline is a JSON \(type); write it as pass or fail"
				else plan_enum_problem(plan_baseline_results; "baseline result") | "baseline \(.)"
				end
			else empty end),
			plan_object_problems("blocker"; plan_blocker_keys; "{kind, detail}"),
			plan_duplicate_problems($ids),
			plan_whole_problems,
			plan_id_problems
		]
	end;

# $files_text: one "status<TAB>lines<TAB>path" line per looked-up path.
def plan_files($files_text):
	$files_text | split("\n") | map(select(length > 0) | split("\t")
		| {key: (.[2:] | join("\t")), value: {status: .[0], lines: (.[1] | tonumber)}})
	| from_entries;

# The problem lines of the raw plan text, at most $max and a count of the rest.
def plan_check($text; $files_text; $hint; $max):
	[$text | try fromjson] as $parsed
	| (if $parsed == [] then
		[if ($text | test("^[[:space:]]*$")) then "the plan is empty; \($hint)"
		else "the plan is not one valid JSON value; \($hint)"
		end]
	else $parsed[0] | plan_problems(plan_files($files_text); $hint)
	end)
	| if length > $max then .[:$max] + ["\(length - $max) more problems not shown; fix the ones above and the check lists the rest"] else . end;
