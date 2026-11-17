# The offer to remount a mounted seat whose sync merged newer work into it.
include "view";
include "title";
include "line";

# view
#   input:  {seat: the synced seat, repo: the checkout it is mounted in}
#   output: the gate's plan, without the gate marker open-gate.sh adds
def view:
	(field("seat") | seat_display) as $seat
	| [status_line("decision"; "Decision needed · remount \($seat)?"),
	   "\($seat) is mounted in \(field("repo") | shown) without its synced work."]
	| blocks;
