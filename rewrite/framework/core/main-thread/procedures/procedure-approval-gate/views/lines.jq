# The fixed lines the main thread shows, one def per line; input: the line's
# fields.
include "view";

def relay_not_confirmed:
	status_line("blocked"; "Blocked · the plan's relay could not be confirmed:")
	+ " run /hooks or restart Claude Code, then ask me to show the plan again";

def hooks_not_checked: "The gate's hooks could not be checked: flow-code-agent-dispatch is not installed.";
