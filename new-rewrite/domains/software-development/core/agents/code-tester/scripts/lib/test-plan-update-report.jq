# A test plan rework's rules, a jq module: load it with jq -L <the skills
# folder> and include "code-tester/scripts/lib/test-plan-update-report".
# The whole plan again, by the plan's rules, and one answer per challenge
# the job's challenge ref names. An applied challenge that asks to add a test needs a T-
# test the reworked plan didn't have.
include "code-tester/scripts/lib/tester-common";
include "code-tester/scripts/lib/test-plan-report";

def tu_challenge_answers: ["applied", "cannot"];

def tu_answer_rules:
	(.facts.challenges // []) as $challenges
	| [$challenges[].id] as $ids
	| [tc_entries("answers") | select((.v | type) == "object" and (.v.id | type) == "string")] as $given
	| [(.facts.plan.tests // [])[] | objects | .id] as $before
	| [tc_entries("tests") | .v | objects | select(.action == "add" and (.id | IN($before[]) | not))] as $new
	| tc_list("answers"; ["id", "answer", "reason"]; ["id", "answer"]; ["reason"]),
	  ($ids[] as $id | select([$given[].v.id] | index([$id]) | not) | "answer \($id): applied or cannot"),
	  ($given[] | select(.v.id | IN($ids[]) | not) | "\(.v.id) is not one of this job's challenges"),
	  (range(0; $given | length) as $a | range($a + 1; $given | length) as $b
	   | select($given[$a].v.id == $given[$b].v.id)
	   | "\($given[$a].w) and \($given[$b].w) both answer \($given[$a].v.id): keep one"),
	  (tc_entries("answers") | select((.v | type) == "object" and (.v | has("answer"))) | .w as $w | .v
	   | if .answer | IN(tu_challenge_answers[]) | not then "\($w).answer \(.answer | tojson) is not applied or cannot"
	     elif .answer == "cannot" and (has("reason") | not) then "\($w) is cannot: add a reason"
	     elif has("reason") then .reason | tp_no_ids("\($w).reason")
	     else empty end),
	  ($given[] | .v | select(.answer == "applied") | .id as $id
	   | select(any($challenges[]; .id == $id and .ask == "add") and ($new | length) == 0)
	   | "\($id) asked to add a test and is applied, but no new T- test was added");

def test_plan_update_problems: tp_common(tp_keys + ["answers"]), tu_answer_rules;
