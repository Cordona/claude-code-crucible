# A review's rules, cold, hot or a re-review, a jq module: load it with
# jq -L <the skills folder> and include "code-reviewer/scripts/lib/review-report".
# The reviewer's common rules, and on a re-review one status per earlier
# finding the job carries: fixed or open for a fix the fixer did (done or
# partly), agree or disagree for one it declined. A clean review is {}.
include "code-reviewer/scripts/lib/reviewer-common";

def rv_statuses: ["fixed", "open", "agree", "disagree"];
def rv_for($fixer): if $fixer == "declined" then ["agree", "disagree"] else ["fixed", "open"] end;

def rv_fixes:
	(.job.earlier // []) as $earlier
	| [rc_entries("fixes") | select((.v | type) == "object" and (.v.id | type) == "string")] as $given
	| rc_list("fixes"; ["id", "status", "reason"]; ["id", "status"]; ["reason"]; []),
	  ($earlier[] | . as $e | select([$given[].v.id] | index([$e.id]) | not)
	   | "give \($e.id) a status: \(rv_for($e.status) | join(" or ")) (the fixer said \($e.status))"),
	  ($given[] | select(.v.id as $id | [$earlier[].id] | index([$id]) | not) | "\(.v.id) is not one of this job's earlier findings"),
	  (range(0; $given | length) as $a | range($a + 1; $given | length) as $b
	   | select($given[$a].v.id == $given[$b].v.id)
	   | "\($given[$a].w) and \($given[$b].w) both name \($given[$a].v.id): keep one"),
	  (rc_entries("fixes") | select((.v | type) == "object" and (.v | has("status"))) | .w as $w | .v
	   | .id as $id | ([$earlier[] | select(.id == $id) | .status] | first) as $fixer
	   | if .status | IN(rv_statuses[]) | not then "\($w).status \(.status | tojson) is not \(rc_or(rv_statuses))"
	     elif $fixer != null and (.status | IN(rv_for($fixer)[]) | not)
	     then (if $fixer == "declined" then "\($id) was declined: give agree or disagree, with a reason"
		   else "\($id) was \($fixer): give fixed or open" end)
	     elif .status != "fixed" and (has("reason") | not) then "\($w) is \(.status): add a reason"
	     else empty end);

def review_report_problems:
	rc_top(["findings", "fixes", "noticed", "notes"]), rc_findings, rv_fixes, rc_noticed, rc_notes, rc_tree;
