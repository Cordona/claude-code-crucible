# The live check's gate, once main has shown the human the build working.
include "view";
include "line";

# view
#   input:  {ask: the gate's question, its first letter lower case, from
#           render-live-check.sh; action: what main did, one line; seat: the
#           build seat}
#   output: the gate's plan, without the gate marker open-gate.sh adds
def view:
	[status_line("decision"; "Decision needed · \(field("ask"))"),
	 section("Checked"; [field("action") | plain_line]),
	 data_section([["Seat", field("seat")]])]
	| blocks;
