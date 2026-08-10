# shellcheck shell=sh
#
# cmd-watch.sh — `watch <KEY>`: add, remove (--remove) or list (--list) the
#                issue's watchers (POST/DELETE/GET
#                /rest/api/3/issue/<KEY>/watchers).
#
# The account defaults to @me and is ALWAYS resolved to an accountId first —
# the same resolver create/update's --assignee uses.
#
# Sourced by jira.sh — never executed directly. Sets no shell options and
# runs no top-level work beyond its own declarations, so sourcing it always
# returns 0 under `set -e`.

# render_watchers_human BODY_FILE — watch count + each watcher's display name.
render_watchers_human() {
	watchers_body_file=$1
	watcher_count=$(jq -r '.watchCount // 0' "$watchers_body_file")
	printf 'Watchers: %s\n' "$watcher_count"
	jq -r '.watchers[]?.displayName // "Unknown"' "$watchers_body_file" | while IFS= read -r watcher_name; do
		clean_watcher_name=$(printf '%s' "$watcher_name" | strip_control_ansi)
		printf '  - %s\n' "$clean_watcher_name"
	done
}

cmd_watch() {
	# TICKET_KEY presence/shape, and the --list/--remove/--account
	# combinations, are validated up front — see the main dispatch section's
	# per-command validation.
	#
	# ensure_workdir runs FIRST, unconditionally — the add/remove branches
	# below reach resolve_account_id() from INSIDE a `$(...)` command
	# substitution, which is a SUBSHELL (the same WORKDIR-loss class already
	# fixed in cmd_search/cmd_create/cmd_comment/cmd_transition; see
	# cmd_search's own comment for the full mechanism) — calling it here
	# first means resolve_account_id -> jira_curl's own ensure_workdir call
	# is a no-op, inherited from the already-tracked WORKDIR.
	ensure_workdir

	if [ "$OPT_LIST" -eq 1 ]; then
		watchers_url="https://${CONFIRMED_HOST}/rest/api/3/issue/${TICKET_KEY}/watchers"
		jira_curl GET "$watchers_url"
		handle_http_status "$JIRA_HTTP_CODE" "list watchers for $TICKET_KEY"
		require_json_body "list watchers for $TICKET_KEY"
		if [ "$OPT_JSON" -eq 1 ]; then
			cat "$JIRA_HTTP_BODY_FILE"
			return 0
		fi
		render_watchers_human "$JIRA_HTTP_BODY_FILE"
		return 0
	fi

	# "me"/"@me" (the default when --account is omitted) resolves via
	# GET /myself; anything else resolves via GET /user/search — the SAME
	# resolve_account_id() the READ path's search --assignee and the WRITE
	# path's create/update --assignee/--developer already use.
	watch_target=${OPT_ACCOUNT:-@me}
	watch_account_id=$(resolve_account_id "$watch_target")

	if [ "$OPT_REMOVE" -eq 1 ]; then
		# the resolved accountId (never the caller's raw --account
		# value) is urlencode()'d into the query string — the SAME helper
		# view/search already use for ?fields=/?query=.
		encoded_watch_account_id=$(urlencode "$watch_account_id")
		remove_watcher_url="https://${CONFIRMED_HOST}/rest/api/3/issue/${TICKET_KEY}/watchers?accountId=${encoded_watch_account_id}"
		jira_curl DELETE "$remove_watcher_url"
		handle_http_status "$JIRA_HTTP_CODE" "remove watcher from $TICKET_KEY"
		# DELETE /watchers returns 204 No Content — no require_json_body call.
		if [ "$OPT_JSON" -eq 1 ]; then
			jq -n --arg key "$TICKET_KEY" --arg accountId "$watch_account_id" \
				'{key: $key, accountId: $accountId, watching: false}'
		else
			printf 'JIRA_UNWATCHED=%s\n' "$TICKET_KEY"
		fi
		return 0
	fi

	# Add: the request body is the BARE accountId as a JSON string (per
	# Jira's own /watchers contract) — built via a single static jq -n
	# program fed via --arg, never string-concatenated.
	watch_request_file="$WORKDIR/watch-request.json"
	jq -n --arg id "$watch_account_id" '$id' >"$watch_request_file"
	add_watcher_url="https://${CONFIRMED_HOST}/rest/api/3/issue/${TICKET_KEY}/watchers"
	jira_curl POST "$add_watcher_url" "$watch_request_file"
	handle_http_status "$JIRA_HTTP_CODE" "add watcher to $TICKET_KEY"
	# POST /watchers returns 204 No Content — no require_json_body call.
	if [ "$OPT_JSON" -eq 1 ]; then
		jq -n --arg key "$TICKET_KEY" --arg accountId "$watch_account_id" \
			'{key: $key, accountId: $accountId, watching: true}'
	else
		printf 'JIRA_WATCHED=%s\n' "$TICKET_KEY"
	fi
}

# validate_watch_args() — `watch`'s per-command argument validation, called by
# jira.sh BEFORE any tool/site/credential check so a caller's own typo
# surfaces as a usage error (exit 2) first.
validate_watch_args() {
	require_ticket_positional watch
	if [ "$OPT_LIST" -eq 1 ] && [ "$OPT_REMOVE" -eq 1 ]; then
		usage >&2
		error "watch --list and --remove are mutually exclusive"
		exit 2
	fi
	if [ "$OPT_LIST" -eq 1 ] && [ -n "$OPT_ACCOUNT" ]; then
		usage >&2
		error "watch --list does not take --account"
		exit 2
	fi
	return 0
}
