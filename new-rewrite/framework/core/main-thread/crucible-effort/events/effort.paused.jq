# effort.paused: parks an open effort, with the human's words.
([.prior[] | select(.type | startswith("effort.")) | .type] | last) as $state
| (if $state == "effort.opened" or $state == "effort.resumed" then empty
	else "the effort is not open, so it can't be paused" end),
(.event.body | if (.words | type) == "string" and (.words | test("\\S")) then empty
	else "body.words must hold the human's words" end),
(.event.body | keys - ["words"] | .[] | "body.\(.) is not an effort.paused field")
