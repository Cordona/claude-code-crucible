# The one line open prints once the draft is open; input: {path: the draft's
# absolute path}.
include "view";
include "line";

def view: section("Opened"; [field("path") | path_text]);
