# A seat that took a commit into its branch with a clean merge.
include "view";
include "title";
include "common";

# view
#   input:  {seat, label: what the commit is for the human, "" when none,
#           with_short: the commit's short sha, merge_short: the merge's short
#           sha, new: false when the seat had nothing of its own}
#   output: one status line
def view:
	(if .label != "" then "\(.label) (\(.with_short))" else .with_short end) as $taken
	| status_line("done"; "\(.seat | seat_display) caught up";
		if .new then "now also holds \($taken), merged at \(.merge_short)" else "now holds \($taken) as it is" end);
