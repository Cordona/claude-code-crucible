# The fixed lines the main thread shows, one def per line; input: the line's
# fields.
include "line";

# input: {code: grill.sh list's exit code}
def grill_list_failed: "grill.sh list exited \(field("code")): nothing was resumed.";
