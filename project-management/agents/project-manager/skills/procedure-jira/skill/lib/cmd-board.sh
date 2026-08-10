# shellcheck shell=sh
#
# cmd-board.sh — `board <BOARD_ID>`: one board's configuration (a SINGLE object,
#                not paginated), rendered as its id/name/type plus its columns.
#
# Sourced by jira.sh — never executed directly. Sets no shell options and
# runs no top-level work beyond its own declarations, so sourcing it always
# returns 0 under `set -e`.

# render_board_config_human FILE — the SINGLE board-configuration object: its
# id/name/type plus one line per column. Columns are walked with the same
# per-object jq extraction (a column NAME is author-controlled text).
render_board_config_human() {
	cfg_file=$1
	cfg_id=$(jq -r '.id // ""' "$cfg_file" | strip_control_ansi)
	cfg_name=$(jq -r '.name // ""' "$cfg_file" | strip_control_ansi)
	cfg_type=$(jq -r '.type // "N/A"' "$cfg_file" | strip_control_ansi)
	printf 'Board %s: %s (type %s)\n' "$cfg_id" "$cfg_name" "$cfg_type"
	cfg_col_count=$(jq '(.columnConfig.columns // []) | length' "$cfg_file")
	if [ "$cfg_col_count" -eq 0 ]; then
		printf 'Columns: (none)\n'
		return 0
	fi
	printf 'Columns:\n'
	jq -c '.columnConfig.columns[]?' "$cfg_file" | while IFS= read -r cfg_col_line; do
		cfg_col_name=$(printf '%s' "$cfg_col_line" | jq -r '.name // ""' | strip_control_ansi)
		printf '  - %s\n' "$cfg_col_name"
	done
}

cmd_board() {
	# The dispatcher parks the single positional in $TICKET_KEY whatever the
	# command; for `board` that value is a numeric BOARD id, already validated by
	# validate_board_args(), so name it as one here. It is the only URL path
	# segment. board/<id>/configuration is a SINGLE object (not paginated), so
	# --json passes the raw body straight through.
	board_id=$TICKET_KEY
	ensure_workdir
	board_url="https://${CONFIRMED_HOST}/rest/agile/1.0/board/${board_id}/configuration"
	jira_curl GET "$board_url"
	handle_http_status "$JIRA_HTTP_CODE" "get configuration for board $board_id"
	require_json_body "get configuration for board $board_id"
	if [ "$OPT_JSON" -eq 1 ]; then
		cat "$JIRA_HTTP_BODY_FILE"
		return 0
	fi
	render_board_config_human "$JIRA_HTTP_BODY_FILE"
}

# validate_board_args() — `board`'s per-command argument validation, called by
# jira.sh BEFORE any tool/site/credential check so a caller's own typo
# surfaces as a usage error (exit 2) first.
validate_board_args() {
	[ -n "$TICKET_KEY" ] || { usage >&2; error "board requires a numeric board id, e.g.: board 826"; exit 2; }
	validate_numeric_id "$TICKET_KEY" || { usage >&2; error "invalid board id (must be numeric): $TICKET_KEY"; exit 2; }
	return 0
}
