# shellcheck shell=sh
#
# cmd-comment.sh — `comment <KEY> --text-file PATH`: convert the markdown to ADF
#                  (uploading any inline images first) and POST it as the
#                  comment body.
#
# There is deliberately no --text string flag: large/arbitrary content must
# never be interpolated into a caller's shell command.
#
# Sourced by jira.sh — never executed directly. Sets no shell options and
# runs no top-level work beyond its own declarations, so sourcing it always
# returns 0 under `set -e`.

# ---------------------------------------------------------------------------
# comment — POST /rest/api/3/issue/<KEY>/comment
# ---------------------------------------------------------------------------

cmd_comment() {
	# TICKET_KEY/--text-file presence is validated up front — see the main
	# dispatch section's per-command required-argument validation.
	#
	# ensure_workdir MUST run here, in the MAIN shell, before
	# convert_markdown_file_to_adf() below — that call reaches jira_curl()
	# from INSIDE its own `$(...)` command substitution at the call site
	# two lines down, which is a subshell (same class of leak already fixed
	# in cmd_search; see that function's comment for the full mechanism).
	ensure_workdir

	require_readable_file "$OPT_TEXT_FILE" "--text-file"
	# Inline-image pre-pass: upload each own-line local image to the issue and
	# build a media map, then convert WITH that map so the images become
	# mediaSingle blocks. An upload to a nonexistent KEY fails loud here (the
	# attachments POST 404s), so the issue's existence is enforced before the
	# comment is posted. No inline images -> empty map -> unchanged behavior.
	comment_media_map=$(resolve_inline_images "$TICKET_KEY" "$OPT_TEXT_FILE")
	comment_adf_file=$(convert_markdown_file_to_adf "$OPT_TEXT_FILE" "$comment_media_map")

	comment_request_file="$WORKDIR/comment-request.json"
	jq -n --slurpfile body "$comment_adf_file" '{body: $body[0]}' >"$comment_request_file"

	comment_url="https://${CONFIRMED_HOST}/rest/api/3/issue/${TICKET_KEY}/comment"
	jira_curl POST "$comment_url" "$comment_request_file"
	handle_http_status "$JIRA_HTTP_CODE" "comment on $TICKET_KEY"
	require_json_body "comment on $TICKET_KEY"

	if [ "$OPT_JSON" -eq 1 ]; then
		# PASSTHROUGH, not synthesized — same reasoning as create's
		# --json (see cmd_create): Jira's 201 body IS the answer.
		cat "$JIRA_HTTP_BODY_FILE"
		return 0
	fi
	new_comment_id=$(jq -r '.id // ""' "$JIRA_HTTP_BODY_FILE" | strip_control_ansi)
	printf 'JIRA_COMMENT_ID=%s\n' "$new_comment_id"
}

# validate_comment_args() — `comment`'s per-command argument validation, called by
# jira.sh BEFORE any tool/site/credential check so a caller's own typo
# surfaces as a usage error (exit 2) first.
validate_comment_args() {
	require_ticket_positional comment
	[ -n "$OPT_TEXT_FILE" ] || { usage >&2; error "comment requires --text-file"; exit 2; }
	return 0
}
