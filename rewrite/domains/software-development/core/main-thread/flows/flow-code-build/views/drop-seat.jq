# The offer to drop a chosen seat whose part this session can't tell.
include "view";
include "title";
include "line";

# view
#   input:  {seat: the chosen seat}
#   output: the gate's plan, without the gate marker open-gate.sh adds
def view: status_line("decision"; "Decision needed · drop \(field("seat") | seat_display)?");
