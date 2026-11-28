# Spike: the rules every job event is held to under the writer's lock: the
# body's fields and kinds, the links, and the repeats. Input {event, prior}
# as the real writer gives it; prints one reason per broken rule.
include "view" {search: "./"};

# kind names: seq, number, string, array, object; a trailing ? also allows null
def fields: {
	"job.dispatched": {kind: "string", target: "seq?", tree: "string?", report: "string", agent_type: "string",
		delivery: "string", hot_agent: "string?", slot: "number?", replaces: "seq?", approval: "seq",
		payload: "object", act: "object"},
	"job.assigned": {name: "string", tool_use_id: "string"},
	"job.ended": {reason: "string"},
	"build.submitted": {commit: "string?", files: "array", report: "string", answers: "object", declines: "object"},
	"test.submitted": {commit: "string?", files: "array", report: "string", answers: "object", declines: "object"},
	"plan.submitted": {draft: "string", answers: "object"},
	"review.submitted": {report: "string"},
	"round.made": {kind: "string", targets: "array", base: "string?", head: "string?", slots: "array", loop: "seq?"},
	"review.merged": {findings: "array", verdict: "string", targets: "array", gaps: "array"},
	"gate.answered": {step: "string", answer: "string"},
	"fix.chosen": {merge: "seq", query: "object", ids: "array", cap: "number"},
	"fix.none": {merge: "seq"},
	"plan.approved": {plan: "seq"},
	"waiver": {ids: "array", reason: "string"},
	"loop.stopped": {reason: "string"},
	"loop.ended": {reason: "string"},
	"fact.answered": {fact: "string", answer: "string"},
	"range.imported": {base: "string", head: "string", tree: "string"},
	"external-review.received": {pr: "string", head: "string", threads: "array"},
	"pr.review-requested": {pr: "string", base: "string", head: "string", tree: "string"},
	"pr.head-moved": {pr: "string", old_head: "string", head: "string", replies: "object"},
	"pr.posted": {items: "array"},
	"root.closed": {reason: "string"}};
# fields the writers may leave out, checked only when present
def optional: {"review.submitted": {findings: "array", answers: "object", rulings: "object", challenges: "array", threads: "object"}};
def choices: {
	"job.dispatched": {delivery: ["cold", "hot"]},
	"job.ended": {reason: ["gave-up", "cancelled", "died"]},
	"round.made": {kind: ["code", "external", "challenge"]},
	"review.merged": {verdict: ["pass", "changes"]},
	"loop.ended": {reason: ["clean", "cap", "deadlock", "replacement-failed", "refused", "stopped"]},
	"fact.answered": {answer: ["no"]}};
# a body field naming an earlier event, and the types it may name
def body_links: {approval: ["gate.answered", "fix.chosen"], replaces: ["job.dispatched"], merge: ["review.merged"],
	plan: ["plan.submitted"], loop: ["fix.chosen"]};

def is_kind($k):
	($k | endswith("?")) as $null | ($k | rtrimstr("?")) as $base
	| (. == null and $null)
	  or (if $base == "seq" then type == "number" and . >= 1 and . == floor else type == $base end);

def ev_in($p; $s): first($p[] | select(.seq == $s)) // null;
def ended($p; $j): any($p[]; .job == $j and ((.type | endswith(".submitted")) or .type == "job.ended"));

def field_reasons($e):
	(fields[$e.type] // null) as $f
	| if $f == null then "\($e.type) is not a job event type" else
		($f | to_entries[] | . as $x | select(($e.body | has($x.key)) | not) | "body.\($x.key) is missing"),
		($f + (optional[$e.type] // {}) | to_entries[] | . as $x | select($e.body | has($x.key))
		 | select($e.body[$x.key] | is_kind($x.value) | not) | "body.\($x.key) must be \($x.value)"),
		((choices[$e.type] // {}) | to_entries[] | . as $x | select($e.body | has($x.key))
		 | select($e.body[$x.key] | IN($x.value[]) | not) | "body.\($x.key) must be one of \($x.value | join(", "))")
	  end;

def link_reasons($e; $p):
	(if $e.root == null or $e.root == $e.seq then empty
	 elif ($e.root | type) != "number" then "root must be a seq, self or null"
	 elif (ev_in($p; $e.root) | .root?) != $e.root then "root \($e.root) is not a chain's first event" else empty end),
	(if $e.round == null then empty elif (ev_in($p; $e.round) | .type?) != "round.made" then "round \($e.round) is not a round.made" else empty end),
	(if $e.job == null then empty elif (ev_in($p; $e.job) | .type?) != "job.dispatched" then "job \($e.job) is not a job.dispatched" else empty end),
	(if $e.agent == null or ($e.agent | type) == "string" then empty else "agent must be a string or null" end),
	(body_links | to_entries[] | . as $x | ($e.body[$x.key] // null) as $s | select(($s | type) == "number")
	 | select((ev_in($p; $s) | .type?) | IN($x.value[]) | not) | "body.\($x.key) \($s) is not a \($x.value | join(" or "))"),
	(if $e.type == "round.made" and ($e.body.targets | type) == "array" then
		$e.body.targets[] | select(ev_in($p; .) == null) | "round target \(.) names no event" else empty end);

# What one approval covers: one job, one round (its slots and replacements),
# or one plan job with its challenge round and its rework.
def use($p; $j):
	if $j.body.replaces != null then use($p; ev_in($p; $j.body.replaces))
	elif $j.round != null then
		ev_in($p; $j.round) as $r
		| if $r.body.kind == "challenge" then use($p; ev_in($p; ev_in($p; $r.body.targets[0]).job)) else "round \($j.round)" end
	elif $j.body.kind == "test-plan" and (ev_in($p; $j.body.target) | .type?) == "round.made" then
		ev_in($p; $j.body.target) as $r | use($p; ev_in($p; ev_in($p; $r.body.targets[0]).job))
	else "job \($j.seq)" end;

def fix_submission($p; $s): ev_in($p; $s) as $x
	| $x != null and ($x.type | IN("build.submitted", "test.submitted", "plan.submitted"))
	  and ($x.type == "plan.submitted" or (ev_in($p; $x.job) | .body.kind?) == "fix");

def repeat_reasons($e; $p):
	if $e.type == "job.assigned" then
		(if $e.job == null then "job.assigned names no job"
		 elif any($p[]; .type == "job.assigned" and .job == $e.job) then "job \($e.job) is already assigned" else empty end)
	elif ($e.type | endswith(".submitted")) or $e.type == "job.ended" then
		(if $e.job == null then "\($e.type) names no job"
		 elif ended($p; $e.job) then "job \($e.job) has already ended" else empty end)
	elif $e.type == "review.merged" then
		(if $e.round == null then "review.merged names no round"
		 elif any($p[]; .type == "review.merged" and .round == $e.round) then "round \($e.round) is already merged" else empty end)
	elif $e.type == "round.made" then
		$e.body.targets[]? | . as $t | select(fix_submission($p; $t))
		| select(any($p[]; .type == "round.made" and any(.body.targets[]; . == $t)))
		| "submission \($t) already has its round"
	elif $e.type | IN("fix.chosen", "fix.none") then
		first($p[] | select((.type | IN("fix.chosen", "fix.none")) and .body.merge == $e.body.merge))
		| "merge \($e.body.merge) already has its choice (\(.seq))"
	elif $e.type == "plan.approved" then
		first($p[] | select(.type == "plan.approved" and .body.plan == $e.body.plan)) | "plan \($e.body.plan) is already approved"
	elif $e.type == "job.dispatched" then
		(if $e.body.replaces != null then
			first($p[] | select(.type == "job.dispatched" and .body.replaces == $e.body.replaces))
			| "job \($e.body.replaces) is already replaced (\(.seq))" else empty end),
		((ev_in($p; $e.body.approval) | select(.type? == "gate.answered")) as $g
		 | use($p; $e) as $mine
		 | first($p[] | select(.type == "job.dispatched" and .body.approval == $g.seq) | select(use($p; .) != $mine))
		 | "gate \($g.seq) already approved \(use($p; .))")
	else empty end;

def reasons:
	(.prior | lab_view) as $p | (.event | lab_event) as $e
	| field_reasons($e),
	  (if fields[$e.type] then link_reasons($e; $p), repeat_reasons($e; $p) else empty end);
