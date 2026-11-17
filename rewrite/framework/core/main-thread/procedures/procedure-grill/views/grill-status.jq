# The acknowledgement of a question dropped, deferred or reopened.
include "view";

# view
#   input:  {id, to: dropped, deferred or open, reason}
#   output: `<Dropped|Deferred|Reopened> · <id>: <reason>`
def view:
	{dropped: "Dropped", deferred: "Deferred", open: "Reopened"}[.to] as $title
	| "\(status_line("done"; "\($title) · \(.id):")) \(.reason)";
