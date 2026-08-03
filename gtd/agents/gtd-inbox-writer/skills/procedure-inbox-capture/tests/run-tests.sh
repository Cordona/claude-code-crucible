#!/usr/bin/env sh
#
# run-tests.sh — self-contained, zero-dependency POSIX test harness for
#                capture.sh (the gtd-inbox-writer agent's sole script).
#
# WHY a hand-rolled harness (not bats), modeled on procedure-gh-issues's:
# capture.sh claims to run with no dependency beyond `jq` + coreutils, so
# the test harness must make the same claim.
#
# What it does:
#   * Builds an isolated PATH "toolbox" of symlinks to only the real tools
#     capture.sh needs, MINUS `jq` — jq lives in its OWN dir that a test
#     opts into via the `run` helper's first argument, so "jq absent" is
#     exercised for real (by leaving that dir off PATH), the same technique
#     procedure-gh-issues/tests/run-tests.sh uses for the `gh` stub. (Modern
#     macOS bundles jq at /usr/bin/jq, so simply narrowing $PATH to
#     /usr/bin:/bin would NOT exclude it — an isolated toolbox is required.)
#   * Every run of capture.sh uses INBOX_FILE pointed at a fresh path under
#     an isolated WORK dir — the real $HOME/.claude/crucible/gtd/inbox.jsonl
#     is never touched.
#   * Structural assertions (keys present, is_processed is a JSON boolean,
#     note is JSON null, id matches the schema's pattern) use the REAL
#     system jq (via $ORIG_PATH), never the isolated toolbox — jq itself is
#     the assertion tool, not something under test in those checks.
#   * Everything runs under `env -i` with an isolated HOME + TMPDIR and is
#     cleaned up on exit.
#
# Usage:  sh run-tests.sh              # run all tests
#         VERBOSE=1 sh run-tests.sh
#         (also runs green under dash: dash run-tests.sh)
#
# Exit 0 = all passed, 1 = one or more failed.
#
set -eu

# ---------------------------------------------------------------------------
# Locations
# ---------------------------------------------------------------------------
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
SCRIPTS_DIR=$(cd "$TESTS_DIR/../scripts" && pwd)
CAPTURE="$SCRIPTS_DIR/capture.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/procedure-inbox-capture-tests.XXXXXX")
TOOLBOX="$WORK/toolbox"   # real tools (jq is NEVER here)
JQDIR="$WORK/jqbin"       # jq only (a test opts in via `run`'s first arg)
mkdir -p "$TOOLBOX" "$JQDIR" "$WORK/home"

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Isolated PATH toolbox: symlink only the real tools capture.sh needs. jq is
# NEVER here (it lives only in $JQDIR, opted into per-run).
# ---------------------------------------------------------------------------
ORIG_PATH=$PATH
link_tool() {
	tp=$(PATH="$ORIG_PATH" command -v "$1" 2>/dev/null || true)
	[ -n "$tp" ] || { printf 'FATAL: required tool not found: %s\n' "$1" >&2; exit 1; }
	ln -s "$tp" "$TOOLBOX/$1"
}
for t in sh mkdir rm mv chmod dirname basename date od tr cksum awk sleep cat; do
	link_tool "$t"
done
jq_real=$(PATH="$ORIG_PATH" command -v jq 2>/dev/null || true)
[ -n "$jq_real" ] || { printf 'FATAL: jq not found on the real PATH\n' >&2; exit 1; }
ln -s "$jq_real" "$JQDIR/jq"

# ---------------------------------------------------------------------------
# Runner primitives
# ---------------------------------------------------------------------------
TESTS_RUN=0
TESTS_FAIL=0
CUR_OUT=""
CUR_ERR=""
CUR_RC=0

# run <with_jq:0|1> [VAR=VALUE ...] <cmd> [args...]
#   Runs <cmd> under the isolated toolbox PATH (+ jq only when with_jq=1),
#   with an isolated HOME/TMPDIR. Leading VAR=VALUE arguments (typically
#   INBOX_FILE=...) are passed straight to `env`. Captures stdout, stderr,
#   exit code.
run() {
	r_jq=$1; shift
	r_path="$TOOLBOX"
	[ "$r_jq" = "1" ] && r_path="$JQDIR:$TOOLBOX"
	set +e
	env -i \
		HOME="$WORK/home" \
		PATH="$r_path" \
		TMPDIR="$WORK" \
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

check() { TESTS_RUN=$((TESTS_RUN + 1)); if [ "$3" -eq 0 ]; then pass "$1"; else fail "$1" "$2"; fi; }

expect_rc() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if [ "$CUR_RC" -eq "$2" ]; then pass "$1"
	else fail "$1" "expected exit $2, got $CUR_RC; stderr: $CUR_ERR"; fi
}

stdout_has() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if printf '%s\n' "$CUR_OUT" | grep -Fq -- "$2"; then pass "$1"
	else fail "$1" "stdout missing: $2"; fi
}

stderr_has() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if printf '%s\n' "$CUR_ERR" | grep -Fq -- "$2"; then pass "$1"
	else fail "$1" "stderr missing: $2"; fi
}

section() { printf '\n== %s ==\n' "$1"; }

# jqr FILTER — run the REAL system jq (never the isolated toolbox) on
# stdin. Assertions are the harness's own logic, not the thing under test.
jqr() { env PATH="$ORIG_PATH" jq "$@"; }

# rwx_to_octal_digit RWX — converts one "rwx"-style permission triplet to
# its octal digit, via `case` (not `&&`/`||` chaining, which would let a
# non-matching final case become the whole statement's exit status under
# `set -e`).
rwx_to_octal_digit() {
	grp=$1
	val=0
	case "$grp" in r??) val=$((val + 4)) ;; esac
	case "$grp" in ?w?) val=$((val + 2)) ;; esac
	case "$grp" in ??x|??s|??t) val=$((val + 1)) ;; esac
	printf '%s' "$val"
}

# perm_octal PATH — best-effort octal permission bits via `ls -ld`, portable
# across BSD (macOS) and GNU `ls` without branching on `stat` flag
# differences (GNU: -c '%a'; BSD: -f '%Lp').
perm_octal() {
	# shellcheck disable=SC2012  # `ls -ld` is deliberate here, not `find` —
	# see the function comment: it avoids branching on GNU vs BSD `stat`
	# flag syntax, which is the actual portability hazard being dodged.
	modestr=$(ls -ld "$1" | awk '{print $1}')
	owner=$(printf '%s' "$modestr" | cut -c2-4)
	group=$(printf '%s' "$modestr" | cut -c5-7)
	other=$(printf '%s' "$modestr" | cut -c8-10)
	printf '%s%s%s' "$(rwx_to_octal_digit "$owner")" "$(rwx_to_octal_digit "$group")" "$(rwx_to_octal_digit "$other")"
}

# ===========================================================================
# capture.sh — usage / argument errors
# ===========================================================================
section "capture.sh — usage / argument errors"
run 1 sh "$CAPTURE" -h
expect_rc "capture(usage): -h -> exit 0" 0
stdout_has "capture(usage): help text" "Usage:"

run 1 sh "$CAPTURE"
expect_rc "capture(missing --text-file): -> exit 2" 2
stderr_has "capture(missing --text-file): diagnostic" "--text-file is required"

run 1 sh "$CAPTURE" --text-file "$WORK/does-not-exist"
expect_rc "capture(nonexistent text-file): -> exit 2" 2
stderr_has "capture(nonexistent text-file): diagnostic" "does not exist or is not readable"

EMPTYFILE="$WORK/empty.md"
: >"$EMPTYFILE"
run 1 sh "$CAPTURE" --text-file "$EMPTYFILE"
expect_rc "capture(empty text-file): -> exit 2" 2
stderr_has "capture(empty text-file): diagnostic" "is empty"

run 1 sh "$CAPTURE" --bogus
expect_rc "capture(unknown option): -> exit 2" 2
stderr_has "capture(unknown option): diagnostic" "unknown option"

section "capture.sh — jq absent"
SIMPLE_TEXT="$WORK/simple.md"
printf 'a captured thought\n' >"$SIMPLE_TEXT"
INBOX_A="$WORK/case-nojq/inbox.jsonl"
run 0 "INBOX_FILE=$INBOX_A" sh "$CAPTURE" --text-file "$SIMPLE_TEXT"
expect_rc "capture(no-jq): -> exit 1" 1
stderr_has "capture(no-jq): diagnostic" "jq is not installed"

# ===========================================================================
# capture.sh — appends a structurally-valid line
# ===========================================================================
section "capture.sh — appends a structurally-valid line"
INBOX_B="$WORK/case-basic/inbox.jsonl"
run 1 "INBOX_FILE=$INBOX_B" sh "$CAPTURE" --text-file "$SIMPLE_TEXT" --project demo
expect_rc "capture(basic): -> exit 0" 0
stdout_has "capture(basic): prints INBOX_ID" "INBOX_ID="

LAST_LINE=$(tail -n 1 "$INBOX_B")
check "capture(basic): schema_version is 1.0" "wrong schema_version" \
	"$( [ "$(printf '%s' "$LAST_LINE" | jqr -r '.schema_version')" = "1.0" ] && echo 0 || echo 1 )"
check "capture(basic): id matches the schema pattern" "id did not match ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}\$" \
	"$( printf '%s' "$LAST_LINE" | jqr -e '.id | test("^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$")' >/dev/null 2>&1 && echo 0 || echo 1 )"
check "capture(basic): is_processed is a JSON boolean (false)" "is_processed was not the JSON boolean false" \
	"$( printf '%s' "$LAST_LINE" | jqr -e '(.is_processed | type) == "boolean" and .is_processed == false' >/dev/null 2>&1 && echo 0 || echo 1 )"
check "capture(basic): note is JSON null" "note was not JSON null" \
	"$( printf '%s' "$LAST_LINE" | jqr -e '.note == null' >/dev/null 2>&1 && echo 0 || echo 1 )"
check "capture(basic): project field set to the --project override" "project mismatch" \
	"$( [ "$(printf '%s' "$LAST_LINE" | jqr -r '.project')" = "demo" ] && echo 0 || echo 1 )"

# ===========================================================================
# capture.sh — optional JSON-Schema validation (never a hard dependency)
# ===========================================================================
# jq does NOT validate JSON Schema, so every assertion above is structural.
# IF (and only if) a real validator is present on the host, additionally
# confirm the captured line validates against the externalized contract.
# Absent either tool, this section is silently skipped — it is never a
# build-breaking requirement.
# ---------------------------------------------------------------------------
section "capture.sh — optional JSON-Schema validation (guarded, not required)"
SCHEMA_FILE=$(cd "$TESTS_DIR/../../../../../../contracts" 2>/dev/null && pwd)/inbox-entry.schema.json
if [ ! -f "$SCHEMA_FILE" ]; then
	printf '  skip schema validation: contracts/inbox-entry.schema.json not found at %s\n' "$SCHEMA_FILE"
elif env PATH="$ORIG_PATH" command -v check-jsonschema >/dev/null 2>&1; then
	printf '%s' "$LAST_LINE" >"$WORK/schema-instance.json"
	TESTS_RUN=$((TESTS_RUN + 1))
	if env PATH="$ORIG_PATH" check-jsonschema --schemafile "$SCHEMA_FILE" "$WORK/schema-instance.json" >"$WORK/schema-out" 2>&1; then
		pass "capture(basic): validates against inbox-entry.schema.json (check-jsonschema)"
	else
		fail "capture(basic): validates against inbox-entry.schema.json (check-jsonschema)" "$(cat "$WORK/schema-out")"
	fi
elif env PATH="$ORIG_PATH" command -v ajv >/dev/null 2>&1; then
	printf '%s' "$LAST_LINE" >"$WORK/schema-instance.json"
	TESTS_RUN=$((TESTS_RUN + 1))
	if env PATH="$ORIG_PATH" ajv validate -s "$SCHEMA_FILE" -d "$WORK/schema-instance.json" >"$WORK/schema-out" 2>&1; then
		pass "capture(basic): validates against inbox-entry.schema.json (ajv)"
	else
		fail "capture(basic): validates against inbox-entry.schema.json (ajv)" "$(cat "$WORK/schema-out")"
	fi
else
	printf '  skip schema validation: neither check-jsonschema nor ajv is on PATH (not a hard dependency)\n'
fi

# ===========================================================================
# capture.sh — verbatim preservation (the injection-safety proof)
# ===========================================================================
section "capture.sh — verbatim preservation"

verbatim_case() {
	# verbatim_case NAME FIXTURE_FILE — captures FIXTURE_FILE's content and
	# asserts the stored "text" field is BYTE-IDENTICAL to the fixture,
	# using `jq -j` (no added trailing newline) + `cmp`.
	name=$1; fixture=$2
	inbox="$WORK/case-verbatim-$name/inbox.jsonl"
	run 1 "INBOX_FILE=$inbox" sh "$CAPTURE" --text-file "$fixture"
	expect_rc "capture(verbatim:$name): -> exit 0" 0
	tail -n 1 "$inbox" | jqr -j '.text' >"$WORK/verbatim-actual-$name"
	TESTS_RUN=$((TESTS_RUN + 1))
	if cmp -s "$fixture" "$WORK/verbatim-actual-$name"; then pass "capture(verbatim:$name): text is byte-identical to the fixture"
	else fail "capture(verbatim:$name): text is byte-identical to the fixture" "$(cmp "$fixture" "$WORK/verbatim-actual-$name" 2>&1)"; fi
}

QUOTE_FIXTURE="$WORK/fixture-quote.md"
printf 'He said "hello" and left.' >"$QUOTE_FIXTURE"
verbatim_case "quote" "$QUOTE_FIXTURE"

NEWLINE_FIXTURE="$WORK/fixture-newline.md"
printf 'line one\nline two\nline three' >"$NEWLINE_FIXTURE"
verbatim_case "newline" "$NEWLINE_FIXTURE"

CMDSUB_FIXTURE="$WORK/fixture-cmdsub.md"
# shellcheck disable=SC2016  # single-quoted ON PURPOSE — this fixture's
# whole point is that $(whoami)/`id`/$HOME must NOT expand; they are the
# literal bytes under test, never evaluated by the script under test.
printf 'run $(whoami) now, also `id` and $HOME' >"$CMDSUB_FIXTURE"
verbatim_case "cmdsub" "$CMDSUB_FIXTURE"

TRAILING_NL_FIXTURE="$WORK/fixture-trailing-nl.md"
printf 'final entry with a trailing newline\n' >"$TRAILING_NL_FIXTURE"
verbatim_case "trailing-newline" "$TRAILING_NL_FIXTURE"

# ===========================================================================
# capture.sh — project derivation (default / override / degenerate guard)
# ===========================================================================
section "capture.sh — project derivation"

PROJ_CWD="$WORK/myproject"
mkdir -p "$PROJ_CWD"
INBOX_PROJ="$WORK/case-project-default/inbox.jsonl"
(
	cd "$PROJ_CWD" || exit 1
	env -i HOME="$WORK/home" PATH="$TOOLBOX:$JQDIR" TMPDIR="$WORK" "INBOX_FILE=$INBOX_PROJ" \
		sh "$CAPTURE" --text-file "$SIMPLE_TEXT" >"$WORK/out" 2>"$WORK/err"
)
CUR_RC=$?
CUR_OUT=$(cat "$WORK/out"); CUR_ERR=$(cat "$WORK/err")
expect_rc "capture(project-default): -> exit 0" 0
check "capture(project-default): project derived from basename(cwd)" "project was not 'myproject'" \
	"$( [ "$(tail -n 1 "$INBOX_PROJ" | jqr -r '.project')" = "myproject" ] && echo 0 || echo 1 )"

INBOX_PROJ_OVERRIDE="$WORK/case-project-override/inbox.jsonl"
run 1 "INBOX_FILE=$INBOX_PROJ_OVERRIDE" sh "$CAPTURE" --text-file "$SIMPLE_TEXT" --project explicit-name
expect_rc "capture(project-override): -> exit 0" 0
check "capture(project-override): --project wins over cwd-derived default" "project mismatch" \
	"$( [ "$(tail -n 1 "$INBOX_PROJ_OVERRIDE" | jqr -r '.project')" = "explicit-name" ] && echo 0 || echo 1 )"

INBOX_PROJ_ROOT="$WORK/case-project-root/inbox.jsonl"
(
	cd / || exit 1
	env -i HOME="$WORK/home" PATH="$TOOLBOX:$JQDIR" TMPDIR="$WORK" "INBOX_FILE=$INBOX_PROJ_ROOT" \
		sh "$CAPTURE" --text-file "$SIMPLE_TEXT" >"$WORK/out" 2>"$WORK/err"
)
CUR_RC=$?
expect_rc "capture(project-root-guard): -> exit 0" 0
check "capture(project-root-guard): project field OMITTED (never stored as '/')" "a project field was present when cwd was '/'" \
	"$( tail -n 1 "$INBOX_PROJ_ROOT" | jqr -e '(has("project")) | not' >/dev/null 2>&1 && echo 0 || echo 1 )"

# ===========================================================================
# capture.sh — --session-id (stored when given, OMITTED when absent)
# ===========================================================================
section "capture.sh — --session-id"

INBOX_SID="$WORK/case-session-id/inbox.jsonl"
run 1 "INBOX_FILE=$INBOX_SID" sh "$CAPTURE" --text-file "$SIMPLE_TEXT" --project demo --session-id "a794b0c6-1853-43f5-9177-dc2085a8c653"
expect_rc "capture(session-id): -> exit 0" 0
stdout_has "capture(session-id): INBOX_ID contract unchanged" "INBOX_ID="
SID_LINE=$(tail -n 1 "$INBOX_SID")
check "capture(session-id): session_id stored with the given value" "session_id mismatch" \
	"$( [ "$(printf '%s' "$SID_LINE" | jqr -r '.session_id')" = "a794b0c6-1853-43f5-9177-dc2085a8c653" ] && echo 0 || echo 1 )"
check "capture(session-id): session_id is a JSON string (never null)" "session_id was not a string" \
	"$( printf '%s' "$SID_LINE" | jqr -e '(.session_id | type) == "string"' >/dev/null 2>&1 && echo 0 || echo 1 )"

INBOX_NOSID="$WORK/case-no-session-id/inbox.jsonl"
run 1 "INBOX_FILE=$INBOX_NOSID" sh "$CAPTURE" --text-file "$SIMPLE_TEXT" --project demo
expect_rc "capture(no session-id): -> exit 0" 0
NOSID_LINE=$(tail -n 1 "$INBOX_NOSID")
check "capture(no session-id): session_id key is OMITTED entirely (not null)" "a session_id key was present when --session-id was not given" \
	"$( printf '%s' "$NOSID_LINE" | jqr -e '(has("session_id")) | not' >/dev/null 2>&1 && echo 0 || echo 1 )"
stdout_has "capture(no session-id): INBOX_ID contract unchanged" "INBOX_ID="

run 1 "INBOX_FILE=$WORK/case-sid-noval/inbox.jsonl" sh "$CAPTURE" --text-file "$SIMPLE_TEXT" --session-id
expect_rc "capture(--session-id no value): -> exit 2" 2
stderr_has "capture(--session-id no value): diagnostic" "requires an argument"

# ===========================================================================
# concurrency — a capture during a held lock is queued, never lost.
# ===========================================================================
section "concurrency — capture blocks then succeeds once a held lock is released"
INBOX_CONC="$WORK/case-conc/inbox.jsonl"
GTD_CONC=$(dirname "$INBOX_CONC")
mkdir -p "$GTD_CONC"
LOCK_CONC="$GTD_CONC/.inbox.lock"
mkdir "$LOCK_CONC"
printf '%s\n' "$$" >"$LOCK_CONC/pid"   # our own pid: alive, so this looks like a genuinely held lock

CONC_TEXT="$WORK/conc-text.md"
printf 'captured while a rewrite held the lock\n' >"$CONC_TEXT"

set +e
env -i HOME="$WORK/home" PATH="$JQDIR:$TOOLBOX" TMPDIR="$WORK" "INBOX_FILE=$INBOX_CONC" \
	sh "$CAPTURE" --text-file "$CONC_TEXT" >"$WORK/conc-out" 2>"$WORK/conc-err" &
CONC_BGPID=$!
set -e

sleep 0.3
rm -rf "$LOCK_CONC"   # simulate the "rewrite" finishing and releasing the lock

set +e
wait "$CONC_BGPID"
CONC_RC=$?
set -e
CONC_OUT=$(cat "$WORK/conc-out"); CONC_ERR=$(cat "$WORK/conc-err")

TESTS_RUN=$((TESTS_RUN + 1))
if [ "$CONC_RC" -eq 0 ]; then pass "concurrency(queued-capture): capture succeeded after the lock was released"
else fail "concurrency(queued-capture): capture succeeded after the lock was released" "rc=$CONC_RC err=$CONC_ERR"; fi

TESTS_RUN=$((TESTS_RUN + 1))
if printf '%s\n' "$CONC_OUT" | grep -Fq -- "INBOX_ID="; then pass "concurrency(queued-capture): stdout carries INBOX_ID"
else fail "concurrency(queued-capture): stdout carries INBOX_ID" "$CONC_OUT"; fi

TESTS_RUN=$((TESTS_RUN + 1))
CONC_LINES=$(wc -l <"$INBOX_CONC" 2>/dev/null | tr -d ' ' || printf '0')
if [ "$CONC_LINES" -eq 1 ]; then pass "concurrency(queued-capture): exactly one entry landed (nothing lost, nothing duplicated)"
else fail "concurrency(queued-capture): exactly one entry landed (nothing lost, nothing duplicated)" "found $CONC_LINES lines"; fi

# ===========================================================================
# concurrency — stale-lock reclaim: a lock held by a dead pid does not wait
# out the full timeout.
# ===========================================================================
section "concurrency — a lock held by a dead pid is reclaimed (stale-lock regression)"
INBOX_STALE="$WORK/case-stale/inbox.jsonl"
GTD_STALE=$(dirname "$INBOX_STALE")
mkdir -p "$GTD_STALE"
LOCK_STALE="$GTD_STALE/.inbox.lock"
mkdir "$LOCK_STALE"
printf '999999\n' >"$LOCK_STALE/pid"   # near-certainly not a live pid on this machine

STALE_TEXT="$WORK/stale-text.md"
printf 'captured after a stale-lock reclaim\n' >"$STALE_TEXT"

START_TS=$(date +%s)
run 1 "INBOX_FILE=$INBOX_STALE" sh "$CAPTURE" --text-file "$STALE_TEXT"
END_TS=$(date +%s)
expect_rc "concurrency(stale-lock): capture succeeds (reclaimed, not waited out)" 0
stderr_has "concurrency(stale-lock): warns about reclaiming" "reclaiming stale inbox lock"
ELAPSED=$((END_TS - START_TS))
check "concurrency(stale-lock): reclaimed promptly (well under the 10s timeout)" "took ${ELAPSED}s" \
	"$( [ "$ELAPSED" -lt 5 ] && echo 0 || echo 1 )"

# the reclaim is an atomic `mv` (rename) of the stale
# lock dir to a `.stale.$$` name, never a blind `rm -rf` of the live lock
# name: only the renamer can win, so a losing waiter re-loops on current
# state instead of deleting a lock a third process may hold. Confirm no
# `.stale.$$` temp is left behind after a normal (non-crashing) reclaim —
# the inline `rm -rf` right after a successful `mv` cleans it up, so it
# never lingers as more than momentary litter.
TESTS_RUN=$((TESTS_RUN + 1))
STALE_LEFTOVER=$(find "$GTD_STALE" -maxdepth 1 -name '.inbox.lock.stale.*' -print 2>/dev/null)
if [ -z "$STALE_LEFTOVER" ]; then pass "concurrency(stale-lock): no .stale.\$\$ reclaim temp left behind"
else fail "concurrency(stale-lock): no .stale.\$\$ reclaim temp left behind" "found: $STALE_LEFTOVER"; fi

# ===========================================================================
# permissions — created gtd/ is 700, inbox.jsonl is 600
# ===========================================================================
section "permissions — created gtd/ is 700, inbox.jsonl is 600"
INBOX_PERM="$WORK/case-perms/gtd/inbox.jsonl"
run 1 "INBOX_FILE=$INBOX_PERM" sh "$CAPTURE" --text-file "$SIMPLE_TEXT"
expect_rc "perms-setup: capture -> exit 0" 0
check "perms: gtd/ directory is 700" "expected 700" \
	"$( [ "$(perm_octal "$(dirname "$INBOX_PERM")")" = "700" ] && echo 0 || echo 1 )"
check "perms: inbox.jsonl is 600" "expected 600" \
	"$( [ "$(perm_octal "$INBOX_PERM")" = "600" ] && echo 0 || echo 1 )"

# ===========================================================================
# Summary
# ===========================================================================
printf '\n== summary ==\n'
printf 'ran %s checks, %s failed\n' "$TESTS_RUN" "$TESTS_FAIL"
[ "$TESTS_FAIL" -eq 0 ] || exit 1
printf 'ALL TESTS PASSED\n'
exit 0
