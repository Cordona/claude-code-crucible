# The fixed lines the main thread shows, one def per line; input: the line's
# fields.
include "line";

def builder_not_installed:
	not_installed("code-builder"; "install code-builder.md under ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/agents/");

def git_not_installed: not_installed("git"; "install it");

def test_part_held: "This flow writes no tests, so the test part is not dispatched.";

def doc_change_not_dispatched: "A doc change is not a builder's task, so it is not dispatched.";

# input: {folder: the part's folder}
def not_in_git_repository: "\(field("folder")) is not in a git repository, so that part is not dispatched.";

# input: {tasks: the parts' tasks, joined by " · "}
def parts_side_by_side: "These parts run side by side, each in its own worktree: \(field("tasks"))" | sentence;

# input: {seat}
def conflict_sent: "The builder in \(field("seat")) is resolving the catch-up's conflicts.";
