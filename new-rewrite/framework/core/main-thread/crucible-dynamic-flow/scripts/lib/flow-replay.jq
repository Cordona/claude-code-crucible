# The flow's shape checks and its replay, in one home: used by the flow
# scripts, the per-event rules and the Stop hook. Input to the replay
# functions: every event of the effort, in seq order.

def one_line: type == "string" and test("\\S") and (test("[\\r\\n]") | not);

# Problems of a done_when at $at, one line each.
def done_when_problems($at):
	if type != "object" then "\($at).done_when must be an object"
	elif has("event") then
		(if .event | one_line then empty else "\($at).done_when.event must be one line: the type of an event a piece writes" end),
		(if has("match") and ((.match | type) != "object") then "\($at).done_when.match must be an object" else empty end),
		((keys - ["event", "match"])[] | "\($at).done_when.\(.) is not a done_when field")
	elif has("criteria") then
		(if .criteria | one_line then empty else "\($at).done_when.criteria must be one line" end),
		(if has("by") and .by != "human" then "\($at).done_when.by can only be human" else empty end),
		((keys - ["criteria", "by"])[] | "\($at).done_when.\(.) is not a done_when field")
	else "\($at).done_when must hold an event or a criteria" end;

# Problems of one node at $at.
def node_problems($at):
	if type != "object" then "\($at) must be an object"
	else
		((keys - ["id", "do", "uses", "done_when"])[] | "\($at).\(.) is not a step field"),
		(if (.id | type) == "number" and .id >= 1 and (.id | floor) == .id then empty else "\($at).id must be a whole number from 1" end),
		(if .do | one_line then empty else "\($at).do must be one line" end),
		(if has("uses") and ((.uses | one_line) | not) then "\($at).uses must be one line" else empty end),
		(if has("done_when") then (.done_when | done_when_problems($at)) else "\($at).done_when is missing" end)
	end;

# Problems of a flow.agreed body.
def flow_problems:
	if type != "object" then "the flow must be an object"
	else
		((keys - ["goal", "done_when", "steps"])[] | "\(.) is not a flow field"),
		(if .goal | one_line then empty else "goal must be one line" end),
		(if has("done_when") then (.done_when | done_when_problems("the flow")) else "the flow's done_when is missing" end),
		(if (.steps | type) == "array" and (.steps | length) > 0 then
			(.steps[] | node_problems("steps[\(.id // "?")]")),
			(if (.steps | map(.id) | unique | length) != (.steps | length) then "steps hold a repeated id" else empty end)
		 else "steps must be a non-empty array" end)
	end;

# Whether event $e fits done_when $dw (an event kind).
def fits($dw): . as $e
	| $e.type == $dw.event and (($dw.match // {}) | to_entries | all(. as $m | $e.body[$m.key] == $m.value));

# The flow named by seq $seq, replayed: {seq, goal, done_when, steps, ended}.
# Each step gains status (open, done, skipped), since (the seq after which
# waiting evidence is looked for), floor (the seq after which named evidence
# must come: its latest reopen, or 0) and, when done, kind, event, evidence.
def flow_state($seq):
	. as $all
	| ($all[] | select(.seq == $seq and .type == "flow.agreed")) as $agreed
	| reduce ($all[] | select(.seq > $seq and (.type | startswith("flow.")) and .body.flow == $seq)) as $e (
		{seq: $seq, goal: $agreed.body.goal, done_when: $agreed.body.done_when, ended: null,
		 ids: [$agreed.body.steps[].id],
		 steps: [$agreed.body.steps[] | . + {status: "open", since: $seq, floor: 0}]};
		if $e.type == "flow.changed" then
			reduce $e.body.ops[] as $op (.;
				if $op.add then
					.ids += [$op.add.id]
					| ($op.add + {status: "open", since: $e.seq, floor: 0}) as $node
					| if $op.before then
						(.steps | map(.id) | index($op.before)) as $i | .steps = .steps[:$i] + [$node] + .steps[$i:]
					  else .steps += [$node] end
				elif $op.skip then .steps |= map(if .id == $op.skip then .status = "skipped" else . end)
				elif $op.move then
					(.steps | map(select(.id == $op.move)) | first) as $node
					| .steps |= map(select(.id != $op.move))
					| (.steps | map(.id) | index($op.before)) as $i | .steps = .steps[:$i] + [$node] + .steps[$i:]
				elif $op.revise then
					if $op.revise.step then .steps |= map(if .id == $op.revise.step then .done_when = $op.revise.done_when else . end)
					else .done_when = $op.revise.done_when end
				elif $op.reopen then
					.steps |= map(if .id == $op.reopen then {id, do, done_when} + (if .uses then {uses} else {} end) + {status: "open", since: $e.seq, floor: $e.seq} else . end)
				else . end)
		elif $e.type == "flow.step.done" then
			.steps |= map(if .id == $e.body.step then . + {status: "done", kind: $e.body.kind}
				+ ($e.body | {event, evidence} | with_entries(select(.value != null))) else . end)
		elif $e.type == "flow.ended" then .ended = $e.body
		else . end);

# The seqs already used as step evidence, across the effort.
def used_evidence: [.[] | select(.type == "flow.step.done") | .body.event | select(. != null)];

# For flow $f (a flow_state) over the events $all: the open event steps with
# evidence waiting unmarked, as [{id, events: [seq...]}].
def waiting($f): . as $all | ($all | used_evidence) as $used
	| [$f.steps[] | select(.status == "open" and (.done_when | has("event"))) as $s
		| [$all[] | select(.seq > $s.since and fits($s.done_when)) | .seq | select(. as $q | $used | index([$q]) | not)] as $ev
		| select($ev | length > 0) | {id: $s.id, events: $ev}];

# The flow ids (seqs of flow.agreed) not yet ended.
def open_flows: . as $all | [$all[] | select(.type == "flow.agreed") | .seq
	| select(. as $s | [$all[] | select(.type == "flow.ended" and .body.flow == $s)] | length == 0)];
