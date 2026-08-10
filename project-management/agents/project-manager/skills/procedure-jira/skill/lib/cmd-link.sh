# shellcheck shell=sh
#
# cmd-link.sh — `link FROM --to TO --link-type NAME`: create one issue link
#               (POST /rest/api/3/issueLink).
#
# link direction (read this before wiring anything that calls `link`):
#   `link FROM --to TO --link-type NAME` models "FROM <verb> TO" in ACTIVE
#   VOICE — e.g. `link PROJ-1 --to PROJ-2 --link-type Blocks` reads as
#   "PROJ-1 blocks PROJ-2". Jira's issueLinkType stores an INWARD phrase and
#   an OUTWARD phrase per type (e.g. type "Blocks": outward "blocks",
#   inward "is blocked by"), and the REST payload names the two ends
#   `outwardIssue`/`inwardIssue`, not "from"/"to". VERIFIED LIVE
#   (2026-07-25, PSWS-958/959): the issue placed in
#   inwardIssue is the one that exhibits the OUTWARD (active-voice) phrase —
#   so FROM (the active subject that "blocks") is sent as inwardIssue and TO
#   (which "is blocked by" FROM) as outwardIssue. cmd_link builds exactly
#   {type:{name:NAME}, inwardIssue:{key:FROM}, outwardIssue:{key:TO}}. This
#   is the REVERSE of the naive "outward phrase => outwardIssue" reading
#   (which shipped first and produced a backwards link — the live test
#   caught it). Use `link-types` to see a type's exact inward/outward wording.
#
# Sourced by jira.sh — never executed directly. Sets no shell options and
# runs no top-level work beyond its own declarations, so sourcing it always
# returns 0 under `set -e`.

cmd_link() {
	# TICKET_KEY (FROM) / --to / --link-type presence & shape are validated
	# up front — see the main dispatch section's per-command validation.
	#
	# Direction (read this before touching this function): `link A --to B
	# --link-type "Blocks"` models "A blocks B". Jira's issueLinkType stores
	# an INWARD and an OUTWARD phrase per type (e.g. type "Blocks": outward
	# "blocks", inward "is blocked by"). VERIFIED LIVE against a real Jira
	# site (2026-07-25, PSWS-958/959): the issue placed in
	# inwardIssue is the one that exhibits the OUTWARD (active-voice) phrase.
	# So for "A blocks B", A (the active subject that "blocks") must be the
	# inwardIssue and B (which "is blocked by" A) must be the outwardIssue.
	# This is the REVERSE of the naive "outward phrase => outwardIssue"
	# reading, which shipped first and produced a backwards link — hence the
	# live check. Do NOT swap these back without re-verifying against Jira.
	#
	# ensure_workdir MUST run here, in the MAIN shell, before
	# convert_markdown_file_to_adf() below (reached only when --comment-file
	# is given) — that call reaches jira_curl() from INSIDE its own `$(...)`
	# command substitution, a subshell (the same class of leak already fixed
	# in cmd_comment; see that function's own comment for the full mechanism).
	ensure_workdir

	link_request_file="$WORKDIR/link-request.json"
	init_fields_accumulator "$link_request_file"
	merge_ref_field "$link_request_file" type name "$OPT_LINK_TYPE"
	# FROM -> inwardIssue, TO -> outwardIssue (verified live; see the
	# direction note above — inwardIssue exhibits the outward/active phrase).
	merge_ref_field "$link_request_file" inwardIssue key "$TICKET_KEY"
	merge_ref_field "$link_request_file" outwardIssue key "$OPT_TO"

	if [ -n "$OPT_COMMENT_FILE" ]; then
		require_readable_file "$OPT_COMMENT_FILE" "--comment-file"
		link_comment_adf_file=$(convert_markdown_file_to_adf "$OPT_COMMENT_FILE")
		link_comment_body_file="$WORKDIR/link-comment-body.json"
		jq -n --slurpfile body "$link_comment_adf_file" '{body: $body[0]}' >"$link_comment_body_file"
		merge_json_field "$link_request_file" comment "$link_comment_body_file"
	fi

	link_url="https://${CONFIRMED_HOST}/rest/api/3/issueLink"
	jira_curl POST "$link_url" "$link_request_file"
	handle_http_status "$JIRA_HTTP_CODE" "link $TICKET_KEY -> $OPT_TO ($OPT_LINK_TYPE)"
	# issueLink POST returns 201 Created with an EMPTY body — deliberately
	# NO require_json_body call here, same reasoning as execute_plain_transition.

	if [ "$OPT_JSON" -eq 1 ]; then
		# SYNTHESIZED, not passthrough — there is no response body
		# to pass through (see above); same reasoning as cmd_update's --json.
		jq -n --arg from "$TICKET_KEY" --arg to "$OPT_TO" --arg type "$OPT_LINK_TYPE" \
			'{from: $from, to: $to, type: $type}'
	else
		printf 'JIRA_LINKED=%s->%s (%s)\n' "$TICKET_KEY" "$OPT_TO" "$OPT_LINK_TYPE"
	fi
}

# validate_link_args() — `link`'s per-command argument validation, called by
# jira.sh BEFORE any tool/site/credential check so a caller's own typo
# surfaces as a usage error (exit 2) first.
validate_link_args() {
	[ -n "$TICKET_KEY" ] || { usage >&2; error "link requires a FROM ticket key, e.g.: link PROJ-1 --to PROJ-2 --link-type Blocks"; exit 2; }
	validate_ticket_key "$TICKET_KEY" || { usage >&2; error "invalid FROM ticket key: $TICKET_KEY"; exit 2; }
	[ -n "$OPT_TO" ] || { usage >&2; error "link requires --to TARGET_KEY"; exit 2; }
	validate_ticket_key "$OPT_TO" || { usage >&2; error "invalid --to ticket key: $OPT_TO"; exit 2; }
	[ -n "$OPT_LINK_TYPE" ] || { usage >&2; error "link requires --link-type NAME"; exit 2; }
	return 0
}
