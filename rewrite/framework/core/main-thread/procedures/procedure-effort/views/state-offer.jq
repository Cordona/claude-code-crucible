# The state offer: what should happen to the open effort when new work comes
# (new-work), or a suggestion to complete it (done).
include "view";
include "paths";
include "common";

# view
#   input:  {case: "new-work" or "done", name: the effort's NAME,
#           reasons: [one trimmed line, ...]}
#   output: the gate's plan, without the gate marker open-gate.sh adds
def view:
	. as $offer
	| {"new-work": {title: "It seems that you are planning something new.", suggestion: "What should happen to the open effort?", tail: way_out},
	   done: {title: "It looks like \($offer.name | code_span) is done.", suggestion: "You should consider completing it:", tail: ""}}[$offer.case] as $lines
	| [status_line("decision"; $lines.title),
	   "\($lines.suggestion)\n\($offer.reasons | map(plain_line) | bullet_list)",
	   $lines.tail]
	| blocks;
