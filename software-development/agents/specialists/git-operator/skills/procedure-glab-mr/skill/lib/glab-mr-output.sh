# shellcheck shell=sh
#
# glab-mr-output.sh — the helpers that READ `glab`'s output: turning an
#                     UNTRUSTED external stream into values this skill's command
#                     scripts are willing to act on.
#
# SOURCED, NEVER EXECUTED. Sourced alongside glab-mr-common.sh by create-mr.sh
# and update-mr.sh; find-mr.sh sources it for normalize_mr_rows alone.
#
# WHY THIS IS A SEPARATE FILE FROM glab-mr-common.sh, and must stay one:
#   Everything here parses bytes this skill does not control — glab's rendered
#   stdout/stderr, which can contain an MR TITLE an outside party chose. That
#   makes these three functions a SECURITY SURFACE with its own change history
#   (SEC-001 host pinning, SEC-002 the host-anchored project match below, SEC-003
#   pooling both captured streams so a spoof cannot be the only candidate seen).
#   They change for reasons diagnostics, validators and comma-splitting never
#   share. procedure-gh-pr has NO equivalent surface — `gh` answers in JSON via
#   `--jq`, so there is nothing to shape-match — which is why that skill has one
#   lib and this one has two. Do NOT collapse these back together for symmetry.
#
# WHAT THIS FILE DOES NOT DO — it does NOT decide POLICY for how many candidates
# turned up. Finding 0, 1, or 2+ means different things to different callers:
# create-mr.sh EXITS 1 on ambiguity (its URL is load-bearing — the iid every
# follow-up operation is keyed off is derived from it), while update-mr.sh only
# WARNS and leaves PM_MR_URL empty (its URL is a documented courtesy field, and
# the edit already succeeded). That divergence is real and belongs at the call
# sites, not in here.
#
# `set -eu` is deliberately NOT re-asserted (the caller has it, and sourcing must
# return 0), and the file ENDS with a function definition for the same reason.
# Every function here is awk-based, and awk always exits 0, so none of them can
# trip the caller's `set -e` on a legitimately empty result.
#

# normalize_mr_rows VALUE — print the `glab mr list --jq` result as clean
# "iid<TAB>web_url" lines, dropping empties.
#
# Two normalizations, both no-ops for the expected output and both cheap
# insurance against glab's --jq string rendering differing from `gh`'s: a
# JSON-encoded "\t" is turned back into a real tab, and any double quotes glab
# may have kept around the rendered string are removed. Neither an iid nor a
# GitLab web_url can legitimately contain a quote, so the stripping cannot
# corrupt a good value. awk always exits 0, so this never trips `set -e`.
#
# find-mr.sh and create-mr.sh call this. update-mr.sh correctly has NO call site
# — it never runs `glab mr list` — so do not add one.
normalize_mr_rows() {
	printf '%s\n' "$1" | awk '
		{
			gsub(/\\t/, "\t")
			gsub(/"/, "")
			if ($0 != "") print
		}
	'
}

# extract_mr_url_candidates TEXT REPO — print every DISTINCT whitespace-delimited
# token in TEXT that is a merge-request URL OF THIS PROJECT, one per line, in
# first-appearance order. Prints nothing when there is no such token.
#
# `glab mr create` prints a human-oriented block and `glab mr update` its own,
# and neither decoration is a documented contract, so the URL is located by SHAPE
# rather than by line or column position. awk always exits 0, so this never trips
# `set -e`.
#
# THE ONE PLACE THE DEDUP/AMBIGUITY RATIONALE IS WRITTEN OUT — every call site
# points here instead of restating it:
#   * glab prints the MR TITLE on the line BEFORE the URL, so a title that merely
#     LOOKS like an MR URL (adversarial, or one that just quotes a link) used to be
#     picked up instead of the real URL: the first shape match in the whole captured
#     output won, and PM_MR_URL/PM_MR_NUMBER then pointed at something the caller
#     never created.
#   * So a candidate must be a URL of the CONFIRMED --repo project, ALL distinct
#     candidates are reported, and the dedup keeps the FIRST occurrence of each
#     distinct value while dropping every later repeat.
#   * Therefore the output holds AT MOST ONE LINE PER DISTINCT URL. The caller never
#     chooses between occurrences: it either has exactly one surviving line and takes
#     it, or it has 2+ — which can only mean genuinely different URLs, i.e. ambiguity
#     or a spoof — and fails closed. Identical repeats collapse to one candidate, so
#     a title quoting the real URL verbatim is harmless.
#
# HOW THE PROJECT MATCH IS ANCHORED (SEC-002): the repo path must follow the HOST
# DIRECTLY. An unanchored `index($i, "/" repo "/")` substring test accepted the
# project path at ANY depth under ANY host, so
# "https://attacker.example/x/<repo>/-/merge_requests/5" qualified — the ambiguity
# guard usually caught it (a genuine URL is normally present too, making 2+
# candidates), but the filter must not lean on that backstop alone. So: scheme +
# host are stripped, the remainder's LITERAL prefix must be "<repo>/", and what
# follows must be GitLab's own MR route. The prefix test is a literal string
# compare, never a regex, so a '.' in a project path cannot act as a wildcard and
# no metacharacter escaping is needed.
extract_mr_url_candidates() {
	printf '%s\n' "$1" | awk -v repo="$2" '
		{
			for (i = 1; i <= NF; i++) {
				tok = $i
				if (tok !~ /^https?:\/\/[^\/]+\//) continue
				path = tok
				sub(/^https?:\/\/[^\/]+\//, "", path)
				if (substr(path, 1, length(repo) + 1) != repo "/") continue
				rest = substr(path, length(repo) + 2)
				if (rest !~ /^(-\/)?merge_requests\/[0-9]+$/) continue
				if (tok in seen) continue
				seen[tok] = 1
				print tok
			}
		}
	'
}

# count_lines TEXT — number of lines in TEXT, 0 for the empty string. awk's
# END{print NR} counts RECORDS, so a final line with no trailing newline still
# counts (unlike `wc -l`, which counts newline BYTES), and it always exits 0.
count_lines() {
	[ -n "$1" ] || { printf '0\n'; return 0; }
	printf '%s\n' "$1" | awk 'END { print NR }'
}
