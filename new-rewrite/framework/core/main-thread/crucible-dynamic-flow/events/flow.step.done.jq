# flow.step.done: one step of an open flow done, with its checked evidence.
include "flow-replay" {search: "../scripts/lib"};
.event.body as $b
| .prior as $all
| ($all | flow_state($b.flow)? // null) as $f
| if $f == null then "flow \($b.flow) is not a flow of this effort"
  elif $f.ended then "flow \($b.flow) has ended"
  else ($f.steps | map(select(.id == $b.step)) | first) as $s
	| if $s == null then "step \($b.step) is not a step of flow \($b.flow)"
	  elif $s.status != "open" then "step \($b.step) is \($s.status), not open"
	  elif ($s.done_when | has("event")) then
		if $b.kind != "event" then "step \($b.step) is done by an event"
		else ($all | map(select(.seq == $b.event)) | first) as $e
			| if $e == null then "event \($b.event) is not in this effort"
			  elif ($e | fits($s.done_when) | not) then "event \($b.event) is not a \($s.done_when.event)\(if $s.done_when.match then " matching \($s.done_when.match | tojson)" else "" end)"
			  elif $e.seq <= $s.since then "event \($b.event) is older than the step's start or reopen"
			  elif ($all | used_evidence | index([$b.event])) then "event \($b.event) is already evidence for another step"
			  else empty end
		end
	  else
		(if $b.kind != (if $s.done_when.by == "human" then "human" else "main" end) then "step \($b.step) is checked by \($s.done_when.by // "main")" else empty end),
		(if $b.evidence | one_line then empty else "step \($b.step) needs one line of evidence" end)
	  end
  end
