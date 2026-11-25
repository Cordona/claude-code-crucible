# Spike: what each root owes next, or its facts. Input: every event.
include "ev";

def owed($step; $args): {step: $step, args: $args};
def fact_words($e; $s):
	{"build.submitted": "build", "test.submitted": "test"}[$s.type] as $t
	| if $s.type | IN("build.submitted", "test.submitted") then
		(($e | ev($s.job)).body.kind) as $k
		| (if $k == "fix" then "fix" else $t end) + " \($s.seq) has no review"
	  elif $s.type == "external-review.received" then "external review \($s.seq) has no judging round"
	  elif $s.type == "pr.review-requested" then "review request \($s.seq) has no review"
	  else "head move \($s.seq) has no re-review" end;
def fact_prefix: {"build.submitted": "no-review", "test.submitted": "no-review",
	"external-review.received": "external-review", "pr.review-requested": "review-requested",
	"pr.head-moved": "head-moved"}[.type];

# a fix submitted inside a live, unstopped loop is the loop's business, not a fact
def in_live_loop($e; $s; $f; $stop):
	$f != null and ($stop | not) and (($e | ev($s.job)).body | .kind == "fix" and .approval == $f.seq);

def facts($root; $f; $stop): . as $e
	| [.[] | select(.type == "fact.answered" and .root == $root) | .body.fact] as $answered
	| [.[] | select(.root == $root and (.type | IN("build.submitted", "test.submitted",
	        "external-review.received", "pr.review-requested", "pr.head-moved")))
	   | . as $s
	   | select(($e | rounds_targeting($s.seq)) == [])
	   | select((.type | IN("build.submitted", "test.submitted") | not) or (in_live_loop($e; $s; $f; $stop) | not))
	   | {key: "\(fact_prefix):\(.seq)", words: fact_words($e; $s)}
	   | select(.key | IN($answered[]) | not)];

# a slot or fix job that gave up or died, with no replacement yet
def owed_replace($root; $f; $stop): . as $e
	| [jobs[] | select(.root == $root and .body.replaces == null) | . as $j
	   | select($e | ended_badly($j.seq))
	   | select(all($e | jobs[]; .body.replaces != $j.seq))
	   | select(if $j.round != null then
	              (($e | merge_of($j.round)) == null) and (($e | round_stopped($e | ev($j.round))) | not)
	            elif $j.body.kind == "fix" then $f != null and $j.body.approval == $f.seq and ($stop | not)
	            else false end)
	   | owed("replace"; {job: .seq})] | first // null;

def owed_round_step($root): . as $e
	| [.[] | select(.type == "round.made" and .root == $root) | . as $r | select($e | settled($r))
	   | if .body.kind == "challenge" then
	       select(all($e | jobs[]; .body.kind != "test-plan" or .body.target != $r.seq)) | owed("plan-rework"; {round: .seq})
	     else
	       select(($e | merge_of($r.seq)) == null) | owed("merge"; {round: .seq})
	     end] | first // null;

def round_pending($root): . as $e
	| any(.[] | select(.type == "round.made" and .root == $root); . as $r | ($e | settled($r)) | not);

# the next fix side, the wait for one, or the round over the fixes
def fix_sides($e; $m; $sides; $subs): if $sides == [] then
		if any($subs[]; . as $s | ($e | rounds_targeting($s)) != []) then null
		else owed("make-round"; {kind: "code", targets: $subs}) end
	else
		$sides[0] as $side
		| ([$e | jobs[] | select(.body.kind == "fix" and .body.target == $m.seq and .body.payload.side == $side)] | last) as $j
		| ($e | end_of($j.seq?)) as $x
		| if $j == null then owed("fix"; {merge: $m.seq, side: $side})
		  elif $x == null then null
		  elif $x.type != "job.ended" then fix_sides($e; $m; $sides[1:]; $subs + [$x.seq])
		  elif $x.body.reason == "cancelled" then "stopped"
		  elif $j.body.replaces != null then "replacement-failed"
		  else null end
	end;

def owed_loop($root; $f; $stop): . as $e
	| if $stop then
		(if any(open_jobs[]; .root == $root) then null else owed("end-card"; {loop: $f.seq, reason: "stopped"}) end)
	  else
		(loop_merges($f) | last) as $m
		| ($m.round) as $rd | ev($rd) as $r
		| (if $r.body.loop == $f.seq then
			(harvest($m).targets) as $t
			| if any(slot_states($r)[]; .state == "failed") then "replacement-failed"
			  elif $t == [] then "clean"
			  elif loop_rounds($f) >= $f.body.cap then "cap"
			  else $t end
		   else $f.body.ids end) as $keys
		| if ($keys | type) == "string" then owed("end-card"; {loop: $f.seq, reason: $keys})
		  else
			([$keys[] as $k | ($e | raised($k)).kind | side_of_kind] | unique | sort_by(. != "production")) as $sides
			| fix_sides($e; $m; $sides; [])
			| if type == "string" then owed("end-card"; {loop: $f.seq, reason: .}) else . end
		  end
	  end;

def decided($m): any(.[]; (.type | IN("fix.chosen", "fix.none")) and .body.merge == $m.seq);

def owed_after_merge($root): . as $e | ev($root) as $start
	| ([.[] | select(.type == "review.merged" and .root == $root)] | last) as $m
	| if $m == null then null else
		(ev($m.round).body.loop) as $l
		| if $l != null then
			(if (loop_end(ev($l)) | .body.reason?) == "cap" and (decided($m) | not) then owed("choose"; {merge: $m.seq}) else null end)
		  elif $start.type == "pr.review-requested" then
			(if any(.[]; .type == "pr.posted" and .root == $root and .seq > $m.seq) then null else owed("comments"; {merge: $m.seq}) end)
		  elif decided($m) then null
		  else owed("choose"; {merge: $m.seq}) end
	  end;

def owed_replies($root): . as $e | ev($root) as $start
	| if $start.type != "external-review.received" then null else
		([.[] | select(.root == $root and (.type == "fix.none" or .type == "loop.ended"))] | last) as $d
		| if $d == null or any(.[]; .type == "pr.posted" and .root == $root and .seq > $d.seq) then null
		  else owed("replies"; {review: $root}) end
	  end;

def owed_plan($root): . as $e
	| ([.[] | select(.type == "plan.submitted" and .root == $root)] | last) as $p
	| if $p == null then null
	  elif ev($p.job).body.payload.challenges then
		(if any(.[]; .type == "plan.approved" and .body.plan == $p.seq) then null else owed("plan-gate"; {plan: $p.seq}) end)
	  elif rounds_targeting($p.seq) == [] then owed("make-round"; {kind: "challenge", targets: [$p.seq]})
	  else null end;

def owes_root($root): . as $e
	| live_loop($root) as $f
	| (if $f then loop_stopped($f) else false end) as $stop
	| (owed_replace($root; $f; $stop)
	   // owed_round_step($root)
	   // (if round_pending($root) then null
	       elif $f then owed_loop($root; $f; $stop)
	       else (owed_after_merge($root) // owed_replies($root) // owed_plan($root)) end)) as $owed
	| {root: $root, owed: $owed, facts: facts($root; $f; $stop),
	   waiting: [open_jobs[] | select(.root == $root) | .seq as $j | {job: $j, since: ($e | since($j))}],
	   loop: (if $f then {chosen: $f.seq, rounds: loop_rounds($f), cap: $f.body.cap} else null end)};

def owes: . as $e
	| [.[] | .root | select(. != null)] | unique
	| .[] | . as $r
	| select(all($e[]; .type != "root.closed" or .root != $r))
	| ($e | owes_root($r))
	| select(.owed != null or .facts != [] or .waiting != []);
