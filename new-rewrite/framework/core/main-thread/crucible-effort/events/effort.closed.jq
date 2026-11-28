# effort.closed: closes an open or paused effort, with its outcome and the human's words.
([.prior[] | select(.type | startswith("effort.")) | .type] | last) as $state
| (if $state == "effort.opened" or $state == "effort.resumed" or $state == "effort.paused" then empty
	else "the effort is already closed" end),
(.event.body | if .outcome == "done" or .outcome == "dropped" then empty
	else "body.outcome must be done or dropped" end),
(.event.body | if (.words | type) == "string" and (.words | test("\\S")) then empty
	else "body.words must hold the human's words" end),
(.event.body | if has("left_open") | not then empty
	elif (.left_open | type) == "array" and (.left_open | length) > 0
		and all(.left_open[]; type == "string" and test("\\S") and (test("\n") | not)) then empty
	else "body.left_open must be a non-empty list of one-line strings" end),
(.event.body | keys - ["outcome", "words", "left_open"] | .[] | "body.\(.) is not an effort.closed field")
