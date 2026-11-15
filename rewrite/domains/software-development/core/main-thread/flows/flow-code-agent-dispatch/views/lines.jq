# The fixed lines of code agent dispatch, one def per line; input: the line's fields.
include "view";
include "line";

# input: {name: the language as the calling flow handed it in}
def no_language_plugin:
	status_line("blocked"; "Stopped · no installed plugin for \(field("name") | shown):") + " this part was not dispatched.";

def ask_tool_missing: "AskUserQuestion is not available, so no plan can be approved and nothing is dispatched.";

def confirm_hooks_loaded: "Confirm under /hooks that the hook entries step 1 lists are loaded, then ask me again.";
