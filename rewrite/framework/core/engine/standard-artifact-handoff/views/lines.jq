# The fixed lines the main thread shows, one def per line; input: the line's
# fields.
include "view";
include "line";

# input: {path: the artifact's full absolute path}
def show_text_offer: "Showing it in the chat is not efficient; it is at \(field("path") | path_text). Show it here anyway?";
