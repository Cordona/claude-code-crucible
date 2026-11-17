# The fixed lines the main thread shows, one def per line; input: the line's
# fields.
include "line";

def tester_not_installed:
	not_installed("code-tester"; "install code-tester.md under ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/agents/");

# input: {seat: the build seat}
def no_build_to_test: "\(field("seat")) has no build since its base, so there is nothing to test yet.";

# input: {seat: the build seat}
def bug_sent: "The agent in \(field("seat")) is fixing the bug the tests found.";
