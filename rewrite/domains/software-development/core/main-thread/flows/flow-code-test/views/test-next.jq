# The "what next?" gate after a test report card; the test.committed event's
# path closes it, as every gate's Data line does.
include "view";
include "line";

# view
#   input:  {ask: the gate's question, its first letter lower case, from
#           render-test-next.sh; report: the test.committed event's path}
#   output: the gate's plan, without the gate marker open-gate.sh adds
def view:
	[status_line("decision"; "Decision needed · \(field("ask"))"),
	 data_section([["Test report", field("report")]])]
	| blocks;
