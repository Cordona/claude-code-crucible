# Seats' work mounted in the human's checkout.
include "view";
include "common";

# view
#   input:  mount.sh's result, {seats: [{seat}...], paths: N, left_alone: M},
#           and repo: the checkout's folder
#   output: one line
def view:
	"Mounted \(.seats | map(.seat) | seat_names) in \(.repo | shown): \(.paths) files;"
	+ " your other \(.left_alone) changed files are untouched.";
