# shellcheck shell=sh
#
# cmd-sprint.sh — `sprint`: the sprint READ (detail, or --issues) and the four
#                 sprint WRITES (--create/--update/--start/--close).
#
# State transitions (future -> active -> closed) are enforced by the SERVER: a
# bad transition surfaces as its own HTTP error, never a pre-GET guess here.
#
# Sourced by jira.sh — never executed directly. Sets no shell options and
# runs no top-level work beyond its own declarations, so sourcing it always
# returns 0 under `set -e`.

# render_sprint_human FILE — the SINGLE sprint-detail object.
render_sprint_human() {
	sprint_file=$1
	sd_id=$(jq -r '.id // ""' "$sprint_file" | strip_control_ansi)
	sd_state=$(jq -r '.state // "N/A"' "$sprint_file" | strip_control_ansi)
	sd_name=$(jq -r '.name // ""' "$sprint_file" | strip_control_ansi)
	sd_start=$(jq -r '.startDate // "N/A"' "$sprint_file" | strip_control_ansi)
	sd_end=$(jq -r '.endDate // "N/A"' "$sprint_file" | strip_control_ansi)
	sd_goal=$(jq -r '.goal // ""' "$sprint_file" | strip_control_ansi)
	printf 'Sprint %s: %s [%s]\n' "$sd_id" "$sd_name" "$sd_state"
	printf '  window: %s -> %s\n' "$sd_start" "$sd_end"
	printf '  goal:   %s\n' "$sd_goal"
}

# emit_sprint_result — the shared success output for every sprint WRITE
# (create/update/start/close). On --json: PASSTHROUGH of Jira's sprint object
# (the 200/201 body IS the answer). Otherwise: the two machine lines
# JIRA_SPRINT_ID / JIRA_SPRINT_STATE. `.id` is a JSON number in the response;
# jq -r renders it as its decimal digits.
emit_sprint_result() {
	if [ "$OPT_JSON" -eq 1 ]; then
		cat "$JIRA_HTTP_BODY_FILE"
		return 0
	fi
	esr_id=$(jq -r '.id // ""' "$JIRA_HTTP_BODY_FILE" | strip_control_ansi)
	esr_state=$(jq -r '.state // ""' "$JIRA_HTTP_BODY_FILE" | strip_control_ansi)
	printf 'JIRA_SPRINT_ID=%s\n' "$esr_id"
	printf 'JIRA_SPRINT_STATE=%s\n' "$esr_state"
}

cmd_sprint() {
	# Mode: exactly one of the WRITE modes (--create/--update/--start/--close) OR
	# a READ (no write mode; the positional SPRINT_ID + optional --issues). Mode,
	# --board/--name presence, id shapes, required dates, and ISO-8601 date FORMAT
	# are all validated up front — see the main dispatch section's per-command
	# block. Bodies are built with static-jq merge helpers (--arg/--argjson),
	# never string concatenation; every write is a POST over /rest/agile/1.0/.
	#
	# The dispatcher parks the single positional in $TICKET_KEY whatever the
	# command; for `sprint` that value is a numeric SPRINT id (empty on
	# --create, which has no positional), so name it as one here.
	sprint_id=$TICKET_KEY
	ensure_workdir

	if [ "$OPT_CREATE" -eq 1 ]; then
		# POST /sprint — body {name, originBoardId[, goal, startDate, endDate]}.
		# originBoardId is a JSON NUMBER (merge_int_field); the rest are strings.
		sprint_create_body="$WORKDIR/sprint-create.json"
		init_fields_accumulator "$sprint_create_body"
		merge_string_field "$sprint_create_body" name "$OPT_NAME"
		merge_int_field    "$sprint_create_body" originBoardId "$OPT_BOARD"
		[ -z "$OPT_GOAL" ]       || merge_string_field "$sprint_create_body" goal "$OPT_GOAL"
		[ -z "$OPT_START_DATE" ] || merge_string_field "$sprint_create_body" startDate "$OPT_START_DATE"
		[ -z "$OPT_END_DATE" ]   || merge_string_field "$sprint_create_body" endDate "$OPT_END_DATE"
		sprint_create_url="https://${CONFIRMED_HOST}/rest/agile/1.0/sprint"
		jira_curl POST "$sprint_create_url" "$sprint_create_body"
		handle_http_status "$JIRA_HTTP_CODE" "create sprint"
		require_json_body "create sprint"
		emit_sprint_result
		return 0
	fi

	if [ "$OPT_UPDATE" -eq 1 ] || [ "$OPT_START" -eq 1 ] || [ "$OPT_CLOSE" -eq 1 ]; then
		# All three POST /sprint/<id> with a PARTIAL body. State transitions
		# (future->active->closed) are enforced by the SERVER — a bad transition
		# surfaces as its own HTTP error via handle_http_status, not a pre-GET.
		# The target is the positional sprint id, numeric-validated up front.
		sprint_write_body="$WORKDIR/sprint-write.json"
		init_fields_accumulator "$sprint_write_body"
		if [ "$OPT_START" -eq 1 ]; then
			# start REQUIRES both dates (enforced up front): {state:active,dates}.
			merge_string_field "$sprint_write_body" state active
			merge_string_field "$sprint_write_body" startDate "$OPT_START_DATE"
			merge_string_field "$sprint_write_body" endDate "$OPT_END_DATE"
		elif [ "$OPT_CLOSE" -eq 1 ]; then
			merge_string_field "$sprint_write_body" state closed
		else
			# update — only the fields the caller supplied (>=1 enforced up front).
			[ -z "$OPT_NAME" ]       || merge_string_field "$sprint_write_body" name "$OPT_NAME"
			[ -z "$OPT_GOAL" ]       || merge_string_field "$sprint_write_body" goal "$OPT_GOAL"
			[ -z "$OPT_START_DATE" ] || merge_string_field "$sprint_write_body" startDate "$OPT_START_DATE"
			[ -z "$OPT_END_DATE" ]   || merge_string_field "$sprint_write_body" endDate "$OPT_END_DATE"
		fi
		sprint_write_url="https://${CONFIRMED_HOST}/rest/agile/1.0/sprint/${sprint_id}"
		jira_curl POST "$sprint_write_url" "$sprint_write_body"
		handle_http_status "$JIRA_HTTP_CODE" "update sprint $sprint_id"
		require_json_body "update sprint $sprint_id"
		emit_sprint_result
		return 0
	fi

	# READ: SPRINT_ID numeric-validated up front. Default: the single
	# sprint-detail object (raw body passthrough on --json). With --issues: the
	# sprint's issues (issues envelope, paginated, rendered via the shared render).
	if [ "$OPT_ISSUES" -eq 1 ]; then
		sprint_issues_url="https://${CONFIRMED_HOST}/rest/agile/1.0/sprint/${sprint_id}/issue"
		sprint_issues_file="$WORKDIR/agile-sprint-issues.jsonl"
		agile_paginate "$sprint_issues_file" "$sprint_issues_url" issues "list issues for sprint $sprint_id"
		if [ "$OPT_JSON" -eq 1 ]; then
			jq -s '{issues: .}' "$sprint_issues_file"
		else
			render_search_human "$sprint_issues_file" "$AGILE_COLLECTED"
		fi
		return 0
	fi
	sprint_url="https://${CONFIRMED_HOST}/rest/agile/1.0/sprint/${sprint_id}"
	jira_curl GET "$sprint_url"
	handle_http_status "$JIRA_HTTP_CODE" "get sprint $sprint_id"
	require_json_body "get sprint $sprint_id"
	if [ "$OPT_JSON" -eq 1 ]; then
		cat "$JIRA_HTTP_BODY_FILE"
		return 0
	fi
	render_sprint_human "$JIRA_HTTP_BODY_FILE"
}

# validate_sprint_args() — `sprint`'s per-command argument validation, called by
# jira.sh BEFORE any tool/site/credential check so a caller's own typo
# surfaces as a usage error (exit 2) first.
validate_sprint_args() {
	# sprint is READ (positional id, optional --issues) OR one WRITE mode
	# (--create/--update/--start/--close). --delete/--release/--archive/--list
	# are foreign modes (version/component/attach) — reject by name, the same
	# by-name foreign-flag guard version/component use, then fold the sprint
	# modes into an exactly-one-write count.
	if [ "$OPT_DELETE" -eq 1 ] || [ "$OPT_RELEASE" -eq 1 ] || [ "$OPT_ARCHIVE" -eq 1 ] || [ "$OPT_LIST" -eq 1 ]; then
		usage >&2
		error "--delete/--release/--archive/--list are not sprint modes"
		exit 2
	fi
	sprint_write_count=$((OPT_CREATE + OPT_UPDATE + OPT_START + OPT_CLOSE))
	if [ "$sprint_write_count" -gt 1 ]; then
		usage >&2
		error "sprint requires exactly one write mode: --create, --update, --start, or --close"
		exit 2
	fi
	if [ "$sprint_write_count" -eq 0 ]; then
		# READ: a numeric sprint id, no write-only flags.
		[ -n "$TICKET_KEY" ] || { usage >&2; error "sprint requires a numeric sprint id, e.g.: sprint 2212"; exit 2; }
		validate_numeric_id "$TICKET_KEY" || { usage >&2; error "invalid sprint id (must be numeric): $TICKET_KEY"; exit 2; }
		if [ -n "$OPT_BOARD" ] || [ -n "$OPT_GOAL" ] || [ -n "$OPT_NAME" ] || [ -n "$OPT_START_DATE" ] || [ -n "$OPT_END_DATE" ]; then
			usage >&2
			error "sprint read takes no --board/--goal/--name/--start-date/--end-date (did you mean a write mode?)"
			exit 2
		fi
	elif [ "$OPT_CREATE" -eq 1 ]; then
		# create: NO positional (the sprint doesn't exist yet); --board + --name.
		if [ -n "$TICKET_KEY" ]; then
			usage >&2
			error "sprint --create takes no positional (use --board and --name): $TICKET_KEY"
			exit 2
		fi
		if [ "$OPT_ISSUES" -eq 1 ]; then usage >&2; error "--issues is a read modifier, not valid with sprint --create"; exit 2; fi
		[ -n "$OPT_BOARD" ] || { usage >&2; error "sprint --create requires --board BOARD_ID"; exit 2; }
		validate_numeric_id "$OPT_BOARD" || { usage >&2; error "invalid --board (must be a numeric board id): $OPT_BOARD"; exit 2; }
		[ -n "$OPT_NAME" ] || { usage >&2; error "sprint --create requires --name STR"; exit 2; }
		if [ -n "$OPT_START_DATE" ]; then
			require_iso_date '--start-date (expected ISO-8601, e.g. 2026-07-26T10:00:00.000Z)' "$OPT_START_DATE"
		fi
		if [ -n "$OPT_END_DATE" ]; then
			require_iso_date '--end-date (expected ISO-8601, e.g. 2026-08-02T10:00:00.000Z)' "$OPT_END_DATE"
		fi
	else
		# update / start / close: positional numeric sprint id; --board rejected.
		[ -n "$TICKET_KEY" ] || { usage >&2; error "sprint --update/--start/--close requires a numeric sprint id, e.g.: sprint 2212 --close"; exit 2; }
		validate_numeric_id "$TICKET_KEY" || { usage >&2; error "invalid sprint id (must be numeric): $TICKET_KEY"; exit 2; }
		if [ "$OPT_ISSUES" -eq 1 ]; then usage >&2; error "--issues is a read modifier, not valid with a sprint write mode"; exit 2; fi
		if [ -n "$OPT_BOARD" ]; then usage >&2; error "--board is only valid with sprint --create"; exit 2; fi
		if [ "$OPT_UPDATE" -eq 1 ]; then
			if [ -z "$OPT_NAME" ] && [ -z "$OPT_GOAL" ] && [ -z "$OPT_START_DATE" ] && [ -z "$OPT_END_DATE" ]; then
				usage >&2
				error "sprint --update requires at least one field to change (--name/--goal/--start-date/--end-date)"
				exit 2
			fi
			if [ -n "$OPT_START_DATE" ]; then
				require_iso_date '--start-date (expected ISO-8601, e.g. 2026-07-26T10:00:00.000Z)' "$OPT_START_DATE"
			fi
			if [ -n "$OPT_END_DATE" ]; then
				require_iso_date '--end-date (expected ISO-8601, e.g. 2026-08-02T10:00:00.000Z)' "$OPT_END_DATE"
			fi
		fi
		if [ "$OPT_START" -eq 1 ]; then
			# start REQUIRES both dates; --name/--goal are not part of a start.
			[ -n "$OPT_START_DATE" ] || { usage >&2; error "sprint --start requires --start-date ISO (start needs both dates)"; exit 2; }
			[ -n "$OPT_END_DATE" ]   || { usage >&2; error "sprint --start requires --end-date ISO (start needs both dates)"; exit 2; }
			require_iso_date '--start-date (expected ISO-8601, e.g. 2026-07-26T10:00:00.000Z)' "$OPT_START_DATE"
			require_iso_date '--end-date (expected ISO-8601, e.g. 2026-08-02T10:00:00.000Z)' "$OPT_END_DATE"
			if [ -n "$OPT_NAME" ] || [ -n "$OPT_GOAL" ]; then
				usage >&2
				error "sprint --start takes only --start-date/--end-date (rename/re-goal with --update)"
				exit 2
			fi
		fi
		if [ "$OPT_CLOSE" -eq 1 ]; then
			if [ -n "$OPT_NAME" ] || [ -n "$OPT_GOAL" ] || [ -n "$OPT_START_DATE" ] || [ -n "$OPT_END_DATE" ]; then
				usage >&2
				error "sprint --close takes no fields (it only sets state=closed)"
				exit 2
			fi
		fi
	fi
	return 0
}
