# shellcheck shell=sh
#
# cmd-search.sh — `search`: build a JQL query from the filter flags (or take a
#                 raw --jql), then page /search/jql to the requested depth.
#
# Also the engine's set-resolution workhorse: children, bulk --jql and
# schedule --jql all drive their reads through cmd_search rather than
# re-implementing request building, escaping, pagination or rendering.
#
# Sourced by jira.sh — never executed directly. Sets no shell options and
# runs no top-level work beyond its own declarations, so sourcing it always
# returns 0 under `set -e`.

cmd_search() {
	# shellcheck disable=SC2034  # reset here, then set + read by projectconfig.sh's loader in the next line's call
	PROJECT_CONFIG_FILE=""
	[ -z "$OPT_PROJECT" ] || try_load_project_config "$OPT_PROJECT"

	# ensure_workdir MUST run here, in the MAIN shell, before
	# build_jql() — build_jql()'s --assignee path can call resolve_account_id()
	# -> jira_curl() -> ensure_workdir() from INSIDE the `search_jql=$(...)` command
	# substitution below, which is a SUBSHELL: a WORKDIR created only in that
	# subshell is discarded the instant the substitution ends (the EXIT trap
	# runs in the MAIN shell, where $WORKDIR would still be empty), orphaning
	# a jira.work.XXXXXX directory in TMPDIR every such search. Calling it
	# here first means jira_curl()'s own ensure_workdir() call is a no-op —
	# the subshell inherits an already-tracked, already-cleaned-up WORKDIR.
	ensure_workdir

	search_jql=$(build_jql)

	# page_limit caps the TOTAL fetched. 0 is the "unbounded" sentinel — paginate
	# to exhaustion (driven purely by isLast/nextPageToken) — which bulk --jql
	# sets via SEARCH_UNBOUNDED so it resolves the FULL matching set instead of
	# silently stopping at the 50 default. A user-supplied --limit is an explicit,
	# intentional cap and always wins over the unbounded mode (see resolve_bulk_keys_file).
	if [ "${SEARCH_UNBOUNDED:-0}" = "1" ] && [ -z "$OPT_LIMIT" ]; then
		page_limit=0
	else
		page_limit=${OPT_LIMIT:-50}
	fi
	page_size=${OPT_PAGE_SIZE:-50}
	[ "$page_size" -le 100 ] || { warn "--page-size capped at Jira's own 100-per-request ceiling"; page_size=100; }

	all_issues_file="$WORKDIR/search-issues.jsonl"
	: >"$all_issues_file"

	page_token=""
	total_fetched=0
	while :; do
		if [ "$page_limit" -gt 0 ]; then
			remaining=$((page_limit - total_fetched))
			[ "$remaining" -gt 0 ] || break
			this_page_size=$page_size
			[ "$remaining" -ge "$this_page_size" ] || this_page_size=$remaining
		else
			this_page_size=$page_size
		fi

		req_body_file="$WORKDIR/search-req-$((total_fetched + 1)).json"
		build_search_request_body "$req_body_file" "$search_jql" "$this_page_size" "$page_token"

		search_url="https://${CONFIRMED_HOST}/rest/api/3/search/jql"
		jira_curl POST "$search_url" "$req_body_file"
		handle_http_status "$JIRA_HTTP_CODE" "search"
		require_json_body "search"

		jq -c '.issues[]?' "$JIRA_HTTP_BODY_FILE" >>"$all_issues_file"
		page_count=$(jq '.issues | length' "$JIRA_HTTP_BODY_FILE")
		total_fetched=$((total_fetched + page_count))

		# NOTE: deliberately NOT `.isLast // true` — jq's `//` treats a JSON
		# `false` as falsy too (not just null/missing), so that idiom would
		# silently turn a real `isLast:false` into `true` and truncate
		# pagination after page one. An explicit null-check avoids it.
		is_last=$(jq -r 'if .isLast == null then true else .isLast end' "$JIRA_HTTP_BODY_FILE")
		[ "$is_last" != "true" ] && [ "$page_count" -gt 0 ] || break

		page_token=$(jq -r '.nextPageToken // empty' "$JIRA_HTTP_BODY_FILE")
		[ -n "$page_token" ] || break
	done

	if [ "$OPT_JSON" -eq 1 ]; then
		jq -s '{issues: .}' "$all_issues_file"
	else
		render_search_human "$all_issues_file" "$total_fetched"
	fi
}

# validate_search_args() — `search`'s per-command argument validation, called by
# jira.sh BEFORE any tool/site/credential check so a caller's own typo
# surfaces as a usage error (exit 2) first.
validate_search_args() {
	# search takes no positional — silently accepting one (e.g. a
	# stray ticket key from a copy-pasted `view` invocation) would run an
	# unintended, unfiltered-by-that-key query instead of failing loudly.
	if [ -n "$TICKET_KEY" ]; then
		usage >&2
		error "search takes no positional argument, got: $TICKET_KEY (use --project instead)"
		exit 2
	fi
	if [ -z "$OPT_JQL" ] && [ -z "$OPT_PROJECT" ] && [ -z "$OPT_ASSIGNEE" ] \
		&& [ -z "$OPT_STATUS" ] && [ -z "$OPT_TYPE" ] && [ -z "$OPT_LABELS" ]; then
		usage >&2
		error "search requires at least one filter: --project/--assignee/--status/--type/--labels/--jql"
		exit 2
	fi
	return 0
}
