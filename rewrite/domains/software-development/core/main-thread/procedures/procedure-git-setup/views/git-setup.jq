# The git setup gate, asked once per effort before its first plan.
include "view";

# view
#   input:  {identities: how many identities the plan offers,
#           origin: "yes" (the repo has an origin remote), "no" (it has none)
#           or "none" (no repository)}
#   output: the gate's plan, without the gate marker open-gate.sh adds
def view:
	. as $gate
	| [status_line("decision"; "Decision needed · git setup for this effort's agents"),
	   (if $gate.identities > 0 then "Pick the identity that signs this effort's agents' commits."
	    else "This machine has no GPG or SSH signing key." end),
	   (if $gate.origin == "yes" then ""
	    elif $gate.origin == "no" then "This repo has no origin remote, so auto-push stays off."
	    else "No repository here, so auto-push stays off." end)]
	| blocks;
