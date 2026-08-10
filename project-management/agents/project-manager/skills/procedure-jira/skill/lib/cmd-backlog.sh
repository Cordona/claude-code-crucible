# shellcheck shell=sh
#
# cmd-backlog.sh — `backlog <BOARD_ID>`: the board's backlog (the issues
#                  envelope), rendered through the shared issue render.
#
# Sourced by jira.sh — never executed directly. Sets no shell options and
# runs no top-level work beyond its own declarations, so sourcing it always
# returns 0 under `set -e`.

cmd_backlog() {
	# The dispatcher parks the single positional in $TICKET_KEY whatever the
	# command; for `backlog` that value is a numeric BOARD id, already validated
	# by validate_backlog_args(), so name it as one here. board/<id>/backlog is
	# the issues envelope — paginated to full resolution, rendered via the shared
	# issue render (the same shape as a search result).
	backlog_board_id=$TICKET_KEY
	ensure_workdir
	backlog_url="https://${CONFIRMED_HOST}/rest/agile/1.0/board/${backlog_board_id}/backlog"
	backlog_file="$WORKDIR/agile-backlog.jsonl"
	agile_paginate "$backlog_file" "$backlog_url" issues "list backlog for board $backlog_board_id"
	if [ "$OPT_JSON" -eq 1 ]; then
		jq -s '{issues: .}' "$backlog_file"
	else
		render_search_human "$backlog_file" "$AGILE_COLLECTED"
	fi
}

# validate_backlog_args() — `backlog`'s per-command argument validation, called by
# jira.sh BEFORE any tool/site/credential check so a caller's own typo
# surfaces as a usage error (exit 2) first.
validate_backlog_args() {
	[ -n "$TICKET_KEY" ] || { usage >&2; error "backlog requires a numeric board id, e.g.: backlog 826"; exit 2; }
	validate_numeric_id "$TICKET_KEY" || { usage >&2; error "invalid board id (must be numeric): $TICKET_KEY"; exit 2; }
	return 0
}
