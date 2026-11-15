# The spec's revision offer.
include "view";

# view
#   input:  {reasons: [one trimmed line, ...]}
#   output: the gate's plan, without the gate marker open-gate.sh adds
def view:
	[status_line("decision"; "Decision needed · revise the spec?"),
	 numbered_section("Why"; .reasons | map(plain_line))]
	| blocks;
