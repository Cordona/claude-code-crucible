# shellcheck shell=sh
#
# cmd-children.sh — `children <KEY>`: the issue's children, resolved by driving
#                   the EXISTING search engine with a `parent = "KEY"` clause
#                   rather than duplicating any request/paging/render path.
#
# Sourced by jira.sh — never executed directly. Sets no shell options and
# runs no top-level work beyond its own declarations, so sourcing it always
# returns 0 under `set -e`.

# ---------------------------------------------------------------------------
# children <KEY> — an epic's/parent's children, via the EXISTING search
# engine (never a duplicated request/paging/render path)
# ---------------------------------------------------------------------------

cmd_children() {
	# TICKET_KEY presence/shape is validated up front — see cmd_view's note.
	#
	# `parent = "KEY"` is a BOUNDED query (never unfiltered), so — unlike a
	# raw --jql passthrough, which is the caller's own responsibility — no
	# fallback/guard against an unbounded read is needed here. The key is
	# escaped through jql_quoted() — the SAME JQL-sink control build_jql()
	# itself uses — even though TICKET_KEY is already
	# shape-validated to ^[A-Z][A-Z0-9]+-[0-9]+$ and therefore cannot carry a
	# quote/backslash; escaping it anyway costs nothing and keeps this call
	# site correct even if that upstream guarantee ever changes. Setting
	# $OPT_JQL and calling cmd_search() directly reuses its ENTIRE request
	# build / pagination / render / --json path verbatim (build_jql()'s raw
	# passthrough branch fires since $OPT_JQL is now non-empty) — respecting
	# whatever --fields/--limit/--page-size the caller also gave.
	# shellcheck disable=SC2034  # deliberately handed to cmd_search (cmd-search.sh) through the OPT_JQL global — that reuse IS this command
	OPT_JQL="parent = $(jql_quoted "$TICKET_KEY")"
	cmd_search
}

# validate_children_args() — `children`'s per-command argument validation, called by
# jira.sh BEFORE any tool/site/credential check so a caller's own typo
# surfaces as a usage error (exit 2) first.
validate_children_args() {
	require_ticket_positional children
	return 0
}
