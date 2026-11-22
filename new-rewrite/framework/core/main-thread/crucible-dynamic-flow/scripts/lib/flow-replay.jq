# The flow's shape checks and its replay, in one home: used by the flow
# scripts, the per-event rules and the Stop hook. Input to the replay
# functions: every event of the effort, in seq order.

def one_line: type == "string" and test("\\S") and (test("[\\r\\n]") | not);

# Problems of a ends_with at $at, one line each: a step ends in an event.
def ends_with_problems($at):
	if type != "object" then "\($at).ends_with must be an object"
	else
		(if .event | one_line then empty else "\($at).ends_with.event must be one line: the type of an event a piece writes" end),
		(if has("match") and ((.match | type) != "object") then "\($at).ends_with.match must be an object" else empty end),
		((keys - ["event", "match"])[] | "\($at).ends_with.\(.) is not a ends_with field")
	end;

# The form of a step's key, <component>/<name>.
def a_key: type == "string" and test("^[A-Za-z0-9._-]+/[a-z0-9]+(-[a-z0-9]+)*$");

# Problems of one id at $at.
def id_problems($at):
	if type == "number" and . >= 1 and floor == . then empty else "\($at).id must be a whole number from 1" end;

# Problems of one proposed step {id, step} at $at: a step only names a
# declared step; what it does and its ends_with come from the catalogue.
def proposed_problems($at):
	if type != "object" then "\($at) must be an object"
	else
		((keys - ["id", "step"])[] | "\($at).\(.) is not a field of a proposed step: name a declared step by its key"),
		(.id | id_problems($at)),
		(if .step | a_key then empty else "\($at).step must be a step key, <component>/<name>, from flow-candidates.sh" end)
	end;

# Problems of a proposed flow, {goal, steps: [{id, step}]}.
def proposal_problems:
	if type != "object" then "the flow must be an object"
	else
		((keys - ["goal", "steps"])[] | "\(.) is not a flow field"),
		(if .goal | one_line then empty else "goal must be one line" end),
		(if (.steps | type) == "array" and (.steps | length) > 0 then
			(.steps[] | proposed_problems("steps[\(.id // "?")]")),
			(if (.steps | map(.id) | unique | length) != (.steps | length) then "steps hold a repeated id" else empty end)
		 else "steps must be a non-empty array" end)
	end;

# Problems of one resolved step at $at, as a flow event holds it:
# {id, step, does, skills, ends_with}.
def node_problems($at):
	if type != "object" then "\($at) must be an object"
	else
		((keys - ["id", "step", "does", "skills", "ends_with"])[] | "\($at).\(.) is not a step field"),
		(.id | id_problems($at)),
		(if .step | a_key then empty else "\($at).step must be a step key, <component>/<name>" end),
		(if .does | one_line then empty else "\($at).does must be one line" end),
		(if (.skills | type) == "array" and (.skills | length) > 0 and all(.skills[]; type == "string") then empty else "\($at).skills must list one skill name or more" end),
		(if has("ends_with") then (.ends_with | ends_with_problems($at)) else "\($at).ends_with is missing" end)
	end;

# Problems of a flow.agreed body without its answer, {goal, steps}.
def flow_problems:
	if type != "object" then "the flow must be an object"
	else
		((keys - ["goal", "steps"])[] | "\(.) is not a flow field"),
		(if .goal | one_line then empty else "goal must be one line" end),
		(if (.steps | type) == "array" and (.steps | length) > 0 then
			(.steps[] | node_problems("steps[\(.id // "?")]")),
			(if (.steps | map(.id) | unique | length) != (.steps | length) then "steps hold a repeated id" else empty end)
		 else "steps must be a non-empty array" end)
	end;

# Whether event $e fits ends_with $dw.
def fits($dw): . as $e
	| $e.type == $dw.event and (($dw.match // {}) | to_entries | all(. as $m | $e.body[$m.key] == $m.value));

# The flow named by seq $seq, replayed: {seq, goal, steps, ended}.
# Each step gains status (open, done, skipped), since (the seq after which
# waiting evidence is looked for), floor (the seq after which named evidence
# must come: its latest reopen, or 0) and, when done, event.
def flow_state($seq):
	. as $all
	| ($all[] | select(.seq == $seq and .type == "flow.agreed")) as $agreed
	| reduce ($all[] | select(.seq > $seq and (.type | startswith("flow.")) and .body.flow == $seq)) as $e (
		{seq: $seq, goal: $agreed.body.goal, ended: null,
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
				elif $op.reopen then
					.steps |= map(if .id == $op.reopen then {id, step, does, skills, ends_with} + {status: "open", since: $e.seq, floor: $e.seq} else . end)
				else . end)
		elif $e.type == "flow.step.done" then
			.steps |= map(if .id == $e.body.step then . + {status: "done", event: $e.body.event} else . end)
		elif $e.type == "flow.ended" then .ended = $e.body
		else . end);

# The seqs already used as step evidence, across the effort.
def used_evidence: [.[] | select(.type == "flow.step.done") | .body.event | select(. != null)];

# For flow $f (a flow_state) over the events $all: the open event steps with
# evidence waiting unmarked, as [{id, events: [seq...]}].
def waiting($f): . as $all | ($all | used_evidence) as $used
	| [$f.steps[] | select(.status == "open") as $s
		| [$all[] | select(.seq > $s.since and fits($s.ends_with)) | .seq | select(. as $q | $used | index([$q]) | not)] as $ev
		| select($ev | length > 0) | {id: $s.id, events: $ev}];

# The flow ids (seqs of flow.agreed) not yet ended.
def open_flows: . as $all | [$all[] | select(.type == "flow.agreed") | .seq
	| select(. as $s | [$all[] | select(.type == "flow.ended" and .body.flow == $s)] | length == 0)];
