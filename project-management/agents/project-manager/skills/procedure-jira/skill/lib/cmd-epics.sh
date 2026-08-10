# shellcheck shell=sh
#
# cmd-epics.sh — `epics <BOARD_ID>`: the board's epics.
#
# board/<id>/epic is UNIQUE among the agile list endpoints in returning isLast
# with NO `total`, which is exactly why agile-paging.sh checks all three
# termination conditions.
#
# Sourced by jira.sh — never executed directly. Sets no shell options and
# runs no top-level work beyond its own declarations, so sourcing it always
# returns 0 under `set -e`.

# render_epics_human FILE TOTAL — one line per epic (values envelope). The epic
# element carries both a key (PROJECT-NNN) and a done flag.
render_epics_human() {
	epics_file=$1
	epics_total=$2
	if [ "$epics_total" -eq 0 ]; then
		printf 'No epics.\n'
		return 0
	fi
	printf '%s epic(s):\n\n' "$epics_total"
	while IFS= read -r epic_line; do
		e_key=$(printf '%s' "$epic_line" | jq -r '.key // ""' | strip_control_ansi)
		e_name=$(printf '%s' "$epic_line" | jq -r '.name // ""' | strip_control_ansi)
		e_done=$(printf '%s' "$epic_line" | jq -r '.done // false' | strip_control_ansi)
		printf '  %-12s [done %s] %s\n' "$e_key" "$e_done" "$e_name"
	done <"$epics_file"
}

cmd_epics() {
	# The dispatcher parks the single positional in $TICKET_KEY whatever the
	# command; for `epics` that value is a numeric BOARD id, already validated by
	# validate_epics_args(), so name it as one here. board/<id>/epic is the
	# values envelope but — UNIQUELY — returns isLast with NO `total`; full
	# pagination therefore relies on isLast/empty-page, which the agile pager
	# handles.
	epics_board_id=$TICKET_KEY
	ensure_workdir
	epics_url="https://${CONFIRMED_HOST}/rest/agile/1.0/board/${epics_board_id}/epic"
	epics_file="$WORKDIR/agile-epics.jsonl"
	agile_paginate "$epics_file" "$epics_url" values "list epics for board $epics_board_id"
	if [ "$OPT_JSON" -eq 1 ]; then
		jq -s '{values: .}' "$epics_file"
	else
		render_epics_human "$epics_file" "$AGILE_COLLECTED"
	fi
}

# validate_epics_args() — `epics`'s per-command argument validation, called by
# jira.sh BEFORE any tool/site/credential check so a caller's own typo
# surfaces as a usage error (exit 2) first.
validate_epics_args() {
	[ -n "$TICKET_KEY" ] || { usage >&2; error "epics requires a numeric board id, e.g.: epics 826"; exit 2; }
	validate_numeric_id "$TICKET_KEY" || { usage >&2; error "invalid board id (must be numeric): $TICKET_KEY"; exit 2; }
	return 0
}
