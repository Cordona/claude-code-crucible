# Seats' commits that could not be merged; the human says what next.
include "view";
include "title";
include "common";

# view
#   input:  tips-merge.sh's conflict result, {merged: false, conflicts:
#           [<path>...]}, plus seat: the seat whose worktree holds the merge
#           for its builder to resolve, when one does
#   output: one line
def view:
	.conflicts as $files
	| ("tips-merge.sh: the commits conflict in \($files | length) file(s): \($files[:max_named] | join(", "))"
		+ (if ($files | length) > max_named then " and \(($files | length) - max_named) more" else "" end)
		+ (if .seat == null then "; nothing was changed"
		   else "; the merge is left in \(.seat | seat_display)'s worktree for its builder to resolve" end))
	| shown;
