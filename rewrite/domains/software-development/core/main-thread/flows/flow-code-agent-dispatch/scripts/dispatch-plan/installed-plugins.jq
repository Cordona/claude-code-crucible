# The installed plugins from list-plugins.sh's plugin lines (--arg listing, run
# with jq -n), as {"<name>": {"kind": "language"|"framework"|"standard"|"procedure",
# "label": str}}, in listing order: the form dispatch-plan-validator.jq takes,
# and the labels the titles come from.
$listing | split("\n") | map(split("\t") | select(length >= 3 and (.[0] | IN("language", "framework", "standard", "procedure")))
	| {key: .[1], value: {kind: .[0], label: .[2]}}) | from_entries
