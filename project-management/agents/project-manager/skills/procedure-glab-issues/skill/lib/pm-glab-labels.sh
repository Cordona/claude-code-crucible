# shellcheck shell=sh
#
# pm-glab-labels.sh — label enumeration for the procedure-glab-issues commands.
#
# CALLER CONTRACT: source pm-diag.sh FIRST. list_all_labels below calls
# pm_strip_jq_quotes, count_lines and warn, all of which live there. (POSIX sh
# resolves a function name at CALL time, so the order only has to hold for the
# sourcing script, which every command already satisfies.)
#
# pm_strip_jq_quotes used to live HERE, and find-duplicate.sh — which needs the
# normalizer but not a single label — had to source this whole unit to reach it,
# inheriting the two page-size constants below as dead weight. It is a generic
# jq-row normalizer with no label topic, so it now lives in pm-diag.sh with the
# other shared text helpers.

# ---------------------------------------------------------------------------
# Label lookup paging.
#
# `glab label list` has NO `--paginate` equivalent (unlike `gh api`, which the
# GitHub sibling uses) and its own default page size is only 30 — so a single
# bare call reads just the first page. BOTH consumers were broken by that, in
# different directions, which is why the page walk exists:
#   * create-issue.sh would MISS every label past the first page and report a
#     perfectly real label as "not found", refusing a legitimate create;
#   * ensure-labels.sh would MISS it and then try to RE-CREATE a label that
#     already exists — glab rejects that, so the run reported a spurious
#     failure.
# Hence an explicit page walk with the API's maximum page size.
# ---------------------------------------------------------------------------
LABELS_PER_PAGE=100
LABELS_MAX_PAGES=50

# list_all_labels REPO — print every label name in REPO, one per line, walking
# `glab label list` a page at a time until a SHORT page proves the last page was
# reached. Returns 1 if any page query fails.
#
# CALLER CONTRACT: $TMP_ERR must already exist — glab's own diagnostics
# accumulate there (appended, not truncated, so a failure on page 3 does not
# erase pages 1-2), and the caller prints it when this returns 1.
list_all_labels() {
	_repo=$1
	_page=1
	while [ "$_page" -le "$LABELS_MAX_PAGES" ]; do
		if ! _raw=$(glab label list --repo "$_repo" --output json \
			--per-page "$LABELS_PER_PAGE" --page "$_page" \
			--jq '.[].name' 2>>"$TMP_ERR"); then
			return 1
		fi
		_clean=$(pm_strip_jq_quotes "$_raw")
		[ -n "$_clean" ] || return 0
		printf '%s\n' "$_clean"
		_count=$(count_lines "$_clean")
		[ "$_count" -ge "$LABELS_PER_PAGE" ] || return 0
		_page=$((_page + 1))
	done
	warn "label lookup stopped after $LABELS_MAX_PAGES pages — a label beyond the first $((LABELS_MAX_PAGES * LABELS_PER_PAGE)) may be misreported as missing"
	return 0
}
