# flow.changed: one change to an open flow, {flow, reason, ops}.
include "flow-replay" {search: "../scripts/lib"};
.event.body as $b
| (.prior | flow_state($b.flow)? // null) as $f
| if $f == null then "flow \($b.flow) is not a flow of this effort"
  elif $f.ended then "flow \($b.flow) has ended"
  else
	((($b | keys) - ["flow", "reason", "ops"])[] | "\(.) is not a flow.changed field"),
	(if $b.reason | one_line then empty else "reason must be one line" end),
	(if ($b.ops | type) == "array" and ($b.ops | length) > 0 then empty else "ops must be a non-empty array" end),
	(reduce ($b.ops[]?) as $op ({f: $f, p: []};
		.f as $s
		| ($s.steps | map(.id)) as $ids
		| if ($op | type) != "object" then .p += ["an op must be an object"]
		  elif $op.add then
			if ($s.ids | index([$op.add.id])) then .p += ["add: id \($op.add.id) is already used"]
			elif ([$op.add | node_problems("add")] | length) > 0 then .p += [$op.add | node_problems("add")]
			elif $op.before and (($ids | index([$op.before])) | not) then .p += ["add: before \($op.before) is not a step"]
			else .f.ids += [$op.add.id] | .f.steps += [$op.add + {status: "open"}] end
		  elif $op.skip then
			if (($s.steps | map(select(.id == $op.skip and .status == "open")) | length) == 0) then .p += ["skip: \($op.skip) is not an open step"] else . end
		  elif $op.move then
			if (($ids | index([$op.move])) | not) or (($ids | index([$op.before])) | not) then .p += ["move: \($op.move) and before \($op.before) must both be steps"] else . end
		  elif $op.reopen then
			if (($s.steps | map(select(.id == $op.reopen and .status != "open")) | length) == 0) then .p += ["reopen: \($op.reopen) is not a done or skipped step"] else . end
		  elif $op.revise then
			if ([$op.revise.done_when | done_when_problems("revise")] | length) > 0 then .p += [$op.revise.done_when | done_when_problems("revise")]
			elif (($op.revise | keys) - ["step", "done_when"]) != [] then .p += ["revise holds only step and done_when"]
			elif $op.revise.step and (($s.steps | map(select(.id == $op.revise.step and .status == "open")) | length) == 0) then .p += ["revise: \($op.revise.step) is not an open step; reopen a done one first"]
			else (if $op.revise.step then .f.steps |= map(if .id == $op.revise.step then .done_when = $op.revise.done_when else . end) else . end) end
		  else .p += ["an op must be add, skip, move, reopen or revise"] end) | .p[])
  end
