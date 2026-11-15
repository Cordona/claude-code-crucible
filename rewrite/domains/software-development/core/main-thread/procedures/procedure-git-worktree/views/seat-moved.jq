# A seat moved onto another commit for new work.
include "view";
include "title";
include "common";

# view
#   input:  {seat, commit: <sha>, follows: the name it was taken from, ""
#           when none}
#   output: one status line
def view:
	.commit[:short_sha_length] as $short
	| status_line("done"; "\(.seat | seat_display) moved"; if .follows != "" then "\(.follows) (\($short))" else $short end);
