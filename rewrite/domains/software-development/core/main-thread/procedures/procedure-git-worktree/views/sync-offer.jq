# The offer to merge into a seat the newer work of the seats it was cut from.
include "view";
include "title";
include "common";

# view
#   input:  chain.sh's line for the seat, {seat, parents: [{seat, in_seat}...]}
#   output: the gate's plan, without the gate marker open-gate.sh adds
def view:
	(.seat | seat_display) as $seat
	| [.parents[] | select(.in_seat | not) | .seat] as $newer
	| [status_line("decision"; "Decision needed · sync \($seat)?"),
	   "\($seat) was cut from \($newer | seat_names), which \(if ($newer | length) == 1 then "has" else "have" end) newer work."]
	| blocks;
