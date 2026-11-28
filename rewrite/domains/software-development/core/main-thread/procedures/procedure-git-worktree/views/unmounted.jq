# A mount taken out of the human's checkout, or forgotten once committed.
include "view";
include "common";

# view
#   input:  unmount.sh's result, {seats: [S...], forgotten: true when the
#           human committed the mount}, and repo: the checkout's folder
#   output: one line
def view:
	if .forgotten then "\(.seats | seat_names) are committed in \(.repo | shown); the mount record is dropped."
	else "Unmounted \(.seats | seat_names) from \(.repo | shown)."
	end;
