# shellcheck shell=sh
#
# cmd-attach.sh — `attach`: issue attachments. Exactly ONE mode of --file
#                 (multipart upload, repeatable), --list, or --delete --id N.
#
# Sourced by jira.sh — never executed directly. Sets no shell options and
# runs no top-level work beyond its own declarations, so sourcing it always
# returns 0 under `set -e`.

# ---------------------------------------------------------------------------
# attach — issue attachments (POST /issue/<KEY>/attachments multipart upload,
# GET /issue/<KEY>?fields=attachment list, DELETE /attachment/<id>). Mode
# selected by exactly ONE of: --file present (upload) / --list / --delete
# (validated up front). Upload/list take the positional KEY; --delete takes
# --id only.
# ---------------------------------------------------------------------------

# render_attachments_human BODY_FILE — one line per attachment. BODY is the
# GET /issue?fields=attachment response; .fields.attachment is a PLAIN ARRAY
# (empty `[]` is valid) — verified against live Jira. `id` is a STRING.
render_attachments_human() {
	attachments_body_file=$1
	# Assert .fields.attachment is a JSON ARRAY before the per-line loop: on a
	# valid-JSON body where it is absent/non-array, `jq -c '.fields.attachment[]'`
	# would error, and under POSIX sh (no pipefail) that error is masked by the
	# pipe — the loop would silently emit nothing and exit 0. Fail loud instead.
	if ! jq -e '.fields.attachment | type=="array"' "$attachments_body_file" >/dev/null 2>&1; then
		error "list attachments failed: response body was not the expected attachment array"
		exit 1
	fi
	attachment_count=$(jq '.fields.attachment | length' "$attachments_body_file")
	if [ "$attachment_count" -eq 0 ]; then
		printf 'No attachments.\n'
		return 0
	fi
	printf 'Attachments:\n'
	# Same delimiter-injection-proof idiom as render_components_human — one
	# compact JSON object per line, each field extracted independently by jq,
	# never an IFS split a filename carrying a literal tab/newline would break.
	# strip_control_ansi on the untrusted filename + mimeType (id/size are
	# API-shaped, but stripping them too is harmless).
	jq -c '.fields.attachment[]' "$attachments_body_file" | while IFS= read -r attachment_line; do
		at_id=$(printf '%s' "$attachment_line" | jq -r '.id // ""' | strip_control_ansi)
		at_name=$(printf '%s' "$attachment_line" | jq -r '.filename // ""' | strip_control_ansi)
		at_size=$(printf '%s' "$attachment_line" | jq -r '.size // ""' | strip_control_ansi)
		at_mime=$(printf '%s' "$attachment_line" | jq -r '.mimeType // ""' | strip_control_ansi)
		printf '  %s · %s · %s · %s\n' "$at_id" "$at_name" "$at_size" "$at_mime"
	done
}

cmd_attach() {
	# Mode (exactly one of upload[=--file present]/--list/--delete), the KEY
	# positional / --id numeric shape, and per-file readability are validated
	# up front — see the main dispatch section's per-command block.
	ensure_workdir

	if [ "$OPT_LIST" -eq 1 ]; then
		attach_list_url="https://${CONFIRMED_HOST}/rest/api/3/issue/${TICKET_KEY}?fields=attachment"
		jira_curl GET "$attach_list_url"
		handle_http_status "$JIRA_HTTP_CODE" "list attachments for $TICKET_KEY"
		require_json_body "list attachments for $TICKET_KEY"
		if [ "$OPT_JSON" -eq 1 ]; then
			cat "$JIRA_HTTP_BODY_FILE"
			return 0
		fi
		render_attachments_human "$JIRA_HTTP_BODY_FILE"
		return 0
	fi

	if [ "$OPT_DELETE" -eq 1 ]; then
		# OPT_ID is numeric-validated up front before this URL-segment interp.
		attach_delete_url="https://${CONFIRMED_HOST}/rest/api/3/attachment/${OPT_ID}"
		jira_curl DELETE "$attach_delete_url"
		handle_http_status "$JIRA_HTTP_CODE" "delete attachment $OPT_ID"
		# DELETE /attachment returns 204 No Content — no require_json_body call.
		if [ "$OPT_JSON" -eq 1 ]; then
			# SYNTHESIZED — no 204 body to pass through (same as component --delete).
			jq -n --arg id "$OPT_ID" '{id: $id, deleted: true}'
		else
			printf 'JIRA_ATTACHMENT_DELETED=%s\n' "$OPT_ID"
		fi
		return 0
	fi

	# upload — POST /issue/<KEY>/attachments as multipart, one -F part per
	# --file. The 200 body is a JSON ARRAY (one object per uploaded file).
	attach_upload_url="https://${CONFIRMED_HOST}/rest/api/3/issue/${TICKET_KEY}/attachments"
	jira_curl_multipart POST "$attach_upload_url" "$OPT_FILES"
	handle_http_status "$JIRA_HTTP_CODE" "upload attachment(s) to $TICKET_KEY"
	require_json_body "upload attachment(s) to $TICKET_KEY"
	if [ "$OPT_JSON" -eq 1 ]; then
		# PASSTHROUGH — Jira's 200 body IS the array of uploaded attachments.
		cat "$JIRA_HTTP_BODY_FILE"
		return 0
	fi
	# Assert the 200 body is a JSON ARRAY before the per-line loop: a valid-JSON
	# non-array body would make `jq -c '.[]'` error, and under POSIX sh (no
	# pipefail) that error is masked by the pipe — the loop would silently emit
	# nothing and exit 0. Fail loud instead.
	if ! jq -e 'type=="array"' "$JIRA_HTTP_BODY_FILE" >/dev/null 2>&1; then
		error "upload attachment(s) to $TICKET_KEY failed: response body was not a JSON array"
		exit 1
	fi
	# One id + filename pair per uploaded file, in array order. id is a STRING;
	# the untrusted filename goes through strip_control_ansi. Same per-line jq
	# idiom as render_attachments_human.
	jq -c '.[]' "$JIRA_HTTP_BODY_FILE" | while IFS= read -r uploaded_line; do
		up_id=$(printf '%s' "$uploaded_line" | jq -r '.id // ""' | strip_control_ansi)
		up_name=$(printf '%s' "$uploaded_line" | jq -r '.filename // ""' | strip_control_ansi)
		printf 'JIRA_ATTACHMENT_ID=%s\n' "$up_id"
		printf 'JIRA_ATTACHMENT_FILENAME=%s\n' "$up_name"
	done
}

# validate_attach_args() — `attach`'s per-command argument validation, called by
# jira.sh BEFORE any tool/site/credential check so a caller's own typo
# surfaces as a usage error (exit 2) first.
validate_attach_args() {
	# --create/--update/--release/--archive are version/component modes,
	# not attach modes — reject by name (clear message; same defense as
	# version/component's foreign-flag guards), and additionally fold every
	# foreign mode flag into the exactly-one count below so no foreign mode
	# passes unnoticed even if one is added later.
	if [ "$OPT_CREATE" -eq 1 ] || [ "$OPT_UPDATE" -eq 1 ] || [ "$OPT_RELEASE" -eq 1 ] || [ "$OPT_ARCHIVE" -eq 1 ]; then
		usage >&2
		error "--create/--update/--release/--archive are not attach modes"
		exit 2
	fi
	# Exactly one of: --file present (upload) | --list | --delete.
	attach_upload=0
	[ -n "$OPT_FILES" ] && attach_upload=1
	attach_mode_count=$((attach_upload + OPT_LIST + OPT_DELETE + OPT_CREATE + OPT_UPDATE + OPT_RELEASE + OPT_ARCHIVE))
	if [ "$attach_mode_count" -ne 1 ]; then
		usage >&2
		error "attach requires exactly one mode: --file PATH (upload), --list, or --delete --id N"
		exit 2
	fi
	# --id is a --delete-only selector; upload/list address the issue by KEY.
	if [ -n "$OPT_ID" ] && [ "$OPT_DELETE" -ne 1 ]; then
		usage >&2
		error "--id is only valid with attach --delete"
		exit 2
	fi
	if [ "$attach_upload" -eq 1 ] || [ "$OPT_LIST" -eq 1 ]; then
		[ -n "$TICKET_KEY" ] || { usage >&2; error "attach upload/--list requires a ticket key, e.g.: attach PROJ-1 --file PATH"; exit 2; }
		validate_ticket_key "$TICKET_KEY" || { usage >&2; error "invalid ticket key: $TICKET_KEY"; exit 2; }
	fi
	if [ "$attach_upload" -eq 1 ]; then
		# Each --file must exist + be readable BEFORE any network call
		# (usage error, exit 2). while-read runs in THIS shell so an exit
		# inside require_readable_file aborts the whole script as intended.
		while IFS= read -r attach_file_path; do
			[ -n "$attach_file_path" ] || continue
			require_readable_file "$attach_file_path" "--file"
		done <<-ATTACH_FILES_EOF
		$OPT_FILES
		ATTACH_FILES_EOF
	fi
	if [ "$OPT_DELETE" -eq 1 ]; then
		if [ -n "$TICKET_KEY" ]; then
			usage >&2
			error "attach --delete takes no ticket key (it deletes by --id): $TICKET_KEY"
			exit 2
		fi
		[ -n "$OPT_ID" ] || { usage >&2; error "attach --delete requires --id N"; exit 2; }
		validate_numeric_id "$OPT_ID" || { usage >&2; error "invalid --id (must be a numeric attachment id): $OPT_ID"; exit 2; }
		# `version --delete`'s two pre-write safety nets are NOT implemented
		# here either, and this is the third destructive --delete in the engine,
		# so it gets component --delete's identical pair of guards rather than a
		# new kind of check. --plan/--dry-run silently ignored on a destructive
		# command is the worst failure available (a caller expecting a preview
		# gets a REAL delete); --project addresses a project, while attach
		# addresses an issue by KEY and an attachment by --id, so it can only be
		# a mistake here.
		require_flag_off --plan/--dry-run "$OPT_PLAN" "version --delete among the delete commands — attach --delete would delete for REAL"
		require_foreign_flag_unset --project "$OPT_PROJECT" "project-scoped commands (attach addresses its target by KEY/--id)"
	fi
	# The three reassignment targets belong to version/component --delete. An
	# attachment has no issue references to re-point, so cmd_attach never reads
	# any of them: unguarded, `attach --delete --id N --move-fix-issues-to M`
	# would exit 0 having deleted the attachment and SILENTLY dropped the flag —
	# the SAME destructive-and-silent shape component --delete's own guards
	# close, so it gets the same guards rather than a new kind of check.
	require_foreign_flag_unset --move-issues-to "$OPT_MOVE_ISSUES_TO" "component --delete"
	require_foreign_flag_unset --move-fix-issues-to "$OPT_MOVE_FIX_ISSUES_TO" "version --delete"
	require_foreign_flag_unset --move-affected-issues-to "$OPT_MOVE_AFFECTED_ISSUES_TO" "version --delete"
	return 0
}
