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

# input: {seat, worktree: its absolute path}
def report_gave_up: "The developer in \(field("seat")) could not write a valid report; its work stays uncommitted in \(field("worktree")).";

# input: {seat, worktree: its absolute path}
def run_not_committed: "The work in \(field("seat")) ended without a commit; what it changed stays uncommitted in \(field("worktree")); ask me to continue it.";

# input: {state: done or blocked, task: the seat's part}
def checked_earlier: "Checked earlier, \(field("state")): \(field("task"))";
