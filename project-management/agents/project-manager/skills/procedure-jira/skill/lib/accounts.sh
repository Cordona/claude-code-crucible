# shellcheck shell=sh
#
# accounts.sh — the accountId resolver: "@me" -> GET /myself, anything else
#               (an email/username) -> GET /user/search.
#
# assignee/developer/watcher values are NEVER sent to Jira as raw
# email/username strings — they are resolved to an opaque accountId here first,
# by every caller, on both the READ (search --assignee) and WRITE paths.
#
# Sourced by jira.sh — never executed directly. Sets no shell options and
# runs no top-level work beyond its own declarations, so sourcing it always
# returns 0 under `set -e`.

# ---------------------------------------------------------------------------
# accountId resolver
# ---------------------------------------------------------------------------

# resolve_account_id VALUE -> prints the resolved accountId. VALUE "@me"
# (the oracle's own convention for a direct field value, distinct from the
# JQL-only "me" shortcut below) resolves via GET /myself; anything else
# resolves via GET /user/search?query=VALUE. Exits 1 if no user is found.
resolve_account_id() {
	rai_value=$1
	if [ "$rai_value" = "@me" ]; then
		rai_url="https://${CONFIRMED_HOST}/rest/api/3/myself"
		jira_curl GET "$rai_url"
		handle_http_status "$JIRA_HTTP_CODE" "resolve @me via /myself"
		require_json_body "resolve @me via /myself"
		rai_account_id=$(jq -r '.accountId // empty' "$JIRA_HTTP_BODY_FILE")
		[ -n "$rai_account_id" ] || { error "GET /myself returned no accountId"; exit 1; }
		printf '%s' "$rai_account_id"
		return 0
	fi

	rai_encoded=$(urlencode "$rai_value")
	rai_url="https://${CONFIRMED_HOST}/rest/api/3/user/search?query=${rai_encoded}"
	jira_curl GET "$rai_url"
	handle_http_status "$JIRA_HTTP_CODE" "resolve accountId for '$rai_value' via /user/search"
	require_json_body "resolve accountId for '$rai_value' via /user/search"
	rai_account_id=$(jq -r '.[0].accountId // empty' "$JIRA_HTTP_BODY_FILE")
	[ -n "$rai_account_id" ] || { error "no Jira user found for '$rai_value'"; exit 1; }
	printf '%s' "$rai_account_id"
}
