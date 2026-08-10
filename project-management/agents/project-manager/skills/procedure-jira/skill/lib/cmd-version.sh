# shellcheck shell=sh
#
# cmd-version.sh — `version`: project versions/releases. Exactly ONE mode of
#                  --list/--create/--update/--release/--archive/--delete;
#                  --delete optionally reassigns the deleted version's issue
#                  references via --move-fix-issues-to/--move-affected-issues-to,
#                  previews itself with --plan/--dry-run, and can be pinned to
#                  an expected owner with --project KEY (both opt-in, both
#                  read-only — see the delete branch's own note).
#
# The /version body is FLAT (no fields{} wrapper) and `project` is the project
# KEY STRING — a numeric projectId is rejected by the API.
#
# Sourced by jira.sh — never executed directly. Sets no shell options and
# runs no top-level work beyond its own declarations, so sourcing it always
# returns 0 under `set -e`.

# ---------------------------------------------------------------------------
# version — project versions/releases (POST/PUT/DELETE /rest/api/3/version,
# GET /rest/api/3/project/<KEY>/versions). Mode selected by exactly ONE of
# --list/--create/--update/--release/--archive/--delete (validated up front).
# ---------------------------------------------------------------------------

# render_versions_human BODY_FILE — one line per version. BODY is a PLAIN JSON
# ARRAY (NOT a paginated {values:[...]} envelope) — verified against live Jira.
render_versions_human() {
	versions_body_file=$1
	version_count=$(jq 'length' "$versions_body_file")
	if [ "$version_count" -eq 0 ]; then
		printf 'No versions.\n'
		return 0
	fi
	printf 'Versions:\n'
	# Emit ONE compact JSON object per line (jq -c escapes any tab or newline
	# inside a version NAME as \t/\n, so a name authored by another Jira user
	# can never split a row or misalign a column) and extract each field
	# INDEPENDENTLY with jq — the same delimiter-injection-proof idiom
	# render_search_human uses. A plain `IFS=<tab> read` split would be unsafe:
	# strip_control_ansi runs AFTER the split and removes neither tab (\011)
	# nor newline (\012), so a name carrying either byte would break parsing.
	jq -c '.[]' "$versions_body_file" | while IFS= read -r version_line; do
		v_name=$(printf '%s' "$version_line" | jq -r '.name // ""' | strip_control_ansi)
		v_id=$(printf '%s' "$version_line" | jq -r '.id // ""' | strip_control_ansi)
		v_released=$(printf '%s' "$version_line" | jq -r '.released // false' | strip_control_ansi)
		printf '  %s (id %s, released %s)\n' "$v_name" "$v_id" "$v_released"
	done
}

# build_version_write_body OUT_FILE — builds the FLAT /version body for the
# active mode (create vs update/release/archive) into OUT_FILE. `project` is
# the project KEY STRING (verified live: a numeric projectId is REJECTED — the
# API reads only the `project` key field). Every value enters jq via
# --arg/--argjson in a static merge program; nothing is concatenated.
build_version_write_body() {
	bvw_out_file=$1
	init_fields_accumulator "$bvw_out_file"
	if [ "$OPT_CREATE" -eq 1 ]; then
		merge_string_field "$bvw_out_file" project "$OPT_PROJECT"
		merge_string_field "$bvw_out_file" name "$OPT_NAME"
		[ -z "$OPT_DESCRIPTION" ]  || merge_string_field "$bvw_out_file" description "$OPT_DESCRIPTION"
		[ -z "$OPT_RELEASE_DATE" ] || merge_string_field "$bvw_out_file" releaseDate "$OPT_RELEASE_DATE"
		[ -z "$OPT_START_DATE" ]   || merge_string_field "$bvw_out_file" startDate "$OPT_START_DATE"
		if [ "$OPT_RELEASED" -eq 1 ]; then merge_bool_field "$bvw_out_file" released true; fi
	elif [ "$OPT_UPDATE" -eq 1 ]; then
		[ -z "$OPT_NAME" ]         || merge_string_field "$bvw_out_file" name "$OPT_NAME"
		[ -z "$OPT_DESCRIPTION" ]  || merge_string_field "$bvw_out_file" description "$OPT_DESCRIPTION"
		[ -z "$OPT_RELEASE_DATE" ] || merge_string_field "$bvw_out_file" releaseDate "$OPT_RELEASE_DATE"
		[ -z "$OPT_START_DATE" ]   || merge_string_field "$bvw_out_file" startDate "$OPT_START_DATE"
	elif [ "$OPT_RELEASE" -eq 1 ]; then
		merge_bool_field "$bvw_out_file" released true
		[ -z "$OPT_RELEASE_DATE" ] || merge_string_field "$bvw_out_file" releaseDate "$OPT_RELEASE_DATE"
	elif [ "$OPT_ARCHIVE" -eq 1 ]; then
		merge_bool_field "$bvw_out_file" archived true
	fi
}

# resolve_version_owner ID — publishes the version's own identity as
# $VERSION_OWNER_NAME + $VERSION_OWNER_PROJECT_KEY, via TWO read-only GETs and
# no write at all. It backs both of `--delete`'s pre-write safety features
# (--plan's disclosure and --project's cross-check), so the read happens ONCE
# per invocation however many of them are in play.
#
# TWO calls because Jira's `GET /version/<id>` reports the owning project as a
# numeric `projectId` ONLY — never its key — so the key a human actually reads
# and passes to --project comes from a second `GET /project/<projectId>`.
# That id is API-SOURCED and becomes a URL path segment, so it goes through the
# SAME validate_numeric_id gate a caller-supplied id does (an unverifiable
# owner fails closed, exit 1, rather than being interpolated unchecked or
# quietly reported as "unknown" — this whole path exists to make a delete
# safer, so it must never degrade into a softer answer).
VERSION_OWNER_NAME=""
VERSION_OWNER_PROJECT_KEY=""
resolve_version_owner() {
	rvo_version_id=$1
	rvo_version_url="https://${CONFIRMED_HOST}/rest/api/3/version/${rvo_version_id}"
	jira_curl GET "$rvo_version_url"
	handle_http_status "$JIRA_HTTP_CODE" "fetch version $rvo_version_id"
	require_json_body "fetch version $rvo_version_id"
	VERSION_OWNER_NAME=$(jq -r '.name // ""' "$JIRA_HTTP_BODY_FILE" | strip_control_ansi)
	rvo_project_id=$(jq -r '.projectId // ""' "$JIRA_HTTP_BODY_FILE")
	if ! validate_numeric_id "$rvo_project_id"; then
		error "could not determine which project version $rvo_version_id belongs to (no usable projectId in the response)"
		exit 1
	fi
	rvo_project_url="https://${CONFIRMED_HOST}/rest/api/3/project/${rvo_project_id}"
	jira_curl GET "$rvo_project_url"
	handle_http_status "$JIRA_HTTP_CODE" "fetch project $rvo_project_id"
	require_json_body "fetch project $rvo_project_id"
	VERSION_OWNER_PROJECT_KEY=$(jq -r '.key // ""' "$JIRA_HTTP_BODY_FILE" | strip_control_ansi)
	if [ -z "$VERSION_OWNER_PROJECT_KEY" ]; then
		error "could not determine which project version $rvo_version_id belongs to (project $rvo_project_id reported no key)"
		exit 1
	fi
	return 0
}

# render_version_delete_plan ID NAME PROJECT_KEY URL — the `--plan`/`--dry-run`
# disclosure for a delete that has NOT happened: what the id actually resolves
# to (so a stale/mistyped one is caught by eye) and the exact request that
# WOULD be sent, followed by the same "NOTHING WAS WRITTEN" line every other
# --plan in this engine ends on. --json SYNTHESIZES its object for the same
# reason transition --plan does: no write was made, so there is no response to
# pass through, and it carries render_batch_plan's plan/willWrite pair so a
# consent gate can machine-check "this changed nothing" identically.
render_version_delete_plan() {
	rvdp_id=$1
	rvdp_name=$2
	rvdp_project_key=$3
	rvdp_url=$4
	if [ "$OPT_JSON" -eq 1 ]; then
		jq -n --arg id "$rvdp_id" --arg name "$rvdp_name" --arg project "$rvdp_project_key" \
			--arg url "$rvdp_url" \
			'{op: "version-delete", plan: true, willWrite: false,
			  id: $id, name: $name, project: $project, url: $url}'
		return 0
	fi
	printf 'PLAN (version --delete): would delete version %s "%s" in project %s\n' \
		"$rvdp_id" "$rvdp_name" "$rvdp_project_key"
	printf '  DELETE %s\n' "$rvdp_url"
	printf 'NOTHING WAS WRITTEN (dry-run / --plan).\n'
}

cmd_version() {
	# Mode (exactly one of --list/--create/--update/--release/--archive/--delete),
	# --project/--name presence, --id / --move-fix-issues-to /
	# --move-affected-issues-to numeric shape, "update needs a field", and "the
	# two --move-*-issues-to flags only with --delete" are validated up front —
	# see the main dispatch section's per-command block.
	ensure_workdir

	if [ "$OPT_LIST" -eq 1 ]; then
		versions_url="https://${CONFIRMED_HOST}/rest/api/3/project/${OPT_PROJECT}/versions"
		jira_curl GET "$versions_url"
		handle_http_status "$JIRA_HTTP_CODE" "list versions for $OPT_PROJECT"
		require_json_body "list versions for $OPT_PROJECT"
		if [ "$OPT_JSON" -eq 1 ]; then
			cat "$JIRA_HTTP_BODY_FILE"
			return 0
		fi
		render_versions_human "$JIRA_HTTP_BODY_FILE"
		return 0
	fi

	if [ "$OPT_CREATE" -eq 1 ]; then
		version_create_body="$WORKDIR/version-create.json"
		build_version_write_body "$version_create_body"
		create_version_url="https://${CONFIRMED_HOST}/rest/api/3/version"
		jira_curl POST "$create_version_url" "$version_create_body"
		handle_http_status "$JIRA_HTTP_CODE" "create version"
		require_json_body "create version"
		if [ "$OPT_JSON" -eq 1 ]; then
			# PASSTHROUGH — Jira's 201 body (id/name/released/...) IS the answer.
			cat "$JIRA_HTTP_BODY_FILE"
			return 0
		fi
		created_version_id=$(jq -r '.id // ""' "$JIRA_HTTP_BODY_FILE" | strip_control_ansi)
		created_version_name=$(jq -r '.name // ""' "$JIRA_HTTP_BODY_FILE" | strip_control_ansi)
		printf 'JIRA_VERSION_ID=%s\n' "$created_version_id"
		printf 'JIRA_VERSION_NAME=%s\n' "$created_version_name"
		return 0
	fi

	if [ "$OPT_DELETE" -eq 1 ]; then
		# delete — DELETE /version/<id> with up to TWO OPTIONAL query params
		# that REASSIGN the deleted version's issue references instead of just
		# stripping them: moveFixIssuesTo re-points every issue's fixVersions,
		# moveAffectedIssuesTo its affectedVersions. They are independent (give
		# either, both, or neither), so the separator is `?` for whichever lands
		# first and `&` for a second — never a fixed `?a=..&b=..` template that
		# would emit a dangling `&` when only the second one is supplied.
		#
		# Every id here is numeric-validated up front and additionally
		# urlencode()'d, the same belt-and-braces component --delete applies to
		# moveIssuesTo even for a digits-only value.
		delete_version_url="https://${CONFIRMED_HOST}/rest/api/3/version/${OPT_ID}"
		delete_version_query=""
		if [ -n "$OPT_MOVE_FIX_ISSUES_TO" ]; then
			encoded_fix_move_target=$(urlencode "$OPT_MOVE_FIX_ISSUES_TO")
			delete_version_query="moveFixIssuesTo=${encoded_fix_move_target}"
		fi
		if [ -n "$OPT_MOVE_AFFECTED_ISSUES_TO" ]; then
			encoded_affected_move_target=$(urlencode "$OPT_MOVE_AFFECTED_ISSUES_TO")
			[ -z "$delete_version_query" ] || delete_version_query="${delete_version_query}&"
			delete_version_query="${delete_version_query}moveAffectedIssuesTo=${encoded_affected_move_target}"
		fi
		[ -z "$delete_version_query" ] || delete_version_url="${delete_version_url}?${delete_version_query}"

		# Two OPT-IN pre-write safety nets over a SITE-GLOBAL id space: a
		# version id carries no project scoping of its own, so a stale or
		# mistyped --id names a real version in whatever project happens to own
		# it, and the server-side cascade (every issue's fixVersions/
		# affectedVersions stripped or re-pointed) has no Jira undo.
		#   --plan/--dry-run  discloses what the id resolves to and mutates
		#                     NOTHING — the same idiom transition/bulk/schedule
		#                     already carry on this globally-parsed flag.
		#   --project KEY     refuses the delete unless the version really
		#                     belongs to KEY. OPTIONAL: omitted, this behaves
		#                     exactly as it did before (no cross-check, no
		#                     extra read), so it adds a safety net without
		#                     making one mandatory.
		# One read serves both, and the cross-check runs BEFORE the plan
		# renders: a mismatch means the plan would describe a version the
		# caller did not mean, and printing it first would read as
		# confirmation of exactly the wrong thing.
		if [ -n "$OPT_PROJECT" ] || [ "$OPT_PLAN" -eq 1 ]; then
			resolve_version_owner "$OPT_ID"
		fi
		if [ -n "$OPT_PROJECT" ] && [ "$OPT_PROJECT" != "$VERSION_OWNER_PROJECT_KEY" ]; then
			error "version $OPT_ID belongs to project $VERSION_OWNER_PROJECT_KEY, not --project $OPT_PROJECT — refusing to delete it"
			exit 1
		fi
		if [ "$OPT_PLAN" -eq 1 ]; then
			render_version_delete_plan "$OPT_ID" "$VERSION_OWNER_NAME" "$VERSION_OWNER_PROJECT_KEY" "$delete_version_url"
			return 0
		fi

		jira_curl DELETE "$delete_version_url"
		handle_http_status "$JIRA_HTTP_CODE" "delete version $OPT_ID"
		# DELETE /version returns 204 No Content — no require_json_body call.
		if [ "$OPT_JSON" -eq 1 ]; then
			# SYNTHESIZED — no 204 body to pass through (same as component --delete).
			jq -n --arg id "$OPT_ID" '{id: $id, deleted: true}'
		else
			printf 'JIRA_VERSION_DELETED=%s\n' "$OPT_ID"
		fi
		return 0
	fi

	# update / release / archive all PUT /version/<id> with a partial body.
	# OPT_ID is numeric-validated up front before it reaches this URL segment.
	version_put_body="$WORKDIR/version-put.json"
	build_version_write_body "$version_put_body"
	version_put_url="https://${CONFIRMED_HOST}/rest/api/3/version/${OPT_ID}"
	jira_curl PUT "$version_put_url" "$version_put_body"
	handle_http_status "$JIRA_HTTP_CODE" "update version $OPT_ID"
	require_json_body "update version $OPT_ID"
	if [ "$OPT_JSON" -eq 1 ]; then
		# PASSTHROUGH — PUT /version returns 200 with the updated version object.
		cat "$JIRA_HTTP_BODY_FILE"
		return 0
	fi
	put_version_id=$(jq -r '.id // ""' "$JIRA_HTTP_BODY_FILE" | strip_control_ansi)
	put_version_name=$(jq -r '.name // ""' "$JIRA_HTTP_BODY_FILE" | strip_control_ansi)
	printf 'JIRA_VERSION_ID=%s\n' "$put_version_id"
	printf 'JIRA_VERSION_NAME=%s\n' "$put_version_name"
}

# validate_version_args() — `version`'s per-command argument validation, called by
# jira.sh BEFORE any tool/site/credential check so a caller's own typo
# surfaces as a usage error (exit 2) first.
validate_version_args() {
	# version takes NO positional — a stray one fails loud (same
	# reasoning as search/link-types).
	if [ -n "$TICKET_KEY" ]; then
		usage >&2
		error "version takes no positional argument, got: $TICKET_KEY"
		exit 2
	fi
	# --delete is a version mode of its own (DELETE /version/<id>) as well as a
	# component mode — the shared OPT_DELETE carrier means `version --list
	# --delete` names TWO version modes, so the exactly-one count below is what
	# rejects it. Every flag in this count is one of `version`'s OWN modes; no
	# foreign mode is folded in.
	version_mode_count=$((OPT_LIST + OPT_CREATE + OPT_UPDATE + OPT_RELEASE + OPT_ARCHIVE + OPT_DELETE))
	if [ "$version_mode_count" -ne 1 ]; then
		usage >&2
		error "version requires exactly one mode: --list, --create, --update, --release, --archive, or --delete"
		exit 2
	fi
	if [ "$OPT_LIST" -eq 1 ] || [ "$OPT_CREATE" -eq 1 ]; then
		[ -n "$OPT_PROJECT" ] || { usage >&2; error "version --list/--create requires --project"; exit 2; }
		validate_project_key "$OPT_PROJECT" || { usage >&2; error "invalid project key: $OPT_PROJECT"; exit 2; }
	fi
	# On --delete, --project is OPTIONAL (the opt-in ownership cross-check —
	# see cmd_version's delete branch), so only its SHAPE is checked, and only
	# when given: a malformed key would otherwise reach the comparison and fail
	# as "belongs to another project" (exit 1), disguising a caller's own typo
	# as a Jira fact instead of the usage error it is.
	if [ "$OPT_DELETE" -eq 1 ] && [ -n "$OPT_PROJECT" ]; then
		validate_project_key "$OPT_PROJECT" || { usage >&2; error "invalid project key: $OPT_PROJECT"; exit 2; }
	fi
	if [ "$OPT_CREATE" -eq 1 ]; then
		[ -n "$OPT_NAME" ] || { usage >&2; error "version --create requires --name"; exit 2; }
	fi
	if [ "$OPT_UPDATE" -eq 1 ] || [ "$OPT_RELEASE" -eq 1 ] || [ "$OPT_ARCHIVE" -eq 1 ] || [ "$OPT_DELETE" -eq 1 ]; then
		[ -n "$OPT_ID" ] || { usage >&2; error "version --update/--release/--archive/--delete requires --id"; exit 2; }
		validate_numeric_id "$OPT_ID" || { usage >&2; error "invalid --id (must be a numeric version id): $OPT_ID"; exit 2; }
	fi
	if [ "$OPT_UPDATE" -eq 1 ]; then
		if [ -z "$OPT_NAME" ] && [ -z "$OPT_DESCRIPTION" ] && [ -z "$OPT_RELEASE_DATE" ] && [ -z "$OPT_START_DATE" ]; then
			usage >&2
			error "version --update requires at least one field to change (--name/--description/--release-date/--start-date)"
			exit 2
		fi
	fi
	# --project and --plan/--dry-run are BOTH --delete's opt-in pre-write safety
	# nets (plus --project's --list/--create naming role), and neither is read
	# by --update/--release/--archive: those three address the version by --id
	# alone, so an unguarded one is SILENTLY dropped. Now that both are
	# documented safety nets on the sibling --delete, a caller has real reason
	# to believe either bit — and a caller who believes they asked for a
	# preview and instead gets a REAL write is the worst outcome this file can
	# produce, exactly as it is for `component --delete`. Rejected before any
	# network call. (Scope note: this guard is deliberately confined to these
	# three modes — whether --plan should be rejected on every other
	# preview-less command is a separate, wider decision.)
	if [ "$OPT_UPDATE" -eq 1 ] || [ "$OPT_RELEASE" -eq 1 ] || [ "$OPT_ARCHIVE" -eq 1 ]; then
		require_foreign_flag_unset --project "$OPT_PROJECT" "version --list/--create/--delete"
		require_flag_off --plan/--dry-run "$OPT_PLAN" "version --delete among the version modes — version --update/--release/--archive would write for REAL"
	fi
	require_foreign_flag_unset --move-issues-to "$OPT_MOVE_ISSUES_TO" "component --delete"
	# The two reassignment targets are optional and INDEPENDENT, but share one
	# rule set (delete-only + numeric version id) — require_delete_move_target
	# carries it, and takes the flag name so a caller who passed just one
	# still gets a diagnostic naming that one.
	[ -z "$OPT_MOVE_FIX_ISSUES_TO" ]      || require_delete_move_target --move-fix-issues-to "$OPT_MOVE_FIX_ISSUES_TO" "version --delete" version
	[ -z "$OPT_MOVE_AFFECTED_ISSUES_TO" ] || require_delete_move_target --move-affected-issues-to "$OPT_MOVE_AFFECTED_ISSUES_TO" "version --delete" version
	return 0
}
