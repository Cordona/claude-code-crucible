# shellcheck shell=sh
#
# agile-paging.sh — the Agile REST (/rest/agile/1.0/) offset pager, shared by
#                   all seven agile list reads.
#
# It handles BOTH agile list envelopes with one loop — the "values" envelope
# (board/sprint/epic lists, isLast, `total` OPTIONAL) and the "issues" envelope
# (sprint issues, backlog, epic issues: `total`, NO isLast) — stopping on the
# FIRST of: an empty page, isLast:true, or startAt reaching a REPORTED total.
#
# Deliberately SEPARATE from cmd-discover.sh's fetch_paginated_values: the two
# share only a superficial offset loop, and their TERMINATION rules genuinely
# diverge (total vs isLast vs the OPT_LIMIT cap).
#
# COUPLING (accepted for this pass): agile_paginate reads $OPT_LIMIT directly as
# its cap, and reports its row count through the $AGILE_COLLECTED global rather
# than a return value.
#
# Sourced by jira.sh — never executed directly. Sets no shell options and
# runs no top-level work beyond its own declarations, so sourcing it always
# returns 0 under `set -e`.

# ===========================================================================
# Agile (READ-only) — boards / sprints / backlog / epics over the Agile REST
# base /rest/agile/1.0/ (note: a DIFFERENT base than the rest of the engine's
# /rest/api/3/, but the SAME jira_curl transport, which takes a full URL and
# pins host/https regardless of path). Every command here is a GET; nothing
# in this block mutates.
# ===========================================================================

# AGILE_PAGE_SIZE — Jira Agile per-request page size (startAt/maxResults offset
# paging). 50 is a safe default well under the API's own ceiling.
AGILE_PAGE_SIZE=50

# AGILE_COLLECTED — set by agile_paginate() to the number of rows it appended,
# so an issues-envelope caller can pass it to render_search_human() as the total
# without re-counting the file.
AGILE_COLLECTED=0

# agile_paginate OUT_FILE URL_BASE ARRAY_KEY ACTION — the fetch half of every
# Agile LIST read: TRUNCATE OUT_FILE, then page a Jira Agile LIST endpoint to
# full resolution, appending each element as one compact JSON line to OUT_FILE,
# and set $AGILE_COLLECTED to the row count. It does NOT branch on --json or
# render anything — each cmd_* owns that split afterward, reading OUT_FILE +
# $AGILE_COLLECTED. Handles BOTH Agile list envelopes with ONE loop:
#   * the "values" envelope (board / sprint / epic lists):
#     {maxResults,startAt,total?,isLast,values:[...]} — `total` is OPTIONAL
#     (the /board/<id>/epic endpoint omits it, returning ONLY isLast).
#   * the "issues" envelope (sprint issues, backlog, epic issues):
#     {startAt,maxResults,total,issues:[...]} — has `total`, NO isLast.
# ARRAY_KEY is "values" or "issues" accordingly.
#
# A deliberately SEPARATE function from fetch_paginated_values (discover's
# offset pager): the two share only a superficial offset loop but their
# TERMINATION rules genuinely diverge — discover's createmeta endpoints have
# `total` and no isLast and no --limit; the Agile endpoints have the isLast /
# no-total variance below and an explicit --limit cap. Keeping them apart means
# this block cannot regress discover (the task's "keep discover intact" rule).
#
# Termination is robust across the envelope variance — it stops on the FIRST of:
#   * an empty page (no rows returned — the infinite-loop guard, and the ONLY
#     stop the epic endpoint would ever need if isLast were also absent),
#   * isLast == true (present ONLY on the values envelope),
#   * `total` present AND startAt has reached it (all rows collected).
# A loop keyed on `total` alone would spin forever on the epic endpoint (no
# total); one keyed on isLast alone would never stop on the issues envelope (no
# isLast). Checking all three covers every shape.
#
# --limit (OPT_LIMIT) is an EXPLICIT cap: when set, at most that many rows are
# collected and paging stops as soon as the cap is reached — the user's
# deliberate choice, never a silent truncation. Unset => full pagination.
agile_paginate() {
	fpa_out_file=$1
	fpa_url_base=$2
	fpa_array_key=$3
	fpa_action=$4
	: >"$fpa_out_file"
	fpa_start=0
	fpa_collected=0
	fpa_cap=${OPT_LIMIT:-0}
	while :; do
		fpa_page_size=$AGILE_PAGE_SIZE
		if [ "$fpa_cap" -gt 0 ]; then
			fpa_remaining=$((fpa_cap - fpa_collected))
			[ "$fpa_remaining" -gt 0 ] || break
			[ "$fpa_remaining" -ge "$fpa_page_size" ] || fpa_page_size=$fpa_remaining
		fi
		case "$fpa_url_base" in
			*\?*) fpa_sep='&' ;;
			*)    fpa_sep='?' ;;
		esac
		fpa_url="${fpa_url_base}${fpa_sep}startAt=${fpa_start}&maxResults=${fpa_page_size}"
		jira_curl GET "$fpa_url"
		handle_http_status "$JIRA_HTTP_CODE" "$fpa_action"
		require_json_body "$fpa_action"
		jq -c --arg k "$fpa_array_key" '.[$k][]?' "$JIRA_HTTP_BODY_FILE" >>"$fpa_out_file"
		fpa_page_count=$(jq --arg k "$fpa_array_key" '(.[$k] // []) | length' "$JIRA_HTTP_BODY_FILE")
		fpa_collected=$((fpa_collected + fpa_page_count))
		fpa_start=$((fpa_start + fpa_page_count))
		# is_last is "true"/"false"/"absent" — NOT `.isLast // false`: `//` also
		# fires on a JSON `false`, and (more importantly) isLast is ABSENT on the
		# issues envelope, so an explicit null-check keeps "absent" distinct from
		# "present and false" (the same trap cmd_search documents at its own loop).
		fpa_is_last=$(jq -r 'if .isLast == null then "absent" else (.isLast | tostring) end' "$JIRA_HTTP_BODY_FILE")
		# total is the row count, or -1 when the field is absent (epic values
		# envelope) — the -1 sentinel keeps the startAt>=total check from firing
		# spuriously on an endpoint that never reports a total.
		fpa_total=$(jq -r 'if .total == null then -1 else .total end' "$JIRA_HTTP_BODY_FILE")
		# Stop on an empty page (guards a missing/short total), OR isLast:true
		# (the values envelope's authoritative "no more pages"), OR once startAt
		# has reached a REPORTED total (issues envelope, and a values envelope
		# that does carry a total).
		[ "$fpa_page_count" -gt 0 ] || break
		[ "$fpa_is_last" != "true" ] || break
		if [ "$fpa_total" -ge 0 ] && [ "$fpa_start" -ge "$fpa_total" ]; then
			break
		fi
	done
	# shellcheck disable=SC2034  # read by every agile cmd_* as the row count; shellcheck lints this unit alone and cannot see them
	AGILE_COLLECTED=$fpa_collected
}
