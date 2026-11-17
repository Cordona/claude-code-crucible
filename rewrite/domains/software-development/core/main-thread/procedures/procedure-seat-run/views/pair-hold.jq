# The pair hold's gate: one agent of a pair left its work uncommitted in the
# worktree both share.
include "view";
include "line";

# view
#   input:  {ask: the gate's question, its first letter lower case, from
#           render-pair-hold.sh; worktree: the shared worktree's path}
#   output: the gate's plan, without the gate marker open-gate.sh adds
def view:
	[status_line("decision"; "Decision needed · \(field("ask"))"),
	 data_section([["Worktree", field("worktree")]])]
	| blocks;
