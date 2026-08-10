# shellcheck shell=sh
#
# cmd-sprints.sh — `sprints <BOARD_ID>`: the board's sprints, optionally
#                  filtered by a --state CSV (active|future|closed).
#
# Sourced by jira.sh — never executed directly. Sets no shell options and
# runs no top-level work beyond its own declarations, so sourcing it always
# returns 0 under `set -e`.

# render_sprints_human FILE TOTAL — one line per sprint (values envelope). Dates are
# optional (a sprint element may omit start/end), so a missing date renders as
# "N/A" rather than an empty gap.
render_sprints_human() {
	sprints_file=$1
	sprints_total=$2
	if [ "$sprints_total" -eq 0 ]; then
		printf 'No sprints.\n'
		return 0
	fi
	printf '%s sprint(s):\n\n' "$sprints_total"
	while IFS= read -r sprint_line; do
		s_id=$(printf '%s' "$sprint_line" | jq -r '.id // ""' | strip_control_ansi)
		s_state=$(printf '%s' "$sprint_line" | jq -r '.state // "N/A"' | strip_control_ansi)
		s_name=$(printf '%s' "$sprint_line" | jq -r '.name // ""' | strip_control_ansi)
		s_start=$(printf '%s' "$sprint_line" | jq -r '.startDate // "N/A"' | strip_control_ansi)
		s_end=$(printf '%s' "$sprint_line" | jq -r '.endDate // "N/A"' | strip_control_ansi)
		printf '  %-8s [%s] %s (%s -> %s)\n' "$s_id" "$s_state" "$s_name" "$s_start" "$s_end"
	done <"$sprints_file"
}

cmd_sprints() {
	# The dispatcher parks the single positional in $TICKET_KEY whatever the
	# command; for `sprints` that value is a numeric BOARD id, already validated
	# by validate_sprints_args(), so name it as one here. Optional --state
	# (allow-list CSV, validated up front) becomes an urlencode'd `state=` query
	# value.
	sprints_board_id=$TICKET_KEY
	ensure_workdir
	sprints_url="https://${CONFIRMED_HOST}/rest/agile/1.0/board/${sprints_board_id}/sprint"
	[ -z "$OPT_STATE" ] || sprints_url="${sprints_url}?state=$(urlencode "$OPT_STATE")"
	sprints_file="$WORKDIR/agile-sprints.jsonl"
	agile_paginate "$sprints_file" "$sprints_url" values "list sprints for board $sprints_board_id"
	if [ "$OPT_JSON" -eq 1 ]; then
		jq -s '{values: .}' "$sprints_file"
	else
		render_sprints_human "$sprints_file" "$AGILE_COLLECTED"
	fi
}

# validate_sprints_args() — `sprints`'s per-command argument validation, called by
# jira.sh BEFORE any tool/site/credential check so a caller's own typo
# surfaces as a usage error (exit 2) first.
validate_sprints_args() {
	[ -n "$TICKET_KEY" ] || { usage >&2; error "sprints requires a numeric board id, e.g.: sprints 826"; exit 2; }
	validate_numeric_id "$TICKET_KEY" || { usage >&2; error "invalid board id (must be numeric): $TICKET_KEY"; exit 2; }
	if [ -n "$OPT_STATE" ]; then
		validate_sprint_states "$OPT_STATE" || { usage >&2; error "invalid --state '$OPT_STATE' (comma-separated: active|future|closed)"; exit 2; }
	fi
	return 0
}
