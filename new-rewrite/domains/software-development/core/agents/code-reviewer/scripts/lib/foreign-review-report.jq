# A foreign review's rules, a jq module: load it with jq -L <the skills
# folder> and include "code-reviewer/scripts/lib/foreign-review-report".
# The reviewer's common rules on someone else's MR: findings, noticed and
# notes, and no fixes, since nothing of ours was fixed.
include "code-reviewer/scripts/lib/reviewer-common";

def foreign_review_report_problems:
	rc_top(["findings", "noticed", "notes"]), rc_findings, rc_noticed, rc_notes, rc_tree;
