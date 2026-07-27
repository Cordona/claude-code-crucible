#!/usr/bin/env sh
#
# run-engine-tests.sh — self-contained, zero-dependency POSIX test harness
#                        for jira.sh: the engine core + view/search/workflow.
#
# WHY a hand-rolled harness (not bats): same rationale as the sibling
# tests/run-tests.sh (md-to-adf.sh) and procedure-gh-issues/tests/run-tests.sh
# — the whole point of this suite is "runs on any machine with no
# dependencies beyond jq". Requiring bats-core would contradict that.
#
# What it does:
#   * Builds an isolated PATH toolbox of symlinks to only the real tools
#     jira.sh needs (jq, mktemp, sed, grep, tr, ...) PLUS a STUB `curl` so no
#     test ever makes a real network call. The curl stub lives in its OWN
#     dir that tests opt into via the run() selector, so "curl absent" and
#     "jq absent" are exercised for real by leaving the relevant tool off
#     PATH — same technique as the sibling harnesses.
#   * The curl stub is a QUEUE, not a single canned response: each
#     invocation reads/increments a shared counter and serves
#     $CURL_STUB_RESP_DIR/resp-<n>.{body,code} — the Nth call gets the Nth
#     canned response. This is what lets one test script exercise a
#     multi-call flow (pagination, accountId-then-search) deterministically.
#   * The stub logs EVERY call's full argv (token-per-line, between
#     CALL_<n>_BEGIN/END markers) to one file, and copies any `--data @file`
#     CONTENTS to `call-<n>.body` — this is how tests prove (a) the exact
#     URL/method hit, (b) the token never appears as an argv token, and
#     (c) the exact JSON body (and therefore the exact JQL string) sent.
#   * Everything runs under `env -i` with an isolated HOME + TMPDIR, and the
#     jira.sh-relevant env vars (JIRA_EMAIL, JIRA_TOKEN, JIRA_SITE,
#     JIRA_CURL_CONFIG, JIRA_PROJECTS_DIR, JIRA_HOST_ALLOWLIST_PATTERN) are
#     passed through explicitly per test via `run()`'s VAR=VALUE args —
#     never inherited from the real environment.
#
# Usage:  sh run-engine-tests.sh              # run all tests
#         VERBOSE=1 sh run-engine-tests.sh
#         (also runs green under dash: dash run-engine-tests.sh)
#
# Exit 0 = all passed, 1 = one or more failed.
#
set -eu

# ---------------------------------------------------------------------------
# Locations
# ---------------------------------------------------------------------------
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
SCRIPTS_DIR=$(cd "$TESTS_DIR/../scripts" && pwd)
JIRA="$SCRIPTS_DIR/jira.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/jira-engine-tests.XXXXXX")
TOOLBOX="$WORK/toolbox"          # real tools, curl NEVER here
NOJQ_TOOLBOX="$WORK/nojq"        # real tools, jq deliberately OMITTED
STUBCURL_DIR="$WORK/stubcurl"    # ONLY the stub `curl`
mkdir -p "$TOOLBOX" "$NOJQ_TOOLBOX" "$STUBCURL_DIR" "$WORK/home"

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Isolated PATH toolboxes: symlink only the real tools jira.sh needs.
# ---------------------------------------------------------------------------
ORIG_PATH=$PATH
link_tool() {
	target_dir=$1
	tool_name=$2
	tool_path=$(PATH="$ORIG_PATH" command -v "$tool_name" 2>/dev/null || true)
	[ -n "$tool_path" ] || { printf 'FATAL: required tool not found: %s\n' "$tool_name" >&2; exit 1; }
	ln -s "$tool_path" "$target_dir/$tool_name"
}
for t in sh mktemp sed grep tr cat rm chmod cp mv dirname tail mkdir date; do
	link_tool "$TOOLBOX" "$t"
	link_tool "$NOJQ_TOOLBOX" "$t"
done
link_tool "$TOOLBOX" jq

# A THIRD toolbox identical to TOOLBOX but with a FIXED-output `date` stub, so
# the backup-collision path is exercised DETERMINISTICALLY: two --write
# runs land in the "same UTC second" and must still produce two distinct
# backups (proving the mktemp uniquifier, not luck of the clock). Selected via
# run()'s `fixedtime`.
FIXEDDATE_TOOLBOX="$WORK/fixeddate"
mkdir -p "$FIXEDDATE_TOOLBOX"
for t in sh mktemp sed grep tr cat rm chmod cp mv dirname tail mkdir jq; do
	link_tool "$FIXEDDATE_TOOLBOX" "$t"
done
cat >"$FIXEDDATE_TOOLBOX/date" <<'FIXED_DATE_STUB'
#!/usr/bin/env sh
# test stub: ignore args, always emit one fixed UTC stamp so two writes collide
printf '20260725T000000Z\n'
FIXED_DATE_STUB
chmod +x "$FIXEDDATE_TOOLBOX/date"

# ---------------------------------------------------------------------------
# The curl stub — a canned-response QUEUE (see the header note). Only ever
# touches CURL_STUB_* env vars, which run() supplies for every invocation.
# ---------------------------------------------------------------------------
cat >"$STUBCURL_DIR/curl" <<'CURL_STUB'
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
url=""
prev=""
for a in "$@"; do
	[ "$prev" = "-o" ] && out_file=$a
	[ "$prev" = "-D" ] && header_out=$a
	case "$a" in
		@*) data_at=${a#@} ;;
	esac
	url=$a
	prev=$a
done

if [ -n "$data_at" ] && [ -n "${CURL_STUB_BODY_LOG_DIR:-}" ]; then
	cat "$data_at" >"$CURL_STUB_BODY_LOG_DIR/call-$n.body"
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
# the -o body path — used by resolve_media_uuid's 303/Location capture.
resp_headers="$CURL_STUB_RESP_DIR/resp-$n.headers"
if [ -n "$header_out" ] && [ -f "$resp_headers" ]; then
	cat "$resp_headers" >"$header_out"
fi

cat "$resp_code"
CURL_STUB
chmod +x "$STUBCURL_DIR/curl"

# ---------------------------------------------------------------------------
# Curl-stub control: queue + logs, reset before every test that uses curl.
# ---------------------------------------------------------------------------
CURL_STUB_RESP_DIR="$WORK/curlresp"
CURL_STUB_COUNTER_FILE="$WORK/curl-counter"
CURL_STUB_ARGV_LOG="$WORK/curl-argv.log"
CURL_STUB_BODY_LOG_DIR="$WORK/curl-bodies"

reset_curl_stub() {
	rm -rf "$CURL_STUB_RESP_DIR" "$CURL_STUB_BODY_LOG_DIR"
	mkdir -p "$CURL_STUB_RESP_DIR" "$CURL_STUB_BODY_LOG_DIR"
	printf '0' >"$CURL_STUB_COUNTER_FILE"
	: >"$CURL_STUB_ARGV_LOG"
}

# set_stub_response N BODY CODE — the Nth curl call gets this response.
set_stub_response() {
	n=$1; body=$2; code=$3
	printf '%s' "$body" >"$CURL_STUB_RESP_DIR/resp-$n.body"
	printf '%s' "$code" >"$CURL_STUB_RESP_DIR/resp-$n.code"
}

# set_stub_headers N HEADERS — the Nth curl call's -D header dump gets these
# raw header lines (used to canned a 303 + Location for resolve_media_uuid).
set_stub_headers() {
	n=$1; headers=$2
	printf '%s' "$headers" >"$CURL_STUB_RESP_DIR/resp-$n.headers"
}

call_count() { cat "$CURL_STUB_COUNTER_FILE" 2>/dev/null || printf '0'; }

# ---------------------------------------------------------------------------
# Runner primitives (same shape as the sibling harnesses). run() takes a
# PATH-toolbox selector, then any number of "VAR=VALUE" env assignments
# (env's own leading-assignment argv parsing — see procedure-gh-issues'
# harness for the same idiom), then the command to run.
# ---------------------------------------------------------------------------
TESTS_RUN=0
TESTS_FAIL=0
CUR_OUT=""
CUR_ERR=""
CUR_RC=0

run() {
	selector=$1; shift
	case "$selector" in
		full)     r_path="$STUBCURL_DIR:$TOOLBOX" ;;
		nocurl)   r_path="$TOOLBOX" ;;
		nojq)     r_path="$STUBCURL_DIR:$NOJQ_TOOLBOX" ;;
		fixedtime) r_path="$STUBCURL_DIR:$FIXEDDATE_TOOLBOX" ;;
		*) printf 'FATAL: bad run() selector: %s\n' "$selector" >&2; exit 1 ;;
	esac
	set +e
	env -i \
		HOME="$WORK/home" \
		PATH="$r_path" \
		TMPDIR="$WORK" \
		CURL_STUB_RESP_DIR="$CURL_STUB_RESP_DIR" \
		CURL_STUB_COUNTER_FILE="$CURL_STUB_COUNTER_FILE" \
		CURL_STUB_ARGV_LOG="$CURL_STUB_ARGV_LOG" \
		CURL_STUB_BODY_LOG_DIR="$CURL_STUB_BODY_LOG_DIR" \
		"$@" >"$WORK/out" 2>"$WORK/err"
	CUR_RC=$?
	set -e
	CUR_OUT=$(cat "$WORK/out"); CUR_ERR=$(cat "$WORK/err")
	rm -f "$WORK/out" "$WORK/err"
	if [ "${VERBOSE:-0}" = "1" ]; then
		printf '    rc=%s\n' "$CUR_RC"
		printf '%s\n' "$CUR_OUT" | sed 's/^/    out| /'
		printf '%s\n' "$CUR_ERR" | sed 's/^/    err| /'
	fi
}

pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; TESTS_FAIL=$((TESTS_FAIL + 1)); }

expect_rc() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if [ "$CUR_RC" -eq "$2" ]; then pass "$1"
	else fail "$1" "expected exit $2, got $CUR_RC; stderr: $CUR_ERR"; fi
}

stdout_has() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if printf '%s\n' "$CUR_OUT" | grep -Fq -- "$2"; then pass "$1"
	else fail "$1" "stdout missing: $2
       stdout was: $CUR_OUT"; fi
}

stdout_not_has() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if printf '%s\n' "$CUR_OUT" | grep -Fq -- "$2"; then fail "$1" "stdout unexpectedly contains: $2"
	else pass "$1"; fi
}

stderr_has() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if printf '%s\n' "$CUR_ERR" | grep -Fq -- "$2"; then pass "$1"
	else fail "$1" "stderr missing: $2
       stderr was: $CUR_ERR"; fi
}

file_has() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if [ -f "$2" ] && grep -Fq -- "$3" "$2"; then pass "$1"
	else fail "$1" "$2 missing: $3"; fi
}

file_not_has() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if [ -f "$2" ] && grep -Fq -- "$3" "$2"; then fail "$1" "$2 unexpectedly contains: $3"
	else pass "$1"; fi
}

# argv_log_has_token / argv_log_not_has_token — like file_has/file_not_has but
# an EXACT-LINE match against the argv log (one argv token per line, see the
# curl stub), not a substring match. This is deliberately stricter than
# file_has for flag assertions: a substring match on "-L" would also match
# inside an unrelated longer token, silently proving nothing.
argv_log_has_token() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if grep -Fxq -- "$2" "$CURL_STUB_ARGV_LOG"; then pass "$1"
	else fail "$1" "argv log missing the exact token: $2"; fi
}

argv_log_not_has_token() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if grep -Fxq -- "$2" "$CURL_STUB_ARGV_LOG"; then fail "$1" "argv log unexpectedly contains the exact token: $2"
	else pass "$1"; fi
}

equals() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if [ "$2" = "$3" ]; then pass "$1"
	else fail "$1" "expected: $3
       got:      $2"; fi
}

section() { printf '\n== %s ==\n' "$1"; }

# ===========================================================================
# usage / argument errors
# ===========================================================================
section "jira.sh — usage / command errors"

run nocurl sh "$JIRA" -h
expect_rc "usage: -h -> exit 0" 0
stdout_has "usage: help text" "Usage"
stdout_has "usage: mentions --confirmed-site" "--confirmed-site"

run nocurl sh "$JIRA"
expect_rc "missing command -> exit 2" 2
stderr_has "missing command: diagnostic" "missing command"

run nocurl sh "$JIRA" bogus
expect_rc "unknown command -> exit 2" 2
stderr_has "unknown command: diagnostic" "unknown command"

run nocurl sh "$JIRA" view PROJ-1
expect_rc "view without --confirmed-site -> exit 2" 2
stderr_has "view without --confirmed-site: diagnostic" "--confirmed-site is required"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" view not-a-key --confirmed-site foo.atlassian.net
expect_rc "view with invalid ticket key -> exit 2" 2
stderr_has "invalid ticket key: diagnostic" "invalid ticket key"

# validate_ticket_key must reject an EMBEDDED/trailing newline, not
# just accept a `grep -Eq '^...$'` match against the first line of a
# multi-line value. These keys are built with a LITERAL newline byte (not
# via `$(...)`, which would strip a trailing one) so the test actually
# exercises the bypass the hardening closes.
EMBEDDED_NEWLINE_KEY="PROJ-1
foo"
run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" view "$EMBEDDED_NEWLINE_KEY" --confirmed-site foo.atlassian.net
expect_rc "view with an embedded-newline ticket key -> exit 2" 2
stderr_has "embedded-newline ticket key: diagnostic" "invalid ticket key"

TRAILING_NEWLINE_KEY="PROJ-1
"
run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" view "$TRAILING_NEWLINE_KEY" --confirmed-site foo.atlassian.net
expect_rc "view with a trailing-newline ticket key -> exit 2" 2
stderr_has "trailing-newline ticket key: diagnostic" "invalid ticket key"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" workflow --confirmed-site foo.atlassian.net
expect_rc "workflow without a ticket key -> exit 2" 2
stderr_has "workflow without ticket key: diagnostic" "requires a ticket key"

# ===========================================================================
# site gate — fails closed, no curl call ever made. Uses
# the "full" toolbox (curl stub present, but the response queue stays EMPTY)
# so each assertion also proves the gate fired BEFORE any network call —
# curl/jq presence is checked first (see the script's dispatch ordering),
# so these tests must supply real tools to reach the gate at all.
# ===========================================================================
section "jira.sh — site gate (fail closed)"

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" view PROJ-1 --confirmed-site evil.example.com
expect_rc "host outside allow-list -> exit 1" 1
stderr_has "host outside allow-list: diagnostic" "not in the allow-list"
equals "host outside allow-list: no network call was made" "$(call_count)" "0"

reset_curl_stub
run full "JIRA_SITE=other.atlassian.net" "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" view PROJ-1 --confirmed-site foo.atlassian.net
expect_rc "intended-site != confirmed-site -> exit 1" 1
stderr_has "site mismatch: diagnostic" "site mismatch"
equals "site mismatch: no network call was made" "$(call_count)" "0"

reset_curl_stub
set_stub_response 1 '{"key":"PROJ-1","fields":{"summary":"s","status":{"name":"Open"},"issuetype":{"name":"Task"}}}' 200
run full "JIRA_SITE=foo.atlassian.net" "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" view PROJ-1 --confirmed-site https://foo.atlassian.net/
expect_rc "intended-site == confirmed-site (scheme/slash normalized) does NOT fail the gate" 0

reset_curl_stub
run full "JIRA_CURL_CONFIG=$WORK/does-not-exist.curlrc" \
	sh "$JIRA" view PROJ-1 --confirmed-site foo.atlassian.net
expect_rc "JIRA_CURL_CONFIG pointing nowhere -> exit 1" 1
stderr_has "missing JIRA_CURL_CONFIG: diagnostic" "missing/unreadable"
equals "missing JIRA_CURL_CONFIG: no network call was made" "$(call_count)" "0"

reset_curl_stub
run full sh "$JIRA" view PROJ-1 --confirmed-site foo.atlassian.net
expect_rc "no credentials at all -> exit 1" 1
stderr_has "no credentials: diagnostic" "no credentials available"
equals "no credentials: no network call was made" "$(call_count)" "0"

# ===========================================================================
# credential handoff — the token NEVER touches argv
# ===========================================================================
section "jira.sh — credential handoff: token never on argv"

reset_curl_stub
set_stub_response 1 '{"key":"PROJ-1","fields":{"summary":"s","status":{"name":"Open"},"issuetype":{"name":"Task"}}}' 200

run full "JIRA_EMAIL=agent@example.com" "JIRA_TOKEN=super-secret-token-value" \
	sh "$JIRA" view PROJ-1 --confirmed-site foo.atlassian.net
expect_rc "view with own-resolved credentials -> exit 0" 0
file_not_has "argv log never contains the raw token" "$CURL_STUB_ARGV_LOG" "super-secret-token-value"
file_not_has "argv log never contains -u/--user" "$CURL_STUB_ARGV_LOG" "-u"
file_has "argv log DOES contain -K (the config-file handoff)" "$CURL_STUB_ARGV_LOG" "-K"

section "jira.sh — credential handoff: JIRA_CURL_CONFIG passthrough is never deleted"

OWN_CFG="$WORK/preexisting.curlrc"
printf 'user = "someone@example.com:their-token"\n' >"$OWN_CFG"
reset_curl_stub
set_stub_response 1 '{"key":"PROJ-1","fields":{"summary":"s","status":{"name":"Open"},"issuetype":{"name":"Task"}}}' 200
run full "JIRA_CURL_CONFIG=$OWN_CFG" sh "$JIRA" view PROJ-1 --confirmed-site foo.atlassian.net
expect_rc "view via JIRA_CURL_CONFIG -> exit 0" 0
argv_log_has_token "JIRA_CURL_CONFIG: -K flag present" "-K"
argv_log_has_token "JIRA_CURL_CONFIG: curl was invoked with -K \$OWN_CFG (the exact path)" "$OWN_CFG"
TESTS_RUN=$((TESTS_RUN + 1))
if [ -f "$OWN_CFG" ]; then pass "pre-supplied curl-config file survives (not ours to delete)"
else fail "pre-supplied curl-config file survives" "file was removed"; fi

# ===========================================================================
# view <KEY>
# ===========================================================================
section "jira.sh — view: --json passthrough"

reset_curl_stub
set_stub_response 1 '{"key":"PROJ-1","fields":{"summary":"Fix the thing","status":{"name":"Open"},"issuetype":{"name":"Task"},"assignee":{"displayName":"A. Gent"}}}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" view PROJ-1 --confirmed-site foo.atlassian.net --json
expect_rc "view --json -> exit 0" 0
VIEW_JSON_KEY=$(printf '%s' "$CUR_OUT" | jq -r '.key')
equals "view --json: raw body on stdout parses as JSON with the right key" "$VIEW_JSON_KEY" "PROJ-1"

section "jira.sh — view: human render strips control/ANSI from response text"

reset_curl_stub
ESC=$(printf '\033')
BEL=$(printf '\007')
SOH=$(printf '\001')
DIRTY_SUMMARY="Danger${ESC}[31m RED ${ESC}[0mtext${BEL}Bell${SOH}Ctrl"
set_stub_response 1 "$(jq -n -c --arg s "$DIRTY_SUMMARY" '{key:"PROJ-2",fields:{summary:$s,status:{name:"Open"},issuetype:{name:"Bug"},assignee:{displayName:"A"}}}')" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" view PROJ-2 --confirmed-site foo.atlassian.net
expect_rc "view human render -> exit 0" 0
stdout_not_has "ANSI escape sequence stripped from render" "${ESC}["
stdout_not_has "bare C0 byte (BEL, \\007) stripped from render" "$BEL"
stdout_not_has "bare C0 byte (SOH, \\001) stripped from render" "$SOH"
stdout_has "underlying text survives the strip" "Danger"
stdout_has "underlying text survives the strip (RED)" "RED"
stdout_has "underlying text survives the strip (Bell)" "Bell"
stdout_has "underlying text survives the strip (Ctrl)" "Ctrl"

section "jira.sh — view: --fields resolves semantic names through the project config"

mkdir -p "$WORK/projects"
cat >"$WORK/projects/PROJ.json" <<'EOF'
{
  "key": "PROJ",
  "custom_fields": { "acceptance_criteria": "customfield_16102" },
  "type_aliases": { "subtask": "Sub-task" }
}
EOF
reset_curl_stub
set_stub_response 1 '{"key":"PROJ-3","fields":{"summary":"s","status":{"name":"Open"},"issuetype":{"name":"Task"}}}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$WORK/projects" \
	sh "$JIRA" view PROJ-3 --confirmed-site foo.atlassian.net --fields acceptance_criteria,summary
expect_rc "view --fields with config alias -> exit 0" 0
file_has "request URL carries the RESOLVED custom field id" "$CURL_STUB_ARGV_LOG" "customfield_16102"

section "jira.sh — view: non-2xx fails with Jira's error message"

reset_curl_stub
set_stub_response 1 '{"errorMessages":["Issue does not exist"]}' 404
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" view PROJ-9 --confirmed-site foo.atlassian.net
expect_rc "view 404 -> exit 1" 1
stderr_has "view 404: HTTP code in diagnostic" "HTTP 404"
stderr_has "view 404: Jira's own error message surfaced" "Issue does not exist"

section "jira.sh — view: a 2xx response with a non-JSON body fails as an API error, not a stray jq exit-2"

reset_curl_stub
set_stub_response 1 '<html>not json, e.g. an intermediary proxy error page</html>' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" view PROJ-9 --confirmed-site foo.atlassian.net
expect_rc "view 200-with-non-JSON-body -> exit 1 (NOT jq's own exit 2)" 1
stderr_has "view 200-with-non-JSON-body: diagnostic" "not valid JSON"

# ===========================================================================
# workflow <KEY>
# ===========================================================================
section "jira.sh — workflow: human render + available transitions"

reset_curl_stub
set_stub_response 1 '{"transitions":[{"id":"11","to":{"name":"In Progress"}},{"id":"21","to":{"name":"Done"}}]}' 200
set_stub_response 2 '{"fields":{"status":{"name":"Open"},"issuetype":{"name":"Task"}}}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" workflow PROJ-1 --confirmed-site foo.atlassian.net
expect_rc "workflow human render -> exit 0" 0
stdout_has "workflow: current status shown" "Open"
stdout_has "workflow: transition target shown" "In Progress"
stdout_has "workflow: second transition target shown" "Done"

section "jira.sh — workflow: --json makes exactly ONE call (no status lookup)"

reset_curl_stub
set_stub_response 1 '{"transitions":[{"id":"11","to":{"name":"In Progress"}}]}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" workflow PROJ-1 --confirmed-site foo.atlassian.net --json
expect_rc "workflow --json -> exit 0" 0
stdout_has "workflow --json: raw transitions body" '"to":{"name":"In Progress"}}'
equals "workflow --json: exactly one curl call" "$(call_count)" "1"

section "jira.sh — workflow: zero transitions"

reset_curl_stub
set_stub_response 1 '{"transitions":[]}' 200
set_stub_response 2 '{"fields":{"status":{"name":"Done"},"issuetype":{"name":"Task"}}}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" workflow PROJ-1 --confirmed-site foo.atlassian.net
expect_rc "workflow zero transitions -> exit 0" 0
stdout_has "workflow zero transitions: final-state message" "No transitions available"

# ===========================================================================
# search
# ===========================================================================
section "jira.sh — search: requires at least one filter"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" search --confirmed-site foo.atlassian.net
expect_rc "search with no filters and no --jql -> exit 2" 2
stderr_has "search no filters: diagnostic" "requires at least one filter"

section "jira.sh — search: rejects a stray positional argument"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" search PROJ-123 --confirmed-site foo.atlassian.net --status Open
expect_rc "search with a stray ticket-key positional -> exit 2" 2
stderr_has "search stray positional: diagnostic" "takes no positional argument"

section "jira.sh — search: builds the /search/jql endpoint with a POST"

reset_curl_stub
set_stub_response 1 '{"issues":[{"key":"PROJ-1","fields":{"summary":"a","status":{"name":"Open"}}}],"isLast":true}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" search --confirmed-site foo.atlassian.net --project PROJ
expect_rc "search basic -> exit 0" 0
file_has "search hits /rest/api/3/search/jql" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/search/jql"
file_has "search uses POST" "$CURL_STUB_ARGV_LOG" "POST"
JQL_SENT=$(jq -r '.jql' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "search JQL: project clause built correctly" "$JQL_SENT" 'project = "PROJ"'

section "jira.sh — search: defaults the field set when --fields is omitted (live Jira returns id-only otherwise)"

reset_curl_stub
set_stub_response 1 '{"issues":[],"isLast":true}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" search --confirmed-site foo.atlassian.net --project PROJ
expect_rc "search without --fields -> exit 0" 0
SENT_FIELDS=$(jq -c '.fields' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "search without --fields: request carries the DEFAULT_SEARCH_FIELDS set, key first" \
	"$SENT_FIELDS" '["key","summary","status","assignee","issuetype"]'

section "jira.sh — search: --fields still overrides the default"

reset_curl_stub
set_stub_response 1 '{"issues":[],"isLast":true}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" search --confirmed-site foo.atlassian.net --project PROJ --fields "key,summary,status"
expect_rc "search with explicit --fields -> exit 0" 0
SENT_FIELDS=$(jq -c '.fields' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "search with explicit --fields: request carries EXACTLY the caller's list, not the default" \
	"$SENT_FIELDS" '["key","summary","status"]'

section "jira.sh — transport hardening: --proto '=https' present, -L/-k/--insecure absent"

argv_log_has_token "transport: --proto present" "--proto"
argv_log_has_token "transport: --proto value is '=https'" "=https"
argv_log_not_has_token "transport: -L (redirect-follow) absent" "-L"
argv_log_not_has_token "transport: -k (insecure) absent" "-k"
argv_log_not_has_token "transport: --insecure absent" "--insecure"

section "jira.sh — search: JQL escaping — quote+backslash escaped, not a broken-out clause"

reset_curl_stub
set_stub_response 1 '{"issues":[],"isLast":true}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" search --confirmed-site foo.atlassian.net --status 'x" OR project=SECRET'
expect_rc "search with injection-shaped --status -> exit 0" 0
JQL_SENT=$(jq -r '.jql' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "search JQL: the quote is backslash-escaped, clause stays ONE string literal" \
	"$JQL_SENT" 'status = "x\" OR project=SECRET"'
TESTS_RUN=$((TESTS_RUN + 1))
case "$JQL_SENT" in
	*'OR project = "SECRET"'*|*'OR project=SECRET"'*'"'*)
		fail "search JQL: no broken-out OR clause escaped the string" "got: $JQL_SENT" ;;
	*) pass "search JQL: no broken-out OR clause escaped the string" ;;
esac

section "jira.sh — search: JQL escaping parameterized across --type"

# assert_field_escapes FLAG FIELD_NAME — a data-driven check that the SAME
# adversarial value, fed through FLAG, produces an escaped `FIELD_NAME =
# "..."` clause and never a broken-out OR clause. Covers the field-specific
# clause builders individually, not just the shared escape function status
# already exercises above — guards against a future per-field regression
# that bypasses jql_quoted() for one field only. --project is deliberately
# NOT parameterized here (see the dedicated allow-list test right below):
# --project is shape-validated to `^[A-Z][A-Z0-9]+$`
# BEFORE it ever reaches the JQL builder, so this exact adversarial value is
# rejected at that earlier gate and never gets a chance to need escaping —
# a stronger guarantee than escaping (the value can't exist at all), not a
# gap in this test.
assert_field_escapes() {
	flag_name=$1
	field_name=$2
	reset_curl_stub
	set_stub_response 1 '{"issues":[],"isLast":true}' 200
	run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
		sh "$JIRA" search --confirmed-site foo.atlassian.net "$flag_name" 'x" OR project=SECRET'
	expect_rc "search --$flag_name injection-shaped -> exit 0" 0
	sent_jql=$(jq -r '.jql' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
	equals "search --$flag_name JQL: quote backslash-escaped, ONE string literal" \
		"$sent_jql" "$field_name = \"x\\\" OR project=SECRET\""
}
assert_field_escapes --type type

section "jira.sh — search: --project is shape-validated BEFORE it can reach any sink"

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" search --confirmed-site foo.atlassian.net --project 'x" OR project=SECRET'
expect_rc "search --project injection-shaped -> exit 1 (rejected before the JQL sink)" 1
stderr_has "search --project injection-shaped: diagnostic" "invalid project key"
equals "search --project injection-shaped: no network call was made" "$(call_count)" "0"

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" search --confirmed-site foo.atlassian.net --project '../../etc/passwd'
expect_rc "search --project path-traversal-shaped -> exit 1" 1
stderr_has "search --project path-traversal-shaped: diagnostic" "invalid project key"

section "jira.sh — search: --assignee me uses currentUser() with NO lookup call"

reset_curl_stub
set_stub_response 1 '{"issues":[],"isLast":true}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" search --confirmed-site foo.atlassian.net --project PROJ --assignee me
expect_rc "search --assignee me -> exit 0" 0
JQL_SENT=$(jq -r '.jql' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
TESTS_RUN=$((TESTS_RUN + 1))
case "$JQL_SENT" in
	*'assignee = currentUser()'*) pass "search --assignee me: JQL uses currentUser()" ;;
	*) fail "search --assignee me: JQL uses currentUser()" "got: $JQL_SENT" ;;
esac
equals "search --assignee me: exactly one curl call (no /myself lookup)" "$(call_count)" "1"

section "jira.sh — search: --assignee @me resolves via GET /myself"

reset_curl_stub
set_stub_response 1 '{"accountId":"acc-self-123"}' 200
set_stub_response 2 '{"issues":[],"isLast":true}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=distinctive-token-me-flow" \
	sh "$JIRA" search --confirmed-site foo.atlassian.net --assignee @me
expect_rc "search --assignee @me -> exit 0" 0
file_has "search --assignee @me: hits /myself first" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/myself"
JQL_SENT=$(jq -r '.jql' "$CURL_STUB_BODY_LOG_DIR/call-2.body")
equals "search --assignee @me: JQL quotes the resolved accountId" "$JQL_SENT" 'assignee = "acc-self-123"'
# the token must be absent from the ACCUMULATED argv log across
# BOTH calls in this flow (/myself, then /search/jql) — not just checked
# after a single call, since a multi-call flow gives the token two chances
# to leak.
file_not_has "search --assignee @me: token absent across the WHOLE 2-call flow" "$CURL_STUB_ARGV_LOG" "distinctive-token-me-flow"
argv_log_not_has_token "search --assignee @me: -u absent across the whole flow" "-u"
argv_log_not_has_token "search --assignee @me: --user absent across the whole flow" "--user"

section "jira.sh — search: --assignee EMAIL resolves via the stubbed GET /user/search"

reset_curl_stub
set_stub_response 1 '[{"accountId":"acc-abc-999","emailAddress":"dev@example.com"}]' 200
set_stub_response 2 '{"issues":[],"isLast":true}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=distinctive-token-email-flow" \
	sh "$JIRA" search --confirmed-site foo.atlassian.net --assignee dev@example.com
expect_rc "search --assignee EMAIL -> exit 0" 0
file_has "search --assignee EMAIL: hits /user/search" "$CURL_STUB_ARGV_LOG" "/rest/api/3/user/search?query="
JQL_SENT=$(jq -r '.jql' "$CURL_STUB_BODY_LOG_DIR/call-2.body")
equals "search --assignee EMAIL: JQL quotes the resolved accountId" "$JQL_SENT" 'assignee = "acc-abc-999"'
file_not_has "search --assignee EMAIL: token absent across the WHOLE 2-call flow" "$CURL_STUB_ARGV_LOG" "distinctive-token-email-flow"
argv_log_not_has_token "search --assignee EMAIL: -u absent across the whole flow" "-u"
argv_log_not_has_token "search --assignee EMAIL: --user absent across the whole flow" "--user"

# regression check: build_jql()'s --assignee path resolves the
# accountId via resolve_account_id() -> jira_curl() -> ensure_workdir(),
# reached from INSIDE `jql=$(build_jql)` — a command-substitution SUBSHELL.
# Before the fix, WORKDIR was created only in that subshell and discarded
# when it exited, so cleanup()'s EXIT trap (running in the MAIN shell, where
# $WORKDIR was still "") never removed it — every such search orphaned a
# jira.work.XXXXXX dir under TMPDIR. Assert none survive this run.
TESTS_RUN=$((TESTS_RUN + 1))
LEAKED_WORKDIRS=$(find "$WORK" -maxdepth 1 -name 'jira.work.*' 2>/dev/null | wc -l | tr -d ' ')
if [ "$LEAKED_WORKDIRS" -eq 0 ]; then
	pass "search --assignee EMAIL: no jira.work.* dir survives (fix confirmed)"
else
	fail "search --assignee EMAIL: no jira.work.* dir survives (fix confirmed)" \
		"found $LEAKED_WORKDIRS leaked dir(s) under $WORK"
fi

section "jira.sh — search: --assignee adversarial value never reaches the JQL — only the resolved accountId does"

reset_curl_stub
set_stub_response 1 '[{"accountId":"acc-safe-000"}]' 200
set_stub_response 2 '{"issues":[],"isLast":true}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" search --confirmed-site foo.atlassian.net --assignee 'x" OR project=SECRET'
expect_rc "search --assignee injection-shaped -> exit 0" 0
# --assignee's raw text never reaches jql_quoted() directly: it is first
# consumed as a /user/search QUERY PARAMETER (urlencoded by urlencode()),
# and only the RESOLVED accountId is ever quoted into the JQL. So the
# equivalent safety property here is stronger than escaping: the injected
# text must be entirely ABSENT from both the request URL and the final JQL.
file_not_has "search --assignee injection-shaped: raw value absent from the /user/search URL" \
	"$CURL_STUB_ARGV_LOG" 'x" OR project=SECRET'
JQL_SENT=$(jq -r '.jql' "$CURL_STUB_BODY_LOG_DIR/call-2.body")
equals "search --assignee injection-shaped: JQL contains ONLY the resolved accountId" \
	"$JQL_SENT" 'assignee = "acc-safe-000"'

section "jira.sh — search: --labels builds an OR'd clause, each value escaped"

reset_curl_stub
set_stub_response 1 '{"issues":[],"isLast":true}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" search --confirmed-site foo.atlassian.net --project PROJ --labels 'a,b'
expect_rc "search --labels a,b -> exit 0" 0
JQL_SENT=$(jq -r '.jql' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "search --labels: builds the OR'd clause, AND'd with project" \
	"$JQL_SENT" 'project = "PROJ" AND (labels = "a" OR labels = "b")'

reset_curl_stub
set_stub_response 1 '{"issues":[],"isLast":true}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" search --confirmed-site foo.atlassian.net --labels 'x" OR project=SECRET'
expect_rc "search --labels injection-shaped -> exit 0" 0
JQL_SENT=$(jq -r '.jql' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "search --labels injection-shaped: quote backslash-escaped inside the OR'd clause" \
	"$JQL_SENT" '(labels = "x\" OR project=SECRET")'

section "jira.sh — search: --assignee EMAIL with no matching user fails closed"

reset_curl_stub
set_stub_response 1 '[]' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" search --confirmed-site foo.atlassian.net --assignee nobody@example.com
expect_rc "search --assignee no match -> exit 1" 1
stderr_has "search --assignee no match: diagnostic" "no Jira user found"

section "jira.sh — search: --type resolves through the project config's type_aliases"

reset_curl_stub
set_stub_response 1 '{"issues":[],"isLast":true}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$WORK/projects" \
	sh "$JIRA" search --confirmed-site foo.atlassian.net --project PROJ --type subtask
expect_rc "search --type alias -> exit 0" 0
JQL_SENT=$(jq -r '.jql' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
TESTS_RUN=$((TESTS_RUN + 1))
case "$JQL_SENT" in
	*'type = "Sub-task"'*) pass "search --type: alias resolved to the config's canonical type" ;;
	*) fail "search --type: alias resolved to the config's canonical type" "got: $JQL_SENT" ;;
esac

section "jira.sh — search: raw --jql passthrough overrides other filters"

reset_curl_stub
set_stub_response 1 '{"issues":[],"isLast":true}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" search --confirmed-site foo.atlassian.net --project PROJ --status Open --jql 'assignee = currentUser() ORDER BY created DESC'
expect_rc "search --jql passthrough -> exit 0" 0
JQL_SENT=$(jq -r '.jql' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "search --jql: raw string used verbatim, other filters ignored" \
	"$JQL_SENT" 'assignee = currentUser() ORDER BY created DESC'

section "jira.sh — search: pagination via nextPageToken (NOT startAt)"

reset_curl_stub
set_stub_response 1 '{"issues":[{"key":"P-1","fields":{"summary":"a","status":{"name":"Open"}}},{"key":"P-2","fields":{"summary":"b","status":{"name":"Open"}}}],"isLast":false,"nextPageToken":"tok-page-2"}' 200
set_stub_response 2 '{"issues":[{"key":"P-3","fields":{"summary":"c","status":{"name":"Open"}}}],"isLast":true}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" search --confirmed-site foo.atlassian.net --project PROJ --page-size 2 --limit 10 --json
expect_rc "search pagination -> exit 0" 0
equals "search pagination: TWO pages fetched" "$(call_count)" "2"
PAGE2_TOKEN=$(jq -r '.nextPageToken' "$CURL_STUB_BODY_LOG_DIR/call-2.body")
equals "search pagination: page 2 request carries the token from page 1" "$PAGE2_TOKEN" "tok-page-2"
TOTAL_ISSUES=$(printf '%s' "$CUR_OUT" | jq '.issues | length')
equals "search pagination: all 3 issues across both pages are merged" "$TOTAL_ISSUES" "3"

section "jira.sh — search: --limit bounds the total fetched (no unbounded reads)"

reset_curl_stub
set_stub_response 1 '{"issues":[{"key":"P-1","fields":{"summary":"a","status":{"name":"Open"}}},{"key":"P-2","fields":{"summary":"b","status":{"name":"Open"}}}],"isLast":false,"nextPageToken":"tok-2"}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" search --confirmed-site foo.atlassian.net --project PROJ --page-size 2 --limit 2 --json
expect_rc "search --limit stops after the cap -> exit 0" 0
equals "search --limit: only ONE page fetched even though isLast=false" "$(call_count)" "1"

section "jira.sh — search: --limit/--page-size validation"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" search --confirmed-site foo.atlassian.net --project PROJ --limit abc
expect_rc "search --limit abc (non-numeric) -> exit 2" 2
stderr_has "search --limit abc: diagnostic" "must be a positive integer"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" search --confirmed-site foo.atlassian.net --project PROJ --page-size 0
expect_rc "search --page-size 0 -> exit 2" 2
stderr_has "search --page-size 0: diagnostic" "must be a positive integer"

reset_curl_stub
set_stub_response 1 '{"issues":[],"isLast":true}' 200
# --limit must be >= the clamped ceiling (100) here, or the per-page size
# would be bounded by the (lower) --limit/remaining-count math instead of
# by the --page-size clamp this test means to isolate.
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" search --confirmed-site foo.atlassian.net --project PROJ --page-size 500 --limit 200
expect_rc "search --page-size 500 (over the ceiling) -> exit 0" 0
stderr_has "search --page-size 500: warns about the 100 ceiling" "capped at Jira's own 100-per-request ceiling"
SENT_MAX_RESULTS=$(jq -r '.maxResults' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "search --page-size 500: request body maxResults clamped to 100" "$SENT_MAX_RESULTS" "100"

section "jira.sh — search: non-2xx fails with Jira's own error message"

reset_curl_stub
set_stub_response 1 '{"errorMessages":["The JQL you have entered is not valid"]}' 400
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" search --confirmed-site foo.atlassian.net --jql 'bogus jql ((('
expect_rc "search 400 -> exit 1" 1
stderr_has "search 400: Jira's own error message surfaced" "is not valid"

section "jira.sh — search: human render strips control/ANSI"

reset_curl_stub
ESC=$(printf '\033')
DIRTY='Bad summary'"${ESC}"'[1mBOLD'"${ESC}"'[0m'
set_stub_response 1 "$(jq -n -c --arg s "$DIRTY" '{issues:[{key:"P-1",fields:{summary:$s,status:{name:"Open"}}}],isLast:true}')" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" search --confirmed-site foo.atlassian.net --project PROJ
expect_rc "search human render -> exit 0" 0
stdout_not_has "search render: ANSI stripped" "${ESC}["
stdout_has "search render: underlying text survives" "BOLD"

# ===========================================================================
# link-types — GET /rest/api/3/issueLinkType
# ===========================================================================
section "jira.sh — link-types: --json passthrough + human render"

reset_curl_stub
set_stub_response 1 '{"issueLinkTypes":[{"id":"10000","name":"Blocks","inward":"is blocked by","outward":"blocks"},{"id":"10001","name":"Relates","inward":"relates to","outward":"relates to"}]}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" link-types --confirmed-site foo.atlassian.net --json
expect_rc "link-types --json -> exit 0" 0
LT_JSON_FIRST_NAME=$(printf '%s' "$CUR_OUT" | jq -r '.issueLinkTypes[0].name')
equals "link-types --json: raw body on stdout parses as JSON" "$LT_JSON_FIRST_NAME" "Blocks"
file_has "link-types: hits GET /rest/api/3/issueLinkType" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/issueLinkType"

reset_curl_stub
set_stub_response 1 '{"issueLinkTypes":[{"id":"10000","name":"Blocks","inward":"is blocked by","outward":"blocks"}]}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" link-types --confirmed-site foo.atlassian.net
expect_rc "link-types human render -> exit 0" 0
stdout_has "link-types human: name shown" "Blocks"
stdout_has "link-types human: outward wording shown" "blocks"
stdout_has "link-types human: inward wording shown" "is blocked by"

section "jira.sh — link-types: takes no positional argument"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" link-types PROJ-1 --confirmed-site foo.atlassian.net
expect_rc "link-types with a stray positional -> exit 2" 2
stderr_has "link-types stray positional: diagnostic" "takes no positional argument"

section "jira.sh — link-types: non-2xx fails with Jira's own error message"

reset_curl_stub
set_stub_response 1 '{"errorMessages":["Not authorized"]}' 401
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" link-types --confirmed-site foo.atlassian.net
expect_rc "link-types 401 -> exit 1" 1
stderr_has "link-types 401: Jira's own error message surfaced" "Not authorized"

# ===========================================================================
# children <KEY> — reuses the search engine with a `parent = "KEY"` JQL
# ===========================================================================
section "jira.sh — children: builds parent = \"KEY\" and drives the search engine"

reset_curl_stub
set_stub_response 1 '{"issues":[{"key":"PROJ-2","fields":{"summary":"child one","status":{"name":"Open"}}}],"isLast":true}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" children PROJ-1 --confirmed-site foo.atlassian.net
expect_rc "children basic -> exit 0" 0
file_has "children hits /rest/api/3/search/jql (the SAME search endpoint)" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/search/jql"
CHILDREN_JQL_SENT=$(jq -r '.jql' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "children: JQL is parent = \"KEY\"" "$CHILDREN_JQL_SENT" 'parent = "PROJ-1"'
stdout_has "children human render: child ticket shown" "PROJ-2"

section "jira.sh — children: respects --fields/--limit/--page-size like search"

reset_curl_stub
set_stub_response 1 '{"issues":[],"isLast":true}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" children PROJ-1 --confirmed-site foo.atlassian.net --fields "key,summary" --json
expect_rc "children --fields --json -> exit 0" 0
CHILDREN_FIELDS_SENT=$(jq -c '.fields' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "children --fields: request carries the caller's explicit field list" \
	"$CHILDREN_FIELDS_SENT" '["key","summary"]'

reset_curl_stub
set_stub_response 1 '{"issues":[],"isLast":true}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" children PROJ-1 --confirmed-site foo.atlassian.net --page-size 5 --json
expect_rc "children --page-size -> exit 0" 0
CHILDREN_MAX_RESULTS_SENT=$(jq -r '.maxResults' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "children --page-size: request body maxResults honors the caller's --page-size" \
	"$CHILDREN_MAX_RESULTS_SENT" "5"

section "jira.sh — children: the ticket key is escaped through the SAME JQL-sink control"

reset_curl_stub
run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" children 'not-a-key' --confirmed-site foo.atlassian.net
expect_rc "children invalid key -> exit 2 (rejected before it can reach the JQL sink)" 2
stderr_has "children invalid key: diagnostic" "invalid ticket key"

section "jira.sh — children: requires a ticket key"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" children --confirmed-site foo.atlassian.net
expect_rc "children without a ticket key -> exit 2" 2
stderr_has "children without ticket key: diagnostic" "requires a ticket key"

# ===========================================================================
# discover <PROJECT> — introspect createmeta + /field, emit the consumed config
# ===========================================================================

# An injection-shaped custom field name authored (in this stub) by "another
# Jira user": contains a command substitution, a backtick, and a double quote.
# It must round-trip completely INERT into the config (a literal JSON key), and
# must never be executed by any layer of discover's jq pipeline (the
# WRITE-COMMAND security note: every value enters jq only via --slurpfile).
# shellcheck disable=SC2016  # the $()/backtick are the injection FIXTURE — they must stay literal, never expand
INJ_NAME='inj$(touch pwned)`whoami`"end'

# queue_discover_responses — the SEVEN canned responses for one full discover
# walk, on the REAL createmeta shapes (captured from live Jira): issuetypes and
# per-type fields are OFFSET-paginated beans whose page array lives under
# `issueTypes` / `fields` respectively (NOT `.values`), carry `startAt` /
# `maxResults` / `total`, and have NO `isLast`. Call order: issuetypes page 1
# (startAt 0, total 3) + page 2 (startAt 2, the subtask type) — a page-1-only
# bug would MISS `Subtask`; then per-type create-screen fields — type 10001
# across TWO pages (total 3; a page-1-only bug MISSES `Acceptance Criteria`),
# types 10002 (the injection field + the OR-arm field) and 10003 one page each
# — then the global /field catalog (a plain array, authoritative names).
# Defined once because every discover --write scenario reuses it.
# Custom-detection OR-arm coverage: type-10002 carries customfield_20001 WITH a
# customfield_ id but NO schema.custom (exercises the OR-arm of the
# custom-detection predicate). The `assignee` field (schema.type user,
# non-custom) also proves non-custom exclusion.
# shellcheck disable=SC2016  # $inj holds the injection FIXTURE; jq reads it via --arg, it must not shell-expand
queue_discover_responses() {
	set_stub_response 1 '{"issueTypes":[{"id":"10001","name":"Task","subtask":false,"hierarchyLevel":0},{"id":"10002","name":"Story","subtask":false,"hierarchyLevel":0}],"startAt":0,"maxResults":50,"total":3}' 200
	set_stub_response 2 '{"issueTypes":[{"id":"10003","name":"Subtask","subtask":true,"hierarchyLevel":-1}],"startAt":2,"maxResults":50,"total":3}' 200
	set_stub_response 3 '{"fields":[{"fieldId":"assignee","name":"Assignee","required":false,"schema":{"type":"user"}},{"fieldId":"customfield_10016","name":"Story Points (createmeta)","required":false,"schema":{"type":"number","custom":"com.x","customId":10016}}],"startAt":0,"maxResults":50,"total":3}' 200
	set_stub_response 4 '{"fields":[{"fieldId":"customfield_16102","name":"Acceptance Criteria","required":false,"schema":{"type":"string","custom":"com.y","customId":16102}}],"startAt":2,"maxResults":50,"total":3}' 200
	set_stub_response 5 "$(jq -n -c --arg inj "$INJ_NAME" '{fields:[{fieldId:"summary",name:"Summary",required:true,schema:{type:"string"}},{fieldId:"customfield_20001",name:"Sprint (createmeta)",required:false,schema:{type:"array"}},{fieldId:"customfield_99999",name:$inj,required:false,schema:{type:"string",custom:"com.z",customId:99999}}],startAt:0,maxResults:50,total:3}')" 200
	set_stub_response 6 '{"fields":[{"fieldId":"summary","name":"Summary","required":true,"schema":{"type":"string"}}],"startAt":0,"maxResults":50,"total":1}' 200
	set_stub_response 7 "$(jq -n -c --arg inj "$INJ_NAME" '[{id:"customfield_10016",key:"customfield_10016",name:"Story Points",custom:true,schema:{type:"number"}},{id:"customfield_16102",key:"customfield_16102",name:"Acceptance Criteria",custom:true},{id:"customfield_20001",key:"customfield_20001",name:"Sprint",custom:true},{id:"customfield_99999",key:"customfield_99999",name:$inj,custom:true},{id:"summary",key:"summary",name:"Summary",custom:false},{id:"assignee",key:"assignee",name:"Assignee",custom:false}]')" 200
}

section "jira.sh — discover: emits the consumed config shape; pagination pulls ALL types/fields"

reset_curl_stub
queue_discover_responses
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" discover PROJ --confirmed-site foo.atlassian.net
expect_rc "discover -> exit 0" 0

TESTS_RUN=$((TESTS_RUN + 1))
if printf '%s' "$CUR_OUT" | jq -e . >/dev/null 2>&1; then pass "discover: stdout is valid JSON"
else fail "discover: stdout is valid JSON" "stdout was: $CUR_OUT"; fi

DISC_KEYS=$(printf '%s' "$CUR_OUT" | jq -c 'keys')
equals "discover: config carries EXACTLY the consumed shape's keys" \
	"$DISC_KEYS" '["custom_fields","issue_types","subtask_parent_types","subtask_types","type_aliases","workflows"]'

DISC_CF_SP=$(printf '%s' "$CUR_OUT" | jq -r '.custom_fields["Story Points"]')
equals "discover: custom_fields maps 'Story Points' -> id (name from the /field catalog, not createmeta)" \
	"$DISC_CF_SP" "customfield_10016"

DISC_CF_AC=$(printf '%s' "$CUR_OUT" | jq -r '.custom_fields["Acceptance Criteria"]')
equals "discover: OFFSET field paging pulled page 2 (Acceptance Criteria from type-10001 startAt=2)" \
	"$DISC_CF_AC" "customfield_16102"

DISC_TYPES=$(printf '%s' "$CUR_OUT" | jq -c '.issue_types')
equals "discover: OFFSET issuetype paging pulled page 2 (Subtask present alongside Task/Story)" \
	"$DISC_TYPES" '["Story","Subtask","Task"]'

DISC_SUB=$(printf '%s' "$CUR_OUT" | jq -c '.subtask_types')
equals "discover: subtask_types is exactly the subtask-flagged type" "$DISC_SUB" '["Subtask"]'

# A customfield_ id with NO schema.custom is still classified custom.
DISC_CF_SPRINT=$(printf '%s' "$CUR_OUT" | jq -r '.custom_fields["Sprint"]')
equals "discover: OR-arm — a customfield_ id with no schema.custom is classified custom" \
	"$DISC_CF_SPRINT" "customfield_20001"

# NON-custom fields must be excluded (guards over-inclusion).
DISC_CF_SUMMARY=$(printf '%s' "$CUR_OUT" | jq -r '.custom_fields.Summary // "ABSENT"')
equals "discover: non-custom field 'Summary' is EXCLUDED from custom_fields" "$DISC_CF_SUMMARY" "ABSENT"
DISC_CF_SUMMARY_LC=$(printf '%s' "$CUR_OUT" | jq -r '.custom_fields.summary // "ABSENT"')
equals "discover: non-custom fieldId 'summary' is EXCLUDED from custom_fields" "$DISC_CF_SUMMARY_LC" "ABSENT"
DISC_CF_ASSIGNEE=$(printf '%s' "$CUR_OUT" | jq -r '.custom_fields.Assignee // "ABSENT"')
equals "discover: non-custom field 'Assignee' (schema.type user) is EXCLUDED from custom_fields" "$DISC_CF_ASSIGNEE" "ABSENT"

# Offset paging terminates by startAt>=total (there is NO isLast on these
# endpoints): exactly seven GETs — issuetypes x2 pages + fields for 3 types
# (type 10001 spans 2 pages) + /field.
equals "discover: seven GETs total (offset paging pulls every page, stops at startAt>=total)" \
	"$(call_count)" "7"

file_has "discover: hits the SPLIT createmeta issuetypes endpoint" \
	"$CURL_STUB_ARGV_LOG" "/rest/api/3/issue/createmeta/PROJ/issuetypes?startAt=0"
file_has "discover: pages the issuetypes endpoint by OFFSET (a second GET at startAt=2)" \
	"$CURL_STUB_ARGV_LOG" "/rest/api/3/issue/createmeta/PROJ/issuetypes?startAt=2"
file_has "discover: hits the per-type createmeta fields endpoint" \
	"$CURL_STUB_ARGV_LOG" "/rest/api/3/issue/createmeta/PROJ/issuetypes/10001?"
file_has "discover: pages the per-type fields endpoint by OFFSET (a second GET at startAt=2)" \
	"$CURL_STUB_ARGV_LOG" "/rest/api/3/issue/createmeta/PROJ/issuetypes/10001?startAt=2"
file_has "discover: hits the global /field catalog" \
	"$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/field"
file_not_has "discover: does NOT use the deprecated combined createmeta endpoint" \
	"$CURL_STUB_ARGV_LOG" "createmeta?projectKeys="

section "jira.sh — discover: an injection-shaped field name round-trips INERT"

DISC_INJ_ID=$(printf '%s' "$CUR_OUT" | jq -r --arg k "$INJ_NAME" '.custom_fields[$k] // "MISSING"')
equals "discover: injection-shaped field name is a literal config KEY -> its id (not executed/mangled)" \
	"$DISC_INJ_ID" "customfield_99999"
# shellcheck disable=SC2016  # asserting the LITERAL injection bytes survive — must not expand here either
stdout_has "discover: injection metacharacters survive verbatim in the config" 'inj$(touch pwned)'

section "jira.sh — discover --write: creates the config under the projects dir + prints the (created) machine line"

DISCOVER_PROJECTS_DIR="$WORK/discover-projects"   # deliberately NOT pre-created: --write's mkdir -p must create it
reset_curl_stub
queue_discover_responses
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$DISCOVER_PROJECTS_DIR" \
	sh "$JIRA" discover PROJ --confirmed-site foo.atlassian.net --write
expect_rc "discover --write (fresh target) -> exit 0" 0
stdout_has "discover --write: machine line names the (created) outcome" "JIRA_DISCOVERED=PROJ -> $DISCOVER_PROJECTS_DIR/PROJ.json (created)"
file_has "discover --write: config saved under the STUBBED projects dir" \
	"$DISCOVER_PROJECTS_DIR/PROJ.json" "customfield_10016"
WRITTEN_SP=$(jq -r '.custom_fields["Story Points"]' "$DISCOVER_PROJECTS_DIR/PROJ.json")
equals "discover --write: the written file maps 'Story Points' -> id" "$WRITTEN_SP" "customfield_10016"
TESTS_RUN=$((TESTS_RUN + 1))
if find "$DISCOVER_PROJECTS_DIR" -name 'PROJ.json.tmp.*' 2>/dev/null | grep -q .; then
	fail "discover --write: atomic write leaves no .tmp staging file" "a .tmp file remained"
else pass "discover --write: atomic write leaves no .tmp staging file"; fi

section "jira.sh — discover: the written config is CONSUMED by the engine's resolve_field_name (SELF-SEEDING round-trip)"

# self-seeding — this section discovers+writes into its OWN fresh dir
# FIRST (a real write through the merge/create path), THEN reads it back via a
# real `view --fields`, so it never depends on the prior --write test running.
ROUNDTRIP_DIR="$WORK/discover-roundtrip"
reset_curl_stub
queue_discover_responses
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$ROUNDTRIP_DIR" \
	sh "$JIRA" discover PROJ --confirmed-site foo.atlassian.net --write
expect_rc "discover round-trip: seed the config via --write -> exit 0" 0
file_has "discover round-trip: seed config present" "$ROUNDTRIP_DIR/PROJ.json" "customfield_10016"

reset_curl_stub
set_stub_response 1 '{"key":"PROJ-5","fields":{"summary":"s","status":{"name":"Open"},"issuetype":{"name":"Task"}}}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" view PROJ-5 --confirmed-site foo.atlassian.net --projects-dir "$ROUNDTRIP_DIR" --fields "Story Points,summary"
expect_rc "discover round-trip: view --fields via the discovered config -> exit 0" 0
file_has "discover round-trip: view resolved 'Story Points' -> customfield_10016 through the written config" \
	"$CURL_STUB_ARGV_LOG" "customfield_10016"

# ===========================================================================
# discover --write: MERGE, never clobber a human-curated config
# ===========================================================================

# A human-curated existing config: curated type_aliases/subtask_parent_types/
# workflows, a semantic custom_fields key (acceptance_criteria), an extra
# top-level "key", and a STALE issue_types the discovery must refresh away.
write_curated_config() {
	cat >"$1" <<'EOF'
{
  "key": "PROJ",
  "custom_fields": { "acceptance_criteria": "customfield_16102", "developer": "customfield_20777" },
  "type_aliases": { "story": "Story" },
  "subtask_parent_types": ["Story"],
  "workflows": { "Task": { "Open": ["In Progress"], "In Progress": ["Done"] } },
  "issue_types": ["OLD_STALE_TYPE"],
  "subtask_types": []
}
EOF
}

section "jira.sh — discover --write: MERGES into an existing curated config (preserve curation + refresh facts + back up)"

MERGE_DIR="$WORK/discover-merge"
mkdir -p "$MERGE_DIR"
write_curated_config "$MERGE_DIR/PROJ.json"
reset_curl_stub
queue_discover_responses
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$MERGE_DIR" \
	sh "$JIRA" discover PROJ --confirmed-site foo.atlassian.net --write
expect_rc "discover --write (existing target) -> exit 0" 0
stdout_has "discover --write merge: machine line names the (merged) outcome + backup" \
	"JIRA_DISCOVERED=PROJ -> $MERGE_DIR/PROJ.json (merged; backup "
equals "merge PRESERVES curated type_aliases" \
	"$(jq -c '.type_aliases' "$MERGE_DIR/PROJ.json")" '{"story":"Story"}'
equals "merge PRESERVES curated workflows" \
	"$(jq -c '.workflows.Task.Open' "$MERGE_DIR/PROJ.json")" '["In Progress"]'
equals "merge PRESERVES curated subtask_parent_types" \
	"$(jq -c '.subtask_parent_types' "$MERGE_DIR/PROJ.json")" '["Story"]'
equals "merge PRESERVES the human semantic custom_fields key" \
	"$(jq -r '.custom_fields.acceptance_criteria' "$MERGE_DIR/PROJ.json")" "customfield_16102"
equals "merge PRESERVES an extra top-level key discovery does not model" \
	"$(jq -r '.key' "$MERGE_DIR/PROJ.json")" "PROJ"
equals "merge REFRESHES issue_types to the discovered facts (stale type gone)" \
	"$(jq -c '.issue_types' "$MERGE_DIR/PROJ.json")" '["Story","Subtask","Task"]'
equals "merge ADDS the discovered display-name custom field" \
	"$(jq -r '.custom_fields["Story Points"]' "$MERGE_DIR/PROJ.json")" "customfield_10016"
MERGE_BACKUP=$(find "$MERGE_DIR" -name 'PROJ.json.bak-*' 2>/dev/null | head -1)
file_has "merge BACKS UP the original (stale type present in the backup)" "$MERGE_BACKUP" "OLD_STALE_TYPE"
TESTS_RUN=$((TESTS_RUN + 1))
if find "$MERGE_DIR" -name 'PROJ.json.tmp.*' 2>/dev/null | grep -q .; then
	fail "merge: atomic write leaves no .tmp staging file (correct merged content landed via mv)" "a .tmp file remained"
else pass "merge: atomic write leaves no .tmp staging file (correct merged content landed via mv)"; fi

section "jira.sh — discover --write --force: clean replace of an existing config (still backs up)"

FORCE_DIR="$WORK/discover-force"
mkdir -p "$FORCE_DIR"
write_curated_config "$FORCE_DIR/PROJ.json"
reset_curl_stub
queue_discover_responses
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$FORCE_DIR" \
	sh "$JIRA" discover PROJ --confirmed-site foo.atlassian.net --write --force
expect_rc "discover --write --force -> exit 0" 0
stdout_has "discover --force: machine line names the (replaced) outcome + backup" \
	"JIRA_DISCOVERED=PROJ -> $FORCE_DIR/PROJ.json (replaced; backup "
equals "force RESETS type_aliases to the empty discovered slot" \
	"$(jq -c '.type_aliases' "$FORCE_DIR/PROJ.json")" '{}'
equals "force RESETS workflows to the empty discovered slot" \
	"$(jq -c '.workflows' "$FORCE_DIR/PROJ.json")" '{}'
equals "force DROPS the curated semantic custom_fields key" \
	"$(jq -r '.custom_fields.acceptance_criteria // "ABSENT"' "$FORCE_DIR/PROJ.json")" "ABSENT"
FORCE_BACKUP=$(find "$FORCE_DIR" -name 'PROJ.json.bak-*' 2>/dev/null | head -1)
file_has "force STILL backs up the original before replacing" "$FORCE_BACKUP" "OLD_STALE_TYPE"

section "jira.sh — discover --write: an INVALID existing config is backed up + replaced fresh with a WARNING"

INVALID_DIR="$WORK/discover-invalid"
mkdir -p "$INVALID_DIR"
printf '%s' 'this is { not valid json at all' >"$INVALID_DIR/PROJ.json"
reset_curl_stub
queue_discover_responses
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$INVALID_DIR" \
	sh "$JIRA" discover PROJ --confirmed-site foo.atlassian.net --write
expect_rc "discover --write (invalid existing) -> exit 0" 0
stderr_has "invalid existing: warns it is not valid JSON" "not valid JSON"
stdout_has "invalid existing: machine line names the (replaced) outcome + backup" \
	"JIRA_DISCOVERED=PROJ -> $INVALID_DIR/PROJ.json (replaced; backup "
equals "invalid existing: fresh config carries the discovered issue_types" \
	"$(jq -c '.issue_types' "$INVALID_DIR/PROJ.json")" '["Story","Subtask","Task"]'
INVALID_BACKUP=$(find "$INVALID_DIR" -name 'PROJ.json.bak-*' 2>/dev/null | head -1)
file_has "invalid existing: the unparseable original is preserved in the backup" "$INVALID_BACKUP" "not valid json"

section "jira.sh — discover --write: same-UTC-second re-writes never overwrite a backup"

# The `fixedtime` toolbox pins `date` to one stamp, so BOTH writes derive the
# SAME .bak-<UTC> base — the ONLY thing keeping them distinct is the mktemp
# suffix. Without the uniquifier these would collapse to a single backup file.
COLLIDE_DIR="$WORK/discover-collide"
mkdir -p "$COLLIDE_DIR"
write_curated_config "$COLLIDE_DIR/PROJ.json"
reset_curl_stub
queue_discover_responses
run fixedtime "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$COLLIDE_DIR" \
	sh "$JIRA" discover PROJ --confirmed-site foo.atlassian.net --write
expect_rc "collide: first --write (fixed UTC second) -> exit 0" 0
reset_curl_stub
queue_discover_responses
run fixedtime "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$COLLIDE_DIR" \
	sh "$JIRA" discover PROJ --confirmed-site foo.atlassian.net --write
expect_rc "collide: second --write (SAME fixed UTC second) -> exit 0" 0
COLLIDE_BACKUPS=$(find "$COLLIDE_DIR" -name 'PROJ.json.bak-20260725T000000Z.*' 2>/dev/null | wc -l | tr -d ' ')
equals "collide: two same-second writes produced TWO distinct backups (mktemp uniquifier — no overwrite)" \
	"$COLLIDE_BACKUPS" "2"

section "jira.sh — discover: a non-numeric issue-type id is skipped (id guard)"

reset_curl_stub
set_stub_response 1 "$(jq -n -c '{issueTypes:[{id:"10001",name:"Task",subtask:false},{id:"../evil",name:"Evil",subtask:false}],startAt:0,maxResults:50,total:2}')" 200
set_stub_response 2 '{"fields":[{"fieldId":"customfield_10016","name":"Story Points","schema":{"custom":"x","customId":10016}}],"startAt":0,"maxResults":50,"total":1}' 200
set_stub_response 3 '[{"id":"customfield_10016","name":"Story Points","custom":true}]' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" discover PROJ --confirmed-site foo.atlassian.net
expect_rc "discover with a non-numeric type id -> exit 0" 0
stderr_has "discover: warns it is skipping the non-numeric id" "skipping issue type with an unexpected id shape"
equals "discover: only THREE GETs (issuetypes + fields for the ONE valid id + /field) — the bad id got no per-type fetch" \
	"$(call_count)" "3"
file_not_has "discover: NO per-type-fields GET for the traversal-shaped id" \
	"$CURL_STUB_ARGV_LOG" "issuetypes/../evil"

section "jira.sh — discover: duplicate custom-field display names are surfaced"

reset_curl_stub
set_stub_response 1 '{"issueTypes":[{"id":"10001","name":"Task","subtask":false}],"startAt":0,"maxResults":50,"total":1}' 200
set_stub_response 2 '{"fields":[{"fieldId":"customfield_100","name":"x"},{"fieldId":"customfield_200","name":"y"}],"startAt":0,"maxResults":50,"total":2}' 200
set_stub_response 3 '[{"id":"customfield_100","name":"Priority Score","custom":true},{"id":"customfield_200","name":"Priority Score","custom":true}]' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" discover PROJ --confirmed-site foo.atlassian.net
expect_rc "discover with a duplicate display name -> exit 0" 0
stderr_has "discover: warns about the duplicate display name" "duplicate custom-field display name"
stderr_has "discover: names the colliding display name" "Priority Score"
DUP_CF_COUNT=$(printf '%s' "$CUR_OUT" | jq '.custom_fields | length')
equals "discover: the flat map keeps exactly one id under the collided name" "$DUP_CF_COUNT" "1"

section "jira.sh — discover: usage + failure paths"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" discover --confirmed-site foo.atlassian.net
expect_rc "discover without a PROJECT -> exit 2" 2
stderr_has "discover without PROJECT: diagnostic" "requires a PROJECT key"

run nocurl sh "$JIRA" discover PROJ
expect_rc "discover without --confirmed-site -> exit 2" 2
stderr_has "discover without --confirmed-site: diagnostic" "--confirmed-site is required"

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$WORK/discover-traversal" \
	sh "$JIRA" discover '../../x' --confirmed-site foo.atlassian.net --write
expect_rc "discover traversal-shaped PROJECT -> exit 2 (rejected BEFORE any read/write)" 2
stderr_has "discover traversal PROJECT: diagnostic" "invalid project key"
equals "discover traversal PROJECT: no network call was made" "$(call_count)" "0"
TESTS_RUN=$((TESTS_RUN + 1))
if [ -e "$WORK/discover-traversal" ]; then fail "discover traversal PROJECT: no projects dir was created" "dir exists"
else pass "discover traversal PROJECT: no file/dir written under the projects dir"; fi

reset_curl_stub
set_stub_response 1 '{"errorMessages":["Project does not exist or you do not have permission"]}' 404
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" discover PROJ --confirmed-site foo.atlassian.net
expect_rc "discover createmeta 404 -> exit 1" 1
stderr_has "discover 404: HTTP code in diagnostic" "HTTP 404"
stderr_has "discover 404: Jira's own error message surfaced" "Project does not exist"

# ===========================================================================
# version — project versions/releases (Phase-2d). Fixtures use the REAL live
# shapes: GET /project/<K>/versions is a PLAIN JSON ARRAY (NOT a paginated
# {values:[...]} envelope); a version object has a STRING id, `released`, and
# OPTIONAL releaseDate/startDate/overdue/userReleaseDate.
# ===========================================================================
section "jira.sh — version --list: parses the PLAIN ARRAY (human + --json)"

reset_curl_stub
set_stub_response 1 '[{"self":"https://foo.atlassian.net/rest/api/3/version/11751","id":"11751","name":"3.10.0","archived":false,"released":false,"releaseDate":"2026-07-06","startDate":"2026-06-29","overdue":true,"projectId":10521},{"id":"11752","name":"3.11.0","archived":false,"released":true}]' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --list --project PSWS --confirmed-site foo.atlassian.net
expect_rc "version --list -> exit 0" 0
file_has "version --list: GET /rest/api/3/project/PSWS/versions" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/project/PSWS/versions"
stdout_has "version --list: version name rendered" "3.10.0"
stdout_has "version --list: string id rendered" "id 11751"
stdout_has "version --list: released flag rendered" "released true"

reset_curl_stub
set_stub_response 1 '[{"id":"11751","name":"3.10.0","released":false}]' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --list --project PSWS --confirmed-site foo.atlassian.net --json
expect_rc "version --list --json -> exit 0" 0
VER_LIST_JSON_ID=$(printf '%s' "$CUR_OUT" | jq -r '.[0].id')
equals "version --list --json: raw PLAIN-ARRAY body passes through (string id)" "$VER_LIST_JSON_ID" "11751"
# Assert the id's JSON TYPE explicitly so the "string id" guarantee is real —
# a numeric id would fail here, where before nothing constrained the type.
VER_LIST_JSON_ID_TYPE=$(printf '%s' "$CUR_OUT" | jq -r '.[0].id | type')
equals "version --list --json: the id is a JSON string (not a number)" "$VER_LIST_JSON_ID_TYPE" "string"

reset_curl_stub
set_stub_response 1 '[]' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --list --project PSWS --confirmed-site foo.atlassian.net
expect_rc "version --list empty -> exit 0" 0
stdout_has "version --list empty: 'No versions.'" "No versions."

section "jira.sh — version --list: a NAME with an embedded TAB cannot misalign columns"

# A plain IFS=<tab> read split of jq's tab-joined line would let a tab INSIDE
# the name shift every following column (the id would end up holding the name's
# tail). strip_control_ansi runs after the split and removes neither tab nor
# newline, so it cannot save it — the renderer extracts each field by jq instead.
reset_curl_stub
DIRTY_TAB_NAME="Auth$(printf '\t')EVIL"
set_stub_response 1 "$(jq -n -c --arg n "$DIRTY_TAB_NAME" '[{id:"11751",name:$n,released:false}]')" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --list --project PSWS --confirmed-site foo.atlassian.net
expect_rc "version --list tab-in-name -> exit 0" 0
stdout_has "version --list: a tab in the name does NOT shift the id column (id 11751 intact)" "id 11751"
stdout_has "version --list: a tab in the name does NOT shift the released column" "released false"

section "jira.sh — version --list: a NAME with an embedded NEWLINE cannot split a row"

# A newline in the name would break the single record across two `read`
# iterations, rendering two bogus rows. Each object is now one compact JSON
# line and each field is extracted independently, so exactly ONE row renders.
reset_curl_stub
DIRTY_NL_NAME="Auth
EVIL"
set_stub_response 1 "$(jq -n -c --arg n "$DIRTY_NL_NAME" '[{id:"11751",name:$n,released:false}]')" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --list --project PSWS --confirmed-site foo.atlassian.net
expect_rc "version --list newline-in-name -> exit 0" 0
NL_ID_ROWS=$(printf '%s\n' "$CUR_OUT" | grep -c '(id ')
TESTS_RUN=$((TESTS_RUN + 1))
if [ "$NL_ID_ROWS" -eq 1 ]; then
	pass "version --list: a newline in the name renders exactly ONE row, never split into two"
else
	fail "version --list: a newline in the name renders exactly ONE row, never split into two" "counted $NL_ID_ROWS rows"
fi

section "jira.sh — version --create: body project is the KEY STRING, never a numeric projectId (ground-truth guard)"

reset_curl_stub
set_stub_response 1 '{"id":"12000","name":"3.12.0","released":false,"archived":false}' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --create --project PSWS --name 3.12.0 --description "next release" \
		--release-date 2026-12-31 --start-date 2026-06-01 --confirmed-site foo.atlassian.net
expect_rc "version --create -> exit 0" 0
file_has "version --create: POST /rest/api/3/version" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/version"
file_has "version --create: uses POST" "$CURL_STUB_ARGV_LOG" "POST"
VER_CREATE_PROJECT=$(jq -r '.project' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "version --create: body 'project' is the KEY STRING (the API rejects projectId)" "$VER_CREATE_PROJECT" "PSWS"
VER_CREATE_HAS_PROJECTID=$(jq -r 'has("projectId")' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "version --create: body carries NO numeric projectId" "$VER_CREATE_HAS_PROJECTID" "false"
VER_CREATE_NAME=$(jq -r '.name' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "version --create: body name" "$VER_CREATE_NAME" "3.12.0"
VER_CREATE_RELDATE=$(jq -r '.releaseDate' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "version --create: releaseDate carried" "$VER_CREATE_RELDATE" "2026-12-31"
VER_CREATE_STARTDATE=$(jq -r '.startDate' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "version --create: startDate carried" "$VER_CREATE_STARTDATE" "2026-06-01"
stdout_has "version --create: machine line names the new id" "JIRA_VERSION_ID=12000"
stdout_has "version --create: machine line names the new name" "JIRA_VERSION_NAME=3.12.0"

section "jira.sh — version --create: minimal body is EXACTLY {name,project}; --released is a JSON boolean"

reset_curl_stub
set_stub_response 1 '{"id":"12002","name":"2.0"}' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --create --project PSWS --name 2.0 --confirmed-site foo.atlassian.net
expect_rc "version --create minimal -> exit 0" 0
VER_CREATE_MIN_KEYS=$(jq -cS 'keys' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "version --create minimal: body is exactly {name,project} (no empty optionals)" "$VER_CREATE_MIN_KEYS" '["name","project"]'

reset_curl_stub
set_stub_response 1 '{"id":"12001","name":"1.0","released":true}' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --create --project PSWS --name 1.0 --released --confirmed-site foo.atlassian.net
expect_rc "version --create --released -> exit 0" 0
VER_CREATE_RELEASED=$(jq -r '.released' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "version --create --released: released:true" "$VER_CREATE_RELEASED" "true"
VER_CREATE_RELEASED_TYPE=$(jq -r '.released | type' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "version --create --released: released is a JSON boolean, not the string \"true\"" "$VER_CREATE_RELEASED_TYPE" "boolean"

section "jira.sh — version --update / --release / --archive: PUT /version/<id> with a partial body"

reset_curl_stub
set_stub_response 1 '{"id":"11751","name":"3.10.1","released":false}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --update --id 11751 --name 3.10.1 --confirmed-site foo.atlassian.net
expect_rc "version --update -> exit 0" 0
file_has "version --update: PUT /rest/api/3/version/11751" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/version/11751"
file_has "version --update: uses PUT" "$CURL_STUB_ARGV_LOG" "PUT"
VER_UPDATE_KEYS=$(jq -cS 'keys' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "version --update: body carries ONLY the changed field" "$VER_UPDATE_KEYS" '["name"]'
VER_UPDATE_NAME=$(jq -r '.name' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "version --update: name value" "$VER_UPDATE_NAME" "3.10.1"
stdout_has "version --update: machine line" "JIRA_VERSION_ID=11751"

reset_curl_stub
set_stub_response 1 '{"id":"11751","name":"3.10.0","released":true,"releaseDate":"2026-07-06"}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --release --id 11751 --release-date 2026-07-06 --confirmed-site foo.atlassian.net
expect_rc "version --release -> exit 0" 0
VER_RELEASE_RELEASED=$(jq -r '.released' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "version --release: body released:true" "$VER_RELEASE_RELEASED" "true"
VER_RELEASE_DATE=$(jq -r '.releaseDate' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "version --release: releaseDate included when given" "$VER_RELEASE_DATE" "2026-07-06"

reset_curl_stub
set_stub_response 1 '{"id":"11751","released":true}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --release --id 11751 --confirmed-site foo.atlassian.net
expect_rc "version --release (no date) -> exit 0" 0
VER_RELEASE_NODATE_KEYS=$(jq -cS 'keys' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "version --release without --release-date: body is exactly {released:true}" "$VER_RELEASE_NODATE_KEYS" '["released"]'

reset_curl_stub
set_stub_response 1 '{"id":"11751","archived":true}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --archive --id 11751 --confirmed-site foo.atlassian.net
expect_rc "version --archive -> exit 0" 0
VER_ARCHIVE_KEYS=$(jq -cS 'keys' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "version --archive: body is exactly {archived:true}" "$VER_ARCHIVE_KEYS" '["archived"]'
VER_ARCHIVE_VAL=$(jq -r '.archived' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "version --archive: archived is a JSON boolean true" "$VER_ARCHIVE_VAL" "true"

section "jira.sh — version: mode-flag + argument validation"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --project PSWS --confirmed-site foo.atlassian.net
expect_rc "version with ZERO mode flags -> exit 2" 2
stderr_has "version zero modes: diagnostic" "exactly one mode"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --list --create --project PSWS --name X --confirmed-site foo.atlassian.net
expect_rc "version with TWO mode flags -> exit 2" 2
stderr_has "version two modes: diagnostic" "exactly one mode"

# A component-only mode flag (--delete) passed to `version` must be rejected by
# name, not silently ignored while the one own mode (--list) runs.
run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --list --delete --project PSWS --confirmed-site foo.atlassian.net
expect_rc "version --list + foreign --delete -> exit 2" 2
stderr_has "version foreign --delete: diagnostic names it not a version mode" "not a version mode"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --list --confirmed-site foo.atlassian.net
expect_rc "version --list without --project -> exit 2" 2
stderr_has "version --list no project: diagnostic" "requires --project"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --create --project PSWS --confirmed-site foo.atlassian.net
expect_rc "version --create without --name -> exit 2" 2
stderr_has "version --create no name: diagnostic" "requires --name"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --update --id abc --name X --confirmed-site foo.atlassian.net
expect_rc "version --update with a NON-NUMERIC --id -> exit 2" 2
stderr_has "version non-numeric id: diagnostic" "numeric version id"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --update --id 11751 --confirmed-site foo.atlassian.net
expect_rc "version --update with no field to change -> exit 2" 2
stderr_has "version --update no field: diagnostic" "at least one field"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --list PROJ-1 --project PSWS --confirmed-site foo.atlassian.net
expect_rc "version with a stray positional -> exit 2" 2
stderr_has "version stray positional: diagnostic" "takes no positional argument"

# ===========================================================================
# component — project components (Phase-2d). GET /project/<K>/components is a
# PLAIN JSON ARRAY (empty [] is valid); DELETE returns 204 No Content.
# ===========================================================================
section "jira.sh — component --list: parses the PLAIN ARRAY (incl. empty [])"

reset_curl_stub
set_stub_response 1 '[{"self":"https://foo.atlassian.net/rest/api/3/component/10500","id":"10500","name":"Auth","description":"authentication","assigneeType":"PROJECT_DEFAULT"},{"id":"10501","name":"API"}]' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" component --list --project PSWS --confirmed-site foo.atlassian.net
expect_rc "component --list -> exit 0" 0
file_has "component --list: GET /rest/api/3/project/PSWS/components" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/project/PSWS/components"
stdout_has "component --list: name rendered" "Auth"
stdout_has "component --list: string id rendered" "id 10500"

reset_curl_stub
set_stub_response 1 '[]' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" component --list --project PSWS --confirmed-site foo.atlassian.net --json
expect_rc "component --list empty --json -> exit 0" 0
equals "component --list empty --json: raw [] passes through" "$CUR_OUT" "[]"

reset_curl_stub
set_stub_response 1 '[]' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" component --list --project PSWS --confirmed-site foo.atlassian.net
expect_rc "component --list empty (human) -> exit 0" 0
stdout_has "component --list empty: 'No components.'" "No components."

section "jira.sh — component --create: body project is the KEY string"

reset_curl_stub
set_stub_response 1 '{"id":"10600","name":"Billing","description":"billing"}' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" component --create --project PSWS --name Billing --description "billing area" \
		--lead-account-id acc-lead-123 --confirmed-site foo.atlassian.net
expect_rc "component --create -> exit 0" 0
file_has "component --create: POST /rest/api/3/component" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/component"
COMP_CREATE_PROJECT=$(jq -r '.project' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "component --create: body 'project' is the KEY string" "$COMP_CREATE_PROJECT" "PSWS"
COMP_CREATE_NAME=$(jq -r '.name' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "component --create: body name" "$COMP_CREATE_NAME" "Billing"
COMP_CREATE_LEAD=$(jq -r '.leadAccountId' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "component --create: leadAccountId carried" "$COMP_CREATE_LEAD" "acc-lead-123"
stdout_has "component --create: machine line names the new id" "JIRA_COMPONENT_ID=10600"

section "jira.sh — component --update: PUT /component/<id> with a partial body"

reset_curl_stub
set_stub_response 1 '{"id":"10500","name":"Auth v2"}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" component --update --id 10500 --name "Auth v2" --confirmed-site foo.atlassian.net
expect_rc "component --update -> exit 0" 0
file_has "component --update: PUT /rest/api/3/component/10500" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/component/10500"
file_has "component --update: uses PUT" "$CURL_STUB_ARGV_LOG" "PUT"
COMP_UPDATE_KEYS=$(jq -cS 'keys' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "component --update: body carries ONLY the changed field" "$COMP_UPDATE_KEYS" '["name"]'

section "jira.sh — component --delete: DELETE /component/<id>, optional ?moveIssuesTo="

reset_curl_stub
set_stub_response 1 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" component --delete --id 10500 --confirmed-site foo.atlassian.net
expect_rc "component --delete -> exit 0" 0
file_has "component --delete: DELETE /rest/api/3/component/10500" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/component/10500"
file_has "component --delete: uses DELETE" "$CURL_STUB_ARGV_LOG" "DELETE"
file_not_has "component --delete: NO ?moveIssuesTo= when not given" "$CURL_STUB_ARGV_LOG" "moveIssuesTo"
stdout_has "component --delete: machine line" "JIRA_COMPONENT_DELETED=10500"

reset_curl_stub
set_stub_response 1 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" component --delete --id 10500 --move-issues-to 10501 --confirmed-site foo.atlassian.net
expect_rc "component --delete --move-issues-to -> exit 0" 0
file_has "component --delete: URL carries ?moveIssuesTo=10501" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/component/10500?moveIssuesTo=10501"

reset_curl_stub
set_stub_response 1 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" component --delete --id 10500 --confirmed-site foo.atlassian.net --json
expect_rc "component --delete --json -> exit 0" 0
COMP_DELETE_JSON=$(printf '%s' "$CUR_OUT" | jq -r '.deleted')
equals "component --delete --json: SYNTHESIZED {deleted:true} (no 204 body to pass through)" "$COMP_DELETE_JSON" "true"

section "jira.sh — component: mode-flag + argument validation"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" component --project PSWS --confirmed-site foo.atlassian.net
expect_rc "component with ZERO mode flags -> exit 2" 2
stderr_has "component zero modes: diagnostic" "exactly one mode"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" component --list --delete --id 10500 --project PSWS --confirmed-site foo.atlassian.net
expect_rc "component with TWO mode flags -> exit 2" 2
stderr_has "component two modes: diagnostic" "exactly one mode"

# A version-only mode flag (--release) passed to `component` must be rejected by
# name, not silently ignored while the one own mode (--list) runs.
run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" component --list --release --project PSWS --confirmed-site foo.atlassian.net
expect_rc "component --list + foreign --release -> exit 2" 2
stderr_has "component foreign --release: diagnostic names it not a component mode" "not component modes"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" component --update --id 10500 --name X --move-issues-to 10501 --confirmed-site foo.atlassian.net
expect_rc "component --move-issues-to WITHOUT --delete -> exit 2" 2
stderr_has "component move-issues-to misuse: diagnostic" "only valid with component --delete"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" component --delete --id abc --confirmed-site foo.atlassian.net
expect_rc "component --delete NON-NUMERIC --id -> exit 2" 2
stderr_has "component non-numeric id: diagnostic" "numeric component id"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" component --create --name X --confirmed-site foo.atlassian.net
expect_rc "component --create without --project -> exit 2" 2
stderr_has "component --create no project: diagnostic" "requires --project"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" component --create --project PSWS --confirmed-site foo.atlassian.net
expect_rc "component --create without --name -> exit 2" 2
stderr_has "component --create no name: diagnostic" "requires --name"

# ===========================================================================
# version / component — HTTP error paths surface Jira's own diagnostic
# ===========================================================================
section "jira.sh — version --create: a non-2xx surfaces the HTTP code + Jira's own error message"

reset_curl_stub
set_stub_response 1 '{"errorMessages":["A version with this name already exists in this project"]}' 400
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --create --project PSWS --name dup --confirmed-site foo.atlassian.net
expect_rc "version --create 400 -> exit 1" 1
stderr_has "version --create 400: HTTP code in diagnostic" "HTTP 400"
stderr_has "version --create 400: Jira's own error message surfaced" "already exists in this project"

section "jira.sh — component --delete: a non-2xx surfaces the HTTP code + Jira's own error message"

reset_curl_stub
set_stub_response 1 '{"errorMessages":["The component with id 10500 does not exist"]}' 404
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" component --delete --id 10500 --confirmed-site foo.atlassian.net
expect_rc "component --delete 404 -> exit 1" 1
stderr_has "component --delete 404: HTTP code in diagnostic" "HTTP 404"
stderr_has "component --delete 404: Jira's own error message surfaced" "does not exist"

# ===========================================================================
# version / component — --json passthrough round-trips the response body on the
# mutate (create/update) paths, not just the read paths
# ===========================================================================
section "jira.sh — version --create/--update --json: the response body round-trips"

reset_curl_stub
set_stub_response 1 '{"id":"12345","name":"9.9","released":false}' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --create --project PSWS --name 9.9 --confirmed-site foo.atlassian.net --json
expect_rc "version --create --json -> exit 0" 0
VER_CREATE_JSON_ID=$(printf '%s' "$CUR_OUT" | jq -r '.id')
equals "version --create --json: passes the 201 body through (id round-trips)" "$VER_CREATE_JSON_ID" "12345"

reset_curl_stub
set_stub_response 1 '{"id":"11751","name":"3.10.9","released":false}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --update --id 11751 --name 3.10.9 --confirmed-site foo.atlassian.net --json
expect_rc "version --update --json -> exit 0" 0
VER_UPDATE_JSON_ID=$(printf '%s' "$CUR_OUT" | jq -r '.id')
equals "version --update --json: passes the 200 body through (id round-trips)" "$VER_UPDATE_JSON_ID" "11751"

section "jira.sh — component --create/--update --json: the response body round-trips"

reset_curl_stub
set_stub_response 1 '{"id":"10600","name":"Billing"}' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" component --create --project PSWS --name Billing --confirmed-site foo.atlassian.net --json
expect_rc "component --create --json -> exit 0" 0
COMP_CREATE_JSON_ID=$(printf '%s' "$CUR_OUT" | jq -r '.id')
equals "component --create --json: passes the 201 body through (id round-trips)" "$COMP_CREATE_JSON_ID" "10600"

reset_curl_stub
set_stub_response 1 '{"id":"10500","name":"Auth v3"}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" component --update --id 10500 --name "Auth v3" --confirmed-site foo.atlassian.net --json
expect_rc "component --update --json -> exit 0" 0
COMP_UPDATE_JSON_ID=$(printf '%s' "$CUR_OUT" | jq -r '.id')
equals "component --update --json: passes the 200 body through (id round-trips)" "$COMP_UPDATE_JSON_ID" "10500"

# ===========================================================================
# version / component — multi-field --update sends exactly the changed keys
# ===========================================================================
section "jira.sh — version --update: a multi-field body carries EXACTLY the changed keys"

reset_curl_stub
set_stub_response 1 '{"id":"11751","name":"3.10.2"}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --update --id 11751 --name 3.10.2 --description "point release" \
		--release-date 2026-08-01 --confirmed-site foo.atlassian.net
expect_rc "version --update multi-field -> exit 0" 0
VER_UPD_MULTI_KEYS=$(jq -cS 'keys' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "version --update multi: body keys are exactly description/name/releaseDate" \
	"$VER_UPD_MULTI_KEYS" '["description","name","releaseDate"]'
VER_UPD_MULTI_DESC=$(jq -r '.description' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "version --update multi: description value" "$VER_UPD_MULTI_DESC" "point release"
VER_UPD_MULTI_RELDATE=$(jq -r '.releaseDate' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "version --update multi: releaseDate value" "$VER_UPD_MULTI_RELDATE" "2026-08-01"

section "jira.sh — component --update: a multi-field body carries EXACTLY the changed keys"

reset_curl_stub
set_stub_response 1 '{"id":"10500","name":"Auth v4"}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" component --update --id 10500 --name "Auth v4" --description "auth area" \
		--lead-account-id acc-lead-9 --confirmed-site foo.atlassian.net
expect_rc "component --update multi-field -> exit 0" 0
COMP_UPD_MULTI_KEYS=$(jq -cS 'keys' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "component --update multi: body keys are exactly description/leadAccountId/name" \
	"$COMP_UPD_MULTI_KEYS" '["description","leadAccountId","name"]'
COMP_UPD_MULTI_LEAD=$(jq -r '.leadAccountId' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "component --update multi: leadAccountId value" "$COMP_UPD_MULTI_LEAD" "acc-lead-9"

# ===========================================================================
# attach flags — create/update --fix-version / --affects-version / --component
# resolve NAME -> id against ONE list-GET per data axis (versions once,
# components once) and merge fixVersions/versions/components:[{id}].
# ===========================================================================
section "jira.sh — create --fix-version: resolves NAME -> id, ONE versions GET, builds fixVersions:[{id}]"

reset_curl_stub
set_stub_response 1 '[{"id":"11751","name":"3.10.0","released":false},{"id":"11752","name":"3.11.0","released":true}]' 200
set_stub_response 2 '{"key":"PSWS-1","id":"1"}' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" create --project PSWS --title "T" --fix-version 3.11.0 --confirmed-site foo.atlassian.net
expect_rc "create --fix-version -> exit 0" 0
file_has "create --fix-version: fetches GET /project/PSWS/versions" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/project/PSWS/versions"
equals "create --fix-version: exactly TWO calls (one versions GET + the create POST)" "$(call_count)" "2"
CREATE_FIXV=$(jq -c '.fields.fixVersions' "$CURL_STUB_BODY_LOG_DIR/call-2.body")
equals "create --fix-version: body fixVersions:[{id}] with the RESOLVED id (name 3.11.0 -> 11752)" "$CREATE_FIXV" '[{"id":"11752"}]'

section "jira.sh — create: all three attach axes share ONE versions GET + ONE components GET (versions NOT refetched for affects)"

reset_curl_stub
set_stub_response 1 '[{"id":"11751","name":"3.10.0"},{"id":"11752","name":"3.11.0"}]' 200
set_stub_response 2 '[{"id":"10500","name":"Auth"},{"id":"10501","name":"API"}]' 200
set_stub_response 3 '{"key":"PSWS-2","id":"2"}' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" create --project PSWS --title "T" --fix-version 3.10.0 --affects-version 3.11.0 \
		--component Auth --confirmed-site foo.atlassian.net
expect_rc "create with all three attach axes -> exit 0" 0
equals "create attach: exactly THREE calls (versions once + components once + POST) — versions NOT refetched for affects" "$(call_count)" "3"
CREATE_ALL_FIXV=$(jq -c '.fields.fixVersions' "$CURL_STUB_BODY_LOG_DIR/call-3.body")
equals "create attach: --fix-version -> fixVersions:[{id}]" "$CREATE_ALL_FIXV" '[{"id":"11751"}]'
CREATE_ALL_AFFV=$(jq -c '.fields.versions' "$CURL_STUB_BODY_LOG_DIR/call-3.body")
equals "create attach: --affects-version -> versions:[{id}]" "$CREATE_ALL_AFFV" '[{"id":"11752"}]'
CREATE_ALL_COMP=$(jq -c '.fields.components' "$CURL_STUB_BODY_LOG_DIR/call-3.body")
equals "create attach: --component -> components:[{id}]" "$CREATE_ALL_COMP" '[{"id":"10500"}]'

section "jira.sh — create: repeatable --component (line-per-value accumulation, names may contain spaces)"

reset_curl_stub
set_stub_response 1 '[{"id":"10500","name":"Auth Service"},{"id":"10501","name":"API"}]' 200
set_stub_response 2 '{"key":"PSWS-3","id":"3"}' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" create --project PSWS --title "T" --component "Auth Service" --component API --confirmed-site foo.atlassian.net
expect_rc "create with two --component (one with a space) -> exit 0" 0
CREATE_MULTI_COMP=$(jq -c '.fields.components' "$CURL_STUB_BODY_LOG_DIR/call-2.body")
equals "create: repeated --component builds a 2-element id array; the spaced name resolved" "$CREATE_MULTI_COMP" '[{"id":"10500"},{"id":"10501"}]'

section "jira.sh — create --fix-version: a NAME containing a space resolves correctly (line-per-value accumulation, never space-split)"

reset_curl_stub
set_stub_response 1 '[{"id":"11760","name":"Sprint 42 Release"},{"id":"11761","name":"3.11.0"}]' 200
set_stub_response 2 '{"key":"PSWS-8","id":"8"}' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" create --project PSWS --title "T" --fix-version "Sprint 42 Release" --confirmed-site foo.atlassian.net
expect_rc "create --fix-version spaced name -> exit 0" 0
CREATE_SPACED_FIXV=$(jq -c '.fields.fixVersions' "$CURL_STUB_BODY_LOG_DIR/call-2.body")
equals "create --fix-version spaced: resolves the spaced name to its id (not space-split into two lookups)" "$CREATE_SPACED_FIXV" '[{"id":"11760"}]'

section "jira.sh — create --affects-version: a NAME containing a space resolves correctly"

reset_curl_stub
set_stub_response 1 '[{"id":"11770","name":"Hotfix 1 0"},{"id":"11771","name":"3.12.0"}]' 200
set_stub_response 2 '{"key":"PSWS-10","id":"10"}' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" create --project PSWS --title "T" --affects-version "Hotfix 1 0" --confirmed-site foo.atlassian.net
expect_rc "create --affects-version spaced name -> exit 0" 0
CREATE_SPACED_AFFV=$(jq -c '.fields.versions' "$CURL_STUB_BODY_LOG_DIR/call-2.body")
equals "create --affects-version spaced: resolves the spaced name to its id" "$CREATE_SPACED_AFFV" '[{"id":"11770"}]'

section "jira.sh — create attach: an unknown NAME fails loud (exit 1, no create POST)"

reset_curl_stub
set_stub_response 1 '[{"id":"11751","name":"3.10.0"}]' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" create --project PSWS --title "T" --fix-version 9.9.9 --confirmed-site foo.atlassian.net
expect_rc "create --fix-version not found -> exit 1" 1
stderr_has "create attach not-found: names the missing name + project" "fix version '9.9.9' not found in project PSWS"
equals "create attach not-found: NO create POST issued (only the versions GET fired)" "$(call_count)" "1"

section "jira.sh — create attach: a DUPLICATE display name fails loud as ambiguous (exit 1, no create POST)"

reset_curl_stub
set_stub_response 1 '[{"id":"10500","name":"Auth"},{"id":"10501","name":"Auth"}]' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" create --project PSWS --title "T" --component Auth --confirmed-site foo.atlassian.net
expect_rc "create --component ambiguous -> exit 1" 1
stderr_has "create attach ambiguous: fails loud" "ambiguous"
equals "create attach ambiguous: no create POST issued" "$(call_count)" "1"

section "jira.sh — update: attach flags resolve against the TICKET's project; a lone attach flag is a valid change"

reset_curl_stub
set_stub_response 1 '[{"id":"11752","name":"3.11.0"}]' 200
set_stub_response 2 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" update PSWS-5 --fix-version 3.11.0 --confirmed-site foo.atlassian.net
expect_rc "update with ONLY --fix-version -> exit 0 (attach counts as a field to change)" 0
file_has "update --fix-version: fetches versions for the ticket's project (PSWS from PSWS-5)" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/project/PSWS/versions"
UPDATE_FIXV=$(jq -c '.fields.fixVersions' "$CURL_STUB_BODY_LOG_DIR/call-2.body")
equals "update --fix-version: PUT body carries fixVersions:[{id}]" "$UPDATE_FIXV" '[{"id":"11752"}]'

section "jira.sh — update attach: an unknown component NAME fails loud (exit 1, no update PUT)"

reset_curl_stub
set_stub_response 1 '[{"id":"10500","name":"Auth"}]' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" update PSWS-6 --component Nonexistent --confirmed-site foo.atlassian.net
expect_rc "update --component not found -> exit 1" 1
stderr_has "update attach not-found: names the missing component + project" "component 'Nonexistent' not found in project PSWS"
equals "update attach not-found: NO update PUT issued (only the components GET fired)" "$(call_count)" "1"

# ===========================================================================
# attach — issue attachment upload / list / delete (Cycle A)
# Fixtures use the REAL live shapes: upload -> a JSON ARRAY (one obj per file),
# id is a STRING, `thumbnail` present ONLY for images; list -> .fields.attachment
# is a plain ARRAY (may be []); delete -> 204 No Content.
# ===========================================================================
# Real attachment objects (probed live). ATTACH_OBJ_PNG carries a thumbnail
# (image); ATTACH_OBJ_TXT does NOT (non-image) — matches live behavior.
ATTACH_OBJ_PNG='{"self":"https://foo.atlassian.net/rest/api/3/attachment/303980","id":"303980","filename":"diagram.png","author":{"accountId":"acc-1","displayName":"A. Gent"},"created":"2026-07-25T17:06:06.495+0200","size":43,"mimeType":"image/png","content":"https://foo.atlassian.net/rest/api/3/attachment/content/303980","thumbnail":"https://foo.atlassian.net/rest/api/3/attachment/thumbnail/303980"}'
ATTACH_OBJ_TXT='{"self":"https://foo.atlassian.net/rest/api/3/attachment/303981","id":"303981","filename":"notes.txt","author":{"accountId":"acc-1","displayName":"A. Gent"},"created":"2026-07-25T17:06:07.100+0200","size":128,"mimeType":"text/plain","content":"https://foo.atlassian.net/rest/api/3/attachment/content/303981"}'

section "jira.sh — attach upload: single file -> POST /issue/<KEY>/attachments, multipart, no JSON content-type"

reset_curl_stub
ATTACH_UP1="$WORK/upload-one.txt"
printf 'hello' >"$ATTACH_UP1"
set_stub_response 1 "[$ATTACH_OBJ_PNG]" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach PSWS-1 --file "$ATTACH_UP1" --confirmed-site foo.atlassian.net
expect_rc "attach upload single -> exit 0" 0
file_has "attach upload: POST goes to /issue/PSWS-1/attachments" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/issue/PSWS-1/attachments"
argv_log_has_token "attach upload: request method is POST" "POST"
argv_log_has_token "attach upload: carries X-Atlassian-Token: no-check" "X-Atlassian-Token: no-check"
argv_log_has_token "attach upload: one -F file part for the file" "file=@\"$ATTACH_UP1\""
argv_log_not_has_token "attach upload: NO JSON content-type header" "Content-Type: application/json"
equals "attach upload single: exactly ONE curl call" "$(call_count)" "1"
stdout_has "attach upload: machine line names the parsed STRING id from the array" "JIRA_ATTACHMENT_ID=303980"
stdout_has "attach upload: machine line names the filename" "JIRA_ATTACHMENT_FILENAME=diagram.png"

section "jira.sh — attach upload: multiple --file -> one -F part each, one POST, one machine line pair per file"

reset_curl_stub
ATTACH_UP_A="$WORK/multi-a.txt"
ATTACH_UP_B="$WORK/multi-b.png"
printf 'a' >"$ATTACH_UP_A"
printf 'b' >"$ATTACH_UP_B"
set_stub_response 1 "[$ATTACH_OBJ_PNG,$ATTACH_OBJ_TXT]" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach PSWS-1 --file "$ATTACH_UP_A" --file "$ATTACH_UP_B" --confirmed-site foo.atlassian.net
expect_rc "attach upload multi -> exit 0" 0
argv_log_has_token "attach upload multi: -F part for file A" "file=@\"$ATTACH_UP_A\""
argv_log_has_token "attach upload multi: -F part for file B" "file=@\"$ATTACH_UP_B\""
equals "attach upload multi: still exactly ONE curl call (all files in one request)" "$(call_count)" "1"
stdout_has "attach upload multi: id from array element 1" "JIRA_ATTACHMENT_ID=303980"
stdout_has "attach upload multi: id from array element 2" "JIRA_ATTACHMENT_ID=303981"

section "jira.sh — attach upload: a path containing ';'/',' is DOUBLE-QUOTED so curl can't split it into a form parameter"

reset_curl_stub
# A filename crafted to look like a curl -F parameter-injection: an unquoted
# `-F file=@/tmp/a;type=texthtml` would make curl set the part's mime, and a
# ',' would start a whole new form part. The path must be wrapped in double-
# quotes to neutralize BOTH the ';' and the ',' (no '/' here — that would be a
# real path separator, not part of the filename we are testing).
ATTACH_EVIL="$WORK/evil;type=texthtml,x.png"
printf 'x' >"$ATTACH_EVIL"
set_stub_response 1 "[$ATTACH_OBJ_PNG]" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach PSWS-1 --file "$ATTACH_EVIL" --confirmed-site foo.atlassian.net
expect_rc "attach upload with ';'/','-laden path -> exit 0" 0
argv_log_has_token "attach filename-safety: the -F value keeps the whole path DOUBLE-QUOTED as the filename" "file=@\"$ATTACH_EVIL\""
argv_log_not_has_token "attach filename-safety: the UNQUOTED (injectable) form is NOT what was built" "file=@$ATTACH_EVIL"

reset_curl_stub
# A path carrying a literal '"' (and a ',') is the sharper attack: the '"'
# is special INSIDE curl's OWN double-quoted -F value, so mere wrapping is not
# enough — an unescaped '"' would close the quotes early and the trailing ','
# would then start a second @-file part / mime override. The value must be
# ESCAPED (backslash first, then the quote) before wrapping. The expected token
# is derived with the SAME escaping the script applies, so this asserts the
# escaped+quoted form is what was built — and that the raw unescaped breakout
# form (which contains a bare '"' before the ',') was NOT.
ATTACH_QUOTE="$WORK/q\",x.png"
printf 'x' >"$ATTACH_QUOTE"
ATTACH_QUOTE_ESC=$(printf '%s' "$ATTACH_QUOTE" | sed 's/\\/\\\\/g; s/"/\\"/g')
set_stub_response 1 "[$ATTACH_OBJ_PNG]" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach PSWS-1 --file "$ATTACH_QUOTE" --confirmed-site foo.atlassian.net
expect_rc "attach upload with a '\"'/','-laden path -> exit 0" 0
argv_log_has_token "attach filename-safety: the '\"' is ESCAPED then quoted in the -F value" "file=@\"$ATTACH_QUOTE_ESC\""
argv_log_not_has_token "attach filename-safety: the raw (breakout) '\"' form with a bare quote was NOT built" "file=@\"$ATTACH_QUOTE\""

section "jira.sh — attach upload --json: raw array passes through, NO machine line"

reset_curl_stub
ATTACH_UP_JSON="$WORK/upload-json.txt"
printf 'j' >"$ATTACH_UP_JSON"
set_stub_response 1 "[$ATTACH_OBJ_PNG]" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach PSWS-1 --file "$ATTACH_UP_JSON" --confirmed-site foo.atlassian.net --json
expect_rc "attach upload --json -> exit 0" 0
stdout_has "attach upload --json: raw array body passes through (the array element)" '"id":"303980"'
stdout_not_has "attach upload --json: NO machine line emitted (passthrough only)" "JIRA_ATTACHMENT_ID"

section "jira.sh — attach upload: a transport error (413) surfaces Jira's message + the HTTP code, exit 1"

reset_curl_stub
ATTACH_UP_413="$WORK/upload-413.txt"
printf 'big' >"$ATTACH_UP_413"
set_stub_response 1 '{"errorMessages":["The attachment exceeds the maximum size."]}' 413
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach PSWS-1 --file "$ATTACH_UP_413" --confirmed-site foo.atlassian.net
expect_rc "attach upload 413 -> exit 1 (handle_http_status wired through jira_curl_multipart)" 1
stderr_has "attach upload 413: surfaces Jira's own error message" "The attachment exceeds the maximum size."
stderr_has "attach upload 413: names the HTTP code" "HTTP 413"

section "jira.sh — attach --list: parses .fields.attachment ARRAY (incl. empty [])"

reset_curl_stub
set_stub_response 1 "{\"fields\":{\"attachment\":[$ATTACH_OBJ_PNG,$ATTACH_OBJ_TXT]}}" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach PSWS-2 --list --confirmed-site foo.atlassian.net
expect_rc "attach --list -> exit 0" 0
file_has "attach --list: GET /issue/PSWS-2?fields=attachment" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/issue/PSWS-2?fields=attachment"
stdout_has "attach --list: string id rendered" "303980"
stdout_has "attach --list: filename rendered" "diagram.png"
stdout_has "attach --list: mimeType rendered" "text/plain"

reset_curl_stub
set_stub_response 1 "{\"fields\":{\"attachment\":[$ATTACH_OBJ_PNG]}}" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach PSWS-2 --list --confirmed-site foo.atlassian.net --json
expect_rc "attach --list --json -> exit 0" 0
stdout_has "attach --list --json: raw body passes through (the array element)" '"id":"303980"'

reset_curl_stub
set_stub_response 1 '{"fields":{"attachment":[]}}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach PSWS-2 --list --confirmed-site foo.atlassian.net
expect_rc "attach --list empty -> exit 0" 0
stdout_has "attach --list empty: 'No attachments.'" "No attachments."

section "jira.sh — attach --delete: DELETE /attachment/<id>, 204 -> machine line; --json synthesized"

reset_curl_stub
set_stub_response 1 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach --delete --id 303980 --confirmed-site foo.atlassian.net
expect_rc "attach --delete -> exit 0" 0
file_has "attach --delete: DELETE /rest/api/3/attachment/303980" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/attachment/303980"
stdout_has "attach --delete: machine line" "JIRA_ATTACHMENT_DELETED=303980"

reset_curl_stub
set_stub_response 1 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach --delete --id 303980 --confirmed-site foo.atlassian.net --json
expect_rc "attach --delete --json -> exit 0" 0
ATTACH_DELETE_JSON=$(printf '%s' "$CUR_OUT" | jq -r '.deleted')
equals "attach --delete --json: SYNTHESIZED {deleted:true} (no 204 body to pass through)" "$ATTACH_DELETE_JSON" "true"
ATTACH_DELETE_ID=$(printf '%s' "$CUR_OUT" | jq -r '.id')
equals "attach --delete --json: SYNTHESIZED id echoes the deleted --id" "$ATTACH_DELETE_ID" "303980"

section "jira.sh — attach: mode-flag + argument validation (all before any network call)"

reset_curl_stub
run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach PSWS-1 --file "$WORK/does-not-exist.txt" --confirmed-site foo.atlassian.net
expect_rc "attach upload with an unreadable --file -> exit 2" 2
stderr_has "attach unreadable --file: diagnostic names the flag" "--file does not exist or is not readable"

reset_curl_stub
run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach --delete --id not-a-number --confirmed-site foo.atlassian.net
expect_rc "attach --delete with a NON-NUMERIC --id -> exit 2" 2

reset_curl_stub
run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach PSWS-1 --confirmed-site foo.atlassian.net
expect_rc "attach with ZERO modes (no --file/--list/--delete) -> exit 2" 2

reset_curl_stub
ATTACH_TWO="$WORK/two-mode.txt"
printf 'x' >"$ATTACH_TWO"
run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach PSWS-1 --file "$ATTACH_TWO" --list --confirmed-site foo.atlassian.net
expect_rc "attach with TWO modes (--file + --list) -> exit 2" 2

# A foreign version/component mode flag on attach is rejected by name AND folded
# into the exactly-one count, so it can never slip past unnoticed.
ATTACH_FOREIGN="$WORK/foreign-mode.txt"
printf 'x' >"$ATTACH_FOREIGN"
for foreign_mode in --create --update --release --archive; do
	reset_curl_stub
	run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
		sh "$JIRA" attach PSWS-1 --file "$ATTACH_FOREIGN" "$foreign_mode" --confirmed-site foo.atlassian.net
	expect_rc "attach upload + foreign mode $foreign_mode -> exit 2" 2
	stderr_has "attach foreign-mode $foreign_mode: diagnostic names it as not an attach mode" "are not attach modes"
done

reset_curl_stub
run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach PSWS-1 --list --id 303980 --confirmed-site foo.atlassian.net
expect_rc "attach --id outside of --delete -> exit 2" 2
stderr_has "attach --id-outside-delete: diagnostic" "--id is only valid with attach --delete"

reset_curl_stub
run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach PSWS-1 --delete --id 303980 --confirmed-site foo.atlassian.net
expect_rc "attach --delete WITH a stray ticket key -> exit 2 (delete addresses by --id, not KEY)" 2

# ===========================================================================
# Cycle B — inline images in description/comment bodies.
#
# The mechanism (probed live): upload the local image (Cycle A multipart) ->
# GET /attachment/content/<id> returns a 303 whose Location is
# https://api.media.atlassian.com/file/<UUID>/binary?token=<JWT> -> extract
# ONLY the UUID (never the JWT) -> md-to-adf.sh emits a mediaSingle block
# referencing that UUID (collection:"").
#
# The stub returns a REAL 303 + Location header (via -D) for the content GET,
# a REAL array upload body, and REAL 201/204 for the write. The Location's
# token is a distinctive sentinel so we can prove it never leaks to output.
# ===========================================================================
MEDIA_UUID="12345678-90ab-cdef-1234-567890abcdef"   # 36 chars, [a-f0-9-]
MEDIA_JWT="SECRETJWTTOKEN0xDEADBEEF"                # sentinel: must NEVER leak
MEDIA_LOCATION="Location: https://api.media.atlassian.com/file/$MEDIA_UUID/binary?token=$MEDIA_JWT&client=abc"
MEDIA_303_HEADERS="HTTP/2 303
$MEDIA_LOCATION
content-length: 0"

section "jira.sh — comment with an inline image: upload -> 303 media-UUID resolve -> mediaSingle in the comment body"

reset_curl_stub
INLINE_IMG1="$WORK/inline-diagram.png"
printf 'PNGDATA' >"$INLINE_IMG1"
COMMENT_IMG_MD="$WORK/comment-with-image.md"
printf 'Look at this.\n\n![a diagram](%s)\n\nThanks.\n' "$INLINE_IMG1" >"$COMMENT_IMG_MD"
# call 1: attachment upload (array body, id 303980)
set_stub_response 1 "[$ATTACH_OBJ_PNG]" 200
# call 2: /attachment/content/303980 -> 303 + Location (media UUID + JWT)
set_stub_response 2 '' 303
set_stub_headers 2 "$MEDIA_303_HEADERS"
# call 3: the comment POST
set_stub_response 3 '{"id":"10001"}' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" comment PSWS-1 --text-file "$COMMENT_IMG_MD" --confirmed-site foo.atlassian.net
expect_rc "comment inline image -> exit 0" 0
equals "comment inline image: exactly THREE calls (upload + content-resolve + comment POST)" "$(call_count)" "3"
file_has "comment inline image: call 1 uploads to /issue/PSWS-1/attachments" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/issue/PSWS-1/attachments"
file_has "comment inline image: call 2 GETs /attachment/content/303980" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/attachment/content/303980"
argv_log_has_token "comment inline image: the resolver dumps headers (-D)" "-D"
argv_log_not_has_token "comment inline image: the resolver NEVER follows the redirect (-L absent)" "-L"
COMMENT_MEDIA_ID=$(jq -r '[.body.content[] | select(.type=="mediaSingle")][0].content[0].attrs.id' "$CURL_STUB_BODY_LOG_DIR/call-3.body")
equals "comment inline image: the comment body carries a mediaSingle referencing the resolved UUID" "$COMMENT_MEDIA_ID" "$MEDIA_UUID"
COMMENT_MEDIA_COLLECTION=$(jq -r '[.body.content[] | select(.type=="mediaSingle")][0].content[0].attrs.collection' "$CURL_STUB_BODY_LOG_DIR/call-3.body")
equals "comment inline image: media node collection is the EMPTY STRING (verified: null -> 400)" "$COMMENT_MEDIA_COLLECTION" ""
stdout_has "comment inline image: still emits the comment id machine line" "JIRA_COMMENT_ID=10001"
# SECURITY — the token-bearing Location must never reach any output channel.
stdout_not_has "comment inline image: the JWT never appears on stdout" "$MEDIA_JWT"
file_not_has "comment inline image: the JWT never appears in the argv log (off-argv, -K config only)" "$CURL_STUB_ARGV_LOG" "$MEDIA_JWT"
TESTS_RUN=$((TESTS_RUN + 1))
if printf '%s' "$CUR_ERR" | grep -Fq -- "$MEDIA_JWT"; then
	fail "comment inline image: the JWT never appears on stderr" "stderr leaked the JWT"
else
	pass "comment inline image: the JWT never appears on stderr"
fi
TESTS_RUN=$((TESTS_RUN + 1))
if printf '%s' "$CUR_OUT$CUR_ERR" | grep -Fq -- "api.media.atlassian.com"; then
	fail "comment inline image: the raw media Location host never appears in output" "output leaked the Location host"
else
	pass "comment inline image: the raw media Location host never appears in output"
fi

section "jira.sh — comment with NO inline images: unchanged single-call behavior (no upload, no resolve)"

reset_curl_stub
COMMENT_PLAIN_MD="$WORK/comment-plain.md"
printf 'Just a plain comment, no images.\n' >"$COMMENT_PLAIN_MD"
set_stub_response 1 '{"id":"10002"}' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" comment PSWS-1 --text-file "$COMMENT_PLAIN_MD" --confirmed-site foo.atlassian.net
expect_rc "comment no images -> exit 0" 0
equals "comment no images: exactly ONE call (the comment POST — no upload, no resolve)" "$(call_count)" "1"
stdout_has "comment no images: comment id machine line" "JIRA_COMMENT_ID=10002"

section "jira.sh — comment inline image: an http(s) image is NOT uploaded (external URL, not a local file)"

reset_curl_stub
COMMENT_HTTP_MD="$WORK/comment-http-image.md"
printf 'Remote image:\n\n![x](https://example.com/x.png)\n' >"$COMMENT_HTTP_MD"
set_stub_response 1 '{"id":"10003"}' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" comment PSWS-1 --text-file "$COMMENT_HTTP_MD" --confirmed-site foo.atlassian.net
expect_rc "comment http image -> exit 0" 0
equals "comment http image: exactly ONE call (an http(s) image is never uploaded)" "$(call_count)" "1"

section "jira.sh — comment inline image: a duplicate path is uploaded ONCE (dedup against the map)"

reset_curl_stub
INLINE_DUP="$WORK/dup.png"
printf 'DUP' >"$INLINE_DUP"
COMMENT_DUP_MD="$WORK/comment-dup.md"
printf '![one](%s)\n\nmiddle\n\n![two](%s)\n' "$INLINE_DUP" "$INLINE_DUP" >"$COMMENT_DUP_MD"
set_stub_response 1 "[$ATTACH_OBJ_PNG]" 200
set_stub_response 2 '' 303
set_stub_headers 2 "$MEDIA_303_HEADERS"
set_stub_response 3 '{"id":"10004"}' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" comment PSWS-1 --text-file "$COMMENT_DUP_MD" --confirmed-site foo.atlassian.net
expect_rc "comment dup image -> exit 0" 0
equals "comment dup image: same path uploaded ONCE -> THREE calls (one upload + one resolve + comment)" "$(call_count)" "3"
DUP_MEDIA_COUNT=$(jq -r '[.body.content[] | select(.type=="mediaSingle")] | length' "$CURL_STUB_BODY_LOG_DIR/call-3.body")
equals "comment dup image: BOTH own-line occurrences still render a mediaSingle (same UUID reused)" "$DUP_MEDIA_COUNT" "2"

section "jira.sh — resolve media UUID: a malformed Location UUID fails loud (exit 1), JWT never leaks"

reset_curl_stub
INLINE_BAD="$WORK/bad-uuid.png"
printf 'BAD' >"$INLINE_BAD"
COMMENT_BAD_MD="$WORK/comment-bad-uuid.md"
printf '![x](%s)\n' "$INLINE_BAD" >"$COMMENT_BAD_MD"
set_stub_response 1 "[$ATTACH_OBJ_PNG]" 200
set_stub_response 2 '' 303
set_stub_headers 2 "HTTP/2 303
Location: https://api.media.atlassian.com/file/NOT-A-REAL-UUID/binary?token=$MEDIA_JWT"
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" comment PSWS-1 --text-file "$COMMENT_BAD_MD" --confirmed-site foo.atlassian.net
expect_rc "resolve media uuid malformed -> exit 1" 1
stderr_has "resolve media uuid malformed: diagnostic names no UUID found" "no media UUID found"
TESTS_RUN=$((TESTS_RUN + 1))
if printf '%s' "$CUR_OUT$CUR_ERR" | grep -Fq -- "$MEDIA_JWT"; then
	fail "resolve media uuid malformed: JWT never leaks even on the error path" "output leaked the JWT"
else
	pass "resolve media uuid malformed: JWT never leaks even on the error path"
fi
# Match the success-path assertions: the token is off-argv (in the -K config
# only) and the raw media host is never surfaced — hold the ERROR path to the
# same bar so a regression can't leak on failure while passing on success.
file_not_has "resolve media uuid malformed: JWT never appears in the argv log (off-argv, -K config only)" "$CURL_STUB_ARGV_LOG" "$MEDIA_JWT"
TESTS_RUN=$((TESTS_RUN + 1))
if printf '%s' "$CUR_OUT$CUR_ERR" | grep -Fq -- "api.media.atlassian.com"; then
	fail "resolve media uuid malformed: the raw media Location host never appears in output" "output leaked the Location host"
else
	pass "resolve media uuid malformed: the raw media Location host never appears in output"
fi

section "jira.sh — resolve media UUID: a non-3xx content response fails loud (exit 1)"

reset_curl_stub
INLINE_NON3XX="$WORK/non3xx.png"
printf 'X' >"$INLINE_NON3XX"
COMMENT_NON3XX_MD="$WORK/comment-non3xx.md"
printf '![x](%s)\n' "$INLINE_NON3XX" >"$COMMENT_NON3XX_MD"
set_stub_response 1 "[$ATTACH_OBJ_PNG]" 200
set_stub_response 2 '' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" comment PSWS-1 --text-file "$COMMENT_NON3XX_MD" --confirmed-site foo.atlassian.net
expect_rc "resolve media uuid non-3xx -> exit 1" 1
stderr_has "resolve media uuid non-3xx: diagnostic names the expected 3xx" "expected a 3xx redirect"

section "jira.sh — update --description-file with an inline image: media map flows through to the PUT body"

reset_curl_stub
INLINE_UPD="$WORK/update-img.png"
printf 'UPD' >"$INLINE_UPD"
UPDATE_IMG_MD="$WORK/update-with-image.md"
printf 'New body.\n\n![shot](%s)\n' "$INLINE_UPD" >"$UPDATE_IMG_MD"
set_stub_response 1 "[$ATTACH_OBJ_PNG]" 200
set_stub_response 2 '' 303
set_stub_headers 2 "$MEDIA_303_HEADERS"
set_stub_response 3 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" update PSWS-1 --description-file "$UPDATE_IMG_MD" --confirmed-site foo.atlassian.net
expect_rc "update --description-file inline image -> exit 0" 0
equals "update inline image: THREE calls (upload + resolve + PUT)" "$(call_count)" "3"
UPDATE_MEDIA_ID=$(jq -r '[.fields.description.content[] | select(.type=="mediaSingle")][0].content[0].attrs.id' "$CURL_STUB_BODY_LOG_DIR/call-3.body")
equals "update inline image: the PUT description carries a mediaSingle with the resolved UUID" "$UPDATE_MEDIA_ID" "$MEDIA_UUID"

section "jira.sh — create --description-file with an inline image: 2-step (create WITHOUT media, then follow-up description update WITH media)"

reset_curl_stub
INLINE_CREATE="$WORK/create-img.png"
printf 'CRT' >"$INLINE_CREATE"
CREATE_IMG_MD="$WORK/create-with-image.md"
printf 'Fresh issue.\n\n![figure](%s)\n' "$INLINE_CREATE" >"$CREATE_IMG_MD"
# call 1: create POST -> 201 with the new key
set_stub_response 1 '{"key":"PSWS-9","id":"90001","self":"https://foo.atlassian.net/rest/api/3/issue/90001"}' 201
# call 2: upload the inline image to the NEW key
set_stub_response 2 "[$ATTACH_OBJ_PNG]" 200
# call 3: resolve the media UUID (303 + Location)
set_stub_response 3 '' 303
set_stub_headers 3 "$MEDIA_303_HEADERS"
# call 4: follow-up description PUT
set_stub_response 4 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" create --project PSWS --title "T" --description-file "$CREATE_IMG_MD" --confirmed-site foo.atlassian.net
expect_rc "create --description-file inline image -> exit 0" 0
equals "create inline image: FOUR calls (create + upload + resolve + follow-up PUT)" "$(call_count)" "4"
file_has "create inline image: call 1 is the create POST /rest/api/3/issue" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/issue"
CREATE_STEP1_MEDIA=$(jq -r '[.fields.description.content[] | select(.type=="mediaSingle")] | length' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "create inline image: the INITIAL create body has NO media (issue did not exist yet -> empty map)" "$CREATE_STEP1_MEDIA" "0"
file_has "create inline image: call 4 PUTs the new key /rest/api/3/issue/PSWS-9" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/issue/PSWS-9"
CREATE_STEP2_MEDIA=$(jq -r '[.fields.description.content[] | select(.type=="mediaSingle")][0].content[0].attrs.id' "$CURL_STUB_BODY_LOG_DIR/call-4.body")
equals "create inline image: the follow-up PUT description carries the mediaSingle with the resolved UUID" "$CREATE_STEP2_MEDIA" "$MEDIA_UUID"
stdout_has "create inline image: still emits the issue-key machine line" "JIRA_ISSUE_KEY=PSWS-9"
stdout_has "create inline image: still emits the URL machine line" "JIRA_ISSUE_URL=https://foo.atlassian.net/browse/PSWS-9"

section "jira.sh — create --description-file with NO inline image: single create call, no follow-up PUT"

reset_curl_stub
CREATE_PLAIN_MD="$WORK/create-plain.md"
printf 'Plain description, no images.\n' >"$CREATE_PLAIN_MD"
set_stub_response 1 '{"key":"PSWS-10","id":"90002","self":"x"}' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" create --project PSWS --title "T" --description-file "$CREATE_PLAIN_MD" --confirmed-site foo.atlassian.net
expect_rc "create no images -> exit 0" 0
equals "create no images: exactly ONE call (create only — no upload, resolve, or follow-up PUT)" "$(call_count)" "1"
stdout_has "create no images: issue-key machine line" "JIRA_ISSUE_KEY=PSWS-10"

section "jira.sh — update --append-file with an inline image: upload -> resolve -> fetch-existing -> PUT carries the mediaSingle (appended to the existing body)"

reset_curl_stub
INLINE_APPEND="$WORK/append-img.png"
printf 'APP' >"$INLINE_APPEND"
APPEND_IMG_MD="$WORK/append-with-image.md"
printf 'Appended note.\n\n![shot](%s)\n' "$INLINE_APPEND" >"$APPEND_IMG_MD"
# call 1: upload the inline image to the issue
set_stub_response 1 "[$ATTACH_OBJ_PNG]" 200
# call 2: resolve the media UUID (303 + Location)
set_stub_response 2 '' 303
set_stub_headers 2 "$MEDIA_303_HEADERS"
# call 3: fetch the existing description (append reads-extends-replaces)
set_stub_response 3 '{"fields":{"description":{"type":"doc","version":1,"content":[{"type":"paragraph","content":[{"type":"text","text":"existing body"}]}]}}}' 200
# call 4: the whole-document description PUT
set_stub_response 4 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" update PSWS-1 --append-file "$APPEND_IMG_MD" --confirmed-site foo.atlassian.net
expect_rc "update --append-file inline image -> exit 0" 0
equals "update append inline image: FOUR calls (upload + resolve + fetch-existing + PUT)" "$(call_count)" "4"
file_has "update append inline image: call 4 PUTs /rest/api/3/issue/PSWS-1" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/issue/PSWS-1"
APPEND_MEDIA_ID=$(jq -r '[.fields.description.content[] | select(.type=="mediaSingle")][0].content[0].attrs.id' "$CURL_STUB_BODY_LOG_DIR/call-4.body")
equals "update append inline image: the appended-description PUT body carries a mediaSingle with the resolved UUID" "$APPEND_MEDIA_ID" "$MEDIA_UUID"
APPEND_KEPT_OLD=$(jq -r '[.fields.description.content[] | select(.type=="paragraph") | .content[]?.text] | join(" ")' "$CURL_STUB_BODY_LOG_DIR/call-4.body")
TESTS_RUN=$((TESTS_RUN + 1))
case "$APPEND_KEPT_OLD" in
	*"existing body"*) pass "update append inline image: the existing description body is preserved ahead of the appended media" ;;
	*) fail "update append inline image: the existing description body is preserved ahead of the appended media" "got: $APPEND_KEPT_OLD" ;;
esac

section "jira.sh — inline-image scan agrees with md-to-adf: a fenced or trailing-text image is NOT uploaded; only a solely-image line is"

reset_curl_stub
INLINE_SOLELY="$WORK/solely.png"
printf 'SOLE' >"$INLINE_SOLELY"
# The fenced and trailing-text image paths deliberately DO NOT EXIST: if scan
# wrongly extracted either (the over-match / fence-desync regressions), require_readable_file
# would abort the whole command (exit 2) — so a clean exit 0 is itself proof
# neither was extracted. Only the solely-image line is a real, uploadable file.
SCAN_MD="$WORK/scan-mixed.md"
{
	printf 'Intro line.\n\n'
	printf '```text\n'
	printf '![in-fence](/nonexistent/in-fence.png)\n'
	printf '```\n\n'
	printf '![trailing](/nonexistent/trailing.png) (fig 1)\n\n'
	printf '![second](/nonexistent/a.png) ![third](/nonexistent/b.png)\n\n'
	printf '![real](%s)\n' "$INLINE_SOLELY"
} >"$SCAN_MD"
set_stub_response 1 "[$ATTACH_OBJ_PNG]" 200
set_stub_response 2 '' 303
set_stub_headers 2 "$MEDIA_303_HEADERS"
set_stub_response 3 '{"id":"10009"}' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" comment PSWS-1 --text-file "$SCAN_MD" --confirmed-site foo.atlassian.net
expect_rc "scan mixed images -> exit 0 (no garbled non-path aborts the command)" 0
equals "scan mixed images: exactly THREE calls — ONLY the solely-image line uploads (upload + resolve + comment)" "$(call_count)" "3"
SCAN_MEDIA_COUNT=$(jq -r '[.body.content[] | select(.type=="mediaSingle")] | length' "$CURL_STUB_BODY_LOG_DIR/call-3.body")
equals "scan mixed images: EXACTLY ONE mediaSingle in the comment body (fenced + trailing-text lines stayed text)" "$SCAN_MEDIA_COUNT" "1"
SCAN_MEDIA_ID=$(jq -r '[.body.content[] | select(.type=="mediaSingle")][0].content[0].attrs.id' "$CURL_STUB_BODY_LOG_DIR/call-3.body")
equals "scan mixed images: the one mediaSingle references the resolved UUID" "$SCAN_MEDIA_ID" "$MEDIA_UUID"

section "jira.sh — create --json with an inline image: emitted JSON is the CREATE's 201 body (snapshot), NOT the follow-up 204 PUT"

reset_curl_stub
INLINE_CJSON="$WORK/cjson-img.png"
printf 'CJ' >"$INLINE_CJSON"
CJSON_MD="$WORK/create-json-with-image.md"
printf 'Body.\n\n![figure](%s)\n' "$INLINE_CJSON" >"$CJSON_MD"
# call 1: create POST -> 201 with the new key/id (the snapshot --json must echo)
set_stub_response 1 '{"key":"PSWS-9","id":"90001","self":"https://foo.atlassian.net/rest/api/3/issue/90001"}' 201
# call 2: upload · call 3: resolve · call 4: follow-up 204 PUT (must NOT be echoed)
set_stub_response 2 "[$ATTACH_OBJ_PNG]" 200
set_stub_response 3 '' 303
set_stub_headers 3 "$MEDIA_303_HEADERS"
set_stub_response 4 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" create --project PSWS --title "T" --description-file "$CJSON_MD" --json --confirmed-site foo.atlassian.net
expect_rc "create --json inline image -> exit 0" 0
equals "create --json inline image: FOUR calls (create + upload + resolve + follow-up PUT)" "$(call_count)" "4"
CJSON_KEY=$(printf '%s' "$CUR_OUT" | jq -r '.key')
equals "create --json inline image: emitted JSON .key is the CREATE's 201 body key" "$CJSON_KEY" "PSWS-9"
CJSON_ID=$(printf '%s' "$CUR_OUT" | jq -r '.id')
equals "create --json inline image: emitted JSON .id is the CREATE's 201 body id (the 204 PUT has no body)" "$CJSON_ID" "90001"

# ===========================================================================
# bulk — apply one existing verb to a SET of issues (client-side loop over the
# reviewed single-issue verbs). Real request/response shapes; curl stubbed.
# ===========================================================================

# --- validation (all exit 2, all BEFORE any network call) ------------------
section "jira.sh — bulk: validation (usage errors, exit 2, no network)"

# Reset the shared curl counter so the "ZERO curl calls" assertions below
# measure THIS section's calls, not a prior test's residue.
reset_curl_stub

run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" bulk --op frobnicate --keys "PSWS-1" --status Done --confirmed-site foo.atlassian.net
expect_rc "bulk invalid --op -> exit 2" 2
stderr_has "bulk invalid --op: diagnostic" "invalid --op"
equals "bulk invalid --op: ZERO curl calls" "$(call_count)" "0"

run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" bulk --keys "PSWS-1" --status Done --confirmed-site foo.atlassian.net
expect_rc "bulk missing --op -> exit 2" 2
stderr_has "bulk missing --op: diagnostic" "bulk requires --op"

run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" bulk --op transition --keys "PSWS-1" --jql "project = PSWS" --status Done --confirmed-site foo.atlassian.net
expect_rc "bulk both --keys and --jql -> exit 2" 2
stderr_has "bulk both selectors: diagnostic" "exactly one of --keys or --jql"
equals "bulk both selectors: ZERO curl calls" "$(call_count)" "0"

run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" bulk --op transition --status Done --confirmed-site foo.atlassian.net
expect_rc "bulk neither selector -> exit 2" 2
stderr_has "bulk neither selector: diagnostic" "requires a set selector"

run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" bulk --op transition --keys "PSWS-1,PSWS-2" --confirmed-site foo.atlassian.net
expect_rc "bulk transition without --status -> exit 2" 2
stderr_has "bulk transition no --status: diagnostic" "requires --status"

run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" bulk --op comment --keys "PSWS-1" --confirmed-site foo.atlassian.net
expect_rc "bulk comment without --text-file -> exit 2" 2
stderr_has "bulk comment no --text-file: diagnostic" "requires --text-file"

run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" bulk --op update --keys "PSWS-1" --confirmed-site foo.atlassian.net
expect_rc "bulk update with no field -> exit 2" 2
stderr_has "bulk update no field: diagnostic" "at least one field"

run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" bulk --op transition --status Done --keys "PSWS-1,not-a-key,PSWS-3" --confirmed-site foo.atlassian.net
expect_rc "bulk invalid key in --keys -> exit 2" 2
stderr_has "bulk invalid key: diagnostic" "invalid ticket key in --keys"
equals "bulk invalid key: ZERO curl calls (validated before network)" "$(call_count)" "0"

run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" bulk STRAY --op transition --status Done --keys "PSWS-1" --confirmed-site foo.atlassian.net
expect_rc "bulk stray positional -> exit 2" 2
stderr_has "bulk stray positional: diagnostic" "takes no positional"

# --- --plan DRY RUN: --keys makes ZERO requests ----------------------------
section "jira.sh — bulk --plan (--keys): resolves + discloses, writes NOTHING, ZERO curl calls"

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" bulk --op transition --status Done --keys "PSWS-1,PSWS-2,PSWS-3" --plan --confirmed-site foo.atlassian.net
expect_rc "bulk --plan --keys -> exit 0" 0
equals "bulk --plan --keys: ZERO curl calls (no read, no write)" "$(call_count)" "0"
stdout_has "bulk --plan: names the intended transition" "would transition to \"Done\""
stdout_has "bulk --plan: lists PSWS-1" "PSWS-1"
stdout_has "bulk --plan: lists PSWS-2" "PSWS-2"
stdout_has "bulk --plan: lists PSWS-3" "PSWS-3"
stdout_has "bulk --plan: states nothing was written" "NOTHING WAS WRITTEN"

# --plan --json: a structured disclosure that provably will NOT write
reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" bulk --op transition --status Done --keys "PSWS-1,PSWS-2" --plan --json --confirmed-site foo.atlassian.net
expect_rc "bulk --plan --json --keys -> exit 0" 0
equals "bulk --plan --json: ZERO curl calls" "$(call_count)" "0"
PLAN_JSON="$CUR_OUT"
equals "bulk --plan --json: willWrite is false" "$(printf '%s' "$PLAN_JSON" | jq -r '.willWrite')" "false"
equals "bulk --plan --json: total is 2" "$(printf '%s' "$PLAN_JSON" | jq -r '.total')" "2"
equals "bulk --plan --json: keys array is the resolved set" "$(printf '%s' "$PLAN_JSON" | jq -c '.keys')" '["PSWS-1","PSWS-2"]'

# --- --plan DRY RUN: --jql makes ONLY the resolve read, no write -----------
section "jira.sh — bulk --plan (--jql): ONE read to resolve the set, ZERO writes"

reset_curl_stub
set_stub_response 1 '{"issues":[{"key":"PSWS-1","fields":{"summary":"a","status":{"name":"Open"}}},{"key":"PSWS-2","fields":{"summary":"b","status":{"name":"Open"}}}],"isLast":true}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" bulk --op transition --status Done --jql "project = PSWS AND status = Open" --plan --confirmed-site foo.atlassian.net
expect_rc "bulk --plan --jql -> exit 0" 0
equals "bulk --plan --jql: exactly ONE curl call (the JQL resolve)" "$(call_count)" "1"
file_has "bulk --plan --jql: the one call is the /search/jql read" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/search/jql"
# The transition verb writes via POST /transitions (never PUT), so a PUT-absent
# assertion would be vacuously true. Assert the actual write endpoint the op
# would hit is absent from the argv log — it would genuinely fail if --plan
# ever issued the transition verb.
file_not_has "bulk --plan --jql: the transition write endpoint was NOT hit" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/issue/PSWS-1/transitions"
stdout_has "bulk --plan --jql: lists the resolved PSWS-1" "PSWS-1"
stdout_has "bulk --plan --jql: lists the resolved PSWS-2" "PSWS-2"
stdout_has "bulk --plan --jql: states nothing was written" "NOTHING WAS WRITTEN"

# --- real bulk over --keys (transition): one 4-call walk per key -----------
section "jira.sh — bulk real (--keys, transition): a verb-request set per key + per-issue result lines"

reset_curl_stub
# PSWS-1 (calls 1-4): status -> transitions -> POST 204 -> verify
set_stub_response 1 '{"fields":{"status":{"name":"Open"},"issuetype":{"name":"Task"}}}' 200
set_stub_response 2 '{"transitions":[{"id":"11","to":{"name":"Done"}}]}' 200
set_stub_response 3 '' 204
set_stub_response 4 '{"fields":{"status":{"name":"Done"}}}' 200
# PSWS-2 (calls 5-8)
set_stub_response 5 '{"fields":{"status":{"name":"Open"},"issuetype":{"name":"Task"}}}' 200
set_stub_response 6 '{"transitions":[{"id":"11","to":{"name":"Done"}}]}' 200
set_stub_response 7 '' 204
set_stub_response 8 '{"fields":{"status":{"name":"Done"}}}' 200
# PSWS-3 (calls 9-12)
set_stub_response 9 '{"fields":{"status":{"name":"Open"},"issuetype":{"name":"Task"}}}' 200
set_stub_response 10 '{"transitions":[{"id":"11","to":{"name":"Done"}}]}' 200
set_stub_response 11 '' 204
set_stub_response 12 '{"fields":{"status":{"name":"Done"}}}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$WORK/noconfig" \
	sh "$JIRA" bulk --op transition --status Done --keys "PSWS-1,PSWS-2,PSWS-3" --confirmed-site foo.atlassian.net
expect_rc "bulk real --keys transition -> exit 0" 0
equals "bulk real --keys: 12 calls (3 keys x 4-call walk)" "$(call_count)" "12"
file_has "bulk real --keys: PSWS-1 transitions endpoint hit" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/issue/PSWS-1/transitions"
file_has "bulk real --keys: PSWS-2 transitions endpoint hit" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/issue/PSWS-2/transitions"
file_has "bulk real --keys: PSWS-3 transitions endpoint hit" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/issue/PSWS-3/transitions"
stdout_has "bulk real --keys: PSWS-1 result line ok" "JIRA_BULK_RESULT=PSWS-1:ok"
stdout_has "bulk real --keys: PSWS-2 result line ok" "JIRA_BULK_RESULT=PSWS-2:ok"
stdout_has "bulk real --keys: PSWS-3 result line ok" "JIRA_BULK_RESULT=PSWS-3:ok"
stdout_has "bulk real --keys: summary line" "JIRA_BULK_SUMMARY=3/3 succeeded"

# --- real bulk over --jql (transition): resolve, then a walk per key -------
section "jira.sh — bulk real (--jql, transition): JQL resolve first, then a verb-request set per resolved key"

reset_curl_stub
# call 1: the JQL resolve returns two keys
set_stub_response 1 '{"issues":[{"key":"PSWS-1","fields":{"summary":"a","status":{"name":"Open"}}},{"key":"PSWS-2","fields":{"summary":"b","status":{"name":"Open"}}}],"isLast":true}' 200
# PSWS-1 (calls 2-5)
set_stub_response 2 '{"fields":{"status":{"name":"Open"},"issuetype":{"name":"Task"}}}' 200
set_stub_response 3 '{"transitions":[{"id":"11","to":{"name":"Done"}}]}' 200
set_stub_response 4 '' 204
set_stub_response 5 '{"fields":{"status":{"name":"Done"}}}' 200
# PSWS-2 (calls 6-9)
set_stub_response 6 '{"fields":{"status":{"name":"Open"},"issuetype":{"name":"Task"}}}' 200
set_stub_response 7 '{"transitions":[{"id":"11","to":{"name":"Done"}}]}' 200
set_stub_response 8 '' 204
set_stub_response 9 '{"fields":{"status":{"name":"Done"}}}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$WORK/noconfig" \
	sh "$JIRA" bulk --op transition --status Done --jql "project = PSWS AND status = Open" --confirmed-site foo.atlassian.net
expect_rc "bulk real --jql transition -> exit 0" 0
equals "bulk real --jql: 9 calls (1 resolve + 2 keys x 4-call walk)" "$(call_count)" "9"
file_has "bulk real --jql: call 1 is the /search/jql resolve" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/search/jql"
JQL_RESOLVE_SENT=$(jq -r '.jql' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "bulk real --jql: the resolve carried the caller's JQL verbatim" "$JQL_RESOLVE_SENT" "project = PSWS AND status = Open"
file_has "bulk real --jql: PSWS-1 transitions endpoint hit" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/issue/PSWS-1/transitions"
file_has "bulk real --jql: PSWS-2 transitions endpoint hit" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/issue/PSWS-2/transitions"
stdout_has "bulk real --jql: PSWS-1 result line ok" "JIRA_BULK_RESULT=PSWS-1:ok"
stdout_has "bulk real --jql: PSWS-2 result line ok" "JIRA_BULK_RESULT=PSWS-2:ok"
stdout_has "bulk real --jql: summary line" "JIRA_BULK_SUMMARY=2/2 succeeded"

# --- partial failure: issue #2 4xx does NOT abort the batch -----------------
section "jira.sh — bulk partial failure (--keys): #2 fails, #1 and #3 still processed, exit non-zero"

reset_curl_stub
# PSWS-1 (calls 1-4): succeeds
set_stub_response 1 '{"fields":{"status":{"name":"Open"},"issuetype":{"name":"Task"}}}' 200
set_stub_response 2 '{"transitions":[{"id":"11","to":{"name":"Done"}}]}' 200
set_stub_response 3 '' 204
set_stub_response 4 '{"fields":{"status":{"name":"Done"}}}' 200
# PSWS-2 (call 5): the very first request (status GET) 404s -> this issue fails
set_stub_response 5 '{"errorMessages":["Issue does not exist"]}' 404
# PSWS-3 (calls 6-9): STILL processed after #2 failed
set_stub_response 6 '{"fields":{"status":{"name":"Open"},"issuetype":{"name":"Task"}}}' 200
set_stub_response 7 '{"transitions":[{"id":"11","to":{"name":"Done"}}]}' 200
set_stub_response 8 '' 204
set_stub_response 9 '{"fields":{"status":{"name":"Done"}}}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$WORK/noconfig" \
	sh "$JIRA" bulk --op transition --status Done --keys "PSWS-1,PSWS-2,PSWS-3" --confirmed-site foo.atlassian.net
expect_rc "bulk partial failure -> exit 1 (any failure => non-zero)" 1
equals "bulk partial failure: 9 calls (4 ok + 1 failed-early + 4 ok)" "$(call_count)" "9"
stdout_has "bulk partial failure: PSWS-1 ok" "JIRA_BULK_RESULT=PSWS-1:ok"
stdout_has "bulk partial failure: PSWS-2 failed" "JIRA_BULK_RESULT=PSWS-2:failed"
stdout_has "bulk partial failure: PSWS-3 ok (processed despite #2 failing)" "JIRA_BULK_RESULT=PSWS-3:ok"
stdout_has "bulk partial failure: accurate summary" "JIRA_BULK_SUMMARY=2/3 succeeded"
file_has "bulk partial failure: PSWS-3's transitions endpoint WAS still hit" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/issue/PSWS-3/transitions"

# --- real bulk over --keys (comment): one POST per issue -------------------
section "jira.sh — bulk real (--keys, comment): one comment POST per issue"

reset_curl_stub
BULK_COMMENT_MD="$WORK/bulk-comment.md"
printf 'Batch note to the team.\n' >"$BULK_COMMENT_MD"
set_stub_response 1 '{"id":"20001"}' 201
set_stub_response 2 '{"id":"20002"}' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" bulk --op comment --text-file "$BULK_COMMENT_MD" --keys "PSWS-1,PSWS-2" --confirmed-site foo.atlassian.net
expect_rc "bulk real comment -> exit 0" 0
equals "bulk real comment: 2 calls (one POST per issue)" "$(call_count)" "2"
file_has "bulk real comment: PSWS-1 comment endpoint hit" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/issue/PSWS-1/comment"
file_has "bulk real comment: PSWS-2 comment endpoint hit" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/issue/PSWS-2/comment"
stdout_has "bulk real comment: PSWS-1 ok" "JIRA_BULK_RESULT=PSWS-1:ok"
stdout_has "bulk real comment: PSWS-2 ok" "JIRA_BULK_RESULT=PSWS-2:ok"
stdout_has "bulk real comment: summary" "JIRA_BULK_SUMMARY=2/2 succeeded"

# --- real bulk over --keys (update): one PUT per issue ---------------------
section "jira.sh — bulk real (--keys, update): one update PUT per issue"

reset_curl_stub
set_stub_response 1 '' 204
set_stub_response 2 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$WORK/noconfig" \
	sh "$JIRA" bulk --op update --due-date 2026-12-31 --keys "PSWS-1,PSWS-2" --confirmed-site foo.atlassian.net
expect_rc "bulk real update -> exit 0" 0
equals "bulk real update: 2 calls (one PUT per issue)" "$(call_count)" "2"
argv_log_has_token "bulk real update: the write method is PUT" "PUT"
file_has "bulk real update: PSWS-1 issue endpoint hit" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/issue/PSWS-1"
file_has "bulk real update: PSWS-2 issue endpoint hit" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/issue/PSWS-2"
UPDATE_DUEDATE_SENT=$(jq -r '.fields.duedate' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "bulk real update: PSWS-1 PUT body carries the due date" "$UPDATE_DUEDATE_SENT" "2026-12-31"
stdout_has "bulk real update: summary" "JIRA_BULK_SUMMARY=2/2 succeeded"

# --- --json: structured per-issue results + summary object -----------------
section "jira.sh — bulk --json (--keys, transition): array of results + a summary object"

reset_curl_stub
set_stub_response 1 '{"fields":{"status":{"name":"Open"},"issuetype":{"name":"Task"}}}' 200
set_stub_response 2 '{"transitions":[{"id":"11","to":{"name":"Done"}}]}' 200
set_stub_response 3 '' 204
set_stub_response 4 '{"fields":{"status":{"name":"Done"}}}' 200
set_stub_response 5 '{"errorMessages":["nope"]}' 404
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$WORK/noconfig" \
	sh "$JIRA" bulk --op transition --status Done --keys "PSWS-1,PSWS-2" --json --confirmed-site foo.atlassian.net
expect_rc "bulk --json partial -> exit 1" 1
BULK_JSON="$CUR_OUT"
equals "bulk --json: op field" "$(printf '%s' "$BULK_JSON" | jq -r '.op')" "transition"
equals "bulk --json: PSWS-1 status ok" "$(printf '%s' "$BULK_JSON" | jq -r '.results[0].status')" "ok"
equals "bulk --json: PSWS-2 status failed" "$(printf '%s' "$BULK_JSON" | jq -r '.results[1].status')" "failed"
equals "bulk --json: summary.ok" "$(printf '%s' "$BULK_JSON" | jq -r '.summary.ok')" "1"
equals "bulk --json: summary.total" "$(printf '%s' "$BULK_JSON" | jq -r '.summary.total')" "2"
equals "bulk --json: summary.failed" "$(printf '%s' "$BULK_JSON" | jq -r '.summary.failed')" "1"

# --- security: an injection-shaped JQL still routes through the escaped path -
section "jira.sh — bulk --jql: JQL flows through the SAME escaped search path (never concatenated)"

reset_curl_stub
set_stub_response 1 '{"issues":[],"isLast":true}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" bulk --op transition --status Done --jql 'project = PSWS AND summary ~ "x\" OR key=SECRET-1"' --plan --confirmed-site foo.atlassian.net
expect_rc "bulk --jql injection-shaped -> exit 1 (zero issues resolved)" 1
equals "bulk --jql injection-shaped: still exactly ONE resolve call" "$(call_count)" "1"
file_has "bulk --jql injection-shaped: went through /search/jql (the escaped sender)" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/search/jql"

# --- full-set resolution: --jql paginates to exhaustion, never caps at 50 ---
# A two-page resolve where page 1 alone holds 50 (== the OLD silent default):
# under the old code the batch would stop at 50 and misreport 50/50 complete.
# The set MUST resolve the full 60 across both pages, with truncated=false.
section "jira.sh — bulk --jql: resolves the FULL matching set (paginates to exhaustion), never silently caps at 50"

BULK_PAGE1=$(jq -nc '{issues: [range(1;51) | {key: ("PSWS-\(.)"), fields:{summary:"s",status:{name:"Open"}}}], isLast:false, nextPageToken:"PAGE2"}')
BULK_PAGE2=$(jq -nc '{issues: [range(51;61) | {key: ("PSWS-\(.)"), fields:{summary:"s",status:{name:"Open"}}}], isLast:true}')

reset_curl_stub
set_stub_response 1 "$BULK_PAGE1" 200
set_stub_response 2 "$BULK_PAGE2" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" bulk --op transition --status Done --jql "project = PSWS" --plan --json --confirmed-site foo.atlassian.net
expect_rc "bulk --jql full-set --plan --json -> exit 0" 0
equals "bulk --jql full-set: paginated BOTH pages to exhaustion (2 resolve calls)" "$(call_count)" "2"
BULK_FULL_PLAN="$CUR_OUT"
equals "bulk --jql full-set: total is the FULL 60, not capped at 50" "$(printf '%s' "$BULK_FULL_PLAN" | jq -r '.total')" "60"
equals "bulk --jql full-set: truncated is false (nothing capped)" "$(printf '%s' "$BULK_FULL_PLAN" | jq -r '.truncated')" "false"
equals "bulk --jql full-set: resolvedLimit is null (no cap)" "$(printf '%s' "$BULK_FULL_PLAN" | jq -r '.resolvedLimit')" "null"
equals "bulk --jql full-set: keys array holds all 60" "$(printf '%s' "$BULK_FULL_PLAN" | jq -r '.keys | length')" "60"
stdout_has "bulk --jql full-set: the set includes a page-2 key (PSWS-60)" "PSWS-60"

# The real run ACTS on the full multi-page set (comment op = one POST per issue,
# so 2 resolve pages + 60 POSTs). Proves the batch mutates all 60, not 50.
section "jira.sh — bulk --jql real: ACTS on the FULL multi-page set (not the first 50), reports the true count"

BULK_FULL_MD="$WORK/bulk-full.md"
printf 'Batch note.\n' >"$BULK_FULL_MD"
reset_curl_stub
set_stub_response 1 "$BULK_PAGE1" 200
set_stub_response 2 "$BULK_PAGE2" 200
bulk_full_n=3
while [ "$bulk_full_n" -le 62 ]; do
	set_stub_response "$bulk_full_n" '{"id":"9"}' 201
	bulk_full_n=$((bulk_full_n + 1))
done
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" bulk --op comment --text-file "$BULK_FULL_MD" --jql "project = PSWS" --confirmed-site foo.atlassian.net
expect_rc "bulk --jql real full-set -> exit 0" 0
equals "bulk --jql real full-set: 62 calls (2 resolve pages + 60 comment POSTs)" "$(call_count)" "62"
stdout_has "bulk --jql real full-set: summary reports the TRUE 60, not 50" "JIRA_BULK_SUMMARY=60/60 succeeded"
stdout_not_has "bulk --jql real full-set: NOT flagged as capped (full set)" "CAPPED"
file_has "bulk --jql real full-set: a page-2 issue (PSWS-60) WAS acted on" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/issue/PSWS-60/comment"
stdout_has "bulk --jql real full-set: page-2 issue PSWS-60 result line" "JIRA_BULK_RESULT=PSWS-60:ok"

# --- disclosed cap: an explicit --limit is intentional but MUST be disclosed --
section "jira.sh — bulk --jql --limit: an explicit cap is DISCLOSED (truncated + resolvedLimit + warning), never a silent partial"

reset_curl_stub
# Page 1 alone fills the --limit 50 (isLast:false => more pages exist beyond it).
set_stub_response 1 "$BULK_PAGE1" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" bulk --op transition --status Done --jql "project = PSWS" --limit 50 --plan --json --confirmed-site foo.atlassian.net
expect_rc "bulk --jql --limit --plan --json -> exit 0" 0
equals "bulk --jql --limit: honored the explicit cap — only ONE page fetched" "$(call_count)" "1"
BULK_CAP_PLAN="$CUR_OUT"
equals "bulk --jql --limit: total is the capped 50" "$(printf '%s' "$BULK_CAP_PLAN" | jq -r '.total')" "50"
equals "bulk --jql --limit: truncated is TRUE (cap in effect)" "$(printf '%s' "$BULK_CAP_PLAN" | jq -r '.truncated')" "true"
equals "bulk --jql --limit: resolvedLimit discloses the cap" "$(printf '%s' "$BULK_CAP_PLAN" | jq -r '.resolvedLimit')" "50"
stderr_has "bulk --jql --limit: warns that more matches may exist" "capped at --limit 50"

# A REAL capped run must never print a bare N/N succeeded — the cap is inline.
reset_curl_stub
BULK_CAP_PAGE=$(jq -nc '{issues: [range(1;3) | {key: ("PSWS-\(.)"), fields:{summary:"s",status:{name:"Open"}}}], isLast:false, nextPageToken:"MORE"}')
set_stub_response 1 "$BULK_CAP_PAGE" 200
set_stub_response 2 '{"id":"9"}' 201
set_stub_response 3 '{"id":"9"}' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" bulk --op comment --text-file "$BULK_FULL_MD" --jql "project = PSWS" --limit 2 --confirmed-site foo.atlassian.net
expect_rc "bulk --jql --limit real -> exit 0" 0
equals "bulk --jql --limit real: 3 calls (1 resolve + 2 comment POSTs)" "$(call_count)" "3"
stdout_has "bulk --jql --limit real: summary discloses the cap inline (never a bare N/N)" "CAPPED at --limit 2"
stderr_has "bulk --jql --limit real: warns more matches may exist" "capped at --limit 2"

# --- a resolved INVALID key fails closed BEFORE any verb request ------------
section "jira.sh — bulk --jql: a resolved invalid key (network-derived, untrusted) fails closed before any mutation"

reset_curl_stub
set_stub_response 1 '{"issues":[{"key":"../evil","fields":{"summary":"s","status":{"name":"Open"}}}],"isLast":true}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" bulk --op transition --status Done --jql "project = PSWS" --confirmed-site foo.atlassian.net
expect_rc "bulk --jql resolved-invalid-key -> exit 1" 1
stderr_has "bulk --jql resolved-invalid-key: diagnostic" "resolved an invalid ticket key"
equals "bulk --jql resolved-invalid-key: only the resolve fired, ZERO verb requests" "$(call_count)" "1"

# --- --plan discloses update + comment intents too (not only transition) ----
section "jira.sh — bulk --plan (--keys): update + comment intents disclosed, ZERO curl"

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" bulk --op update --due-date 2026-12-31 --labels urgent,backend --keys "PSWS-1,PSWS-2" --plan --confirmed-site foo.atlassian.net
expect_rc "bulk --plan update -> exit 0" 0
equals "bulk --plan update: ZERO curl calls" "$(call_count)" "0"
stdout_has "bulk --plan update: names the update intent" "update field(s):"
stdout_has "bulk --plan update: field-summary lists the changed due-date aspect" "due-date"
stdout_has "bulk --plan update: field-summary lists the changed labels aspect" "labels"
stdout_has "bulk --plan update: states nothing was written" "NOTHING WAS WRITTEN"

reset_curl_stub
BULK_PLAN_MD="$WORK/bulk-plan-comment.md"
printf 'note\n' >"$BULK_PLAN_MD"
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" bulk --op comment --text-file "$BULK_PLAN_MD" --keys "PSWS-1,PSWS-2" --plan --confirmed-site foo.atlassian.net
expect_rc "bulk --plan comment -> exit 0" 0
equals "bulk --plan comment: ZERO curl calls" "$(call_count)" "0"
stdout_has "bulk --plan comment: names the comment intent phrase" "add a comment from"
stdout_has "bulk --plan comment: states nothing was written" "NOTHING WAS WRITTEN"

# --- empty-set boundaries: whitespace-only --keys and a zero-resolve --jql ---
section "jira.sh — bulk empty-set boundaries: whitespace-only --keys (exit 2) and zero-resolve --jql (exit 1)"

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" bulk --op transition --status Done --keys " , ," --confirmed-site foo.atlassian.net
expect_rc "bulk --keys whitespace/comma-only -> exit 2" 2
stderr_has "bulk --keys empty: diagnostic" "contained no ticket keys"
equals "bulk --keys empty: ZERO curl calls" "$(call_count)" "0"

reset_curl_stub
set_stub_response 1 '{"issues":[],"isLast":true}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" bulk --op transition --status Done --jql "project = PSWS" --confirmed-site foo.atlassian.net
expect_rc "bulk --jql zero-resolve -> exit 1" 1
stderr_has "bulk --jql zero-resolve: diagnostic" "resolved ZERO issues"

# ===========================================================================
# Agile (READ-only) — boards / board / sprints / sprint / backlog / epics / epic
# over /rest/agile/1.0/. Fixtures use the REAL live envelope shapes: the two
# distinct list envelopes (`values` vs `issues`), the epic values envelope that
# carries isLast but NO `total`, and the single-object configuration/detail
# reads. The load-bearing tests are the multi-page ones that prove FULL
# resolution across both pagination shapes.
# ===========================================================================
section "jira.sh — agile boards: real values envelope, human + --json, query params"

# Real board list element shape (id/self/name/type/location.projectKey).
AGILE_BOARDS='{"maxResults":50,"startAt":0,"total":2,"isLast":true,"values":[{"id":826,"self":"https://foo.atlassian.net/rest/agile/1.0/board/826","name":"PSWS board","type":"simple","location":{"projectKey":"PSWS"}},{"id":827,"self":"x","name":"Scrum board","type":"scrum","location":{"projectKey":"PSWS"}}]}'

reset_curl_stub
set_stub_response 1 "$AGILE_BOARDS" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" boards --project PSWS --type simple --confirmed-site foo.atlassian.net
expect_rc "boards: real envelope -> exit 0" 0
stdout_has "boards: header counts both boards" "2 board(s):"
stdout_has "boards: renders board id 826" "826"
stdout_has "boards: renders board name" "PSWS board"
stdout_has "boards: renders board type + project" "[simple]"
file_has "boards: URL carries projectKeyOrId query" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/agile/1.0/board?projectKeyOrId=PSWS&type=simple&startAt=0&maxResults=50"

reset_curl_stub
set_stub_response 1 "$AGILE_BOARDS" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" boards --json --confirmed-site foo.atlassian.net
expect_rc "boards --json -> exit 0" 0
equals "boards --json: collected array wrapped as {values:[...]}" "$(printf '%s' "$CUR_OUT" | jq -r '.values | length')" "2"
equals "boards --json: first board id" "$(printf '%s' "$CUR_OUT" | jq -r '.values[0].id')" "826"

# No filter -> no query string at all (just the paging params).
reset_curl_stub
set_stub_response 1 '{"maxResults":50,"startAt":0,"total":0,"isLast":true,"values":[]}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" boards --confirmed-site foo.atlassian.net
expect_rc "boards: empty set -> exit 0" 0
stdout_has "boards: empty set renders 'No boards.'" "No boards."
file_has "boards: no-filter URL has only paging params (leading ?)" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/agile/1.0/board?startAt=0&maxResults=50"

section "jira.sh — agile board <id>: single configuration object (not paginated)"

AGILE_BOARD_CFG='{"id":826,"name":"PSWS board","type":"simple","columnConfig":{"columns":[{"name":"To Do","statuses":[{"id":"1"}]},{"name":"In Progress","statuses":[]},{"name":"Done","statuses":[]}]},"filter":{"id":"123"}}'
reset_curl_stub
set_stub_response 1 "$AGILE_BOARD_CFG" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" board 826 --confirmed-site foo.atlassian.net
expect_rc "board <id>: config -> exit 0" 0
equals "board <id>: single GET, no pagination" "$(call_count)" "1"
stdout_has "board <id>: header line" "Board 826: PSWS board (type simple)"
stdout_has "board <id>: lists a column" "To Do"
stdout_has "board <id>: lists another column" "In Progress"
file_has "board <id>: hits the configuration endpoint" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/agile/1.0/board/826/configuration"

reset_curl_stub
set_stub_response 1 "$AGILE_BOARD_CFG" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" board 826 --json --confirmed-site foo.atlassian.net
expect_rc "board <id> --json -> exit 0" 0
equals "board <id> --json: raw body passthrough (columnConfig intact)" "$(printf '%s' "$CUR_OUT" | jq -r '.columnConfig.columns | length')" "3"

section "jira.sh — agile sprints <board>: real values envelope + --state query"

AGILE_SPRINTS='{"maxResults":50,"startAt":0,"total":2,"isLast":true,"values":[{"id":2212,"self":"x","state":"closed","name":"Sprint 1","startDate":"2026-01-01","endDate":"2026-01-14","completeDate":"2026-01-14","originBoardId":826,"goal":"ship"},{"id":2213,"self":"x","state":"active","name":"Sprint 2","originBoardId":826,"goal":""}]}'
reset_curl_stub
set_stub_response 1 "$AGILE_SPRINTS" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprints 826 --state active,closed --confirmed-site foo.atlassian.net
expect_rc "sprints: real envelope -> exit 0" 0
stdout_has "sprints: header counts both" "2 sprint(s):"
stdout_has "sprints: renders sprint id" "2212"
stdout_has "sprints: renders state" "[closed]"
stdout_has "sprints: a sprint with NO dates renders N/A window" "N/A -> N/A"
file_has "sprints: --state CSV is urlencoded into the query" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/agile/1.0/board/826/sprint?state=active%2Cclosed&startAt=0&maxResults=50"

reset_curl_stub
set_stub_response 1 "$AGILE_SPRINTS" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprints 826 --json --confirmed-site foo.atlassian.net
expect_rc "sprints --json -> exit 0" 0
equals "sprints --json: collected array wrapped as {values:[...]}" "$(printf '%s' "$CUR_OUT" | jq -r '.values | length')" "2"

reset_curl_stub
set_stub_response 1 '{"maxResults":50,"startAt":0,"total":0,"isLast":true,"values":[]}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprints 826 --confirmed-site foo.atlassian.net
expect_rc "sprints: empty set -> exit 0" 0
stdout_has "sprints: empty set renders 'No sprints.'" "No sprints."

section "jira.sh — agile sprint <id>: detail (single object) vs --issues (issues envelope)"

AGILE_SPRINT_DETAIL='{"id":2212,"self":"x","state":"closed","name":"Sprint 1","startDate":"2026-01-01","endDate":"2026-01-14","goal":"ship it"}'
reset_curl_stub
set_stub_response 1 "$AGILE_SPRINT_DETAIL" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprint 2212 --confirmed-site foo.atlassian.net
expect_rc "sprint <id> detail -> exit 0" 0
equals "sprint <id> detail: single GET" "$(call_count)" "1"
stdout_has "sprint <id> detail: header" "Sprint 2212: Sprint 1 [closed]"
stdout_has "sprint <id> detail: goal line" "ship it"
file_has "sprint <id> detail: hits /sprint/<id>" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/agile/1.0/sprint/2212"

reset_curl_stub
set_stub_response 1 "$AGILE_SPRINT_DETAIL" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprint 2212 --json --confirmed-site foo.atlassian.net
expect_rc "sprint <id> detail --json -> exit 0" 0
equals "sprint <id> detail --json: raw single-object body passes straight through (goal intact)" "$(printf '%s' "$CUR_OUT" | jq -r '.goal')" "ship it"

AGILE_SPRINT_ISSUES='{"expand":"x","startAt":0,"maxResults":50,"total":2,"issues":[{"key":"PSWS-160","fields":{"summary":"do a thing","status":{"name":"Done"},"assignee":null}},{"key":"PSWS-161","fields":{"summary":"another","status":{"name":"Open"},"assignee":null}}]}'
reset_curl_stub
set_stub_response 1 "$AGILE_SPRINT_ISSUES" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprint 2212 --issues --confirmed-site foo.atlassian.net
expect_rc "sprint <id> --issues -> exit 0" 0
stdout_has "sprint --issues: issue-envelope header" "2 issue(s):"
stdout_has "sprint --issues: renders an issue key" "PSWS-160"
stdout_has "sprint --issues: renders issue status" "[Done]"
file_has "sprint --issues: hits /sprint/<id>/issue" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/agile/1.0/sprint/2212/issue?startAt=0&maxResults=50"

reset_curl_stub
set_stub_response 1 "$AGILE_SPRINT_ISSUES" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprint 2212 --issues --json --confirmed-site foo.atlassian.net
expect_rc "sprint --issues --json -> exit 0" 0
equals "sprint --issues --json: {issues:[...]} collected" "$(printf '%s' "$CUR_OUT" | jq -r '.issues | length')" "2"

# ===========================================================================
# Agile WRITE (Cycle-2) — sprint lifecycle: create / update / start / close.
# Every case runs with a STUBBED curl (zero network) and proves the exact
# POST URL + method + JSON body shape sent, per the live-probed ground truth.
# ===========================================================================
section "jira.sh — sprint --create: POST /sprint, body carries name + integer originBoardId"

SPRINT_CREATED='{"id":2300,"self":"x","state":"future","name":"Cycle 2","originBoardId":826,"goal":"ship writes"}'
reset_curl_stub
set_stub_response 1 "$SPRINT_CREATED" 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprint --create --board 826 --name "Cycle 2" --goal "ship writes" \
		--start-date 2026-07-26T10:00:00.000Z --end-date 2026-08-02T10:00:00.000Z \
		--confirmed-site foo.atlassian.net
expect_rc "sprint --create -> exit 0" 0
file_has "sprint --create: POST /rest/agile/1.0/sprint" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/agile/1.0/sprint"
argv_log_has_token "sprint --create: uses POST" "POST"
SP_CREATE_NAME=$(jq -r '.name' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "sprint --create: body name" "$SP_CREATE_NAME" "Cycle 2"
SP_CREATE_BOARD=$(jq -r '.originBoardId' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "sprint --create: body originBoardId value" "$SP_CREATE_BOARD" "826"
SP_CREATE_BOARD_TYPE=$(jq -r '.originBoardId | type' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "sprint --create: originBoardId is a JSON NUMBER, not the string \"826\"" "$SP_CREATE_BOARD_TYPE" "number"
SP_CREATE_GOAL=$(jq -r '.goal' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "sprint --create: goal carried" "$SP_CREATE_GOAL" "ship writes"
SP_CREATE_START=$(jq -r '.startDate' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "sprint --create: startDate carried verbatim" "$SP_CREATE_START" "2026-07-26T10:00:00.000Z"
SP_CREATE_END=$(jq -r '.endDate' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "sprint --create: endDate carried verbatim" "$SP_CREATE_END" "2026-08-02T10:00:00.000Z"
stdout_has "sprint --create: machine line names the new id" "JIRA_SPRINT_ID=2300"
stdout_has "sprint --create: machine line names the state" "JIRA_SPRINT_STATE=future"

section "jira.sh — sprint --create: minimal body is EXACTLY {name,originBoardId}"

reset_curl_stub
set_stub_response 1 '{"id":2301,"state":"future","name":"Minimal","originBoardId":826}' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprint --create --board 826 --name "Minimal" --confirmed-site foo.atlassian.net
expect_rc "sprint --create minimal -> exit 0" 0
SP_CREATE_MIN_KEYS=$(jq -cS 'keys' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "sprint --create minimal: body is exactly {name,originBoardId} (no empty optionals)" "$SP_CREATE_MIN_KEYS" '["name","originBoardId"]'

reset_curl_stub
set_stub_response 1 "$SPRINT_CREATED" 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprint --create --board 826 --name "Cycle 2" --json --confirmed-site foo.atlassian.net
expect_rc "sprint --create --json -> exit 0" 0
equals "sprint --create --json: raw sprint object passes straight through" "$(printf '%s' "$CUR_OUT" | jq -r '.state')" "future"

section "jira.sh — sprint --update: POST /sprint/<id>, PARTIAL body of only the changed fields"

reset_curl_stub
set_stub_response 1 '{"id":2300,"state":"future","name":"Renamed","originBoardId":826,"goal":"new goal"}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprint --update 2300 --name "Renamed" --goal "new goal" --confirmed-site foo.atlassian.net
expect_rc "sprint --update -> exit 0" 0
file_has "sprint --update: POST /rest/agile/1.0/sprint/2300" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/agile/1.0/sprint/2300"
argv_log_has_token "sprint --update: uses POST" "POST"
SP_UPDATE_KEYS=$(jq -cS 'keys' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "sprint --update: body carries ONLY the changed fields" "$SP_UPDATE_KEYS" '["goal","name"]'
SP_UPDATE_NAME=$(jq -r '.name' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "sprint --update: name value" "$SP_UPDATE_NAME" "Renamed"
stdout_has "sprint --update: machine line" "JIRA_SPRINT_ID=2300"

section "jira.sh — sprint --start: body is state=active PLUS both dates (ground-truth: start needs both)"

reset_curl_stub
set_stub_response 1 '{"id":2300,"state":"active","name":"Cycle 2","originBoardId":826,"startDate":"2026-07-26T10:00:00.000Z","endDate":"2026-08-02T10:00:00.000Z"}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprint --start 2300 --start-date 2026-07-26T10:00:00.000Z --end-date 2026-08-02T10:00:00.000Z \
		--confirmed-site foo.atlassian.net
expect_rc "sprint --start -> exit 0" 0
file_has "sprint --start: POST /rest/agile/1.0/sprint/2300" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/agile/1.0/sprint/2300"
SP_START_STATE=$(jq -r '.state' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "sprint --start: body state=active" "$SP_START_STATE" "active"
SP_START_KEYS=$(jq -cS 'keys' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "sprint --start: body is exactly {endDate,startDate,state}" "$SP_START_KEYS" '["endDate","startDate","state"]'
SP_START_SD=$(jq -r '.startDate' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "sprint --start: startDate carried" "$SP_START_SD" "2026-07-26T10:00:00.000Z"
stdout_has "sprint --start: machine state line" "JIRA_SPRINT_STATE=active"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprint --start 2300 --start-date 2026-07-26T10:00:00.000Z --confirmed-site foo.atlassian.net
expect_rc "sprint --start missing --end-date -> exit 2" 2
stderr_has "sprint --start missing end-date: diagnostic" "requires --end-date"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprint --start 2300 --end-date 2026-08-02T10:00:00.000Z --confirmed-site foo.atlassian.net
expect_rc "sprint --start missing --start-date -> exit 2" 2
stderr_has "sprint --start missing start-date: diagnostic" "requires --start-date"

section "jira.sh — sprint --close: body is EXACTLY {state:closed}"

reset_curl_stub
set_stub_response 1 '{"id":2300,"state":"closed","name":"Cycle 2","originBoardId":826}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprint --close 2300 --confirmed-site foo.atlassian.net
expect_rc "sprint --close -> exit 0" 0
file_has "sprint --close: POST /rest/agile/1.0/sprint/2300" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/agile/1.0/sprint/2300"
SP_CLOSE_KEYS=$(jq -cS 'keys' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "sprint --close: body is exactly {state}" "$SP_CLOSE_KEYS" '["state"]'
SP_CLOSE_STATE=$(jq -r '.state' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "sprint --close: state=closed" "$SP_CLOSE_STATE" "closed"
stdout_has "sprint --close: machine state line" "JIRA_SPRINT_STATE=closed"

section "jira.sh — sprint write: mode mutual-exclusion, foreign-flag + date-format + id guards (NO network)"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprint --create --close --board 826 --name X --confirmed-site foo.atlassian.net
expect_rc "sprint: two write modes -> exit 2" 2
stderr_has "sprint: two write modes diagnostic" "exactly one write mode"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprint 2300 --delete --confirmed-site foo.atlassian.net
expect_rc "sprint: foreign --delete mode -> exit 2" 2
stderr_has "sprint: foreign --delete diagnostic" "are not sprint modes"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprint --create --name X --confirmed-site foo.atlassian.net
expect_rc "sprint --create missing --board -> exit 2" 2
stderr_has "sprint --create missing board: diagnostic" "requires --board"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprint --create --board 826 --confirmed-site foo.atlassian.net
expect_rc "sprint --create missing --name -> exit 2" 2
stderr_has "sprint --create missing name: diagnostic" "requires --name"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprint --create --board abc --name X --confirmed-site foo.atlassian.net
expect_rc "sprint --create non-numeric --board -> exit 2" 2
stderr_has "sprint --create bad board: diagnostic" "invalid --board"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprint --create --board 826 --name X --start-date 2026-07-26 --confirmed-site foo.atlassian.net
expect_rc "sprint --create bad --start-date (date, no time) -> exit 2" 2
stderr_has "sprint --create bad start-date: diagnostic" "invalid --start-date"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprint --create --board 826 --name X --end-date "not-a-date" --confirmed-site foo.atlassian.net
expect_rc "sprint --create bad --end-date -> exit 2" 2
stderr_has "sprint --create bad end-date: diagnostic" "invalid --end-date"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprint --update abc --name X --confirmed-site foo.atlassian.net
expect_rc "sprint --update non-numeric id -> exit 2" 2
stderr_has "sprint --update bad id: diagnostic" "invalid sprint id"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprint --update 2300 --confirmed-site foo.atlassian.net
expect_rc "sprint --update with no fields -> exit 2" 2
stderr_has "sprint --update no fields: diagnostic" "at least one field"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprint --create --board 826 --name X --confirmed-site foo.atlassian.net PROJ-1
expect_rc "sprint --create with a stray positional -> exit 2" 2
stderr_has "sprint --create stray positional: diagnostic" "takes no positional"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprint --close 2300 --name X --confirmed-site foo.atlassian.net
expect_rc "sprint --close with a field -> exit 2" 2
stderr_has "sprint --close with a field: diagnostic" "takes no fields"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprint 2300 --goal "x" --confirmed-site foo.atlassian.net
expect_rc "sprint read with a write-only flag -> exit 2" 2
stderr_has "sprint read with write flag: diagnostic" "did you mean a write mode"

# A guard must make ZERO network calls — the usage error fires before dispatch.
reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprint --start 2300 --start-date 2026-07-26T10:00:00.000Z --confirmed-site foo.atlassian.net
expect_rc "sprint --start guard fires before any network -> exit 2" 2
equals "sprint --start guard: no curl call was made" "$(call_count)" "0"

section "jira.sh — sprint --start: a 4xx WRITE surfaces the server's error body to stderr"

# A sprint WRITE that the server rejects (e.g. starting a sprint that is not in
# the 'future' state) must fail non-zero AND surface Jira's own error body — the
# same handle_http_status path the READ commands use, applied to a write.
reset_curl_stub
set_stub_response 1 '{"errorMessages":["Sprint can only be started from the future state"]}' 400
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprint --start 2300 --start-date 2026-07-26T10:00:00.000Z --end-date 2026-08-02T10:00:00.000Z \
		--confirmed-site foo.atlassian.net
expect_rc "sprint --start on a bad server state -> exit 1" 1
stderr_has "sprint --start 4xx: HTTP code in diagnostic" "HTTP 400"
stderr_has "sprint --start 4xx: Jira's own error body surfaced" "Sprint can only be started from the future state"

section "jira.sh — sprint --create: a leading-zero --board is a clean usage error, not a jq abort"

# A leading-zero numeric id ("0826") is JSON-invalid as an integer literal; fed to
# merge_int_field's `jq --argjson` it would abort jq mid-body. validate_numeric_id
# now rejects it up front as a usage error (exit 2) BEFORE any body build or
# network call — a clean failure, never jq's own exit code.
reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprint --create --board 0826 --name X --confirmed-site foo.atlassian.net
expect_rc "sprint --create leading-zero --board -> exit 2 (usage, before any body build)" 2
stderr_has "sprint --create leading-zero board: diagnostic" "invalid --board"
equals "sprint --create leading-zero board: no network call was made" "$(call_count)" "0"

section "jira.sh — agile backlog <board>: issues envelope"

AGILE_BACKLOG='{"expand":"x","startAt":0,"maxResults":50,"total":1,"issues":[{"key":"PSWS-500","fields":{"summary":"backlog item","status":{"name":"Backlog"},"assignee":null}}]}'
reset_curl_stub
set_stub_response 1 "$AGILE_BACKLOG" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" backlog 826 --confirmed-site foo.atlassian.net
expect_rc "backlog -> exit 0" 0
stdout_has "backlog: issue-envelope header" "1 issue(s):"
stdout_has "backlog: renders the item" "PSWS-500"
file_has "backlog: hits /board/<id>/backlog" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/agile/1.0/board/826/backlog?startAt=0&maxResults=50"

section "jira.sh — agile epics <board>: values envelope with isLast and NO total"

# The epic element carries key/name/summary/done; the envelope has isLast but
# NO `total` — the exact quirk that breaks a total-only pagination loop.
AGILE_EPICS='{"maxResults":50,"startAt":0,"isLast":true,"values":[{"id":91591,"key":"PSWS-469","self":"x","name":"Auth epic","summary":"s","color":{"key":"c"},"done":false},{"id":91592,"key":"PSWS-470","self":"x","name":"Billing epic","summary":"s","color":{"key":"c"},"done":true}]}'
reset_curl_stub
set_stub_response 1 "$AGILE_EPICS" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" epics 826 --confirmed-site foo.atlassian.net
expect_rc "epics -> exit 0" 0
stdout_has "epics: header counts both" "2 epic(s):"
stdout_has "epics: renders epic key" "PSWS-469"
stdout_has "epics: renders done flag" "[done true]"
file_has "epics: hits /board/<id>/epic" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/agile/1.0/board/826/epic?startAt=0&maxResults=50"

reset_curl_stub
set_stub_response 1 '{"maxResults":50,"startAt":0,"total":0,"isLast":true,"values":[]}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" epics 826 --confirmed-site foo.atlassian.net
expect_rc "epics: empty set -> exit 0" 0
stdout_has "epics: empty set renders 'No epics.'" "No epics."

section "jira.sh — agile epic <id> --issues: issues envelope"

AGILE_EPIC_ISSUES='{"expand":"x","startAt":0,"maxResults":50,"total":1,"issues":[{"key":"PSWS-471","fields":{"summary":"epic child","status":{"name":"In Progress"},"assignee":null}}]}'
reset_curl_stub
set_stub_response 1 "$AGILE_EPIC_ISSUES" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" epic 91591 --issues --confirmed-site foo.atlassian.net
expect_rc "epic --issues -> exit 0" 0
stdout_has "epic --issues: issue-envelope header" "1 issue(s):"
stdout_has "epic --issues: renders the child" "PSWS-471"
file_has "epic --issues: hits /epic/<id>/issue" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/agile/1.0/epic/91591/issue?startAt=0&maxResults=50"

reset_curl_stub
set_stub_response 1 "$AGILE_EPIC_ISSUES" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" epic 91591 --issues --json --confirmed-site foo.atlassian.net
expect_rc "epic --issues --json -> exit 0" 0
equals "epic --issues --json: {issues:[...]} collected" "$(printf '%s' "$CUR_OUT" | jq -r '.issues | length')" "1"

# ---- THE load-bearing pagination tests: FULL resolution across BOTH shapes ---
section "jira.sh — agile epics: MULTI-PAGE via isLast (NO total) resolves the FULL set, not page 1"

# Page 1: isLast:false and NO `total` at all -> a total-only loop would spin or
# stop wrong; the isLast:false must drive a second fetch.
AGILE_EPICS_P1=$(jq -nc '{maxResults:50,startAt:0,isLast:false,values:[range(1;51) | {id:(.), key:("PSWS-\(.)"), name:"e", summary:"s", done:false}]}')
AGILE_EPICS_P2=$(jq -nc '{maxResults:50,startAt:50,isLast:true,values:[range(51;61) | {id:(.), key:("PSWS-\(.)"), name:"e", summary:"s", done:false}]}')
reset_curl_stub
set_stub_response 1 "$AGILE_EPICS_P1" 200
set_stub_response 2 "$AGILE_EPICS_P2" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" epics 826 --json --confirmed-site foo.atlassian.net
expect_rc "epics multi-page (isLast, no total) -> exit 0" 0
equals "epics multi-page: BOTH pages fetched (isLast:false drove page 2)" "$(call_count)" "2"
equals "epics multi-page: ALL 60 collected, not just page-1's 50" "$(printf '%s' "$CUR_OUT" | jq -r '.values | length')" "60"
stdout_has "epics multi-page: a page-2 epic (PSWS-60) is present" "PSWS-60"

section "jira.sh — agile issues envelope: MULTI-PAGE via total resolves the FULL set"

AGILE_ISSUES_P1=$(jq -nc '{startAt:0,maxResults:50,total:97,issues:[range(1;51) | {key:("PSWS-\(.)"), fields:{summary:"s", status:{name:"Open"}, assignee:null}}]}')
AGILE_ISSUES_P2=$(jq -nc '{startAt:50,maxResults:50,total:97,issues:[range(51;98) | {key:("PSWS-\(.)"), fields:{summary:"s", status:{name:"Open"}, assignee:null}}]}')
reset_curl_stub
set_stub_response 1 "$AGILE_ISSUES_P1" 200
set_stub_response 2 "$AGILE_ISSUES_P2" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" backlog 826 --json --confirmed-site foo.atlassian.net
expect_rc "backlog multi-page (total) -> exit 0" 0
equals "backlog multi-page: BOTH pages fetched" "$(call_count)" "2"
equals "backlog multi-page: ALL 97 collected across pages" "$(printf '%s' "$CUR_OUT" | jq -r '.issues | length')" "97"
stdout_has "backlog multi-page: a page-2 issue (PSWS-97) is present" "PSWS-97"

section "jira.sh — agile --limit: an EXPLICIT cap is honored (never a silent over-fetch)"

reset_curl_stub
# The engine caps the REQUEST's maxResults to the remaining need and stops
# paging once the cap is reached (it relies on the server honoring maxResults,
# exactly like the existing search path — it does not truncate client-side).
# The fixture models a server that honors maxResults=10 (a 10-row page) while
# STILL reporting total:97 (more exist beyond the cap) — so the load-bearing
# proof is that only ONE page is fetched despite the larger total, and the
# request carried maxResults=10, never a silent over-fetch to exhaustion.
AGILE_ISSUES_LIM=$(jq -nc '{startAt:0,maxResults:10,total:97,issues:[range(1;11) | {key:("PSWS-\(.)"), fields:{summary:"s", status:{name:"Open"}, assignee:null}}]}')
set_stub_response 1 "$AGILE_ISSUES_LIM" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" backlog 826 --limit 10 --json --confirmed-site foo.atlassian.net
expect_rc "backlog --limit 10 -> exit 0" 0
equals "backlog --limit: only ONE page fetched despite total:97 (cap stopped paging)" "$(call_count)" "1"
equals "backlog --limit: exactly the capped 10 rows kept" "$(printf '%s' "$CUR_OUT" | jq -r '.issues | length')" "10"
file_has "backlog --limit: maxResults request capped to the remaining need (10)" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/agile/1.0/board/826/backlog?startAt=0&maxResults=10"

section "jira.sh — agile: id/flag validation (numeric ids, allow-listed --type/--state) -> exit 2"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" board PSWS-1 --confirmed-site foo.atlassian.net
expect_rc "board: non-numeric id -> exit 2" 2
stderr_has "board: non-numeric id diagnostic" "invalid board id"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprint abc --confirmed-site foo.atlassian.net
expect_rc "sprint: non-numeric id -> exit 2" 2
stderr_has "sprint: non-numeric id diagnostic" "invalid sprint id"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" epic 91x --issues --confirmed-site foo.atlassian.net
expect_rc "epic: non-numeric id -> exit 2" 2
stderr_has "epic: non-numeric id diagnostic" "invalid epic id"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" epic 91591 --confirmed-site foo.atlassian.net
expect_rc "epic: missing --issues -> exit 2" 2
stderr_has "epic: missing --issues diagnostic" "requires --issues"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" boards --type bogus --confirmed-site foo.atlassian.net
expect_rc "boards: bad --type -> exit 2" 2
stderr_has "boards: bad --type diagnostic" "invalid --type"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" boards --project 'bad key' --confirmed-site foo.atlassian.net
expect_rc "boards: invalid --project -> exit 2" 2
stderr_has "boards: invalid --project diagnostic" "invalid project key"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprints 826 --state bogus --confirmed-site foo.atlassian.net
expect_rc "sprints: bad --state -> exit 2" 2
stderr_has "sprints: bad --state diagnostic" "invalid --state"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprints 826 --state active,bogus --confirmed-site foo.atlassian.net
expect_rc "sprints: one bad element in a --state CSV -> exit 2" 2
stderr_has "sprints: bad --state CSV element diagnostic" "invalid --state"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprints 826 --state active, --confirmed-site foo.atlassian.net
expect_rc "sprints: trailing-comma --state CSV (empty element) -> exit 2" 2
stderr_has "sprints: trailing-comma --state CSV diagnostic" "invalid --state"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" boards PSWS-1 --confirmed-site foo.atlassian.net
expect_rc "boards: stray positional -> exit 2" 2
stderr_has "boards: stray positional diagnostic" "takes no positional argument"

# ===========================================================================
# regression: the existing seven commands still parse/dispatch unchanged
# ===========================================================================
section "jira.sh — regression: pre-existing + new commands still recognized (-h short-circuits before dispatch, so this proves recognition, not routing)"

for pre_existing_command in view search workflow create comment transition update version component attach bulk boards board sprints sprint backlog epics epic; do
	run nocurl sh "$JIRA" "$pre_existing_command" -h
	expect_rc "regression: '$pre_existing_command -h' still exits 0 (command still recognized)" 0
	stdout_has "regression: '$pre_existing_command -h' still prints usage" "Usage"
done

# ===========================================================================
# preconditions: curl / jq absent
# ===========================================================================
section "jira.sh — preconditions"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" view PROJ-1 --confirmed-site foo.atlassian.net
expect_rc "curl absent -> exit 1" 1
stderr_has "curl absent: diagnostic" "curl is not installed"

run nojq "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" view PROJ-1 --confirmed-site foo.atlassian.net
expect_rc "jq absent -> exit 1" 1
stderr_has "jq absent: diagnostic" "jq is not installed"

# ===========================================================================
# Summary
# ===========================================================================
printf '\n%d tests, %d failed\n' "$TESTS_RUN" "$TESTS_FAIL"
[ "$TESTS_FAIL" -eq 0 ]
