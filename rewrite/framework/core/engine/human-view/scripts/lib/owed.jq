# The owed record's shape and the shown check's text rule, one copy for
# show.sh, its Stop hook and the approval gate's question hook. The record's
# fields are listed on show.sh --help.

# is_owed_record
#   input:  any JSON value
#   output: true when it is a well-formed owed record
def is_owed_record:
	type == "object"
	and ([.id, .name, .skill, .text, .created] | all(type == "string"))
	and (.text != "")
	and (.created | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
	and (.effort == null or (.effort | type) == "string")
	and (.tries | type == "number" and . >= 0 and . == floor)
	and (if .kind == "gate" then (.gate | type) == "string" and (.status == "owed" or .status == "shown")
		elif .kind == "card" then .gate == null and .status == "owed"
		else false end);

# is_stale($now; $stale)
#   input:  an owed record
#   output: true when it was created more than $stale seconds before $now
def is_stale($now; $stale): ($now - (.created | fromdateiso8601)) > $stale;

# normalised
#   input:  text
#   output: the text with CR dropped, trailing spaces and tabs cut from each
#           line, each run of blank lines collapsed to one, and leading and
#           trailing blank lines dropped, so a card is matched however the
#           chat reflows its spacing
def normalised:
	gsub("\r"; "") | split("\n") | map(sub("[ \t]+$"; ""))
	| reduce .[] as $line ([]; if $line == "" and length > 0 and .[-1] == "" then . else . + [$line] end)
	| until(length == 0 or .[0] != ""; .[1:])
	| until(length == 0 or .[-1] != ""; .[:-1])
	| join("\n");

# is_cards_only($cards)
#   input:  normalised text
#   output: true when it is one or more of the normalised texts $cards, in
#           any order, each starting on a line of its own, with or without
#           a blank line before it
def is_cards_only($cards):
	. as $text
	| any($cards[] | select(. != "");
		. as $card
		| $text == $card
			or (($text | startswith($card + "\n"))
				and ($text[($card | length):] | ltrimstr("\n") | ltrimstr("\n") | is_cards_only($cards))));

# card_shown_in($text)
#   input:  an owed record
#   output: true when normalised text $text holds the record's text, normalised
def card_shown_in($text): (.text | normalised) as $card | $text | contains($card);
