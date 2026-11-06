# shellcheck shell=sh
#
# cmd-attach.sh — `attach`: issue attachments. Exactly ONE mode of --file
#                 (multipart upload, repeatable), --list, --delete --id N, or
#                 --download PATH --id N.
#
# Sourced by jira.sh — never executed directly. Sets no shell options and
# runs no top-level work beyond its own declarations, so sourcing it always
# returns 0 under `set -e`.

# ---------------------------------------------------------------------------
# attach — issue attachments (POST /issue/<KEY>/attachments multipart upload,
# GET /issue/<KEY>?fields=attachment list, DELETE /attachment/<id>, and
# GET /attachment/content/<id> -> the media CDN for --download). Mode selected
# by exactly ONE of: --file present (upload) / --list / --delete / --download
# (validated up front). Upload/list take the positional KEY; --delete and
# --download take --id only.
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
	# Mode (exactly one of upload[=--file present]/--list/--delete/--download),
	# the KEY positional / --id numeric shape, per-file readability and the
	# --download destination's local preconditions are validated up front — see
	# the main dispatch section's per-command block.
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

	if [ -n "$OPT_DOWNLOAD" ]; then
		# Two GETs, both inside download_attachment_content (the transport unit
		# owns every curl): /attachment/content/<id> for the media Location,
		# then the media CDN itself. OPT_ID is numeric-validated, and all FIVE of
		# OPT_DOWNLOAD's local preconditions are settled up front — the path does
		# NOT exist, its parent directory exists, that parent is writable, that
		# parent is not one other local users can write (assert_safe_download_dir),
		# and the path does not begin with "-" (which the install `ln` and the
		# cross-device `df` pre-check would read as an option) — so neither
		# argument is a surprise here.
		download_attachment_content "$OPT_ID" "$OPT_DOWNLOAD"
		if [ "$OPT_JSON" -eq 1 ]; then
			# SYNTHESIZED — the media CDN's response body IS the file, so there
			# is no JSON to pass through (same as --delete's 204 above).
			jq -n --arg id "$OPT_ID" --arg path "$OPT_DOWNLOAD" '{id: $id, path: $path, downloaded: true}'
		else
			# The path is CALLER-supplied and shares this stream with the
			# engine's other machine lines, so it goes through
			# runtime.sh's one_line_display — a newline in it would
			# otherwise forge a second line here.
			printf 'JIRA_ATTACHMENT_DOWNLOADED=%s -> %s\n' "$OPT_ID" "$(one_line_display "$OPT_DOWNLOAD")"
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
# jira.sh BEFORE any curl/site/credential check so a caller's own typo
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
	# Exactly one of: --file present (upload) | --list | --delete | --download.
	attach_upload=0
	[ -n "$OPT_FILES" ] && attach_upload=1
	attach_download=0
	[ -n "$OPT_DOWNLOAD" ] && attach_download=1
	attach_mode_count=$((attach_upload + OPT_LIST + OPT_DELETE + attach_download + OPT_CREATE + OPT_UPDATE + OPT_RELEASE + OPT_ARCHIVE))
	if [ "$attach_mode_count" -ne 1 ]; then
		usage >&2
		error "attach requires exactly one mode: --file PATH (upload), --list, --delete --id N, or --download PATH --id N"
		exit 2
	fi
	# --id selects an ATTACHMENT, so it belongs to the two modes that address one
	# (--delete, --download); upload/list address the ISSUE by KEY.
	if [ -n "$OPT_ID" ] && [ "$OPT_DELETE" -ne 1 ] && [ "$attach_download" -ne 1 ]; then
		usage >&2
		error "--id is only valid with attach --delete or attach --download"
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
		# so it gets component --delete's guard against a silently-ignored
		# --plan/--dry-run rather than a new kind of check: a preview dropped on a
		# destructive command is the worst failure available, since a caller
		# expecting one gets a REAL delete. Its --project refusal is at command
		# scope, at the end of this function — it applies to every attach mode.
		require_flag_off --plan/--dry-run "$OPT_PLAN" "version --delete among the delete commands — attach --delete would delete for REAL"
	fi
	if [ "$attach_download" -eq 1 ]; then
		# Same target shape as --delete above: an attachment id, never a ticket
		# key.
		if [ -n "$TICKET_KEY" ]; then
			usage >&2
			error "attach --download takes no ticket key (it downloads by --id): $TICKET_KEY"
			exit 2
		fi
		[ -n "$OPT_ID" ] || { usage >&2; error "attach --download requires --id N"; exit 2; }
		validate_numeric_id "$OPT_ID" || { usage >&2; error "invalid --id (must be a numeric attachment id): $OPT_ID"; exit 2; }
		# --plan and --force are both ACCEPTED by the shared parser and read by
		# NOBODY on this path, so each would be silently dropped on a mode that
		# creates a real local file — the same destructive-and-silent shape
		# --delete's own guards close, and not --list's situation (a listing has
		# no side effect for a preview to preview or a --force to force).
		# --force is the sharper of the two: this mode's help text tells the
		# caller outright that there is no --force, so accepting one would
		# confirm an overwrite policy that does not exist.
		require_flag_off --plan/--dry-run "$OPT_PLAN" "the commands that implement a preview (attach --download writes the file for real)"
		require_flag_off --force "$OPT_FORCE" "discover --write (attach --download has no overwrite mode)"
		# The destination's local preconditions, checked BEFORE any network
		# call for the same reason require_readable_file checks --file's paths up
		# front: every one of them is knowable now, and a caller should not spend a
		# request to learn about their own typo. FOUR are usage errors (exit 2) —
		# already-exists, parent absent, parent not writable, leading dash — and the
		# FIFTH, the parent directory's own safety, is exit 1 for the reason stated
		# at that check.
		#
		# REFUSING AN EXISTING PATH IS THE WHOLE OVERWRITE POLICY — there is no
		# --force, deliberately: the destination is arbitrary caller-chosen local
		# filesystem, and a mode that can silently replace a file on a mistyped
		# path is a worse default than one the caller has to re-run. -L catches a
		# DANGLING symlink, which -e does not. It is a usability guard, not a
		# security control: what protects the payload is that
		# download_attachment_content stages it inside the engine's own 0700
		# $WORKDIR and installs it with a hard link, which REFUSES an existing
		# destination name rather than writing through whatever it finds there —
		# so a path appearing between here and the install is a failed install,
		# never a followed symlink.
		if [ -e "$OPT_DOWNLOAD" ] || [ -L "$OPT_DOWNLOAD" ]; then
			usage >&2
			error "--download destination already exists (refusing to overwrite it): $(one_line_display "$OPT_DOWNLOAD")"
			exit 2
		fi
		# A leading "-" is refused because this path reaches two option-parsed
		# arguments — download_attachment_content's `ln` destination, and the `df`
		# behind its cross-device pre-check, which is handed the directory
		# derived from this path — and the toolbox has no realpath to normalize one
		# away with. Unchecked, `--download -out.bin` clears every other
		# precondition and then fails deep inside the download on a diagnostic
		# outside this mode's exit-2 destination contract, reported only after the
		# first request already spent the media JWT this pre-flight exists to avoid
		# wasting.
		#
		# THE FIRST BYTE OF THE WHOLE PATH — not the filename component, and not
		# "any component". A filename-only test misses `-dir/out.bin` (there it is
		# the DIRECTORY's own dash that gets read as an option), while a
		# per-component test refuses `dir/-out.bin`, `./-out.bin` and every absolute
		# path under a `-`-prefixed ancestor, all of which reach those tools with a
		# harmless leading byte and work. Verified both ways before narrowing to this.
		case "$OPT_DOWNLOAD" in
			-*)
				usage >&2
				error "--download destination must not begin with '-' (it would be read as an option): $(one_line_display "$OPT_DOWNLOAD")"
				exit 2 ;;
		esac
		# runtime.sh's parent_dir, not a copy of its expansion, because
		# download_attachment_content derives the SAME directory to ask whether it
		# is on another filesystem than $WORKDIR: two hand-rolled derivations that
		# disagreed would check one directory here and install into another there.
		attach_download_dir=$(parent_dir "$OPT_DOWNLOAD")
		if [ ! -d "$attach_download_dir" ]; then
			usage >&2
			error "--download destination directory does not exist: $(one_line_display "$attach_download_dir")"
			exit 2
		fi
		# Writability too, not existence alone: without this, an unwritable
		# directory surfaces as download_attachment_content's install `ln` failing
		# mid-run — after the payload has already been fetched — instead of as this
		# command's own usage error.
		if [ ! -w "$attach_download_dir" ]; then
			usage >&2
			error "--download destination directory is not writable: $(one_line_display "$attach_download_dir")"
			exit 2
		fi
		# AND THAT DIRECTORY MUST ITSELF BE SAFE TO KEEP A FILE IN — the same gate
		# runtime.sh applies to ${TMPDIR:-/tmp}, applied here to the one directory on
		# this path nobody else validates. The install is already sound (staged in
		# 0700 $WORKDIR, hard-linked, post-install verified), and this check does not
		# harden it: it refuses a destination whose directory another local user may
		# write, because such a user can unlink the SUCCESSFULLY installed file and
		# leave their own content at that name afterwards — no race to win, and
		# nothing about the install can prevent it. See assert_safe_download_dir for
		# why that is a trust boundary here specifically ($JIRA_PROJECTS_DIR/<KEY>.json
		# is a reachable destination) rather than the caller's own business.
		#
		# LAST OF THE DESTINATION CHECKS, and exit 1 rather than 2 WITH NO usage() —
		# deliberately both. Last, so a path whose directory is absent or unwritable still
		# gets its own precise exit-2 usage error instead of a fail-closed "could not
		# read the permissions". And exit 1, because this is the same "this location
		# is not safe to use" refusal as the $TMPDIR one it shares an implementation
		# with — a property of the local filesystem, not a malformed argument — so it
		# is classified with that one and not with the four usage errors above.
		assert_safe_download_dir "$attach_download_dir"
	fi
	# --project addresses a PROJECT, and NO attach mode is project-scoped: upload
	# and --list address an ISSUE by KEY, --delete and --download an ATTACHMENT by
	# --id. So the flag can only ever be a mistake here, in any mode — which is
	# why the guard sits at COMMAND scope and not inside one branch. Per-branch,
	# it covered --delete alone and left upload/--list/--download accepting and
	# SILENTLY dropping it, against this engine's documented contract that an
	# --id-addressed mode refuses --project by name. One guard cannot drift as a
	# fifth mode is added.
	require_foreign_flag_unset --project "$OPT_PROJECT" "project-scoped commands (attach addresses its target by KEY/--id)"
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
