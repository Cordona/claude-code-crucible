# shellcheck shell=sh
#
# cmd-vote.sh — `vote <KEY>`: add, remove (--remove) or list (--list) the
#               caller's vote on the issue.
#
# Sourced by jira.sh — never executed directly. Sets no shell options and
# runs no top-level work beyond its own declarations, so sourcing it always
# returns 0 under `set -e`.

# render_votes_human BODY_FILE — vote count + whether the caller has voted.
render_votes_human() {
	votes_body_file=$1
	vote_count=$(jq -r '.votes // 0' "$votes_body_file")
	has_voted=$(jq -r '.hasVoted // false' "$votes_body_file")
	printf 'Votes: %s\n' "$vote_count"
	printf 'You have voted: %s\n' "$has_voted"
}

cmd_vote() {
	# TICKET_KEY presence/shape, and the --list/--remove mutual exclusivity,
	# are validated up front — see the main dispatch section's per-command
	# validation.
	if [ "$OPT_LIST" -eq 1 ]; then
		votes_url="https://${CONFIRMED_HOST}/rest/api/3/issue/${TICKET_KEY}/votes"
		jira_curl GET "$votes_url"
		handle_http_status "$JIRA_HTTP_CODE" "list votes for $TICKET_KEY"
		require_json_body "list votes for $TICKET_KEY"
		if [ "$OPT_JSON" -eq 1 ]; then
			cat "$JIRA_HTTP_BODY_FILE"
			return 0
		fi
		render_votes_human "$JIRA_HTTP_BODY_FILE"
		return 0
	fi

	if [ "$OPT_REMOVE" -eq 1 ]; then
		remove_vote_url="https://${CONFIRMED_HOST}/rest/api/3/issue/${TICKET_KEY}/votes"
		jira_curl DELETE "$remove_vote_url"
		handle_http_status "$JIRA_HTTP_CODE" "remove vote from $TICKET_KEY"
		# DELETE /votes returns 204 No Content — no require_json_body call.
		if [ "$OPT_JSON" -eq 1 ]; then
			jq -n --arg key "$TICKET_KEY" '{key: $key, voted: false}'
		else
			printf 'JIRA_UNVOTED=%s\n' "$TICKET_KEY"
		fi
		return 0
	fi

	add_vote_url="https://${CONFIRMED_HOST}/rest/api/3/issue/${TICKET_KEY}/votes"
	jira_curl POST "$add_vote_url"
	handle_http_status "$JIRA_HTTP_CODE" "add vote to $TICKET_KEY"
	# POST /votes returns 204 No Content — no require_json_body call.
	if [ "$OPT_JSON" -eq 1 ]; then
		jq -n --arg key "$TICKET_KEY" '{key: $key, voted: true}'
	else
		printf 'JIRA_VOTED=%s\n' "$TICKET_KEY"
	fi
}

# validate_vote_args() — `vote`'s per-command argument validation, called by
# jira.sh BEFORE any tool/site/credential check so a caller's own typo
# surfaces as a usage error (exit 2) first.
validate_vote_args() {
	require_ticket_positional vote
	if [ "$OPT_LIST" -eq 1 ] && [ "$OPT_REMOVE" -eq 1 ]; then
		usage >&2
		error "vote --list and --remove are mutually exclusive"
		exit 2
	fi
	return 0
}
