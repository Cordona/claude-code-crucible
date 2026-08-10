# shellcheck shell=sh
#
# cmd-boards.sh — `boards`: list the site's agile boards, optionally filtered by
#                 --project and/or --type.
#
# Sourced by jira.sh — never executed directly. Sets no shell options and
# runs no top-level work beyond its own declarations, so sourcing it always
# returns 0 under `set -e`.

# render_boards_human FILE TOTAL — one line per board (values envelope). Each element
# is emitted as one compact JSON object (jq -c escapes any tab/newline inside a
# board NAME, so an author-controlled name can never split a row) and every
# field is extracted INDEPENDENTLY through jq + strip_control_ansi — the same
# delimiter-injection-safe idiom render_search_human / render_versions_human use.
render_boards_human() {
	boards_file=$1
	boards_total=$2
	if [ "$boards_total" -eq 0 ]; then
		printf 'No boards.\n'
		return 0
	fi
	printf '%s board(s):\n\n' "$boards_total"
	while IFS= read -r board_line; do
		b_id=$(printf '%s' "$board_line" | jq -r '.id // ""' | strip_control_ansi)
		b_name=$(printf '%s' "$board_line" | jq -r '.name // ""' | strip_control_ansi)
		b_type=$(printf '%s' "$board_line" | jq -r '.type // "N/A"' | strip_control_ansi)
		b_project=$(printf '%s' "$board_line" | jq -r '.location.projectKey // "N/A"' | strip_control_ansi)
		printf '  %-8s [%s] %s (project %s)\n' "$b_id" "$b_type" "$b_name" "$b_project"
	done <"$boards_file"
}

cmd_boards() {
	# No positional; optional --project (validated as a project key up front) and
	# --type (allow-list-validated up front). Both are urlencode'd query values.
	ensure_workdir
	boards_url="https://${CONFIRMED_HOST}/rest/agile/1.0/board"
	boards_qs=""
	if [ -n "$OPT_PROJECT" ]; then
		boards_qs="projectKeyOrId=$(urlencode "$OPT_PROJECT")"
	fi
	if [ -n "$OPT_TYPE" ]; then
		[ -z "$boards_qs" ] || boards_qs="${boards_qs}&"
		boards_qs="${boards_qs}type=$(urlencode "$OPT_TYPE")"
	fi
	[ -z "$boards_qs" ] || boards_url="${boards_url}?${boards_qs}"

	boards_file="$WORKDIR/agile-boards.jsonl"
	agile_paginate "$boards_file" "$boards_url" values "list boards"
	if [ "$OPT_JSON" -eq 1 ]; then
		jq -s '{values: .}' "$boards_file"
	else
		render_boards_human "$boards_file" "$AGILE_COLLECTED"
	fi
}

# validate_boards_args() — `boards`'s per-command argument validation, called by
# jira.sh BEFORE any tool/site/credential check so a caller's own typo
# surfaces as a usage error (exit 2) first.
validate_boards_args() {
	# boards takes NO positional (it addresses boards via --project/--type) —
	# a stray one fails loud, same reasoning as search/version.
	if [ -n "$TICKET_KEY" ]; then
		usage >&2
		error "boards takes no positional argument, got: $TICKET_KEY (use --project)"
		exit 2
	fi
	if [ -n "$OPT_PROJECT" ]; then
		validate_project_key "$OPT_PROJECT" || { usage >&2; error "invalid project key: $OPT_PROJECT"; exit 2; }
	fi
	if [ -n "$OPT_TYPE" ]; then
		validate_board_type "$OPT_TYPE" || { usage >&2; error "invalid --type '$OPT_TYPE' (must be scrum|kanban|simple)"; exit 2; }
	fi
	return 0
}
