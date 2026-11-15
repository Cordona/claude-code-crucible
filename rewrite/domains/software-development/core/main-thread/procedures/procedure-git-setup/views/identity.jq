# The answer to "what's this repo's identity?": who it signs as, or why it
# can't sign.
include "view";

# A value as inline Markdown text: shown, then \ * _ ` escaped.
def markdown_text: shown | gsub("(?<mark>[\\\\*_`])"; "\\\(.mark)");

# view
#   input:  {signs: true, identity: its label, "<name> · <email> · <key>"}
#           or {signs: false, reason: why it can't sign, "" when no check
#           gave one, email: the committer email, or null when unknown}
#   output: one status line
def view:
	if .signs then status_line("done"; "This repo signs as \(.identity | markdown_text) ✅")
	else (if .reason != "" then .reason else "its signing key does not carry \(.email // "the email")" end) as $why
		| status_line("attention"; "This repo's identity can't sign: \($why | markdown_text)")
	end;
