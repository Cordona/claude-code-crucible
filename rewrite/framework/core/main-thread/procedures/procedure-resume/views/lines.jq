# The fixed lines the main thread shows, one def per line; input: the line's
# fields.
include "line";

# input: {skill: the name of the skill that could not be loaded or run}
def skill_not_installed: not_installed(field("skill"));

# input: {code: grill.sh list's exit code}
def grill_list_failed: "grill.sh list exited \(field("code")): nothing was resumed.";
