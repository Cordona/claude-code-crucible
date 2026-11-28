# An external review's rules, a jq module: load it with jq -L <the skills
# folder> and include "code-reviewer/scripts/lib/external-review-report".
# One item per point of someone else's review of our MR: every thread to
# judge judged, each point once; an item may judge any thread of the fetch;
# only valid has a finding, by the reviewer's finding rules; the others
# their reply or note. facts {threads: [{id, source, role}], judge: [id]},
# from reviewer-facts.sh.
include "code-reviewer/scripts/lib/reviewer-common";

def ex_verdicts: ["valid", "rejected", "already-fixed", "deferred", "answered", "noted"];

def ex_rules:
	. as $in
	| [(.facts.threads // [])[] | .id] as $threads
	| (.facts.judge // $threads) as $judge
	| [rc_entries("items") | select((.v | type) == "object")] as $items
	| (.report.items | if . == null or type == "array" then empty else "items must be a list" end),
	  ($judge[] as $t | select([$items[].v.thread] | index([$t]) | not) | "judge thread \($t): \(rc_or(ex_verdicts))"),
	  ($items[] | select(has("v") and (.v.thread | type) == "string" and (.v.thread | IN($threads[]) | not)) | "thread \(.v.thread) is not one of this job's threads"),
	  ([$items[] | select((.v.item | type) == "string") | {thread: .v.thread, item: .v.item}] | group_by(.) | map(select(length > 1) | .[0])[]
	   | "thread \(.thread) has item \(.item) twice: give each point its own label"),
	  (rc_entries("items") | .w as $w | .v as $v
	   | rc_object($v; $w; ["thread", "item", "verdict", "finding", "reply", "note", "source"]; ["thread", "verdict"]; ["thread", "item", "note"]; ["reply"]),
	     (if ($v | type) != "object" then empty
	      else
		(if $v | has("verdict") and ($v.verdict | IN(ex_verdicts[]) | not) then "\($w).verdict \($v.verdict | tojson) is not \(rc_or(ex_verdicts))" else empty end),
		(if $v.verdict == "valid" then
			(if $v | has("finding") | not then "\($w) is valid: add its finding" else empty end),
			(if $v | has("reply") then "\($w) is valid: remove its reply; it's drafted from the fix" else empty end)
		 elif ($v.verdict | IN(ex_verdicts[])) and ($v | has("finding")) then "\($w) is \($v.verdict): remove its finding"
		 else empty end),
		(if ($v.verdict | IN("rejected", "already-fixed", "answered")) and ($v | has("reply") | not) then "\($w) is \($v.verdict): add the reply to post" else empty end),
		(if $v.verdict == "deferred" and ($v | has("reply") | not) and ($v | has("note") | not)
		 then "\($w) is deferred: add the reply to post, or a note saying what the decision is" else empty end),
		(if ($v.finding | type) == "object" then
			($in | rc_finding("\($w).finding"; $v.finding))
		 else empty end)
	      end));

def external_review_report_problems: rc_top(["items", "noticed"]), ex_rules, rc_noticed, rc_tree;
