# flow.ended: an open flow ended, done once every step is done or skipped,
# or dropped with the human's words: {flow, outcome, words?}.
include "flow-replay" {search: "../scripts/lib"};
.event.body as $b
| .prior as $all
| ($all | flow_state($b.flow)? // null) as $f
| if $f == null then "flow \($b.flow) is not a flow of this effort"
  elif $f.ended then "flow \($b.flow) has already ended"
  elif $b.outcome == "dropped" then
	((($b | keys) - ["flow", "outcome", "words"])[] | "\(.) is not a flow.ended field"),
	(if $b.words | one_line then empty else "a dropped flow needs the human's words" end)
  elif $b.outcome != "done" then "outcome must be done or dropped"
  else
	((($b | keys) - ["flow", "outcome"])[] | "\(.) is not a field of a done flow.ended"),
	([$f.steps[] | select(.status == "open") | .id] as $open
		| if ($open | length) == 1 then "step \($open[0]) is still open"
		  elif $open != [] then "steps \($open | map(tostring) | join(", ")) are still open" else empty end)
  end
