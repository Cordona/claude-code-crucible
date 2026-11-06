# The context's link rule, the one definition agent-context-validator.jq and
# procedure-read-trackers' read-link.sh both apply.
# Include it with: include "agent-context-url"; and -L this folder, or a
# search path relative to the including file, such as {search: "./"}.

# The whole link can go into a shell command line: a host of letters, digits,
# dots and hyphens with an optional port, then a path, query and fragment of
# only these characters, none of which quotes, substitutes, redirects, splits
# or chains in a shell (any other character goes in percent-encoded).
def http_url: type == "string" and test("^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?([/?#][A-Za-z0-9._~/?#=%:+,@-]*)?$"; "i");
