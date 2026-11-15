# The fixed lines of git worktrees, one def per line; input: the line's fields.
include "line";
include "title";

# input: {seat, taken: what the seat would take in, "NAME (short sha)" or the
# short sha}
def in_sync: "\(field("seat") | seat_display) already holds \(field("taken")): nothing to take in.";

# input: {remote, branch}
def pushed: "PUSHED: \(field("remote"))/\(field("branch"))";

# input: {reason: why the commit was made unsigned}
def unsigned: "UNSIGNED: \(field("reason"))";
