# An effort's state and its history, shown when the human asks where it stands.
include "view";
include "paths";
include "common";

# view
#   input:  {name: the effort's NAME, folder: its absolute folder,
#           items: [{state, from?, at}, ...], its effort.* events oldest first}
#   output: the status line, the History section and the folder's bare path
def view:
	. as $effort
	| $effort.items[-1].state as $state
	| [status_line($state | state_status; "Effort · \($effort.name | code_span)"; $state),
	   section("History"; $effort.items | map("\(.state) · \(.at[0:10]) \(.at[11:16]) UTC")),
	   ($effort.folder | path_text)]
	| blocks;
