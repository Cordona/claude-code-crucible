# shellcheck shell=sh
#
# cmd-view.sh — `view <KEY>`: fetch one issue and render it (or pass its raw
#               JSON through on --json).
#
# Sourced by jira.sh — never executed directly. Sets no shell options and
# runs no top-level work beyond its own declarations, so sourcing it always
# returns 0 under `set -e`.

# ---------------------------------------------------------------------------
# view <KEY>
# ---------------------------------------------------------------------------

render_view_human() {
	body_file=$1
	key=$(jq -r '.key // ""' "$body_file" | strip_control_ansi)
	summary=$(jq -r '.fields.summary // ""' "$body_file" | strip_control_ansi)
	status=$(jq -r '.fields.status.name // "N/A"' "$body_file" | strip_control_ansi)
	itype=$(jq -r '.fields.issuetype.name // "N/A"' "$body_file" | strip_control_ansi)
	assignee=$(jq -r '.fields.assignee.displayName // "Unassigned"' "$body_file" | strip_control_ansi)
	printf 'Key:      %s\n' "$key"
	printf 'Summary:  %s\n' "$summary"
	printf 'Status:   %s\n' "$status"
	printf 'Type:     %s\n' "$itype"
	printf 'Assignee: %s\n' "$assignee"
}

cmd_view() {
	# TICKET_KEY presence/shape is validated up front, before any dep/site
	# gate check — see the main dispatch section's validate_command_args().
	load_config_for_ticket_key "$TICKET_KEY"

	path="/rest/api/3/issue/$TICKET_KEY"
	if [ -n "$OPT_FIELDS" ]; then
		resolved_fields=$(resolve_fields_csv "$PROJECT_CONFIG_FILE" "$OPT_FIELDS")
		encoded=$(urlencode "$resolved_fields")
		path="${path}?fields=${encoded}"
	fi
	view_url="https://${CONFIRMED_HOST}${path}"

	jira_curl GET "$view_url"
	handle_http_status "$JIRA_HTTP_CODE" "view $TICKET_KEY"
	require_json_body "view $TICKET_KEY"

	if [ "$OPT_JSON" -eq 1 ]; then
		cat "$JIRA_HTTP_BODY_FILE"
		return 0
	fi
	render_view_human "$JIRA_HTTP_BODY_FILE"
}

# validate_view_args() — `view`'s per-command argument validation, called by
# jira.sh BEFORE any tool/site/credential check so a caller's own typo
# surfaces as a usage error (exit 2) first.
validate_view_args() {
	require_ticket_positional view
	return 0
}
