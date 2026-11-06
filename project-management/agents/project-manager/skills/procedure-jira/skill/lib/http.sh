# shellcheck shell=sh
#
# http.sh — the ONLY unit in this engine that invokes `curl`. Every request
#           leaves through jira_curl (JSON), jira_curl_multipart (attachment
#           upload), fetch_attachment_content_redirect (the egress that must
#           hold a 3xx to read its Location, shared by both resolve_media_*
#           helpers), or download_attachment_content (the media-CDN fetch) —
#           and ALL FOUR re-assert the same security invariants before sending:
#             * nothing secret on argv: both the site token and the media URL's
#               own embedded JWT travel in a -K config (a 600 file for the
#               token, stdin for the URL), never as a curl argument `ps` could
#               show;
#             * the URL's host is re-checked immediately before sending, fail
#               closed — assert_confirmed_host for the three Jira egresses,
#               is_media_host for the fourth;
#             * under $JIRA_READ_ONLY, a WRITE is refused (fail closed) — the
#               sink-side counterpart of jira.sh's one-shot
#               require_write_allowed. For the two curl senders that take a
#               method the test is "a non-GET method", with ONE named,
#               exactly-matched exception, POST /rest/api/3/search/jql (see
#               is_read_only_search_post).
#               fetch_attachment_content_redirect is the only sender exempt:
#               its method is a literal GET, not a parameter, and its whole
#               effect is reading a redirect header.
#               download_attachment_content is NOT exempt on that reasoning and
#               carries its own re-check — its dangerous effect is the LOCAL FILE
#               WRITE, which is what makes `attach --download` a write to
#               readonlygate.sh in the first place, and a GET method says nothing
#               about it;
#             * `-q` FIRST on every invocation, `--proto '=https'`, never -L,
#               never -k/--insecure.
#
# download_attachment_content is the FOURTH sender and the only one that aims at
# a host other than $CONFIRMED_HOST and sends no SITE credential — read its own
# header for why both are correct there. It lives here rather than in
# cmd-attach.sh for the same reason the other three do: a request reviewed
# anywhere else is a transport nobody reviews.
#
# EVERY RE-CHECK IN THIS UNIT IS DELIBERATELY INDEPENDENT — the two host pins
# (assert_confirmed_host, is_media_host), the scheme pin (assert_https_url) and
# the read-only re-checks alike. The defense is in checking at TWO POINTS OF THE
# CONTROL FLOW — where a URL or a mode is chosen, and again immediately before the
# egress — never in typing the literal or the comparison twice. So each pin owns
# its own comparison, its own literal and its own refusal; only the host
# EXTRACTION (url_host) is shared, because a weakness in how a pin FINDS the host
# is not a defense at all, just a bug that must never be fixed at one pin and
# missed at the other. Each function below documents only what is LOCAL to it —
# whether it is an assert or a predicate, what it does or does not case-fold, why
# its own call site needs the check — and leaves this rationale here.
#
# FLAG ORDER IS PART OF THE HARDENING, not cosmetic, and it has TWO rules.
#
# `-q` IS THE LITERAL FIRST ARGUMENT of all four invocations, and only there
# does it do anything: curl reads $CURL_HOME/$HOME/.curlrc BEFORE it processes
# argv, and `-q` suppresses that read only when it is the first parameter.
# Without it, a local .curlrc holding `insecure`, `cacert`, `proxy` or
# `location` would silently negate the invariants this unit asserts — a
# plaintext/unverified downgrade, a retargeted egress, or a followed redirect,
# including on the JWT-bearing media fetch. `-q` does NOT suppress an explicit
# `-K` config, so the credential handoff below is unaffected.
#
# `-K <config>` COMES BEFORE EVERY HARDENING FLAG — third argument today, after
# `-q -sS`, and the rule is its position relative to the flags it must not be
# able to override, not a fixed index: curl applies its options left to right and
# a later one WINS, so a directive inside the config file — today only
# `user = "..."`, but the file is supplied from outside via $JIRA_CURL_CONFIG —
# can never override the `--proto '=https'` pinning this unit asserts. Keep any
# new hardening flag after the -K, never move the -K below one, and never move
# the -q off the front. Both placements apply to download_attachment_content's
# `-K -` stdin config, whose one `url = "..."` directive this unit writes itself.
#
# Keeping every `curl` call in one file is the point of the unit: the transport's
# security guarantees are reviewed ONCE, here, instead of at each command.
# handle_http_status/require_json_body live here too — they are the response half
# of the same transport contract.
#
# Sourced by jira.sh — never executed directly. Sets no shell options and
# runs no top-level work beyond its own declarations, so sourcing it always
# returns 0 under `set -e`.

# is_read_only_search_post METHOD URL -> 0 iff METHOD/URL are the ONE non-GET
# request this engine may send under $JIRA_READ_ONLY: a POST to EXACTLY
# https://<CONFIRMED_HOST>/rest/api/3/search/jql, Jira's own JQL search
# endpoint. Stated here, ahead of all four curl senders, because it is the
# transport's read-only method policy rather than any one sender's own logic —
# even though only jira_curl, the sole sender a read can reach with a non-GET
# method, actually calls it.
#
# WHY AN EXCEPTION EXISTS AT ALL. `search` — and `children`, which drives its
# read through cmd_search rather than reimplementing it — is classified a READ
# by readonlygate.sh's is_write_invocation, correctly: it mutates nothing. But
# Jira's REST v3 search endpoint IS a POST. The JQL, the field list and the page
# token travel in a JSON BODY because a real query is too large/structured for a
# GET query string, so this is the API's own shape, not a write dressed as a
# read. The sink's "any non-GET IS the write the gate refuses" heuristic — right
# for every other endpoint this engine touches — was therefore wrong for exactly
# this one, and refused two of the five commands SKILL.md's read-only credential
# scope names (view/search/workflow/children/transition --plan).
#
# READ THIS BEFORE WIDENING IT. This is ONE NAMED ENDPOINT, not a policy that
# POST is sometimes trustworthy. The URL test is whole-string EQUALITY against a
# literal rebuilt from $CONFIRMED_HOST — never a prefix, substring or glob — so
# it admits that one URL and nothing that merely starts with, contains or
# resembles it (a `?`/`;` suffix, a `/rest/api/3/search/jql/...` extension, a
# path-traversal tail, a look-alike host). Adding a second "read that POSTs"
# means adding a second equally exact arm and justifying it here; relaxing this
# into a pattern match, or dropping the method half, silently re-opens the write
# channel the gate exists to close. Every other method/URL pair stays refused,
# fail-closed, exactly as before this exception existed.
is_read_only_search_post() {
	irosp_method=$1
	irosp_url=$2
	case "$irosp_method" in
		POST) [ "$irosp_url" = "https://${CONFIRMED_HOST}/rest/api/3/search/jql" ] ;;
		*) return 1 ;;
	esac
}

# url_host URL -> prints URL's host: the `https://` scheme stripped, everything
# from the first `/` onward cut.
#
# ONE EXTRACTION, SHARED BY BOTH HOST PINS — assert_confirmed_host below and
# is_media_host further down; see this file's header for why only the extraction
# is shared. What sharing it closes is a future hardening of the extraction itself
# — userinfo (`https://real-host@evil/`), an explicit port, a bare authority with
# no path — landing at one security-critical pin and missing the other.
#
# DELIBERATELY NOT CASE-FOLDED, unlike both of its callers' comparisons. Each pin
# folds at its own comparison instead, because assert_confirmed_host's diagnostic
# must report the host AS THE CALLER SPELLED IT, which a folding extraction
# cannot give it back.
url_host() {
	printf '%s' "$1" | sed -E 's#^https://##; s#/.*##'
}

# assert_https_url URL — refuse the send (exit 1) unless URL's scheme is https.
# The scheme check of the two senders that receive a URL as a PARAMETER
# (jira_curl, jira_curl_multipart), where it was previously spelled inline and
# byte-identically in both. An ASSERT rather than a predicate for the same
# reason assert_confirmed_host is one: the two refusals were byte-identical, so
# the MESSAGE is part of what was duplicated and is owned here.
#
# IT RUNS BEFORE THE HOST PIN, which is a diagnostic correction as much as a
# de-duplication: with the host check first, `http://<confirmed-host>/...` was
# refused as a host MISMATCH — url_host leaves a non-https scheme attached, so
# the host can never match — reporting the wrong reason for the right refusal.
#
# fetch_attachment_content_redirect deliberately does NOT call it: it is the one
# sender that BUILDS its URL, from an `https://` literal on the line above its
# own assert, rather than receiving one from another unit.
assert_https_url() {
	case "$1" in
		https://*) : ;;
		*) error "internal: refusing a non-https URL: $1"; exit 1 ;;
	esac
}

# assert_confirmed_host URL — refuse the send (exit 1) unless URL's host is the
# confirmed site. The host-pin re-check of the THREE Jira-bound senders
# (jira_curl, jira_curl_multipart, fetch_attachment_content_redirect); the
# fourth, download_attachment_content, aims at the media CDN and pins against
# is_media_host instead. Safe on every URL this engine can currently build
# (all three are built from $CONFIRMED_HOST) — it is an assertion against a
# FUTURE bug in a security-critical sink, the "fail secure" posture
# standard-security asks for, not dead code kept for its own sake.
#
# AN ASSERT, NOT A PREDICATE — deliberately unlike is_media_host, whose two call
# sites wrap it in two DIFFERENT diagnostics, which is why a bare predicate is
# right there. All three $CONFIRMED_HOST refusals were byte-identical, so the
# MESSAGE is part of what was duplicated and is owned here too; the callers keep
# only the call.
#
# The comparison is UNCONDITIONAL — $CONFIRMED_HOST, never an overridable
# ${VAR:-default}, since a pin the environment can retarget is not a pin.
# Case-FOLDED on BOTH sides, matching is_media_host and credentials.sh's
# host-binding check, because hostnames are case-insensitive and
# sitegate.sh's normalize_site preserves the caller's own casing. The
# diagnostic still reports the host AS EXTRACTED, unfolded.
assert_confirmed_host() {
	ach_host=$(url_host "$1")
	if [ "$(downcase "$ach_host")" != "$(downcase "$CONFIRMED_HOST")" ]; then
		error "internal: refusing to send a request to '$ach_host' — it does not match the confirmed site '$CONFIRMED_HOST' (fail closed)"
		exit 1
	fi
}

# jira_curl METHOD URL [DATA_FILE] [CONTENT_TYPE]
# Sets $JIRA_HTTP_BODY_FILE (the response body, always a FRESH file — never
# reused across calls, so a caller holding an earlier response's path stays
# valid after a later call) and $JIRA_HTTP_CODE (the numeric HTTP status).
jira_curl() {
	jc_method=$1
	jc_url=$2
	jc_data_file=${3:-}
	jc_content_type=${4:-application/json}

	assert_https_url "$jc_url"
	assert_confirmed_host "$jc_url"

	# Read-only re-check — this unit's two-points-of-the-control-flow rule (see
	# the file header) applied to lib/readonlygate.sh's gate. jira.sh asserts
	# require_write_allowed ONCE, at dispatch; that classification is correct
	# today, so nothing this engine can currently dispatch reaches here with a
	# non-GET method under $JIRA_READ_ONLY. It is an assertion against a FUTURE
	# bug in a security-critical sink — a newly added command classified as a
	# read by omission, or a "read" command that grows a write path (an
	# attachment upload is already reachable from create/update/comment) — at
	# the one place such a bug is still catchable: the network egress itself.
	# GET is the only method this engine reads with, save the ONE exactly-matched
	# endpoint is_read_only_search_post names, so any other method/URL pair IS
	# the write the gate refuses. Fails closed (exit 1), like every check above
	# it — and note the exception cannot smuggle a request to another host: its
	# comparison is against a URL rebuilt from the same $CONFIRMED_HOST the
	# re-check above pins.
	if is_read_only_requested && [ "$jc_method" != GET ] \
		&& ! is_read_only_search_post "$jc_method" "$jc_url"; then
		error "internal: \$JIRA_READ_ONLY is set: refusing to send $jc_method $jc_url — read-only mode permits GET, plus POST to /rest/api/3/search/jql alone (fail closed)"
		exit 1
	fi

	ensure_workdir
	RESP_COUNTER=$((RESP_COUNTER + 1))
	JIRA_HTTP_BODY_FILE="$WORKDIR/resp-$RESP_COUNTER.json"

	set -- curl -q -sS -K "$CURL_CONFIG_FILE" --proto '=https' \
		-H 'Accept: application/json' \
		-X "$jc_method" \
		-o "$JIRA_HTTP_BODY_FILE" \
		-w '%{http_code}'

	if [ -n "$jc_data_file" ]; then
		set -- "$@" -H "Content-Type: $jc_content_type" --data "@$jc_data_file"
	fi

	set -- "$@" "$jc_url"

	if ! JIRA_HTTP_CODE=$("$@"); then
		error "curl request failed (network/TLS error) for $jc_method $jc_url"
		exit 1
	fi
}

# jira_curl_multipart METHOD URL FILES_NL — the multipart/form-data sibling
# of jira_curl(), for attachment upload. Sends one `-F file=@PATH` part per
# newline-terminated path in FILES_NL, with NO JSON content-type (curl builds
# the multipart body + its own boundary). Preserves EVERY security property of
# jira_curl: the auth token stays in the `-K` config file (NEVER on argv, so
# it can't leak via `ps`), the host is pinned to $CONFIRMED_HOST (fail closed),
# `--proto '=https'` forbids a plaintext downgrade, and no redirect is followed.
# Sets $JIRA_HTTP_BODY_FILE + $JIRA_HTTP_CODE identically to jira_curl, so
# handle_http_status / require_json_body work against it unchanged. Adds Jira's
# `X-Atlassian-Token: no-check` XSRF opt-out (required by the attachments API).
jira_curl_multipart() {
	mp_method=$1
	mp_url=$2
	mp_files=$3

	assert_https_url "$mp_url"
	assert_confirmed_host "$mp_url"

	# Read-only re-check — the same fail-closed assertion jira_curl() carries, its
	# own copy rather than an inherited one, for the reason the file header gives.
	# It bites hardest in THIS helper: the multipart egress is an attachment
	# upload, reachable from create/update/comment's inline-image path as well
	# as from `attach`, so a future misclassification of any of those would land
	# here first.
	#
	# GET-ONLY HERE, DELIBERATELY: jira_curl's POST /rest/api/3/search/jql
	# exception is NOT repeated, because no read can reach this helper. Every
	# caller sends multipart/form-data to /rest/api/3/issue/<KEY>/attachments
	# (cmd-attach.sh's upload and inline-images.sh's pre-pass — checked, those
	# are the only two), which is an unambiguous WRITE; the search endpoint takes
	# a JSON body and is never requested through here. Copying the exception over
	# "for symmetry" would widen the permitted surface for zero capability, which
	# is the direction this gate must never move.
	if is_read_only_requested && [ "$mp_method" != GET ]; then
		error "internal: \$JIRA_READ_ONLY is set: refusing to send $mp_method $mp_url — read-only mode permits GET only (fail closed)"
		exit 1
	fi

	ensure_workdir
	RESP_COUNTER=$((RESP_COUNTER + 1))
	JIRA_HTTP_BODY_FILE="$WORKDIR/resp-$RESP_COUNTER.json"

	set -- curl -q -sS -K "$CURL_CONFIG_FILE" --proto '=https' \
		-H 'Accept: application/json' \
		-H 'X-Atlassian-Token: no-check' \
		-X "$mp_method" \
		-o "$JIRA_HTTP_BODY_FILE" \
		-w '%{http_code}'

	# Append one `-F file=@PATH` part per path. POSIX sh has no arrays, so the
	# paths arrive as one NL-terminated line each; a here-doc while-read runs in
	# THIS shell (no subshell, so the `set --` accumulation survives) and never
	# word-splits/globs the path (unlike `for p in $mp_files`).
	#
	# SECURITY — the path is ESCAPED, then wrapped in DOUBLE QUOTES inside the
	# -F value (file=@"PATH"): curl parses an unquoted `-F` @-path's `;` and `,`
	# as parameter separators (`;type=`, `;filename=`, and `,` starting the next
	# part), so a crafted path like `/tmp/a;type=text/html` could otherwise
	# inject a form parameter / override the declared mime. Double-quoting the
	# @-path makes curl treat those bytes literally as the filename — BUT a `"`
	# or `\` embedded in the path is itself special INSIDE curl's quoted value:
	# `/tmp/a";type=text/html` would break out of the quotes and inject a mime
	# override, and `/tmp/a",/etc/passwd` a second `@`-file part. So we escape
	# backslash FIRST, then the double quote (same order + helper shape as
	# curl_config_escape), before wrapping — closing the breakout.
	while IFS= read -r mp_path; do
		[ -n "$mp_path" ] || continue
		mp_esc=$(printf '%s' "$mp_path" | sed 's/\\/\\\\/g; s/"/\\"/g')
		set -- "$@" -F "file=@\"$mp_esc\""
	done <<-MULTIPART_FILES_EOF
	$mp_files
	MULTIPART_FILES_EOF

	set -- "$@" "$mp_url"

	# shellcheck disable=SC2034  # the response status every caller passes to handle_http_status; those callers live in other units
	if ! JIRA_HTTP_CODE=$("$@"); then
		error "curl request failed (network/TLS error) for $mp_method $mp_url"
		exit 1
	fi
}

# handle_http_status CODE ACTION_DESC — exits 1 with Jira's own error
# message (if any, stripped of control/ANSI) on a non-2xx response.
handle_http_status() {
	hhs_code=$1
	hhs_action=$2
	case "$hhs_code" in
		2??) return 0 ;;
	esac
	error "$hhs_action failed (HTTP $hhs_code)"
	if [ -s "$JIRA_HTTP_BODY_FILE" ]; then
		jq -r '(.errorMessages // [])[], (.errors // {} | to_entries[] | "\(.key): \(.value)")' \
			"$JIRA_HTTP_BODY_FILE" 2>/dev/null | strip_control_ansi >&2 || true
	fi
	exit 1
}

# require_json_body ACTION_DESC — call right after a 2xx handle_http_status
# passes, for any endpoint whose success response this script expects to be
# JSON (every call site in this phase). Without this, a 2xx response with a
# malformed body (e.g. an intermediary proxy's HTML error page) would reach
# an unguarded jq call further downstream and abort with JQ'S OWN exit code
# (2) under `set -e` — colliding with this script's documented "2 = usage
# error" contract for a failure that has nothing to do with usage. Reported
# the same way as any other API failure: exit 1.
require_json_body() {
	rjb_action=$1
	if ! jq -e . "$JIRA_HTTP_BODY_FILE" >/dev/null 2>&1; then
		error "$rjb_action failed: response body was not valid JSON"
		exit 1
	fi
}

# fetch_attachment_content_redirect ATTACHMENT_ID LABEL — the ONE request behind
# both resolve_media_* helpers below: GET /attachment/content/<id>, which Jira
# answers with a 303 whose Location is
# https://api.media.atlassian.com/file/<UUID>/binary?token=<JWT>. Dumps the
# response headers into a trap-cleaned $WORKDIR file it allocates ITSELF and
# publishes as $FACR_HEADER_FILE (the body goes to /dev/null), and returns only
# once the status is confirmed 3xx. Every failure exits 1, LABEL naming the
# operation the caller is performing ("resolve media uuid" / "resolve media
# download url") and never any byte of the Location.
#
# IT OWNS THE ALLOCATION, like jira_curl owns $JIRA_HTTP_BODY_FILE for its ~25
# callers: both resolvers below used to repeat the same ensure_workdir +
# $RESP_COUNTER + path-build preamble and pass the result in, differing only in
# a filename prefix that was never load-bearing. Read $FACR_HEADER_FILE
# IMMEDIATELY after the call and do not hold the path across another one — both
# resolvers run inside a command substitution, where the $RESP_COUNTER bump dies
# with the subshell, so two calls from two subshells can name the same file.
#
# ONE PRIMITIVE, TWO CALLERS, AND THAT IS THE SECURITY POINT: a hardening flag
# or host-pin tightening applied here moves BOTH resolvers — which two
# hand-maintained copies of this request could not guarantee. Do not re-inline
# it; each resolver keeps only what it does with the Location left behind, as
# jira_curl's own ~25 callers keep only their response handling.
#
# NO -L, DELIBERATELY: the redirect is HELD, never followed. Following it would
# hit api.media.atlassian.com with the Jira credential attached and put the
# token-bearing URL on the wire from a sender that never pinned its host.
#
# READ-ONLY EXEMPT, and the only sender that is: the method is a literal GET,
# not a parameter, and the whole effect is reading a response header — there is
# no write here for $JIRA_READ_ONLY to refuse. download_attachment_content,
# which spends what the second resolver returns, is NOT exempt on that
# reasoning; see its own header.
#
# The numeric-id guard is this function's own precondition on ATTACHMENT_ID
# (interpolated into the URL path), so it runs FIRST — ahead of the header-file
# allocation, which emits nothing and touches only $WORKDIR.
fetch_attachment_content_redirect() {
	facr_attachment_id=$1
	facr_label=$2
	validate_numeric_id "$facr_attachment_id" || {
		error "internal: $facr_label received a non-numeric attachment id"
		exit 1
	}
	facr_url="https://${CONFIRMED_HOST}/rest/api/3/attachment/content/${facr_attachment_id}"
	assert_confirmed_host "$facr_url"

	ensure_workdir
	RESP_COUNTER=$((RESP_COUNTER + 1))
	FACR_HEADER_FILE="$WORKDIR/media-headers-$RESP_COUNTER.txt"

	if ! facr_code=$(curl -q -sS -K "$CURL_CONFIG_FILE" --proto '=https' \
		-H 'Accept: application/json' \
		-X GET \
		-D "$FACR_HEADER_FILE" \
		-o /dev/null \
		-w '%{http_code}' \
		"$facr_url"); then
		error "$facr_label: curl request failed (network/TLS error) for attachment $facr_attachment_id"
		exit 1
	fi

	case "$facr_code" in
		3??) : ;;
		*)
			error "$facr_label for attachment $facr_attachment_id: expected a 3xx redirect, got HTTP $facr_code"
			exit 1 ;;
	esac
}

# is_media_host URL -> 0 iff URL's host is EXACTLY Atlassian's media CDN.
#
# TWO CALLERS, AND BOTH MUST STAY: resolve_media_download_url as it reads the
# redirect Location, and download_attachment_content immediately before it
# spends that Location (this file's header has why two).
#
# The host is a HARDCODED literal, never $CONFIRMED_HOST and never an
# overridable ${VAR:-default}: the media CDN is Atlassian-wide and shared by
# every Jira Cloud site, so it cannot be derived from the confirmed site — and a
# pin the environment can retarget is not a pin. Case-FOLDED, like
# credentials.sh's own host-binding check, since hostnames are case-insensitive.
# Takes the whole URL rather than a pre-extracted host so the extraction cannot
# drift between the call sites — a look-alike host, a userinfo trick landing
# outside the exact string, or a bare authority with no path is then refused at
# both or neither.
is_media_host() {
	imh_host=$(downcase "$(url_host "$1")")
	[ "$imh_host" = "api.media.atlassian.com" ]
}

# resolve_media_uuid ATTACHMENT_ID -> prints ONLY the 36-char media UUID for the
# attachment, read out of the 303 Location fetch_attachment_content_redirect
# holds above.
#
# SECURITY (the whole point of this helper): the Location carries a short-lived
# JWT and MUST NEVER leave this function. The primitive already holds the
# redirect rather than following it, keeps the token off argv, and dumps the
# headers to a trap-cleaned $WORKDIR file. What this function adds is that the
# EXTRACTION emits the UUID and nothing else — a `sed -n s///p` capture prints
# the captured group on a match and nothing at all on no match, so neither the
# Location nor its JWT ever reaches stdout or a diagnostic.
#
# resolve_media_download_url below is the sibling to read next: same request,
# same primitive, and one difference — it DOES return the token-bearing
# Location. Its header states why that is safe there, and why this helper is the
# CORRECT one for a caller that only needs to identify an attachment.
resolve_media_uuid() {
	rmu_attachment_id=$1
	fetch_attachment_content_redirect "$rmu_attachment_id" "resolve media uuid"

	# Case-insensitive header name (HTTP/2 lowercases). The sed capture emits
	# ONLY the UUID — never the surrounding token-bearing URL.
	rmu_uuid=$(grep -i '^location:' "$FACR_HEADER_FILE" 2>/dev/null \
		| sed -n 's#.*/file/\([a-f0-9-]\{36\}\)/binary.*#\1#p' \
		| sed -n '1p')
	if ! validate_media_uuid "$rmu_uuid"; then
		# Deliberately does NOT echo the header/Location (short-lived JWT).
		error "resolve media uuid for attachment $rmu_attachment_id: no media UUID found in the redirect Location"
		exit 1
	fi
	printf '%s' "$rmu_uuid"
}

# resolve_media_download_url ATTACHMENT_ID -> prints the FULL redirect Location
# for the attachment's content, read out of the same 303 that
# fetch_attachment_content_redirect holds for resolve_media_uuid above. The
# request is now literally the same code for both; the only difference is what
# comes back, and that difference is a security one.
#
# UNLIKE resolve_media_uuid, THIS FUNCTION DOES RETURN THE JWT. The Location is
# https://api.media.atlassian.com/file/<UUID>/binary?token=<JWT>, and that token
# is a bearer credential for the attachment's bytes — whoever holds this string
# can fetch them until it expires. Exactly ONE caller may receive it:
# download_attachment_content below, which spends it on one immediate request
# and stores it nowhere. That second request is the whole justification for
# returning it at all. So the URL is never printed, logged, or folded into a
# diagnostic: every error below names the attachment id alone, and nothing
# extracted from the Location header — not even the host it failed on, since a
# Location without a path would put the token inside the substring an extraction
# calls "the host".
#
# The Location's host is pinned by is_media_host above (against the hardcoded
# media CDN, not $CONFIRMED_HOST — its header says why); anything else,
# including a non-https scheme, fails closed (exit 1), the same fail-secure
# direction as the $CONFIRMED_HOST re-check the primitive makes before sending.
resolve_media_download_url() {
	rmdu_attachment_id=$1
	fetch_attachment_content_redirect "$rmdu_attachment_id" "resolve media download url"

	# Case-insensitive header name (HTTP/2 lowercases), first Location only, its
	# name+leading space stripped, and the header dump's trailing CR removed
	# (raw CRLF lines — this is the one place in the engine that reads them, see
	# strip_control_ansi's note on why they never route through it).
	rmdu_location=$(grep -i '^location:' "$FACR_HEADER_FILE" 2>/dev/null \
		| sed -n '1s/^[^:]*:[[:space:]]*//p' \
		| tr -d '\015')
	case "$rmdu_location" in
		https://*) : ;;
		*)
			error "resolve media download url for attachment $rmdu_attachment_id: the redirect Location was absent or not https (fail closed)"
			exit 1 ;;
	esac
	if ! is_media_host "$rmdu_location"; then
		error "resolve media download url for attachment $rmdu_attachment_id: the redirect Location does not point at Atlassian's media host (fail closed)"
		exit 1
	fi
	printf '%s' "$rmdu_location"
}

# download_attachment_content ATTACHMENT_ID DEST_PATH — fetch the attachment's
# bytes and install them at DEST_PATH. FIVE preconditions on DEST_PATH, all of
# them the caller's pre-flight's to refuse before any network call: it must not
# already exist, its directory must exist, that directory must be writable, and
# DEST_PATH must not begin with "-" (four usage errors, exit 2 — the last of them
# protecting THIS function's own `ln`, and the `df` behind its cross-device
# pre-check, which take DEST_PATH and the directory derived from it as
# option-parsed arguments and would read a leading dash as an option); and that
# directory must not be one other local users can write with no sticky bit
# (runtime.sh's assert_safe_download_dir, exit 1 — see the staging note below for
# what it does and does NOT relieve this function of).
#
# It calls ensure_workdir ITSELF rather than relying on the caller, for two
# reasons now: the staged body lives in $WORKDIR (see below), and
# resolve_media_download_url needs it too while running inside a command
# substitution, where its own assignment to $WORKDIR would die with the subshell.
#
# TWO DELIBERATE REQUESTS, NOT ONE FOLLOWED REDIRECT. resolve_media_download_url
# holds the 303 and hands back a Location whose host it has already pinned, so
# the GET below is aimed at a host THIS unit chose — re-asserted again right
# before the send, exactly as the other three senders re-assert theirs. `-L`
# would hand that choice to the response instead.
#
# NO SITE CREDENTIAL, and that is the point: Jira's token must never reach
# api.media.atlassian.com. The URL's own short-lived JWT is the media CDN's
# authorization — Jira's API puts it in the query string, which is not this
# engine's choice — so the URL is ITSELF a bearer credential, and it reaches
# curl through a `-K -` stdin config rather than as an argument, under the same
# never-on-argv rule the site token follows (an argv URL is readable by any
# local user via `ps`/`/proc/<pid>/cmdline` for the life of the request). It is
# likewise never logged: every diagnostic below names the attachment id and the
# HTTP status, never the URL or any substring of it (resolve_media_download_url's
# header has the full rule).
#
# THE BODY STAGES INSIDE $WORKDIR, NEVER BESIDE DEST_PATH, AND THAT IS A
# SECURITY PROPERTY RATHER THAN A CONVENIENCE. curl re-opens its `-o` path BY
# NAME, after a full DNS/TLS/HTTP round-trip to the media CDN — hundreds of
# milliseconds in which the staging path's own NAME is attacker-reachable if it
# sits in the caller-named destination directory, which this mode's threat model
# already assumes another local user may write (no sticky bit). That user can
# `readdir` the parent, then unlink or rename away whatever is at the staging
# name and create their own entity there, including a directory holding a symlink
# — so curl writes the fetched bytes THROUGH it, an arbitrary local file write as
# the invoking user, retryable until it lands.
#
# Note carefully what does NOT close that window: the staging entity's own mode.
# A 0700 staging directory protects only what is created INSIDE it — whether its
# OWN directory entry can be removed and replaced is always the PARENT's
# permissions to decide. The location is the vulnerability, so only staging
# outside attacker-writable territory fixes it; SKILL.md's 2.10 entry has what
# was tried first. runtime.sh's assert_safe_tmpdir applies the same reasoning to
# ${TMPDIR:-/tmp}, one level further up, for every $WORKDIR this engine creates.
#
# THE PRE-FLIGHT NOW REFUSES SUCH A DESTINATION DIRECTORY UP FRONT
# (assert_safe_download_dir), AND THAT DOES NOT MAKE THIS STAGING CHOICE
# REDUNDANT — do not relocate it back on that reasoning. Two gaps survive the
# gate by construction: it reads the 9 POSIX mode bits, so a directory carrying
# an ACL entry that grants another user write is WARNED about and then ACCEPTED
# (see assert_safe_dir's own ACL note for why refusing was rejected); and it is a
# MODE-LEVEL check in cmd-attach.sh, while the property this function needs is
# its own. Staging outside the destination directory is what holds in both cases.
#
# $WORKDIR is that territory's opposite: an engine-owned `mktemp -d` under
# ${TMPDIR:-/tmp} (see runtime.sh's ensure_workdir), 0700 by construction, so no
# other user can traverse it, let alone replace an entry in it. A bare file with
# a predictable name inside it is therefore safe — and is exactly what the other
# ~25 responses in this unit already do ($WORKDIR/resp-<n>.json), so the staged
# body follows that $RESP_COUNTER pattern rather than inventing a second one.
# The trap-time `rm -rf "$WORKDIR"` already reaches it, which is why this
# function no longer registers a staging carrier of its own and no longer
# removes anything on its failure paths: a partial body simply stays inside
# $WORKDIR until cleanup() takes the whole directory. Nothing is ever created at
# DEST_PATH before the install below, so a failed, refused or interrupted
# download still leaves no truncated file a caller could mistake for a real one.
#
# THE INSTALL IS `ln` THEN `rm`, AND THE HARD LINK IS THE SAFETY MECHANISM. Both
# properties the install needs come from link(2) itself, at the instant of the
# install, so there is no window between checking and acting:
#   * it CANNOT cross a filesystem — inherent to a hard link, not a policy — so a
#     destination on another filesystem is refused by the kernel (EXDEV);
#   * it refuses an existing destination NAME rather than writing through it, so a
#     symlink raced in at DEST_PATH is rejected, never followed.
# An earlier shape used `mv -f` and could guarantee neither, because both answers
# depended on a pre-check taken before the round-trip: a cross-device `mv` reports
# SUCCESS having silently copied BY NAME into the caller-named directory (handing
# the symlink-follow straight back to the attacker, non-atomically, for the length
# of the whole payload), and `mv` STATS its destination, so a symlink-to-a-
# DIRECTORY raced in at DEST_PATH made it move the payload INSIDE that directory
# and exit 0. runtime.sh's atomic_install is still deliberately not used here, and
# it is a rename install for its own reason (it must REPLACE an existing config,
# where this mode must never replace anything): it would copy the whole payload a
# second time, create a second entry in the caller-named directory, and end in the
# `mv` whose two concessions are listed above.
#
# `-n` IS LOAD-BEARING FOR THE SECOND PROPERTY: `ln`(1), like `mv`, stats its
# target and reads a symlink-to-a-directory as "link INTO that directory".
# `-n` (--no-dereference) makes it operate on the LINK NAME, so link(2) finds an
# existing entry and refuses.
#
# ITS PORTABILITY IS NARROWER THAN THE SHARED SPELLING SUGGESTS. GNU, BSD and
# busybox `ln` all spell it `-n` and all genuinely refuse a symlink-to-a-directory
# at the destination. POSIX does not mandate the flag — but Solaris/illumos and
# AIX `ln` ACCEPT `-n` meaning something else entirely ("do not overwrite an
# existing target", already the default there), so on those platforms it is a
# SILENT NO-OP: `ln -n` behaves like a bare `ln`, links the payload INSIDE the
# attacker's directory and exits 0. An earlier version of this comment claimed an
# `ln` without the flag "fails the install loudly"; that is true of an `ln` that
# REJECTS `-n`, and false of the two real Unix families that accept and ignore it.
#
# SO THE POST-INSTALL CHECK IS THE ONLY DEFENSE LAYER THERE, never a redundancy
# given `-n`: it must not be removed or weakened on the reasoning that the flag
# already covers this. A REAL directory raced in at DEST_PATH is the residual
# `-n` does not cover on ANY platform (unchanged from `mv`); a SYMLINK to one is a
# residual wherever `-n` is a no-op. The check refuses both — it is runtime.sh's
# shared assert_install_landed, whose header has why the symlink case is refused
# without touching anything at all.
#
# runtime.sh's is_known_cross_device is now only a COURTESY, checked before the
# first request so an already-doomed destination costs neither the short-lived
# media JWT nor a fetched payload. The safety no longer rests on it: a wrong
# answer there wastes a round-trip that `ln` then refuses anyway.
#
# THE INSTALLED FILE'S 0600 COMES FROM ONE PLACE — the `umask 077` on the command
# substitution that runs curl, which is the only thing that decides the mode curl
# creates the staged body with. `ln` does not carry a mode across; DEST_PATH and
# the staged body ARE one inode, so it is the same mode by identity. It is NOT
# there to protect the staged body (0700 $WORKDIR already does that, which is
# exactly why it looks removable), so deleting it silently publishes every
# downloaded attachment at the caller's umask — 0644 on a default login.
#
# WHY IT LIVES HERE rather than composing http.sh's primitives from
# cmd-attach.sh: this unit's one-curl-sink invariant is engine-wide, so a `curl`
# outside it is a transport nobody reviews — worth more than keeping the
# function down to a bare request.
download_attachment_content() {
	dac_attachment_id=$1
	dac_dest_path=$2

	# Read-only re-check at the SINK — the same fail-closed defense-in-depth the
	# two method-taking senders carry, but NOT on their method-based reasoning.
	# fetch_attachment_content_redirect is exempt because a literal GET reading a
	# redirect header cannot be the write the gate refuses; THIS function's dangerous
	# effect is the LOCAL FILE WRITE below, which is exactly why readonlygate.sh
	# classifies `attach --download` a write. So a GET exempts nothing here, and
	# without this line a reversal of that classification — a regression this
	# engine has already had once — would leave the one local-write egress with no
	# sink-side backstop, unlike every network write.
	if is_read_only_requested; then
		error "internal: \$JIRA_READ_ONLY is set: refusing the local file write for attachment $dac_attachment_id (fail closed)"
		exit 1
	fi

	ensure_workdir

	# A COURTESY REFUSAL, BEFORE THE FIRST REQUEST, so an already-doomed
	# destination costs neither the short-lived media JWT nor a fetched payload.
	# The install's `ln` is what actually refuses a cross-device destination (see
	# the header), which is why this check may only answer a CONFIDENT verdict and
	# why an unparsable `df` proceeds here rather than refusing. It can therefore
	# afford the more specific diagnostic of the two, naming $TMPDIR because
	# relocating $WORKDIR is the caller's remedy.
	dac_dest_dir=$(parent_dir "$dac_dest_path")
	if is_known_cross_device "$WORKDIR" "$dac_dest_dir"; then
		error "download attachment $dac_attachment_id: the destination directory is on a different filesystem than the engine's temp directory ($WORKDIR), and the download is installed with a hard link, which cannot cross one — point \$TMPDIR at a PRIVATE directory you own (not group- or world-writable, or one with the sticky bit set) on the destination's own filesystem and re-run"
		exit 1
	fi

	dac_media_url=$(resolve_media_download_url "$dac_attachment_id")

	# Host re-assertion at the SINK — a SECOND call to is_media_host, not trust in
	# the resolver's, against a future bug handing this function a Location its
	# resolver never pinned (this file's header has why two checks). The
	# diagnostic names the attachment id ALONE: a Location with no path would
	# leave the JWT inside what the extraction calls "the host".
	if ! is_media_host "$dac_media_url"; then
		error "internal: refusing the download request for attachment $dac_attachment_id — its URL does not point at Atlassian's media host (fail closed)"
		exit 1
	fi

	# A fixed name inside 0700 $WORKDIR, allocated on the same $RESP_COUNTER the
	# ~25 response bodies in this unit use — no `mktemp` and no guard for one,
	# because nothing here can fail: the directory already exists (ensure_workdir
	# above) and curl creates the file itself. See this function's header for why
	# the LOCATION, not the name and not the mode, is what closes the staging race.
	RESP_COUNTER=$((RESP_COUNTER + 1))
	dac_body_file="$WORKDIR/download-$RESP_COUNTER.bin"

	# The token-bearing URL is escaped (curl_config_escape — a `"` or `\` would
	# otherwise break out of the quoted parameter) and handed to curl as a one
	# directive config on stdin, never on argv.
	#
	# `umask 077` scopes to this command substitution's own subshell (the engine's
	# umask is untouched) and is the ONE thing that sets the INSTALLED file's 0600
	# — read the header before concluding it is redundant, because it does NOT
	# protect the staged body and looks removable for exactly that reason.
	#
	# No FAILURE path below removes the staged body: it is inside $WORKDIR, which
	# the EXIT trap takes whole, and nothing is at the destination to clean up.
	# Only the completed install drops it, and even that is non-fatal.
	if ! dac_code=$(umask 077; printf 'url = "%s"\n' "$(curl_config_escape "$dac_media_url")" \
		| curl -q -sS -K - --proto '=https' \
			-X GET \
			-o "$dac_body_file" \
			-w '%{http_code}'); then
		error "download attachment $dac_attachment_id: curl request failed (network/TLS error)"
		exit 1
	fi

	case "$dac_code" in
		2??) : ;;
		*)
			error "download attachment $dac_attachment_id failed (HTTP $dac_code)"
			exit 1 ;;
	esac

	# GUARDED, and the message is DELIBERATELY GENERIC about the cause. `ln` can
	# fail here for a cross-device destination, a permission loss, a full
	# filesystem, an entry appearing at DEST_PATH (including a symlink), or an `ln`
	# with no `-n` — and neither its exit status nor its wording distinguishes
	# those portably, so claiming one would be a guess. `ln`'s own raw message
	# still prints, since its stderr is deliberately not redirected and is what a
	# human diagnoses from; the guard replaces only its EXIT STATUS with this
	# function's documented exit 1 and its own uniform error() line.
	if ! ln -n "$dac_body_file" "$dac_dest_path"; then
		error "download attachment $dac_attachment_id: could not install the downloaded file at the destination"
		exit 1
	fi
	# THE POST-INSTALL VERIFICATION IS runtime.sh's SHARED assert_install_landed,
	# not a private sequence any more: `mv -f` — which atomic_install installs
	# with — concedes the SAME two residuals `ln -n` does (a real directory raced
	# in at the destination, and a symlink to one wherever `-n` is a no-op), so the
	# three refusals, the one best-effort withdrawal and the no-`rm`-through-a-
	# symlink rule are one reviewed unit rather than two copies. Its header owns
	# the reasoning; what is passed from here is the staged body's basename (the
	# entity a misplaced install leaves behind) and the diagnostics' own prefix.
	assert_install_landed "$dac_dest_path" "${dac_body_file##*/}" link \
		"download attachment $dac_attachment_id"
	# DEST_PATH is now a second link to the staged body, so dropping this one
	# leaves the caller a single-link file rather than one that stays hard-linked
	# into $WORKDIR until teardown. Non-fatal (cleanup()'s own idiom): the EXIT
	# trap's `rm -rf "$WORKDIR"` reaches it anyway, and an `rm` failure here must
	# not turn a completed install into an error.
	rm -f "$dac_body_file" 2>/dev/null || true
}
