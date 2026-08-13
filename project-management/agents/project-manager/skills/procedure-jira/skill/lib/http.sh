# shellcheck shell=sh
#
# http.sh — the ONLY unit in this engine that invokes `curl`. Every request
#           leaves through jira_curl (JSON), jira_curl_multipart (attachment
#           upload), or resolve_media_uuid (the one egress that must hold a 3xx
#           to read its Location) — and all three re-assert the same security
#           invariants before sending:
#             * the token stays in the -K config file, never on argv;
#             * the URL's host is re-checked against $CONFIRMED_HOST (fail closed);
#             * under $JIRA_READ_ONLY, a non-GET method is refused (fail closed)
#               — the sink-side counterpart of jira.sh's one-shot
#               require_write_allowed; resolve_media_uuid needs no check of its
#               own because its method is a literal GET, not a parameter;
#             * `--proto '=https'`, never -L, never -k/--insecure.
#
# FLAG ORDER IS PART OF THE HARDENING, not cosmetic. curl applies its options
# left to right and a later one WINS, so `-K <config>` is placed FIRST, right
# after `curl -sS`, and every hardening flag comes AFTER it. That way a
# directive inside the config file — today only `user = "..."`, but the file is
# supplied from outside via $JIRA_CURL_CONFIG — can never override the
# `--proto '=https'` pinning this unit asserts. Keep any new hardening flag
# after the -K, and never move the -K down.
#
# Keeping every `curl` call in one file is the point of the unit: the transport's
# security guarantees are reviewed ONCE, here, instead of at each command.
# handle_http_status/require_json_body live here too — they are the response half
# of the same transport contract.
#
# Sourced by jira.sh — never executed directly. Sets no shell options and
# runs no top-level work beyond its own declarations, so sourcing it always
# returns 0 under `set -e`.

# jira_curl METHOD URL [DATA_FILE] [CONTENT_TYPE]
# Sets $JIRA_HTTP_BODY_FILE (the response body, always a FRESH file — never
# reused across calls, so a caller holding an earlier response's path stays
# valid after a later call) and $JIRA_HTTP_CODE (the numeric HTTP status).
jira_curl() {
	method=$1
	url=$2
	data_file=${3:-}
	content_type=${4:-application/json}

	req_host=$(printf '%s' "$url" | sed -E 's#^https://##; s#/.*##')
	if [ "$req_host" != "$CONFIRMED_HOST" ]; then
		error "internal: refusing to send a request to '$req_host' — it does not match the confirmed site '$CONFIRMED_HOST' (fail closed)"
		exit 1
	fi
	case "$url" in
		https://*) : ;;
		*) error "internal: refusing a non-https URL: $url"; exit 1 ;;
	esac

	# Read-only re-check — the SAME defense-in-depth invariant as the host
	# re-check above, applied to lib/readonlygate.sh's gate. jira.sh asserts
	# require_write_allowed ONCE, at dispatch; that classification is correct
	# today, so nothing this engine can currently dispatch reaches here with a
	# non-GET method under $JIRA_READ_ONLY. It is an assertion against a FUTURE
	# bug in a security-critical sink — a newly added command classified as a
	# read by omission, or a "read" command that grows a write path (an
	# attachment upload is already reachable from create/update/comment) — at
	# the one place such a bug is still catchable: the network egress itself.
	# GET is the only method this engine reads with, so any other method IS the
	# write the gate refuses. Fails closed (exit 1), like every check above it.
	if is_read_only_requested && [ "$method" != GET ]; then
		error "internal: \$JIRA_READ_ONLY is set: refusing to send $method $url — read-only mode permits GET only (fail closed)"
		exit 1
	fi

	ensure_workdir
	RESP_COUNTER=$((RESP_COUNTER + 1))
	JIRA_HTTP_BODY_FILE="$WORKDIR/resp-$RESP_COUNTER.json"

	set -- curl -sS -K "$CURL_CONFIG_FILE" --proto '=https' \
		-H 'Accept: application/json' \
		-X "$method" \
		-o "$JIRA_HTTP_BODY_FILE" \
		-w '%{http_code}'

	if [ -n "$data_file" ]; then
		set -- "$@" -H "Content-Type: $content_type" --data "@$data_file"
	fi

	set -- "$@" "$url"

	if ! JIRA_HTTP_CODE=$("$@"); then
		error "curl request failed (network/TLS error) for $method $url"
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

	mp_req_host=$(printf '%s' "$mp_url" | sed -E 's#^https://##; s#/.*##')
	if [ "$mp_req_host" != "$CONFIRMED_HOST" ]; then
		error "internal: refusing to send a request to '$mp_req_host' — it does not match the confirmed site '$CONFIRMED_HOST' (fail closed)"
		exit 1
	fi
	case "$mp_url" in
		https://*) : ;;
		*) error "internal: refusing a non-https URL: $mp_url"; exit 1 ;;
	esac

	# Read-only re-check — the same fail-closed assertion jira_curl() carries
	# (see its note for why a once-asserted gate is re-checked at the sink),
	# re-stated here rather than inherited, exactly as the host re-check is.
	# It bites hardest in THIS helper: the multipart egress is an attachment
	# upload, reachable from create/update/comment's inline-image path as well
	# as from `attach`, so a future misclassification of any of those would land
	# here first.
	if is_read_only_requested && [ "$mp_method" != GET ]; then
		error "internal: \$JIRA_READ_ONLY is set: refusing to send $mp_method $mp_url — read-only mode permits GET only (fail closed)"
		exit 1
	fi

	ensure_workdir
	RESP_COUNTER=$((RESP_COUNTER + 1))
	JIRA_HTTP_BODY_FILE="$WORKDIR/resp-$RESP_COUNTER.json"

	set -- curl -sS -K "$CURL_CONFIG_FILE" --proto '=https' \
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
	code=$1
	action=$2
	case "$code" in
		2??) return 0 ;;
	esac
	error "$action failed (HTTP $code)"
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
	action=$1
	if ! jq -e . "$JIRA_HTTP_BODY_FILE" >/dev/null 2>&1; then
		error "$action failed: response body was not valid JSON"
		exit 1
	fi
}

# resolve_media_uuid ATTACHMENT_ID -> prints ONLY the 36-char media UUID for
# the attachment. GETs /attachment/content/<id>, which returns a 303 whose
# Location is https://api.media.atlassian.com/file/<UUID>/binary?token=<JWT>.
#
# SECURITY (the whole point of this helper): the Location carries a short-lived
# JWT and MUST NEVER leave this function. So the request:
#   * does NOT follow the redirect (NO -L) — never hits api.media.atlassian.com,
#     never downloads the binary, never puts the token-bearing URL on the wire;
#   * dumps headers to a WORKDIR file (-D, trap-cleaned) with the body -> /dev/null;
#   * extracts ONLY the UUID via a `sed -n s///p` capture — on a match it prints
#     the captured group and NOTHING else, so the Location/JWT is never emitted;
#     on no match it prints nothing (the header line never reaches stdout/stderr).
# The token stays off argv (in the -K config file), the host is pinned (the URL
# is built from CONFIRMED_HOST), and the transport is https-only.
resolve_media_uuid() {
	rmu_attachment_id=$1
	validate_numeric_id "$rmu_attachment_id" || {
		error "internal: resolve_media_uuid received a non-numeric attachment id"
		exit 1
	}
	ensure_workdir
	RESP_COUNTER=$((RESP_COUNTER + 1))
	rmu_header_file="$WORKDIR/media-headers-$RESP_COUNTER.txt"
	rmu_url="https://${CONFIRMED_HOST}/rest/api/3/attachment/content/${rmu_attachment_id}"

	# Host-pin re-check — the SAME fail-closed invariant jira_curl/
	# jira_curl_multipart apply before every send: this is the one egress that
	# uses a raw `curl` (to hold the redirect), so it re-verifies the URL's host
	# against $CONFIRMED_HOST here rather than inheriting the sibling helpers'
	# check. Safe today (rmu_url is CONFIRMED_HOST-built), an assertion against
	# a future bug in a security-critical sink (standard-security "fail secure").
	rmu_req_host=$(printf '%s' "$rmu_url" | sed -E 's#^https://##; s#/.*##')
	if [ "$rmu_req_host" != "$CONFIRMED_HOST" ]; then
		error "internal: refusing to send a request to '$rmu_req_host' — it does not match the confirmed site '$CONFIRMED_HOST' (fail closed)"
		exit 1
	fi

	if ! rmu_code=$(curl -sS -K "$CURL_CONFIG_FILE" --proto '=https' \
		-H 'Accept: application/json' \
		-X GET \
		-D "$rmu_header_file" \
		-o /dev/null \
		-w '%{http_code}' \
		"$rmu_url"); then
		error "resolve media uuid: curl request failed (network/TLS error) for attachment $rmu_attachment_id"
		exit 1
	fi

	case "$rmu_code" in
		3??) : ;;
		*)
			error "resolve media uuid for attachment $rmu_attachment_id: expected a 3xx redirect, got HTTP $rmu_code"
			exit 1 ;;
	esac

	# Case-insensitive header name (HTTP/2 lowercases). The sed capture emits
	# ONLY the UUID — never the surrounding token-bearing URL.
	rmu_uuid=$(grep -i '^location:' "$rmu_header_file" 2>/dev/null \
		| sed -n 's#.*/file/\([a-f0-9-]\{36\}\)/binary.*#\1#p' \
		| sed -n '1p')
	if ! validate_media_uuid "$rmu_uuid"; then
		# Deliberately does NOT echo the header/Location (short-lived JWT).
		error "resolve media uuid for attachment $rmu_attachment_id: no media UUID found in the redirect Location"
		exit 1
	fi
	printf '%s' "$rmu_uuid"
}
