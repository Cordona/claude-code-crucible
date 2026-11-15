# The "what next?" gate, asked once the context is ready.
include "view";

# view
#   input:  {docs: the draft's docs folder, grill: the grill file or "",
#           settled: the grill's settled questions, or null without a grill}
#   output: the gate's plan, without the gate marker open-gate.sh adds
def view:
	. as $gate
	| [status_line("decision"; "Decision needed · the context is ready: what next?"),
	   (if $gate.settled == null or $gate.settled == 0 then "" else section("Settled"; [$gate.settled | counted("decision"; "decisions")]) end),
	   data_section([["Docs", $gate.docs]] + (if $gate.grill == "" then [] else [["Grill", $gate.grill]] end))]
	| blocks;
