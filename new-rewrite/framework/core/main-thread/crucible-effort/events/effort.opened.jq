# effort.opened: the effort's first event, naming it.
if (.prior | length) > 0 then "effort.opened must be the effort's first event" else empty end,
(.event.body | if (.name | type) == "string" and (.name | test("\\S")) then empty
	else "body.name must be a non-empty string" end),
(.event.body | keys - ["name"] | .[] | "body.\(.) is not an effort.opened field")
