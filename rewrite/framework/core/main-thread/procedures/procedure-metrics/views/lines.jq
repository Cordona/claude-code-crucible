# The fixed lines the main thread shows, one def per line; input: the line's
# fields.
include "line";

def effort_not_installed: not_installed("procedure-effort");

def no_effort_found: "No effort found.";

# input: {code: metrics.sh's exit code}
def metrics_stopped: "metrics.sh was stopped (exit \(field("code"))).";
