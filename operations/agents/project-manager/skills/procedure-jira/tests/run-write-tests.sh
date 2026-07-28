#!/usr/bin/env sh
#
# run-write-tests.sh — self-contained, zero-dependency POSIX test harness
#                       for jira.sh's Phase-2b WRITE commands: create,
#                       comment, transition, update.
#
# WHY a SIBLING file, not folded into run-engine-tests.sh: that harness is
# already 130 assertions covering the engine core + the three READ commands;
# folding four more commands' worth of scenarios into it would blur two
# genuinely separate concerns (read-path plumbing vs. write-path plumbing)
# into one file, hurting "a reader learns what the system does from the
# tests" (standard-testing). Same harness SHAPE, deliberately duplicated —
# see run-engine-tests.sh's own header for why a hand-rolled harness at all.
#
# Usage:  sh run-write-tests.sh              # run all tests
#         VERBOSE=1 sh run-write-tests.sh
#         (also runs green under dash: dash run-write-tests.sh)
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

WORK=$(mktemp -d "${TMPDIR:-/tmp}/jira-write-tests.XXXXXX")
TOOLBOX="$WORK/toolbox"          # real tools, curl NEVER here
STUBCURL_DIR="$WORK/stubcurl"    # ONLY the stub `curl`
mkdir -p "$TOOLBOX" "$STUBCURL_DIR" "$WORK/home" "$WORK/projects"

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Isolated PATH toolbox: symlink only the real tools jira.sh + md-to-adf.sh
# need. curl is NEVER here (it comes from the stub dir).
# ---------------------------------------------------------------------------
ORIG_PATH=$PATH
link_tool() {
	target_dir=$1
	tool_name=$2
	tool_path=$(PATH="$ORIG_PATH" command -v "$tool_name" 2>/dev/null || true)
	[ -n "$tool_path" ] || { printf 'FATAL: required tool not found: %s\n' "$tool_name" >&2; exit 1; }
	ln -s "$tool_path" "$target_dir/$tool_name"
}
for t in sh mktemp sed grep tr cat rm chmod cp dirname tail; do
	link_tool "$TOOLBOX" "$t"
done
link_tool "$TOOLBOX" jq

# ---------------------------------------------------------------------------
# The curl stub — a canned-response QUEUE, identical mechanism to
# run-engine-tests.sh's stub (see that file's header for the full rationale).
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
data_at=""
url=""
prev=""
for a in "$@"; do
	[ "$prev" = "-o" ] && out_file=$a
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

call_count() { cat "$CURL_STUB_COUNTER_FILE" 2>/dev/null || printf '0'; }

# call_body N -> the parsed JSON body jira.sh sent as the Nth call's --data @file.
call_body() { jq -c . "$CURL_STUB_BODY_LOG_DIR/call-$1.body"; }

# assert_no_leaked_workdir NAME — regression check: no jira.work.*
# dir survives under $WORK (jira.sh's TMPDIR for the run that just
# happened). Call right after a `run` whose command reaches jira_curl()
# from inside a `$(...)` subshell before the function's own ensure_workdir —
# exactly the leak class already fixed once in cmd_search and now also in
# cmd_comment/cmd_create (see those functions' own comments).
assert_no_leaked_workdir() {
	TESTS_RUN=$((TESTS_RUN + 1))
	leaked=$(find "$WORK" -maxdepth 1 -name 'jira.work.*' 2>/dev/null | wc -l | tr -d ' ')
	if [ "$leaked" -eq 0 ]; then
		pass "$1: no jira.work.* dir survives"
	else
		fail "$1: no jira.work.* dir survives" "found $leaked leaked dir(s) under $WORK"
	fi
}

# ---------------------------------------------------------------------------
# Runner primitives (identical shape to run-engine-tests.sh — see that file
# for the run() VAR=VALUE / env leading-assignment idiom).
# ---------------------------------------------------------------------------
TESTS_RUN=0
TESTS_FAIL=0
CUR_OUT=""
CUR_ERR=""
CUR_RC=0

run() {
	selector=$1; shift
	case "$selector" in
		full)   r_path="$STUBCURL_DIR:$TOOLBOX" ;;
		nocurl) r_path="$TOOLBOX" ;;
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

# ---------------------------------------------------------------------------
# Shared fixtures: a project config with custom fields + a workflow graph.
# ---------------------------------------------------------------------------
cat >"$WORK/projects/PROJ.json" <<'EOF'
{
  "key": "PROJ",
  "issue_types": ["Task", "Story", "Bug", "Sub-task"],
  "type_aliases": { "subtask": "Sub-task" },
  "subtask_types": ["Sub-task"],
  "subtask_parent_types": ["Story", "Task"],
  "custom_fields": {
    "acceptance_criteria": "customfield_16102",
    "review_notes": "customfield_12402",
    "developer": "customfield_25500"
  },
  "workflows": {
    "Task": {
      "Open": ["In Progress", "Closed"],
      "In Progress": ["Reviewing", "Open", "Closed"],
      "Reviewing": ["Done", "In Progress", "Closed"],
      "Done": ["Closed"],
      "Closed": []
    }
  }
}
EOF

# ===========================================================================
# create — usage errors
# ===========================================================================
section "jira.sh create — usage errors"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" create --title x --confirmed-site foo.atlassian.net
expect_rc "create without --project -> exit 2" 2
stderr_has "create without --project: diagnostic" "requires --project"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" create --project PROJ --confirmed-site foo.atlassian.net
expect_rc "create without --title -> exit 2" 2
stderr_has "create without --title: diagnostic" "requires --title"

# ===========================================================================
# create — the fields{} envelope
# ===========================================================================
section "jira.sh create — builds the REST fields{} envelope, description ADF merged via FILE"

DESC_FILE="$WORK/description.md"
printf '## Summary\n\nSome **bold** description text.\n' >"$DESC_FILE"

reset_curl_stub
set_stub_response 1 '{"id":"10001","key":"PROJ-101","self":"x"}' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$WORK/projects" \
	sh "$JIRA" create --project PROJ --title "New ticket" --description-file "$DESC_FILE" \
	--confirmed-site foo.atlassian.net
expect_rc "create with description -> exit 0" 0
stdout_has "create: prints JIRA_ISSUE_KEY" "JIRA_ISSUE_KEY=PROJ-101"
stdout_has "create: prints JIRA_ISSUE_URL" "JIRA_ISSUE_URL=https://foo.atlassian.net/browse/PROJ-101"

SENT_BODY=$(call_body 1)
equals "create: project.key" "$(printf '%s' "$SENT_BODY" | jq -r '.fields.project.key')" "PROJ"
equals "create: issuetype.name defaults to Task" "$(printf '%s' "$SENT_BODY" | jq -r '.fields.issuetype.name')" "Task"
equals "create: summary" "$(printf '%s' "$SENT_BODY" | jq -r '.fields.summary')" "New ticket"
equals "create: description is an ADF DOC OBJECT, not a string" \
	"$(printf '%s' "$SENT_BODY" | jq -r '.fields.description.type')" "doc"
DESC_TEXT=$(printf '%s' "$SENT_BODY" | jq -r '[.fields.description.content[].content[]?.text] | join(" ")')
TESTS_RUN=$((TESTS_RUN + 1))
case "$DESC_TEXT" in
	*"bold"*) pass "create: converted markdown content survives in the ADF" ;;
	*) fail "create: converted markdown content survives in the ADF" "got: $DESC_TEXT" ;;
esac

section "jira.sh create — custom fields (acceptance/review) land under fields{}, not top-level"

AC_FILE="$WORK/acceptance.md"
printf -- '- given X\n- when Y\n- then Z\n' >"$AC_FILE"

reset_curl_stub
set_stub_response 1 '{"id":"10002","key":"PROJ-102","self":"x"}' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$WORK/projects" \
	sh "$JIRA" create --project PROJ --title "With AC" --acceptance-file "$AC_FILE" \
	--confirmed-site foo.atlassian.net
expect_rc "create with --acceptance-file -> exit 0" 0
SENT_BODY=$(call_body 1)
equals "create: acceptance criteria under fields.customfield_16102" \
	"$(printf '%s' "$SENT_BODY" | jq -r '.fields.customfield_16102.type')" "doc"
equals "create: no stray top-level 'acceptance' key" \
	"$(printf '%s' "$SENT_BODY" | jq 'has("acceptance")')" "false"

section "jira.sh create — --review-file"

RN_FILE="$WORK/review.md"
printf 'Looks solid; one nit on error handling.\n' >"$RN_FILE"

reset_curl_stub
set_stub_response 1 '{"id":"10002b","key":"PROJ-1022","self":"x"}' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$WORK/projects" \
	sh "$JIRA" create --project PROJ --title "With review notes" --review-file "$RN_FILE" \
	--confirmed-site foo.atlassian.net
expect_rc "create with --review-file -> exit 0" 0
SENT_BODY=$(call_body 1)
equals "create: review notes under fields.customfield_12402" \
	"$(printf '%s' "$SENT_BODY" | jq -r '.fields.customfield_12402.type')" "doc"

section "jira.sh create — --acceptance-file with NO configured field fails loud (divergence from the oracle's silent drop)"

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" create --project NOCFG --title "x" --acceptance-file "$AC_FILE" --confirmed-site foo.atlassian.net
expect_rc "create --acceptance-file, unconfigured project -> exit 1" 1
stderr_has "create --acceptance-file unconfigured: diagnostic" "custom_fields.acceptance_criteria"
equals "create --acceptance-file unconfigured: no network call was made" "$(call_count)" "0"

section "jira.sh create — --assignee resolves to {id: accountId}"

reset_curl_stub
set_stub_response 1 '[{"accountId":"acc-777"}]' 200
set_stub_response 2 '{"id":"10003","key":"PROJ-103","self":"x"}' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" create --project PROJ --title "Assigned" --assignee dev@example.com \
	--confirmed-site foo.atlassian.net
expect_rc "create --assignee -> exit 0" 0
SENT_BODY=$(call_body 2)
equals "create: assignee is {id: accountId} (not {accountId:...})" \
	"$(printf '%s' "$SENT_BODY" | jq -c '.fields.assignee')" '{"id":"acc-777"}'

section "jira.sh create — --type alias resolution + issue_types validation"

reset_curl_stub
# call 1: the subtask-parent-type lookup GET (config declares "Sub-task" a
# subtask type, so cmd_create looks up PROJ-1's own issue type first);
# call 2: the create POST itself.
set_stub_response 1 '{"fields":{"issuetype":{"name":"Task"}}}' 200
set_stub_response 2 '{"id":"10004","key":"PROJ-104","self":"x"}' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$WORK/projects" \
	sh "$JIRA" create --project PROJ --title "A subtask alias" --type subtask --parent PROJ-1 \
	--confirmed-site foo.atlassian.net
expect_rc "create --type subtask (needs --parent) -> exit 0" 0
SENT_BODY=$(call_body 2)
equals "create: --type resolved through type_aliases" \
	"$(printf '%s' "$SENT_BODY" | jq -r '.fields.issuetype.name')" "Sub-task"
assert_no_leaked_workdir "subtask create"

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$WORK/projects" \
	sh "$JIRA" create --project PROJ --title "Bad type" --type Nonsense --confirmed-site foo.atlassian.net
expect_rc "create --type not in issue_types -> exit 1" 1
stderr_has "create bad type: diagnostic" "invalid type 'Nonsense'"

section "jira.sh create — subtask type requires --parent, and validates the parent's type"

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$WORK/projects" \
	sh "$JIRA" create --project PROJ --title "No parent" --type Sub-task --confirmed-site foo.atlassian.net
expect_rc "create Sub-task without --parent -> exit 1" 1
stderr_has "create Sub-task without --parent: diagnostic" "requires --parent"

reset_curl_stub
set_stub_response 1 '{"fields":{"issuetype":{"name":"Bug"}}}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$WORK/projects" \
	sh "$JIRA" create --project PROJ --title "Bad parent type" --type Sub-task --parent PROJ-9 \
	--confirmed-site foo.atlassian.net
expect_rc "create Sub-task under a disallowed parent type -> exit 1" 1
stderr_has "create Sub-task disallowed parent: diagnostic" "subtask_parent_types"

section "jira.sh create — labels/due-date/parent"

reset_curl_stub
set_stub_response 1 '{"id":"10005","key":"PROJ-105","self":"x"}' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" create --project PROJ --title "Fields" --labels 'a,b' --due-date 2026-01-15 --parent PROJ-1 \
	--confirmed-site foo.atlassian.net
expect_rc "create labels/due-date/parent -> exit 0" 0
SENT_BODY=$(call_body 1)
equals "create: labels array" "$(printf '%s' "$SENT_BODY" | jq -c '.fields.labels')" '["a","b"]'
equals "create: duedate" "$(printf '%s' "$SENT_BODY" | jq -r '.fields.duedate')" "2026-01-15"
equals "create: parent.key" "$(printf '%s' "$SENT_BODY" | jq -r '.fields.parent.key')" "PROJ-1"

section "jira.sh create — non-2xx surfaces Jira's own error"

reset_curl_stub
set_stub_response 1 '{"errorMessages":["Field summary is required"]}' 400
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" create --project PROJ --title "x" --confirmed-site foo.atlassian.net
expect_rc "create 400 -> exit 1" 1
stderr_has "create 400: Jira's own error message surfaced" "Field summary is required"

# ===========================================================================
# create — injection safety (SEC / the required test from the brief)
# ===========================================================================
section "jira.sh create — an injection-shaped summary/description stays completely inert"

INJECTION_DESC_FILE="$WORK/injection-description.md"
# shellcheck disable=SC2016  # deliberately single-quoted: this $(...) / `...` payload must NOT expand — that IS the test
printf 'Danger: $(rm -rf /tmp/should-not-run) and `echo pwned` and "quoted" text.\n' >"$INJECTION_DESC_FILE"
# pre-create the marker and have the payload try to DELETE it
# ($(rm -f "$MARKER")) rather than create it ($(touch ...)) — `touch` is NOT
# on the isolated toolbox PATH, so a `$(touch ...)` payload would fail
# "command not found" regardless of whether the substitution ever actually
# ran, making that version of the test unable to fail on a real regression
# (false confidence). `rm` IS on the toolbox (jira.sh itself needs it), so
# this version genuinely distinguishes "never executed" (marker SURVIVES)
# from "executed" (marker is gone).
MARKER_FILE="$WORK/injection-marker.txt"
printf 'marker\n' >"$MARKER_FILE"

reset_curl_stub
set_stub_response 1 '{"id":"10006","key":"PROJ-106","self":"x"}' 201
# shellcheck disable=SC2016  # deliberately single-quoted: the $(rm -f ...) / `echo hi` payload must reach jira.sh literally, never expand in THIS test script
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" create --project PROJ \
	--title 'Fix $(rm -f "'"$MARKER_FILE"'") bug `echo hi`' \
	--description-file "$INJECTION_DESC_FILE" \
	--confirmed-site foo.atlassian.net
expect_rc "create with an injection-shaped summary/description -> exit 0 (never executed)" 0
TESTS_RUN=$((TESTS_RUN + 1))
if [ -f "$MARKER_FILE" ]; then
	pass "create: injection-shaped summary NEVER executed (marker file SURVIVES)"
else
	fail "create: injection-shaped summary NEVER executed (marker file SURVIVES)" "the marker file was DELETED — command substitution ran!"
fi
SENT_BODY=$(call_body 1)
# shellcheck disable=SC2016  # deliberately single-quoted: asserting the LITERAL unexpanded string was sent
equals "create: the literal \$(...) text survives inertly in summary" \
	"$(printf '%s' "$SENT_BODY" | jq -r '.fields.summary')" 'Fix $(rm -f "'"$MARKER_FILE"'") bug `echo hi`'
DESC_INERT_TEXT=$(printf '%s' "$SENT_BODY" | jq -r '[.fields.description.content[0].content[].text] | join("")')
TESTS_RUN=$((TESTS_RUN + 1))
# shellcheck disable=SC2016  # deliberately single-quoted: matching the LITERAL unexpanded string in the response
case "$DESC_INERT_TEXT" in
	*'$(rm -rf /tmp/should-not-run)'*) pass "create: the literal \$(...) text survives inertly in the ADF description" ;;
	*) fail "create: the literal \$(...) text survives inertly in the ADF description" "got: $DESC_INERT_TEXT" ;;
esac

# ===========================================================================
# comment
# ===========================================================================
section "jira.sh comment — usage errors"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" comment --confirmed-site foo.atlassian.net
expect_rc "comment without a ticket key -> exit 2" 2
stderr_has "comment without ticket key: diagnostic" "requires a ticket key"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" comment PROJ-1 --confirmed-site foo.atlassian.net
expect_rc "comment without --text-file -> exit 2" 2
stderr_has "comment without --text-file: diagnostic" "requires --text-file"

section "jira.sh comment — posts ADF via --data @file"

COMMENT_FILE="$WORK/comment.md"
printf 'LGTM, **great** work.\n' >"$COMMENT_FILE"

reset_curl_stub
set_stub_response 1 '{"id":"20001","body":{}}' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" comment PROJ-1 --text-file "$COMMENT_FILE" --confirmed-site foo.atlassian.net
expect_rc "comment -> exit 0" 0
stdout_has "comment: prints JIRA_COMMENT_ID" "JIRA_COMMENT_ID=20001"
argv_log_has_token "comment: sent via --data (a file), never inline JSON on argv" "--data"
SENT_BODY=$(call_body 1)
equals "comment: body is an ADF doc" "$(printf '%s' "$SENT_BODY" | jq -r '.body.type')" "doc"
COMMENT_TEXT=$(printf '%s' "$SENT_BODY" | jq -r '[.body.content[0].content[].text] | join("")')
TESTS_RUN=$((TESTS_RUN + 1))
case "$COMMENT_TEXT" in
	*"great"*) pass "comment: converted markdown content survives in the ADF" ;;
	*) fail "comment: converted markdown content survives in the ADF" "got: $COMMENT_TEXT" ;;
esac
assert_no_leaked_workdir "comment"

section "jira.sh comment — non-2xx surfaces Jira's own error"

reset_curl_stub
set_stub_response 1 '{"errorMessages":["Issue does not exist"]}' 404
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" comment PROJ-999 --text-file "$COMMENT_FILE" --confirmed-site foo.atlassian.net
expect_rc "comment 404 -> exit 1" 1
stderr_has "comment 404: Jira's own error message surfaced" "Issue does not exist"

# ===========================================================================
# transition — --plan (no writes)
# ===========================================================================
section "jira.sh transition — usage errors"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" transition PROJ-1 --confirmed-site foo.atlassian.net
expect_rc "transition without --status -> exit 2" 2
stderr_has "transition without --status: diagnostic" "requires --status"

section "jira.sh transition — --plan emits the multi-step path WITHOUT any POST firing"

reset_curl_stub
set_stub_response 1 '{"fields":{"status":{"name":"Open"},"issuetype":{"name":"Task"}}}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$WORK/projects" \
	sh "$JIRA" transition PROJ-1 --status Done --plan --confirmed-site foo.atlassian.net --json
expect_rc "transition --plan --json -> exit 0" 0
equals "transition --plan: exactly ONE call (the status GET, no writes)" "$(call_count)" "1"
argv_log_not_has_token "transition --plan: no POST method token anywhere" "POST"
PLAN_JSON="$CUR_OUT"
equals "transition --plan: executed=false" "$(printf '%s' "$PLAN_JSON" | jq -r '.executed')" "false"
equals "transition --plan: full walked path" "$(printf '%s' "$PLAN_JSON" | jq -c '.path')" '["In Progress","Reviewing","Done"]'

section "jira.sh transition — --plan human mode discloses the path + no-write notice"

reset_curl_stub
set_stub_response 1 '{"fields":{"status":{"name":"Open"},"issuetype":{"name":"Task"}}}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$WORK/projects" \
	sh "$JIRA" transition PROJ-1 --status Done --plan --confirmed-site foo.atlassian.net
expect_rc "transition --plan human -> exit 0" 0
stdout_has "transition --plan human: shows step 1" "In Progress"
stdout_has "transition --plan human: shows step 2" "Reviewing"
stdout_has "transition --plan human: shows final step" "Done"
stdout_has "transition --plan human: explicit no-write notice" "NOTHING WAS WRITTEN"

section "jira.sh transition — --plan to Closed WITHOUT --resolution discloses NO resolution/comment (opt-in, not auto-defaulted)"

reset_curl_stub
set_stub_response 1 '{"fields":{"status":{"name":"Open"},"issuetype":{"name":"Task"}}}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$WORK/projects" \
	sh "$JIRA" transition PROJ-1 --status Closed --plan --confirmed-site foo.atlassian.net
expect_rc "transition --plan to Closed, no --resolution (human) -> exit 0" 0
equals "transition --plan to Closed: exactly ONE call (status GET, no writes)" "$(call_count)" "1"
argv_log_not_has_token "transition --plan to Closed: no POST method token anywhere" "POST"
TESTS_RUN=$((TESTS_RUN + 1))
case "$CUR_OUT" in
	*"Will set resolution"*|*"Will add a system comment"*)
		fail "transition --plan to Closed without --resolution: discloses NOTHING resolution-related" "got: $CUR_OUT" ;;
	*) pass "transition --plan to Closed without --resolution: discloses NOTHING resolution-related" ;;
esac

reset_curl_stub
set_stub_response 1 '{"fields":{"status":{"name":"Open"},"issuetype":{"name":"Task"}}}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$WORK/projects" \
	sh "$JIRA" transition PROJ-1 --status Closed --plan --confirmed-site foo.atlassian.net --json
expect_rc "transition --plan to Closed, no --resolution (json) -> exit 0" 0
equals "transition --plan to Closed (json): exactly ONE call" "$(call_count)" "1"
PLAN_CLOSED_JSON="$CUR_OUT"
equals "transition --plan to Closed (json), no --resolution: .resolution == null" \
	"$(printf '%s' "$PLAN_CLOSED_JSON" | jq -r '.resolution')" "null"
equals "transition --plan to Closed (json): .executed == false" \
	"$(printf '%s' "$PLAN_CLOSED_JSON" | jq -r '.executed')" "false"

section "jira.sh transition — --plan WITH an explicit --resolution still discloses it (the P4 consent-gate disclosure)"

reset_curl_stub
set_stub_response 1 '{"fields":{"status":{"name":"Open"},"issuetype":{"name":"Task"}}}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$WORK/projects" \
	sh "$JIRA" transition PROJ-1 --status Closed --resolution Resolved --plan --confirmed-site foo.atlassian.net
expect_rc "transition --plan to Closed --resolution Resolved (human) -> exit 0" 0
equals "transition --plan to Closed --resolution: exactly ONE call (status GET, no writes)" "$(call_count)" "1"
argv_log_not_has_token "transition --plan to Closed --resolution: no POST method token anywhere" "POST"
stdout_has "transition --plan to Closed --resolution (human): discloses the resolution" "Will set resolution: Resolved"
stdout_has "transition --plan to Closed --resolution (human): discloses the injected system comment" \
	'Will add a system comment: "Closed with resolution: Resolved"'

reset_curl_stub
set_stub_response 1 '{"fields":{"status":{"name":"Open"},"issuetype":{"name":"Task"}}}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$WORK/projects" \
	sh "$JIRA" transition PROJ-1 --status Closed --resolution Resolved --plan --confirmed-site foo.atlassian.net --json
expect_rc "transition --plan to Closed --resolution Resolved (json) -> exit 0" 0
equals "transition --plan to Closed --resolution (json): exactly ONE call" "$(call_count)" "1"
PLAN_RES_JSON="$CUR_OUT"
equals "transition --plan to Closed --resolution (json): .resolution == Resolved" \
	"$(printf '%s' "$PLAN_RES_JSON" | jq -r '.resolution')" "Resolved"
equals "transition --plan to Closed --resolution (json): .executed == false" \
	"$(printf '%s' "$PLAN_RES_JSON" | jq -r '.executed')" "false"

# ===========================================================================
# transition — the real walk
# ===========================================================================
section "jira.sh transition — real walk verifies status after EACH step"

reset_curl_stub
set_stub_response 1 '{"fields":{"status":{"name":"Open"},"issuetype":{"name":"Task"}}}' 200
set_stub_response 2 '{"transitions":[{"id":"11","to":{"name":"In Progress"}}]}' 200
set_stub_response 3 '' 204
set_stub_response 4 '{"fields":{"status":{"name":"In Progress"}}}' 200
set_stub_response 5 '{"transitions":[{"id":"22","to":{"name":"Reviewing"}}]}' 200
set_stub_response 6 '' 204
set_stub_response 7 '{"fields":{"status":{"name":"Reviewing"}}}' 200
set_stub_response 8 '{"transitions":[{"id":"33","to":{"name":"Done"}}]}' 200
set_stub_response 9 '' 204
set_stub_response 10 '{"fields":{"status":{"name":"Done"}}}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$WORK/projects" \
	sh "$JIRA" transition PROJ-1 --status Done --confirmed-site foo.atlassian.net --json
expect_rc "transition real walk -> exit 0" 0
equals "transition real walk: 10 calls (1 status + 3 x [transitions,POST,verify])" "$(call_count)" "10"
WALK_JSON="$CUR_OUT"
equals "transition real walk: executed=true" "$(printf '%s' "$WALK_JSON" | jq -r '.executed')" "true"
equals "transition real walk: path matches the plan" "$(printf '%s' "$WALK_JSON" | jq -c '.path')" '["In Progress","Reviewing","Done"]'

section "jira.sh transition — a step that silently no-ops fails loud"

reset_curl_stub
set_stub_response 1 '{"fields":{"status":{"name":"Open"},"issuetype":{"name":"Task"}}}' 200
set_stub_response 2 '{"transitions":[{"id":"11","to":{"name":"In Progress"}}]}' 200
set_stub_response 3 '' 204
# The verify-GET after the POST still reports "Open" — the transition
# silently did not apply (e.g. a workflow validator rejected it).
set_stub_response 4 '{"fields":{"status":{"name":"Open"}}}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$WORK/projects" \
	sh "$JIRA" transition PROJ-1 --status Done --confirmed-site foo.atlassian.net
expect_rc "transition silent no-op -> exit 1" 1
stderr_has "transition: diagnostic names both statuses" "did not apply (status is still 'Open')"

section "jira.sh transition — F3: two same-named transitions -> picks the FIRST deterministically, notes the ambiguity"

reset_curl_stub
set_stub_response 1 '{"fields":{"status":{"name":"Open"},"issuetype":{"name":"Task"}}}' 200
# A real workflow can offer TWO transitions with the SAME .to.name (seen
# live). id "11" is listed FIRST in Jira's own response order — the fix
# must pick that one, never id "12".
set_stub_response 2 '{"transitions":[{"id":"11","to":{"name":"In Progress"}},{"id":"12","to":{"name":"In Progress"}}]}' 200
set_stub_response 3 '' 204
set_stub_response 4 '{"fields":{"status":{"name":"In Progress"}}}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$WORK/projects" \
	sh "$JIRA" transition PROJ-1 --status "In Progress" --confirmed-site foo.atlassian.net
expect_rc "transition with two same-named transitions -> exit 0" 0
POST_BODY_AMBIGUOUS=$(call_body 3)
equals "transition ambiguous name: picks the FIRST transition id (11, not 12)" \
	"$(printf '%s' "$POST_BODY_AMBIGUOUS" | jq -r '.transition.id')" "11"
stderr_has "transition ambiguous name: one-line stderr note naming the count" \
	"2 transitions on PROJ-1 are named 'In Progress' — picking the first"

section "jira.sh transition — a Closed target does NOT auto-set a resolution (strictly opt-in)"

reset_curl_stub
set_stub_response 1 '{"fields":{"status":{"name":"Reviewing"},"issuetype":{"name":"Task"}}}' 200
set_stub_response 2 '{"transitions":[{"id":"99","to":{"name":"Closed"}}]}' 200
set_stub_response 3 '' 204
set_stub_response 4 '{"fields":{"status":{"name":"Closed"}}}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$WORK/projects" \
	sh "$JIRA" transition PROJ-1 --status Closed --confirmed-site foo.atlassian.net --json
expect_rc "transition to Closed, no --resolution -> exit 0" 0
equals "transition to Closed, no --resolution: .resolution == null (NOT auto-defaulted)" \
	"$(printf '%s' "$CUR_OUT" | jq -r '.resolution')" "null"
TRANSITION_POST_BODY=$(call_body 3)
equals "transition to Closed, no --resolution: fields.resolution is ABSENT from the POST body" \
	"$(printf '%s' "$TRANSITION_POST_BODY" | jq 'has("fields")')" "false"
equals "transition to Closed, no --resolution: NO comment injected either (update key absent)" \
	"$(printf '%s' "$TRANSITION_POST_BODY" | jq 'has("update")')" "false"
equals "transition to Closed, no --resolution: POST body is JUST the transition id" \
	"$(printf '%s' "$TRANSITION_POST_BODY" | jq -c '.')" '{"transition":{"id":"99"}}'

section "jira.sh transition — a lowercase --status matches the graph's canonically-cased node (BFS + verify)"

reset_curl_stub
set_stub_response 1 '{"fields":{"status":{"name":"Reviewing"},"issuetype":{"name":"Task"}}}' 200
set_stub_response 2 '{"transitions":[{"id":"99","to":{"name":"Closed"}}]}' 200
set_stub_response 3 '' 204
set_stub_response 4 '{"fields":{"status":{"name":"Closed"}}}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$WORK/projects" \
	sh "$JIRA" transition PROJ-1 --status closed --confirmed-site foo.atlassian.net --json
expect_rc "transition --status closed (lowercase) -> exit 0 (NOT 'no valid workflow path')" 0
LOWER_WALK_JSON="$CUR_OUT"
equals "transition --status closed (lowercase): BFS path uses the graph's own casing" \
	"$(printf '%s' "$LOWER_WALK_JSON" | jq -c '.path')" '["Closed"]'
equals "transition --status closed (lowercase): resolution stays null (opt-in, none given)" \
	"$(printf '%s' "$LOWER_WALK_JSON" | jq -r '.resolution')" "null"

section "jira.sh transition — explicit --resolution is opt-in and sets the field + injects the comment"

reset_curl_stub
set_stub_response 1 '{"fields":{"status":{"name":"Reviewing"},"issuetype":{"name":"Task"}}}' 200
set_stub_response 2 '{"transitions":[{"id":"99","to":{"name":"Closed"}}]}' 200
set_stub_response 3 '' 204
set_stub_response 4 '{"fields":{"status":{"name":"Closed"}}}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$WORK/projects" \
	sh "$JIRA" transition PROJ-1 --status Closed --resolution "Won't Fix" --confirmed-site foo.atlassian.net --json
expect_rc "transition --resolution \"Won't Fix\" -> exit 0" 0
equals "transition --resolution: .resolution honors the explicit value" \
	"$(printf '%s' "$CUR_OUT" | jq -r '.resolution')" "Won't Fix"
OVERRIDE_POST_BODY=$(call_body 3)
equals "transition --resolution: fields.resolution.name" \
	"$(printf '%s' "$OVERRIDE_POST_BODY" | jq -r '.fields.resolution.name')" "Won't Fix"
equals "transition --resolution: injected comment text uses the given value" \
	"$(printf '%s' "$OVERRIDE_POST_BODY" | jq -r '.update.comment[0].add.body.content[0].content[0].text')" \
	"Closed with resolution: Won't Fix"

section "jira.sh transition — already at target is a no-op success"

reset_curl_stub
set_stub_response 1 '{"fields":{"status":{"name":"Done"},"issuetype":{"name":"Task"}}}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$WORK/projects" \
	sh "$JIRA" transition PROJ-1 --status Done --confirmed-site foo.atlassian.net
expect_rc "transition already at target -> exit 0" 0
equals "transition already at target: exactly ONE call" "$(call_count)" "1"
stdout_has "transition already at target: message" 'already "Done"'

section "jira.sh transition — already-at-target compares case-INSENSITIVELY"

reset_curl_stub
set_stub_response 1 '{"fields":{"status":{"name":"Done"},"issuetype":{"name":"Task"}}}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$WORK/projects" \
	sh "$JIRA" transition PROJ-1 --status "done" --confirmed-site foo.atlassian.net --json
expect_rc "transition --status done (lowercase) already at Done -> exit 0" 0
equals "transition --status done (lowercase): exactly ONE call (no spurious walk)" "$(call_count)" "1"
LOWER_ALREADY_JSON="$CUR_OUT"
equals "transition --status done (lowercase): alreadyAtTarget == true" \
	"$(printf '%s' "$LOWER_ALREADY_JSON" | jq -r '.alreadyAtTarget')" "true"
equals "transition --status done (lowercase): displays Jira's OWN canonical casing" \
	"$(printf '%s' "$LOWER_ALREADY_JSON" | jq -r '.to')" "Done"

section "jira.sh transition — no valid path fails closed"

reset_curl_stub
set_stub_response 1 '{"fields":{"status":{"name":"Closed"},"issuetype":{"name":"Task"}}}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$WORK/projects" \
	sh "$JIRA" transition PROJ-1 --status Open --confirmed-site foo.atlassian.net
expect_rc "transition unreachable target -> exit 1" 1
stderr_has "transition unreachable target: diagnostic" "no valid workflow path"

# ===========================================================================
# update
# ===========================================================================
section "jira.sh update — usage errors"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" update PROJ-1 --confirmed-site foo.atlassian.net
expect_rc "update with no fields -> exit 2" 2
stderr_has "update no fields: diagnostic" "requires at least one field"

DESC2_FILE="$WORK/desc2.md"
printf 'x\n' >"$DESC2_FILE"
run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" update PROJ-1 --description-file "$DESC2_FILE" --append-file "$DESC2_FILE" \
	--confirmed-site foo.atlassian.net
expect_rc "update --description-file + --append-file together -> exit 2" 2
stderr_has "update mutual exclusivity: diagnostic" "mutually exclusive"

section "jira.sh update — builds the correct PUT fields{}"

reset_curl_stub
set_stub_response 1 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" update PROJ-1 --title "New title" --labels 'x,y' --due-date 2026-02-01 --parent PROJ-9 \
	--confirmed-site foo.atlassian.net
expect_rc "update simple fields -> exit 0" 0
stdout_has "update: prints JIRA_UPDATED" "JIRA_UPDATED=PROJ-1"
argv_log_has_token "update: uses PUT" "PUT"
SENT_BODY=$(call_body 1)
equals "update: summary" "$(printf '%s' "$SENT_BODY" | jq -r '.fields.summary')" "New title"
equals "update: labels" "$(printf '%s' "$SENT_BODY" | jq -c '.fields.labels')" '["x","y"]'
equals "update: duedate" "$(printf '%s' "$SENT_BODY" | jq -r '.fields.duedate')" "2026-02-01"
equals "update: parent.key" "$(printf '%s' "$SENT_BODY" | jq -r '.fields.parent.key')" "PROJ-9"
stderr_has "update --labels: warns about full-replace semantics" "replaces ALL labels"

section "jira.sh update — --description-file REPLACES (not appends) the description"

DESC3_FILE="$WORK/desc3.md"
printf 'Brand new description.\n' >"$DESC3_FILE"

reset_curl_stub
set_stub_response 1 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" update PROJ-1 --description-file "$DESC3_FILE" --confirmed-site foo.atlassian.net
expect_rc "update --description-file -> exit 0" 0
equals "update --description-file: exactly ONE call (no existing-description fetch, unlike --append-file)" "$(call_count)" "1"
SENT_BODY=$(call_body 1)
equals "update --description-file: replacement text" \
	"$(printf '%s' "$SENT_BODY" | jq -r '.fields.description.content[0].content[0].text')" "Brand new description."

section "jira.sh update — --assignee resolves to {id: accountId}"

reset_curl_stub
set_stub_response 1 '[{"accountId":"acc-update-assignee"}]' 200
set_stub_response 2 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" update PROJ-1 --assignee dev@example.com --confirmed-site foo.atlassian.net
expect_rc "update --assignee -> exit 0" 0
SENT_BODY=$(call_body 2)
equals "update --assignee: {id: accountId} shape" \
	"$(printf '%s' "$SENT_BODY" | jq -c '.fields.assignee')" '{"id":"acc-update-assignee"}'

section "jira.sh update — --append-file fetches the existing ADF, then appends (not replaces)"

reset_curl_stub
set_stub_response 1 '{"fields":{"description":{"type":"doc","version":1,"content":[{"type":"paragraph","content":[{"type":"text","text":"Original."}]}]}}}' 200
set_stub_response 2 '' 204
APPEND_FILE="$WORK/append.md"
printf 'Appended paragraph.\n' >"$APPEND_FILE"
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" update PROJ-1 --append-file "$APPEND_FILE" --confirmed-site foo.atlassian.net
expect_rc "update --append-file -> exit 0" 0
equals "update --append-file: TWO calls (fetch existing, then PUT)" "$(call_count)" "2"
SENT_BODY=$(call_body 2)
equals "update --append-file: original paragraph survives" \
	"$(printf '%s' "$SENT_BODY" | jq -r '.fields.description.content[0].content[0].text')" "Original."
equals "update --append-file: new paragraph appended after it" \
	"$(printf '%s' "$SENT_BODY" | jq -r '.fields.description.content[1].content[0].text')" "Appended paragraph."

section "jira.sh update — --developer resolves via accountId, {accountId: ...} shape (distinct from assignee's {id: ...})"

reset_curl_stub
set_stub_response 1 '[{"accountId":"acc-dev-555"}]' 200
set_stub_response 2 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$WORK/projects" \
	sh "$JIRA" update PROJ-1 --developer dev@example.com --confirmed-site foo.atlassian.net
expect_rc "update --developer -> exit 0" 0
SENT_BODY=$(call_body 2)
equals "update --developer: customfield_25500 = {accountId: ...}" \
	"$(printf '%s' "$SENT_BODY" | jq -c '.fields.customfield_25500')" '{"accountId":"acc-dev-555"}'

section "jira.sh update — --developer with no configured field fails loud"

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" update PROJ-1 --developer dev@example.com --confirmed-site foo.atlassian.net
expect_rc "update --developer unconfigured -> exit 1" 1
stderr_has "update --developer unconfigured: diagnostic" "custom_fields.developer"

section "jira.sh update — non-2xx surfaces Jira's own error"

reset_curl_stub
set_stub_response 1 '{"errorMessages":["Issue does not exist"]}' 404
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" update PROJ-999 --title "x" --confirmed-site foo.atlassian.net
expect_rc "update 404 -> exit 1" 1
stderr_has "update 404: Jira's own error message surfaced" "Issue does not exist"

# ===========================================================================
# link — POST /rest/api/3/issueLink
# ===========================================================================
section "jira.sh link — usage errors"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" link PROJ-1 --link-type Blocks --confirmed-site foo.atlassian.net
expect_rc "link without --to -> exit 2" 2
stderr_has "link without --to: diagnostic" "requires --to"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" link PROJ-1 --to PROJ-2 --confirmed-site foo.atlassian.net
expect_rc "link without --link-type -> exit 2" 2
stderr_has "link without --link-type: diagnostic" "requires --link-type"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" link not-a-key --to PROJ-2 --link-type Blocks --confirmed-site foo.atlassian.net
expect_rc "link with an invalid FROM key -> exit 2" 2
stderr_has "link invalid FROM key: diagnostic" "invalid FROM ticket key"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" link PROJ-1 --to not-a-key --link-type Blocks --confirmed-site foo.atlassian.net
expect_rc "link with an invalid --to key -> exit 2" 2
stderr_has "link invalid --to key: diagnostic" "invalid --to ticket key"

section "jira.sh link — direction: FROM -> inwardIssue, --to -> outwardIssue (\"FROM <verb> TO\", verified live)"

reset_curl_stub
set_stub_response 1 '' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" link PROJ-1 --to PROJ-2 --link-type Blocks --confirmed-site foo.atlassian.net
expect_rc "link PROJ-1 blocks PROJ-2 -> exit 0" 0
LINK_BODY=$(call_body 1)
equals "link: type.name" "$(printf '%s' "$LINK_BODY" | jq -r '.type.name')" "Blocks"
equals "link: FROM is inwardIssue.key (active voice: FROM blocks TO — verified live)" \
	"$(printf '%s' "$LINK_BODY" | jq -r '.inwardIssue.key')" "PROJ-1"
equals "link: TO is outwardIssue.key" \
	"$(printf '%s' "$LINK_BODY" | jq -r '.outwardIssue.key')" "PROJ-2"
equals "link: no stray comment key when --comment-file is not given" \
	"$(printf '%s' "$LINK_BODY" | jq 'has("comment")')" "false"
stdout_has "link human: prints JIRA_LINKED" "JIRA_LINKED=PROJ-1->PROJ-2 (Blocks)"

section "jira.sh link — --comment-file attaches an ADF comment under comment.body"

LINK_COMMENT_FILE="$WORK/link-comment.md"
printf 'Linking because of **shared root cause**.\n' >"$LINK_COMMENT_FILE"
reset_curl_stub
set_stub_response 1 '' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" link PROJ-1 --to PROJ-2 --link-type Relates --comment-file "$LINK_COMMENT_FILE" \
	--confirmed-site foo.atlassian.net
expect_rc "link --comment-file -> exit 0" 0
LINK_COMMENT_BODY=$(call_body 1)
equals "link --comment-file: comment.body is an ADF doc" \
	"$(printf '%s' "$LINK_COMMENT_BODY" | jq -r '.comment.body.type')" "doc"
LINK_COMMENT_TEXT=$(printf '%s' "$LINK_COMMENT_BODY" | jq -r '[.comment.body.content[0].content[].text] | join("")')
TESTS_RUN=$((TESTS_RUN + 1))
case "$LINK_COMMENT_TEXT" in
	*"shared root cause"*) pass "link --comment-file: converted markdown content survives in the ADF" ;;
	*) fail "link --comment-file: converted markdown content survives in the ADF" "got: $LINK_COMMENT_TEXT" ;;
esac
assert_no_leaked_workdir "link --comment-file"

section "jira.sh link — --json synthesizes a small object (no response body to pass through, 201 is empty)"

reset_curl_stub
set_stub_response 1 '' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" link PROJ-1 --to PROJ-2 --link-type Blocks --confirmed-site foo.atlassian.net --json
expect_rc "link --json -> exit 0" 0
equals "link --json: from" "$(printf '%s' "$CUR_OUT" | jq -r '.from')" "PROJ-1"
equals "link --json: to" "$(printf '%s' "$CUR_OUT" | jq -r '.to')" "PROJ-2"
equals "link --json: type" "$(printf '%s' "$CUR_OUT" | jq -r '.type')" "Blocks"

section "jira.sh link — an injection-shaped --link-type stays completely inert"

reset_curl_stub
set_stub_response 1 '' 201
# shellcheck disable=SC2016  # deliberately single-quoted: this $(...) / `...` payload must reach jira.sh literally, never expand in THIS test script
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" link PROJ-1 --to PROJ-2 --link-type 'Blocks $(echo pwned) `echo pwned`' \
	--confirmed-site foo.atlassian.net
expect_rc "link with an injection-shaped --link-type -> exit 0 (never executed)" 0
LINK_INJECTION_BODY=$(call_body 1)
# shellcheck disable=SC2016  # deliberately single-quoted: asserting the LITERAL unexpanded string was sent
equals "link: the literal \$(...) text survives inertly in type.name" \
	"$(printf '%s' "$LINK_INJECTION_BODY" | jq -r '.type.name')" 'Blocks $(echo pwned) `echo pwned`'

section "jira.sh link — a --link-type with a literal double-quote survives inertly (JSON metachar)"

reset_curl_stub
set_stub_response 1 '' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" link PROJ-1 --to PROJ-2 --link-type 'is "blocked" by' --confirmed-site foo.atlassian.net
expect_rc "link with a quote-bearing --link-type -> exit 0" 0
LINK_QUOTE_BODY=$(call_body 1)
equals "link: the literal double-quote round-trips intact in type.name" \
	"$(printf '%s' "$LINK_QUOTE_BODY" | jq -r '.type.name')" 'is "blocked" by'

section "jira.sh link — non-2xx surfaces Jira's own error"

reset_curl_stub
set_stub_response 1 '{"errorMessages":["Issue link type is not valid"]}' 400
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" link PROJ-1 --to PROJ-2 --link-type Bogus --confirmed-site foo.atlassian.net
expect_rc "link 400 -> exit 1" 1
stderr_has "link 400: Jira's own error message surfaced" "Issue link type is not valid"

# ===========================================================================
# worklog — POST /rest/api/3/issue/<KEY>/worklog
# ===========================================================================
section "jira.sh worklog — usage errors"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" worklog PROJ-1 --confirmed-site foo.atlassian.net
expect_rc "worklog without --time-spent -> exit 2" 2
stderr_has "worklog without --time-spent: diagnostic" "requires --time-spent"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" worklog --time-spent 2h --confirmed-site foo.atlassian.net
expect_rc "worklog without a ticket key -> exit 2" 2
stderr_has "worklog without ticket key: diagnostic" "requires a ticket key"

section "jira.sh worklog — builds timeSpent/comment/started, no fields{} wrapper"

WORKLOG_COMMENT_FILE="$WORK/worklog-comment.md"
printf 'Investigated the **root cause**.\n' >"$WORKLOG_COMMENT_FILE"
reset_curl_stub
set_stub_response 1 '{"id":"30001","timeSpent":"2h"}' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" worklog PROJ-1 --time-spent 2h --comment-file "$WORKLOG_COMMENT_FILE" \
	--started "2026-07-24T10:00:00.000+0000" --confirmed-site foo.atlassian.net
expect_rc "worklog with comment + started -> exit 0" 0
stdout_has "worklog: prints JIRA_WORKLOGGED" "JIRA_WORKLOGGED=PROJ-1 (2h)"
WORKLOG_BODY=$(call_body 1)
equals "worklog: timeSpent" "$(printf '%s' "$WORKLOG_BODY" | jq -r '.timeSpent')" "2h"
equals "worklog: started" "$(printf '%s' "$WORKLOG_BODY" | jq -r '.started')" "2026-07-24T10:00:00.000+0000"
equals "worklog: comment is an ADF doc" "$(printf '%s' "$WORKLOG_BODY" | jq -r '.comment.type')" "doc"
equals "worklog: request body has NO fields{} wrapper (unlike create/update)" \
	"$(printf '%s' "$WORKLOG_BODY" | jq 'has("fields")')" "false"
assert_no_leaked_workdir "worklog with comment"

section "jira.sh worklog — --time-spent/--comment-file/--started are all optional except --time-spent"

reset_curl_stub
set_stub_response 1 '{"id":"30002","timeSpent":"30m"}' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" worklog PROJ-1 --time-spent 30m --confirmed-site foo.atlassian.net
expect_rc "worklog minimal (time-spent only) -> exit 0" 0
WORKLOG_MINIMAL_BODY=$(call_body 1)
equals "worklog minimal: ONLY timeSpent is present" \
	"$(printf '%s' "$WORKLOG_MINIMAL_BODY" | jq -c '.')" '{"timeSpent":"30m"}'

section "jira.sh worklog — --json passes the 201 response body through"

reset_curl_stub
set_stub_response 1 '{"id":"30003","timeSpent":"1d 4h","author":{"displayName":"A"}}' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" worklog PROJ-1 --time-spent "1d 4h" --confirmed-site foo.atlassian.net --json
expect_rc "worklog --json -> exit 0" 0
equals "worklog --json: passthrough body's id" "$(printf '%s' "$CUR_OUT" | jq -r '.id')" "30003"

section "jira.sh worklog — an injection-shaped --time-spent stays completely inert"

reset_curl_stub
set_stub_response 1 '{"id":"30004","timeSpent":"x"}' 201
# shellcheck disable=SC2016  # deliberately single-quoted: this $(...) / `...` payload must reach jira.sh literally, never expand in THIS test script
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" worklog PROJ-1 --time-spent '2h $(echo pwned) `echo pwned`' --confirmed-site foo.atlassian.net
expect_rc "worklog with an injection-shaped --time-spent -> exit 0 (never executed)" 0
WORKLOG_INJECTION_BODY=$(call_body 1)
# shellcheck disable=SC2016  # deliberately single-quoted: asserting the LITERAL unexpanded string was sent
equals "worklog: the literal \$(...) text survives inertly in timeSpent" \
	"$(printf '%s' "$WORKLOG_INJECTION_BODY" | jq -r '.timeSpent')" '2h $(echo pwned) `echo pwned`'

section "jira.sh worklog — non-2xx surfaces Jira's own error"

reset_curl_stub
set_stub_response 1 '{"errorMessages":["Time spent is not a valid duration"]}' 400
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" worklog PROJ-1 --time-spent "bogus" --confirmed-site foo.atlassian.net
expect_rc "worklog 400 -> exit 1" 1
stderr_has "worklog 400: Jira's own error message surfaced" "Time spent is not a valid duration"

# ===========================================================================
# watch — POST/DELETE/GET /rest/api/3/issue/<KEY>/watchers
# ===========================================================================
section "jira.sh watch — usage errors"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" watch --confirmed-site foo.atlassian.net
expect_rc "watch without a ticket key -> exit 2" 2
stderr_has "watch without ticket key: diagnostic" "requires a ticket key"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" watch PROJ-1 --list --remove --confirmed-site foo.atlassian.net
expect_rc "watch --list + --remove -> exit 2" 2
stderr_has "watch --list + --remove: diagnostic" "mutually exclusive"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" watch PROJ-1 --list --account dev@example.com --confirmed-site foo.atlassian.net
expect_rc "watch --list + --account -> exit 2" 2
stderr_has "watch --list + --account: diagnostic" "does not take --account"

section "jira.sh watch — add self (no --account) resolves via GET /myself, POSTs the bare accountId string"

reset_curl_stub
set_stub_response 1 '{"accountId":"acc-self-watch"}' 200
set_stub_response 2 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" watch PROJ-1 --confirmed-site foo.atlassian.net
expect_rc "watch self -> exit 0" 0
stdout_has "watch self: prints JIRA_WATCHED" "JIRA_WATCHED=PROJ-1"
file_has "watch self: hits /myself first" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/myself"
WATCH_ADD_BODY=$(cat "$CURL_STUB_BODY_LOG_DIR/call-2.body")
equals "watch self: request body is the BARE accountId JSON string" "$WATCH_ADD_BODY" '"acc-self-watch"'
assert_no_leaked_workdir "watch self"

reset_curl_stub
set_stub_response 1 '{"accountId":"acc-self-watch"}' 200
set_stub_response 2 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" watch PROJ-1 --confirmed-site foo.atlassian.net --json
expect_rc "watch add --json -> exit 0" 0
equals "watch add --json: key" "$(printf '%s' "$CUR_OUT" | jq -r '.key')" "PROJ-1"
equals "watch add --json: synthesized watching=true" "$(printf '%s' "$CUR_OUT" | jq -r '.watching')" "true"

section "jira.sh watch — add a specified --account (email) resolves via /user/search"

reset_curl_stub
set_stub_response 1 '[{"accountId":"acc-watch-777"}]' 200
set_stub_response 2 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" watch PROJ-1 --account dev@example.com --confirmed-site foo.atlassian.net
expect_rc "watch --account -> exit 0" 0
file_has "watch --account: hits /user/search" "$CURL_STUB_ARGV_LOG" "/rest/api/3/user/search?query="
WATCH_ACCOUNT_BODY=$(cat "$CURL_STUB_BODY_LOG_DIR/call-2.body")
equals "watch --account: request body is the resolved accountId" "$WATCH_ACCOUNT_BODY" '"acc-watch-777"'

section "jira.sh watch — --remove urlencodes accountId into the DELETE query string"

reset_curl_stub
set_stub_response 1 '{"accountId":"acc self/needs+encoding"}' 200
set_stub_response 2 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" watch PROJ-1 --remove --confirmed-site foo.atlassian.net
expect_rc "watch --remove -> exit 0" 0
stdout_has "watch --remove: prints JIRA_UNWATCHED" "JIRA_UNWATCHED=PROJ-1"
argv_log_has_token "watch --remove: DELETE method used" "DELETE"
file_has "watch --remove: DELETE url carries an urlencoded accountId (space -> %20)" \
	"$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/issue/PROJ-1/watchers?accountId=acc%20self%2Fneeds%2Bencoding"
file_not_has "watch --remove: the RAW unencoded accountId never appears on argv" \
	"$CURL_STUB_ARGV_LOG" "acc self/needs+encoding"

reset_curl_stub
set_stub_response 1 '{"accountId":"acc-self-watch"}' 200
set_stub_response 2 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" watch PROJ-1 --remove --confirmed-site foo.atlassian.net --json
expect_rc "watch --remove --json -> exit 0" 0
equals "watch --remove --json: synthesized watching=false" "$(printf '%s' "$CUR_OUT" | jq -r '.watching')" "false"

section "jira.sh watch — --list renders watch count + watcher names, --json passes through"

reset_curl_stub
set_stub_response 1 '{"watchCount":2,"watchers":[{"displayName":"Alice A"},{"displayName":"Bob B"}]}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" watch PROJ-1 --list --confirmed-site foo.atlassian.net
expect_rc "watch --list human -> exit 0" 0
stdout_has "watch --list human: count shown (labeled)" "Watchers: 2"
stdout_has "watch --list human: first watcher shown" "Alice A"
stdout_has "watch --list human: second watcher shown" "Bob B"
equals "watch --list: exactly ONE call (no accountId resolution needed)" "$(call_count)" "1"

reset_curl_stub
set_stub_response 1 '{"watchCount":0,"watchers":[]}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" watch PROJ-1 --list --confirmed-site foo.atlassian.net --json
expect_rc "watch --list --json -> exit 0" 0
equals "watch --list --json: passthrough watchCount" "$(printf '%s' "$CUR_OUT" | jq -r '.watchCount')" "0"

section "jira.sh watch — non-2xx surfaces Jira's own error"

reset_curl_stub
set_stub_response 1 '{"errorMessages":["Issue does not exist"]}' 404
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" watch PROJ-999 --list --confirmed-site foo.atlassian.net
expect_rc "watch --list 404 -> exit 1" 1
stderr_has "watch --list 404: Jira's own error message surfaced" "Issue does not exist"

# ===========================================================================
# vote — POST/DELETE/GET /rest/api/3/issue/<KEY>/votes
# ===========================================================================
section "jira.sh vote — usage errors"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" vote --confirmed-site foo.atlassian.net
expect_rc "vote without a ticket key -> exit 2" 2
stderr_has "vote without ticket key: diagnostic" "requires a ticket key"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" vote PROJ-1 --list --remove --confirmed-site foo.atlassian.net
expect_rc "vote --list + --remove -> exit 2" 2
stderr_has "vote --list + --remove: diagnostic" "mutually exclusive"

section "jira.sh vote — add vote: POST with NO body, exactly one call"

reset_curl_stub
set_stub_response 1 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" vote PROJ-1 --confirmed-site foo.atlassian.net
expect_rc "vote add -> exit 0" 0
stdout_has "vote add: prints JIRA_VOTED" "JIRA_VOTED=PROJ-1"
argv_log_has_token "vote add: POST method used" "POST"
equals "vote add: exactly ONE call (no accountId resolution — self-vote is implicit)" "$(call_count)" "1"
argv_log_not_has_token "vote add: --data absent (no request body)" "--data"

reset_curl_stub
set_stub_response 1 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" vote PROJ-1 --confirmed-site foo.atlassian.net --json
expect_rc "vote add --json -> exit 0" 0
equals "vote add --json: key" "$(printf '%s' "$CUR_OUT" | jq -r '.key')" "PROJ-1"
equals "vote add --json: synthesized voted=true" "$(printf '%s' "$CUR_OUT" | jq -r '.voted')" "true"

section "jira.sh vote — remove vote: DELETE, exactly one call"

reset_curl_stub
set_stub_response 1 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" vote PROJ-1 --remove --confirmed-site foo.atlassian.net
expect_rc "vote --remove -> exit 0" 0
stdout_has "vote --remove: prints JIRA_UNVOTED" "JIRA_UNVOTED=PROJ-1"
argv_log_has_token "vote --remove: DELETE method used" "DELETE"

reset_curl_stub
set_stub_response 1 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" vote PROJ-1 --remove --confirmed-site foo.atlassian.net --json
expect_rc "vote --remove --json -> exit 0" 0
equals "vote --remove --json: synthesized voted=false" "$(printf '%s' "$CUR_OUT" | jq -r '.voted')" "false"

section "jira.sh vote — --list renders votes + hasVoted, --json passes through"

reset_curl_stub
set_stub_response 1 '{"votes":5,"hasVoted":true}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" vote PROJ-1 --list --confirmed-site foo.atlassian.net
expect_rc "vote --list human -> exit 0" 0
stdout_has "vote --list human: vote count shown (labeled)" "Votes: 5"
stdout_has "vote --list human: hasVoted shown (labeled)" "You have voted: true"

reset_curl_stub
set_stub_response 1 '{"votes":0,"hasVoted":false}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" vote PROJ-1 --list --confirmed-site foo.atlassian.net --json
expect_rc "vote --list --json -> exit 0" 0
equals "vote --list --json: passthrough votes" "$(printf '%s' "$CUR_OUT" | jq -r '.votes')" "0"

section "jira.sh vote — non-2xx surfaces Jira's own error"

reset_curl_stub
set_stub_response 1 '{"errorMessages":["Issue does not exist"]}' 404
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" vote PROJ-999 --confirmed-site foo.atlassian.net
expect_rc "vote 404 -> exit 1" 1
stderr_has "vote 404: Jira's own error message surfaced" "Issue does not exist"

# ===========================================================================
# schedule — issue scheduling: move to sprint / backlog / epic (parent). Real
# request/response shapes; curl stubbed. Ground truth (confirmed live):
#   --to-sprint ID  POST /rest/agile/1.0/sprint/<ID>/issue      {"issues":[...]}
#   --to-backlog    POST /rest/agile/1.0/backlog/<BOARD>/issue  {"issues":[...]}
#   --to-epic KEY   PUT  /rest/api/3/issue/<K> {"fields":{"parent":{"key":KEY}}}
#   --from-epic     PUT  /rest/api/3/issue/<K> {"fields":{"parent":null}}
# NOTE: keys use a >=2-char project prefix (PROJ-1, not A-1) because the shared
# validate_ticket_key allow-list is ^[A-Z][A-Z0-9]+-[0-9]+$ (a single-char
# project prefix like "A-1" is deliberately rejected engine-wide).
# ===========================================================================

# --- argument parsing (all exit 2, all BEFORE any network call) ------------
section "jira.sh — schedule: argument parsing (usage errors, exit 2, no network)"

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" schedule --keys "PROJ-1" --confirmed-site foo.atlassian.net
expect_rc "schedule missing target op -> exit 2" 2
stderr_has "schedule missing target op: diagnostic" "exactly one target op"
equals "schedule missing target op: ZERO curl calls" "$(call_count)" "0"

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" schedule --to-sprint 2212 --from-epic --keys "PROJ-1" --confirmed-site foo.atlassian.net
expect_rc "schedule two target ops -> exit 2" 2
stderr_has "schedule two target ops: diagnostic" "exactly one target op"
equals "schedule two target ops: ZERO curl calls" "$(call_count)" "0"

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" schedule --to-sprint 2212 --confirmed-site foo.atlassian.net
expect_rc "schedule neither --keys nor --jql -> exit 2" 2
stderr_has "schedule neither selector: diagnostic" "requires an issue selector"
equals "schedule neither selector: ZERO curl calls" "$(call_count)" "0"

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" schedule --to-sprint 2212 --keys "PROJ-1" --jql "project = PROJ" --confirmed-site foo.atlassian.net
expect_rc "schedule both --keys and --jql -> exit 2" 2
stderr_has "schedule both selectors: diagnostic" "exactly one of --keys or --jql"
equals "schedule both selectors: ZERO curl calls" "$(call_count)" "0"

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" schedule --to-backlog --keys "PROJ-1" --confirmed-site foo.atlassian.net
expect_rc "schedule --to-backlog without --board -> exit 2" 2
stderr_has "schedule --to-backlog no --board: diagnostic" "requires --board"
equals "schedule --to-backlog no --board: ZERO curl calls" "$(call_count)" "0"

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" schedule --to-sprint 2212 --board 826 --keys "PROJ-1" --confirmed-site foo.atlassian.net
expect_rc "schedule --board on a non-backlog op -> exit 2" 2
stderr_has "schedule stray --board: diagnostic" "--board is only valid with schedule --to-backlog"

# --- id / key validation (all exit 2, all BEFORE any network call) ---------
section "jira.sh — schedule: id/key validation (rejected before any network call)"

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" schedule --to-sprint 01 --keys "PROJ-1" --confirmed-site foo.atlassian.net
expect_rc "schedule --to-sprint 01 (leading zero) -> exit 2" 2
stderr_has "schedule bad sprint id 01: diagnostic" "invalid --to-sprint"
equals "schedule bad sprint id 01: ZERO curl calls" "$(call_count)" "0"

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" schedule --to-sprint x --keys "PROJ-1" --confirmed-site foo.atlassian.net
expect_rc "schedule --to-sprint x (non-numeric) -> exit 2" 2
stderr_has "schedule bad sprint id x: diagnostic" "invalid --to-sprint"
equals "schedule bad sprint id x: ZERO curl calls" "$(call_count)" "0"

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" schedule --to-backlog --board 0x --keys "PROJ-1" --confirmed-site foo.atlassian.net
expect_rc "schedule --to-backlog bad board id -> exit 2" 2
stderr_has "schedule bad board id: diagnostic" "invalid --board"
equals "schedule bad board id: ZERO curl calls" "$(call_count)" "0"

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" schedule --to-epic foo --keys "PROJ-1" --confirmed-site foo.atlassian.net
expect_rc "schedule --to-epic foo (bad key shape) -> exit 2" 2
stderr_has "schedule bad epic key foo: diagnostic" "invalid --to-epic"
equals "schedule bad epic key foo: ZERO curl calls" "$(call_count)" "0"

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" schedule --to-epic "A--1" --keys "PROJ-1" --confirmed-site foo.atlassian.net
expect_rc "schedule --to-epic A--1 (bad key shape) -> exit 2" 2
stderr_has "schedule bad epic key A--1: diagnostic" "invalid --to-epic"
equals "schedule bad epic key A--1: ZERO curl calls" "$(call_count)" "0"

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" schedule --to-sprint 2212 --keys "PROJ-1,not-a-key,PROJ-3" --confirmed-site foo.atlassian.net
expect_rc "schedule invalid key in --keys -> exit 2" 2
stderr_has "schedule invalid --keys entry: diagnostic" "invalid ticket key in --keys"
equals "schedule invalid --keys entry: ZERO curl calls" "$(call_count)" "0"

# --- move to sprint: endpoint/method/body ----------------------------------
section "jira.sh — schedule --to-sprint: POST /agile/1.0/sprint/<id>/issue with the issues[] array"

reset_curl_stub
set_stub_response 1 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" schedule --to-sprint 2212 --keys "PROJ-1,PROJ-2" --confirmed-site foo.atlassian.net
expect_rc "schedule --to-sprint --keys -> exit 0" 0
equals "schedule --to-sprint: exactly ONE call (whole array in one POST)" "$(call_count)" "1"
argv_log_has_token "schedule --to-sprint: method is POST" "POST"
file_has "schedule --to-sprint: hits sprint/<id>/issue" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/agile/1.0/sprint/2212/issue"
SENT_BODY=$(call_body 1)
equals "schedule --to-sprint: issues array is exactly the selected keys, in order" \
	"$(printf '%s' "$SENT_BODY" | jq -c '.issues')" '["PROJ-1","PROJ-2"]'
stdout_has "schedule --to-sprint: PROJ-1 result ok" "JIRA_SCHEDULE_RESULT=PROJ-1:ok"
stdout_has "schedule --to-sprint: PROJ-2 result ok" "JIRA_SCHEDULE_RESULT=PROJ-2:ok"
stdout_has "schedule --to-sprint: summary" "JIRA_SCHEDULE_SUMMARY=2/2 succeeded"

# --- move to backlog: endpoint/method/body ---------------------------------
section "jira.sh — schedule --to-backlog: POST /agile/1.0/backlog/<board>/issue (board-scoped, REQUIRES --board)"

reset_curl_stub
set_stub_response 1 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" schedule --to-backlog --board 826 --keys "PROJ-1,PROJ-2" --confirmed-site foo.atlassian.net
expect_rc "schedule --to-backlog --keys -> exit 0" 0
equals "schedule --to-backlog: exactly ONE call" "$(call_count)" "1"
argv_log_has_token "schedule --to-backlog: method is POST" "POST"
file_has "schedule --to-backlog: hits backlog/<board>/issue (board-scoped)" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/agile/1.0/backlog/826/issue"
SENT_BODY=$(call_body 1)
equals "schedule --to-backlog: issues array is exactly the selected keys" \
	"$(printf '%s' "$SENT_BODY" | jq -c '.issues')" '["PROJ-1","PROJ-2"]'
stdout_has "schedule --to-backlog: summary" "JIRA_SCHEDULE_SUMMARY=2/2 succeeded"

# --- assign to epic: PUT parent per issue ----------------------------------
section "jira.sh — schedule --to-epic: PUT /api/3/issue/<key> with fields.parent set (per issue)"

reset_curl_stub
set_stub_response 1 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" schedule --to-epic EPIC-9 --keys "PROJ-1" --confirmed-site foo.atlassian.net
expect_rc "schedule --to-epic --keys -> exit 0" 0
equals "schedule --to-epic: one PUT per issue" "$(call_count)" "1"
argv_log_has_token "schedule --to-epic: method is PUT" "PUT"
file_has "schedule --to-epic: hits /api/3/issue/<key>" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/issue/PROJ-1"
SENT_BODY=$(call_body 1)
equals "schedule --to-epic: body sets fields.parent.key to the epic key" \
	"$(printf '%s' "$SENT_BODY" | jq -r '.fields.parent.key')" "EPIC-9"
stdout_has "schedule --to-epic: summary" "JIRA_SCHEDULE_SUMMARY=1/1 succeeded"

# --- remove from epic: PUT parent:null per issue ---------------------------
section "jira.sh — schedule --from-epic: PUT /api/3/issue/<key> with fields.parent = null"

reset_curl_stub
set_stub_response 1 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" schedule --from-epic --keys "PROJ-1" --confirmed-site foo.atlassian.net
expect_rc "schedule --from-epic --keys -> exit 0" 0
argv_log_has_token "schedule --from-epic: method is PUT" "PUT"
file_has "schedule --from-epic: hits /api/3/issue/<key>" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/issue/PROJ-1"
SENT_BODY=$(call_body 1)
equals "schedule --from-epic: fields.parent is JSON null (not absent, not a string)" \
	"$(printf '%s' "$SENT_BODY" | jq -c '.fields.parent')" "null"
equals "schedule --from-epic: the fields object HAS a parent key (set to null, not merely omitted)" \
	"$(printf '%s' "$SENT_BODY" | jq -c '.fields | has("parent")')" "true"

# --- --jql selector: resolves via search, then moves -----------------------
section "jira.sh — schedule --jql: resolves the set via /search/jql, then moves it"

reset_curl_stub
# call 1: the JQL resolve returns two keys; call 2: the sprint move.
set_stub_response 1 '{"issues":[{"key":"PROJ-1","fields":{"summary":"a","status":{"name":"Open"}}},{"key":"PROJ-2","fields":{"summary":"b","status":{"name":"Open"}}}],"isLast":true}' 200
set_stub_response 2 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" schedule --to-sprint 2212 --jql "project = PROJ AND status = Open" --confirmed-site foo.atlassian.net
expect_rc "schedule --jql --to-sprint -> exit 0" 0
equals "schedule --jql: 2 calls (1 search resolve + 1 sprint move)" "$(call_count)" "2"
file_has "schedule --jql: call 1 is the /search/jql resolve" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/search/jql"
JQL_SENT=$(jq -r '.jql' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "schedule --jql: the resolve carried the caller's JQL verbatim" "$JQL_SENT" "project = PROJ AND status = Open"
file_has "schedule --jql: call 2 is the sprint move" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/agile/1.0/sprint/2212/issue"
argv_log_has_token "schedule --jql: the mutating move is a POST (method pinned, not just the URL)" "POST"
SENT_BODY=$(call_body 2)
equals "schedule --jql: the move's issues[] is the resolved set" \
	"$(printf '%s' "$SENT_BODY" | jq -c '.issues')" '["PROJ-1","PROJ-2"]'

# --- --jql --limit truncation disclosure -----------------------------------
# An explicit --limit is an intentional cap: when the resolved set reaches it,
# the truncation MUST be disclosed (never silently mutate a truncated set). The
# search returns a FULL page of --limit issues with isLast:false (more exist
# server-side), so the resolved set is capped at --limit and truncated=true.
section "jira.sh — schedule --jql --limit: caps the set at N and discloses the truncation (dry-run: NOTE, real run: CAPPED)"

# (a) dry-run: the warn fires AND the plan prints the NOTE disclosure.
reset_curl_stub
set_stub_response 1 '{"issues":[{"key":"PROJ-1","fields":{"summary":"a","status":{"name":"Open"}}},{"key":"PROJ-2","fields":{"summary":"b","status":{"name":"Open"}}}],"isLast":false}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" schedule --to-sprint 2212 --jql "project = PROJ" --limit 2 --dry-run --confirmed-site foo.atlassian.net
expect_rc "schedule --jql --limit 2 --dry-run -> exit 0" 0
# ONE call proves the sprint-move POST never fired (only the search resolve — a
# POST to /search/jql — so a no-POST-token check would be a false negative here).
equals "schedule --jql --limit dry-run: ONE call (the search resolve only, no writes)" "$(call_count)" "1"
stderr_has "schedule --jql --limit dry-run: warn discloses the cap" "capped at --limit 2 — additional matches may exist"
stdout_has "schedule --jql --limit dry-run: plan prints the NOTE cap disclosure" "NOTE: capped at --limit 2"

# (b) real run: the same cap is disclosed in the summary as CAPPED ...
reset_curl_stub
set_stub_response 1 '{"issues":[{"key":"PROJ-1","fields":{"summary":"a","status":{"name":"Open"}}},{"key":"PROJ-2","fields":{"summary":"b","status":{"name":"Open"}}}],"isLast":false}' 200
set_stub_response 2 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" schedule --to-sprint 2212 --jql "project = PROJ" --limit 2 --confirmed-site foo.atlassian.net
expect_rc "schedule --jql --limit 2 real run -> exit 0" 0
equals "schedule --jql --limit real run: 2 calls (search resolve + sprint move)" "$(call_count)" "2"
stderr_has "schedule --jql --limit real run: warn discloses the cap" "capped at --limit 2 — additional matches may exist"
stdout_has "schedule --jql --limit real run: summary discloses the cap as CAPPED" "CAPPED at --limit 2"

# --- --jql resolves ZERO issues: fail closed, mutate nothing ---------------
# A selector that resolves to an empty set is a fail-closed error (exit 1), not
# a silent no-op success: only the single search read fires, never a write.
section "jira.sh — schedule --jql resolves ZERO issues: exit 1, ZERO mutating calls"

reset_curl_stub
set_stub_response 1 '{"issues":[],"isLast":true}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" schedule --to-epic EPIC-9 --jql "project = PROJ AND status = Nonexistent" --confirmed-site foo.atlassian.net
expect_rc "schedule --jql zero issues -> exit 1" 1
stderr_has "schedule --jql zero issues: diagnostic names the empty resolve" "resolved ZERO issues"
# The epic op mutates via PUT; the ONLY call is the search read (itself a POST to
# /search/jql), so call_count==1 + no-PUT together prove ZERO mutating calls fired.
equals "schedule --jql zero issues: exactly ONE call (the search read, nothing more)" "$(call_count)" "1"
argv_log_not_has_token "schedule --jql zero issues: no PUT (mutating call) recorded" "PUT"

# --- dry-run: discloses the plan, makes NO mutating call -------------------
section "jira.sh — schedule --dry-run: discloses the plan, writes NOTHING (--keys => ZERO calls)"

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" schedule --to-sprint 2212 --keys "PROJ-1,PROJ-2" --dry-run --confirmed-site foo.atlassian.net
expect_rc "schedule --dry-run --keys -> exit 0" 0
equals "schedule --dry-run --keys: ZERO curl calls (no read, no write)" "$(call_count)" "0"
argv_log_not_has_token "schedule --dry-run: no POST recorded" "POST"
argv_log_not_has_token "schedule --dry-run: no PUT recorded" "PUT"
stdout_has "schedule --dry-run: names the intended change" "would move to sprint 2212"
stdout_has "schedule --dry-run: lists PROJ-1" "PROJ-1"
stdout_has "schedule --dry-run: lists PROJ-2" "PROJ-2"
stdout_has "schedule --dry-run: states nothing was written" "NOTHING WAS WRITTEN"

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" schedule --to-epic EPIC-9 --keys "PROJ-1,PROJ-2" --dry-run --json --confirmed-site foo.atlassian.net
expect_rc "schedule --dry-run --json -> exit 0" 0
equals "schedule --dry-run --json: ZERO curl calls" "$(call_count)" "0"
PLAN_JSON="$CUR_OUT"
equals "schedule --dry-run --json: willWrite is false" "$(printf '%s' "$PLAN_JSON" | jq -r '.willWrite')" "false"
equals "schedule --dry-run --json: op is to-epic" "$(printf '%s' "$PLAN_JSON" | jq -r '.op')" "to-epic"
equals "schedule --dry-run --json: keys array is the resolved set" \
	"$(printf '%s' "$PLAN_JSON" | jq -c '.keys')" '["PROJ-1","PROJ-2"]'

# --- partial failure: one issue's PUT fails, others still attempted --------
section "jira.sh — schedule --to-epic partial failure: #2 fails, #1 and #3 still attempted, exit non-zero"

reset_curl_stub
set_stub_response 1 '' 204                                            # PROJ-1 PUT ok
set_stub_response 2 '{"errorMessages":["Field parent cannot be set"]}' 400  # PROJ-2 PUT fails
set_stub_response 3 '' 204                                            # PROJ-3 PUT ok (still attempted)
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" schedule --to-epic EPIC-9 --keys "PROJ-1,PROJ-2,PROJ-3" --confirmed-site foo.atlassian.net
expect_rc "schedule --to-epic partial failure -> exit 1 (any failure => non-zero)" 1
equals "schedule partial failure: all 3 PUTs attempted (not aborted on #2)" "$(call_count)" "3"
file_has "schedule partial failure: PROJ-3's PUT WAS still issued after #2 failed" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/issue/PROJ-3"
stdout_has "schedule partial failure: PROJ-1 ok" "JIRA_SCHEDULE_RESULT=PROJ-1:ok"
stdout_has "schedule partial failure: PROJ-2 failed" "JIRA_SCHEDULE_RESULT=PROJ-2:failed"
stdout_has "schedule partial failure: PROJ-3 ok (processed despite #2 failing)" "JIRA_SCHEDULE_RESULT=PROJ-3:ok"
stdout_has "schedule partial failure: accurate summary" "JIRA_SCHEDULE_SUMMARY=2/3 succeeded"
stderr_has "schedule partial failure: Jira's own error surfaced for the failed issue" "Field parent cannot be set"

# --- batch (sprint) failure: the whole call 4xx -> all keys reported failed -
section "jira.sh — schedule --to-sprint batch failure: a non-2xx marks the whole set failed, exit non-zero"

reset_curl_stub
set_stub_response 1 '{"errorMessages":["Sprint does not exist"]}' 404
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" schedule --to-sprint 999 --keys "PROJ-1,PROJ-2" --confirmed-site foo.atlassian.net
expect_rc "schedule --to-sprint batch 404 -> exit 1" 1
stdout_has "schedule batch failure: PROJ-1 failed" "JIRA_SCHEDULE_RESULT=PROJ-1:failed"
stdout_has "schedule batch failure: PROJ-2 failed" "JIRA_SCHEDULE_RESULT=PROJ-2:failed"
stdout_has "schedule batch failure: summary 0/2" "JIRA_SCHEDULE_SUMMARY=0/2 succeeded"
stderr_has "schedule batch failure: Jira's own error surfaced" "Sprint does not exist"

# ===========================================================================
# Token never on argv — across ALL write commands (Phase 2b + Phase 2c)
# ===========================================================================
section "jira.sh — token never on argv (create/comment/transition/update/link/worklog/watch/vote)"

reset_curl_stub
set_stub_response 1 '{"id":"1","key":"PROJ-1","self":"x"}' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=distinctive-write-token" \
	sh "$JIRA" create --project PROJ --title "t" --confirmed-site foo.atlassian.net
file_not_has "create: token absent from argv" "$CURL_STUB_ARGV_LOG" "distinctive-write-token"
argv_log_not_has_token "create: -u absent" "-u"

reset_curl_stub
set_stub_response 1 '{"id":"1","body":{}}' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=distinctive-write-token" \
	sh "$JIRA" comment PROJ-1 --text-file "$COMMENT_FILE" --confirmed-site foo.atlassian.net
file_not_has "comment: token absent from argv" "$CURL_STUB_ARGV_LOG" "distinctive-write-token"

reset_curl_stub
set_stub_response 1 '{"fields":{"status":{"name":"Open"},"issuetype":{"name":"Task"}}}' 200
set_stub_response 2 '{"transitions":[{"id":"11","to":{"name":"In Progress"}}]}' 200
set_stub_response 3 '' 204
set_stub_response 4 '{"fields":{"status":{"name":"In Progress"}}}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=distinctive-write-token" "JIRA_PROJECTS_DIR=$WORK/projects" \
	sh "$JIRA" transition PROJ-1 --status "In Progress" --confirmed-site foo.atlassian.net
file_not_has "transition: token absent from argv across the whole walk" "$CURL_STUB_ARGV_LOG" "distinctive-write-token"

reset_curl_stub
set_stub_response 1 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=distinctive-write-token" \
	sh "$JIRA" update PROJ-1 --title "t" --confirmed-site foo.atlassian.net
file_not_has "update: token absent from argv" "$CURL_STUB_ARGV_LOG" "distinctive-write-token"

reset_curl_stub
set_stub_response 1 '' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=distinctive-write-token" \
	sh "$JIRA" link PROJ-1 --to PROJ-2 --link-type Blocks --confirmed-site foo.atlassian.net
file_not_has "link: token absent from argv" "$CURL_STUB_ARGV_LOG" "distinctive-write-token"

reset_curl_stub
set_stub_response 1 '{"id":"1","timeSpent":"1h"}' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=distinctive-write-token" \
	sh "$JIRA" worklog PROJ-1 --time-spent 1h --confirmed-site foo.atlassian.net
file_not_has "worklog: token absent from argv" "$CURL_STUB_ARGV_LOG" "distinctive-write-token"

reset_curl_stub
set_stub_response 1 '{"accountId":"acc-token-check"}' 200
set_stub_response 2 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=distinctive-write-token" \
	sh "$JIRA" watch PROJ-1 --confirmed-site foo.atlassian.net
file_not_has "watch: token absent from argv across the whole flow" "$CURL_STUB_ARGV_LOG" "distinctive-write-token"

reset_curl_stub
set_stub_response 1 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=distinctive-write-token" \
	sh "$JIRA" vote PROJ-1 --confirmed-site foo.atlassian.net
file_not_has "vote: token absent from argv" "$CURL_STUB_ARGV_LOG" "distinctive-write-token"

reset_curl_stub
set_stub_response 1 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=distinctive-write-token" \
	sh "$JIRA" schedule --to-sprint 2212 --keys "PROJ-1" --confirmed-site foo.atlassian.net
file_not_has "schedule: token absent from argv" "$CURL_STUB_ARGV_LOG" "distinctive-write-token"

# ===========================================================================
# Summary
# ===========================================================================
printf '\n%d tests, %d failed\n' "$TESTS_RUN" "$TESTS_FAIL"
[ "$TESTS_FAIL" -eq 0 ]
