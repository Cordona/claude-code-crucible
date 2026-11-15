# The effort offer, asked before an effort starts; with its own title, the
# grill offer procedure-grill asks.
include "view";
include "paths";
include "common";

# view
#   input:  {title: one trimmed line, open: [each other effort's NAME, once],
#           way_out_shown: true when a state offer just showed the way out,
#           reasons: [one trimmed line, ...]}
#   output: the gate's plan, without the gate marker open-gate.sh adds
def view:
	. as $offer
	| ($offer.open | length) as $open_count
	| [status_line("decision"; "Decision needed · \($offer.title)"),
	   bullet_section("This session already works on"; $offer.open | map(code_span)),
	   (if $open_count == 0 or $offer.way_out_shown then "" else way_out end),
	   section("Why"; $offer.reasons | map(plain_line))]
	| blocks;
