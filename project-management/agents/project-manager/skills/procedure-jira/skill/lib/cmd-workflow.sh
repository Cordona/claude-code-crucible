# shellcheck shell=sh
#
# cmd-workflow.sh — `workflow <KEY>`: the issue's current status/type plus every
#                   transition currently available on it.
#
# Sourced by jira.sh — never executed directly. Sets no shell options and
# runs no top-level work beyond its own declarations, so sourcing it always
# returns 0 under `set -e`.

# ---------------------------------------------------------------------------
# workflow <KEY>
# ---------------------------------------------------------------------------

render_workflow_human() {
	key=$1
	status_file=$2
	transitions_file=$3

	current_status=$(jq -r '.fields.status.name // "N/A"' "$status_file" | strip_control_ansi)
	issue_type=$(jq -r '.fields.issuetype.name // "N/A"' "$status_file" | strip_control_ansi)
	printf 'Ticket: %s\n' "$key"
	printf 'Type:   %s\n' "$issue_type"
	printf 'Status: %s\n\n' "$current_status"

	count=$(jq '.transitions | length' "$transitions_file")
	if [ "$count" -eq 0 ]; then
		printf 'No transitions available (ticket may be in a final state).\n'
		return 0
	fi

	printf 'Available transitions:\n'
	jq -r '.transitions[] | "\(.id)\t\(.to.name)"' "$transitions_file" | while IFS="$(printf '\t')" read -r tid tname; do
		clean_id=$(printf '%s' "$tid" | strip_control_ansi)
		clean_name=$(printf '%s' "$tname" | strip_control_ansi)
		printf '  -> %s (id %s)\n' "$clean_name" "$clean_id"
	done
}

cmd_workflow() {
	# TICKET_KEY presence/shape is validated up front — see cmd_view's note.
	trans_url="https://${CONFIRMED_HOST}/rest/api/3/issue/${TICKET_KEY}/transitions"
	jira_curl GET "$trans_url"
	handle_http_status "$JIRA_HTTP_CODE" "fetch transitions for $TICKET_KEY"
	require_json_body "fetch transitions for $TICKET_KEY"
	transitions_body=$JIRA_HTTP_BODY_FILE

	if [ "$OPT_JSON" -eq 1 ]; then
		cat "$transitions_body"
		return 0
	fi

	status_url="https://${CONFIRMED_HOST}/rest/api/3/issue/${TICKET_KEY}?fields=status,issuetype"
	jira_curl GET "$status_url"
	handle_http_status "$JIRA_HTTP_CODE" "fetch status for $TICKET_KEY"
	require_json_body "fetch status for $TICKET_KEY"

	render_workflow_human "$TICKET_KEY" "$JIRA_HTTP_BODY_FILE" "$transitions_body"
}

# validate_workflow_args() — `workflow`'s per-command argument validation, called by
# jira.sh BEFORE any tool/site/credential check so a caller's own typo
# surfaces as a usage error (exit 2) first.
validate_workflow_args() {
	require_ticket_positional workflow
	return 0
}
