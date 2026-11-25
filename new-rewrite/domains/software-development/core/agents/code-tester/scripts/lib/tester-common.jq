# The tester's own shared ground for its reports: the keys, the text rules,
# the gates and the blockers; a jq module: load it with jq -L <the skills
# folder> and include "code-tester/scripts/lib/tester-common". This agent's report
# rules build on it; no other agent includes it. Every at is checked by the
# plumbing, before these rules run. Input {report, job, tree, facts}, as
# agent-submission's report-check.sh gives it: report the parsed report,
# its empty lists and objects pruned; job as job-of.sh prints it; tree
# {changed, lines}, changed whether the tree differs from its head. Each
# problem is the one line the agent repairs it by.

def tc_keys: ["summary", "gates", "decisions", "impact", "noticed", "questions", "blockers"];
# Filled in by a script, never by the agent.
def tc_stamped: ["id", "commit", "job", "kind", "agent", "iteration", "fix_round", "effort", "report", "sha256", "seq"];
def tc_gates: ["format", "lint", "typecheck", "test", "build", "scan", "manual", "mutation"];
def tc_results: ["pass", "fail", "not_run", "narrowed"];
def tc_text_max: 200;

def tc_or($words): if ($words | length) < 2 then $words[0] else ($words[:-1] | join(", ")) + " or " + $words[-1] end;

# The problem of the text at $where, or nothing.
def tc_text($where):
	if type != "string" then "\($where) must be text"
	elif test("^\\s*$") then "\($where) is blank; write it, or drop the entry"
	elif test("[\\r\\n]") then "\($where) is more than one line; write it on one"
	elif length > tc_text_max then "\($where) is \(length) characters; shorten it to \(tc_text_max)"
	else empty end;

# The entries of list $name, each {i, v, w}: its index, value and name.
def tc_entries($name):
	.report[$name] | if type == "array" then to_entries[] | {i: .key, v: .value, w: "\($name)[\(.key)]"} else empty end;

# The shape of list $name: a list of objects, only $fields, each of
# $required there, and each of $texts that is there one line of text.
def tc_list($name; $fields; $required; $texts):
	(.report[$name] | if . == null or type == "array" then empty else "\($name) must be a list" end),
	(tc_entries($name)
	 | .w as $w | .v as $v
	 | if ($v | type) != "object" then "\($w) must be an object"
	   else
		(($v | keys_unsorted) - $fields)[] as $k | "\($w) has unknown key \"\($k)\"; its keys are \($fields | join(", "))"
	   end,
	   if ($v | type) != "object" then empty
	   else
		(($required - ($v | keys))[] | if . == "at" then "\($w) needs at: the file and line" else "\($w) needs \(.)" end),
		($texts[] as $k | $v | select(has($k)) | .[$k] | tc_text("\($w).\($k)"))
	   end);

def tc_top($keys):
	(.report | keys_unsorted[]) as $k
	| if tc_stamped | index([$k]) then "remove \"\($k)\": this is filled in for you"
	  elif $keys | index([$k]) | not then "unknown key \"\($k)\"; the keys are \($keys | join(", "))"
	  else empty end;

# The summary becomes the commit's subject, "crucible(<kind>): <summary>",
# of at most 72 characters: so it is at most 55, and less for a long kind.
def tc_summary_max: [55, 72 - ("crucible(\(.job.kind // "build")): " | length)] | min;

def tc_summary:
	tc_summary_max as $max
	| .report | if has("summary") | not then "summary is missing: say in one line, of \($max) characters or fewer, what you did"
	else .summary | (tc_text("summary")
		// (if length > $max then "summary is \(length) characters; shorten it to \($max) or fewer"
			elif test("^[a-z]+(\\([^)]*\\))?!?:") then "summary starts with \"\(capture("^(?<p>[^:]*:)").p)\": drop the prefix; the commit adds its own"
			else empty end))
	end;

# The failed checks of the tree. A failed mutation gate is not one: its
# failing list holds the breaks that survived, which the review judges.
def tc_fails: [tc_entries("gates") | select((.v | type) == "object" and .v.result == "fail" and .v.gate != "mutation")];
def tc_blocker_kinds: [tc_entries("blockers") | .v | objects | .kind];

# The blocker kinds this agent may report, and those that answer a failed
# check of the tree.
def tc_blocker_kinds_allowed: ["gate_red", "cannot", "production_bug"];
def tc_covering: ["gate_red", "production_bug"];

def tc_gate_rules:
	(if (.report.gates | type) == "array" and (.report.gates | length) > 0 then empty
	 elif .report.gates == null then "list at least one gate you ran or couldn't run"
	 else empty end),
	tc_list("gates"; ["gate", "where", "result", "note", "failing"]; ["gate", "result"]; ["where", "note"]),
	(tc_entries("gates") | select((.v | type) == "object") | .w as $w | .v
	 | (if has("gate") and (.gate | IN(tc_gates[]) | not) then "\($w).gate \(.gate | tojson) is not one of \(tc_gates | join(", "))" else empty end),
	   (if has("result") and (.result | IN(tc_results[]) | not) then "\($w).result \(.result | tojson) is not one of \(tc_results | join(", "))" else empty end),
	   (if (.result == "not_run" or .result == "narrowed") and (has("note") | not) then "\($w) is \(.result): add a note saying why" else empty end),
	   (if .result == "fail" then
		(if has("failing") | not then "\($w) fails: list what fails in failing"
		 elif (.failing | type) != "array" then "\($w).failing must be a list"
		 else .failing | to_entries[] | .key as $i | .value | tc_text("\($w).failing[\($i)]") end)
	    elif has("failing") then "\($w) is \(.result // "without a result"): failing belongs only to a fail"
	    else empty end)),
	([tc_entries("gates") | select((.v | type) == "object" and (.v.gate | type) == "string")] as $gates
	 | range(0; $gates | length) as $a | range($a + 1; $gates | length) as $b
	 | $gates[$a] as $x | $gates[$b] as $y
	 | select($x.v.gate == $y.v.gate)
	 | if ($x.v | has("where") | not) or ($y.v | has("where") | not) then "\($x.w) and \($y.w) are both \($x.v.gate | tojson): add where to each"
	   elif $x.v.where == $y.v.where then "\($x.w) and \($y.w) are both \($x.v.gate | tojson) on \($x.v.where): give each its own where"
	   else empty end),
	((.job.known_failures // []) as $known | tc_blocker_kinds as $kinds
	 | tc_fails[] | select((.v.failing | type) == "array" and (.v.failing | all(type == "string")))
	 | (.v.failing - $known) as $new
	 | select(($new | length) > 0 and (any($kinds[]; IN(tc_covering[])) | not))
	 | if ($new | length) == 1 then "\(.w) fails on \($new[0]), which isn't a known failure: fix it, or add a gate_red blocker"
	   else "\(.w) fails on \($new | join(", ")), which aren't known failures: fix them, or add a gate_red blocker" end);

def tc_blocker_rules:
	tc_list("blockers"; ["kind", "at", "detail"]; ["kind", "detail"]; ["detail"]),
	((tc_fails | length) as $fails
	 | tc_entries("blockers") | select((.v | type) == "object" and (.v | has("kind"))) | .w as $w | .v.kind
	 | if IN(tc_blocker_kinds_allowed[]) | not then "\($w).kind \(tojson) is not \(tc_or(tc_blocker_kinds_allowed))"
	   elif . == "gate_red" and $fails == 0 then "\($w) is gate_red but no gate failed"
	   else empty end);

def tc_notice_rules:
	tc_list("noticed"; ["at", "kind", "text"]; ["at", "text"]; ["text"]),
	(tc_entries("noticed") | select((.v | type) == "object" and (.v | has("kind"))) | .w as $w | .v.kind
	 | if IN("secret", "instruction") then empty else "\($w).kind \(tojson) is not secret or instruction" end);

# Every rule of a report but the unchanged tree's; $keys are the report's
# keys, which a fix adds to.
def tc_common_problems($keys):
	tc_top($keys),
	tc_summary,
	tc_gate_rules,
	tc_list("decisions"; ["at", "choice", "why"]; ["at", "choice", "why"]; ["choice", "why"]),
	tc_list("impact"; ["text", "at"]; ["text"]; ["text"]),
	tc_notice_rules,
	tc_list("questions"; ["text"]; ["text"]; ["text"]),
	tc_blocker_rules;

def tc_blocked: (.report.blockers | type) == "array" and (.report.blockers | length) > 0;

def tc_unchanged_problem:
	if .tree.changed or tc_blocked then empty
	else "nothing changed in the tree: make the change, or add a blocker saying why" end;
