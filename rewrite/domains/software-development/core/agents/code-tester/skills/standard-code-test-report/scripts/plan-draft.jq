# The draft number of a tester seat's test plan, the one count the plan card
# and the plan gate share. A module: load it with jq -L <this folder> and
# include "plan-draft". A seat's drafts restart after its test commit and
# after a closed plan: a test-plan gate answer naming the seat whose label is
# one render-plan-gate.sh builds to close it, Stop or Agree, no tests.

def plan_draft_closing_labels: ["Stop", "Agree, no tests"];

# Whether . (a gate answer) is a closing label, with or without " (Recommended)".
def plan_draft_closes:
	. as $answer | any(plan_draft_closing_labels[]; . == $answer or . + " (Recommended)" == $answer);

# Input: the effort's test-plan.made, test.committed and
# gate.test-plan.answered events, in any order. Output: the number of seat
# $seat's test-plan.made events up to seq $seq after the later of its last
# test.committed and its last closed plan before $seq.
def plan_draft($seat; $seq):
	(map(select(.seq < $seq
		and ((.type == "test.committed" and .seat == $seat)
			or (.type == "gate.test-plan.answered" and (.body.view | objects | .seat == $seat)
				and (.body.answer | strings | plan_draft_closes)))))
		| map(.seq) | max // 0) as $since
	| map(select(.type == "test-plan.made" and .seat == $seat and .seq > $since and .seq <= $seq)) | length;
