# shellcheck shell=sh
#
# cmd-link-types.sh — `link-types`: list the site's issue-link types with each
#                     type's inward AND outward wording, so a caller can pick a
#                     valid --link-type and confirm which end reads which way
#                     before calling `link` for real.
#
# Sourced by jira.sh — never executed directly. Sets no shell options and
# runs no top-level work beyond its own declarations, so sourcing it always
# returns 0 under `set -e`.

# render_link_types_human BODY_FILE — lists each link type's name plus its
# inward/outward wording, so a caller can discover valid --link-type values
# and confirm which end (inward/outward) reads which way before calling
# `link` for real.
render_link_types_human() {
	link_types_body_file=$1
	printf 'Available link types:\n'
	jq -r '.issueLinkTypes[] | "\(.name)\t\(.inward)\t\(.outward)"' "$link_types_body_file" \
		| while IFS="$(printf '\t')" read -r lt_name lt_inward lt_outward; do
			clean_lt_name=$(printf '%s' "$lt_name" | strip_control_ansi)
			clean_lt_inward=$(printf '%s' "$lt_inward" | strip_control_ansi)
			clean_lt_outward=$(printf '%s' "$lt_outward" | strip_control_ansi)
			printf '  %s\n    outward: %s\n    inward:  %s\n' "$clean_lt_name" "$clean_lt_outward" "$clean_lt_inward"
		done
}

cmd_link_types() {
	# No positional/required flags — validated up front (rejects a stray
	# positional the same way `search` does).
	link_types_url="https://${CONFIRMED_HOST}/rest/api/3/issueLinkType"
	jira_curl GET "$link_types_url"
	handle_http_status "$JIRA_HTTP_CODE" "list issue link types"
	require_json_body "list issue link types"

	if [ "$OPT_JSON" -eq 1 ]; then
		cat "$JIRA_HTTP_BODY_FILE"
		return 0
	fi
	render_link_types_human "$JIRA_HTTP_BODY_FILE"
}

# validate_link_types_args() — `link-types`'s per-command argument validation, called by
# jira.sh BEFORE any tool/site/credential check so a caller's own typo
# surfaces as a usage error (exit 2) first.
validate_link_types_args() {
	# link-types takes no positional — same "fail loud on a stray
	# argument" reasoning as search's own check above.
	if [ -n "$TICKET_KEY" ]; then
		usage >&2
		error "link-types takes no positional argument, got: $TICKET_KEY"
		exit 2
	fi
	return 0
}
