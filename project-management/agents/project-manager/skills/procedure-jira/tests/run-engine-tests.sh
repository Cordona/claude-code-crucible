#!/usr/bin/env sh
#
# run-engine-tests.sh — zero-dependency POSIX test harness for jira.sh: the
#                        engine core + view/search/workflow.
#
# WHY a hand-rolled harness (not bats): same rationale as the sibling
# tests/run-tests.sh (md-to-adf.sh) and procedure-gh-issues/tests/run-tests.sh
# — the whole point of this suite is "runs on any machine with no
# dependencies beyond jq". Requiring bats-core would contradict that.
#
# The runner primitives and the curl stub live in tests/lib/harness.sh and
# tests/lib/curl-stub.sh, dot-sourced by all three Jira suites; this file owns
# only its own PATH-toolbox selector map and its assertions.
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
SCRIPTS_DIR=$(cd "$TESTS_DIR/../skill/scripts" && pwd)
JIRA="$SCRIPTS_DIR/jira.sh"

# Shared harness mechanics (runner primitives + the curl stub) — one copy for
# all three Jira suites; see lib/harness.sh's header for what stays local.
# shellcheck source=SCRIPTDIR/lib/harness.sh
. "$TESTS_DIR/lib/harness.sh"
# shellcheck source=SCRIPTDIR/lib/curl-stub.sh
. "$TESTS_DIR/lib/curl-stub.sh"

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
#
# dirname/readlink/realpath/basename are DELIBERATELY ABSENT, and that absence
# is a load-bearing regression guard, not an oversight: jira.sh resolves
# skill/lib/ and md-to-adf.sh from its own $0 with pure parameter expansion
# (see its Portability header), and a future regression to
# `SCRIPT_DIR=$(dirname "$0")` must break this suite loudly instead of passing
# green. Adding any of the four back here silently voids that claim.
# ---------------------------------------------------------------------------
harness_init "$WORK"
for t in sh mktemp sed grep tr cat rm chmod cp mv tail mkdir date; do
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
for t in sh mktemp sed grep tr cat rm chmod cp mv tail mkdir jq; do
	link_tool "$FIXEDDATE_TOOLBOX" "$t"
done
cat >"$FIXEDDATE_TOOLBOX/date" <<'FIXED_DATE_STUB'
#!/usr/bin/env sh
# test stub: ignore args, always emit one fixed UTC stamp so two writes collide
printf '20260725T000000Z\n'
FIXED_DATE_STUB
chmod +x "$FIXEDDATE_TOOLBOX/date"

# The canned-response-queue curl stub (lib/curl-stub.sh owns the mechanism).
init_curl_stub "$STUBCURL_DIR" "$WORK"

# run SELECTOR [VAR=VALUE...] COMMAND... — the PATH-toolbox selector map, the
# one part of the runner that is genuinely per-suite. Everything else lives in
# lib/harness.sh's harness_run.
run() {
	selector=$1; shift
	case "$selector" in
		full)      r_path="$STUBCURL_DIR:$TOOLBOX" ;;
		nocurl)    r_path="$TOOLBOX" ;;
		nojq)      r_path="$STUBCURL_DIR:$NOJQ_TOOLBOX" ;;
		fixedtime) r_path="$STUBCURL_DIR:$FIXEDDATE_TOOLBOX" ;;
		*) printf 'FATAL: bad run() selector: %s\n' "$selector" >&2; exit 1 ;;
	esac
	harness_run "$r_path" "$@"
}

# ---------------------------------------------------------------------------
# Shared diagnostic needles
#
# PRIORITY_SCOPE_DIAG — jira.sh's --priority foreign-flag refusal (asserted at
# four sites below: view, and bulk's transition/comment/ordering cases; the
# transition site lives in the sibling run-write-tests.sh, which defines its own
# copy because the two suites are separate processes with no shared state).
#
# The `error: ` prefix is LOAD-BEARING, not decoration. Every exit-2 guard dumps
# the full usage() text to stderr BEFORE its diagnostic, and usage.sh's file-
# header COMMENT already documents this exact scoping rule in near-identical
# prose (not the printed usage() heredoc itself, which carries no "only valid"
# text today) — so if that comment's wording ever migrates into the heredoc, a
# needle made of the bare sentence alone would become satisfiable by the usage
# dump, proving only "some guard exited 2", not "THIS guard fired". Only
# runtime.sh's error() writer emits the `<prog>: error: <msg>` form; usage()
# can never carry it, today or after such a migration. The same prefix is what
# makes the stderr_not_has ordering assertion below meaningful: absence of the
# sentence is only evidence when usage()'s copy of it cannot satisfy the needle.
# ---------------------------------------------------------------------------
PRIORITY_SCOPE_DIAG="error: --priority is only valid with create, update, and bulk --op update"

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
argv_log_has_token "argv log DOES contain -K (the config-file handoff)" "-K"

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

# jira.sh's --priority scoping block keys off the COMMAND NAME, not off the
# read/write classification readonlygate.sh owns, so a PURE READ must refuse the
# flag exactly as a write command does. view is that read: `view PROJ-1` is
# otherwise fully valid here (well-shaped key, validator passes), so the exit 2
# can only come from the scoping block and not from an unrelated usage error.
#
# Runs under `full` (the stub curl IS on PATH) and asserts ZERO calls, so
# "refused before the network" is a real observation rather than an artifact of
# curl being unavailable.
section "jira.sh — view: a stray --priority is refused before any network call (--priority belongs to create/update/bulk --op update)"

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" view PROJ-1 --priority High --confirmed-site foo.atlassian.net
expect_rc "view + --priority -> exit 2" 2
stderr_has "view stray --priority: diagnostic names the three commands that DO support it" \
	"$PRIORITY_SCOPE_DIAG"
equals "view stray --priority: ZERO curl calls (the issue is never fetched)" "$(call_count)" "0"

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

# ---------------------------------------------------------------------------
# version --delete — DELETE /version/<id> with up to TWO OPTIONAL, INDEPENDENT
# reassignment query params (moveFixIssuesTo / moveAffectedIssuesTo). Mirrors
# the component --delete section below: a 204 No Content response, a machine
# line in human mode, a SYNTHESIZED body under --json.
#
# Every URL assertion here is argv_log_has_token (an exact-LINE match against
# the argv log), NOT file_has (a substring match). That is load-bearing for
# this command specifically: the query string is built by appending, so a
# substring assertion on ".../version/11751" would pass just as happily against
# ".../version/11751?" or ".../version/11751?&moveAffectedIssuesTo=11753". The
# exact-line form is what makes "no query string at all", "no dangling &" and
# "no doubled ?" real assertions rather than wishful ones.
#
# The three ids are DELIBERATELY DISTINCT (11751 deleted, 11752 fix target,
# 11753 affected target) so a mapping that swapped the two params — the other
# way this can silently break — fails instead of matching by coincidence.
# ---------------------------------------------------------------------------
section "jira.sh — version --delete: DELETE /version/<id>, no query string when no move flag is given"

reset_curl_stub
set_stub_response 1 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --delete --id 11751 --confirmed-site foo.atlassian.net
expect_rc "version --delete -> exit 0" 0
argv_log_has_token "version --delete: URL is EXACTLY /rest/api/3/version/11751 (no trailing '?')" "https://foo.atlassian.net/rest/api/3/version/11751"
argv_log_has_token "version --delete: uses DELETE" "DELETE"
file_not_has "version --delete: no moveFixIssuesTo when not given" "$CURL_STUB_ARGV_LOG" "moveFixIssuesTo"
file_not_has "version --delete: no moveAffectedIssuesTo when not given" "$CURL_STUB_ARGV_LOG" "moveAffectedIssuesTo"
stdout_has "version --delete: machine line names the deleted id" "JIRA_VERSION_DELETED=11751"

section "jira.sh — version --delete: ONE move flag opens the query with '?', never a dangling separator"

reset_curl_stub
set_stub_response 1 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --delete --id 11751 --move-fix-issues-to 11752 --confirmed-site foo.atlassian.net
expect_rc "version --delete --move-fix-issues-to -> exit 0" 0
argv_log_has_token "version --delete --move-fix-issues-to: URL is EXACTLY .../version/11751?moveFixIssuesTo=11752" "https://foo.atlassian.net/rest/api/3/version/11751?moveFixIssuesTo=11752"
file_not_has "version --delete --move-fix-issues-to: the untouched param is absent" "$CURL_STUB_ARGV_LOG" "moveAffectedIssuesTo"

# The SECOND param given ALONE is the dangling-separator case: it is the one
# whose branch also emits the '&' joiner, so a joiner emitted unconditionally
# (rather than only when a first param already landed) produces `?&moveAffec…`.
# The exact-line match below is what rejects that, and a doubled '?' with it.
reset_curl_stub
set_stub_response 1 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --delete --id 11751 --move-affected-issues-to 11753 --confirmed-site foo.atlassian.net
expect_rc "version --delete --move-affected-issues-to -> exit 0" 0
argv_log_has_token "version --delete --move-affected-issues-to ALONE: URL is EXACTLY .../version/11751?moveAffectedIssuesTo=11753 (no leading '&', no doubled '?')" "https://foo.atlassian.net/rest/api/3/version/11751?moveAffectedIssuesTo=11753"
file_not_has "version --delete --move-affected-issues-to: the untouched param is absent" "$CURL_STUB_ARGV_LOG" "moveFixIssuesTo"

section "jira.sh — version --delete: BOTH move flags join with exactly one '&', in fix-then-affected order"

reset_curl_stub
set_stub_response 1 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --delete --id 11751 --move-fix-issues-to 11752 --move-affected-issues-to 11753 \
	--confirmed-site foo.atlassian.net
expect_rc "version --delete with BOTH move flags -> exit 0" 0
argv_log_has_token "version --delete both flags: URL is EXACTLY .../version/11751?moveFixIssuesTo=11752&moveAffectedIssuesTo=11753" "https://foo.atlassian.net/rest/api/3/version/11751?moveFixIssuesTo=11752&moveAffectedIssuesTo=11753"

section "jira.sh — version --delete --json: SYNTHESIZES a body (the 204 has none to pass through)"

reset_curl_stub
set_stub_response 1 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --delete --id 11751 --confirmed-site foo.atlassian.net --json
expect_rc "version --delete --json -> exit 0" 0
# One compact, key-sorted compare pins the WHOLE synthesized object — the shape
# (exactly {id,deleted}, identical to component --delete's), the id's JSON
# STRING type, and the deleted flag's JSON BOOLEAN type — in a single
# diagnosable assertion. Parsing $CUR_OUT with jq at all is also what proves
# the empty 204 body was never fed to a parser.
VER_DELETE_JSON=$(printf '%s' "$CUR_OUT" | jq -cS '.')
equals "version --delete --json: SYNTHESIZED body is exactly {id:\"11751\",deleted:true}" "$VER_DELETE_JSON" '{"deleted":true,"id":"11751"}'

# ---------------------------------------------------------------------------
# version --delete's TWO OPT-IN pre-write safety nets: `--plan`/`--dry-run`
# (disclose, write nothing) and `--project KEY` (refuse unless the version
# really belongs to KEY). Both are backed by resolve_version_owner's TWO
# read-only GETs — /version/<id> for the name + numeric projectId, then
# /project/<projectId> for the KEY a human actually reads.
#
# WHY THE METHOD SEQUENCE IS THE LOAD-BEARING ASSERTION HERE, and not a URL
# one: the version GET and the DELETE address the SAME url
# (.../rest/api/3/version/11751), so no URL assertion can tell "read it" from
# "deleted it" apart. The ordered METHOD sequence can, and it is the only
# thing that proves --plan short-circuited BEFORE the write rather than after
# it, and that the cross-check refused BEFORE the write rather than alongside
# it. Every case below therefore pins the full sequence, not just a count.
# ---------------------------------------------------------------------------

# request_method_sequence -> the HTTP methods of the last run's curl calls, in
# call order, joined by "/" (e.g. "GET/GET/DELETE"). http.sh's jira_curl always
# passes the method as the argv token immediately following `-X`, and the stub
# logs one argv token per line — so "the line after each `-X` line" IS the
# method, in call order, with no parsing of the surrounding CALL_<n> markers.
request_method_sequence() {
	sed -n '/^-X$/{n;p;}' "$CURL_STUB_ARGV_LOG" | tr '\n' '/' | sed 's|/$||'
}

# The owning project is reported by /version/<id> ONLY as a numeric projectId,
# which is exactly why a second GET exists; the two ids are deliberately
# distinct (version 11751, project 10042) so a mix-up cannot pass by accident.
VERSION_OWNER_BODY='{"id":"11751","name":"1.2.0","projectId":10042}'
VERSION_OWNER_PROJECT_BODY='{"id":"10042","key":"PSWS","name":"Platform Services"}'

# EVERY case below queues a 204 as its THIRD response, including the ones that
# must not write at all. That is deliberate and load-bearing: with no third
# response the stub errors out, so a guard that stopped working would fail the
# run for the wrong reason and the "no DELETE" assertions would be propped up by
# the fixture rather than by the code. With the 204 queued, a missing
# short-circuit or a missing cross-check produces a CLEAN, successful delete —
# and these assertions are the only thing standing in its way.

section "jira.sh — version --delete --plan: TWO read-only GETs, ZERO writes, plan disclosed"

reset_curl_stub
set_stub_response 1 "$VERSION_OWNER_BODY" 200
set_stub_response 2 "$VERSION_OWNER_PROJECT_BODY" 200
set_stub_response 3 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --delete --id 11751 --plan --confirmed-site foo.atlassian.net
expect_rc "version --delete --plan -> exit 0" 0
equals "version --delete --plan: exactly TWO curl calls (the owner resolve, nothing more)" "$(call_count)" "2"
equals "version --delete --plan: the two calls are GET/GET — the DELETE never happened" \
	"$(request_method_sequence)" "GET/GET"
argv_log_has_token "version --delete --plan: first read is GET /version/11751" "https://foo.atlassian.net/rest/api/3/version/11751"
argv_log_has_token "version --delete --plan: second read is GET /project/10042 (the key comes from the numeric projectId)" "https://foo.atlassian.net/rest/api/3/project/10042"
stdout_has "version --delete --plan: discloses the resolved name AND owning project" \
	'would delete version 11751 "1.2.0" in project PSWS'
stdout_has "version --delete --plan: discloses the exact request that WOULD be sent" \
	"DELETE https://foo.atlassian.net/rest/api/3/version/11751"
stdout_has "version --delete --plan: ends on the engine-wide dry-run line" "NOTHING WAS WRITTEN"
stdout_not_has "version --delete --plan: NO success machine line (nothing was deleted)" "JIRA_VERSION_DELETED"

reset_curl_stub
set_stub_response 1 "$VERSION_OWNER_BODY" 200
set_stub_response 2 "$VERSION_OWNER_PROJECT_BODY" 200
set_stub_response 3 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --delete --id 11751 --plan --json --confirmed-site foo.atlassian.net
expect_rc "version --delete --plan --json -> exit 0" 0
equals "version --delete --plan --json: still exactly TWO GETs, no write" \
	"$(request_method_sequence)" "GET/GET"
# One key-sorted compare pins the WHOLE synthesized plan object — the op tag, the
# plan/willWrite pair a consent gate machine-checks, and every resolved field —
# in a single diagnosable assertion, the same idiom the --json delete above uses.
VER_PLAN_JSON=$(printf '%s' "$CUR_OUT" | jq -cS '.')
equals "version --delete --plan --json: SYNTHESIZED plan object is exactly the documented shape" \
	"$VER_PLAN_JSON" \
	'{"id":"11751","name":"1.2.0","op":"version-delete","plan":true,"project":"PSWS","url":"https://foo.atlassian.net/rest/api/3/version/11751","willWrite":false}'

section "jira.sh — version --delete --plan + the move flags: the disclosed URL is the one that WOULD be sent"

# THE CONTRACT A PREVIEW MAKES: the URL it discloses is the URL the real request
# would carry — reassignment query and all. That only holds because the query is
# built BEFORE the --plan short-circuit; move the construction after it and the
# plan still prints, still says NOTHING WAS WRITTEN, and still exits 0, while
# quietly disclosing a bare .../version/11751 for a delete that would in fact
# re-point every issue's fixVersions. A caller reading that plan would approve a
# reassignment they were never shown.
#
# Each case pins the FULL URL as one substring, so a plan that dropped a param,
# swapped the two, or emitted a dangling separator fails here — the same
# exact-shape discipline the non-plan cases above apply to the argv log. The
# GET/GET method sequence alongside it is what proves the preview is still a
# preview: with a 204 queued as call 3, a lost short-circuit would delete for
# real and read as "GET/GET/DELETE".

reset_curl_stub
set_stub_response 1 "$VERSION_OWNER_BODY" 200
set_stub_response 2 "$VERSION_OWNER_PROJECT_BODY" 200
set_stub_response 3 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --delete --id 11751 --plan --move-fix-issues-to 11752 --confirmed-site foo.atlassian.net
expect_rc "version --delete --plan --move-fix-issues-to -> exit 0" 0
equals "version --delete --plan --move-fix-issues-to: still GET/GET — the reassigning DELETE never happened" \
	"$(request_method_sequence)" "GET/GET"
stdout_has "version --delete --plan --move-fix-issues-to: the disclosed URL carries the real ?moveFixIssuesTo=11752" \
	"DELETE https://foo.atlassian.net/rest/api/3/version/11751?moveFixIssuesTo=11752"

reset_curl_stub
set_stub_response 1 "$VERSION_OWNER_BODY" 200
set_stub_response 2 "$VERSION_OWNER_PROJECT_BODY" 200
set_stub_response 3 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --delete --id 11751 --plan --move-affected-issues-to 11753 --confirmed-site foo.atlassian.net
expect_rc "version --delete --plan --move-affected-issues-to -> exit 0" 0
equals "version --delete --plan --move-affected-issues-to: still GET/GET — the reassigning DELETE never happened" \
	"$(request_method_sequence)" "GET/GET"
stdout_has "version --delete --plan --move-affected-issues-to ALONE: the disclosed URL opens with '?', not a dangling '&'" \
	"DELETE https://foo.atlassian.net/rest/api/3/version/11751?moveAffectedIssuesTo=11753"

reset_curl_stub
set_stub_response 1 "$VERSION_OWNER_BODY" 200
set_stub_response 2 "$VERSION_OWNER_PROJECT_BODY" 200
set_stub_response 3 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --delete --id 11751 --plan --move-fix-issues-to 11752 --move-affected-issues-to 11753 \
	--confirmed-site foo.atlassian.net
expect_rc "version --delete --plan with BOTH move flags -> exit 0" 0
equals "version --delete --plan both move flags: still GET/GET — the reassigning DELETE never happened" \
	"$(request_method_sequence)" "GET/GET"
# Same fix-then-affected order, same single '&', as the non-plan both-flags case
# above pins on the wire — which is the whole point: one construction, two
# consumers, so the preview cannot drift from the request.
stdout_has "version --delete --plan both move flags: the disclosed URL joins both params with exactly one '&', fix before affected" \
	"DELETE https://foo.atlassian.net/rest/api/3/version/11751?moveFixIssuesTo=11752&moveAffectedIssuesTo=11753"

# The machine-readable half of the same contract: a consent gate reads `url` from
# the synthesized object, not the human line, so it is pinned in full too.
reset_curl_stub
set_stub_response 1 "$VERSION_OWNER_BODY" 200
set_stub_response 2 "$VERSION_OWNER_PROJECT_BODY" 200
set_stub_response 3 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --delete --id 11751 --plan --json --move-fix-issues-to 11752 --move-affected-issues-to 11753 \
	--confirmed-site foo.atlassian.net
expect_rc "version --delete --plan --json with BOTH move flags -> exit 0" 0
equals "version --delete --plan --json both move flags: still GET/GET, no write" \
	"$(request_method_sequence)" "GET/GET"
VER_PLAN_MOVE_JSON=$(printf '%s' "$CUR_OUT" | jq -cS '.')
equals "version --delete --plan --json both move flags: the synthesized object's url carries BOTH query params" \
	"$VER_PLAN_MOVE_JSON" \
	'{"id":"11751","name":"1.2.0","op":"version-delete","plan":true,"project":"PSWS","url":"https://foo.atlassian.net/rest/api/3/version/11751?moveFixIssuesTo=11752&moveAffectedIssuesTo=11753","willWrite":false}'

section "jira.sh — version --delete --project: the ownership cross-check, under --plan and for real"

reset_curl_stub
set_stub_response 1 "$VERSION_OWNER_BODY" 200
set_stub_response 2 "$VERSION_OWNER_PROJECT_BODY" 200
set_stub_response 3 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --delete --id 11751 --plan --project PSWS --confirmed-site foo.atlassian.net
expect_rc "version --delete --plan --project MATCHING -> exit 0" 0
equals "version --delete --plan --project MATCHING: ONE owner resolve serves both features (still just GET/GET)" \
	"$(request_method_sequence)" "GET/GET"
stdout_has "version --delete --plan --project MATCHING: the plan is still disclosed" \
	'would delete version 11751 "1.2.0" in project PSWS'
stdout_has "version --delete --plan --project MATCHING: states nothing was written" "NOTHING WAS WRITTEN"

# The cross-check must fire EVEN UNDER --plan: a mismatch means the plan would
# describe a version the caller did not mean, and printing it would read as
# confirmation of exactly the wrong thing.
reset_curl_stub
set_stub_response 1 "$VERSION_OWNER_BODY" 200
set_stub_response 2 "$VERSION_OWNER_PROJECT_BODY" 200
set_stub_response 3 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --delete --id 11751 --plan --project OTHER --confirmed-site foo.atlassian.net
expect_rc "version --delete --plan --project MISMATCHED -> exit 1" 1
equals "version --delete --plan --project MISMATCHED: still only the two reads, no write" \
	"$(request_method_sequence)" "GET/GET"
stderr_has "version --delete --plan --project MISMATCHED: diagnostic names BOTH the real owner and the asserted one" \
	"version 11751 belongs to project PSWS, not --project OTHER"
stdout_not_has "version --delete --plan --project MISMATCHED: the plan is NOT printed (it would confirm the wrong version)" \
	"would delete version 11751"
stdout_not_has "version --delete --plan --project MISMATCHED: no dry-run footer either" "NOTHING WAS WRITTEN"

reset_curl_stub
set_stub_response 1 "$VERSION_OWNER_BODY" 200
set_stub_response 2 "$VERSION_OWNER_PROJECT_BODY" 200
set_stub_response 3 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --delete --id 11751 --project PSWS --confirmed-site foo.atlassian.net
expect_rc "version --delete --project MATCHING (a real delete) -> exit 0" 0
equals "version --delete --project MATCHING: THREE requests" "$(call_count)" "3"
equals "version --delete --project MATCHING: in GET/GET/DELETE order — both reads precede the write" \
	"$(request_method_sequence)" "GET/GET/DELETE"
stdout_has "version --delete --project MATCHING: machine line names the deleted id" "JIRA_VERSION_DELETED=11751"

reset_curl_stub
set_stub_response 1 "$VERSION_OWNER_BODY" 200
set_stub_response 2 "$VERSION_OWNER_PROJECT_BODY" 200
set_stub_response 3 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --delete --id 11751 --project OTHER --confirmed-site foo.atlassian.net
expect_rc "version --delete --project MISMATCHED (a real delete attempt) -> exit 1" 1
equals "version --delete --project MISMATCHED: only the two reads happened" "$(call_count)" "2"
# The whole point of the flag: the destructive request must never be issued at
# all, not merely be reported as failed afterwards. A 204 IS queued as call 3
# above, so a cross-check that ran too late would exit 0 here and this would fail.
argv_log_not_has_token "version --delete --project MISMATCHED: the DELETE was NEVER sent" "DELETE"
stderr_has "version --delete --project MISMATCHED: refusal diagnostic" \
	"version 11751 belongs to project PSWS, not --project OTHER — refusing to delete it"
stdout_not_has "version --delete --project MISMATCHED: no success machine line" "JIRA_VERSION_DELETED"

# REGRESSION GUARD for the DEFAULT path: neither opt-in flag given, the delete
# must behave EXACTLY as it did before --plan/--project existed — one request,
# the DELETE, and NO owner-resolution read bolted on. Pinning the full method
# sequence to a bare "DELETE" is what proves that: any GET added to this path
# (an unconditional resolve, a "cheap" pre-read) makes the sequence
# "GET/GET/DELETE" and fails here, where a call-count-only assertion could be
# quietly relaxed later.
section "jira.sh — version --delete with NEITHER opt-in flag: unchanged single-request default"

reset_curl_stub
set_stub_response 1 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --delete --id 11751 --confirmed-site foo.atlassian.net
expect_rc "version --delete (no --plan, no --project) -> exit 0" 0
equals "version --delete default: exactly ONE request" "$(call_count)" "1"
equals "version --delete default: that request is the DELETE and nothing precedes it" \
	"$(request_method_sequence)" "DELETE"
argv_log_has_token "version --delete default: URL is EXACTLY /rest/api/3/version/11751" "https://foo.atlassian.net/rest/api/3/version/11751"
file_not_has "version --delete default: no /project/ lookup was added to this path" "$CURL_STUB_ARGV_LOG" "/rest/api/3/project/"
stdout_has "version --delete default: machine line unchanged" "JIRA_VERSION_DELETED=11751"

section "jira.sh — version --delete: the owner resolve fails CLOSED on an unusable response"

# The resolve exists to make a delete SAFER, so an owner it cannot establish
# must be exit 1 — never a softer "unknown" that proceeds to the DELETE anyway.
reset_curl_stub
set_stub_response 1 '{"id":"11751","name":"1.2.0"}' 200
set_stub_response 2 "$VERSION_OWNER_PROJECT_BODY" 200
set_stub_response 3 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --delete --id 11751 --plan --confirmed-site foo.atlassian.net
expect_rc "version --delete --plan, version response carries NO projectId -> exit 1" 1
equals "version --delete --plan, no projectId: stops after the first read" "$(call_count)" "1"
argv_log_not_has_token "version --delete --plan, no projectId: the DELETE was NEVER sent" "DELETE"
stderr_has "version --delete --plan, no projectId: diagnostic" \
	"could not determine which project version 11751 belongs to"

reset_curl_stub
set_stub_response 1 "$VERSION_OWNER_BODY" 200
set_stub_response 2 '{"id":"10042","name":"Platform Services"}' 200
set_stub_response 3 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --delete --id 11751 --project PSWS --confirmed-site foo.atlassian.net
expect_rc "version --delete --project, project response carries NO key -> exit 1" 1
equals "version --delete --project, no key: both reads ran, nothing more" "$(request_method_sequence)" "GET/GET"
argv_log_not_has_token "version --delete --project, no key: the DELETE was NEVER sent" "DELETE"
stderr_has "version --delete --project, no key: diagnostic names the unhelpful project" \
	"project 10042 reported no key"

section "jira.sh — version: mode-flag + argument validation"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --project PSWS --confirmed-site foo.atlassian.net
expect_rc "version with ZERO mode flags -> exit 2" 2
stderr_has "version zero modes: diagnostic" "exactly one mode"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --list --create --project PSWS --name X --confirmed-site foo.atlassian.net
expect_rc "version with TWO mode flags -> exit 2" 2
stderr_has "version two modes: diagnostic" "exactly one mode"

# `version --list --delete` names TWO of version's OWN modes. It used to be
# rejected by NAME ("--delete is not a version mode") because --delete was then
# a component-only flag; --delete is now a version mode in its own right, so the
# exactly-one-mode count is what rejects the pair. The property under test is
# unchanged — you cannot give two version modes at once — only the diagnostic
# that enforces it, which is why this asserts the new message rather than being
# dropped. Shaped like the sibling `component --list --delete --id` case below.
run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --list --delete --id 11751 --project PSWS --confirmed-site foo.atlassian.net
expect_rc "version --list + --delete (TWO modes) -> exit 2" 2
stderr_has "version --list --delete: diagnostic names the exactly-one-mode rule" "exactly one mode"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --delete --create --project PSWS --name X --id 11751 --confirmed-site foo.atlassian.net
expect_rc "version --delete + --create (TWO modes) -> exit 2" 2
stderr_has "version --delete --create: diagnostic names the exactly-one-mode rule" "exactly one mode"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --delete --confirmed-site foo.atlassian.net
expect_rc "version --delete without --id -> exit 2" 2
stderr_has "version --delete no id: diagnostic names --id as required" "--update/--release/--archive/--delete requires --id"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --delete --id abc --confirmed-site foo.atlassian.net
expect_rc "version --delete with a NON-NUMERIC --id -> exit 2" 2
stderr_has "version --delete non-numeric id: diagnostic" "invalid --id (must be a numeric version id)"

# --project is OPTIONAL on --delete, so only its SHAPE is checked — but it IS
# checked, and at VALIDATION time. A malformed key left unchecked would reach
# the ownership comparison instead and fail as "belongs to another project"
# (exit 1), dressing a caller's own typo up as a Jira fact. Exit 2 AND zero
# curl calls together are what prove it was rejected before the network, which
# neither assertion establishes on its own.
reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --delete --id 11751 --project psws --confirmed-site foo.atlassian.net
expect_rc "version --delete with a MALFORMED --project -> exit 2 (usage), not exit 1 (ownership)" 2
stderr_has "version --delete malformed project: diagnostic" "invalid project key: psws"
equals "version --delete malformed project: ZERO curl calls (rejected before the owner resolve)" "$(call_count)" "0"

# The two reassignment targets are INDEPENDENT guards in the validator — each
# is numeric-checked and mode-checked on its own — so each is asserted on its
# own. A shared assertion would let one guard be deleted and still pass.
run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --delete --id 11751 --move-fix-issues-to abc --confirmed-site foo.atlassian.net
expect_rc "version --delete NON-NUMERIC --move-fix-issues-to -> exit 2" 2
stderr_has "version non-numeric move-fix target: diagnostic names THAT flag" "invalid --move-fix-issues-to (must be a numeric version id)"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --delete --id 11751 --move-affected-issues-to abc --confirmed-site foo.atlassian.net
expect_rc "version --delete NON-NUMERIC --move-affected-issues-to -> exit 2" 2
stderr_has "version non-numeric move-affected target: diagnostic names THAT flag" "invalid --move-affected-issues-to (must be a numeric version id)"

# Both reassignment flags are meaningful ONLY while deleting: paired with any
# other mode they must fail loud, never be silently ignored while that mode runs.
run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --list --project PSWS --move-fix-issues-to 11752 --confirmed-site foo.atlassian.net
expect_rc "version --list + --move-fix-issues-to -> exit 2" 2
stderr_has "version move-fix-issues-to misuse: diagnostic" "--move-fix-issues-to is only valid with version --delete"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --list --project PSWS --move-affected-issues-to 11753 --confirmed-site foo.atlassian.net
expect_rc "version --list + --move-affected-issues-to -> exit 2" 2
stderr_has "version move-affected-issues-to misuse: diagnostic" "--move-affected-issues-to is only valid with version --delete"

# --project means something in exactly THREE of version's six modes: it NAMES the
# project for --list/--create, and it is --delete's opt-in ownership cross-check.
# --update/--release/--archive address the version by --id alone and never read
# it, so an unguarded --project there would be SILENTLY dropped — and now that
# --project is a documented safety net on the sibling --delete, a caller has real
# reason to believe it bit. The guard is ONE call covering all three modes, but
# each mode is asserted on its own: a mode dropped from the guard's condition
# would otherwise still pass on the strength of its siblings.
#
# All three run under the `full` selector and assert ZERO calls, so "refused
# before the network" is observed rather than assumed.
for version_unscoped_mode in --update --release --archive; do
	reset_curl_stub
	run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
		sh "$JIRA" version "$version_unscoped_mode" --id 11751 --name X --project PSWS \
		--confirmed-site foo.atlassian.net
	expect_rc "version $version_unscoped_mode + --project -> exit 2" 2
	stderr_has "version $version_unscoped_mode --project: diagnostic names the three modes that DO read --project" \
		"--project is only valid with version --list/--create/--delete"
	equals "version $version_unscoped_mode --project: ZERO curl calls (the PUT is never sent)" "$(call_count)" "0"
done

# --plan/--dry-run is the SECOND of --delete's two opt-in pre-write safety nets,
# and the graver one to lose: --update/--release/--archive implement NO preview,
# so a silently-ignored --plan means a caller who believes they asked for a dry
# run gets a REAL write instead. Same one-guard-covering-three-modes shape as the
# --project loop above, and asserted the same way — per mode, so a mode dropped
# from the condition cannot ride on its siblings.
#
# BOTH spellings are exercised because two distinct pieces of production code
# must hold for the guard to bite: jira.sh's parser folding `--dry-run` into the
# same OPT_PLAN carrier as `--plan`, and the guard reading that carrier. The
# --plan cases alone would stay green if the `--dry-run` alias were dropped from
# the parser, leaving the friendlier spelling silently ignored — exactly the
# failure this guard exists to prevent. The nested loop is scenario
# parameterization over (spelling x mode); every label names both, so a red test
# identifies the exact pair.
#
# All six run under the `full` selector and assert ZERO calls, so "refused before
# the network" is observed rather than assumed.
for version_plan_spelling in --plan --dry-run; do
	for version_unpreviewable_mode in --update --release --archive; do
		reset_curl_stub
		run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
			sh "$JIRA" version "$version_unpreviewable_mode" --id 11751 --name X "$version_plan_spelling" \
			--confirmed-site foo.atlassian.net
		expect_rc "version $version_unpreviewable_mode + $version_plan_spelling -> exit 2" 2
		stderr_has "version $version_unpreviewable_mode $version_plan_spelling: diagnostic names the only version mode that previews, and warns this one writes for REAL" \
			"--plan/--dry-run is only valid with version --delete among the version modes — version --update/--release/--archive would write for REAL"
		equals "version $version_unpreviewable_mode $version_plan_spelling: ZERO curl calls (the PUT is never sent)" "$(call_count)" "0"
	done
done

# Regression guard for the guard: the LEGITIMATE --release (neither --plan nor
# --project) must still clear validation. Run WITHOUT the stub curl for the same
# reason as the component --update guard below — reaching the curl precondition
# is the observable proof that validate_version_args returned instead of
# exiting 2.
run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --release --id 11751 --confirmed-site foo.atlassian.net
expect_rc "version --release WITHOUT --plan/--project -> still passes validation (exit 1 at the tool check, not exit 2)" 1
stderr_has "version --release plain: got PAST validation to the curl precondition" "curl is not installed"

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

# The mirror image of `version --list --move-issues-to`'s rejection above: the
# two reassignment flags are VERSION --delete flags, and cmd_component never
# reads either. Without these guards `component --delete --id N
# --move-fix-issues-to M` would exit 0 having deleted the component and SILENTLY
# dropped the reassignment — destructive AND silent. Each flag is its own guard,
# so each gets its own case: a shared one would let either be deleted and pass.
run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" component --delete --id 10500 --move-fix-issues-to 10501 --confirmed-site foo.atlassian.net
expect_rc "component --delete + foreign --move-fix-issues-to -> exit 2" 2
stderr_has "component move-fix-issues-to misuse: diagnostic names the owning command" "--move-fix-issues-to is only valid with version --delete"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" component --delete --id 10500 --move-affected-issues-to 10501 --confirmed-site foo.atlassian.net
expect_rc "component --delete + foreign --move-affected-issues-to -> exit 2" 2
stderr_has "component move-affected-issues-to misuse: diagnostic names the owning command" "--move-affected-issues-to is only valid with version --delete"

# Distinct code path from the two above: this guard is NOT gated on component's
# active mode, so a non-delete mode must be rejected by the SAME diagnostic —
# never allowed to run its own mode while silently ignoring the foreign flag
# (the `component --list --release` failure shape, one flag over).
run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" component --list --project PSWS --move-fix-issues-to 10501 --confirmed-site foo.atlassian.net
expect_rc "component --list + foreign --move-fix-issues-to (guard is mode-independent) -> exit 2" 2
stderr_has "component --list move-fix-issues-to misuse: same diagnostic as --delete" "--move-fix-issues-to is only valid with version --delete"

# `version --delete`'s TWO pre-write safety nets are NOT implemented by
# `component --delete`, which is destructive and irreversible — so each must be
# REFUSED rather than silently ignored. --plan is the graver of the two: a
# caller who believes they asked for a preview and instead gets a real delete
# has been actively misled by the tool. Each flag is its own guard (a 0/1 carrier
# vs. a string carrier — see require_flag_off's header on why they cannot share
# one), so each gets its own case.
#
# Both run under the `full` selector (the stub curl IS on PATH) and assert ZERO
# calls, so "refused before the network" is a real observation rather than an
# artifact of curl being unavailable — the same shape the attach cases below use.
reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" component --delete --id 10500 --plan --confirmed-site foo.atlassian.net
expect_rc "component --delete + --plan -> exit 2" 2
stderr_has "component --delete --plan: diagnostic names the only --delete that previews, and warns this one is for REAL" \
	"--plan/--dry-run is only valid with version --delete among the delete commands — component --delete would delete for REAL"
equals "component --delete --plan: ZERO curl calls (the component is NOT deleted)" "$(call_count)" "0"

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" component --delete --id 10500 --project PSWS --confirmed-site foo.atlassian.net
expect_rc "component --delete + --project -> exit 2" 2
# --project IS a component flag (--list/--create take it), so the diagnostic must
# name THOSE modes — not another command, as the move-flag guards above do.
stderr_has "component --delete --project: diagnostic names component's OWN modes that take --project" \
	"--project is only valid with component --list/--create"
equals "component --delete --project: ZERO curl calls (the component is NOT deleted)" "$(call_count)" "0"

# --update carries the SAME --project guard as --delete above, for the same
# reason and with the same diagnostic: --project NAMES the project in only two
# of this command's four modes (--list/--create), and --update addresses the
# component by --id alone. Unguarded, `component --update --id N --project
# WRONGKEY` would exit 0 having edited whatever project's component N really
# belongs to, with the scope the caller stated never checked against anything.
# The key is well-formed but WRONG on purpose: --update never runs
# validate_project_key, so a malformed key would prove nothing about this
# guard — only a valid-shaped, unread key does.
reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" component --update --id 10500 --name X --project WRONGKEY --confirmed-site foo.atlassian.net
expect_rc "component --update + --project -> exit 2" 2
stderr_has "component --update --project: diagnostic names component's OWN modes that take --project" \
	"--project is only valid with component --list/--create"
equals "component --update --project: ZERO curl calls (the PUT is never sent)" "$(call_count)" "0"

# ORDERING, pinned deliberately: the --project guard sits AFTER the
# at-least-one-field check, so an --update carrying ONLY a bogus --project is
# told what it is actually missing rather than being lectured about --project.
# Both branches error-then-exit, so exactly ONE diagnostic reaches stderr —
# asserting the missing-field one therefore proves the ORDER, not merely that
# the message exists. Swap the two blocks in validate_component_args and this
# case fails while the case above still passes.
reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" component --update --id 10500 --project WRONGKEY --confirmed-site foo.atlassian.net
expect_rc "component --update + --project + NO field flag -> exit 2" 2
stderr_has "component --update --project no field: the MISSING-FIELD diagnostic wins over the --project one" \
	"component --update requires at least one field to change"
equals "component --update --project no field: ZERO curl calls" "$(call_count)" "0"

# Regression guard for the guard: the LEGITIMATE --update (a field flag, no
# --project) must still clear validation. Run WITHOUT the stub curl so the run
# stops at the first precondition AFTER validation — reaching "curl is not
# installed" (exit 1) is the observable proof that validate_component_args
# returned rather than exiting 2, which a happy-path exit-0 case cannot
# distinguish from a validator that never ran at all.
run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" component --update --id 10500 --name X --confirmed-site foo.atlassian.net
expect_rc "component --update --name WITHOUT --project -> still passes validation (exit 1 at the tool check, not exit 2)" 1
stderr_has "component --update no project: got PAST validation to the curl precondition" "curl is not installed"

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

section "jira.sh — version --delete: a non-2xx surfaces the HTTP code + Jira's own error message"

# DELETE /version/<id> documents FOUR statuses (Atlassian's published OpenAPI
# spec, operation deleteVersion), and the three failures are distinct scenarios
# — covered one per case below, because collapsing them hides which one the
# script actually handles.
#
# 404 means exactly one thing here: "Returned if the version is not found" —
# the id does not exist. It is NOT the permission-denied response; that is 401
# (next case). The status check must fire BEFORE the 204 "no body to parse"
# branch — otherwise a failed delete would be reported as a successful one.
reset_curl_stub
set_stub_response 1 '{"errorMessages":["The version with id 11751 does not exist"]}' 404
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --delete --id 11751 --confirmed-site foo.atlassian.net
expect_rc "version --delete 404 (version not found) -> exit 1" 1
stderr_has "version --delete 404: HTTP code in diagnostic" "HTTP 404"
stderr_has "version --delete 404: Jira's own error message surfaced" "does not exist"
stdout_not_has "version --delete 404: NO success machine line on the error path" "JIRA_VERSION_DELETED"

# 401 is the PERMISSION-DENIED response: the spec folds "the authentication
# credentials are incorrect" and "the user does not have the required
# permissions" into this one status, so an account without "Administer
# Projects" on the version's project gets 401 — never 404. This is the failure
# a real caller hits with a project-scoped token, so the wording Jira sends is
# the only thing that tells them WHY, and it must reach stderr.
reset_curl_stub
set_stub_response 1 '{"errorMessages":["You do not have permission to edit versions in this project."]}' 401
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --delete --id 11751 --confirmed-site foo.atlassian.net
expect_rc "version --delete 401 (permission denied) -> exit 1" 1
stderr_has "version --delete 401: HTTP code in diagnostic" "HTTP 401"
stderr_has "version --delete 401: Jira's own permission message surfaced" \
	"You do not have permission to edit versions in this project."
stdout_not_has "version --delete 401: NO success machine line on the error path" "JIRA_VERSION_DELETED"

# 400 ("Returned if the request is invalid") is reachable through a move target
# only the SERVER can reject: the spec requires the replacement version to be in
# the same project as the deleted one and to not BE the deleted one — neither of
# which jira.sh can know locally, its own guard checking numeric shape only.
# The body is the OTHER ErrorCollection shape — a per-field `errors` MAP instead
# of `errorMessages` — so this also pins handle_http_status's `errors` branch,
# which no other case in this suite reaches.
reset_curl_stub
set_stub_response 1 '{"errorMessages":[],"errors":{"moveFixIssuesTo":"The version with id 10999 is not in the same project as the version being deleted."}}' 400
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --delete --id 11751 --move-fix-issues-to 10999 --confirmed-site foo.atlassian.net
expect_rc "version --delete 400 (invalid move target) -> exit 1" 1
stderr_has "version --delete 400: HTTP code in diagnostic" "HTTP 400"
stderr_has 'version --delete 400: per-field errors MAP surfaced as "field: message"' \
	"moveFixIssuesTo: The version with id 10999 is not in the same project"
stdout_not_has "version --delete 400: NO success machine line on the error path" "JIRA_VERSION_DELETED"

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

# The three reassignment targets belong to version/component --delete. attach
# shares their OPT_* carriers but never reads one, so an unguarded
# `attach --delete --id N --move-…-to M` would exit 0 having DELETED the
# attachment and silently dropped the flag — destructive AND quiet, the worst
# pairing. Each flag is a SEPARATE guard naming a DIFFERENT owning command, so
# each gets its own case: a shared or looped assertion would let one guard be
# deleted, or one message be wrong, and still pass.
#
# Every case runs under the `full` selector (the stub curl IS on PATH) and
# asserts ZERO calls, so "rejected before the network" is a real observation
# rather than an artifact of curl being unavailable.
reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach --delete --id 303980 --move-fix-issues-to 11752 --confirmed-site foo.atlassian.net
expect_rc "attach --delete + --move-fix-issues-to -> exit 2" 2
stderr_has "attach --move-fix-issues-to: diagnostic names THAT flag and its owning command" \
	"--move-fix-issues-to is only valid with version --delete"
equals "attach --move-fix-issues-to: ZERO curl calls (the attachment is NOT deleted)" "$(call_count)" "0"

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach --delete --id 303980 --move-affected-issues-to 11753 --confirmed-site foo.atlassian.net
expect_rc "attach --delete + --move-affected-issues-to -> exit 2" 2
stderr_has "attach --move-affected-issues-to: diagnostic names THAT flag and its owning command" \
	"--move-affected-issues-to is only valid with version --delete"
equals "attach --move-affected-issues-to: ZERO curl calls (the attachment is NOT deleted)" "$(call_count)" "0"

# --move-issues-to is component --delete's, not version's — the diagnostic must
# name the command that actually accepts it, never a sibling's.
reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach --delete --id 303980 --move-issues-to 20501 --confirmed-site foo.atlassian.net
expect_rc "attach --delete + --move-issues-to -> exit 2" 2
stderr_has "attach --move-issues-to: diagnostic names component --delete as the owner, not version" \
	"--move-issues-to is only valid with component --delete"
equals "attach --move-issues-to: ZERO curl calls (the attachment is NOT deleted)" "$(call_count)" "0"

# `attach --delete` is the third destructive delete in the engine and implements
# neither of `version --delete`'s pre-write safety nets, so it carries component
# --delete's identical pair of guards. The diagnostics are NOT identical to
# component's, and deliberately so: each names the command it is really talking
# about, so a caller is never pointed at a sibling's behaviour.
reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach --delete --id 303980 --plan --confirmed-site foo.atlassian.net
expect_rc "attach --delete + --plan -> exit 2" 2
stderr_has "attach --delete --plan: diagnostic names attach --delete itself as the one that would delete for REAL" \
	"--plan/--dry-run is only valid with version --delete among the delete commands — attach --delete would delete for REAL"
equals "attach --delete --plan: ZERO curl calls (the attachment is NOT deleted)" "$(call_count)" "0"

# attach addresses an issue by KEY and an attachment by --id; it has no
# project-scoped mode at all, so --project can only ever be a mistake here — and
# the diagnostic says exactly that rather than naming modes attach does not have.
reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach --delete --id 303980 --project PSWS --confirmed-site foo.atlassian.net
expect_rc "attach --delete + --project -> exit 2" 2
stderr_has "attach --delete --project: diagnostic states attach addresses its target by KEY/--id, never by project" \
	"--project is only valid with project-scoped commands (attach addresses its target by KEY/--id)"
equals "attach --delete --project: ZERO curl calls (the attachment is NOT deleted)" "$(call_count)" "0"

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

# --- --priority is scoped to `--op update` ---------------------------------
# bulk reaches cmd_update — and therefore reads OPT_PRIORITY — ONLY for
# `--op update`. On every other op the flag would be accepted and SILENTLY
# DROPPED, so jira.sh's central scoping block refuses it there through the
# engine's own require_foreign_flag_unset. The `--op update` half of this
# contract is covered further down ("bulk --op update --priority: accepted ALONE
# by the guard, disclosed by --plan, and actually sent").
#
# Each op gets its OWN case rather than a loop: the ops carry different required
# args (--status vs --text-file), and one shared/looped assertion would let a
# single op's rejection regress while the section stayed green.
section "jira.sh — bulk --priority on a NON-update op: refused (exit 2) before any network call"

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" bulk --op transition --keys "PSWS-1,PSWS-2" --status Done --priority High --confirmed-site foo.atlassian.net
expect_rc "bulk --op transition + --priority -> exit 2" 2
stderr_has "bulk transition stray --priority: diagnostic names the three commands that DO support it" \
	"$PRIORITY_SCOPE_DIAG"
equals "bulk transition stray --priority: ZERO curl calls (nothing was transitioned)" "$(call_count)" "0"

# The --text-file below is a REAL readable file, so the exit 2 cannot be coming
# from cmd_bulk's readability guard instead of the scoping block.
BULK_PRIORITY_MD="$WORK/bulk-priority-comment.md"
printf 'note\n' >"$BULK_PRIORITY_MD"

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" bulk --op comment --keys "PSWS-1" --text-file "$BULK_PRIORITY_MD" --priority High --confirmed-site foo.atlassian.net
expect_rc "bulk --op comment + --priority -> exit 2" 2
stderr_has "bulk comment stray --priority: diagnostic names the three commands that DO support it" \
	"$PRIORITY_SCOPE_DIAG"
equals "bulk comment stray --priority: ZERO curl calls (no comment was posted)" "$(call_count)" "0"

# --- ORDERING: per-command validation still runs FIRST ---------------------
# The scoping block sits AFTER the per-command validate_*_args dispatch on
# purpose: a caller whose REAL mistake is `--op frobnicate` must read THAT
# diagnostic, not a lecture about --priority. An `expect_rc 2` alone would pass
# whichever guard fired, so BOTH halves are asserted — the --op message present,
# the --priority message ABSENT.
#
# --keys IS given here on purpose, exactly as --status is on the transition case
# in run-write-tests.sh: it makes the invocation valid in every respect EXCEPT
# the --op, so the only two guards in play are the ones this ordering claim is
# about. Without it, "the --op error wins" would also be riding on
# validate_bulk_args' own INTERNAL order (its --op case at cmd-bulk.sh:163 runs
# before its set-selector requirement at :174) — an ordering this test never
# claims to assert, and whose reversal would silently change which diagnostic
# this case is really observing.
section "jira.sh — bulk: an invalid --op reports the --op error, NOT the --priority scoping error (validation order)"

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" bulk --op frobnicate --keys "PSWS-1" --priority High --confirmed-site foo.atlassian.net
expect_rc "bulk invalid --op + --priority -> exit 2" 2
stderr_has "bulk invalid --op + --priority: the --op diagnostic is the one reported" \
	"invalid --op 'frobnicate' (must be transition|comment|update)"
stderr_not_has "bulk invalid --op + --priority: the --priority scoping diagnostic is NOT reported" \
	"$PRIORITY_SCOPE_DIAG"
equals "bulk invalid --op + --priority: ZERO curl calls" "$(call_count)" "0"

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

# --- --priority flows through the update verb AND its own hand-kept surfaces --
# bulk delegates to cmd_update, so --priority reaches the wire for free. bulk's
# own at-least-one-field guard and its --plan disclosure both now derive from
# cmd-update.sh's update_field_summary()/has_update_field_request() — a single
# shared source, not two hand-maintained copies — and this test guards that the
# shared list actually reaches both surfaces for a real field, not just that
# they happen to agree today.
section "jira.sh — bulk --op update --priority: accepted ALONE by the guard, disclosed by --plan, and actually sent"

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" bulk --op update --priority High --keys "PSWS-1,PSWS-2" --plan --confirmed-site foo.atlassian.net
expect_rc "bulk --plan update --priority alone -> exit 0 (not the 'at least one field' usage error)" 0
equals "bulk --plan update --priority: ZERO curl calls" "$(call_count)" "0"
stdout_has "bulk --plan update --priority: the field-summary NAMES the priority change" "update field(s): priority"
stdout_has "bulk --plan update --priority: states nothing was written" "NOTHING WAS WRITTEN"

reset_curl_stub
set_stub_response 1 '' 204
set_stub_response 2 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$WORK/noconfig" \
	sh "$JIRA" bulk --op update --priority High --keys "PSWS-1,PSWS-2" --confirmed-site foo.atlassian.net
expect_rc "bulk real update --priority -> exit 0" 0
equals "bulk real update --priority: 2 calls (one PUT per issue)" "$(call_count)" "2"
# The stdout channel is asserted BEFORE the body reads: a regression that makes
# the per-issue verb fail leaves no call-N.body at all, and reading one first
# would abort the suite before this line ever ran.
stdout_has "bulk real update --priority: both issues reported succeeded" "JIRA_BULK_SUMMARY=2/2 succeeded"
BULK_PRIORITY_SENT=$(jq -c '.fields.priority' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "bulk real update --priority: PSWS-1's PUT body carries {name: High}" "$BULK_PRIORITY_SENT" '{"name":"High"}'
BULK_PRIORITY_SENT_2=$(jq -c '.fields.priority' "$CURL_STUB_BODY_LOG_DIR/call-2.body")
equals "bulk real update --priority: PSWS-2's PUT body carries it too" "$BULK_PRIORITY_SENT_2" '{"name":"High"}'

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
# Split-parity assertions (P1, P2, P4, P5)
#
# These cover gaps the split of jira.sh into 43 sourced units could silently
# open and that the pre-split suite had no reason to check. They assert the
# SHAPE of the split, not any command's behavior — the rest of this file
# already covers behavior.
# ===========================================================================
section "jira.sh — split parity (dispatcher identity, temp files, unit containment)"

# P1 — a usage error must still be prefixed with the DISPATCHER's own name.
# $PROG is ${0##*/}, so if a unit were ever EXECUTED instead of sourced the
# prefix would silently become that unit's filename ("cmd-view.sh: error: ...")
# and every caller that greps this prefix would break. Anchored deliberately:
# the harness's substring stderr_has would also match a mid-line occurrence.
run nocurl sh "$JIRA" bogus
TESTS_RUN=$((TESTS_RUN + 1))
if printf '%s\n' "$CUR_ERR" | grep -q '^jira\.sh: error:'; then
	pass "P1: a usage error is prefixed exactly 'jira.sh: error:'"
else
	fail "P1: a usage error is prefixed exactly 'jira.sh: error:'" "stderr was: $CUR_ERR"
fi

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" view not-a-key --confirmed-site foo.atlassian.net
TESTS_RUN=$((TESTS_RUN + 1))
if printf '%s\n' "$CUR_ERR" | grep -q '^jira\.sh: error:'; then
	pass "P1: a per-command validation error is prefixed exactly 'jira.sh: error:'"
else
	fail "P1: a per-command validation error is prefixed exactly 'jira.sh: error:'" "stderr was: $CUR_ERR"
fi

# P2 — the no-arg and -h paths must leave NO temp artifacts behind. Sourcing 43
# units runs more top-level code before argv parsing than the monolith did, so a
# unit that created a workdir or a credential config at LOAD time would leak one
# on every single --help.
count_jira_tmp_artifacts() {
	find "$WORK" -maxdepth 1 \
		\( -name 'jira.work.*' -o -name 'jira.curlconfig.*' \) 2>/dev/null |
		wc -l | tr -d ' '
}

run nocurl sh "$JIRA"
TESTS_RUN=$((TESTS_RUN + 1))
p2_leaked=$(count_jira_tmp_artifacts)
if [ "$p2_leaked" -eq 0 ]; then
	pass "P2: no-args leaves zero jira.work.*/jira.curlconfig.* temp files"
else
	fail "P2: no-args leaves zero jira.work.*/jira.curlconfig.* temp files" "found $p2_leaked under $WORK"
fi

run nocurl sh "$JIRA" -h
TESTS_RUN=$((TESTS_RUN + 1))
p2_leaked=$(count_jira_tmp_artifacts)
if [ "$p2_leaked" -eq 0 ]; then
	pass "P2: -h leaves zero jira.work.*/jira.curlconfig.* temp files"
else
	fail "P2: -h leaves zero jira.work.*/jira.curlconfig.* temp files" "found $p2_leaked under $WORK"
fi

# P4 — every command's validate_<cmd>_args() must ACCEPT a valid argument set
# (returning 0) AND REJECT an invalid one (exiting 2). The split turned one
# 513-line `case` into 26 functions, and a function that falls off its end
# returning the status of its last test would abort the dispatcher under
# `set -e` before the command ever ran. Each wrapper therefore ends with an
# explicit `return 0`, and this asserts all 26 do.
#
# EVERY ACCEPT CASE IS PAIRED WITH A REJECT CASE, deliberately: an accept-only
# set would pass in full against a validator gutted to `return 0`, which is the
# exact regression this gate exists to catch. The reject half proves the guard
# still fires; the accept half proves it does not over-fire.
#
# The driver sources the units exactly as jira.sh does and REPLAYS jira.sh's own
# OPT_* initializer block rather than keeping a hand-written copy of the
# defaults, so this test cannot drift from the engine it is checking. It brackets
# that block on the STABLE MARKER COMMENTS jira.sh carries (not on the names of
# the first and last variables, which a behaviour-preserving rename or reorder
# would silently invalidate — emptying the range and turning all 26 checks into
# unbound-variable noise), and it FAILS LOUDLY if the extraction comes back
# empty.
P4_DRIVER="$WORK/validate-driver.sh"
cat >"$P4_DRIVER" <<'P4_DRIVER_EOF'
#!/usr/bin/env sh
set -eu
p4_script_dir=$1
p4_case_file=$2
SCRIPT_DIR=$p4_script_dir
LIB_DIR="$p4_script_dir/../lib"
MD_TO_ADF="$p4_script_dir/md-to-adf.sh"
PROG=jira.sh
for p4_unit in "$LIB_DIR"/*.sh; do
	. "$p4_unit"
done
p4_opts=$(mktemp "${TMPDIR:-/tmp}/jira-p4-opts.XXXXXX")
sed -n '/OPT DEFAULTS BEGIN/,/OPT DEFAULTS END/p' "$p4_script_dir/jira.sh" >"$p4_opts"
# A non-empty extraction is the driver's own precondition: if the markers ever
# stop matching, say so in one clear line instead of failing 52 times with an
# unbound-variable error that names the wrong culprit.
if [ ! -s "$p4_opts" ]; then
	printf 'P4 DRIVER: the OPT DEFAULTS marker block in jira.sh extracted EMPTY\n' >&2
	rm -f "$p4_opts"
	exit 90
fi
. "$p4_opts"
rm -f "$p4_opts"
set +e
. "$p4_case_file"
p4_rc=$?
set -e
printf '%s\n' "$p4_rc"
P4_DRIVER_EOF

P4_FILE="$WORK/p4-attachment.txt"
printf 'x\n' >"$P4_FILE"

# p4_run COMMAND ASSIGNMENTS — write one case file and run the driver on it.
p4_run() {
	p4_case_file="$WORK/p4-case.sh"
	{
		printf 'COMMAND=%s\n' "$1"
		printf '%s\n' "$2"
		printf 'validate_%s_args\n' "$(printf '%s' "$1" | tr '-' '_')"
	} >"$p4_case_file"
	p4_fn="validate_$(printf '%s' "$1" | tr '-' '_')_args"
	run nocurl sh "$P4_DRIVER" "$SCRIPTS_DIR" "$p4_case_file"
}

# p4_accept COMMAND ASSIGNMENTS — the wrapper must return 0 for a VALID set.
p4_accept() {
	p4_run "$1" "$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [ "$CUR_RC" -eq 0 ] && [ "$CUR_OUT" = "0" ]; then
		pass "P4: $p4_fn accepts a valid argument set (\$? = 0)"
	else
		fail "P4: $p4_fn accepts a valid argument set (\$? = 0)" \
			"driver rc=$CUR_RC stdout='$CUR_OUT' stderr='$CUR_ERR'"
	fi
}

# p4_reject COMMAND ASSIGNMENTS WHY — the wrapper must exit 2 (usage error) for
# an INVALID set. The validators exit rather than return, so the exit status
# lands on the driver process itself; rc 90 is the driver's own marker-block
# precondition failure and is reported separately so it can never be mistaken
# for a validator verdict.
p4_reject() {
	p4_run "$1" "$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [ "$CUR_RC" -eq 2 ]; then
		pass "P4: $p4_fn rejects $3 (exit 2)"
	else
		fail "P4: $p4_fn rejects $3 (exit 2)" \
			"driver rc=$CUR_RC stdout='$CUR_OUT' stderr='$CUR_ERR'"
	fi
}

p4_accept view       'TICKET_KEY=PROJ-1'
p4_reject view       ':' 'a missing ticket key'
p4_accept search     'OPT_PROJECT=PROJ'
p4_reject search     ':' 'a filterless query'
p4_accept workflow   'TICKET_KEY=PROJ-1'
p4_reject workflow   'TICKET_KEY=not-a-key' 'a malformed ticket key'
p4_accept create     'OPT_PROJECT=PROJ
OPT_TITLE="A title"'
p4_reject create     'OPT_TITLE="A title"' 'a missing --project'
p4_accept comment    "TICKET_KEY=PROJ-1
OPT_TEXT_FILE=$P4_FILE"
p4_reject comment    'TICKET_KEY=PROJ-1' 'a missing --text-file'
p4_accept transition 'TICKET_KEY=PROJ-1
OPT_STATUS=Done'
p4_reject transition 'TICKET_KEY=PROJ-1' 'a missing --status'
p4_accept update     'TICKET_KEY=PROJ-1
OPT_TITLE="A title"'
p4_reject update     'OPT_TITLE="A title"' 'a missing ticket key'
p4_accept link       'TICKET_KEY=PROJ-1
OPT_TO=PROJ-2
OPT_LINK_TYPE=Blocks'
p4_reject link       'TICKET_KEY=PROJ-1
OPT_TO=PROJ-2' 'a missing --link-type'
p4_accept link-types ':'
p4_reject link-types 'TICKET_KEY=PROJ-1' 'a stray positional'
p4_accept children   'TICKET_KEY=PROJ-1'
p4_reject children   ':' 'a missing ticket key'
p4_accept discover   'TICKET_KEY=PROJ'
p4_reject discover   'TICKET_KEY=../../etc' 'a traversal-shaped project key'
p4_accept worklog    'TICKET_KEY=PROJ-1
OPT_TIME_SPENT=2h'
p4_reject worklog    'TICKET_KEY=PROJ-1' 'a missing --time-spent'
p4_accept watch      'TICKET_KEY=PROJ-1'
p4_reject watch      'TICKET_KEY=PROJ-1
OPT_LIST=1
OPT_REMOVE=1' 'mutually exclusive --list --remove'
p4_accept vote       'TICKET_KEY=PROJ-1'
p4_reject vote       'TICKET_KEY=PROJ-1
OPT_LIST=1
OPT_REMOVE=1' 'mutually exclusive --list --remove'
p4_accept version    'OPT_LIST=1
OPT_PROJECT=PROJ'
p4_reject version    'OPT_PROJECT=PROJ' 'no mode flag at all'
p4_accept component  'OPT_LIST=1
OPT_PROJECT=PROJ'
p4_reject component  'OPT_LIST=1
OPT_RELEASE=1
OPT_PROJECT=PROJ' 'a foreign (version) mode flag'
p4_accept attach     "TICKET_KEY=PROJ-1
OPT_FILES='$P4_FILE
'"
p4_reject attach     'TICKET_KEY=PROJ-1' 'no mode flag at all'
p4_accept bulk       'OPT_OP=transition
OPT_KEYS=PROJ-1
OPT_STATUS=Done'
p4_reject bulk       'OPT_KEYS=PROJ-1
OPT_STATUS=Done' 'a missing --op'
p4_accept boards     ':'
p4_reject boards     'TICKET_KEY=826' 'a stray positional'
p4_accept board      'TICKET_KEY=826'
p4_reject board      'TICKET_KEY=not-numeric' 'a non-numeric board id'
p4_accept sprints    'TICKET_KEY=826'
p4_reject sprints    'TICKET_KEY=826
OPT_STATE=bogus' 'an out-of-allow-list --state'
p4_accept sprint     'TICKET_KEY=2212'
p4_reject sprint     'TICKET_KEY=2212
OPT_CREATE=1
OPT_UPDATE=1' 'two write modes at once'
p4_accept backlog    'TICKET_KEY=826'
p4_reject backlog    'TICKET_KEY=not-numeric' 'a non-numeric board id'
p4_accept epics      'TICKET_KEY=826'
p4_reject epics      ':' 'a missing board id'
p4_accept epic       'TICKET_KEY=91591
OPT_ISSUES=1'
p4_reject epic       'TICKET_KEY=91591' 'a missing --issues'
p4_accept schedule   'OPT_TO_SPRINT=2212
OPT_KEYS=PROJ-1'
p4_reject schedule   'OPT_TO_SPRINT=2212
OPT_TO_BACKLOG=1
OPT_KEYS=PROJ-1' 'two target ops at once'

# P5 — every `curl` invocation must live in lib/http.sh, and there must be
# exactly three of them (jira_curl, jira_curl_multipart, resolve_media_uuid).
# This is the split's single most load-bearing structural claim: the transport's
# security properties (token off argv, host pinned, --proto '=https', no -L) are
# reviewed ONCE because there is only one place to review. A fourth call site
# anywhere else silently voids that.
#
# The gate matches the INVOCATION PATTERN — `curl` in command position followed
# by the start of an ARGUMENT — rather than the literal string 'curl -sS'. A
# future call written with an extra space, a reordered flag, or a different
# first option is still a fourth transport, and an exact-string gate would wave
# it through. Three shapes count as an argument start: an option (`-`), a
# quoted word (`"` or `'`), and an expansion (`$`). The last two exist because a
# call whose URL precedes every flag — `curl "$url" -o f` — is just as much a
# fourth transport as `curl -o f "$url"`, and a `-`-only matcher would miss it.
#
# Two normalizations run BEFORE the match:
#   * comment lines are stripped, so a unit header that TALKS about curl is not
#     miscounted as a call;
#   * line continuations are FOLDED, so a call split as `curl \` + flags on the
#     next line is seen as the single logical command it is. Without the fold,
#     that reformatting alone evades the gate — a false negative, the exact
#     opposite of what a structural guard may do.
# `command -v curl` (jira.sh's dependency probe) stays excluded by construction:
# what follows it is a redirection or end-of-line, never an argument start.
P5_LIB_DIR=$(cd "$SCRIPTS_DIR/../lib" && pwd)
P5_INVOCATION_RE='(^|[^A-Za-z0-9_])curl[[:space:]]+["$'"'"'-]'

# p5_fold_continuations — join each backslash-continued line with its successor,
# so a multi-line command is matched as one line. awk, not sed: folding needs an
# embedded newline in a substitution, which BSD and GNU sed spell differently.
p5_fold_continuations() {
	awk '
		{ p5_line = p5_line $0 }
		/\\$/  { sub(/\\$/, "", p5_line); next }
		       { print p5_line; p5_line = "" }
		END    { if (p5_line != "") print p5_line }
	'
}

# p5_invocations FILE -> that file's curl-invocation lines (comments stripped,
# continuations folded).
p5_invocations() {
	grep -v '^[[:space:]]*#' "$1" | p5_fold_continuations | grep -E "$P5_INVOCATION_RE" || true
}

P5_HITS=""
P5_COUNT=0
for p5_file in "$P5_LIB_DIR"/*.sh "$SCRIPTS_DIR"/*.sh; do
	[ -f "$p5_file" ] || continue
	p5_n=$(p5_invocations "$p5_file" | grep -c . | tr -d ' ')
	[ "$p5_n" -gt 0 ] || continue
	P5_COUNT=$((P5_COUNT + p5_n))
	P5_HITS="$P5_HITS $p5_file"
done
P5_HITS=${P5_HITS# }

TESTS_RUN=$((TESTS_RUN + 1))
if [ "$P5_COUNT" -eq 3 ]; then
	pass "P5: exactly 3 curl invocations across every unit"
else
	fail "P5: exactly 3 curl invocations across every unit" "found $P5_COUNT in: $P5_HITS"
fi

TESTS_RUN=$((TESTS_RUN + 1))
if [ "$P5_HITS" = "$P5_LIB_DIR/http.sh" ]; then
	pass "P5: every curl invocation lives in lib/http.sh"
else
	fail "P5: every curl invocation lives in lib/http.sh" "files with a hit: $P5_HITS"
fi

# The gate must itself be falsifiable: a synthetic unit carrying a curl call the
# gate is claimed to catch has to actually be counted. Without these probes, a
# matcher that stopped matching anything would report "exactly 3" forever — a
# broken analyzer looking identical to a clean tree. Each probe below is one
# rewriting a fourth transport could plausibly arrive in.
P5_PROBE="$WORK/p5-probe.sh"

# p5_probe_count TEXT -> how many curl invocations the gate finds in TEXT.
p5_probe_count() {
	printf '%s\n' "$1" >"$P5_PROBE"
	p5_invocations "$P5_PROBE" | grep -c . | tr -d ' '
}

# shellcheck disable=SC2016  # every probe below is literal shell TEXT written to a file, not an expansion this script wants performed
equals "P5: the gate counts a REFORMATTED curl invocation (and not the comment)" \
	"$(p5_probe_count '# a comment mentioning curl -sS must NOT be counted
p5_probe() { curl  --proto "=https" -sS -o /dev/null "$1"; }')" "1"

# shellcheck disable=SC2016  # see the SC2016 note on the first probe
equals "P5: the gate counts a curl invocation whose flags sit on a CONTINUATION line" \
	"$(p5_probe_count 'p5_probe() {
	curl \
		--proto "=https" \
		-sS -o /dev/null "$1"
}')" "1"

# shellcheck disable=SC2016  # see the SC2016 note on the first probe
equals "P5: the gate counts a curl invocation whose URL precedes every flag" \
	"$(p5_probe_count 'p5_probe() { curl "$1" -o /dev/null; }')" "1"

# The widened matcher must not swing the other way: `command -v curl` is the
# dependency probe every entry point runs, and counting it would report a fourth
# transport that does not exist — noise that trains the reader to ignore P5.
equals "P5: the gate does NOT count the command -v curl dependency probe" \
	"$(p5_probe_count 'command -v curl >/dev/null 2>&1 || { error "curl is not installed"; exit 1; }')" "0"

# ===========================================================================
# Summary
# ===========================================================================
printf '\n%d tests, %d failed\n' "$TESTS_RUN" "$TESTS_FAIL"
[ "$TESTS_FAIL" -eq 0 ]
