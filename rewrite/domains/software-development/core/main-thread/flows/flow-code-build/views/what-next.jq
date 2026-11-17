# The "what next?" gate after a build card.
include "view";
include "line";

# view
#   input:  {ask: the gate's question, its first letter lower case, from
#           render-what-next.sh; seat: the build seat}
#   output: the gate's plan, without the gate marker open-gate.sh adds
def view:
	[status_line("decision"; "Decision needed · \(field("ask"))"),
	 data_section([["Seat", field("seat")]])]
	| blocks;
