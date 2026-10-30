# shellcheck shell=sh
#
# cmd-workflow.sh — `workflow <KEY>`: the issue's current status/type plus every
#                   transition currently available on it — id, name, target
#                   status, whether it has a screen, and the resolutions it
#                   accepts (--json: the raw ?expand=transitions.fields body).
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

	# ONE jq pass renders every row (rather than a jq fork per field per
	# transition); every line-break codepoint inside an API value folds to a
	# space (JQ_ONE_LINE_DEF, runtime.sh) so a crafted name can never forge a
	# row, then strip_control_ansi runs over the lot.
	# The transition NAME and its TARGET are both shown because they differ in
	# real workflows ("Done" can lead to "TBD TO PREPROD"), and two transitions
	# can share a target — the id is what `transition --transition-id` takes.
	printf 'Available transitions:\n'
	jq -r "$JQ_ONE_LINE_DEF"'.transitions[] | objects
		| [(.id // "" | tostring), (.name // ""), (.to.name // ""),
		   (if .hasScreen == true then "yes" elif .hasScreen == false then "no" else "unknown" end),
		   ((.fields.resolution.allowedValues // []) | map(objects | .name // empty) | join(", ")),
		   (if (.fields.resolution // null) == null then "no" else "yes" end)]
		| map(one_line)
		| "  -> \(.[2]) (id \(.[0]), transition \"\(.[1])\", screen: \(.[3]))"
		  + (if .[5] == "no" then ""
		     elif .[4] == "" then "\n       resolution: settable"
		     else "\n       resolution: \(.[4])" end)' "$transitions_file" \
		| strip_control_ansi
}

cmd_workflow() {
	# TICKET_KEY presence/shape is validated up front — see cmd_view's note.
	fetch_issue_transitions "$TICKET_KEY"
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

# fetch_issue_transitions TICKET_KEY — GET the transitions available on the
# issue RIGHT NOW, with ?expand=transitions.fields so each carries its screen
# fields (fields.resolution + allowedValues when the screen can set one). Leaves
# the body in $JIRA_HTTP_BODY_FILE. Shared with cmd-transition.sh, whose
# --status finder, --transition-id finder and --resolution check all read this
# same response — one request shape for the read and the write path.
fetch_issue_transitions() {
	fit_url="https://${CONFIRMED_HOST}/rest/api/3/issue/${1}/transitions?expand=transitions.fields"
	jira_curl GET "$fit_url"
	handle_http_status "$JIRA_HTTP_CODE" "fetch transitions for $1"
	require_json_body "fetch transitions for $1"
}

# validate_workflow_args() — `workflow`'s per-command argument validation, called by
# jira.sh BEFORE any curl/site/credential check so a caller's own typo
# surfaces as a usage error (exit 2) first.
validate_workflow_args() {
	require_ticket_positional workflow
	return 0
}
