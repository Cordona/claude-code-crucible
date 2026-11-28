# flow.step.done: one step of an open flow done, {flow, step, event}: the
# event that ends the step, checked here.
include "flow-replay" {search: "../scripts/lib"};
.event.body as $b
| .prior as $all
| ($all | flow_state($b.flow)? // null) as $f
| ((($b | keys) - ["flow", "step", "event"])[] | "\(.) is not a flow.step.done field"),
  (if $f == null then "flow \($b.flow) is not a flow of this effort"
   elif $f.ended then "flow \($b.flow) has ended"
   else ($f.steps | map(select(.id == $b.step)) | first) as $s
	| ($all | map(select(.seq == $b.event)) | first) as $e
	| if $s == null then "step \($b.step) is not a step of flow \($b.flow)"
	  elif $s.status != "open" then "step \($b.step) is \($s.status), not open"
	  elif $e == null then "event \($b.event) is not in this effort"
	  elif ($e | fits($s.ends_with) | not) then "event \($b.event) is not a \($s.ends_with.event)\(if $s.ends_with.match then " matching \($s.ends_with.match | tojson)" else "" end)"
	  elif $e.seq <= $s.floor then "event \($b.event) is older than the step's reopen"
	  elif ($all | used_evidence | index([$b.event])) then "event \($b.event) is already evidence for another step"
	  else empty end
   end)
