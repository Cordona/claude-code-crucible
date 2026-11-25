# Spike: planning a dispatch. job_plan($o) plans one job (job-dispatch.sh),
# round_plan($o; $git) plans a round and its jobs (round.sh). Both return
# {ok: false, refusal, by?} or {ok: true, ...}, and derive the root and the
# approval from the events only.
include "ev";

def tech_kind: "shell";
def refuse($key): {ok: false, refusal: $key};
def done_already($seq): {ok: false, refusal: "done-already", by: $seq};
def cut($ids): . as $e | [$ids[] as $i | ($e | raised($i)) | {id, kind, file, severity, title}];
def authors_of($round): . as $e
	| [$round.body.targets[] as $t | ($e | ev($t)) | select(.type | IN("build.submitted", "test.submitted")) | .agent];

def agent_session($a): [.[] | select(.type == "job.assigned" and .agent == $a) | .session] | last;
def hot_refusal($agent; $type; $authors; $running):
	if $agent == null then "no-hot-agent"
	elif $running != null and agent_session($agent) != $running then "hot-agent-gone"
	elif ($agent | IN($authors[])) then "own-commit"
	elif agent_type_of($agent) != $type then "type-misfit"
	elif agent_open_jobs($agent) != [] then "hot-agent-busy"
	else null end;

# --- one job ---------------------------------------------------------------

def fix_ctx($o): . as $e | ev($o.merge) as $M
	| if $M == null or $M.type != "review.merged" then {stop: refuse("not-a-merge")}
	  else
		live_loop($M.root) as $f
		| (if $f == null then null else (loop_merges($f) | last) end) as $cur
		| (if $f == null or $cur.seq != $M.seq then []
		   elif $M.seq == $f.body.merge then $f.body.ids
		   else harvest($M).targets end) as $keys
		| [$keys[] | . as $k | select((($e | raised($k)).kind | side_of_kind) == $o.side)] as $mine
		| ([jobs[] | select(.body.kind == "fix" and .body.target == $M.seq and .body.payload.side == $o.side)] | last) as $had
		| {root: $M.root, round: null, kind: "fix", target: $M.seq, tree: tree_of_root($M.root),
		   agent_type: need_type("fix"; $o.side), slot: null, replaces: null, approval: $f.seq?,
		   payload: {findings: cut($mine), side: $o.side}, authors: [],
		   stop: (if $had then done_already($had.seq) else null end),
		   deny: (if $f == null or $cur.seq != $M.seq then "no-approval"
		          elif loop_stopped($f) then "loop-stopped"
		          elif $M.seq != $f.body.merge and loop_rounds($f) >= $f.body.cap then "no-approval"
		          elif $mine == [] then "no-targets"
		          else null end)}
	  end;

def tree_job_ctx($o; $kind): . as $e | root_of_tree($o.tree) as $root
	| unused_gate($kind; $root) as $g
	| (if $kind == "test" then ([.[] | select(.type == "build.submitted" and .root == $root)] | last | .seq?) else null end) as $build
	| {root: $root, round: null, kind: $kind, target: $build, tree: $o.tree, agent_type: need_type($kind; null),
	   slot: null, replaces: null, approval: $g.seq?, authors: [],
	   payload: (if $kind == "build" then {task: $o.task} else {build: $build} end),
	   stop: (if $kind == "test" and $build == null then refuse("no-build") else null end),
	   deny: (if $g == null then "no-approval" else null end)};

def plan_job_ctx($o): . as $e | ev($o.target // $o.round) as $T
	| if $T == null then {stop: refuse("no-target")}
	  elif $T.type == "build.submitted" then
		unused_gate("test-plan"; $T.root) as $g
		| {root: $T.root, round: null, kind: "test-plan", target: $T.seq, tree: ev($T.job).body.tree,
		   agent_type: "lab-tester", slot: null, replaces: null, approval: $g.seq?, authors: [],
		   payload: {build: $T.seq}, stop: null, deny: (if $g == null then "no-approval" else null end)}
	  elif $T.type == "round.made" and $T.body.kind == "challenge" then
		ev($T.body.targets[0]) as $p | ev($p.job) as $pj
		| ([jobs[] | select(.body.kind == "test-plan" and .body.target == $T.seq)] | first) as $had
		| {root: $T.root, round: null, kind: "test-plan", target: $T.seq, tree: $pj.body.tree,
		   agent_type: "lab-tester", slot: null, replaces: null, approval: $pj.body.approval, authors: [],
		   payload: {build: $pj.body.payload.build,
		             challenges: [.[] | select(.type == "review.submitted" and .round == $T.seq) | .body.challenges[]?.key]},
		   stop: (if $had then done_already($had.seq) elif (settled($T) | not) then refuse("round-open") else null end),
		   deny: null}
	  else {stop: refuse("no-target")} end;

def replacement_ctx($o): . as $e | ev($o.replaces) as $J
	| if $J == null or $J.type != "job.dispatched" then {stop: refuse("not-a-job")}
	  else
		([jobs[] | select(.body.replaces == $J.seq)] | first) as $had
		| (if $J.round != null then ev($J.round) else null end) as $r
		| live_loop($J.root) as $f
		| $J.body + {root: $J.root, round: $J.round, replaces: $J.seq,
		    authors: (if $r != null and ($J.body.kind | writing_kind | not) then authors_of($r) else [] end),
		    stop: (if $had then done_already($had.seq)
		           elif ($o.kind != null and $o.kind != $J.body.kind) then refuse("kind-mismatch")
		           elif (ended_badly($J.seq) | not) then refuse("not-replaceable")
		           else null end),
		    second: ($J.body.replaces != null),
		    deny: (if $r != null and round_stopped($r) then "loop-stopped"
		           elif $J.body.kind == "fix" and ($f == null or $f.seq != $J.body.approval) then "no-approval"
		           elif $J.body.kind == "fix" and loop_stopped($f) then "loop-stopped"
		           else null end)}
	  end;

def job_ctx($o):
	if $o.replaces != null then replacement_ctx($o)
	elif $o.merge != null or $o.kind == "fix" then fix_ctx($o)
	elif $o.kind == "build" or $o.kind == "test" then tree_job_ctx($o; $o.kind)
	elif $o.kind == "test-plan" then plan_job_ctx($o)
	else {stop: refuse("round-job")} end;

def job_plan($o): . as $e | job_ctx($o) as $c
	| ($o.delivery // "cold") as $d
	| if $c.stop then $c.stop
	  elif $d == "hot" and (hot_refusal($o.hot_agent; $c.agent_type; $c.authors; $o.running)) then refuse(hot_refusal($o.hot_agent; $c.agent_type; $c.authors; $o.running))
	  elif $c.second then refuse("second-replacement")
	  elif $c.replaces != null and $d == "hot" then refuse("replacement-is-fresh")
	  elif $c.tree != null and busy($c.tree; $c.kind) != [] then refuse("tree-busy")
	  elif $c.deny then refuse($c.deny)
	  else {ok: true, root: $c.root, round: $c.round,
	        body: {kind: $c.kind, target: $c.target, tree: $c.tree, agent_type: $c.agent_type, delivery: $d,
	               hot_agent: (if $d == "hot" then $o.hot_agent else null end), slot: $c.slot,
	               replaces: $c.replaces, approval: $c.approval, payload: $c.payload}}
	  end;

# --- a round -----------------------------------------------------------------

def slot_kind_of($job): . as $e | ev($job.round).body.slots[]? | select(.slot == $job.body.slot) | .kind;

# a reviewer of this kind who already submitted on the root, free and not an author
def hot_for($root; $kind; $type; $authors; $taken; $running): . as $e
	| [.[] | select(.type == "review.submitted" and .root == $root and .round != null) | . as $s
	   | ($e | ev($s.job)) as $j | select(($e | slot_kind_of($j)) == $kind) | $s.agent] | last as $a
	| if $a == null or ($a | IN($taken[])) or ($e | hot_refusal($a; $type; $authors; $running)) then null else $a end;

def round_jobs($e; $root; $authors; $hot; $running):
	reduce .[] as $j ([];
		[.[].hot_agent | select(. != null)] as $taken
		| (if $hot then ($e | hot_for($root; $j.slot_kind; $j.agent_type; $authors; $taken; $running)) else null end) as $a
		| . + [$j + {delivery: (if $a then "hot" else "cold" end), hot_agent: $a}]);

def loop_round_plan($o): . as $e
	| [$o.targets[] as $t | ($e | ev($t))] as $subs
	| if any($subs[]; . == null or (.type | IN("build.submitted", "test.submitted") | not)) then refuse("not-fix-submissions") else
	[$subs[] | .job as $j | ($e | ev($j))] as $fjobs
	| if any($fjobs[]; .body.kind != "fix") then refuse("not-fix-submissions") else
	$subs[0].root as $root | live_loop($root) as $f
	| (first(.[] | select(.type == "round.made") | select(any(.body.targets[]; IN($o.targets[])))) // null) as $had
	| if $had then done_already($had.seq)
	  elif $f == null or any($fjobs[]; .body.approval != $f.seq) then refuse("no-approval")
	  elif loop_stopped($f) then refuse("loop-stopped")
	  elif loop_rounds($f) >= $f.body.cap then refuse("no-approval")
	  else
		ev($fjobs[0].body.target) as $m | ev($m.round) as $prev
		| ([$fjobs[].body.payload.findings[].id] | unique) as $given
		| ([$subs[].body.answers] | add // {}) as $answers
		| ([$subs[].body.declines] | add // {}) as $declines
		| [$m.body.findings[] | select(.status == "insisted" and $answers[.id] == "declined") | .id] as $dead
		| ($given - $dead) as $live
		| [$subs[].body.files[]] as $changed
		| (($changed + [$live[] as $k | ($e | raised($k)).file]) | unique) as $cover
		| (if $live == [] and $changed == [] then [] else ([$live[] as $k | ($e | raised($k)).kind] + [tech_kind] | unique) end) as $kinds
		| skipped_ids($root; infinite) as $skipped
		| (INDEX($m.body.findings[]; .id)) as $status
		| $prev.body.head as $base | ([$subs[].body.commit | select(. != null)] | last // $base) as $head
		| [$kinds | to_entries[] | .value as $k | {slot: (.key + 1), slot_kind: $k, kind: "review", agent_type: "lab-reviewer",
		    cover: $cover,
		    payload: {cover: $cover, diff: "\($base)..\($head)",
		      earlier: [$live[] as $id | ($e | raised($id)) | select(.kind == $k)
		                | {id, status: $status[.id].status, title, answer: $answers[.id], decline: ($declines[.id] // null)}],
		      skipped: [$skipped[] as $id | ($e | raised($id)) | select(.kind == $k and (.file | IN($cover[]))) | .id]}}] as $reviewers
		| (if $dead == [] then [] else
		    [{slot: (($reviewers | length) + 1), slot_kind: "arbiter", kind: "arbiter", agent_type: "lab-arbiter",
		      cover: ([$dead[] as $id | ($e | raised($id)).file] | unique),
		      payload: {keys: [$dead[] as $id | ($e | raised($id))
		                       | {id, finding: .title, decline: ($declines[.id] // null), insist: null}]}}] end) as $arbiter
		| {ok: true, root: $root, approval: $f.seq, tree: $fjobs[0].body.tree,
		   round: {kind: "code", targets: $o.targets, base: $base, head: $head,
		           slots: [($reviewers + $arbiter)[] | {slot, kind: .slot_kind, agent_type, cover}], loop: $f.seq},
		   jobs: (($reviewers + $arbiter) | round_jobs($e; $root; [$subs[].agent]; true; $o.running))}
	  end end end;

def gated_round_plan($o; $git): . as $e
	| [$o.targets[] as $t | ($e | ev($t))] as $ts
	| ($ts | map(.root?) | unique) as $roots
	| if any($ts[]; . == null) or ($roots | length) != 1 then refuse("bad-targets")
	  elif $o.kinds == [] then refuse("no-kinds") else
	$roots[0] as $root | unused_gate("review"; $root) as $g
	| if $g == null then refuse("no-approval") else
	if $o.kind == "external" then
		$ts[0] as $r
		| if $r.type != "external-review.received" then refuse("bad-targets") else
		[$o.kinds | to_entries[] | .value as $k
		 | [$r.body.threads[] | select($k == tech_kind or .file != null) | .thread] as $cover
		 | {slot: (.key + 1), slot_kind: $k, kind: "external-review", agent_type: "lab-reviewer", cover: $cover,
		    payload: {threads: $cover}}] as $slots
		| {ok: true, root: $root, approval: $g.seq, tree: ($r.body.tree // tree_of_root($root)),
		   round: {kind: "external", targets: $o.targets, base: null, head: $r.body.head,
		           slots: [$slots[] | {slot, kind: .slot_kind, agent_type, cover}], loop: null},
		   jobs: ($slots | round_jobs($e; $root; []; false; $o.running))} end
	else
		($ts | last) as $last
		| (if $last.type == "pr.head-moved" then {base: $last.body.old_head, head: $last.body.head}
		   elif $last.type | IN("range.imported", "pr.review-requested") then {base: $last.body.base, head: $last.body.head}
		   else {base: $git.base, head: $last.body.commit} end) as $range
		| (([$ts[] | .body.files[]?] + $git.files) | unique) as $cover
		| (if $last.type | IN("range.imported", "pr.review-requested") then $last.body.tree
		   elif $last.job != null then ($e | ev($last.job)).body.tree
		   else tree_of_root($root) end) as $tree
		| ($last.body.replies // {}) as $replies
		| [$o.kinds | to_entries[] | .value as $k
		   | {slot: (.key + 1), slot_kind: $k, kind: "review", agent_type: "lab-reviewer", cover: $cover,
		      payload: {cover: $cover, diff: "\($range.base)..\($range.head)", skipped: [],
		        earlier: (if $last.type != "pr.head-moved" then [] else
		          [$e | findings_status($root; infinite)[] | select(.kind == $k and (.status | IN("open", "insisted", "ruled-fix")))
		           | {id, status, title, answer: (if $replies[.id] then "done" else null end), decline: null}] end)}}] as $slots
		| {ok: true, root: $root, approval: $g.seq, tree: $tree,
		   round: {kind: "code", targets: $o.targets, base: $range.base, head: $range.head,
		           slots: [$slots[] | {slot, kind: .slot_kind, agent_type, cover}], loop: null},
		   jobs: ($slots | round_jobs($e; $root; [$ts[].agent | select(. != null)]; false; $o.running))}
	end end end;

def challenge_round_plan($o): . as $e | ev($o.targets[0]) as $p
	| if $p == null or $p.type != "plan.submitted" then refuse("bad-targets")
	  elif rounds_targeting($p.seq) != [] then done_already(rounds_targeting($p.seq)[0].seq)
	  else
		[{slot: 1, slot_kind: "challenge", kind: "challenge", agent_type: "lab-challenger", cover: [$p.body.draft],
		  payload: {draft: $p.body.draft}}] as $slots
		| {ok: true, root: $p.root, approval: ev($p.job).body.approval, tree: null,
		   round: {kind: "challenge", targets: [$p.seq], base: null, head: null,
		           slots: [$slots[] | {slot, kind: .slot_kind, agent_type, cover}], loop: null},
		   jobs: ($slots | round_jobs($e; $p.root; []; false; $o.running))}
	  end;

def round_plan($o; $git):
	if $o.kind == "challenge" then challenge_round_plan($o)
	elif $o.kind == "code" and $o.kinds == null then loop_round_plan($o)
	elif $o.kind | IN("code", "external") then gated_round_plan($o; $git)
	else refuse("bad-kind") end;
