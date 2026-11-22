# The context's link rule: an http(s) URL whose characters are all safe on a
# shell command line. Used by context-add.sh and the context.cut rule.
def safe_link:
	type == "string"
	and test("^[Hh][Tt][Tt][Pp][Ss]?://[A-Za-z0-9.-]+(:[0-9]+)?([/?#][A-Za-z0-9._~/?#=%:+,@-]*)?$");
