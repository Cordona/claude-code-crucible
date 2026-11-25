# A build-fix report's rules, a jq module: load it with jq -L <the skills
# folder> and include "code-builder/scripts/lib/build-fix-report". The
# builder's common rules, with fixes, one per chosen finding, and its own
# rule for an unchanged tree in place of the build's; the job holds the
# findings and sent_back.
include "code-builder/scripts/lib/builder-common";

def fx_statuses: ["done", "partly", "declined"];

def fx_rules:
	(.job.findings // []) as $chosen
	| (.job.sent_back // []) as $sent_back
	| bc_blocker_kinds as $kinds
	| [bc_entries("fixes") | select((.v | type) == "object" and (.v.id | type) == "string")] as $given
	| bc_list("fixes"; ["id", "status", "note", "reason"]; ["id", "status"]; ["note", "reason"]),
	  ($chosen[] as $id | select([$given[].v.id] | index([$id]) | not) | "list \($id) in fixes: \(bc_or(fx_statuses))"),
	  ($given[] | select(.v.id as $id | $chosen | index([$id]) | not) | "\(.v.id) is not one of this job's findings"),
	  (range(0; $given | length) as $a | range($a + 1; $given | length) as $b
	   | select($given[$a].v.id == $given[$b].v.id)
	   | "\($given[$a].w) and \($given[$b].w) both name \($given[$a].v.id): keep one"),
	  (bc_entries("fixes") | select((.v | type) == "object" and (.v | has("status"))) | .w as $w | .v
	   | .id as $id
	   | if .status | IN(fx_statuses[]) | not then "\($w).status \(.status | tojson) is not \(bc_or(fx_statuses))"
	     elif (.status == "partly" or .status == "declined") and (has("reason") | not) then "\($w) is \(.status): add a reason"
	     elif .status == "declined" and ($sent_back | index([$id])) and ($kinds | index(["cannot"]) | not)
	     then "\($id) was sent back by the human: it can't be declined again; fix it, or add a cannot blocker"
	     else empty end);

# An unchanged tree is right only when every finding was declined.
def fx_unchanged_problem:
	if .tree.changed then empty
	else first(bc_entries("fixes") | .v | objects | select(.status != "declined" and (.status | IN(fx_statuses[])))
		| "nothing changed, but \(.id) is \(.status): commit the fix") // empty
	end;

def build_fix_report_problems: bc_common_problems(bc_keys + ["fixes"]), fx_rules, fx_unchanged_problem;
