# The fixed lines of git worktrees, one def per line; input: the line's fields.
include "line";
include "title";
include "view";

# input: {seat, taken: what the seat would take in, "NAME (short sha)" or the
# short sha}
def in_sync: "\(field("seat") | seat_display) already holds \(field("taken")): nothing to take in.";

# input: {remote, branch}
def pushed: "PUSHED: \(field("remote"))/\(field("branch"))";

# input: {reason: why the commit was made unsigned}
def unsigned: "UNSIGNED: \(field("reason"))";

# input: {seat, taken: what the seat would take in, files: the conflicting
# files named for the human, needs: the roles that must resolve them,
# space-separated}
def out_of_scope:
	(field("seat") | seat_display) as $seat
	| (field("needs") | split(" ") | map("the " + .) | join(" and ")) as $roles
	| "**\($seat) did not take \(field("taken")):** \(field("files")) conflict, and \($roles) must resolve them; the merge was cancelled and \($seat) is unchanged."
	| shown;
