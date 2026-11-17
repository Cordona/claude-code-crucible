# What is mounted in the human's checkout, and how it stands.
include "view";
include "title";
include "common";

def listed: if . == [] then "none" else join(", ") end;

# view
#   input:  mount-status.sh's result (see its --help) and repo: the
#           checkout's folder
#   output: one line
def view:
	if .mounted | not then "Nothing is mounted in \(.repo | shown)."
	else "Mounted in \(.repo | shown): \(.seats | map(.seat) | seat_names)"
		+ "; moved on since: \(.seats | map(select(.stale) | .seat | seat_display) | listed)"
		+ "; cut-from seats with newer work: "
		+ (if .parents_moved == null then "not checked"
			else .parents_moved | map("\(.parent | seat_display) → \(.seat | seat_display)") | listed end)
		+ "; HEAD moved: \(if .head_moved then "yes" else "no" end)"
		+ "; edited: \(if .edited == [] then "none"
			else (.edited[:max_named] | map(shown) | join(", "))
				+ (if (.edited | length) > max_named then " and \((.edited | length) - max_named) more" else "" end) end)."
	end;
