# shellcheck shell=sh
#
# cmd-update.sh — `update <KEY>`: PUT /issue with only the fields the caller
#                 named, including the --append-file path (fetch the existing
#                 description -> extend its content array -> replace the whole
#                 doc).
#
# Sourced by jira.sh — never executed directly. Sets no shell options and
# runs no top-level work beyond its own declarations, so sourcing it always
# returns 0 under `set -e`.

# ---------------------------------------------------------------------------
# update — PUT /rest/api/3/issue/<KEY>
# ---------------------------------------------------------------------------

# build_appended_description TICKET_KEY APPEND_MARKDOWN_FILE -> prints the
# path to a NEW ADF file whose content is the issue's EXISTING description's
# content array with the newly-converted markdown's blocks appended after it
# (matches the oracle's fetch-existing -> extend -> replace-whole-doc
# behavior for --append-file).
#
# localId UNIQUENESS ACROSS THE MERGE (the one thing this does beyond
# concatenating). ADF requires a taskList/taskItem localId to be unique WITHIN
# THE DOCUMENT, and md-to-adf.sh's counter — correctly, for a document it
# converts whole — restarts at 1 on every invocation. Appending is the one
# place where TWO independently-converted documents become ONE: if the stored
# description already holds a tool-generated checklist, its taskList-1/
# taskItem-1 meet the fresh conversion's taskList-1/taskItem-1 and the merged
# doc ships DUPLICATE localIds. So the appended blocks are RENUMBERED here, to
# continue above the highest id already present in the stored content, rather
# than salting md-to-adf.sh's counter per invocation (which would make a pure,
# deterministic converter's output depend on the process it ran in, for a
# uniqueness rule that is scoped to the document either way).
#
# The three jq helpers below implement exactly that, and nothing about them
# needs a regex (this engine keeps its jq Oniguruma-free — see jira.sh's
# Portability header):
#   * an id PARTICIPATES only if it splits on "-" into exactly TWO parts whose
#     second is 1..12 ASCII digits ("taskItem-7"). That is the shape
#     md-to-adf.sh's next_task_local_id mints, for ANY prefix it may grow later,
#     and it structurally excludes the 5-part UUID localIds Jira's own editor
#     writes — which therefore need no shifting, since a UUID cannot collide
#     with a "<prefix>-<n>" id in the first place.
#
#     The 12-DIGIT CEILING is a correctness guard, not tidiness. jq's numbers
#     are IEEE doubles, so a stored suffix past 2^53 loses integer precision:
#     with a 20-digit suffix as the offset, ($seq + $by) ROUNDS TO THE SAME
#     double for $seq = 1, 2, 3, ..., every appended id renders as the
#     identical "taskItem-1e+20", and the merged doc ships the very duplicate
#     localIds this whole transform exists to prevent — silently, with no jq
#     error. 12 sits far below the 2^53 boundary, so every participating
#     suffix — and every shifted result — stays exactly representable.
#
#     Excluding a 13+-digit stored suffix from max_local_id is safe IN
#     PRACTICE rather than by construction, and the honest version of that
#     argument is worth stating: the offset is bounded by 10^12, and
#     md-to-adf.sh's counter is a per-invocation sequence that mints only a
#     few digits, so no id this converter produces can shift onto an excluded
#     one. A HAND-AUTHORED description could still be built to collide exactly
#     at the boundary — a stored "taskItem-999999999999" (12 digits, so it
#     participates and sets the offset) beside a stored "taskItem-1000000000000"
#     (13 digits, excluded) shifts a freshly appended "taskItem-1" onto that
#     excluded id — but that takes ADF posted through the raw API, never
#     content this tool writes. Tightening the ceiling would not close the
#     class, only move it (a 9-digit ceiling collides at 10 digits the same
#     way), so 12 stays: it is chosen for the precision bound it really does
#     enforce.
#   * the offset is the MAXIMUM participating suffix in the stored content (0
#     when there is none, which makes the whole transform a no-op — the
#     overwhelmingly common case, since most descriptions hold no checklist).
#   * every appended id keeps its own prefix and gains that offset. Within the
#     new document the suffixes are already distinct (one shared counter feeds
#     both prefixes), and shifting them all by the same amount preserves that
#     while lifting every one of them above every stored id.
build_appended_description() {
	append_ticket_key=$1
	append_markdown_file=$2
	append_media_map=${3:-}

	existing_desc_url="https://${CONFIRMED_HOST}/rest/api/3/issue/${append_ticket_key}?fields=description"
	jira_curl GET "$existing_desc_url"
	handle_http_status "$JIRA_HTTP_CODE" "fetch existing description for $append_ticket_key"
	require_json_body "fetch existing description for $append_ticket_key"
	existing_description_file=$JIRA_HTTP_BODY_FILE

	appended_adf_file=$(convert_markdown_file_to_adf "$append_markdown_file" "$append_media_map")

	ensure_workdir
	APPEND_COUNTER=$((APPEND_COUNTER + 1))
	merged_description_file="$WORKDIR/appended-description-$APPEND_COUNTER.json"
	append_err_file="$WORKDIR/appended-description-$APPEND_COUNTER.err"
	# Guard: if the existing description's .content isn't an array (an
	# unexpected Jira response shape), `.content += [...]` would otherwise
	# fail OPAQUELY under set -e with a raw jq type error. jq's own error()
	# turns that into a clean, named failure this script reports itself.
	if ! jq -c --slurpfile new_content "$appended_adf_file" \
		'def local_id_seq:
		   split("-") as $parts
		   | if ($parts | length) == 2 and ($parts[1] | length) > 0
		        and ($parts[1] | length) <= 12
		        and ($parts[1] | explode | all(. >= 48 and . <= 57))
		     then ($parts[1] | tonumber)
		     else 0
		     end;
		 def max_local_id:
		   [ .. | objects | select(has("attrs"))
		        | .attrs | objects | select(has("localId"))
		        | .localId | strings | local_id_seq ]
		   | max // 0;
		 def offset_local_ids($by):
		   if $by == 0 then . else
		     walk(
		       if type == "object" then
		         if has("attrs") and (.attrs | type) == "object"
		            and (.attrs | has("localId")) and (.attrs.localId | type) == "string"
		         then
		           (.attrs.localId | local_id_seq) as $seq
		           | if $seq == 0 then .
		             else .attrs.localId = ((.attrs.localId | split("-") | .[0])
		                                    + "-" + (($seq + $by) | tostring))
		             end
		         else . end
		       else . end)
		   end;
		 (.fields.description // {type: "doc", version: 1, content: []}) as $existing
		 | if ($existing.content | type) != "array" then
		     error("existing description.content is not an array")
		   else
		     $existing
		     | .content += ($new_content[0]
		                    | offset_local_ids($existing | max_local_id)
		                    | .content)
		   end' \
		"$existing_description_file" >"$merged_description_file" 2>"$append_err_file"; then
		error "could not append to the existing description for $append_ticket_key: unexpected response shape"
		sed 's/^/  /' "$append_err_file" >&2 2>/dev/null || true
		exit 1
	fi
	printf '%s' "$merged_description_file"
}

cmd_update() {
	# TICKET_KEY presence, the --description-file/--append-file mutual
	# exclusivity, and "at least one field" are validated up front — see the
	# main dispatch section's per-command required-argument validation.
	load_config_for_ticket_key "$TICKET_KEY"

	ensure_workdir
	update_fields_acc="$WORKDIR/update-fields.json"
	init_fields_accumulator "$update_fields_acc"

	[ -z "$OPT_TITLE" ] || merge_string_field "$update_fields_acc" summary "$OPT_TITLE"

	if [ -n "$OPT_APPEND_FILE" ]; then
		require_readable_file "$OPT_APPEND_FILE" "--append-file"
		# Inline images in the appended markdown are uploaded + resolved, then
		# their media blocks append into the built description.
		append_media_map=$(resolve_inline_images "$TICKET_KEY" "$OPT_APPEND_FILE")
		appended_description_file=$(build_appended_description "$TICKET_KEY" "$OPT_APPEND_FILE" "$append_media_map")
		merge_json_field "$update_fields_acc" description "$appended_description_file"
	elif [ -n "$OPT_DESCRIPTION_FILE" ]; then
		require_readable_file "$OPT_DESCRIPTION_FILE" "--description-file"
		description_media_map=$(resolve_inline_images "$TICKET_KEY" "$OPT_DESCRIPTION_FILE")
		description_adf_file=$(convert_markdown_file_to_adf "$OPT_DESCRIPTION_FILE" "$description_media_map")
		merge_json_field "$update_fields_acc" description "$description_adf_file"
	fi

	if [ -n "$OPT_ACCEPTANCE_FILE" ]; then
		# usage error (require_readable_file, exit 2) before the
		# precondition check (require_custom_field, exit 1) — same ordering
		# fix as cmd_create's identical pair.
		require_readable_file "$OPT_ACCEPTANCE_FILE" "--acceptance-file"
		acceptance_field_id=$(require_custom_field "$PROJECT_CONFIG_FILE" acceptance_criteria "--acceptance-file")
		acceptance_adf_file=$(convert_markdown_file_to_adf "$OPT_ACCEPTANCE_FILE")
		merge_json_field "$update_fields_acc" "$acceptance_field_id" "$acceptance_adf_file"
	fi

	if [ -n "$OPT_REVIEW_FILE" ]; then
		require_readable_file "$OPT_REVIEW_FILE" "--review-file"
		review_field_id=$(require_custom_field "$PROJECT_CONFIG_FILE" review_notes "--review-file")
		review_adf_file=$(convert_markdown_file_to_adf "$OPT_REVIEW_FILE")
		merge_json_field "$update_fields_acc" "$review_field_id" "$review_adf_file"
	fi

	if [ -n "$OPT_ASSIGNEE" ]; then
		assignee_account_id=$(resolve_account_id "$OPT_ASSIGNEE")
		merge_ref_field "$update_fields_acc" assignee id "$assignee_account_id"
	fi

	if [ -n "$OPT_DEVELOPER" ]; then
		developer_field_id=$(require_custom_field "$PROJECT_CONFIG_FILE" developer "--developer")
		developer_account_id=$(resolve_account_id "$OPT_DEVELOPER")
		merge_ref_field "$update_fields_acc" "$developer_field_id" accountId "$developer_account_id"
	fi

	if [ -n "$OPT_LABELS" ]; then
		# Data-loss surprise guard: REST v3's fields.labels REPLACES the
		# whole array (the correct semantics — see merge_labels_field's own
		# header note on why this deliberately diverges from the oracle's
		# ACLI-only partial "labelsToAdd"), so a caller updating one
		# unrelated field who also happens to pass --labels would otherwise
		# silently drop every existing label not repeated here.
		warn "--labels replaces ALL labels on $TICKET_KEY; existing labels not listed here will be removed"
		merge_labels_field "$update_fields_acc" "$OPT_LABELS"
	fi
	[ -z "$OPT_DUE_DATE" ] || merge_string_field "$update_fields_acc" duedate "$OPT_DUE_DATE"
	if [ -n "$OPT_PARENT" ]; then
		# --parent is a ticket-key reference; shape-validate it
		# the same as everywhere else a ticket key is used (this one never
		# reaches a URL — only a JSON value via merge_ref_field — but is
		# validated for consistency with create's identical flag, and to
		# reject a nonsensical value before spending a round-trip on it).
		validate_ticket_key "$OPT_PARENT" || { error "invalid parent ticket key: $OPT_PARENT"; exit 1; }
		merge_ref_field "$update_fields_acc" parent key "$OPT_PARENT"
	fi
	# Opt-in only, unvalidated locally — the project's own priority scheme is the
	# source of truth; see cmd_create's identical call for the full reasoning.
	# Placed AFTER --parent to keep create's and update's field order identical
	# (assignee -> labels -> due-date -> parent -> priority -> attach), which is
	# also the order update_field_summary and jira.sh's own OPT declarations
	# list them in.
	[ -z "$OPT_PRIORITY" ] || merge_ref_field "$update_fields_acc" priority name "$OPT_PRIORITY"

	# Attach flags — same NAME -> id resolution as create, but the project is
	# derived from the ticket key being updated (TICKET_KEY is shape-validated
	# up front, so its extracted project prefix is a safe URL path segment).
	if [ -n "$OPT_FIX_VERSIONS" ] || [ -n "$OPT_AFFECTS_VERSIONS" ] || [ -n "$OPT_COMPONENTS" ]; then
		update_project=$(extract_project_from_key "$TICKET_KEY")
		merge_attach_flags "$update_fields_acc" "$update_project"
	fi

	update_request_file="$WORKDIR/update-request.json"
	jq -n --slurpfile fields "$update_fields_acc" '{fields: $fields[0]}' >"$update_request_file"

	update_url="https://${CONFIRMED_HOST}/rest/api/3/issue/${TICKET_KEY}"
	jira_curl PUT "$update_url" "$update_request_file"
	handle_http_status "$JIRA_HTTP_CODE" "update $TICKET_KEY"
	# PUT /issue returns 204 No Content on success — deliberately NO
	# require_json_body call here, same reasoning as execute_plain_transition.

	if [ "$OPT_JSON" -eq 1 ]; then
		# SYNTHESIZED, not passthrough — the PUT response has no
		# body (204) to pass through, so --json here summarizes the fields
		# THIS invocation just sent, not anything Jira returned.
		jq -n --slurpfile fields "$update_fields_acc" --arg key "$TICKET_KEY" \
			'{key: $key, updatedFields: ($fields[0] | keys)}'
	else
		printf 'JIRA_UPDATED=%s\n' "$TICKET_KEY"
	fi
}

# update_field_summary -> a space-joined list of the update aspects the caller
# asked to change ("assignee labels priority"), or the empty string when they
# named none. It is the SINGLE SOURCE OF TRUTH for which fields the update verb
# can change, and has two consumers, both of which derive from it rather than
# re-enumerating the set: cmd-bulk.sh's bulk_intent_phrase (the --plan
# disclosure a consent gate reads) and has_update_field_request below (the
# at-least-one-field guard behind both `update` and `bulk --op update`).
#
# WHY IT IS ONE FUNCTION AND NOT THREE LISTS. The set used to be enumerated in
# all three places, byte-identically, with nothing enforcing that; adding
# --priority meant editing all three, and the --plan copy is the one whose
# omission fails SILENTLY — the gate would disclose a write it never names.
# Deriving both the guard and the disclosure from one list makes a forgotten
# field impossible rather than merely unlikely.
#
# It lives HERE, beside the verb that owns the fields, and is purely
# descriptive: it reads only the OPT_* carriers and never touches the network.
update_field_summary() {
	ufs_fields=""
	[ -z "$OPT_TITLE" ]            || ufs_fields="$ufs_fields title"
	[ -z "$OPT_DESCRIPTION_FILE" ] || ufs_fields="$ufs_fields description"
	[ -z "$OPT_APPEND_FILE" ]      || ufs_fields="$ufs_fields description(append)"
	[ -z "$OPT_ACCEPTANCE_FILE" ]  || ufs_fields="$ufs_fields acceptance"
	[ -z "$OPT_REVIEW_FILE" ]      || ufs_fields="$ufs_fields review"
	[ -z "$OPT_ASSIGNEE" ]         || ufs_fields="$ufs_fields assignee"
	[ -z "$OPT_DEVELOPER" ]        || ufs_fields="$ufs_fields developer"
	[ -z "$OPT_LABELS" ]           || ufs_fields="$ufs_fields labels"
	[ -z "$OPT_DUE_DATE" ]         || ufs_fields="$ufs_fields due-date"
	[ -z "$OPT_PARENT" ]           || ufs_fields="$ufs_fields parent"
	[ -z "$OPT_PRIORITY" ]         || ufs_fields="$ufs_fields priority"
	[ -z "$OPT_FIX_VERSIONS" ]     || ufs_fields="$ufs_fields fix-version"
	[ -z "$OPT_AFFECTS_VERSIONS" ] || ufs_fields="$ufs_fields affects-version"
	[ -z "$OPT_COMPONENTS" ]       || ufs_fields="$ufs_fields component"
	# strip the single leading space
	printf '%s' "${ufs_fields# }"
}

# has_update_field_request -> 0 if the caller named at least one updatable
# field, 1 if none — which is exactly "the summary above is non-empty", so the
# predicate carries no field list of its own to drift from it.
has_update_field_request() {
	[ -n "$(update_field_summary)" ]
}

# validate_update_args() — `update`'s per-command argument validation, called by
# jira.sh BEFORE any tool/site/credential check so a caller's own typo
# surfaces as a usage error (exit 2) first.
validate_update_args() {
	require_ticket_positional update
	if [ -n "$OPT_DESCRIPTION_FILE" ] && [ -n "$OPT_APPEND_FILE" ]; then
		usage >&2
		error "--description-file and --append-file are mutually exclusive"
		exit 2
	fi
	if ! has_update_field_request; then
		usage >&2
		error "update requires at least one field to change"
		exit 2
	fi
	return 0
}
