# job.defined: one job the human approved, written by job-define.sh.
# {kind, approval_gate {ref, position}, plugins, input_refs, work}: ref an
# accepted jobs gate, each ref and position once; input_refs each an earlier
# event's seq or a list of them; work {tree, range?, loop {iteration}, known_failures?}.
# Which refs and trees a kind takes is checked at resolve, from the kind's
# kinds/KIND.json; what can go stale between resolve and the write is checked here.
include "jobs-define/scripts/lib/job-frame";
.event as $e | $e.body as $b | .prior as $all
| (if $e.by == "job-define.sh" then empty else "job.defined is written only by job-define.sh" end),
  ((($b | keys) - ["kind", "approval_gate", "plugins", "input_refs", "work"])[] | "\(.) is not a job.defined field"),
  (if ($b.kind | type) == "string" and ($b.kind | test("^[a-z][a-z0-9]*(-[a-z0-9]+)*$")) then empty
   else "kind must be lowercase words joined by dashes" end),
  ($b.approval_gate as $g
   | if ($g | type) != "object" or (($g | keys) != ["position", "ref"]) then "approval_gate must be {ref, position}"
     elif ($g.ref | jf_whole | not) or ($g.position | jf_whole | not) then "approval_gate's ref and position must be whole numbers from 1"
     elif ([$all[] | select(.seq == $g.ref and .type == "gate.answered" and .body.record == "jobs" and .body.accepted == true)]
	| length) != 1 then "approval_gate.ref must be the seq of an accepted jobs gate"
     elif [$all[] | select(.type == "job.defined" and .body.approval_gate == $g)] | length > 0
     then "job \($g.position) of gate \($g.ref) is already defined"
     else empty end),
  ($b.plugins | jf_plugins_problems),
  (if ($b.input_refs | type) != "object" then "input_refs must be an object of event seqs"
   else ($b.input_refs | to_entries[] | .key as $k | .value
	| if (type == "array" and length > 0) or jf_whole then empty
	  else "input_refs.\($k) must be an event's seq or a list of them" end,
	  ([if type == "array" then .[] else . end] | .[] as $s
	   | if ($s | jf_whole) and ([$all[] | select(.seq == $s)] | length) == 1 then empty
	     else "input_refs.\($k): \($s) is not an earlier event's seq" end))
   end),
  (if ($b.work | type) != "object" then "work must be {tree, range?, loop}"
   else
	((($b.work | keys) - ["tree", "range", "loop", "known_failures"])[] | "work.\(.) is not a work field"),
	(if ($b.work | has("known_failures") | not) or ($b.work.known_failures | jf_lines) then empty
	 else "work.known_failures must be a list of one-line check names" end),
	($b.work.tree | jf_tree_problems($all)),
	(if ($b.work | has("range") | not) then empty
	 elif ($b.work.range | type) == "object" and ($b.work.range | keys) == ["base", "head"]
		and ($b.work.range.base | jf_sha) and ($b.work.range.head | jf_sha) then empty
	 else "work.range must be {base, head}, each a full commit sha" end),
	(if ($b.work.loop | type) != "object" or (($b.work.loop | keys) - ["iteration", "round"] | length) > 0
	 then "work.loop must be {iteration, round?}"
	 elif ($b.work.loop.iteration | jf_whole | not) then "work.loop.iteration must be a whole number from 1"
	 elif ($b.work.loop | has("round")) and ($b.work.loop.round | jf_whole | not) then "work.loop.round must be a whole number from 1"
	 elif ($b | jf_iteration($all)) as $n | $b.work.loop.iteration != $n
	 then "work.loop.iteration must be \($b | jf_iteration($all)), \(if $b.kind == "build" then "the next build's" else "the current one" end) on its tree: resolve again"
	 else empty end)
   end)
