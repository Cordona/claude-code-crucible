# shellcheck shell=sh
#
# search-core.sh — the request-body builder and the human renderer shared by
#                  every issue-list read.
#
# render_search_human is genuinely cross-command (search, children, sprint
# --issues, backlog, epic --issues all render the SAME issue shape), which is
# why it lives here rather than in cmd-search.sh.
#
# Sourced by jira.sh — never executed directly. Sets no shell options and
# runs no top-level work beyond its own declarations, so sourcing it always
# returns 0 under `set -e`.

# ---------------------------------------------------------------------------
# search
# ---------------------------------------------------------------------------

# Live-testing defect: the real /rest/api/3/search/jql, given NO
# explicit `fields`, returns each issue holding ONLY `id` — no `key`, no
# `fields` object at all — so render_search_human/--json show nulls
# (verified live: passing --fields "key,summary,status" works correctly).
# This is the real API's own default-fields behavior, not something this
# script can leave unset — DEFAULT_SEARCH_FIELDS is what --fields falls
# back to when the caller doesn't give one; `key` is always first since
# every downstream consumer (render_search_human, jq '.key') depends on it.
DEFAULT_SEARCH_FIELDS="key,summary,status,assignee,issuetype"

# build_search_request_body OUT_FILE JQL MAX_RESULTS TOKEN — writes ONE
# compact JSON object via a single static jq program (fields/nextPageToken
# included only when present) fed entirely via --arg/--argjson. JQL is
# passed as DATA into JSON structure here — the JQL-sink escaping already
# happened in build_jql(); this step only has to be JSON-safe, which --arg
# guarantees.
build_search_request_body() {
	bsrb_out_file=$1
	bsrb_jql=$2
	bsrb_max_results=$3
	bsrb_token=$4

	bsrb_fields_csv=${OPT_FIELDS:-$DEFAULT_SEARCH_FIELDS}
	bsrb_fields_json=$(printf '%s' "$bsrb_fields_csv" | jq -R -c \
		'split(",") | map(gsub("^[[:space:]]+|[[:space:]]+$";"")) | map(select(length > 0))')

	jq -n -c \
		--arg jql "$bsrb_jql" \
		--argjson maxResults "$bsrb_max_results" \
		--argjson fields "$bsrb_fields_json" \
		--arg token "$bsrb_token" \
		'{jql:$jql, maxResults:$maxResults, fields:$fields}
		 + (if ($token|length) > 0 then {nextPageToken:$token} else {} end)' \
		>"$bsrb_out_file"
}

render_search_human() {
	rsh_issues_file=$1
	rsh_total=$2
	if [ "$rsh_total" -eq 0 ]; then
		printf 'No matching issues.\n'
		return 0
	fi
	printf '%s issue(s):\n\n' "$rsh_total"
	while IFS= read -r rsh_issue_line; do
		rsh_key=$(printf '%s' "$rsh_issue_line" | jq -r '.key' | strip_control_ansi)
		rsh_summary=$(printf '%s' "$rsh_issue_line" | jq -r '.fields.summary // ""' | strip_control_ansi)
		rsh_status=$(printf '%s' "$rsh_issue_line" | jq -r '.fields.status.name // "N/A"' | strip_control_ansi)
		printf '  %-12s [%s] %s\n' "$rsh_key" "$rsh_status" "$rsh_summary"
	done <"$rsh_issues_file"
}
