# The acknowledgement of the answers one reply gave.
include "view";

# The new answers: one on the title's line, two or more each on its own line
# after a hard break; "" for none.
def recorded:
	if length == 0 then ""
	elif length == 1 then "\(status_line("done"; "Recorded:")) \(.[0].id): \(.[0].text)"
	else "\(status_line("done"; "Recorded"))  \n" + (map("\(.id): \(.text)") | join("  \n")) end;

def changed: "\(status_line("done"; "Changed · \(.id):")) \(.text) (was \(.was): \(.reason))";

# view
#   input:  {recorded: [{id, text}, ...],
#           changed: [{id, text, was: the answer it replaces, reason}, ...],
#           reopened: [id, ...], the settled children sent back to open}
#   output: `Recorded`, one `Changed · <id>` per change and `Back to open`,
#           each block only when it holds anything
def view:
	[(.recorded | recorded),
	 (.changed[] | changed),
	 (if (.reopened | length) > 0 then "Back to open: \(.reopened | join(", "))" else "" end)]
	| blocks;
