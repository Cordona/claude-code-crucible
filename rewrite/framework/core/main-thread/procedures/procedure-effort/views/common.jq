# The defs this skill's cards share.

def way_out: "A new session or /clear keeps each effort clean.";

# Open and completed need nothing from the human; paused and dropped leave
# the effort waiting on them.
def state_status: {open: "done", completed: "done", paused: "attention", dropped: "attention"}[.];
