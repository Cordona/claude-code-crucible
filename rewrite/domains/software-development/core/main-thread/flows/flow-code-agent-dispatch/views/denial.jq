# The inject hook's deny reason, after its "flow-code-agent-dispatch:" prefix.
# Each problem starts with its KIND word, which the flow routes on.
include "view";

# view
#   input:  {count: every problem, shown: the problems to show, chosen and
#           cut, more: how many are not shown, details: the dispatch.denied
#           event, or null}
#   output: the status line, the Problems section, "+N more", the Data path
def view:
	[status_line("blocked"; "Blocked · the dispatch was denied: \(.count | counted("problem"; "problems"))"),
	 section("Problem"; "Problems"; .shown | map(shown)),
	 (if .more > 0 then "+\(.more) more" else "" end),
	 data_section(if .details == null then [] else [["Denial", .details]] end)]
	| blocks;
