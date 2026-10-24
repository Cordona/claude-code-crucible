# shellcheck shell=sh
#
# accounts.sh — the accountId resolver: "@me" -> GET /myself, anything else
#               (an email/username) -> GET /user/search.
#
# assignee/developer/reviewer/watcher values are NEVER sent to Jira as raw
# email/username strings — they are resolved to an opaque accountId here first,
# by every caller, on both the READ (search --assignee) and WRITE paths.
#
# Sourced by jira.sh — never executed directly. Sets no shell options and
# runs no top-level work beyond its own declarations, so sourcing it always
# returns 0 under `set -e`.

# ---------------------------------------------------------------------------
# accountId resolver
# ---------------------------------------------------------------------------

# USER_SEARCH_MAX_RESULTS — the explicit cap on /user/search's result page. 50 is
# Jira's own default page size, the same figure agile-paging.sh's AGILE_PAGE_SIZE
# and cmd-discover.sh's DISCOVER_PAGE_SIZE already pin for the same reason: an
# implicit server-side default is not a number this engine can reason about.
#
# It is a CAP, not a page size, and deliberately NOT paginated: this lookup asks
# "does exactly one user match this value exactly", and that question cannot be
# answered from a page — a second identical match one row past the cap would be
# invisible and the resolver would name a principal it never saw a rival for. So
# a SATURATED result set is treated as an incomplete answer and fails loud below,
# rather than walking startAt (which would spend unbounded round trips on a fuzzy
# substring search whose only acceptable outcome is a single exact hit anyway).
#
# The REQUEST asks for CAP + 1 rows, ONE MORE than the cap it enforces, and that
# extra row is what distinguishes the two cases: requesting exactly the cap makes
# a COMPLETE 50-match set byte-identical to a TRUNCATED one, so an exact, unique
# email would be refused whenever the site happens to hold exactly 50 fuzzy
# matches for it. Asking for 51 removes that case — 51 back proves the true set
# is at least 51 and genuinely beyond what uniqueness can be judged from, while
# 50 or fewer back proves the whole set was captured and the exact-match test
# below is looking at all of it.
USER_SEARCH_MAX_RESULTS=50

# resolve_account_id VALUE -> prints the resolved accountId. VALUE "@me"
# (the oracle's own convention for a direct field value, distinct from the
# JQL-only "me" shortcut below) resolves via GET /myself; anything else
# resolves via GET /user/search?query=VALUE. Exits 1 if no user is found, if
# VALUE does not identify exactly one of them (see the ambiguity guard below), or
# if the result set came back SATURATED (see USER_SEARCH_MAX_RESULTS above — a
# non-exhaustive set cannot establish uniqueness).
#
# WHY AN AMBIGUOUS MATCH IS A FAILURE, NOT A PICK. /user/search is a FUZZY,
# UNORDERED substring search: "sam" matches sam@x.com, samantha@x.com and
# "Sam Okafor" alike, in whatever order Jira feels like returning them. Taking
# .[0] therefore names a principal by coin flip, and the write then SUCCEEDS —
# nothing downstream reveals the wrong person was chosen. So a 2+ result set
# resolves only when EXACTLY ONE entry matches VALUE exactly (emailAddress or
# displayName, case-insensitively); otherwise it fails loud.
#
# The diagnostic names the COUNT and the caller's own VALUE, never the other
# matched users' emails or display names: those are third parties' PII, and an
# error stream lands in logs and transcripts they never see. That value is
# rendered from $rai_safe_value, never the raw parameter — see its note below.
resolve_account_id() {
	rai_value=$1
	if [ "$rai_value" = "@me" ]; then
		rai_url="https://${CONFIRMED_HOST}/rest/api/3/myself"
		jira_curl GET "$rai_url"
		handle_http_status "$JIRA_HTTP_CODE" "resolve @me via /myself"
		require_json_body "resolve @me via /myself"
		rai_account_id=$(jq -r '.accountId // empty' "$JIRA_HTTP_BODY_FILE")
		[ -n "$rai_account_id" ] || { error "GET /myself returned no accountId"; exit 1; }
		printf '%s' "$rai_account_id"
		return 0
	fi

	# The ONE rendering of this value that a human or an agent ever reads: every
	# diagnostic below interpolates THIS, never $rai_value. The raw value is the
	# caller's own typed string, so a crafted one carrying a newline would otherwise
	# forge a line on stderr — a second "jira.sh: error: …" an agent reading this
	# engine's output takes for the engine's own verdict, the same forgery
	# one_line_display stops at cmd-update.sh's consent gate (see runtime.sh).
	# The wire is unaffected: the lookup below sends the untouched, urlencoded value.
	rai_safe_value=$(one_line_display "$rai_value")

	rai_encoded=$(urlencode "$rai_value")
	rai_url="https://${CONFIRMED_HOST}/rest/api/3/user/search?query=${rai_encoded}&maxResults=$((USER_SEARCH_MAX_RESULTS + 1))"
	jira_curl GET "$rai_url"
	handle_http_status "$JIRA_HTTP_CODE" "resolve accountId for '$rai_safe_value' via /user/search"
	require_json_body "resolve accountId for '$rai_safe_value' via /user/search"
	# A non-array body (an unexpected response shape) counts as zero matches and
	# falls into the no-user-found failure below, rather than reaching `.[0]` and
	# dying on jq's own "cannot index object with number".
	rai_match_count=$(jq 'if type == "array" then length else 0 end' "$JIRA_HTTP_BODY_FILE")
	if [ "$rai_match_count" -eq 0 ]; then
		error "no Jira user found for '$rai_safe_value'"
		exit 1
	fi
	# A saturated result set cannot establish uniqueness — the test below sees only
	# what came back. See USER_SEARCH_MAX_RESULTS above for the full rationale and
	# for why the request asks for one row MORE than this threshold.
	if [ "$rai_match_count" -gt "$USER_SEARCH_MAX_RESULTS" ]; then
		error "/user/search returned more than $USER_SEARCH_MAX_RESULTS results for '$rai_safe_value' — the match set is not exhaustive, so no unique match can be established; pass the full email address or display name"
		exit 1
	fi
	# `| objects` on both paths: a malformed response whose array holds
	# non-objects (a bare string, a number) would otherwise reach .emailAddress/
	# .accountId and die on jq's own type error with jq's exit status (5),
	# OUTSIDE this script's documented 0/1/2 contract. Filtered out instead, such
	# an element counts as no match and falls into the failures below.
	if [ "$rai_match_count" -eq 1 ]; then
		rai_account_id=$(jq -r '(.[0] | objects | .accountId) // empty' "$JIRA_HTTP_BODY_FILE")
		[ -n "$rai_account_id" ] || { error "no Jira user found for '$rai_safe_value'"; exit 1; }
	else
		# ascii_downcase folds ONLY A-Z, so the exact-match test is
		# case-insensitive for ASCII alone: a display name differing from the
		# typed value only in NON-ASCII case ("JOSÉ" vs "josé") is not recognized
		# as an exact match and this resolver then refuses rather than guessing.
		# That is the safe direction — a refusal is visible, a coin-flip pick is
		# not — but it is why a value that looks right can still be rejected. Pass
		# the byte-exact display name, or the email address, to get past it.
		rai_account_id=$(jq -r --arg v "$rai_value" \
			'($v | ascii_downcase) as $want
			 | [ .[] | objects
			         | select((((.emailAddress // "") | ascii_downcase) == $want)
			                  or (((.displayName // "") | ascii_downcase) == $want)) ]
			 | if length == 1 then (.[0].accountId // empty) else empty end' \
			"$JIRA_HTTP_BODY_FILE")
		[ -n "$rai_account_id" ] || {
			error "$rai_match_count Jira users matched '$rai_safe_value' and none of them is a unique exact match — pass the full email address or display name"
			exit 1
		}
	fi
	printf '%s' "$rai_account_id"
}
