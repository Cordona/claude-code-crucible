# shellcheck shell=sh
#
# cmd-component.sh — `component`: project components. Exactly ONE mode of
#                    --list/--create/--update/--delete; --delete optionally
#                    reassigns the component's issues via --move-issues-to.
#
# Sourced by jira.sh — never executed directly. Sets no shell options and
# runs no top-level work beyond its own declarations, so sourcing it always
# returns 0 under `set -e`.

# ---------------------------------------------------------------------------
# component — project components (POST/PUT/DELETE /rest/api/3/component,
# GET /rest/api/3/project/<KEY>/components). Mode selected by exactly ONE of
# --list/--create/--update/--delete (validated up front).
# ---------------------------------------------------------------------------

# render_components_human BODY_FILE — one line per component. BODY is a PLAIN
# JSON ARRAY (empty `[]` is valid) — verified against live Jira.
render_components_human() {
	components_body_file=$1
	component_count=$(jq 'length' "$components_body_file")
	if [ "$component_count" -eq 0 ]; then
		printf 'No components.\n'
		return 0
	fi
	printf 'Components:\n'
	# Same delimiter-injection-proof idiom as render_versions_human /
	# render_search_human — one compact JSON object per line, each field
	# extracted independently by jq, never an IFS=<tab> split that a name
	# carrying a literal tab/newline would break (strip_control_ansi strips
	# neither byte).
	jq -c '.[]' "$components_body_file" | while IFS= read -r component_line; do
		c_name=$(printf '%s' "$component_line" | jq -r '.name // ""' | strip_control_ansi)
		c_id=$(printf '%s' "$component_line" | jq -r '.id // ""' | strip_control_ansi)
		printf '  %s (id %s)\n' "$c_name" "$c_id"
	done
}

cmd_component() {
	# Mode (exactly one of --list/--create/--update/--delete), --project/--name
	# presence, --id / --move-issues-to numeric shape, and "--move-issues-to
	# only with --delete" are validated up front — see the per-command block.
	ensure_workdir

	if [ "$OPT_LIST" -eq 1 ]; then
		components_url="https://${CONFIRMED_HOST}/rest/api/3/project/${OPT_PROJECT}/components"
		jira_curl GET "$components_url"
		handle_http_status "$JIRA_HTTP_CODE" "list components for $OPT_PROJECT"
		require_json_body "list components for $OPT_PROJECT"
		if [ "$OPT_JSON" -eq 1 ]; then
			cat "$JIRA_HTTP_BODY_FILE"
			return 0
		fi
		render_components_human "$JIRA_HTTP_BODY_FILE"
		return 0
	fi

	if [ "$OPT_CREATE" -eq 1 ]; then
		component_create_body="$WORKDIR/component-create.json"
		init_fields_accumulator "$component_create_body"
		merge_string_field "$component_create_body" project "$OPT_PROJECT"
		merge_string_field "$component_create_body" name "$OPT_NAME"
		[ -z "$OPT_DESCRIPTION" ]     || merge_string_field "$component_create_body" description "$OPT_DESCRIPTION"
		[ -z "$OPT_LEAD_ACCOUNT_ID" ] || merge_string_field "$component_create_body" leadAccountId "$OPT_LEAD_ACCOUNT_ID"
		create_component_url="https://${CONFIRMED_HOST}/rest/api/3/component"
		jira_curl POST "$create_component_url" "$component_create_body"
		handle_http_status "$JIRA_HTTP_CODE" "create component"
		require_json_body "create component"
		if [ "$OPT_JSON" -eq 1 ]; then
			cat "$JIRA_HTTP_BODY_FILE"
			return 0
		fi
		created_component_id=$(jq -r '.id // ""' "$JIRA_HTTP_BODY_FILE" | strip_control_ansi)
		created_component_name=$(jq -r '.name // ""' "$JIRA_HTTP_BODY_FILE" | strip_control_ansi)
		printf 'JIRA_COMPONENT_ID=%s\n' "$created_component_id"
		printf 'JIRA_COMPONENT_NAME=%s\n' "$created_component_name"
		return 0
	fi

	if [ "$OPT_UPDATE" -eq 1 ]; then
		component_update_body="$WORKDIR/component-update.json"
		init_fields_accumulator "$component_update_body"
		[ -z "$OPT_NAME" ]            || merge_string_field "$component_update_body" name "$OPT_NAME"
		[ -z "$OPT_DESCRIPTION" ]     || merge_string_field "$component_update_body" description "$OPT_DESCRIPTION"
		[ -z "$OPT_LEAD_ACCOUNT_ID" ] || merge_string_field "$component_update_body" leadAccountId "$OPT_LEAD_ACCOUNT_ID"
		update_component_url="https://${CONFIRMED_HOST}/rest/api/3/component/${OPT_ID}"
		jira_curl PUT "$update_component_url" "$component_update_body"
		handle_http_status "$JIRA_HTTP_CODE" "update component $OPT_ID"
		require_json_body "update component $OPT_ID"
		if [ "$OPT_JSON" -eq 1 ]; then
			cat "$JIRA_HTTP_BODY_FILE"
			return 0
		fi
		updated_component_id=$(jq -r '.id // ""' "$JIRA_HTTP_BODY_FILE" | strip_control_ansi)
		updated_component_name=$(jq -r '.name // ""' "$JIRA_HTTP_BODY_FILE" | strip_control_ansi)
		printf 'JIRA_COMPONENT_ID=%s\n' "$updated_component_id"
		printf 'JIRA_COMPONENT_NAME=%s\n' "$updated_component_name"
		return 0
	fi

	# delete — DELETE /component/<id> with an OPTIONAL ?moveIssuesTo=<id2> to
	# reassign the component's issues. Both ids are numeric-validated up front;
	# moveIssuesTo is urlencode()'d into the query the same way watch --remove
	# encodes its accountId (belt-and-braces even for a digits-only value).
	delete_component_url="https://${CONFIRMED_HOST}/rest/api/3/component/${OPT_ID}"
	if [ -n "$OPT_MOVE_ISSUES_TO" ]; then
		encoded_move_target=$(urlencode "$OPT_MOVE_ISSUES_TO")
		delete_component_url="${delete_component_url}?moveIssuesTo=${encoded_move_target}"
	fi
	jira_curl DELETE "$delete_component_url"
	handle_http_status "$JIRA_HTTP_CODE" "delete component $OPT_ID"
	# DELETE /component returns 204 No Content — no require_json_body call.
	if [ "$OPT_JSON" -eq 1 ]; then
		# SYNTHESIZED — no 204 body to pass through (same as cmd_update's --json).
		jq -n --arg id "$OPT_ID" '{id: $id, deleted: true}'
	else
		printf 'JIRA_COMPONENT_DELETED=%s\n' "$OPT_ID"
	fi
}

# validate_component_args() — `component`'s per-command argument validation, called by
# jira.sh BEFORE any tool/site/credential check so a caller's own typo
# surfaces as a usage error (exit 2) first.
validate_component_args() {
	if [ -n "$TICKET_KEY" ]; then
		usage >&2
		error "component takes no positional argument, got: $TICKET_KEY"
		exit 2
	fi
	# --release/--archive are VERSION modes, not component modes. Without
	# this, `component --list --release` would count exactly one OWN
	# component mode (--list) and silently run the list, ignoring the
	# foreign --release. Reject by name, and fold both commands' mode flags
	# into the exactly-one count for defense in depth.
	if [ "$OPT_RELEASE" -eq 1 ] || [ "$OPT_ARCHIVE" -eq 1 ]; then
		usage >&2
		error "--release/--archive are not component modes (did you mean 'version --release/--archive'?)"
		exit 2
	fi
	component_mode_count=$((OPT_LIST + OPT_CREATE + OPT_UPDATE + OPT_DELETE + OPT_RELEASE + OPT_ARCHIVE))
	if [ "$component_mode_count" -ne 1 ]; then
		usage >&2
		error "component requires exactly one mode: --list, --create, --update, or --delete"
		exit 2
	fi
	if [ "$OPT_LIST" -eq 1 ] || [ "$OPT_CREATE" -eq 1 ]; then
		[ -n "$OPT_PROJECT" ] || { usage >&2; error "component --list/--create requires --project"; exit 2; }
		validate_project_key "$OPT_PROJECT" || { usage >&2; error "invalid project key: $OPT_PROJECT"; exit 2; }
	fi
	if [ "$OPT_CREATE" -eq 1 ]; then
		[ -n "$OPT_NAME" ] || { usage >&2; error "component --create requires --name"; exit 2; }
	fi
	if [ "$OPT_UPDATE" -eq 1 ] || [ "$OPT_DELETE" -eq 1 ]; then
		[ -n "$OPT_ID" ] || { usage >&2; error "component --update/--delete requires --id"; exit 2; }
		validate_numeric_id "$OPT_ID" || { usage >&2; error "invalid --id (must be a numeric component id): $OPT_ID"; exit 2; }
	fi
	if [ "$OPT_UPDATE" -eq 1 ]; then
		if [ -z "$OPT_NAME" ] && [ -z "$OPT_DESCRIPTION" ] && [ -z "$OPT_LEAD_ACCOUNT_ID" ]; then
			usage >&2
			error "component --update requires at least one field to change (--name/--description/--lead-account-id)"
			exit 2
		fi
		# --project NAMES the project in exactly two of this command's four
		# modes (--list/--create). --update addresses the component by --id
		# alone and never reads it, so an unguarded --project here is SILENTLY
		# dropped: `component --update --id N --project WRONGKEY` would exit 0
		# having edited whatever project's component N actually belongs to,
		# with the scope the caller stated never checked against anything.
		# Same silently-ignored-scope shape the --delete branch below already
		# rejects, and the same guard `version --update/--release/--archive`
		# carries for the identical reason.
		require_foreign_flag_unset --project "$OPT_PROJECT" "component --list/--create"
	fi
	# `version --delete`'s two pre-write safety nets are NOT implemented here,
	# and this command is destructive, so both flags must fail loud rather than
	# be silently ignored — the same destructive-and-silent shape the
	# --move-*-issues-to guards below close, on flags whose whole POINT is
	# safety:
	#   --plan/--dry-run  a caller who believes they asked for a preview and
	#                     instead gets a REAL, irreversible delete is the worst
	#                     outcome this file can produce. Rejected before any
	#                     network call.
	#   --project         `version --delete`'s ownership cross-check. A
	#                     component id is already project-scoped by the API, so
	#                     there is nothing to cross-check — but --project IS a
	#                     component flag (--list/--create take it), so the
	#                     diagnostic names those modes rather than another
	#                     command.
	if [ "$OPT_DELETE" -eq 1 ]; then
		require_flag_off --plan/--dry-run "$OPT_PLAN" "version --delete among the delete commands — component --delete would delete for REAL"
		require_foreign_flag_unset --project "$OPT_PROJECT" "component --list/--create"
	fi
	# The reassignment target is optional, and carries the SAME rule set as
	# version --delete's own two (delete-only + a numeric id of this command's
	# entity kind) — require_delete_move_target carries it for all three, and
	# takes the flag/command/id-kind so every diagnostic reads exactly as it
	# did when this block was spelled out here.
	[ -z "$OPT_MOVE_ISSUES_TO" ] || require_delete_move_target --move-issues-to "$OPT_MOVE_ISSUES_TO" "component --delete" component
	# --move-fix-issues-to/--move-affected-issues-to are VERSION --delete
	# flags, and the mirror image of validate_version_args' rejection of this
	# command's --move-issues-to. Without these, `component --delete --id N
	# --move-fix-issues-to M` would exit 0 having deleted the component and
	# SILENTLY dropped the reassignment the caller asked for — the shared
	# OPT_* carriers mean cmd_component simply never reads either flag.
	# Destructive + silent is the one combination that must fail loud.
	require_foreign_flag_unset --move-fix-issues-to "$OPT_MOVE_FIX_ISSUES_TO" "version --delete"
	require_foreign_flag_unset --move-affected-issues-to "$OPT_MOVE_AFFECTED_ISSUES_TO" "version --delete"
	return 0
}
