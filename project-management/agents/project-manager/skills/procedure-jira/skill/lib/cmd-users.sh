# shellcheck shell=sh
#
# cmd-users.sh — `users --query STR`: look up Jira users (GET
#                /rest/api/3/user/search) and list each one's accountId, so a
#                caller can find the id a user-picker field, a JQL clause or a
#                mention needs without guessing it.
#
# A READ, and deliberately NOT resolve_account_id: that resolver answers "which
# ONE user is this" and fails on anything but a unique exact match, while this
# command answers "who matches" and lists every hit. It reuses the resolver's
# page cap (USER_SEARCH_MAX_RESULTS, accounts.sh) as its default --limit, so
# the two lookups of the same endpoint ask for the same size of page. The
# result is one page, never walked: /user/search is a fuzzy substring match,
# and a query that saturates the page is better narrowed than paged through.
#
# Sourced by jira.sh — never executed directly. Sets no shell options and
# runs no top-level work beyond its own declarations, so sourcing it always
# returns 0 under `set -e`.

cmd_users() {
	users_limit=${OPT_LIMIT:-$USER_SEARCH_MAX_RESULTS}
	users_url="https://${CONFIRMED_HOST}/rest/api/3/user/search?query=$(urlencode "$OPT_QUERY")&maxResults=${users_limit}"
	jira_curl GET "$users_url"
	handle_http_status "$JIRA_HTTP_CODE" "search users"
	require_json_body "search users"
	if ! jq -e 'type == "array"' "$JIRA_HTTP_BODY_FILE" >/dev/null; then
		error "search users failed: expected a JSON array of users"
		exit 1
	fi

	if [ "$OPT_JSON" -eq 1 ]; then
		cat "$JIRA_HTTP_BODY_FILE"
		return 0
	fi
	render_users_human "$JIRA_HTTP_BODY_FILE" "$users_limit"
}

# render_users_human BODY_FILE LIMIT — one line per user. ONE jq pass renders
# every row (rather than a jq fork per field per user), with every line-break
# codepoint inside a value folded to a space (JQ_ONE_LINE_DEF, runtime.sh) so a
# crafted display name can never forge a row, and the whole stream then goes
# through strip_control_ansi like every other human render of API text.
#
# The closing caveat prints on EVERY non-empty result, not only a full page:
# per the endpoint's own REST API description, /user/search takes the users in
# the startAt/maxResults range FIRST and only then keeps the ones that match,
# so it "usually returns fewer users than specified in maxResults" — a page
# shorter than LIMIT does not prove the match set was exhausted.
render_users_human() {
	ruh_body_file=$1
	ruh_limit=$2
	ruh_count=$(jq 'length' "$ruh_body_file")
	if [ "$ruh_count" -eq 0 ]; then
		printf 'No users found for query: %s\n' "$(one_line_display "$OPT_QUERY")"
		return 0
	fi
	printf '%s user(s):\n\n' "$ruh_count"
	jq -r "$JQ_ONE_LINE_DEF"'.[] | objects
		| [(.accountId // ""), (.displayName // ""), (if has("active") then (.active | tostring) else "unknown" end), (.accountType // "unknown")]
		| map(one_line)
		| "  \(.[0])  \(.[1])  (active: \(.[2]), type: \(.[3]))"' "$ruh_body_file" \
		| strip_control_ansi
	printf '\n(one page of at most %s rows: /user/search filters its page after fetching, so fewer rows than that do not prove there are no more matches — narrow --query to be sure)\n' "$ruh_limit"
}

# validate_users_args() — `users`'s per-command argument validation, called by
# jira.sh BEFORE any tool/site/credential check so a caller's own typo
# surfaces as a usage error (exit 2) first.
validate_users_args() {
	if [ -n "$TICKET_KEY" ]; then
		usage >&2
		error "users takes no positional argument, got: $TICKET_KEY (use --query)"
		exit 2
	fi
	[ -n "$OPT_QUERY" ] || { usage >&2; error "users requires --query STR (a name or email fragment)"; exit 2; }
	return 0
}
