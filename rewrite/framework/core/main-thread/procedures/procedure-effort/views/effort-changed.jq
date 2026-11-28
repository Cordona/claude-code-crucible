# The one line shown after an effort's state changed.
include "view";
include "paths";
include "common";

# view
#   input:  {name: the effort's NAME, folder: its absolute folder,
#           items: [{state, started, at}, ...], its effort.* events oldest first}
#   output: `Effort <started|reopened|state> · <name>: <folder>`
def view:
	. as $effort
	| $effort.items[-1] as $newest
	| (if $newest.started then "started" elif $newest.state == "open" then "reopened" else $newest.state end) as $word
	| "\(status_line(if $word == "started" or $word == "reopened" then "done" else $newest.state | state_status end; "Effort \($word) · \($effort.name | code_span):")) \($effort.folder | path_text)";
