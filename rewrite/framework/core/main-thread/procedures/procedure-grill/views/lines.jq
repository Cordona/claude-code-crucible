# The fixed lines the main thread shows, one def per line; input: the line's
# fields.
include "line";

# input: {reason: the reason in procedure-context's stopped: line}
def work_stopped: ("The work stopped: \(field("reason"))" | sentence) + " What is on disk stays in the effort.";

def offer_not_installed: "The grill offer could not be shown: its renderer is not installed correctly.";

def offer_question_not_read: "The grill offer's question could not be read.";

def offer_not_shown: "The grill offer could not be shown.";
