# shellcheck shell=sh
#
# cmd-worklog.sh — `worklog <KEY> --time-spent STR`: POST a worklog entry.
#
# Note the request body has NO fields{} wrapper (unlike create/update) — the
# accumulator built by fields.sh IS the whole body.
#
# Sourced by jira.sh — never executed directly. Sets no shell options and
# runs no top-level work beyond its own declarations, so sourcing it always
# returns 0 under `set -e`.

# ---------------------------------------------------------------------------
# worklog <KEY> — POST /rest/api/3/issue/<KEY>/worklog
# ---------------------------------------------------------------------------

cmd_worklog() {
	# TICKET_KEY/--time-spent presence is validated up front — see the main
	# dispatch section's per-command required-argument validation.
	#
	# ensure_workdir MUST run here, in the MAIN shell, before
	# convert_markdown_file_to_adf() below (reached only when --comment-file
	# is given) — same subshell-WORKDIR-loss class already fixed in
	# cmd_comment; see that function's own comment for the full mechanism.
	ensure_workdir

	# The request body has NO fields{} wrapper (unlike create/update) — the
	# accumulator built by init_fields_accumulator()/merge_*_field() IS the
	# whole request body, sent to jira_curl as-is.
	worklog_request_file="$WORKDIR/worklog-request.json"
	init_fields_accumulator "$worklog_request_file"
	merge_string_field "$worklog_request_file" timeSpent "$OPT_TIME_SPENT"

	if [ -n "$OPT_COMMENT_FILE" ]; then
		require_readable_file "$OPT_COMMENT_FILE" "--comment-file"
		worklog_comment_adf_file=$(convert_markdown_file_to_adf "$OPT_COMMENT_FILE")
		merge_json_field "$worklog_request_file" comment "$worklog_comment_adf_file"
	fi

	[ -z "$OPT_STARTED" ] || merge_string_field "$worklog_request_file" started "$OPT_STARTED"

	worklog_url="https://${CONFIRMED_HOST}/rest/api/3/issue/${TICKET_KEY}/worklog"
	jira_curl POST "$worklog_url" "$worklog_request_file"
	handle_http_status "$JIRA_HTTP_CODE" "log work on $TICKET_KEY"
	require_json_body "log work on $TICKET_KEY"

	if [ "$OPT_JSON" -eq 1 ]; then
		# PASSTHROUGH — Jira's own 201 response body (the created
		# worklog entry) IS the answer, same reasoning as cmd_create/cmd_comment.
		cat "$JIRA_HTTP_BODY_FILE"
		return 0
	fi
	printf 'JIRA_WORKLOGGED=%s (%s)\n' "$TICKET_KEY" "$OPT_TIME_SPENT"
}

# validate_worklog_args() — `worklog`'s per-command argument validation, called by
# jira.sh BEFORE any tool/site/credential check so a caller's own typo
# surfaces as a usage error (exit 2) first.
validate_worklog_args() {
	[ -n "$TICKET_KEY" ] || { usage >&2; error "worklog requires a ticket key, e.g.: worklog PROJ-1 --time-spent 2h"; exit 2; }
	validate_ticket_key "$TICKET_KEY" || { usage >&2; error "invalid ticket key: $TICKET_KEY"; exit 2; }
	[ -n "$OPT_TIME_SPENT" ] || { usage >&2; error "worklog requires --time-spent STR"; exit 2; }
	return 0
}
