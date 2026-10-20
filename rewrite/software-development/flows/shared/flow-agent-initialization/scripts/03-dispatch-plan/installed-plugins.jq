# The installed plugins from list-plugins.sh's plugin lines (--arg listing, run
# with jq -n), as {"<name>": {"kind": "tech"|"standard", "label": str}}: the
# form dispatch-plan-validator.jq takes, and the labels technology comes from.
$listing | split("\n") | map(split("\t") | select(length >= 3 and (.[0] == "tech" or .[0] == "standard"))
	| {key: .[1], value: {kind: .[0], label: .[2]}}) | from_entries
