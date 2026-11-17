# The spec's approval gate; the draft's path closes it, as every gate's Data
# line does.
include "view";

# view
#   input:  {goal: the Goal line, points: [one trimmed open point, ...],
#           spec: the draft's absolute path}
#   output: the gate's plan, without the gate marker open-gate.sh adds
def view:
	[status_line("decision"; "Decision needed · approve the spec?"),
	 section("Goal"; [.goal | plain_line]),
	 (if (.points | length) == 0 then section("Open points"; ["none"])
	  else numbered_section("Open points"; .points | map(plain_line)) end),
	 data_section([["Spec", .spec]])]
	| blocks;
