# shellcheck shell=sh
#
# cmd-epic.sh — `epic <EPIC_ID> --issues`: the epic's issues (its issues are the
#               only supported epic read).
#
# Sourced by jira.sh — never executed directly. Sets no shell options and
# runs no top-level work beyond its own declarations, so sourcing it always
# returns 0 under `set -e`.

cmd_epic() {
	# The dispatcher parks the single positional in $TICKET_KEY whatever the
	# command; for `epic` that value is a numeric EPIC id, already validated by
	# validate_epic_args(), so name it as one here. --issues is REQUIRED (the
	# only supported epic read is its issues). epic/<id>/issue is the issues
	# envelope, paginated, rendered via the shared issue render.
	epic_id=$TICKET_KEY
	ensure_workdir
	epic_issues_url="https://${CONFIRMED_HOST}/rest/agile/1.0/epic/${epic_id}/issue"
	epic_issues_file="$WORKDIR/agile-epic-issues.jsonl"
	agile_paginate "$epic_issues_file" "$epic_issues_url" issues "list issues for epic $epic_id"
	if [ "$OPT_JSON" -eq 1 ]; then
		jq -s '{issues: .}' "$epic_issues_file"
	else
		render_search_human "$epic_issues_file" "$AGILE_COLLECTED"
	fi
}

# validate_epic_args() — `epic`'s per-command argument validation, called by
# jira.sh BEFORE any tool/site/credential check so a caller's own typo
# surfaces as a usage error (exit 2) first.
validate_epic_args() {
	[ -n "$TICKET_KEY" ] || { usage >&2; error "epic requires a numeric epic id, e.g.: epic 91591 --issues"; exit 2; }
	validate_numeric_id "$TICKET_KEY" || { usage >&2; error "invalid epic id (must be numeric): $TICKET_KEY"; exit 2; }
	[ "$OPT_ISSUES" -eq 1 ] || { usage >&2; error "epic requires --issues (its issues are the only supported epic read)"; exit 2; }
	return 0
}
