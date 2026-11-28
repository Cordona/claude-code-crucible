# grill.ended: an ended grill, written once. Its body is the grill, in the
# shape grill-shape.jq sets; its number is not already ended in the effort.
include "grill-shape" {search: "../scripts/lib"};
.event.body as $b
| ($b | grill_problems),
  (if [.prior[] | select(.type == "grill.ended") | .body.number] | index([$b.number]) then
	"grill \($b.number) has already ended" else empty end),
  (if (.event | tojson | length) <= 65536 then empty else "the event is over 65536 bytes" end)
