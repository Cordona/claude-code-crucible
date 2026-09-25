# shellcheck shell=sh
#
# cmd-link.sh — `link FROM --to TO --link-type NAME`: create one issue link
#               (POST /rest/api/3/issueLink); `link FROM --remove`: delete one
#               (DELETE /rest/api/3/issueLink/<id>).
#
# link --remove (read this before wiring a consent gate onto it):
#   The link is SELECTED one of two mutually exclusive ways, and never guessed:
#   `--link-id N` names it directly, and is cross-checked against FROM (GET
#   /issueLink/<N>; FROM must be one of its two ends) so a valid-but-wrong id
#   cannot delete a link on some unrelated issue; `--to KEY --link-type NAME`
#   resolves it from FROM's own issuelinks, and must match EXACTLY ONE link —
#   zero or several is a refusal naming the candidates, never a pick. Direction
#   is NOT part of that match: a "Blocks" link between FROM and KEY is found
#   whichever of the two is the blocker, because the caller naming both ends
#   and the type is already naming one link. `--plan`/`--dry-run` stops after
#   those reads and prints the link that WOULD go; it is still classified a
#   WRITE by lib/readonlygate.sh (see that file's --plan note).
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

	if [ "$OPT_REMOVE" -eq 1 ]; then
		remove_issue_link
		return 0
	fi

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

# remove_issue_link — `link FROM --remove`: select the link (see the file
# header), then either disclose it (--plan) or DELETE it. The selection travels
# as the three LINK_REMOVAL_* globals below, published by whichever resolver
# ran and read back by the renderers and the DELETE.
LINK_REMOVAL_ID=""
LINK_REMOVAL_TYPE=""
LINK_REMOVAL_OTHER_END=""
remove_issue_link() {
	if [ -n "$OPT_LINK_ID" ]; then
		resolve_link_by_id
	else
		resolve_link_by_ends
	fi
	# The id is about to become a URL path segment. On the --to path it came
	# from the RESPONSE, so it gets the same shape check a caller's --link-id
	# got at validation — an untrusted value never reaches a URL unchecked.
	validate_numeric_id "$LINK_REMOVAL_ID" || {
		error "issue link id from Jira is not numeric — refusing to build a URL from it"
		exit 1
	}

	if [ "$OPT_PLAN" -eq 1 ]; then
		if [ "$OPT_JSON" -eq 1 ]; then
			render_link_removal_json false
		else
			render_link_removal_plan_human
		fi
		return 0
	fi

	unlink_url="https://${CONFIRMED_HOST}/rest/api/3/issueLink/${LINK_REMOVAL_ID}"
	jira_curl DELETE "$unlink_url"
	handle_http_status "$JIRA_HTTP_CODE" "remove issue link $LINK_REMOVAL_ID from $TICKET_KEY"
	# DELETE /issueLink/<id> returns 204 No Content — no require_json_body call.
	if [ "$OPT_JSON" -eq 1 ]; then
		render_link_removal_json true
	else
		printf 'JIRA_UNLINKED=%s\n' "$LINK_REMOVAL_ID"
	fi
}

# resolve_link_by_id — `link --remove --link-id N`: fetch the link and refuse
# (exit 1) unless FROM is one of its two ends. Publishes the selected link as
# LINK_REMOVAL_ID/LINK_REMOVAL_TYPE/LINK_REMOVAL_OTHER_END.
resolve_link_by_id() {
	rlbi_url="https://${CONFIRMED_HOST}/rest/api/3/issueLink/${OPT_LINK_ID}"
	jira_curl GET "$rlbi_url"
	handle_http_status "$JIRA_HTTP_CODE" "fetch issue link $OPT_LINK_ID"
	require_json_body "fetch issue link $OPT_LINK_ID"
	rlbi_inward=$(jq -r '.inwardIssue.key // ""' "$JIRA_HTTP_BODY_FILE")
	rlbi_outward=$(jq -r '.outwardIssue.key // ""' "$JIRA_HTTP_BODY_FILE")
	if [ "$rlbi_inward" = "$TICKET_KEY" ]; then
		LINK_REMOVAL_OTHER_END=$rlbi_outward
	elif [ "$rlbi_outward" = "$TICKET_KEY" ]; then
		LINK_REMOVAL_OTHER_END=$rlbi_inward
	else
		error "issue link $OPT_LINK_ID does not belong to $TICKET_KEY (it joins '$(one_line_display "$rlbi_inward")' and '$(one_line_display "$rlbi_outward")') — refusing to remove it"
		exit 1
	fi
	LINK_REMOVAL_ID=$OPT_LINK_ID
	LINK_REMOVAL_TYPE=$(jq -r '.type.name // ""' "$JIRA_HTTP_BODY_FILE")
}

# resolve_link_by_ends — `link --remove --to KEY --link-type NAME`: find the
# ONE link on FROM whose type name equals NAME (case-insensitively) and whose
# other end is KEY. Zero or several matches fail loud (exit 1); several are
# listed by id so the caller can re-run with --link-id. Publishes the same
# three LINK_REMOVAL_* values resolve_link_by_id does.
resolve_link_by_ends() {
	rlbe_url="https://${CONFIRMED_HOST}/rest/api/3/issue/${TICKET_KEY}?fields=issuelinks"
	jira_curl GET "$rlbe_url"
	handle_http_status "$JIRA_HTTP_CODE" "fetch issue links of $TICKET_KEY"
	require_json_body "fetch issue links of $TICKET_KEY"
	rlbe_summary=$(jq -c --arg to "$OPT_TO" --arg t "$OPT_LINK_TYPE" \
		'[(.fields.issuelinks // [])[] | objects
		  | select(((.type.name // "") | ascii_downcase) == ($t | ascii_downcase))
		  | select((.outwardIssue.key // "") == $to or (.inwardIssue.key // "") == $to)]
		 | {count: length, ids: (map(.id // "" | tostring) | join(" ")),
		    id: (.[0].id // "" | tostring), type: (.[0].type.name // "")}' \
		"$JIRA_HTTP_BODY_FILE")
	rlbe_safe_type=$(one_line_display "$OPT_LINK_TYPE")
	rlbe_count=$(printf '%s' "$rlbe_summary" | jq -r '.count')
	if [ "$rlbe_count" -eq 0 ]; then
		error "no '$rlbe_safe_type' link between $TICKET_KEY and $OPT_TO — nothing to remove (run \`view $TICKET_KEY --fields issuelinks --json\` to see its links)"
		exit 1
	fi
	if [ "$rlbe_count" -gt 1 ]; then
		rlbe_ids=$(printf '%s' "$rlbe_summary" | jq -r '.ids')
		error "$rlbe_count '$rlbe_safe_type' links join $TICKET_KEY and $OPT_TO (ids: $(one_line_display "$rlbe_ids")) — refusing to pick one; re-run with --link-id N"
		exit 1
	fi
	LINK_REMOVAL_ID=$(printf '%s' "$rlbe_summary" | jq -r '.id')
	LINK_REMOVAL_TYPE=$(printf '%s' "$rlbe_summary" | jq -r '.type')
	LINK_REMOVAL_OTHER_END=$OPT_TO
}

# render_link_removal_plan_human — what the consent gate discloses before a
# real `link --remove`. The type and the other end's key are API text, folded
# onto their one line so a crafted value cannot forge the closing row.
render_link_removal_plan_human() {
	printf 'JIRA_UNLINK_PLANNED=%s\n' "$LINK_REMOVAL_ID"
	printf 'Would remove link %s: %s <-> %s (type: %s)\n' "$LINK_REMOVAL_ID" "$TICKET_KEY" \
		"$(one_line_display "$LINK_REMOVAL_OTHER_END")" "$(one_line_display "$LINK_REMOVAL_TYPE")"
	printf 'NOTHING WAS WRITTEN (dry-run / --plan).\n'
}

# render_link_removal_json EXECUTED — the ONE --json shape for both the
# --plan preview (false) and the real delete (true), the same executed flag
# transition/comment-edit carry. SYNTHESIZED: the DELETE answers 204 with no
# body, and --plan never reaches it.
render_link_removal_json() {
	jq -n --arg id "$LINK_REMOVAL_ID" --arg type "$LINK_REMOVAL_TYPE" \
		--arg from "$TICKET_KEY" --arg to "$LINK_REMOVAL_OTHER_END" --argjson executed "$1" \
		'{id: $id, type: $type, from: $from, to: $to, executed: $executed}'
}

# validate_link_args() — `link`'s per-command argument validation, called by
# jira.sh BEFORE any tool/site/credential check so a caller's own typo
# surfaces as a usage error (exit 2) first.
validate_link_args() {
	[ -n "$TICKET_KEY" ] || { usage >&2; error "link requires a FROM ticket key, e.g.: link PROJ-1 --to PROJ-2 --link-type Blocks"; exit 2; }
	validate_ticket_key "$TICKET_KEY" || { usage >&2; error "invalid FROM ticket key: $TICKET_KEY"; exit 2; }
	if [ "$OPT_REMOVE" -eq 1 ]; then
		require_link_remove_selector
		return 0
	fi
	# --link-id and --plan belong to --remove alone: accepted and dropped here,
	# either would CREATE a link the caller believed they were removing or only
	# previewing.
	require_foreign_flag_unset --link-id "$OPT_LINK_ID" "link --remove"
	require_flag_off --plan/--dry-run "$OPT_PLAN" "link --remove"
	[ -n "$OPT_TO" ] || { usage >&2; error "link requires --to TARGET_KEY"; exit 2; }
	validate_ticket_key "$OPT_TO" || { usage >&2; error "invalid --to ticket key: $OPT_TO"; exit 2; }
	[ -n "$OPT_LINK_TYPE" ] || { usage >&2; error "link requires --link-type NAME"; exit 2; }
	return 0
}

# require_link_remove_selector — the --remove half of validate_link_args (a
# usage guard, exit 2, hence require_* rather than validate_*): exactly
# one selector (--link-id, or --to with --link-type), and no --comment-file,
# which Jira's DELETE has nowhere to put.
require_link_remove_selector() {
	if [ -n "$OPT_COMMENT_FILE" ]; then
		usage >&2
		error "link --remove does not take --comment-file (deleting a link posts no comment)"
		exit 2
	fi
	if [ -n "$OPT_LINK_ID" ]; then
		if [ -n "$OPT_TO" ] || [ -n "$OPT_LINK_TYPE" ]; then
			usage >&2
			error "link --remove takes --link-id N OR --to KEY --link-type NAME, not both"
			exit 2
		fi
		validate_numeric_id "$OPT_LINK_ID" || { usage >&2; error "invalid --link-id (must be a numeric issue-link id): $OPT_LINK_ID"; exit 2; }
		return 0
	fi
	if [ -z "$OPT_TO" ] || [ -z "$OPT_LINK_TYPE" ]; then
		usage >&2
		error "link --remove requires --link-id N, or both --to KEY and --link-type NAME"
		exit 2
	fi
	validate_ticket_key "$OPT_TO" || { usage >&2; error "invalid --to ticket key: $OPT_TO"; exit 2; }
	return 0
}
