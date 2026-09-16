# shellcheck shell=sh
#
# curl-stub.sh — the canned-response-QUEUE `curl` stub shared by every Jira
#                test harness, plus the control surface tests drive it with.
#
# WHY A STUB AT ALL: no test in this suite may make a real network call. Each
# harness builds an isolated PATH toolbox that deliberately EXCLUDES the real
# curl and adds this stub in its own directory, so a test opts into "curl
# exists" by putting that directory on PATH — which is also how "curl absent"
# is exercised for real, by leaving it off.
#
# WHAT MAKES IT A QUEUE, not one canned response: every invocation reads and
# increments a shared counter file and serves
# $CURL_STUB_RESP_DIR/resp-<n>.{body,code} — the Nth call gets the Nth queued
# response. That is what lets one test drive a multi-call flow (pagination, an
# accountId lookup followed by a search, a transition walk) deterministically.
#
# WHAT IT RECORDS, and why each record exists:
#   * every call's FULL argv, one token per line between CALL_<n>_BEGIN/END
#     markers, in $CURL_STUB_ARGV_LOG — this is how a test proves the exact
#     URL/method hit, and how the "the token is NEVER an argv token" security
#     assertions are made (an exact-LINE grep, never a substring one);
#   * the CONTENTS of any `--data @file` as $CURL_STUB_BODY_LOG_DIR/call-<n>.body
#     — how a test proves the exact JSON body, and therefore the exact JQL
#     string, that was sent;
#   * the STDIN of any `-K -` call as $CURL_STUB_STDIN_LOG_DIR/call-<n>.stdin —
#     the counterpart record for a URL or credential that reaches curl through a
#     stdin CONFIG instead of argv. http.sh's download_attachment_content sends
#     the media CDN's token-bearing URL that way precisely so it never appears in
#     argv, which makes the argv log structurally blind to it: without this
#     record, every "the JWT is not on the wire" assertion over the argv log
#     passes whether the request was made or not. The per-call FILE (rather than
#     one appended log) is what lets a test assert the stronger claim by its
#     ABSENCE — no call-2.stdin means no second request was even handed a URL.
#
# WHY IT IS ONE FILE INSTEAD OF THREE COPIES: this stub used to be pasted
# verbatim into run-engine-tests.sh, run-write-tests.sh and run-rig-tests.sh,
# and the copies had already drifted — only the engine copy honoured `-D`
# header dumps. The production-side "each skill is deployed independently, so
# it duplicates rather than sources" rationale does not apply to tests/, which
# is never deployed. This file is the single copy; it is the SUPERSET (the -D
# support included), so no harness loses a capability by sourcing it.
#
# Sourced by the test harnesses — never executed directly.

# init_curl_stub STUB_DIR WORK_DIR — write the stub executable into STUB_DIR
# (which must already exist and must contain NOTHING else, so a test can put
# exactly `curl` on PATH) and point the control variables at WORK_DIR.
init_curl_stub() {
	ics_stub_dir=$1
	ics_work_dir=$2

	CURL_STUB_RESP_DIR="$ics_work_dir/curlresp"
	CURL_STUB_COUNTER_FILE="$ics_work_dir/curl-counter"
	CURL_STUB_ARGV_LOG="$ics_work_dir/curl-argv.log"
	CURL_STUB_BODY_LOG_DIR="$ics_work_dir/curl-bodies"
	CURL_STUB_STDIN_LOG_DIR="$ics_work_dir/curl-stdin"

	cat >"$ics_stub_dir/curl" <<'CURL_STUB'
#!/usr/bin/env sh
set -eu

n=0
[ -f "$CURL_STUB_COUNTER_FILE" ] && n=$(cat "$CURL_STUB_COUNTER_FILE")
n=$((n + 1))
printf '%s' "$n" >"$CURL_STUB_COUNTER_FILE"

if [ -n "${CURL_STUB_ARGV_LOG:-}" ]; then
	{
		printf 'CALL_%s_BEGIN\n' "$n"
		for a in "$@"; do printf '%s\n' "$a"; done
		printf 'CALL_%s_END\n' "$n"
	} >>"$CURL_STUB_ARGV_LOG"
fi

out_file=""
header_out=""
data_at=""
stdin_config=""
url=""
prev=""
for a in "$@"; do
	[ "$prev" = "-o" ] && out_file=$a
	[ "$prev" = "-D" ] && header_out=$a
	# `-K -` is the ONLY shape that makes this call read stdin, so the capture
	# below is gated on the adjacent PAIR. An unconditional read would block
	# forever on every other call in the suite, whose stdin is the harness's own.
	[ "$prev" = "-K" ] && [ "$a" = "-" ] && stdin_config=1
	case "$a" in
		@*) data_at=${a#@} ;;
	esac
	url=$a
	prev=$a
done

if [ -n "$data_at" ] && [ -n "${CURL_STUB_BODY_LOG_DIR:-}" ]; then
	cat "$data_at" >"$CURL_STUB_BODY_LOG_DIR/call-$n.body"
fi

# Recorded BEFORE the canned-response lookup below, on the same reasoning the
# argv and body records are: real curl consumes its config before it can fail,
# so a call that dies on an unqueued response must still show what it was handed.
if [ -n "$stdin_config" ] && [ -n "${CURL_STUB_STDIN_LOG_DIR:-}" ]; then
	cat >"$CURL_STUB_STDIN_LOG_DIR/call-$n.stdin"
fi

resp_body="$CURL_STUB_RESP_DIR/resp-$n.body"
resp_code="$CURL_STUB_RESP_DIR/resp-$n.code"
if [ ! -f "$resp_body" ] || [ ! -f "$resp_code" ]; then
	printf 'STUB curl: no canned response configured for call #%s (url=%s)\n' "$n" "$url" >&2
	exit 99
fi

[ -z "$out_file" ] || cat "$resp_body" >"$out_file"

# Header dump (-D): if this call requested one AND a header response is
# configured for it, write the canned header block to the -D file. Mirrors
# the -o body path — used by http.sh's fetch_attachment_content_redirect, the
# one request behind BOTH resolve_media_uuid and resolve_media_download_url, to
# capture the 303's Location.
resp_headers="$CURL_STUB_RESP_DIR/resp-$n.headers"
if [ -n "$header_out" ] && [ -f "$resp_headers" ]; then
	cat "$resp_headers" >"$header_out"
fi

cat "$resp_code"
CURL_STUB
	chmod +x "$ics_stub_dir/curl"
}

# reset_curl_stub — empty the queue, the counter and all three logs. Call before
# EVERY test that uses curl, so each test's call numbering starts at 1 and no
# assertion can accidentally read a previous test's argv log.
reset_curl_stub() {
	rm -rf "$CURL_STUB_RESP_DIR" "$CURL_STUB_BODY_LOG_DIR" "$CURL_STUB_STDIN_LOG_DIR"
	mkdir -p "$CURL_STUB_RESP_DIR" "$CURL_STUB_BODY_LOG_DIR" "$CURL_STUB_STDIN_LOG_DIR"
	printf '0' >"$CURL_STUB_COUNTER_FILE"
	: >"$CURL_STUB_ARGV_LOG"
}

# set_stub_response N BODY CODE — the Nth curl call gets this response.
set_stub_response() {
	scr_n=$1
	printf '%s' "$2" >"$CURL_STUB_RESP_DIR/resp-$scr_n.body"
	printf '%s' "$3" >"$CURL_STUB_RESP_DIR/resp-$scr_n.code"
}

# set_stub_headers N HEADERS — the Nth curl call's -D header dump gets these
# raw header lines (used to can the 303 + Location that
# fetch_attachment_content_redirect holds for both resolve_media_* callers).
set_stub_headers() {
	printf '%s' "$2" >"$CURL_STUB_RESP_DIR/resp-$1.headers"
}

# call_count -> how many curl calls the last `run` made.
call_count() { cat "$CURL_STUB_COUNTER_FILE" 2>/dev/null || printf '0'; }

# request_method_sequence -> the HTTP methods of the last run's curl calls, in
# call order, joined by "/" (e.g. "GET/GET/DELETE"). http.sh's jira_curl always
# passes the method as the argv token immediately following `-X`, and the stub
# logs one argv token per line — so "the line after each `-X` line" IS the
# method, in call order, with no parsing of the surrounding CALL_<n> markers.
#
# WHY IT BELONGS HERE rather than in one suite: it is the assertion of last
# resort whenever a read and a write address the SAME url, so no URL assertion
# can tell "read it" from "wrote it" apart — version --delete's plan/cross-check
# gates in the engine suite, comment-edit's read-before-write ordering in the
# write suite. It reads only this file's own argv log, exactly like call_count.
request_method_sequence() {
	sed -n '/^-X$/{n;p;}' "$CURL_STUB_ARGV_LOG" | tr '\n' '/' | sed 's|/$||'
}
