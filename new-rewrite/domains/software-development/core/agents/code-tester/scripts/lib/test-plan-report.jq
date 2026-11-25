# A test plan's rules, a jq module: load it with jq -L <the skills folder>
# and include "code-tester/scripts/lib/test-plan-report"; a rework's rules
# build on them. Input as tester-common.jq's; facts {plan, changed}, from
# tester-facts.sh: plan the plan a rework reworks, changed the paths the
# job changed.
include "code-tester/scripts/lib/tester-common";

def tp_keys: ["behaviours", "tests", "support", "untested", "baseline", "run", "no_tests", "noticed", "blockers"];
def tp_actions: ["add", "modify", "remove"];
def tp_levels: ["e2e", "integration", "unit"];
def tp_recommends: ["test", "skip"];

# Each action's keys and its required keys.
def tp_fields:
	{"add": ["id", "action", "file", "name", "level", "why", "guards", "breaks_on"],
	 "modify": ["id", "action", "file", "names", "changes", "keeps", "guards", "breaks_on"],
	 "remove": ["id", "action", "file", "names", "covered_by"]};
def tp_required:
	{"add": ["id", "file", "name", "level", "guards", "breaks_on"],
	 "modify": ["id", "file", "names", "changes", "keeps", "breaks_on"],
	 "remove": ["id", "file", "names", "covered_by"]};
def tp_verb: {"add": "adds a test", "modify": "modifies a test", "remove": "removes a test"};
def tp_says:
	{"id": "its T- id", "file": "the test file", "name": "the test's name", "names": "the tests, one or more",
	 "level": "e2e, integration or unit", "why": "why it isn't end to end", "guards": "the behaviours it guards",
	 "breaks_on": "what makes it fail", "changes": "what changes", "keeps": "what it must still assert",
	 "covered_by": "what still covers them"};

def tp_id_pattern: "\\b[BTNC]-[0-9]+\\b";

# The problem of human-read text naming an internal ID, at $w.
def tp_no_ids($w):
	if type == "string" and test(tp_id_pattern)
	then "\($w) names \(capture("(?<id>" + tp_id_pattern + ")").id): say it in words; the IDs are for scripts"
	else empty end;

def tp_path($w):
	if type != "string" or test("^\\s*$") then "\($w) must be a path in the tree"
	elif test("^/") or test("(^|/)\\.\\.(/|$)") then "\($w) \(tojson) must be a path in the tree"
	else empty end;

# The ids of list $name: $prefix- and a number, unique in the plan.
def tp_ids($name; $prefix):
	[tc_entries($name) | select((.v | type) == "object" and (.v | has("id")))] as $es
	| $es[] | .v.id as $id
	| if ($id | type) != "string" or ($id | test("^" + $prefix + "-[1-9][0-9]*$") | not)
		or ([$es[] | select(.v.id == $id)] | length) > 1
	  then "\(.w).id \($id | tojson) must be \($prefix)- and a number, unique in the plan"
	  else empty end;

def tp_behaviours:
	if .report | has("behaviours") | not then "list the behaviours the change has, even with no_tests"
	else
		tc_list("behaviours"; ["id", "text", "at", "guarded_by"]; ["id", "text", "at"]; ["text"]),
		tp_ids("behaviours"; "B"),
		(tc_entries("behaviours") | select((.v | type) == "object") | .w as $w | .v
		 | (.text | tp_no_ids("\($w).text")),
		   (if has("guarded_by") | not then empty
			elif (.guarded_by | type) != "array" then "\($w).guarded_by must be a list of <file>: <test>"
			else .guarded_by | to_entries[] | .key as $i | .value | tc_text("\($w).guarded_by[\($i)]") end))
	end;

def tp_behaviour_ids: [tc_entries("behaviours") | .v | objects | .id | strings];
def tp_test_ids: [tc_entries("tests") | .v | objects | .id | strings];

def tp_test_rules:
	tp_behaviour_ids as $bs | tp_test_ids as $ts
	| (.report.tests | if . == null or type == "array" then empty else "tests must be a list" end),
	  tp_ids("tests"; "T"),
	  (tc_entries("tests") | .w as $w | .v
	   | if type != "object" then "\($w) must be an object"
	     elif has("action") | not then "\($w) needs action: add, modify or remove"
	     elif .action | IN(tp_actions[]) | not then "\($w).action \(.action | tojson) is not add, modify or remove"
	     else .action as $a | . as $t
		| ((($t | keys_unsorted) - tp_fields[$a])[] | "\($w) has unknown key \"\(.)\"; an \($a) test's keys are \(tp_fields[$a] | join(", "))"),
		  ((tp_required[$a] - ($t | keys))[] | "\($w) \(tp_verb[$a]): add \(.), \(tp_says[.])"),
		  (if $a == "add" and ($t.level | IN("unit", "integration")) and ($t | has("why") | not)
		   then "\($w) \(tp_verb[$a]): add why, \(tp_says.why)" else empty end),
		  (if $t | has("file") then $t.file | tp_path("\($w).file") else empty end),
		  (if $t | has("level") and ($t.level | IN(tp_levels[]) | not)
		   then "\($w).level \($t.level | tojson) is not e2e, integration or unit" else empty end),
		  (["name", "why", "breaks_on", "changes", "keeps"][] as $k | $t | select(has($k)) | .[$k]
		   | (tc_text("\($w).\($k)") // tp_no_ids("\($w).\($k)"))),
		  (if $t | has("names") | not then empty
		   elif ($t.names | type) != "array" then "\($w).names must be a list of the tests' names"
		   else $t.names | to_entries[] | .key as $i | .value | (tc_text("\($w).names[\($i)]") // tp_no_ids("\($w).names[\($i)]")) end),
		  (if $t | has("guards") | not then empty
		   elif ($t.guards | type) != "array" then "\($w).guards must be a list of B- ids"
		   else $t.guards[] | select(IN($bs[]) | not) | "\($w).guards names \(.), which isn't a behaviour in this plan" end),
		  (if $t | has("covered_by") | not then empty
		   else $t.covered_by
			| if type != "string" then "\($w).covered_by must be a T- test of this plan, <file>: <test>, or nothing: <why>"
			  elif test("^T-[1-9][0-9]*$") then (if IN($ts[]) then empty else "\($w).covered_by names \(.), which isn't a test in this plan" end)
			  elif test("^nothing: \\S") or test("^[^:\\s][^:]*: \\S") then empty
			  else "\($w).covered_by must be a T- test of this plan, <file>: <test>, or nothing: <why>" end
		   end)
	     end);

def tp_has_tests: (.report.tests | type) == "array" and (.report.tests | length) > 0;

def tp_no_tests_rule:
	if tp_has_tests and (.report | has("no_tests")) then "the plan has both tests and no_tests: keep one"
	elif (tp_has_tests | not) and (.report | has("no_tests") | not) then "the plan has no tests: add tests, or no_tests saying why"
	elif .report | has("no_tests") then .report.no_tests | (tc_text("no_tests") // tp_no_ids("no_tests"))
	else empty end;

def tp_support:
	tc_list("support"; ["file", "what"]; ["file", "what"]; ["what"]),
	(tc_entries("support") | select((.v | type) == "object") | .w as $w | .v
	 | (if has("file") then .file | tp_path("\($w).file") else empty end),
	   (.what | tp_no_ids("\($w).what")));

def tp_untested:
	tc_list("untested"; ["id", "case", "reason", "risk", "proof", "recommend"];
		["id", "case", "reason", "risk", "proof", "recommend"]; ["case", "reason", "risk"]),
	tp_ids("untested"; "N"),
	(tc_entries("untested") | select((.v | type) == "object") | .w as $w | .v
	 | (["case", "reason", "risk"][] as $k | .[$k] | tp_no_ids("\($w).\($k)")),
	   (if has("proof") and (.proof | type == "string" and (. == "unproven" or test("^[^:\\s]+:[1-9][0-9]*$")
		or test("^[^:\\s][^:]*: \\S")) | not)
	    then "\($w).proof must be a test, a path:line, or unproven" else empty end),
	   (if has("recommend") and (.recommend | IN(tp_recommends[]) | not)
	    then "\($w).recommend \(.recommend | tojson) is not test or skip" else empty end));

# The baseline, shaped like a gate. An unknown failure needs a gate_red
# blocker, or a modify whose names include the failing test.
def tp_baseline:
	.report.baseline as $g
	| [tc_entries("blockers") | .v | objects | .kind] as $kinds
	| [tc_entries("tests") | .v | objects | select(.action == "modify") | .names | arrays[] | strings] as $repaired
	| if $g == null then "add baseline: the tests' state before any change, shaped like a gate"
	  elif ($g | type) != "object" then "baseline must be one gate: {gate, where?, result, note?, failing?}"
	  else
		((($g | keys_unsorted) - ["gate", "where", "result", "note", "failing"])[] | "baseline has unknown key \"\(.)\"; its keys are gate, where, result, note, failing"),
		((["gate", "result"] - ($g | keys))[] | "baseline needs \(.)"),
		(if $g | has("gate") and ($g.gate | IN(tc_gates[]) | not) then "baseline.gate \($g.gate | tojson) is not one of \(tc_gates | join(", "))" else empty end),
		(if $g | has("result") and ($g.result | IN(tc_results[]) | not) then "baseline.result \($g.result | tojson) is not one of \(tc_results | join(", "))" else empty end),
		(if ($g.result == "not_run" or $g.result == "narrowed") and ($g | has("note") | not) then "baseline is \($g.result): add a note saying why" else empty end),
		(if $g | has("note") then $g.note | tc_text("baseline.note") else empty end),
		(if $g.result != "fail" then (if $g | has("failing") then "baseline is \($g.result // "without a result"): failing belongs only to a fail" else empty end)
		 elif ($g.failing | type) != "array" or ($g.failing | length) == 0 then "baseline fails: list what fails in failing"
		 else ($g.failing - (.job.known_failures // []))[]
			| select(. as $f | ($kinds | index(["gate_red"]) | not) and ($repaired | any(. as $n | $f == $n or ($f | endswith("::" + $n))) | not))
			| "baseline fails on \(.), which isn't a known failure: add a gate_red blocker, or a modify that repairs it"
		 end)
	  end;

def tp_run:
	if (.report.run | type) != "array" or (.report.run | length) == 0
		or any(.report.run[]; type != "object" or (.command | type) != "string" or (.command | test("^\\s*$")))
	then "add run: where and how to run these tests"
	else tc_list("run"; ["where", "command"]; ["where", "command"]; ["where"]),
		(tc_entries("run") | .w as $w | .v.where | tp_no_ids("\($w).where"))
	end;

def tp_blockers:
	tc_list("blockers"; ["kind", "at", "detail"]; ["kind", "detail"]; ["detail"]),
	(tc_entries("blockers") | select((.v | type) == "object") | .w as $w | .v
	 | (if has("kind") and (.kind | IN("gate_red", "cannot") | not) then "\($w).kind \(.kind | tojson) is not gate_red or cannot" else empty end),
	   (.detail | tp_no_ids("\($w).detail")));

# A noticed entry in a plan is read by the human, who never sees IDs.
def tp_noticed_text:
	tc_entries("noticed") | select((.v | type) == "object" and (.v.text | type) == "string") | .w as $w
	| .v.text | tp_no_ids("\($w).text");

def tp_unchanged_tree:
	if .tree.changed | not then empty
	else (.facts.changed // [])[] | "a plan job changes nothing in the tree: undo the change to \(.)" end;

def tp_common($keys):
	tc_top($keys),
	tp_behaviours,
	tp_test_rules,
	tp_no_tests_rule,
	tp_support,
	tp_untested,
	tp_baseline,
	tp_run,
	tc_notice_rules,
	tp_noticed_text,
	tp_blockers,
	tp_unchanged_tree;

def test_plan_problems: tp_common(tp_keys);
