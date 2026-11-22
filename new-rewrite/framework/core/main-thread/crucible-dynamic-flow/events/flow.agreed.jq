# flow.agreed: a flow the human agreed, {goal, done_when, steps, answer}:
# answer is the seq of the human's accepted answer, used once. Whether it
# accepted this flow is flow-agree.sh's question to the gate's reader.
include "flow-replay" {search: "../scripts/lib"};
.event.body as $b | .prior as $all
| ($b | del(.answer) | flow_problems),
  (if ($b.answer | type) != "number" then "answer must be the seq of the human's answer"
   elif ([$all[] | select(.type == "flow.agreed" and .body.answer == $b.answer)] | length) > 0 then "answer \($b.answer) already agreed another flow"
   else empty end),
  (if (.event | tojson | length) <= 65536 then empty else "the event is over 65536 bytes" end)
