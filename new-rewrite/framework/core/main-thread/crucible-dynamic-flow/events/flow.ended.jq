# flow.ended: an open flow ended, done with its own evidence, or dropped.
include "flow-replay" {search: "../scripts/lib"};
.event.body as $b
| .prior as $all
| ($all | flow_state($b.flow)? // null) as $f
| if $f == null then "flow \($b.flow) is not a flow of this effort"
  elif $f.ended then "flow \($b.flow) has already ended"
  elif $b.outcome == "dropped" then (if $b.words | one_line then empty else "a dropped flow needs the human's words" end)
  elif $b.outcome != "done" then "outcome must be done or dropped"
  else
	([$f.steps[] | select(.status == "open") | .id] as $open
		| if $open != [] then "steps \($open | map(tostring) | join(", ")) are still open" else empty end),
	(if ($f.done_when | has("event")) then
		($all | map(select(.seq == $b.event)) | first) as $e
		| if $b.kind != "event" then "the flow is done by an event"
		  elif $e == null or ($e | fits($f.done_when) | not) or $e.seq <= $f.seq then "the flow's evidence must be a \($f.done_when.event) after the flow started"
		  else empty end
	 else
		(if $b.kind != (if $f.done_when.by == "human" then "human" else "main" end) then "the flow is checked by \($f.done_when.by // "main")" else empty end),
		(if $b.evidence | one_line then empty else "the flow needs one line of evidence that its goal is met" end)
	 end)
  end
