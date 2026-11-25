# Spike: shared queries over an effort's events. Every function takes the
# whole event array (sorted by seq) as its input.

def ev($s): first(.[] | select(.seq == $s)) // null;
def is_end: (.type | endswith(".submitted")) or .type == "job.ended";
def end_of($j): first(.[] | select(.job == $j and is_end)) // null;
def jobs: [.[] | select(.type == "job.dispatched")];
def open_jobs: . as $e | [jobs[] | select(.seq as $j | ($e | end_of($j)) == null)];
def since($j): (first(.[] | select(.type == "job.assigned" and .job == $j)) | .seq) // $j;
def ended_badly($j): (end_of($j)) as $x | $x != null and $x.type == "job.ended" and ($x.body.reason | IN("gave-up", "died"));

def writing_kind: IN("build", "fix", "test", "test-plan");
def need_type($kind; $side):
	{build: "lab-builder", test: "lab-tester", "test-plan": "lab-tester", review: "lab-reviewer",
	 "external-review": "lab-reviewer", challenge: "lab-challenger", arbiter: "lab-arbiter"}[$kind]
	// (if $side == "tests" then "lab-tester" else "lab-builder" end);
def side_of_kind: if . == "test" then "tests" else "production" end;
def serious: .severity | IN("critical", "high", "medium");

# --- agents and trees -------------------------------------------------------

def agent_jobs($a): [.[] | select(.type == "job.assigned" and .agent == $a) | .job];
def agent_type_of($a): . as $e | (agent_jobs($a) | last) as $j | if $j == null then null else ($e | ev($j)).body.agent_type end;
def agent_open_jobs($a): . as $e | [open_jobs[] | select(.body.hot_agent == $a or (.seq | IN($e | agent_jobs($a)[])))] | map(.seq);
def root_of_tree($t): . as $e
	| [jobs[] | select(.body.tree == $t) | .seq as $j | (.root // ($e | end_of($j) | .root?))] | map(select(. != null)) | last // null;
def tree_of_root($r): [jobs[] | select(.root == $r and .body.tree != null) | .body.tree] | last // null;
def busy($tree; $kind): [open_jobs[] | select(.body.tree == $tree) | select(($kind | writing_kind) or (.body.kind | writing_kind)) | .seq];

# --- gates and loops --------------------------------------------------------

def used_approvals: [jobs[] | .body.approval];
def unused_gate($step; $root): . as $e
	| [.[] | select(.type == "gate.answered" and .body.step == $step and .body.accepted != false and (.root == $root or .root == null))
	       | select(.seq | IN($e | used_approvals[]) | not)] | last // null;
def latest_choice($root; $upto): last(.[] | select(.type == "fix.chosen" and .root == $root and .seq <= $upto)) // null;
def owning_choice($ev): ($ev.root) as $r | ($ev.seq) as $s | latest_choice($r; $s);
def loop_end($f): . as $e | first(.[] | select(.type == "loop.ended" and .root == $f.root and .seq > $f.seq)
	| . as $x | select(($e | owning_choice($x)).seq == $f.seq)) // null;
def loop_stopped($f): . as $e | any(.[] | select(.type == "loop.stopped" and .root == $f.root and .seq > $f.seq);
	. as $x | ($e | owning_choice($x)).seq == $f.seq);
def live_loop($root): (latest_choice($root; infinite)) as $f
	| if $f == null or (loop_end($f)) != null then null else $f end;
def loop_rounds($f): [.[] | select(.type == "round.made" and .body.loop == $f.seq)] | length;
def round_stopped($round): . as $e | $round.body.loop as $l
	| if $l == null then false else ($e | loop_stopped($e | ev($l))) end;
def loop_merges($f): . as $e | [.[] | select(.type == "review.merged")
	| .round as $rd | select(.seq == $f.body.merge or (($e | ev($rd)).body.loop == $f.seq))];

# --- findings ---------------------------------------------------------------

# Every raised finding, with its effort-wide id: <KIND>-NN per kind, in
# review.submitted seq order, then report order.
def all_raised:
	[.[] | select(.type == "review.submitted") | . as $s | (.body.findings // [])[]
	     | . + {sub: $s.seq, root: $s.root}]
	| reduce .[] as $f ({n: {}, out: []};
		(.n[$f.kind] = ((.n[$f.kind] // 0) + 1))
		| .n[$f.kind] as $k
		| .out += [$f + {id: (($f.kind | ascii_upcase) + "-" + (if $k < 10 then "0" else "" end) + ($k | tostring))}])
	| .out;
def raised($id): first(all_raised[] | select(.id == $id)) // null;

def findings_status($root; $upto): . as $e
	| [.[] | select(.type == "review.submitted" and .root == $root and .seq <= $upto)] as $subs
	| [all_raised[] | select(.root == $root and .sub <= $upto)]
	| map(. as $f | .status = (reduce ($subs[] | select(.seq > $f.sub)) as $s ("open";
		if ($s.body.answers // {})[$f.id] then $s.body.answers[$f.id]
		elif ($s.body.rulings // {})[$f.id] then "ruled-" + $s.body.rulings[$f.id]
		else . end)));

# The keys the human saw at the latest choice and did not choose.
def skipped_ids($root; $upto): . as $e | latest_choice($root; $upto) as $c
	| if $c == null then [] else
		[($e | ev($c.body.merge)).body.findings[] | select(.status | IN("open", "skipped"))
		 | select(.id | IN($c.body.ids[]) | not) | .id] end;
def waived($root): [.[] | select(.type == "waiver" and .root == $root) | .body.ids[]];
def rejected($root): . as $e
	| [.[] | select(.type == "review.submitted" and .root == $root) | (.body.threads // {}) | to_entries[] | select(.value == "rejected") | .key] as $t
	| [all_raised[] | select(.root == $root and .thread != null and (.thread | IN($t[]))) | .id];

# The keys a fix job was given, for the fix submissions a round targets.
def given($round): . as $e
	| [$round.body.targets[] as $t | ($e | ev($t)) | select(.job != null) | .job as $j | ($e | ev($j)) | .body.payload.findings[]?.id] | unique;

# The harvest: what a next fix takes from a merge's findings list.
def merge_targets($root; $round; $findings; $mseq): . as $e
	| (waived($root) + rejected($root)) as $out
	| [$findings[] | select(.status != "skipped" and (.id | IN($out[]) | not))] as $ok
	| if $round.body.loop == null then
		[$ok[] | select(.status == "open" and .realism == "realistic" and serious) | .id]
	  else
		($e | given($round)) as $given
		| [$e[] | select(.type == "review.merged" and .root == $root and .seq < $mseq) | .body.findings[].id] as $prev
		| [$ok[] | select(
			((.id | IN($given[])) and (.status | IN("open", "insisted", "ruled-fix")))
			or ((.id | IN($prev[]) | not) and .status == "open" and .realism == "realistic" and serious)) | .id]
	  end;
def fix_submissions_of($mseq): . as $e
	| [.[] | select(.type | IN("build.submitted", "test.submitted")) | select(.job != null)
	       | .job as $j | select(($e | ev($j)).body | .kind == "fix" and .target == $mseq)];
def deadlocked($m): . as $e
	| [fix_submissions_of($m.seq)[] | .body.answers | to_entries[] | select(.value == "declined") | .key] as $dec
	| [$m.body.findings[] | select(.status == "insisted" and (.id | IN($dec[]))) | .id];
def harvest($m): . as $e | ev($m.round) as $r
	| {targets: merge_targets($m.root; $r; $m.body.findings; $m.seq), deadlocked: deadlocked($m)};

# --- rounds -----------------------------------------------------------------

def slot_jobs($round; $slot): [jobs[] | select(.round == $round and .body.slot == $slot)];
# done | gap | failed (gap after a failed replacement) | replace (owed) | open
def slot_state($round; $slot; $stopped): . as $e | (slot_jobs($round; $slot) | last) as $j
	| if $j == null then "open" else
		($e | end_of($j.seq)) as $x
		| if $x == null then "open"
		  elif $x.type != "job.ended" then "done"
		  elif $x.body.reason == "cancelled" then "gap"
		  elif $j.body.replaces != null then "failed"
		  elif $stopped then "gap"
		  else "replace" end
	  end;
def slot_states($r): . as $e | ($e | round_stopped($r)) as $stop
	| [$r.body.slots[] | .slot as $n | {slot: $n, state: ($e | slot_state($r.seq; $n; $stop))}];
def settled($r): all(slot_states($r)[]; .state | IN("done", "gap", "failed"));
def gaps($r): [slot_states($r)[] | select(.state | IN("gap", "failed")) | .slot];
def merge_of($r): first(.[] | select(.type == "review.merged" and .round == $r)) // null;
def rounds_targeting($s): [.[] | select(.type == "round.made" and any(.body.targets[]; . == $s))];
