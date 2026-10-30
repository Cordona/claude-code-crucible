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
#   makes these functions a SECURITY SURFACE with its own change history
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
# The parsing is awk-based. Every parser except one always exits 0, so it cannot
# trip the caller's `set -e` on a legitimately empty result; the one predicate,
# is_cloudflare_error_page, is only ever called as a condition.
#
# The Cloudflare helpers at the end of this file read glab's captured stderr
# ($TMP_ERR) and use emit_captured_stderr/error/warn from glab-mr-common.sh,
# resolved at call time like every cross-file call here.
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

# ---------------------------------------------------------------------------
# Cloudflare error pages. When Cloudflare fronts a GitLab instance, a failed
# request can come back as Cloudflare's OWN HTML error page instead of GitLab's
# JSON. glab relays it verbatim ("403 failed to parse unknown error format:
# <!DOCTYPE html> …"), a wall of markup that names neither the cause nor the
# fix. The same template serves very different situations — a WAF/firewall
# block (403, the request never reached GitLab), an origin error or timeout
# (5xx, e.g. 524, where the request MAY have reached GitLab), a rate limit
# (1015, 429) — so only the HTTP status, not the page itself, tells them apart.
# ---------------------------------------------------------------------------

# emit_glab_write_failure_detail CONTENT ORIGIN_ERROR_NOTE — the detail block for
# a failed `glab mr create`/`update`, printed on stderr right after the caller's
# own error() line. Anything that is not a Cloudflare error page falls through to
# emit_captured_stderr unchanged, so every other failure reads as it always has.
#
# A Cloudflare page gets a neutral report (glab's lead-in, the page's title and
# Ray ID, never its HTML), then ONE status-specific addition:
#   * 403 — the access-block statuses of this template: the WAF explanation.
#     CONTENT names what the request carried that most likely triggered it
#     (e.g. "the MR description").
#   * 5xx — ORIGIN_ERROR_NOTE, a warning about what may already have happened at
#     GitLab; empty for none.
# Any other status gets the neutral report alone.
emit_glab_write_failure_detail() {
	# shellcheck disable=SC2154  # TMP_ERR is the global init_tmp_err (glab-mr-common.sh) sets before any glab call
	if ! is_cloudflare_error_page "$TMP_ERR"; then
		emit_captured_stderr
		return 0
	fi
	print_text_before_html "$TMP_ERR" | sed 's/^/  /' >&2
	error "Cloudflare returned its own HTML error page instead of GitLab's response (the HTML is not shown)"
	print_cloudflare_page_identity "$TMP_ERR" | sed 's/^/  /' >&2
	case $(print_text_before_html "$TMP_ERR" | print_http_status) in
		403)
			error "Cloudflare blocked the request before it reached GitLab"
			warn  "most likely cause: $1 — raw shell command lines (curl/wget with -H/-d headers) are the known trigger"
			warn  "rewrite such steps as prose (describe the request instead of pasting the command) and retry"
			;;
		5[0-9][0-9])
			[ -z "$2" ] || warn "$2"
			;;
		*) ;;
	esac
}

# is_cloudflare_error_page FILE — 0 when FILE holds an HTML document built from
# Cloudflare's error-page template, 1 otherwise. Unlike the helpers above this
# one is a PREDICATE, so its non-zero status is meaningful: call it only as an
# `if`/`!` condition, where it cannot trip `set -e`.
#
# WHY THESE MARKERS:
#   * "cf-error-details" (the template's details element) or "cf.errors.css"
#     (its stylesheet) — markup only Cloudflare's own error template carries.
#     A bare "/cdn-cgi/" is NOT enough: Cloudflare can inject /cdn-cgi/ script
#     references into ANY HTML it proxies, GitLab's included.
#   * An HTML document opener ("<!doctype html" or an "<html" tag), because a
#     GitLab API error is JSON, which glab renders as text. Requiring it as well
#     stops a JSON message that merely QUOTES a marker (an echoed field value,
#     say) from being read as a Cloudflare page.
# Cloudflare's challenge pages use a different template and are not matched;
# they keep the plain captured-stderr output.
# Matching is case-insensitive (tolower — byte-wise under the lib's LC_ALL=C).
is_cloudflare_error_page() {
	awk '
		{ line = tolower($0) }
		line ~ /<!doctype html|<html([ >]|$)/                 { has_html = 1 }
		index(line, "cf-error-details") || index(line, "cf.errors.css") { has_template = 1 }
		END { exit !(has_html && has_template) }
	' "$1"
}

# print_text_before_html FILE — print FILE's lines up to the HTML document
# opener, plus the part of the opener's own line that precedes it, with trailing
# whitespace trimmed and empty results dropped. That is glab's own lead-in
# ("POST https://…: 403 failed to parse unknown error format:"), which keeps the
# endpoint and status visible while the markup is withheld.
print_text_before_html() {
	awk '
		{
			line = tolower($0)
			cut = match(line, /<!doctype html|<html([ >]|$)/)
			text = cut ? substr($0, 1, cut - 1) : $0
			sub(/[ \t\r]+$/, "", text)
			if (text != "") print text
			if (cut) exit
		}
	' "$1"
}

# print_http_status — read glab's lead-in on stdin and print the HTTP status
# glab reported, or nothing. glab writes "<METHOD> <url>: <status> <message>",
# and the lead-in may arrive wrapped across lines, so the lines are joined and
# the status is the first three-digit token right after a ": ". A URL's own
# colons ("https:", "host:port") are never followed by a space, so they cannot
# match.
print_http_status() {
	awk '
		{ joined = joined " " $0 }
		END {
			if (match(joined, /: +[0-9][0-9][0-9]( |$)/)) {
				status = substr(joined, RSTART, RLENGTH)
				gsub(/[^0-9]/, "", status)
				print status
			}
		}
	'
}

# print_cloudflare_page_identity FILE — print the error page's <title> and its
# Cloudflare Ray ID, one "label: value" line each, omitting either when absent.
# The Ray ID is what a Cloudflare zone admin needs to find the matching event.
# The page is UNTRUSTED, so both values are reduced to printable ASCII and
# length-capped before they reach the terminal, and the Ray ID is accepted only
# as a single alphanumeric token.
print_cloudflare_page_identity() {
	awk '
		{ page = page " " $0 }
		END {
			lower = tolower(page)
			if (match(lower, /<title[^>]*>[^<]*<\/title>/)) {
				title = substr(page, RSTART, RLENGTH)
				sub(/^<[^>]*>/, "", title)
				sub(/<[^>]*>$/, "", title)
				print_field("page title", title, 120)
			}
			text = page
			gsub(/<[^>]*>/, " ", text)
			if (match(text, /Ray ID:[ \t]*[0-9A-Za-z]+/)) {
				ray = substr(text, RSTART, RLENGTH)
				sub(/^Ray ID:[ \t]*/, "", ray)
				print_field("Cloudflare Ray ID", ray, 32)
			}
		}
		function print_field(label, value, max_len) {
			gsub(/[^ -~]/, " ", value)
			gsub(/  +/, " ", value)
			sub(/^ /, "", value)
			sub(/ $/, "", value)
			if (length(value) > max_len) value = substr(value, 1, max_len) "..."
			if (value != "") print label ": " value
		}
	' "$1"
}
