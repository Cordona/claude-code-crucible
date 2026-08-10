# shellcheck shell=sh
#
# cmd-create.sh — `create`: POST /issue, plus the project-config-driven type
#                 resolution/validation and the subtask parent-type rules.
#
# Inline images are a deliberate 2-STEP: an attachment upload needs a live
# issue, so the description is first sent WITHOUT media, then (only when the
# markdown actually contains own-line local images) re-converted WITH the media
# map and PUT back. With no inline images this costs ZERO extra calls.
#
# Sourced by jira.sh — never executed directly. Sets no shell options and
# runs no top-level work beyond its own declarations, so sourcing it always
# returns 0 under `set -e`.

# ---------------------------------------------------------------------------
# create — POST /rest/api/3/issue
# ---------------------------------------------------------------------------

# validate_issue_type_if_configured TYPE — a no-op when no project config
# was loaded, or when the config declares no issue_types at all (matches the
# oracle: an empty/absent list means "skip validation", not "reject everything").
validate_issue_type_if_configured() {
	candidate_type=$1
	[ -n "$PROJECT_CONFIG_FILE" ] || return 0
	jq -e --arg t "$candidate_type" \
		'(.issue_types // []) as $types | ($types | length) == 0 or (($types | index($t)) != null)' \
		"$PROJECT_CONFIG_FILE" >/dev/null 2>&1 || {
		error "invalid type '$candidate_type' for this project (see the project config's issue_types)"
		exit 1
	}
}

# is_subtask_type CONFIG_FILE TYPE -> 0 if TYPE is in the config's
# subtask_types list.
is_subtask_type() {
	config_file_for_check=$1
	candidate_type=$2
	jq -e --arg t "$candidate_type" '(.subtask_types // []) | index($t) != null' \
		"$config_file_for_check" >/dev/null 2>&1
}

# validate_subtask_parent_type CONFIG_FILE PARENT_TYPE — fails closed (exit
# 1) if the config declares subtask_parent_types and PARENT_TYPE isn't one
# of them (an empty/absent list means "no constraint configured").
validate_subtask_parent_type() {
	config_file_for_check=$1
	candidate_parent_type=$2
	jq -e --arg pt "$candidate_parent_type" \
		'(.subtask_parent_types // []) as $allowed | ($allowed | length) == 0 or (($allowed | index($pt)) != null)' \
		"$config_file_for_check" >/dev/null 2>&1 || {
		error "a subtask may only be created under one of the project config's subtask_parent_types (parent's type is: $candidate_parent_type)"
		exit 1
	}
}

cmd_create() {
	# --project/--title presence is validated up front — see the main
	# dispatch section's per-command required-argument validation.
	#
	# ensure_workdir MUST run here, in the MAIN shell, before ANY
	# call that might reach jira_curl() from inside a `$(...)` command
	# substitution (resolve_issue_type_of() below, for a subtask create, is
	# exactly such a call) — the same orphan-WORKDIR leak already fixed once
	# in cmd_search; see that function's own comment for the full mechanism.
	ensure_workdir

	PROJECT_CONFIG_FILE=""
	try_load_project_config "$OPT_PROJECT"

	resolved_issue_type=$(resolve_type_alias "$PROJECT_CONFIG_FILE" "${OPT_TYPE:-Task}")
	validate_issue_type_if_configured "$resolved_issue_type"

	if [ -n "$PROJECT_CONFIG_FILE" ] && is_subtask_type "$PROJECT_CONFIG_FILE" "$resolved_issue_type"; then
		if [ -z "$OPT_PARENT" ]; then
			error "issue type '$resolved_issue_type' requires --parent (a subtask type per the project config)"
			exit 1
		fi
		# --parent becomes a URL path segment in resolve_issue_type_of
		# below — shape-validate it FIRST, the same rule ticket keys already
		# follow everywhere else they reach a URL.
		validate_ticket_key "$OPT_PARENT" || { error "invalid parent ticket key: $OPT_PARENT"; exit 1; }
		parent_issue_type=$(resolve_issue_type_of "$OPT_PARENT")
		validate_subtask_parent_type "$PROJECT_CONFIG_FILE" "$parent_issue_type"
	fi

	create_fields_acc="$WORKDIR/create-fields.json"
	init_fields_accumulator "$create_fields_acc"

	merge_ref_field "$create_fields_acc" project key "$OPT_PROJECT"
	merge_ref_field "$create_fields_acc" issuetype name "$resolved_issue_type"
	merge_string_field "$create_fields_acc" summary "$OPT_TITLE"

	if [ -n "$OPT_DESCRIPTION_FILE" ]; then
		require_readable_file "$OPT_DESCRIPTION_FILE" "--description-file"
		description_adf_file=$(convert_markdown_file_to_adf "$OPT_DESCRIPTION_FILE")
		merge_json_field "$create_fields_acc" description "$description_adf_file"
	fi

	if [ -n "$OPT_ACCEPTANCE_FILE" ]; then
		# the usage-error (require_readable_file, exit 2) runs
		# BEFORE the precondition check (require_custom_field, exit 1) — a
		# bad file path is a caller typo and should surface first, same
		# ordering rule as the rest of this script (usage before preconditions).
		require_readable_file "$OPT_ACCEPTANCE_FILE" "--acceptance-file"
		acceptance_field_id=$(require_custom_field "$PROJECT_CONFIG_FILE" acceptance_criteria "--acceptance-file")
		acceptance_adf_file=$(convert_markdown_file_to_adf "$OPT_ACCEPTANCE_FILE")
		merge_json_field "$create_fields_acc" "$acceptance_field_id" "$acceptance_adf_file"
	fi

	if [ -n "$OPT_REVIEW_FILE" ]; then
		require_readable_file "$OPT_REVIEW_FILE" "--review-file"
		review_field_id=$(require_custom_field "$PROJECT_CONFIG_FILE" review_notes "--review-file")
		review_adf_file=$(convert_markdown_file_to_adf "$OPT_REVIEW_FILE")
		merge_json_field "$create_fields_acc" "$review_field_id" "$review_adf_file"
	fi

	if [ -n "$OPT_ASSIGNEE" ]; then
		assignee_account_id=$(resolve_account_id "$OPT_ASSIGNEE")
		merge_ref_field "$create_fields_acc" assignee id "$assignee_account_id"
	fi

	[ -z "$OPT_LABELS" ]   || merge_labels_field "$create_fields_acc" "$OPT_LABELS"
	[ -z "$OPT_DUE_DATE" ] || merge_string_field "$create_fields_acc" duedate "$OPT_DUE_DATE"
	[ -z "$OPT_PARENT" ]   || merge_ref_field "$create_fields_acc" parent key "$OPT_PARENT"

	# Attach flags resolve NAME -> id against the project's live version/
	# component lists (versions fetched once, components once) and merge
	# fixVersions/versions/components:[{id}]. OPT_PROJECT is the create target —
	# already shape-validated by try_load_project_config above before it reaches
	# a URL.
	merge_attach_flags "$create_fields_acc" "$OPT_PROJECT"

	create_request_file="$WORKDIR/create-request.json"
	jq -n --slurpfile fields "$create_fields_acc" '{fields: $fields[0]}' >"$create_request_file"

	create_url="https://${CONFIRMED_HOST}/rest/api/3/issue"
	jira_curl POST "$create_url" "$create_request_file"
	handle_http_status "$JIRA_HTTP_CODE" "create issue"
	require_json_body "create issue"
	# Hold onto the create's OWN 201 body (key/id/self) — jira_curl writes a
	# fresh file per call, so this path stays valid across the follow-up calls
	# below; the --json passthrough must return THIS body, not a later one.
	create_response_body=$JIRA_HTTP_BODY_FILE
	created_key=$(jq -r '.key // ""' "$create_response_body" | strip_control_ansi)
	# created_key becomes a URL path segment in EVERY use below (the inline-image
	# upload URL inside resolve_inline_images, the description-update URL, and the
	# browse URL) — shape-validate it HERE, right after it is extracted from the
	# 201 body and BEFORE the first such use, the same validate-before-URL
	# invariant the comment/update call sites enforce on their up-front TICKET_KEY.
	validate_ticket_key "$created_key" || {
		error "internal: created issue key is not a valid ticket key: $created_key"
		exit 1
	}

	# --- Inline images: the 2-STEP ordering. An attachment upload needs a live
	# issue, so the description above was converted and sent WITHOUT media (an
	# empty map). Now the issue EXISTS: run the pre-pass against the new key
	# and, only if it found inline images, re-convert the description WITH the
	# media map and PUT it back. Net effect: one create + (only when inline
	# images are present) exactly one follow-up description update. With no
	# inline images this block makes ZERO extra calls — identical to before. ---
	if [ -n "$OPT_DESCRIPTION_FILE" ]; then
		create_media_map=$(resolve_inline_images "$created_key" "$OPT_DESCRIPTION_FILE")
		if media_map_has_entries "$create_media_map"; then
			create_media_desc_file=$(convert_markdown_file_to_adf "$OPT_DESCRIPTION_FILE" "$create_media_map")
			create_desc_update_acc="$WORKDIR/create-desc-update-fields.json"
			init_fields_accumulator "$create_desc_update_acc"
			merge_json_field "$create_desc_update_acc" description "$create_media_desc_file"
			create_desc_update_req="$WORKDIR/create-desc-update-request.json"
			jq -n --slurpfile fields "$create_desc_update_acc" '{fields: $fields[0]}' >"$create_desc_update_req"
			create_desc_update_url="https://${CONFIRMED_HOST}/rest/api/3/issue/${created_key}"
			jira_curl PUT "$create_desc_update_url" "$create_desc_update_req"
			handle_http_status "$JIRA_HTTP_CODE" "update description with inline images on $created_key"
			# PUT /issue returns 204 No Content — no require_json_body here.
		fi
	fi

	if [ "$OPT_JSON" -eq 1 ]; then
		# PASSTHROUGH, not synthesized — Jira's own 201 response
		# body (key/id/self) IS the answer; there is nothing this script
		# could usefully re-derive, unlike update's --json (see cmd_update).
		cat "$create_response_body"
		return 0
	fi
	printf 'JIRA_ISSUE_KEY=%s\n' "$created_key"
	printf 'JIRA_ISSUE_URL=https://%s/browse/%s\n' "$CONFIRMED_HOST" "$created_key"
}

# validate_create_args() — `create`'s per-command argument validation, called by
# jira.sh BEFORE any tool/site/credential check so a caller's own typo
# surfaces as a usage error (exit 2) first.
validate_create_args() {
	[ -n "$OPT_PROJECT" ] || { usage >&2; error "create requires --project"; exit 2; }
	[ -n "$OPT_TITLE" ]   || { usage >&2; error "create requires --title"; exit 2; }
	return 0
}
