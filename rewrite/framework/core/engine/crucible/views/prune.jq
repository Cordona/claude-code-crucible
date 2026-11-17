# The prune view: the dry run's list, or what --apply removed; input as
# common's prune_view, plus applied (true after --apply).
include "common";

def view:
	if .applied then prune_view("done"; "Prune"; "Removed"; "")
	else prune_view("decision"; "Prune dry run"; "Would remove";
		"Nothing changed; to remove them, add --apply and the folders.")
	end;
