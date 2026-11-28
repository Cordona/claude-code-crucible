# Where a new seat starts from, said when its base is taken.
include "title";
include "common";

# view
#   input:  {seat, base: <sha>, base_seats: [S...] ([] when independent),
#           snapshot: true when the base is a snapshot of the checkout}
#   output: one line
def view:
	"\(.seat | seat_display): Starts from \(if .base_seats != [] then .base_seats | seat_names
		elif .snapshot then "your checkout with your uncommitted changes" else "your checkout" end)"
	+ " (\(.base[:short_sha_length])).";
