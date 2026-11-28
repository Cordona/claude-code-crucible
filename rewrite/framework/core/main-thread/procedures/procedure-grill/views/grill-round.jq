# One round of a grill's questions, for the human to answer in one reply.
include "view";

# One question of a round: its number, then its recommendation and reason
# on lines indented under its text, after hard breaks.
def round_item($delimiter):
	"\(.number)\($delimiter) " as $marker
	| (" " * ($marker | length)) as $indent
	| "\($marker)\(.text | plain_line)  \n\($indent)Recommendation: \(.recommendation)  \n\($indent)Reason: \(.reason)";

# The questions numbered by their ids. Markdown numbers a list from its
# first item on, so each run of consecutive numbers is a list of its own: a
# blank line and the other delimiter (. or )) start the next, numbered from
# its first.
def round_list:
	sort_by(.number)
	| reduce .[] as $question ([];
		if length > 0 and .[length - 1][-1].number + 1 == $question.number
		then .[length - 1] += [$question] else . + [[$question]] end)
	| to_entries
	| map((if .key % 2 == 0 then "." else ")" end) as $delimiter | .value | map(round_item($delimiter)) | join("\n"))
	| join("\n\n");

# view
#   input:  {round: the round's number,
#           questions: [{number: the id's number, text, recommendation, reason}, ...]}
#   output: the `Decision needed · grill round <n>` title, the numbered
#           questions and, in round 1, how to stop the grill
def view:
	[status_line("decision"; "Decision needed · grill round \(.round)"),
	 (.questions | round_list),
	 (if .round == 1 then "Say \"end the grill\" at any point to stop." else "" end)]
	| blocks;
