# The fixed lines the main thread shows, one def per line; input: the line's
# fields.
include "line";

def what_next_not_shown: "The \"what next?\" question could not be shown; the flow goes on to its own plan.";

def tracker_links_not_read: "Tracker links are not read: read-link.sh could not run.";

# input: {link: the link, or its place n; code: read-link.sh's exit code}
def link_not_read: "Link \(field("link")) was not read (read-link.sh exit \(field("code"))).";

def spec_needed: "Every dispatch needs a spec, and a small one is enough.";

# input: {option: the approval question's approve option}
def pick_approve_option: "To approve the spec, pick \"\(field("option"))\" when the gate asks.";

def context_unchanged: "The context stays as it was.";
