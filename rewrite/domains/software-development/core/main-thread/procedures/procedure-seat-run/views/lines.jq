# The fixed lines of seat runs, one def per line; input: the line's fields.
include "line";

# input: {seat, worktree: its absolute path}
def report_gave_up: "The developer in \(field("seat")) could not write a valid report; its work stays uncommitted in \(field("worktree")).";

# input: {seat, worktree: its absolute path}
def run_not_committed: "The work in \(field("seat")) ended without a commit; what it changed stays uncommitted in \(field("worktree")); ask me to continue it.";

# input: {state: done or blocked, task: the seat's part}
def checked_earlier: "Checked earlier, \(field("state")): \(field("task"))";
