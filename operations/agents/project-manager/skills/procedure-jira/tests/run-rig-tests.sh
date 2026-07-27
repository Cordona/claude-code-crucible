#!/usr/bin/env sh
#
# run-rig-tests.sh — self-contained, zero-network POSIX test harness for the
# guard logic of agile-test-rig.sh. It is the STAR deliverable of Cycle 2:
# it proves — with a STUBBED curl + a hand-written manifest FIXTURE — that the
# rig's guard_mutation() and safety invariants genuinely REFUSE to mutate a
# real, pre-existing, or unprovable artifact, and NEVER emit a mutation curl
# when they refuse.
#
# It reuses the SAME canned-response-queue curl stub the engine suite uses (see
# tests/run-engine-tests.sh): each curl call is logged (full argv, one token per
# line) and served the Nth queued response, so every assertion is a pure
# function of (manifest fixture, queued responses). NOTHING here touches a real
# Jira — the stub is the only `curl` on PATH.
#
# Usage:  sh run-rig-tests.sh          (also green under: dash run-rig-tests.sh)
# Exit 0 = all passed, 1 = one or more failed.
#
set -eu

TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
RIG="$TESTS_DIR/agile-test-rig.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/jira-rig-tests.XXXXXX")
TOOLBOX="$WORK/toolbox"
STUBCURL_DIR="$WORK/stubcurl"
mkdir -p "$TOOLBOX" "$STUBCURL_DIR" "$WORK/home"

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Isolated PATH toolbox: only the real tools the rig needs, plus the stub curl
# in its OWN dir (opted into per run).
# ---------------------------------------------------------------------------
ORIG_PATH=$PATH
link_tool() {
	target_dir=$1
	tool_name=$2
	tool_path=$(PATH="$ORIG_PATH" command -v "$tool_name" 2>/dev/null || true)
	[ -n "$tool_path" ] || { printf 'FATAL: required tool not found: %s\n' "$tool_name" >&2; exit 1; }
	ln -s "$tool_path" "$target_dir/$tool_name"
}
for t in sh mktemp sed grep tr cat rm chmod cp mv dirname mkdir od jq; do
	link_tool "$TOOLBOX" "$t"
done

# ---------------------------------------------------------------------------
# The curl stub — identical contract to the engine suite's: a canned-response
# QUEUE that logs every call's argv (one token per line) and serves the Nth
# response from CURL_STUB_RESP_DIR/resp-<n>.{body,code}.
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
# Curl-stub control: queue + logs, reset before every test.
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

set_stub_response() {
	n=$1; body=$2; code=$3
	printf '%s' "$body" >"$CURL_STUB_RESP_DIR/resp-$n.body"
	printf '%s' "$code" >"$CURL_STUB_RESP_DIR/resp-$n.code"
}

call_count() { cat "$CURL_STUB_COUNTER_FILE" 2>/dev/null || printf '0'; }

# count_method METHOD — how many logged curl calls used `-X METHOD`. The argv
# log lists each token on its own line, so an exact-line grep for the method
# right after a `-X` token would be ideal; a plain exact-line count of the
# method token is enough here because the rig only ever passes a method via -X.
count_method() {
	grep -Fxc -- "$1" "$CURL_STUB_ARGV_LOG" 2>/dev/null || printf '0'
}

# ---------------------------------------------------------------------------
# Manifest fixture builder. A run's manifest is a flat, greppable line log.
# write_manifest PATH — writes a canonical fixture: RUNID + one minted board
# (826000) + one minted sprint (2300) + one minted filter (5000), and a
# PRE-EXISTING deny-list (real board 826, real sprint 2212, real filter 100).
# ---------------------------------------------------------------------------
RUNID="deadbeefcafe1234"
write_manifest() {
	wm_path=$1
	{
		printf 'RUNID %s\n' "$RUNID"
		printf 'PROJ PSWS\n'
		printf 'FILTER 5000\n'
		printf 'BOARD 826000\n'
		printf 'MINTED filter 5000\n'
		printf 'MINTED board 826000\n'
		printf 'MINTED sprint 2300\n'
		printf 'PREEXISTING board 826\n'
		printf 'PREEXISTING sprint 2212\n'
		printf 'PREEXISTING filter 100\n'
	} >"$wm_path"
}

MANIFEST="$WORK/manifest.txt"

# ---------------------------------------------------------------------------
# Runner primitives (same shape as the engine harness).
# ---------------------------------------------------------------------------
TESTS_RUN=0
TESTS_FAIL=0
CUR_OUT=""
CUR_ERR=""
CUR_RC=0

run() {
	set +e
	env -i \
		HOME="$WORK/home" \
		PATH="$STUBCURL_DIR:$TOOLBOX" \
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
stderr_has() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if printf '%s\n' "$CUR_ERR" | grep -Fq -- "$2"; then pass "$1"
	else fail "$1" "stderr missing: $2
       stderr was: $CUR_ERR"; fi
}
stdout_has() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if printf '%s\n' "$CUR_OUT" | grep -Fq -- "$2"; then pass "$1"
	else fail "$1" "stdout missing: $2
       stdout was: $CUR_OUT"; fi
}
equals() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if [ "$2" = "$3" ]; then pass "$1"
	else fail "$1" "expected: $3
       got:      $2"; fi
}
argv_log_not_has_token() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if grep -Fxq -- "$2" "$CURL_STUB_ARGV_LOG"; then fail "$1" "argv log unexpectedly contains the exact token: $2"
	else pass "$1"; fi
}
argv_log_has_token() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if grep -Fxq -- "$2" "$CURL_STUB_ARGV_LOG"; then pass "$1"
	else fail "$1" "argv log missing the exact token: $2"; fi
}

# manifest_has_line / manifest_not_has_line — EXACT whole-line match (grep -Fxq)
# against a manifest file, the same strictness the rig's own manifest_minted_has
# uses: a substring test for "PREEXISTING board 826" would also match
# "...826000", proving nothing.
manifest_has_line() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if [ -f "$2" ] && grep -Fxq -- "$3" "$2"; then pass "$1"
	else fail "$1" "$2 missing exact line: $3"; fi
}
manifest_not_has_line() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if [ -f "$2" ] && grep -Fxq -- "$3" "$2"; then fail "$1" "$2 unexpectedly contains exact line: $3"
	else pass "$1"; fi
}
section() { printf '\n== %s ==\n' "$1"; }

SITE="foo.atlassian.net"

# A board object whose name CARRIES the RUNID — a provenance MATCH.
BOARD_OK="{\"id\":826000,\"name\":\"CRUCIBLE-EPHEMERAL-${RUNID}-board\",\"type\":\"scrum\"}"
# A board object whose name does NOT carry the RUNID — provenance MISMATCH.
BOARD_WRONG='{"id":826000,"name":"Team Alpha Delivery Board","type":"scrum"}'

# ===========================================================================
section "rig guard_mutation — ACCEPTS a properly minted + provenance-matching id"
# ===========================================================================
# guard-check board 826000: manifest says minted, not preexisting; the GET'd
# board name carries the RUNID -> guard PASSES -> the sentinel DELETE is issued.
#   call 1 = provenance GET (board, name carries RUNID)
#   call 2 = sentinel DELETE
reset_curl_stub
write_manifest "$MANIFEST"
set_stub_response 1 "$BOARD_OK" 200
set_stub_response 2 '' 204
run "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$RIG" guard-check board 826000 --confirmed-site "$SITE" --manifest "$MANIFEST"
expect_rc "accept: minted+provenance-matching board -> exit 0" 0
argv_log_has_token "accept: the sentinel DELETE mutation WAS emitted" "DELETE"
equals "accept: exactly two calls (provenance GET + DELETE)" "$(call_count)" "2"
equals "accept: exactly ONE DELETE" "$(count_method DELETE)" "1"

# ===========================================================================
section "rig guard_mutation — REFUSES a PRE-EXISTING (real) id, emits NO mutation"
# ===========================================================================
# The deny-list is DEFENSE-IN-DEPTH: even an id that somehow appears in the
# minted set is STILL refused if it is also in the pre-existing set. This
# fixture puts board 826 in BOTH sets so check (a) passes and the deny-list
# check (b) is the one that fires — a pure manifest read, ZERO curl, NO DELETE.
DENY_MANIFEST="$WORK/deny-manifest.txt"
{
	printf 'RUNID %s\n' "$RUNID"
	printf 'MINTED board 826\n'
	printf 'PREEXISTING board 826\n'
} >"$DENY_MANIFEST"
reset_curl_stub
run "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$RIG" guard-check board 826 --confirmed-site "$SITE" --manifest "$DENY_MANIFEST"
expect_rc "refuse-preexisting: -> exit 3 (guard refusal)" 3
stderr_has "refuse-preexisting: names the deny-list" "PRE-EXISTING deny-list"
argv_log_not_has_token "refuse-preexisting: NO DELETE mutation emitted" "DELETE"
equals "refuse-preexisting: ZERO curl calls (manifest-only refusal)" "$(call_count)" "0"

# ===========================================================================
section "rig guard_mutation — REFUSES an id NOT in minted (typo/foreign), NO mutation"
# ===========================================================================
# board 999999 was never minted. Refusal fires at check (a) -> ZERO curl calls.
reset_curl_stub
write_manifest "$MANIFEST"
run "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$RIG" guard-check board 999999 --confirmed-site "$SITE" --manifest "$MANIFEST"
expect_rc "refuse-not-minted: -> exit 3" 3
stderr_has "refuse-not-minted: names the minted set" "NOT in the run manifest's minted set"
argv_log_not_has_token "refuse-not-minted: NO DELETE mutation emitted" "DELETE"
equals "refuse-not-minted: ZERO curl calls" "$(call_count)" "0"

# ===========================================================================
section "rig guard_mutation — REFUSES on wrong PROVENANCE (name lacks RUNID), NO mutation"
# ===========================================================================
# board 826000 IS minted + not preexisting, so checks (a)/(b) pass; but the
# GET'd board name does NOT carry the RUNID -> refuse at (c). Exactly ONE curl
# (the provenance GET) and NO DELETE.
reset_curl_stub
write_manifest "$MANIFEST"
set_stub_response 1 "$BOARD_WRONG" 200
run "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$RIG" guard-check board 826000 --confirmed-site "$SITE" --manifest "$MANIFEST"
expect_rc "refuse-provenance: -> exit 3" 3
stderr_has "refuse-provenance: names the provenance failure" "failed provenance"
argv_log_not_has_token "refuse-provenance: NO DELETE mutation emitted" "DELETE"
equals "refuse-provenance: exactly ONE curl (the provenance GET)" "$(call_count)" "1"

# ===========================================================================
section "rig guard_mutation — sprint provenance via originBoardId -> minted board name"
# ===========================================================================
# guard-check sprint 2300 (minted). Provenance = GET sprint -> originBoardId
# (826000, a minted board) -> GET that board -> name carries RUNID -> ACCEPT.
#   call 1 = GET sprint (originBoardId=826000)
#   call 2 = GET board 826000 (name carries RUNID)
#   call 3 = sentinel DELETE sprint
reset_curl_stub
write_manifest "$MANIFEST"
set_stub_response 1 '{"id":2300,"name":"Sprint 1","state":"future","originBoardId":826000}' 200
set_stub_response 2 "$BOARD_OK" 200
set_stub_response 3 '' 204
run "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$RIG" guard-check sprint 2300 --confirmed-site "$SITE" --manifest "$MANIFEST"
expect_rc "accept-sprint: minted sprint w/ minted origin board -> exit 0" 0
argv_log_has_token "accept-sprint: sentinel DELETE emitted" "DELETE"
equals "accept-sprint: three calls (sprint GET + board GET + DELETE)" "$(call_count)" "3"

# A sprint whose originBoardId is a REAL (non-minted) board must be REFUSED even
# though the sprint id itself is minted — the origin board is not ours.
reset_curl_stub
write_manifest "$MANIFEST"
set_stub_response 1 '{"id":2300,"name":"Sprint 1","state":"future","originBoardId":826}' 200
run "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$RIG" guard-check sprint 2300 --confirmed-site "$SITE" --manifest "$MANIFEST"
expect_rc "refuse-sprint-origin: origin board not minted -> exit 3" 3
stderr_has "refuse-sprint-origin: names the provenance failure" "failed provenance"
argv_log_not_has_token "refuse-sprint-origin: NO DELETE emitted" "DELETE"
equals "refuse-sprint-origin: exactly ONE curl (the sprint GET; no board GET, no DELETE)" "$(call_count)" "1"

# ===========================================================================
section "rig guard_mutation — REFUSES a manifest with NO RUNID line, emits NO mutation"
# ===========================================================================
# The run token is the thread every provenance check hangs on. A manifest that
# lists a minted id but carries no RUNID is untrustworthy — refuse at the RUNID
# gate: exit 3, ZERO curl, NO DELETE. (board 826000 IS minted here, so this
# proves the RUNID gate fires BEFORE the minted-set check.)
NORUNID_MANIFEST="$WORK/norunid-manifest.txt"
{
	printf 'PROJ PSWS\n'
	printf 'MINTED board 826000\n'
} >"$NORUNID_MANIFEST"
reset_curl_stub
run "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$RIG" guard-check board 826000 --confirmed-site "$SITE" --manifest "$NORUNID_MANIFEST"
expect_rc "refuse-no-runid: -> exit 3" 3
stderr_has "refuse-no-runid: names the missing RUNID" "has no RUNID"
argv_log_not_has_token "refuse-no-runid: NO DELETE mutation emitted" "DELETE"
equals "refuse-no-runid: ZERO curl calls (manifest-only refusal)" "$(call_count)" "0"

# ===========================================================================
section "rig guard_mutation — REFUSES a manifest RUNID of the wrong shape (forged/low-entropy)"
# ===========================================================================
# A forged manifest carrying a too-short/non-hex RUNID must not slip a weak
# token past the guard: the substring provenance match would be trivially
# satisfiable. Refuse at the RUNID-shape gate — ZERO curl, NO DELETE.
FORGED_MANIFEST="$WORK/forged-manifest.txt"
{
	printf 'RUNID abc\n'
	printf 'MINTED board 826000\n'
} >"$FORGED_MANIFEST"
reset_curl_stub
run "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$RIG" guard-check board 826000 --confirmed-site "$SITE" --manifest "$FORGED_MANIFEST"
expect_rc "forged-runid: -> exit 3" 3
stderr_has "forged-runid: names the invalid run token" "not a valid run token"
argv_log_not_has_token "forged-runid: NO DELETE mutation emitted" "DELETE"
equals "forged-runid: ZERO curl calls (refused at the RUNID-shape gate)" "$(call_count)" "0"

# ===========================================================================
section "rig setup — REJECTS an invalid --runid override before any mint/network"
# ===========================================================================
# An injected --runid is untrusted: a hex-but-too-short token (8 chars < 16)
# must be rejected as a usage error (exit 2) BEFORE setup mints or touches the
# network — closing the forged-manifest seed at its source.
reset_curl_stub
run "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$RIG" setup --project PSWS --runid deadbeef --confirmed-site "$SITE" --manifest "$WORK/sec-manifest.txt"
expect_rc "bad --runid override (too short) -> exit 2" 2
stderr_has "bad --runid: diagnostic names the required shape" "lowercase-hex"
equals "bad --runid: no curl call was made" "$(call_count)" "0"

# ===========================================================================
section "rig guard_mutation — the FILTER artifact kind: ACCEPT vs REFUSE"
# ===========================================================================
# A filter whose GET'd name CARRIES the RUNID -> provenance MATCH.
FILTER_OK="{\"id\":5000,\"name\":\"CRUCIBLE-EPHEMERAL-${RUNID}-filter\"}"
# A filter whose name does NOT carry the RUNID -> provenance MISMATCH.
FILTER_WRONG='{"id":5000,"name":"Shared Team Filter"}'
# ACCEPT: filter 5000 is minted (write_manifest) + name carries RUNID -> DELETE.
#   call 1 = provenance GET (filter, name carries RUNID) ; call 2 = sentinel DELETE
reset_curl_stub
write_manifest "$MANIFEST"
set_stub_response 1 "$FILTER_OK" 200
set_stub_response 2 '' 204
run "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$RIG" guard-check filter 5000 --confirmed-site "$SITE" --manifest "$MANIFEST"
expect_rc "accept-filter: minted+provenance-matching filter -> exit 0" 0
argv_log_has_token "accept-filter: the sentinel DELETE mutation WAS emitted" "DELETE"
equals "accept-filter: exactly two calls (provenance GET + DELETE)" "$(call_count)" "2"

# REFUSE: filter 5000 minted, but the GET'd name lacks the RUNID -> refuse at (c).
reset_curl_stub
write_manifest "$MANIFEST"
set_stub_response 1 "$FILTER_WRONG" 200
run "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$RIG" guard-check filter 5000 --confirmed-site "$SITE" --manifest "$MANIFEST"
expect_rc "refuse-filter: name lacks RUNID -> exit 3" 3
stderr_has "refuse-filter: names the provenance failure" "failed provenance"
argv_log_not_has_token "refuse-filter: NO DELETE mutation emitted" "DELETE"
equals "refuse-filter: exactly ONE curl (the provenance GET)" "$(call_count)" "1"

# ===========================================================================
section "rig teardown — deletes a minted FILTER (guarded), verifies 404 (LAYER 5)"
# ===========================================================================
# A manifest with a SINGLE minted filter. Teardown: provenance GET -> DELETE ->
# verify GET (404 = gone) -> exit 0.
FILTER_TD_MANIFEST="$WORK/filter-td-manifest.txt"
{
	printf 'RUNID %s\n' "$RUNID"
	printf 'MINTED filter 5000\n'
} >"$FILTER_TD_MANIFEST"
reset_curl_stub
set_stub_response 1 "$FILTER_OK" 200
set_stub_response 2 '' 204
set_stub_response 3 '{"errorMessages":["not found"]}' 404
run "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$RIG" teardown --confirmed-site "$SITE" --manifest "$FILTER_TD_MANIFEST"
expect_rc "teardown-filter: 404 after delete -> exit 0" 0
stderr_has "teardown-filter: reports verified gone" "deleted + verified gone: filter 5000"
argv_log_has_token "teardown-filter: hits the /rest/api/3/filter/5000 endpoint" "https://foo.atlassian.net/rest/api/3/filter/5000"

# ===========================================================================
section "rig register-sprint — provenance ACCEPT vs REFUSE"
# ===========================================================================
# ACCEPT: sprint 4400's originBoardId is a MINTED board (826000) whose name
# carries the RUNID -> the sprint is appended to the MINTED set (no DELETE — this
# only registers). Two provenance calls: GET sprint -> GET origin board.
reset_curl_stub
write_manifest "$MANIFEST"
set_stub_response 1 '{"id":4400,"name":"Sprint X","state":"future","originBoardId":826000}' 200
set_stub_response 2 "$BOARD_OK" 200
run "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$RIG" register-sprint 4400 --confirmed-site "$SITE" --manifest "$MANIFEST"
expect_rc "register-accept: minted-origin sprint -> exit 0" 0
equals "register-accept: two provenance calls (sprint GET + origin board GET)" "$(call_count)" "2"
argv_log_not_has_token "register-accept: register issues NO mutation (append-only)" "DELETE"
manifest_has_line "register-accept: sprint appended to the MINTED set" "$MANIFEST" "MINTED sprint 4400"

# REFUSE: sprint 4400's originBoardId is a REAL (non-minted) board (826) -> refuse
# at provenance, write NOTHING. Exactly ONE curl (the sprint GET); the board GET
# never fires because the minted-board check on the origin id short-circuits it.
reset_curl_stub
write_manifest "$MANIFEST"
set_stub_response 1 '{"id":4400,"name":"Sprint X","state":"future","originBoardId":826}' 200
run "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$RIG" register-sprint 4400 --confirmed-site "$SITE" --manifest "$MANIFEST"
expect_rc "register-refuse: non-minted origin board -> exit 3" 3
stderr_has "register-refuse: names the provenance failure" "failed provenance"
manifest_not_has_line "register-refuse: sprint NOT written to the manifest" "$MANIFEST" "MINTED sprint 4400"
equals "register-refuse: exactly ONE curl (sprint GET; refused before the board GET)" "$(call_count)" "1"

# ===========================================================================
section "rig setup — the layer-2 deny-list BUILDER (paginated boards + per-board sprints)"
# ===========================================================================
# Drive the real setup end to end under the stub with an injected --runid, and
# assert the produced manifest carries the full MINTED + PREEXISTING deny-list.
# Boards paginate across TWO pages (multi-page walk); one pre-existing board
# answers /sprint with a 4xx (kanban) and is tolerated + skipped.
#   call 1 = boards page 1 (826,900; isLast=false)
#   call 2 = boards page 2 (901; isLast=true)
#   call 3 = board 826 sprints (2212)
#   call 4 = board 900 sprints (400 kanban -> skip)
#   call 5 = board 901 sprints (empty)
#   call 6 = create filter (id 5000)
#   call 7 = create board  (id 826000)
#   call 8 = empty-board backlog check (total 0)
BUILDER_RUNID="abcdef0123456789"
BUILDER_MANIFEST="$WORK/builder-manifest.txt"
reset_curl_stub
set_stub_response 1 '{"values":[{"id":826},{"id":900}],"isLast":false}' 200
set_stub_response 2 '{"values":[{"id":901}],"isLast":true}' 200
set_stub_response 3 '{"values":[{"id":2212}],"isLast":true}' 200
set_stub_response 4 '{"errorMessages":["Board 900 is not a scrum board"]}' 400
set_stub_response 5 '{"values":[],"isLast":true}' 200
set_stub_response 6 '{"id":5000}' 200
set_stub_response 7 '{"id":826000}' 200
set_stub_response 8 '{"maxResults":1,"startAt":0,"total":0,"issues":[]}' 200
run "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$RIG" setup --project PSWS --runid "$BUILDER_RUNID" --confirmed-site "$SITE" --manifest "$BUILDER_MANIFEST"
expect_rc "setup-builder: -> exit 0" 0
equals "setup-builder: exactly 8 curl calls (2 board pages + 3 sprint walks + filter + board + backlog)" "$(call_count)" "8"
manifest_has_line "setup-builder: records the injected RUNID" "$BUILDER_MANIFEST" "RUNID $BUILDER_RUNID"
manifest_has_line "setup-builder: records the project" "$BUILDER_MANIFEST" "PROJ PSWS"
manifest_has_line "setup-builder: MINTED filter" "$BUILDER_MANIFEST" "MINTED filter 5000"
manifest_has_line "setup-builder: MINTED board" "$BUILDER_MANIFEST" "MINTED board 826000"
manifest_has_line "setup-builder: PREEXISTING board 826 (page 1)" "$BUILDER_MANIFEST" "PREEXISTING board 826"
manifest_has_line "setup-builder: PREEXISTING board 900 (page 1)" "$BUILDER_MANIFEST" "PREEXISTING board 900"
manifest_has_line "setup-builder: PREEXISTING board 901 (page 2 — multi-page walk)" "$BUILDER_MANIFEST" "PREEXISTING board 901"
manifest_has_line "setup-builder: PREEXISTING sprint 2212 (walked per board)" "$BUILDER_MANIFEST" "PREEXISTING sprint 2212"
manifest_not_has_line "setup-builder: the kanban board 900 contributed NO sprint line" "$BUILDER_MANIFEST" "PREEXISTING sprint 900"

# ===========================================================================
section "rig full — the real sprint lifecycle end-to-end (setup -> create -> register -> start -> close -> teardown)"
# ===========================================================================
# The whole reason the rig exists: setup mints a board, `full` then drives
# jira.sh's REAL sprint WRITE verbs (create/start/close) against it, registers
# the created sprint into the manifest, and teardown guard-deletes filter, board,
# AND the now-registered sprint. Every jira.sh curl routes through the SAME stub.
#   setup:     1 boards page (empty) + create filter + create board + backlog  (calls 1-4)
#   lifecycle: jira.sh sprint --create (5); register provenance GET sprint (6) + GET board (7);
#              jira.sh sprint --start (8); jira.sh sprint --close (9)
#   teardown:  sprint 3300 [prov GET sprint (10) + GET board (11) + DELETE (12) + verify 404 (13)];
#              board 826000 [prov GET (14) + DELETE (15) + verify 404 (16)];
#              filter 5000  [prov GET (17) + DELETE (18) + verify 404 (19)]
FULL_MANIFEST="$WORK/full-manifest.txt"
reset_curl_stub
set_stub_response 1 '{"values":[],"isLast":true}' 200
set_stub_response 2 '{"id":5000}' 200
set_stub_response 3 '{"id":826000}' 200
set_stub_response 4 '{"maxResults":1,"startAt":0,"total":0,"issues":[]}' 200
set_stub_response 5 "{\"id\":3300,\"name\":\"CRUCIBLE-EPHEMERAL-${RUNID}-sprint\",\"state\":\"future\",\"originBoardId\":826000}" 201
set_stub_response 6 '{"id":3300,"name":"S","state":"future","originBoardId":826000}' 200
set_stub_response 7 "$BOARD_OK" 200
set_stub_response 8 '{"id":3300,"state":"active"}' 200
set_stub_response 9 '{"id":3300,"state":"closed"}' 200
set_stub_response 10 '{"id":3300,"name":"S","state":"closed","originBoardId":826000}' 200
set_stub_response 11 "$BOARD_OK" 200
set_stub_response 12 '' 204
set_stub_response 13 '{"errorMessages":["not found"]}' 404
set_stub_response 14 "$BOARD_OK" 200
set_stub_response 15 '' 204
set_stub_response 16 '{"errorMessages":["not found"]}' 404
set_stub_response 17 "{\"id\":5000,\"name\":\"CRUCIBLE-EPHEMERAL-${RUNID}-filter\"}" 200
set_stub_response 18 '' 204
set_stub_response 19 '{"errorMessages":["not found"]}' 404
run "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$RIG" full --project PSWS --runid "$RUNID" --confirmed-site "$SITE" --manifest "$FULL_MANIFEST"
expect_rc "full-lifecycle: -> exit 0" 0
manifest_has_line "full-lifecycle: the created sprint was registered as minted" "$FULL_MANIFEST" "MINTED sprint 3300"
stderr_has "full-lifecycle: created the sprint via jira.sh" "created sprint 3300 via jira.sh"
stderr_has "full-lifecycle: started the sprint" "started sprint 3300"
stderr_has "full-lifecycle: closed the sprint" "closed sprint 3300"
stderr_has "full-lifecycle: teardown removed the registered sprint" "deleted + verified gone: sprint 3300"
stderr_has "full-lifecycle: teardown removed the board" "deleted + verified gone: board 826000"
stderr_has "full-lifecycle: teardown removed the filter" "deleted + verified gone: filter 5000"
stderr_has "full-lifecycle: teardown complete" "teardown complete"

# ===========================================================================
section "rig setup — empty-board invariant (LAYER 4)"
# ===========================================================================
# A backlog with ZERO issues passes the invariant.
reset_curl_stub
set_stub_response 1 '{"maxResults":1,"startAt":0,"total":0,"issues":[]}' 200
run "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$RIG" empty-board-check 826000 --confirmed-site "$SITE"
expect_rc "empty-board: empty backlog -> exit 0" 0
stderr_has "empty-board: reports the invariant holds" "invariant holds"

# A NON-EMPTY backlog ABORTS loudly (someone reused the run label on a real ticket).
reset_curl_stub
set_stub_response 1 '{"maxResults":1,"startAt":0,"total":3,"issues":[{"key":"PSWS-1"}]}' 200
run "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$RIG" empty-board-check 826000 --confirmed-site "$SITE"
expect_rc "empty-board: non-empty backlog -> exit 5" 5
stderr_has "empty-board: loud abort names the invariant" "EMPTY-BOARD INVARIANT FAILED"

# ===========================================================================
section "rig teardown — deletes minted ids, verifies 404, reports a SURVIVOR loudly (LAYER 5)"
# ===========================================================================
# A manifest with a SINGLE minted board. Teardown: guard provenance GET (name
# carries RUNID) -> DELETE -> verify GET. When the verify GET still returns 200,
# the board SURVIVED -> loud exit 4.
#   call 1 = provenance GET (board name carries RUNID)   [guard_mutation]
#   call 2 = DELETE board                                 [204]
#   call 3 = verify GET                                   [200 -> SURVIVOR]
SURV_MANIFEST="$WORK/surv-manifest.txt"
{
	printf 'RUNID %s\n' "$RUNID"
	printf 'MINTED board 826000\n'
} >"$SURV_MANIFEST"
reset_curl_stub
set_stub_response 1 "$BOARD_OK" 200
set_stub_response 2 '' 204
set_stub_response 3 "$BOARD_OK" 200
run "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$RIG" teardown --confirmed-site "$SITE" --manifest "$SURV_MANIFEST"
expect_rc "teardown-survivor: a survivor -> exit 4" 4
stderr_has "teardown-survivor: loud SURVIVOR report" "SURVIVOR: board 826000"
stderr_has "teardown-survivor: names manual cleanup" "TEARDOWN INCOMPLETE"

# The clean case: the verify GET returns 404 -> deleted + verified gone -> exit 0.
reset_curl_stub
set_stub_response 1 "$BOARD_OK" 200
set_stub_response 2 '' 204
set_stub_response 3 '{"errorMessages":["not found"]}' 404
run "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$RIG" teardown --confirmed-site "$SITE" --manifest "$SURV_MANIFEST"
expect_rc "teardown-clean: 404 after delete -> exit 0" 0
stderr_has "teardown-clean: reports verified gone" "deleted + verified gone: board 826000"

# Teardown must REFUSE to delete a MINTED id whose provenance fails — fail
# closed, aborting rather than deleting blindly. (Board name lacks the RUNID.)
reset_curl_stub
set_stub_response 1 "$BOARD_WRONG" 200
run "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$RIG" teardown --confirmed-site "$SITE" --manifest "$SURV_MANIFEST"
expect_rc "teardown-provenance: minted id that fails provenance -> exit 3" 3
argv_log_not_has_token "teardown-provenance: NO DELETE emitted" "DELETE"

# ===========================================================================
section "rig — host fail-closed + usage guards (no network)"
# ===========================================================================
reset_curl_stub
write_manifest "$MANIFEST"
run "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$RIG" guard-check board 826000 --confirmed-site "evil.example.com" --manifest "$MANIFEST"
expect_rc "host outside allow-list -> exit 1" 1
stderr_has "host outside allow-list: diagnostic" "not an *.atlassian.net host"
equals "host fail-closed: no curl call was made" "$(call_count)" "0"

run "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$RIG" guard-check board 826000 --manifest "$MANIFEST"
expect_rc "missing --confirmed-site -> exit 2" 2
stderr_has "missing --confirmed-site: diagnostic" "--confirmed-site SITE is required"

run "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$RIG" guard-check board notanid --confirmed-site "$SITE" --manifest "$MANIFEST"
expect_rc "guard-check non-numeric id -> exit 2" 2
stderr_has "guard-check non-numeric id: diagnostic" "requires a numeric ID"

run "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$RIG" bogus-sub --confirmed-site "$SITE"
expect_rc "unknown subcommand -> exit 2" 2
stderr_has "unknown subcommand: diagnostic" "unknown subcommand"

# ===========================================================================
section "rig_sprint_create wrapper — REFUSES a non-minted board, emits NO engine call"
# ===========================================================================
# board 999999 was never minted. The wrapper's minted-assertion is a PURE
# manifest read, so it refuses (exit 3) BEFORE jira.sh is ever invoked -> ZERO
# curl calls, NO POST to the sprint-create endpoint.
reset_curl_stub
write_manifest "$MANIFEST"
run "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$RIG" sprint-create 999999 --confirmed-site "$SITE" --manifest "$MANIFEST"
expect_rc "sprint_create-refuse: non-minted board -> exit 3" 3
stderr_has "sprint_create-refuse: names the minted-set failure" "NOT in the run manifest's minted set"
argv_log_not_has_token "sprint_create-refuse: NO create mutation emitted (POST url absent)" "https://foo.atlassian.net/rest/agile/1.0/sprint"
equals "sprint_create-refuse: ZERO curl calls (engine never invoked)" "$(call_count)" "0"

# ===========================================================================
section "rig_sprint_create wrapper — REFUSES a minted-but-DENY-LISTED board (belt-and-suspenders)"
# ===========================================================================
# A forged manifest where board 826 is BOTH minted and pre-existing: the minted
# check (a) passes, the deny-list check (b) fires -> refuse, NO engine call.
SC_DENY_MANIFEST="$WORK/sc-deny-manifest.txt"
{
	printf 'RUNID %s\n' "$RUNID"
	printf 'MINTED board 826\n'
	printf 'PREEXISTING board 826\n'
} >"$SC_DENY_MANIFEST"
reset_curl_stub
run "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$RIG" sprint-create 826 --confirmed-site "$SITE" --manifest "$SC_DENY_MANIFEST"
expect_rc "sprint_create-deny: minted+deny-listed board -> exit 3" 3
stderr_has "sprint_create-deny: names the deny-list" "PRE-EXISTING deny-list"
equals "sprint_create-deny: ZERO curl calls (engine never invoked)" "$(call_count)" "0"

# ===========================================================================
section "rig_sprint_create wrapper — ACCEPTS a minted board, DRIVES the engine (one create POST)"
# ===========================================================================
# board 826000 IS minted + not deny-listed -> the wrapper invokes jira.sh, which
# POSTs exactly once to the sprint-create endpoint. The engine call is proven via
# the stub argv log (the create URL is present).
reset_curl_stub
write_manifest "$MANIFEST"
set_stub_response 1 "{\"id\":7001,\"name\":\"CRUCIBLE-EPHEMERAL-seam-sprint\",\"state\":\"future\",\"originBoardId\":826000}" 201
run "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$RIG" sprint-create 826000 --confirmed-site "$SITE" --manifest "$MANIFEST"
expect_rc "sprint_create-accept: minted board -> exit 0" 0
argv_log_has_token "sprint_create-accept: engine POSTed to the sprint-create endpoint" "https://foo.atlassian.net/rest/agile/1.0/sprint"
equals "sprint_create-accept: exactly ONE curl call (the engine's create POST)" "$(call_count)" "1"

# ===========================================================================
section "rig_sprint_start/close/update wrappers — REFUSE a non-minted sprint, NO engine call"
# ===========================================================================
# sprint 888888 was never minted/registered. Each wrapper's minted-assertion is a
# pure manifest read -> refuse (exit 3) with ZERO curl, NO engine call.
for verb in start close update; do
	reset_curl_stub
	write_manifest "$MANIFEST"
	run "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
		sh "$RIG" "sprint-$verb" 888888 --confirmed-site "$SITE" --manifest "$MANIFEST"
	expect_rc "sprint_$verb-refuse: non-minted sprint -> exit 3" 3
	stderr_has "sprint_$verb-refuse: names the minted-set failure" "NOT in the run manifest's minted set"
	argv_log_not_has_token "sprint_$verb-refuse: NO mutation emitted (POST url absent)" "https://foo.atlassian.net/rest/agile/1.0/sprint/888888"
	equals "sprint_$verb-refuse: ZERO curl calls (engine never invoked)" "$(call_count)" "0"
done

# ===========================================================================
section "rig_sprint_start/close/update wrappers — ACCEPT a minted sprint, DRIVE the engine"
# ===========================================================================
# sprint 2300 IS minted (write_manifest) + not deny-listed -> each wrapper invokes
# jira.sh, which POSTs exactly once to /sprint/2300. Proven via the argv log.
for verb in start close update; do
	reset_curl_stub
	write_manifest "$MANIFEST"
	set_stub_response 1 '{"id":2300,"state":"active"}' 200
	run "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
		sh "$RIG" "sprint-$verb" 2300 --confirmed-site "$SITE" --manifest "$MANIFEST"
	expect_rc "sprint_$verb-accept: minted sprint -> exit 0" 0
	argv_log_has_token "sprint_$verb-accept: engine POSTed to /sprint/2300" "https://foo.atlassian.net/rest/agile/1.0/sprint/2300"
	equals "sprint_$verb-accept: exactly ONE curl call (the engine's write POST)" "$(call_count)" "1"
done

# ===========================================================================
section "rig provision — stands up 3 sprints (future/active/closed), LEAVES THEM STANDING (no teardown)"
# ===========================================================================
# provision runs setup, then creates 3 sprints via the guarded wrappers, each
# provenance-registered, in states future/active/closed — and NEVER tears down.
# The 16-call sequence (ZERO deletes):
#   setup:  boards page empty (1) + create filter (2) + create board (3) + backlog (4)
#   future: create (5); register GET sprint (6) + GET board (7)
#   active: create (8); register GET sprint (9) + GET board (10); start (11)
#   closed: create (12); register GET sprint (13) + GET board (14); start (15); close (16)
PROV_MANIFEST="$WORK/provision-manifest.txt"
reset_curl_stub
set_stub_response 1 '{"values":[],"isLast":true}' 200
set_stub_response 2 '{"id":5000}' 200
set_stub_response 3 '{"id":826000}' 200
set_stub_response 4 '{"maxResults":1,"startAt":0,"total":0,"issues":[]}' 200
set_stub_response 5 "{\"id\":3301,\"name\":\"[CRUCIBLE][TEST] future ${RUNID}\",\"state\":\"future\",\"originBoardId\":826000}" 201
set_stub_response 6 '{"id":3301,"name":"S","state":"future","originBoardId":826000}' 200
set_stub_response 7 "$BOARD_OK" 200
set_stub_response 8 "{\"id\":3302,\"name\":\"[CRUCIBLE][TEST] active ${RUNID}\",\"state\":\"future\",\"originBoardId\":826000}" 201
set_stub_response 9 '{"id":3302,"name":"S","state":"future","originBoardId":826000}' 200
set_stub_response 10 "$BOARD_OK" 200
set_stub_response 11 '{"id":3302,"state":"active"}' 200
set_stub_response 12 "{\"id\":3303,\"name\":\"[CRUCIBLE][TEST] closed ${RUNID}\",\"state\":\"future\",\"originBoardId\":826000}" 201
set_stub_response 13 '{"id":3303,"name":"S","state":"future","originBoardId":826000}' 200
set_stub_response 14 "$BOARD_OK" 200
set_stub_response 15 '{"id":3303,"state":"active"}' 200
set_stub_response 16 '{"id":3303,"state":"closed"}' 200
run "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$RIG" provision --project PSWS --runid "$RUNID" --confirmed-site "$SITE" --manifest "$PROV_MANIFEST"
expect_rc "provision: -> exit 0" 0
equals "provision: exactly 16 curl calls (setup 4 + 3x[create+2 register] + start + start + close)" "$(call_count)" "16"
argv_log_not_has_token "provision: NO DELETE emitted (world LEFT STANDING, no teardown)" "DELETE"
manifest_has_line "provision: records the injected RUNID" "$PROV_MANIFEST" "RUNID $RUNID"
manifest_has_line "provision: MINTED filter" "$PROV_MANIFEST" "MINTED filter 5000"
manifest_has_line "provision: MINTED board" "$PROV_MANIFEST" "MINTED board 826000"
manifest_has_line "provision: MINTED future sprint 3301" "$PROV_MANIFEST" "MINTED sprint 3301"
manifest_has_line "provision: MINTED active sprint 3302" "$PROV_MANIFEST" "MINTED sprint 3302"
manifest_has_line "provision: MINTED closed sprint 3303" "$PROV_MANIFEST" "MINTED sprint 3303"
stdout_has "provision: report prints the future sprint id" "sprint future:  3301"
stdout_has "provision: report prints the active sprint id" "sprint active:  3302"
stdout_has "provision: report prints the closed sprint id" "sprint closed:  3303"
stdout_has "provision: report prints the board id" "board id:       826000"
stdout_has "provision: report prints the filter id" "filter id:      5000"
stdout_has "provision: report prints the manifest path" "manifest:       $PROV_MANIFEST"
stdout_has "provision: report states the world is LEFT STANDING" "LEFT STANDING"
stderr_has "provision: left the active sprint ACTIVE" "started sprint 3302 (left ACTIVE)"
stderr_has "provision: left the closed sprint CLOSED" "closed sprint 3303 (left CLOSED)"

# ===========================================================================
# Summary
# ===========================================================================
printf '\n%d tests, %d failed\n' "$TESTS_RUN" "$TESTS_FAIL"
[ "$TESTS_FAIL" -eq 0 ]
