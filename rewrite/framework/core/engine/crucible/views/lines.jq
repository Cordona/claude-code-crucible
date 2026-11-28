# The fixed lines the main thread shows, one def per line; input: the line's
# fields.
include "line";

def artifact_handoff_missing: "standard-artifact-handoff is missing: install the framework's core engine skills, then ask again.";

# input: {code: crucible.sh's exit code}
def crucible_exited: "crucible.sh exited \(field("code")).";
