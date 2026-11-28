# effort.resumed: puts a paused or closed effort back to open, with the human's words.
([.prior[] | select(.type | startswith("effort.")) | .type] | last) as $state
| (if $state == "effort.paused" or $state == "effort.closed" then empty
	else "the effort is not paused or closed, so it can't be resumed" end),
(.event.body | if (.words | type) == "string" and (.words | test("\\S")) then empty
	else "body.words must hold the human's words" end),
(.event.body | keys - ["words"] | .[] | "body.\(.) is not an effort.resumed field")
