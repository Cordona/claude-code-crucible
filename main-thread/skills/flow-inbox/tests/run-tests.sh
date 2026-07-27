#!/usr/bin/env sh
#
# run-tests.sh — self-contained, zero-dependency POSIX test harness for the
#                flow-inbox script suite (list.sh, process.sh,
#                purge-processed.sh).
#
# capture.sh is NOT under test here — it moved to the gtd-inbox-writer
# agent's own procedure-inbox-capture skill
# (operations/agents/gtd-inbox-writer/skills/procedure-inbox-capture/tests),
# which is colocated with the script the agent owns. Every fixture entry
# this suite needs is written DIRECTLY as a JSONL line (see append_entry
# below) — the same technique this suite already used for its
# malformed/concat-line cases — so this suite never shells out to
# capture.sh and needs none of its scripts.
#
# WHY a hand-rolled harness (not bats), modeled on procedure-gh-issues's:
# the scripts under test claim to run with no dependency beyond `jq` +
# coreutils, so the test harness must make the same claim.
#
# What it does:
#   * Builds an isolated PATH "toolbox" of symlinks to only the real tools
#     the scripts need, MINUS `jq` — jq lives in its OWN dir that a test
#     opts into via the `run` helper's first argument, so "jq absent" is
#     exercised for real (by leaving that dir off PATH), the same technique
#     procedure-gh-issues/tests/run-tests.sh uses for the `gh` stub. (Modern
#     macOS bundles jq at /usr/bin/jq, so simply narrowing $PATH to
#     /usr/bin:/bin would NOT exclude it — an isolated toolbox is required.)
#   * Every run of a script under test uses INBOX_FILE pointed at a fresh
#     path under an isolated WORK dir — the real
#     $HOME/.claude/crucible/gtd/inbox.jsonl is never touched.
#   * Structural assertions (keys present, is_processed is a JSON boolean)
#     use the REAL system jq (via $ORIG_PATH), never the isolated toolbox —
#     jq itself is the assertion tool, not something under test in those
#     checks.
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
LIST="$SCRIPTS_DIR/list.sh"
PROCESS="$SCRIPTS_DIR/process.sh"
PURGE="$SCRIPTS_DIR/purge-processed.sh"
RENDER="$SCRIPTS_DIR/render-md.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/flow-inbox-tests.XXXXXX")
TOOLBOX="$WORK/toolbox"   # real tools (jq is NEVER here)
JQDIR="$WORK/jqbin"       # jq only (a test opts in via `run`'s first arg)
mkdir -p "$TOOLBOX" "$JQDIR" "$WORK/home"

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Isolated PATH toolbox: symlink only the real tools the scripts need. jq is
# NEVER here (it lives only in $JQDIR, opted into per-run).
# ---------------------------------------------------------------------------
ORIG_PATH=$PATH
link_tool() {
	tp=$(PATH="$ORIG_PATH" command -v "$1" 2>/dev/null || true)
	[ -n "$tp" ] || { printf 'FATAL: required tool not found: %s\n' "$1" >&2; exit 1; }
	ln -s "$tp" "$TOOLBOX/$1"
}
for t in sh mktemp mkdir rm mv chmod dirname date cat sleep; do
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

# ---------------------------------------------------------------------------
# Fixture helpers — write inbox entries DIRECTLY (no capture.sh involved).
# ---------------------------------------------------------------------------

# next_fixture_id — a unique, schema-shaped-looking id for fixture data.
# This suite never asserts against the id PATTERN (that is capture.sh's own
# concern, covered in procedure-inbox-capture's suite) — it only needs
# stable, collision-free ids to look entries up by.
#
# WHY this sets a global ($FIXTURE_ID) instead of printing for a caller to
# capture via `$(next_fixture_id)`: a command substitution runs the function
# in a SUBSHELL, so its increment of $FIXTURE_ID_SEQ would never reach the
# parent shell — every call would restart the counter at 1 and hand out the
# same id (the subshell-scope-loss trap). Calling `next_fixture_id` directly
# (no `$()`) runs it in-process, so the increment sticks.
FIXTURE_ID_SEQ=0
FIXTURE_ID=""
next_fixture_id() {
	FIXTURE_ID_SEQ=$((FIXTURE_ID_SEQ + 1))
	FIXTURE_ID=$(printf '20260101T000000Z-fixture%04d' "$FIXTURE_ID_SEQ")
}

# append_entry FILE ID TEXT [PROJECT] [IS_PROCESSED]
#   Appends one schema-shaped JSONL line straight to FILE, bypassing
#   capture.sh entirely — mirrors the shape capture.sh itself would write
#   (schema_version/id/ts/text/[project]/is_processed/note). Uses `jq`
#   directly (not the `jqr` wrapper): append_entry always runs at the
#   harness's own top level, never inside `run()`'s PATH-restricted env, so
#   the caller's real PATH — and therefore the real system jq — is already
#   in effect here; line construction is never the thing under test.
append_entry() {
	entry_file=$1; entry_id=$2; entry_text=$3; entry_project=${4:-}; entry_processed=${5:-false}
	mkdir -p "$(dirname "$entry_file")"
	if [ -n "$entry_project" ]; then
		entry_line=$(jq -c -n \
			--arg id "$entry_id" --arg ts "2026-01-01T00:00:00Z" --arg text "$entry_text" \
			--arg project "$entry_project" --argjson is_processed "$entry_processed" \
			'{schema_version:"1.0", id:$id, ts:$ts, text:$text, project:$project, is_processed:$is_processed, note:null}')
	else
		entry_line=$(jq -c -n \
			--arg id "$entry_id" --arg ts "2026-01-01T00:00:00Z" --arg text "$entry_text" \
			--argjson is_processed "$entry_processed" \
			'{schema_version:"1.0", id:$id, ts:$ts, text:$text, is_processed:$is_processed, note:null}')
	fi
	printf '%s\n' "$entry_line" >>"$entry_file"
}

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

# ---------------------------------------------------------------------------
# render-md.sh test helpers. render-md.sh reads JSON on stdin, so `run` (which
# never redirects stdin) can't drive it — this pair feeds a fixture file on
# stdin, always WITH jq (render-md needs it), under the same isolated env. The
# raw stdout is kept in a file so golden assertions can compare EXACT bytes
# (trailing newline included) via cmp — a command-substitution capture would
# strip the trailing newline and defeat the byte-exact check.
# ---------------------------------------------------------------------------
render_run() {
	# render_run <mode> <status_label|-> <stdin_file>
	rr_mode=$1; rr_label=$2; rr_input=$3
	set +e
	if [ "$rr_label" = "-" ]; then
		env -i HOME="$WORK/home" PATH="$JQDIR:$TOOLBOX" TMPDIR="$WORK" \
			sh "$RENDER" --mode "$rr_mode" <"$rr_input" >"$WORK/render-out" 2>"$WORK/render-err"
	else
		env -i HOME="$WORK/home" PATH="$JQDIR:$TOOLBOX" TMPDIR="$WORK" \
			sh "$RENDER" --mode "$rr_mode" --status-label "$rr_label" <"$rr_input" >"$WORK/render-out" 2>"$WORK/render-err"
	fi
	CUR_RC=$?
	set -e
	CUR_OUT=$(cat "$WORK/render-out"); CUR_ERR=$(cat "$WORK/render-err")
	if [ "${VERBOSE:-0}" = "1" ]; then
		printf '    rc=%s\n' "$CUR_RC"
		printf '%s\n' "$CUR_OUT" | sed 's/^/    out| /'
		printf '%s\n' "$CUR_ERR" | sed 's/^/    err| /'
	fi
}

# assert_golden NAME EXPECTED_FILE — the last render_run's stdout must be
# BYTE-IDENTICAL to EXPECTED_FILE (trailing newline included).
assert_golden() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if cmp -s "$2" "$WORK/render-out"; then pass "$1"
	else fail "$1" "byte mismatch vs golden; got:$(printf '\n')$(cat "$WORK/render-out")"; fi
}

# ===========================================================================
# list.sh — usage / absent file / bad args
# ===========================================================================
section "list.sh — usage / absent file / bad args"
run 1 sh "$LIST" -h
expect_rc "list(usage): -h -> exit 0" 0
stdout_has "list(usage): help text" "Usage:"

run 1 "INBOX_FILE=$WORK/does-not-exist/inbox.jsonl" sh "$LIST" --all
expect_rc "list(absent-file): -> exit 0" 0
stdout_has "list(absent-file): prints []" "[]"

run 1 sh "$LIST" --active --processed
expect_rc "list(conflicting status flags): -> exit 2" 2
stderr_has "list(conflicting status flags): diagnostic" "mutually exclusive"

INBOX_NOJQ_LIST="$WORK/case-nojq-list/inbox.jsonl"
run 0 "INBOX_FILE=$INBOX_NOJQ_LIST" sh "$LIST" --all
expect_rc "list(no-jq): -> exit 1" 1
stderr_has "list(no-jq): diagnostic" "jq is not installed"

run 1 sh "$LIST" --id
expect_rc "list(--id no value): -> exit 2" 2
stderr_has "list(--id no value): diagnostic" "requires an argument"

run 1 sh "$LIST" --id "20260101T000000Z-deadbeef" --project demo
expect_rc "list(--id combined with --project): -> exit 2" 2
stderr_has "list(--id combined with --project): diagnostic" "mutually exclusive"

run 1 sh "$LIST" --id "20260101T000000Z-deadbeef" --active
expect_rc "list(--id combined with --active): -> exit 2" 2
stderr_has "list(--id combined with --active): diagnostic" "mutually exclusive"

run 1 sh "$LIST" --id "20260101T000000Z-deadbeef" --processed
expect_rc "list(--id combined with --processed): -> exit 2" 2
stderr_has "list(--id combined with --processed): diagnostic" "mutually exclusive"

run 1 sh "$LIST" --id "20260101T000000Z-deadbeef" --all
expect_rc "list(--id combined with --all): -> exit 2" 2
stderr_has "list(--id combined with --all): diagnostic" "mutually exclusive"

run 1 "INBOX_FILE=$WORK/does-not-exist/inbox.jsonl" sh "$LIST" --id "20260101T000000Z-deadbeef"
expect_rc "list(--id, absent file): -> exit 0" 0
stdout_has "list(--id, absent file): prints []" "[]"

INBOX_EMPTY_LIST="$WORK/case-empty-list/inbox.jsonl"
mkdir -p "$(dirname "$INBOX_EMPTY_LIST")"
: >"$INBOX_EMPTY_LIST"
run 1 "INBOX_FILE=$INBOX_EMPTY_LIST" sh "$LIST" --id "20260101T000000Z-deadbeef"
expect_rc "list(--id, present-but-empty file): -> exit 0" 0
stdout_has "list(--id, present-but-empty file): prints []" "[]"

# ===========================================================================
# list.sh — filters by project + status
# ===========================================================================
section "list.sh — filters by project + status"
INBOX_LIST="$WORK/case-list/inbox.jsonl"

next_fixture_id; ID_A1=$FIXTURE_ID
append_entry "$INBOX_LIST" "$ID_A1" "item one, project A" A false
next_fixture_id; ID_A2=$FIXTURE_ID
append_entry "$INBOX_LIST" "$ID_A2" "item two, project A" A false
next_fixture_id; ID_B1=$FIXTURE_ID
append_entry "$INBOX_LIST" "$ID_B1" "item three, project B" B false

run 1 "INBOX_FILE=$INBOX_LIST" sh "$PROCESS" --id "$ID_A2"
expect_rc "list-setup: process A2 -> exit 0" 0

run 1 "INBOX_FILE=$INBOX_LIST" sh "$LIST" --project A --active
expect_rc "list(project-A-active): -> exit 0" 0
check "list(project-A-active): exactly 1 entry" "expected length 1" \
	"$( [ "$(printf '%s' "$CUR_OUT" | jqr 'length')" -eq 1 ] && echo 0 || echo 1 )"

run 1 "INBOX_FILE=$INBOX_LIST" sh "$LIST" --project A --processed
expect_rc "list(project-A-processed): -> exit 0" 0
check "list(project-A-processed): exactly 1 entry" "expected length 1" \
	"$( [ "$(printf '%s' "$CUR_OUT" | jqr 'length')" -eq 1 ] && echo 0 || echo 1 )"

run 1 "INBOX_FILE=$INBOX_LIST" sh "$LIST" --project A --all
expect_rc "list(project-A-all): -> exit 0" 0
check "list(project-A-all): exactly 2 entries" "expected length 2" \
	"$( [ "$(printf '%s' "$CUR_OUT" | jqr 'length')" -eq 2 ] && echo 0 || echo 1 )"

run 1 "INBOX_FILE=$INBOX_LIST" sh "$LIST" --all
expect_rc "list(all-projects-all-status): -> exit 0" 0
check "list(all-projects-all-status): exactly 3 entries" "expected length 3" \
	"$( [ "$(printf '%s' "$CUR_OUT" | jqr 'length')" -eq 3 ] && echo 0 || echo 1 )"

run 1 "INBOX_FILE=$INBOX_LIST" sh "$LIST" --project B --active
expect_rc "list(project-B-active): -> exit 0" 0
check "list(project-B-active): exactly 1 entry" "expected length 1" \
	"$( [ "$(printf '%s' "$CUR_OUT" | jqr 'length')" -eq 1 ] && echo 0 || echo 1 )"

# ===========================================================================
# list.sh — --id lookup
# ===========================================================================
section "list.sh — --id lookup"

# ID_A1 is active (never processed); ID_A2 was flipped to processed above —
# --id must find both regardless of is_processed state.
run 1 "INBOX_FILE=$INBOX_LIST" sh "$LIST" --id "$ID_A1"
expect_rc "list(--id, active entry): -> exit 0" 0
check "list(--id, active entry): exactly 1 entry" "expected length 1" \
	"$( [ "$(printf '%s' "$CUR_OUT" | jqr 'length')" -eq 1 ] && echo 0 || echo 1 )"
check "list(--id, active entry): returned id matches" "id mismatch" \
	"$( [ "$(printf '%s' "$CUR_OUT" | jqr -r '.[0].id')" = "$ID_A1" ] && echo 0 || echo 1 )"

run 1 "INBOX_FILE=$INBOX_LIST" sh "$LIST" --id "$ID_A2"
expect_rc "list(--id, processed entry): -> exit 0" 0
check "list(--id, processed entry): exactly 1 entry" "expected length 1" \
	"$( [ "$(printf '%s' "$CUR_OUT" | jqr 'length')" -eq 1 ] && echo 0 || echo 1 )"
check "list(--id, processed entry): returned id matches" "id mismatch" \
	"$( [ "$(printf '%s' "$CUR_OUT" | jqr -r '.[0].id')" = "$ID_A2" ] && echo 0 || echo 1 )"
check "list(--id, processed entry): is_processed is true" "expected is_processed == true" \
	"$( printf '%s' "$CUR_OUT" | jqr -e '.[0].is_processed == true' >/dev/null 2>&1 && echo 0 || echo 1 )"

run 1 "INBOX_FILE=$INBOX_LIST" sh "$LIST" --id "20260101T000000Z-deadbeef"
expect_rc "list(--id, non-existent): -> exit 0" 0
stdout_has "list(--id, non-existent): prints []" "[]"

# ===========================================================================
# list.sh — malformed pre-existing line is skipped on read
# ===========================================================================
section "list.sh — malformed line skipped on read"
INBOX_MALFORMED="$WORK/case-malformed-list/inbox.jsonl"
next_fixture_id; ID_MALFORMED_LIST=$FIXTURE_ID
append_entry "$INBOX_MALFORMED" "$ID_MALFORMED_LIST" "a captured thought"
printf 'this is not json at all\n' >>"$INBOX_MALFORMED"

run 1 "INBOX_FILE=$INBOX_MALFORMED" sh "$LIST" --all
expect_rc "list(malformed-line): -> exit 0" 0
check "list(malformed-line): only the valid entry is returned" "expected length 1" \
	"$( [ "$(printf '%s' "$CUR_OUT" | jqr 'length')" -eq 1 ] && echo 0 || echo 1 )"
stderr_has "list(malformed-line): warns about the malformed line" "malformed"

# A malformed line elsewhere in the log must not break an --id lookup: the
# resilient read skips it and the lookup still finds the genuine entry.
run 1 "INBOX_FILE=$INBOX_MALFORMED" sh "$LIST" --id "$ID_MALFORMED_LIST"
expect_rc "list(--id, malformed line present): -> exit 0" 0
check "list(--id, malformed line present): the valid entry is still found" "expected length 1" \
	"$( [ "$(printf '%s' "$CUR_OUT" | jqr 'length')" -eq 1 ] && echo 0 || echo 1 )"
stderr_has "list(--id, malformed line present): warns about the malformed line" "malformed"

# ===========================================================================
# object+scalar concatenation — a line like `{"id":"x"}5`
# must be classified malformed, never treated as a valid object. Before the
# fix, jq's parse-count check accepted this shape (jq emits the object once,
# `empty` for the trailing scalar), so downstream `.field` access on the
# concatenated value could error and, under `set -e`, abort the WHOLE
# script. Cover all three concatenation shapes (scalar/array/string tail)
# across list.sh (skip-on-read), process.sh and purge-processed.sh
# (preserve-on-rewrite) — none may abort.
# ===========================================================================
section "object+scalar/array/string concatenation is malformed, never aborts"

INBOX_CONCAT_LIST="$WORK/case-concat-list/inbox.jsonl"
next_fixture_id
append_entry "$INBOX_CONCAT_LIST" "$FIXTURE_ID" "a captured thought"
{
	printf '%s\n' '{"id":"x"}5'
	printf '%s\n' '{"id":"x"}[1,2]'
	printf '%s\n' '{"id":"x"}"s"'
} >>"$INBOX_CONCAT_LIST"

run 1 "INBOX_FILE=$INBOX_CONCAT_LIST" sh "$LIST" --all
expect_rc "concat(list): object+scalar concatenation does NOT abort the script" 0
check "concat(list): only the one genuinely valid entry is returned" "expected length 1" \
	"$( [ "$(printf '%s' "$CUR_OUT" | jqr 'length')" -eq 1 ] && echo 0 || echo 1 )"
stderr_has "concat(list): warns about the malformed concatenation lines" "malformed"

INBOX_CONCAT_PROC="$WORK/case-concat-process/inbox.jsonl"
next_fixture_id; CONCAT_PROC_ID=$FIXTURE_ID
append_entry "$INBOX_CONCAT_PROC" "$CONCAT_PROC_ID" "a captured thought"
CONCAT_LINE='{"id":"x"}5'
printf '%s\n' "$CONCAT_LINE" >>"$INBOX_CONCAT_PROC"

run 1 "INBOX_FILE=$INBOX_CONCAT_PROC" sh "$PROCESS" --id "$CONCAT_PROC_ID"
expect_rc "concat(process): object+scalar concatenation does NOT abort the rewrite" 0
TESTS_RUN=$((TESTS_RUN + 1))
if grep -Fxq -- "$CONCAT_LINE" "$INBOX_CONCAT_PROC"; then pass "concat(process): concatenation line preserved verbatim, not misread as an object"
else fail "concat(process): concatenation line preserved verbatim, not misread as an object" "not found in rewritten file"; fi

INBOX_CONCAT_PURGE="$WORK/case-concat-purge/inbox.jsonl"
next_fixture_id; CONCAT_PURGE_ID=$FIXTURE_ID
append_entry "$INBOX_CONCAT_PURGE" "$CONCAT_PURGE_ID" "to be purged for the concat case" concat false
run 1 "INBOX_FILE=$INBOX_CONCAT_PURGE" sh "$PROCESS" --id "$CONCAT_PURGE_ID"
printf '%s\n' "$CONCAT_LINE" >>"$INBOX_CONCAT_PURGE"

run 1 "INBOX_FILE=$INBOX_CONCAT_PURGE" sh "$PURGE" --project concat --apply
expect_rc "concat(purge): object+scalar concatenation does NOT abort the rewrite" 0
stdout_has "concat(purge): purged 1" "INBOX_PURGED=1"
TESTS_RUN=$((TESTS_RUN + 1))
if grep -Fxq -- "$CONCAT_LINE" "$INBOX_CONCAT_PURGE"; then pass "concat(purge): concatenation line preserved verbatim after purge"
else fail "concat(purge): concatenation line preserved verbatim after purge" "not found after purge"; fi

# ===========================================================================
# process.sh — flips, --unprocess reverses, note-file, bad --id
# ===========================================================================
section "process.sh — flips / --unprocess / note-file / bad --id"
run 1 sh "$PROCESS" -h
expect_rc "process(usage): -h -> exit 0" 0
stdout_has "process(usage): help text" "Usage:"

run 1 sh "$PROCESS"
expect_rc "process(missing --id): -> exit 2" 2
stderr_has "process(missing --id): diagnostic" "--id is required"

run 1 sh "$PROCESS" --id x --note-file "$WORK/does-not-exist"
expect_rc "process(nonexistent note-file): -> exit 2" 2

INBOX_PROC="$WORK/case-process/inbox.jsonl"
next_fixture_id; ID_PROC=$FIXTURE_ID
append_entry "$INBOX_PROC" "$ID_PROC" "a captured thought"

run 1 "INBOX_FILE=$INBOX_PROC" sh "$PROCESS" --id "$ID_PROC"
expect_rc "process(flip): -> exit 0" 0
stdout_has "process(flip): prints INBOX_PROCESSED" "INBOX_PROCESSED=$ID_PROC"
check "process(flip): is_processed is now true" "expected is_processed == true" \
	"$( tail -n 1 "$INBOX_PROC" | jqr -e '.is_processed == true' >/dev/null 2>&1 && echo 0 || echo 1 )"

NOTE_FILE="$WORK/note.md"
printf 'turned into ticket #26' >"$NOTE_FILE"
run 1 "INBOX_FILE=$INBOX_PROC" sh "$PROCESS" --id "$ID_PROC" --unprocess --note-file "$NOTE_FILE"
expect_rc "process(unprocess+note): -> exit 0" 0
check "process(unprocess): is_processed reversed to false" "expected is_processed == false" \
	"$( tail -n 1 "$INBOX_PROC" | jqr -e '.is_processed == false' >/dev/null 2>&1 && echo 0 || echo 1 )"
check "process(note): note stored verbatim" "note content mismatch" \
	"$( [ "$(tail -n 1 "$INBOX_PROC" | jqr -j '.note')" = "turned into ticket #26" ] && echo 0 || echo 1 )"

BEFORE_SNAPSHOT="$WORK/before-bad-id.jsonl"
cp "$INBOX_PROC" "$BEFORE_SNAPSHOT"
run 1 "INBOX_FILE=$INBOX_PROC" sh "$PROCESS" --id "20260101T000000Z-deadbeef"
expect_rc "process(bad-id): -> exit 1" 1
stderr_has "process(bad-id): diagnostic names the expectation" "expected exactly one"
TESTS_RUN=$((TESTS_RUN + 1))
if cmp -s "$BEFORE_SNAPSHOT" "$INBOX_PROC"; then pass "process(bad-id): inbox file is byte-identical (no rewrite happened)"
else fail "process(bad-id): inbox file is byte-identical (no rewrite happened)" "$(cmp "$BEFORE_SNAPSHOT" "$INBOX_PROC" 2>&1)"; fi

run 0 "INBOX_FILE=$INBOX_PROC" sh "$PROCESS" --id "$ID_PROC"
expect_rc "process(no-jq): -> exit 1" 1
stderr_has "process(no-jq): diagnostic" "jq is not installed"

# ===========================================================================
# process.sh — malformed pre-existing line preserved verbatim on rewrite
# ===========================================================================
section "process.sh — malformed line preserved on rewrite"
INBOX_MALFORMED_PROC="$WORK/case-malformed-process/inbox.jsonl"
next_fixture_id; TARGET_ID=$FIXTURE_ID
append_entry "$INBOX_MALFORMED_PROC" "$TARGET_ID" "a captured thought"
MALFORMED_LINE='{"broken": totally not json'
printf '%s\n' "$MALFORMED_LINE" >>"$INBOX_MALFORMED_PROC"

run 1 "INBOX_FILE=$INBOX_MALFORMED_PROC" sh "$PROCESS" --id "$TARGET_ID"
expect_rc "process(preserve-malformed): -> exit 0" 0
TESTS_RUN=$((TESTS_RUN + 1))
if grep -Fxq -- "$MALFORMED_LINE" "$INBOX_MALFORMED_PROC"; then pass "process(preserve-malformed): malformed line survives byte-for-byte"
else fail "process(preserve-malformed): malformed line survives byte-for-byte" "not found in rewritten file"; fi

# ===========================================================================
# purge-processed.sh — usage errors
# ===========================================================================
section "purge-processed.sh — usage errors"
run 1 sh "$PURGE" -h
expect_rc "purge(usage): -h -> exit 0" 0
stdout_has "purge(usage): help text" "Usage:"

run 1 sh "$PURGE"
expect_rc "purge(bare call): -> exit 2" 2
stderr_has "purge(bare call): diagnostic" "is required"

run 1 sh "$PURGE" --project X --all
expect_rc "purge(both --project and --all): -> exit 2" 2
stderr_has "purge(both): diagnostic" "mutually exclusive"

run 1 "INBOX_FILE=$WORK/does-not-exist/inbox.jsonl" sh "$PURGE" --all
expect_rc "purge(absent-file, dry-run): -> exit 0" 0
stdout_has "purge(absent-file, dry-run): matched 0" "INBOX_PURGE_MATCHED=0"

run 1 "INBOX_FILE=$WORK/does-not-exist/inbox.jsonl" sh "$PURGE" --all --apply
expect_rc "purge(absent-file, --apply): -> exit 0" 0
stdout_has "purge(absent-file, --apply): purged 0" "INBOX_PURGED=0"

run 0 "INBOX_FILE=$INBOX_PROC" sh "$PURGE" --all
expect_rc "purge(no-jq): -> exit 1" 1
stderr_has "purge(no-jq): diagnostic" "jq is not installed"

# ===========================================================================
# purge-processed.sh — dry run mutates nothing
# ===========================================================================
section "purge-processed.sh — dry run mutates nothing"
INBOX_PURGE="$WORK/case-purge/inbox.jsonl"
GTD_PURGE_DIR=$(dirname "$INBOX_PURGE")

next_fixture_id
append_entry "$INBOX_PURGE" "$FIXTURE_ID" "keep me unprocessed" P false
next_fixture_id; ID_TO_PURGE=$FIXTURE_ID
append_entry "$INBOX_PURGE" "$ID_TO_PURGE" "purge me once processed" P false
run 1 "INBOX_FILE=$INBOX_PURGE" sh "$PROCESS" --id "$ID_TO_PURGE"

LINES_BEFORE=$(wc -l <"$INBOX_PURGE" | tr -d ' ')

run 1 "INBOX_FILE=$INBOX_PURGE" sh "$PURGE" --project P
expect_rc "purge(dry-run): -> exit 0" 0
stdout_has "purge(dry-run): matched 1" "INBOX_PURGE_MATCHED=1"

LINES_AFTER=$(wc -l <"$INBOX_PURGE" | tr -d ' ')
check "purge(dry-run): line count unchanged" "expected $LINES_BEFORE lines, still" \
	"$( [ "$LINES_BEFORE" -eq "$LINES_AFTER" ] && echo 0 || echo 1 )"
TESTS_RUN=$((TESTS_RUN + 1))
if [ -z "$(find "$GTD_PURGE_DIR" -maxdepth 1 -name '*.purged' -print 2>/dev/null)" ]; then
	pass "purge(dry-run): no .purged backup file was created"
else
	fail "purge(dry-run): no .purged backup file was created" "a .purged file exists after a dry run"
fi

# ===========================================================================
# purge-processed.sh — --apply deletes and backs up first
# ===========================================================================
section "purge-processed.sh — --apply deletes and backs up first"
run 1 "INBOX_FILE=$INBOX_PURGE" sh "$PURGE" --project P --apply
expect_rc "purge(apply): -> exit 0" 0
stdout_has "purge(apply): matched 1" "INBOX_PURGE_MATCHED=1"
stdout_has "purge(apply): purged 1" "INBOX_PURGED=1"

BACKUP_FOUND=$(find "$GTD_PURGE_DIR" -maxdepth 1 -name '*.purged' -print 2>/dev/null | head -n 1)
TESTS_RUN=$((TESTS_RUN + 1))
if [ -n "$BACKUP_FOUND" ]; then pass "purge(apply): a .purged backup file was created"
else fail "purge(apply): a .purged backup file was created" "no *.purged file found in $GTD_PURGE_DIR"; fi

if [ -n "$BACKUP_FOUND" ]; then
	check "purge(apply): backup contains the removed entry's id" "id not found in backup" \
		"$( grep -Fq -- "$ID_TO_PURGE" "$BACKUP_FOUND" && echo 0 || echo 1 )"
	check "purge(apply): backup file is 600" "expected 600" \
		"$( [ "$(perm_octal "$BACKUP_FOUND")" = "600" ] && echo 0 || echo 1 )"
fi

REMAINING=$(wc -l <"$INBOX_PURGE" | tr -d ' ')
check "purge(apply): exactly 1 line remains (the unprocessed entry)" "expected 1 line, got $REMAINING" \
	"$( [ "$REMAINING" -eq 1 ] && echo 0 || echo 1 )"
TESTS_RUN=$((TESTS_RUN + 1))
if grep -Fq -- "$ID_TO_PURGE" "$INBOX_PURGE"; then fail "purge(apply): the purged entry is gone from the log" "id still present"
else pass "purge(apply): the purged entry is gone from the log"; fi

# ===========================================================================
# purge-processed.sh — INBOX_PURGE_BACKUP=<path> is emitted only on a real
# --apply that wrote a backup (never on a dry-run), and the path it names is
# real, on disk, 600, and contains the removed line(s).
# ===========================================================================
section "purge-processed.sh — INBOX_PURGE_BACKUP path is emitted"
INBOX_PURGE_BK="$WORK/case-purge-backup/inbox.jsonl"

next_fixture_id
append_entry "$INBOX_PURGE_BK" "$FIXTURE_ID" "stays unprocessed" BK false
next_fixture_id; ID_TO_PURGE_BK=$FIXTURE_ID
append_entry "$INBOX_PURGE_BK" "$ID_TO_PURGE_BK" "removed line for the backup-path case" BK false
run 1 "INBOX_FILE=$INBOX_PURGE_BK" sh "$PROCESS" --id "$ID_TO_PURGE_BK"

# Dry-run: matches, but writes nothing — the key must NOT appear.
run 1 "INBOX_FILE=$INBOX_PURGE_BK" sh "$PURGE" --project BK
expect_rc "purge(backup-key, dry-run): -> exit 0" 0
TESTS_RUN=$((TESTS_RUN + 1))
if printf '%s\n' "$CUR_OUT" | grep -Fq -- "INBOX_PURGE_BACKUP="; then
	fail "purge(backup-key, dry-run): INBOX_PURGE_BACKUP is NOT printed" "found in stdout: $CUR_OUT"
else
	pass "purge(backup-key, dry-run): INBOX_PURGE_BACKUP is NOT printed"
fi

# --apply: the key IS printed, and it names a real backup file.
run 1 "INBOX_FILE=$INBOX_PURGE_BK" sh "$PURGE" --project BK --apply
expect_rc "purge(backup-key, apply): -> exit 0" 0
stdout_has "purge(backup-key, apply): purged 1" "INBOX_PURGED=1"

BACKUP_KEY_LINE=$(printf '%s\n' "$CUR_OUT" | grep -F -- "INBOX_PURGE_BACKUP=" || true)
TESTS_RUN=$((TESTS_RUN + 1))
if [ -n "$BACKUP_KEY_LINE" ]; then pass "purge(backup-key, apply): INBOX_PURGE_BACKUP= is printed"
else fail "purge(backup-key, apply): INBOX_PURGE_BACKUP= is printed" "not found in stdout: $CUR_OUT"; fi

BACKUP_KEY_PATH=$(printf '%s\n' "$BACKUP_KEY_LINE" | sed -n 's/^INBOX_PURGE_BACKUP=//p')
TESTS_RUN=$((TESTS_RUN + 1))
if [ -n "$BACKUP_KEY_PATH" ] && [ -f "$BACKUP_KEY_PATH" ]; then pass "purge(backup-key, apply): the printed path exists on disk"
else fail "purge(backup-key, apply): the printed path exists on disk" "path='$BACKUP_KEY_PATH'"; fi

check "purge(backup-key, apply): the backup file contains the removed entry's id" "id not found in backup" \
	"$( [ -n "$BACKUP_KEY_PATH" ] && grep -Fq -- "$ID_TO_PURGE_BK" "$BACKUP_KEY_PATH" && echo 0 || echo 1 )"
check "purge(backup-key, apply): the backup file is 600" "expected 600" \
	"$( [ -n "$BACKUP_KEY_PATH" ] && [ "$(perm_octal "$BACKUP_KEY_PATH")" = "600" ] && echo 0 || echo 1 )"

# ===========================================================================
# purge-processed.sh — preserves malformed lines
# ===========================================================================
section "purge-processed.sh — preserves malformed lines"
INBOX_PURGE_MALFORMED="$WORK/case-purge-malformed/inbox.jsonl"
next_fixture_id; ID_M1=$FIXTURE_ID
append_entry "$INBOX_PURGE_MALFORMED" "$ID_M1" "to be purged" M false
next_fixture_id
append_entry "$INBOX_PURGE_MALFORMED" "$FIXTURE_ID" "stays unprocessed" M false
run 1 "INBOX_FILE=$INBOX_PURGE_MALFORMED" sh "$PROCESS" --id "$ID_M1"
MALFORMED_M_LINE='{{{not json}}}'
printf '%s\n' "$MALFORMED_M_LINE" >>"$INBOX_PURGE_MALFORMED"

run 1 "INBOX_FILE=$INBOX_PURGE_MALFORMED" sh "$PURGE" --project M --apply
expect_rc "purge(preserve-malformed): -> exit 0" 0
stdout_has "purge(preserve-malformed): purged 1" "INBOX_PURGED=1"
TESTS_RUN=$((TESTS_RUN + 1))
if grep -Fxq -- "$MALFORMED_M_LINE" "$INBOX_PURGE_MALFORMED"; then pass "purge(preserve-malformed): malformed line survives byte-for-byte"
else fail "purge(preserve-malformed): malformed line survives byte-for-byte" "not found after purge"; fi

# ===========================================================================
# concurrency — process.sh blocks then succeeds once a held lock is
# released. capture.sh's own held-lock/stale-lock coverage lives in
# procedure-inbox-capture's suite; this suite proves the SAME on-disk
# `.inbox.lock` guarantee from the process/purge side (process.sh and
# purge-processed.sh share identical acquire_lock code, so exercising one
# is representative of both — no cross-script race test is needed).
# ===========================================================================
section "concurrency — process.sh blocks then succeeds once a held lock is released"
INBOX_CONC="$WORK/case-conc-process/inbox.jsonl"
GTD_CONC=$(dirname "$INBOX_CONC")
next_fixture_id; CONC_ID=$FIXTURE_ID
append_entry "$INBOX_CONC" "$CONC_ID" "entry to flip while the lock is held"

LOCK_CONC="$GTD_CONC/.inbox.lock"
mkdir "$LOCK_CONC"
printf '%s\n' "$$" >"$LOCK_CONC/pid"   # our own pid: alive, so this looks like a genuinely held lock

set +e
env -i HOME="$WORK/home" PATH="$JQDIR:$TOOLBOX" TMPDIR="$WORK" "INBOX_FILE=$INBOX_CONC" \
	sh "$PROCESS" --id "$CONC_ID" >"$WORK/conc-out" 2>"$WORK/conc-err" &
CONC_BGPID=$!
set -e

sleep 0.3
rm -rf "$LOCK_CONC"   # simulate the concurrent holder finishing and releasing the lock

set +e
wait "$CONC_BGPID"
CONC_RC=$?
set -e
CONC_OUT=$(cat "$WORK/conc-out"); CONC_ERR=$(cat "$WORK/conc-err")

TESTS_RUN=$((TESTS_RUN + 1))
if [ "$CONC_RC" -eq 0 ]; then pass "concurrency(queued-process): process succeeded after the lock was released"
else fail "concurrency(queued-process): process succeeded after the lock was released" "rc=$CONC_RC err=$CONC_ERR"; fi

TESTS_RUN=$((TESTS_RUN + 1))
if printf '%s\n' "$CONC_OUT" | grep -Fq -- "INBOX_PROCESSED=$CONC_ID"; then pass "concurrency(queued-process): stdout carries INBOX_PROCESSED"
else fail "concurrency(queued-process): stdout carries INBOX_PROCESSED" "$CONC_OUT"; fi

TESTS_RUN=$((TESTS_RUN + 1))
if tail -n 1 "$INBOX_CONC" | jqr -e '.is_processed == true' >/dev/null 2>&1; then
	pass "concurrency(queued-process): the entry was actually flipped, nothing lost"
else
	fail "concurrency(queued-process): the entry was actually flipped, nothing lost" "not flipped after the queued run"
fi

# ===========================================================================
# concurrency — a lock held by a dead pid is reclaimed (stale-lock
# regression), from the process.sh side.
# ===========================================================================
section "concurrency — a lock held by a dead pid is reclaimed (stale-lock regression, process.sh)"
INBOX_STALE="$WORK/case-stale-process/inbox.jsonl"
GTD_STALE=$(dirname "$INBOX_STALE")
next_fixture_id; STALE_ID=$FIXTURE_ID
append_entry "$INBOX_STALE" "$STALE_ID" "entry present before the stale-lock reclaim"

LOCK_STALE="$GTD_STALE/.inbox.lock"
mkdir "$LOCK_STALE"
printf '999999\n' >"$LOCK_STALE/pid"   # near-certainly not a live pid on this machine

START_TS=$(date +%s)
run 1 "INBOX_FILE=$INBOX_STALE" sh "$PROCESS" --id "$STALE_ID"
END_TS=$(date +%s)
expect_rc "concurrency(stale-lock, process): process succeeds (reclaimed, not waited out)" 0
stderr_has "concurrency(stale-lock, process): warns about reclaiming" "reclaiming stale inbox lock"
ELAPSED=$((END_TS - START_TS))
check "concurrency(stale-lock, process): reclaimed promptly (well under the 10s timeout)" "took ${ELAPSED}s" \
	"$( [ "$ELAPSED" -lt 5 ] && echo 0 || echo 1 )"

# the reclaim is an atomic `mv` (rename) of the stale lock dir to a
# `.stale.$$` name, never a blind `rm -rf` of the live lock name — confirm
# no `.stale.$$` temp is left behind after a normal (non-crashing) reclaim.
TESTS_RUN=$((TESTS_RUN + 1))
STALE_LEFTOVER=$(find "$GTD_STALE" -maxdepth 1 -name '.inbox.lock.stale.*' -print 2>/dev/null)
if [ -z "$STALE_LEFTOVER" ]; then pass "concurrency(stale-lock, process): no .stale.\$\$ reclaim temp left behind"
else fail "concurrency(stale-lock, process): no .stale.\$\$ reclaim temp left behind" "found: $STALE_LEFTOVER"; fi

# ===========================================================================
# render-md.sh — usage / shape errors
# ===========================================================================
section "render-md.sh — usage / shape errors"
run 1 sh "$RENDER" -h
expect_rc "render(usage): -h -> exit 0" 0
stdout_has "render(usage): help text" "Usage:"

printf '[]' >"$WORK/render-empty-array.json"
render_run bogus - "$WORK/render-empty-array.json"
expect_rc "render(bad --mode): -> exit 2" 2
stderr_has "render(bad --mode): diagnostic" "invalid --mode"

render_run list wat "$WORK/render-empty-array.json"
expect_rc "render(bad --status-label): -> exit 2" 2
stderr_has "render(bad --status-label): diagnostic" "invalid --status-label"

printf 'not json at all' >"$WORK/render-notjson.json"
render_run list active "$WORK/render-notjson.json"
expect_rc "render(non-JSON stdin): -> exit 1" 1
stderr_has "render(non-JSON stdin): diagnostic" "not valid JSON"

printf '{"id":"x"}' >"$WORK/render-object.json"
render_run list active "$WORK/render-object.json"
expect_rc "render(list given an object): -> exit 1" 1
stderr_has "render(list given an object): diagnostic" "expects a JSON array"

printf '[]' >"$WORK/render-empty-for-captured.json"
render_run captured - "$WORK/render-empty-for-captured.json"
expect_rc "render(captured given empty array): -> exit 1" 1
stderr_has "render(captured given empty array): diagnostic" "expects one record on stdin"

# A SCALAR (or a non-object array element) must fail closed with a
# clean exit 1 — never let `.ts`/`.text` raw-abort jq with exit 5.
printf '5' >"$WORK/render-scalar.json"
render_run captured - "$WORK/render-scalar.json"
expect_rc "render(captured given a scalar): -> exit 1" 1
stderr_has "render(captured given a scalar): diagnostic names the type" "got: number"

printf '["not-an-object"]' >"$WORK/render-array-of-scalar.json"
render_run processed - "$WORK/render-array-of-scalar.json"
expect_rc "render(processed given an array of scalars): -> exit 1" 1
stderr_has "render(processed given an array of scalars): diagnostic" "got: string"

# ===========================================================================
# render-md.sh — Template A (list) golden files
# ===========================================================================
section "render-md.sh — Template A (list) goldens"

# N==0 across all three status labels (heading only, no item blocks).
printf '[]' >"$WORK/A0.json"

render_run list active "$WORK/A0.json"
expect_rc "render(A, N=0, active): -> exit 0" 0
cat >"$WORK/A0-active.golden" <<'EOF'
## Inbox — no active items
EOF
assert_golden "render(A, N=0, active): golden" "$WORK/A0-active.golden"

render_run list processed "$WORK/A0.json"
cat >"$WORK/A0-processed.golden" <<'EOF'
## Inbox — no processed items
EOF
assert_golden "render(A, N=0, processed): golden" "$WORK/A0-processed.golden"

render_run list all "$WORK/A0.json"
cat >"$WORK/A0-all.golden" <<'EOF'
## Inbox — no items
EOF
assert_golden "render(A, N=0, all): golden" "$WORK/A0-all.golden"

# N==1 active, a record WITH project + session_id — singular "item".
jq -c -n '[{schema_version:"1.0",id:"i1",ts:"2026-01-01T00:00:00Z",text:"hello world",project:"my-repo",is_processed:false,note:null,session_id:"sess-1"}]' >"$WORK/A1.json"
render_run list active "$WORK/A1.json"
expect_rc "render(A, N=1, active): -> exit 0" 0
cat >"$WORK/A1.golden" <<'EOF'
## Inbox — 1 active item

### My repo

**1.**
> hello world

- Captured: 2026-01-01 00:00 UTC
- Session ID: sess-1
EOF
assert_golden "render(A, N=1, active, full fields): golden" "$WORK/A1.golden"

# N==1 all — heading qualifier "1 item". Single project -> exactly one group
# header, no per-item Project bullet.
render_run list all "$WORK/A1.json"
cat >"$WORK/A1-all.golden" <<'EOF'
## Inbox — 1 item

### My repo

**1.**
> hello world

- Captured: 2026-01-01 00:00 UTC
- Session ID: sess-1
EOF
assert_golden "render(A, N=1, all, single-project group): golden" "$WORK/A1-all.golden"

# N==2: item 1 has project + session; item 2 has NO project (only Captured) —
# proves the optional Session ID bullet appears ONLY when present, the per-item
# Project bullet is DROPPED (now in the group header), an entry with no project
# renders under a literal "### (no project)" header placed LAST, and the
# multiline blockquote / inter-item + inter-group spacing.
jq -c -n '[
  {schema_version:"1.0",id:"i1",ts:"2026-01-01T00:00:00Z",text:"first",project:"repo-a",is_processed:false,note:null,session_id:"s1"},
  {schema_version:"1.0",id:"i2",ts:"2026-01-02T09:30:00Z",text:"second line one\nsecond line two",is_processed:false,note:null}
]' >"$WORK/A2.json"
render_run list active "$WORK/A2.json"
expect_rc "render(A, N=2): -> exit 0" 0
cat >"$WORK/A2.golden" <<'EOF'
## Inbox — 2 active items

### Repo a

**1.**
> first

- Captured: 2026-01-01 00:00 UTC
- Session ID: s1

### (no project)

**2.**
> second line one
> second line two

- Captured: 2026-01-02 09:30 UTC
EOF
assert_golden "render(A, N=2, group headers + no-project last + no Project bullet): golden" "$WORK/A2.golden"

# N==3, TWO named projects with the FIRST group holding TWO items — proves the
# global ordinal does NOT reset per group (Beta's item is **3.**, not **1.**),
# A->Z group ordering, and one header per group. Fed pre-sorted, exactly as
# list.sh's canonical order would emit it.
jq -c -n '[
  {schema_version:"1.0",id:"a1",ts:"2026-01-01T00:00:00Z",text:"alpha one",project:"alpha",is_processed:false,note:null},
  {schema_version:"1.0",id:"a2",ts:"2026-01-01T01:00:00Z",text:"alpha two",project:"alpha",is_processed:false,note:null},
  {schema_version:"1.0",id:"b1",ts:"2026-01-01T02:00:00Z",text:"beta one",project:"beta",is_processed:false,note:null}
]' >"$WORK/Amulti.json"
render_run list active "$WORK/Amulti.json"
expect_rc "render(A, N=3, multi-project): -> exit 0" 0
cat >"$WORK/Amulti.golden" <<'EOF'
## Inbox — 3 active items

### Alpha

**1.**
> alpha one

- Captured: 2026-01-01 00:00 UTC

**2.**
> alpha two

- Captured: 2026-01-01 01:00 UTC

### Beta

**3.**
> beta one

- Captured: 2026-01-01 02:00 UTC
EOF
assert_golden "render(A, N=3, multi-project global ordinals): golden" "$WORK/Amulti.golden"

# N==2 with --status-label processed — pluralized "processed items"
# heading (the processed label was previously only exercised at N==0).
jq -c -n '[
  {schema_version:"1.0",id:"i1",ts:"2026-01-01T00:00:00Z",text:"done one",project:"repo-a",is_processed:true,note:null,session_id:"s1",processed_ts:"2026-01-02T08:00:00Z"},
  {schema_version:"1.0",id:"i2",ts:"2026-01-01T01:00:00Z",text:"done two",is_processed:true,note:null}
]' >"$WORK/A2proc.json"
render_run list processed "$WORK/A2proc.json"
expect_rc "render(A, N=2, processed label): -> exit 0" 0
cat >"$WORK/A2proc.golden" <<'EOF'
## Inbox — 2 processed items

### Repo a

**1.**
> done one

- Captured: 2026-01-01 00:00 UTC
- Session ID: s1

### (no project)

**2.**
> done two

- Captured: 2026-01-01 01:00 UTC
EOF
assert_golden "render(A, N=2, processed pluralization + grouping): golden" "$WORK/A2proc.golden"

# ===========================================================================
# render-md.sh — Template B (captured) goldens
# ===========================================================================
section "render-md.sh — Template B (captured) goldens"

# Fed as a ONE-ELEMENT ARRAY, exactly as `list.sh --id ID` emits — proves the
# array-or-object normalization.
jq -c -n '[{schema_version:"1.0",id:"i1",ts:"2026-01-01T00:00:00Z",text:"buy milk",project:"my-repo",is_processed:false,note:null,session_id:"s9"}]' >"$WORK/B-cap-full.json"
render_run captured - "$WORK/B-cap-full.json"
expect_rc "render(B captured, array input, full): -> exit 0" 0
cat >"$WORK/B-cap-full.golden" <<'EOF'
Captured to inbox.

> buy milk

- Captured: 2026-01-01 00:00 UTC
- Project: My repo
- Session ID: s9
EOF
assert_golden "render(B captured, full fields): golden" "$WORK/B-cap-full.golden"

# Bare OBJECT input, no project / no session_id — only Captured.
jq -c -n '{schema_version:"1.0",id:"i1",ts:"2026-01-01T00:00:00Z",text:"buy milk",is_processed:false,note:null}' >"$WORK/B-cap-min.json"
render_run captured - "$WORK/B-cap-min.json"
expect_rc "render(B captured, object input, minimal): -> exit 0" 0
cat >"$WORK/B-cap-min.golden" <<'EOF'
Captured to inbox.

> buy milk

- Captured: 2026-01-01 00:00 UTC
EOF
assert_golden "render(B captured, minimal fields): golden" "$WORK/B-cap-min.golden"

# ===========================================================================
# render-md.sh — Template B (processed) goldens
# ===========================================================================
section "render-md.sh — Template B (processed) goldens"

# Full: processed_ts + note + project + session_id (all optional bullets).
jq -c -n '[{schema_version:"1.0",id:"i1",ts:"2026-01-01T00:00:00Z",text:"ship it",project:"my-repo",is_processed:true,note:"became ticket #42",session_id:"s9",processed_ts:"2026-01-02T10:15:00Z"}]' >"$WORK/B-proc-full.json"
render_run processed - "$WORK/B-proc-full.json"
expect_rc "render(B processed, full): -> exit 0" 0
cat >"$WORK/B-proc-full.golden" <<'EOF'
Processed inbox item.

> ship it

- Captured: 2026-01-01 00:00 UTC
- Processed: 2026-01-02 10:15 UTC
- Project: My repo
- Session ID: s9
- Outcome: became ticket #42
EOF
assert_golden "render(B processed, full fields): golden" "$WORK/B-proc-full.golden"

# Minimal: no note (null), no processed_ts — neither line appears.
jq -c -n '[{schema_version:"1.0",id:"i1",ts:"2026-01-01T00:00:00Z",text:"ship it",is_processed:true,note:null}]' >"$WORK/B-proc-min.json"
render_run processed - "$WORK/B-proc-min.json"
expect_rc "render(B processed, minimal): -> exit 0" 0
cat >"$WORK/B-proc-min.golden" <<'EOF'
Processed inbox item.

> ship it

- Captured: 2026-01-01 00:00 UTC
EOF
assert_golden "render(B processed, no note / no processed_ts): golden" "$WORK/B-proc-min.golden"

# processed_ts PRESENT but note NULL — the common no-note receipt:
# the Processed line appears, the Outcome line is dropped.
jq -c -n '[{schema_version:"1.0",id:"i1",ts:"2026-01-01T00:00:00Z",text:"ship it",project:"my-repo",is_processed:true,note:null,session_id:"s9",processed_ts:"2026-01-02T10:15:00Z"}]' >"$WORK/B-proc-nonote.json"
render_run processed - "$WORK/B-proc-nonote.json"
expect_rc "render(B processed, processed_ts + null note): -> exit 0" 0
cat >"$WORK/B-proc-nonote.golden" <<'EOF'
Processed inbox item.

> ship it

- Captured: 2026-01-01 00:00 UTC
- Processed: 2026-01-02 10:15 UTC
- Project: My repo
- Session ID: s9
EOF
assert_golden "render(B processed, processed_ts present, note null → no Outcome line): golden" "$WORK/B-proc-nonote.golden"

# ===========================================================================
# render-md.sh — captured text is DATA, rendered INERT
# ===========================================================================
section "render-md.sh — captured text is inert (injection safety)"

# Text containing " $(...) backtick | and a LEADING > — none may execute or
# alter the document structure; it only ever flows as a jq string value into
# the blockquote body. A byte-exact golden IS the proof: if any layer expanded
# $(whoami) or ran `id`, the bytes would differ.
# shellcheck disable=SC2016  # single-quoted ON PURPOSE — $(whoami)/`id`/$HOME
# must NOT expand; they are the literal bytes under test, the exact thing
# render-md.sh must render inert.
printf 'run $(whoami) and `id`; a | "pipe"\n> leading gt' >"$WORK/inert-text.txt"
jq -c -n --rawfile t "$WORK/inert-text.txt" '[{schema_version:"1.0",id:"i1",ts:"2026-01-01T00:00:00Z",text:$t,is_processed:false,note:null}]' >"$WORK/inert.json"
render_run captured - "$WORK/inert.json"
expect_rc "render(inert): -> exit 0" 0
cat >"$WORK/inert.golden" <<'EOF'
Captured to inbox.

> run $(whoami) and `id`; a | "pipe"
> > leading gt

- Captured: 2026-01-01 00:00 UTC
EOF
assert_golden "render(inert): metachars rendered verbatim, structure intact" "$WORK/inert.golden"
# shellcheck disable=SC2016  # the needle is the LITERAL $(whoami) text — it must not expand
stdout_has "render(inert): literal \$(whoami) survives unexecuted" 'run $(whoami)'

# ===========================================================================
# render-md.sh — transforms (sentence-case project + minute-precision ts)
# ===========================================================================
section "render-md.sh — deterministic transforms"

# Multi-hyphen + underscore -> sentence case; seconds dropped to minute
# precision (13:45:59 -> 13:45).
jq -c -n '{schema_version:"1.0",id:"i1",ts:"2026-03-09T13:45:59Z",text:"x",project:"claude-code-foundry",is_processed:false,note:null}' >"$WORK/xform1.json"
render_run captured - "$WORK/xform1.json"
stdout_has "render(xform): claude-code-foundry -> 'Claude code foundry'" "- Project: Claude code foundry"
stdout_has "render(xform): minute precision drops seconds" "- Captured: 2026-03-09 13:45 UTC"

jq -c -n '{schema_version:"1.0",id:"i1",ts:"2026-03-09T13:45:59Z",text:"x",project:"my_cool_repo",is_processed:false,note:null}' >"$WORK/xform2.json"
render_run captured - "$WORK/xform2.json"
stdout_has "render(xform): underscores -> spaces, first cap" "- Project: My cool repo"

# An UNPARSEABLE ts exercises the fixed-position slice fallback of
# the timestamp transform (the parse path's `catch`) — pinned byte-exact.
# "not-a-date-xxxxxxxxxxxx" -> [0:10]="not-a-date" + " " + [11:16]="xxxxx".
jq -c -n '{schema_version:"1.0",id:"i1",ts:"not-a-date-xxxxxxxxxxxx",text:"y",is_processed:false,note:null}' >"$WORK/xform-badts.json"
render_run captured - "$WORK/xform-badts.json"
expect_rc "render(xform, unparseable ts): -> exit 0" 0
cat >"$WORK/xform-badts.golden" <<'EOF'
Captured to inbox.

> y

- Captured: not-a-date xxxxx UTC
EOF
assert_golden "render(xform, unparseable ts): slice fallback golden" "$WORK/xform-badts.golden"

# A text ending in a newline must NOT produce a dangling "> " line —
# blockquote() trims exactly one trailing newline first.
printf 'final line\n' >"$WORK/trailing-nl.txt"
jq -c -n --rawfile t "$WORK/trailing-nl.txt" '[{schema_version:"1.0",id:"i1",ts:"2026-01-01T00:00:00Z",text:$t,is_processed:false,note:null}]' >"$WORK/trailing-nl.json"
render_run captured - "$WORK/trailing-nl.json"
expect_rc "render(trailing-newline text): -> exit 0" 0
cat >"$WORK/trailing-nl.golden" <<'EOF'
Captured to inbox.

> final line

- Captured: 2026-01-01 00:00 UTC
EOF
assert_golden "render(trailing-newline text): no dangling blockquote line" "$WORK/trailing-nl.golden"

# ===========================================================================
# list.sh — --session-id filter (combines with --project/status)
# ===========================================================================
section "list.sh — --session-id filter"
INBOX_SESS="$WORK/case-session/inbox.jsonl"
mkdir -p "$(dirname "$INBOX_SESS")"
{
	jq -c -n '{schema_version:"1.0",id:"20260101T000001Z-aaaaaaaa",ts:"2026-01-01T00:00:01Z",text:"one",project:"repo-a",is_processed:false,note:null,session_id:"S1"}'
	jq -c -n '{schema_version:"1.0",id:"20260101T000002Z-bbbbbbbb",ts:"2026-01-01T00:00:02Z",text:"two",project:"repo-a",is_processed:false,note:null,session_id:"S2"}'
	jq -c -n '{schema_version:"1.0",id:"20260101T000003Z-cccccccc",ts:"2026-01-01T00:00:03Z",text:"three",project:"repo-b",is_processed:false,note:null,session_id:"S1"}'
} >>"$INBOX_SESS"

run 1 "INBOX_FILE=$INBOX_SESS" sh "$LIST" --session-id S1 --all
expect_rc "list(--session-id S1): -> exit 0" 0
check "list(--session-id S1): exactly 2 entries" "expected length 2" \
	"$( [ "$(printf '%s' "$CUR_OUT" | jqr 'length')" -eq 2 ] && echo 0 || echo 1 )"
check "list(--session-id S1): both carry session_id S1" "a non-S1 entry leaked" \
	"$( printf '%s' "$CUR_OUT" | jqr -e 'all(.[]; .session_id == "S1")' >/dev/null 2>&1 && echo 0 || echo 1 )"

run 1 "INBOX_FILE=$INBOX_SESS" sh "$LIST" --session-id S1 --project repo-a --all
expect_rc "list(--session-id + --project, AND): -> exit 0" 0
check "list(--session-id S1 + --project repo-a): exactly 1 entry" "expected length 1" \
	"$( [ "$(printf '%s' "$CUR_OUT" | jqr 'length')" -eq 1 ] && echo 0 || echo 1 )"
check "list(--session-id S1 + --project repo-a): it is the aaaa entry" "wrong id" \
	"$( [ "$(printf '%s' "$CUR_OUT" | jqr -r '.[0].id')" = "20260101T000001Z-aaaaaaaa" ] && echo 0 || echo 1 )"

run 1 "INBOX_FILE=$INBOX_SESS" sh "$LIST" --session-id NOPE --all
expect_rc "list(--session-id no match): -> exit 0" 0
stdout_has "list(--session-id no match): prints []" "[]"

# Old spelling is gone: --session is now an unknown option, not a silent alias.
run 1 "INBOX_FILE=$INBOX_SESS" sh "$LIST" --session S1 --all
expect_rc "list(--session, the old name): -> exit 2" 2
stderr_has "list(--session, the old name): diagnostic" "unknown option: --session"

# ===========================================================================
# list.sh — --ids multi-select (canonical order) + mutual exclusion
# ===========================================================================
section "list.sh — --ids multi-select + mutual exclusion"

# Listed reversed on the command line — output MUST be the CANONICAL order
# (project asc, then id), not the argument order. aaaa is project repo-a and
# cccc is repo-b, so repo-a's aaaa sorts first regardless of how they were
# listed.
run 1 "INBOX_FILE=$INBOX_SESS" sh "$LIST" --ids "20260101T000003Z-cccccccc,20260101T000001Z-aaaaaaaa"
expect_rc "list(--ids multi): -> exit 0" 0
check "list(--ids multi): exactly 2 entries" "expected length 2" \
	"$( [ "$(printf '%s' "$CUR_OUT" | jqr 'length')" -eq 2 ] && echo 0 || echo 1 )"
check "list(--ids multi): first is repo-a's aaaa (canonical project order, not arg order)" "order not canonical" \
	"$( [ "$(printf '%s' "$CUR_OUT" | jqr -r '.[0].id')" = "20260101T000001Z-aaaaaaaa" ] && echo 0 || echo 1 )"
check "list(--ids multi): second is repo-b's cccc" "wrong second id" \
	"$( [ "$(printf '%s' "$CUR_OUT" | jqr -r '.[1].id')" = "20260101T000003Z-cccccccc" ] && echo 0 || echo 1 )"

run 1 "INBOX_FILE=$INBOX_SESS" sh "$LIST" --ids "does-not-exist,also-nope"
expect_rc "list(--ids no match): -> exit 0" 0
stdout_has "list(--ids no match): prints []" "[]"

run 1 "INBOX_FILE=$INBOX_SESS" sh "$LIST" --ids "x,y" --project repo-a
expect_rc "list(--ids + --project): -> exit 2" 2
stderr_has "list(--ids + --project): diagnostic" "mutually exclusive"

run 1 "INBOX_FILE=$INBOX_SESS" sh "$LIST" --ids "x,y" --session-id S1
expect_rc "list(--ids + --session-id): -> exit 2" 2
stderr_has "list(--ids + --session-id): diagnostic" "mutually exclusive"

run 1 "INBOX_FILE=$INBOX_SESS" sh "$LIST" --ids "x,y" --active
expect_rc "list(--ids + --active): -> exit 2" 2
stderr_has "list(--ids + --active): diagnostic" "mutually exclusive"

run 1 "INBOX_FILE=$INBOX_SESS" sh "$LIST" --id "x" --ids "y,z"
expect_rc "list(--id + --ids): -> exit 2" 2
stderr_has "list(--id + --ids): diagnostic" "mutually exclusive"

run 1 sh "$LIST" --ids
expect_rc "list(--ids no value): -> exit 2" 2
stderr_has "list(--ids no value): diagnostic" "requires an argument"

# ===========================================================================
# list.sh — --format json|md
# ===========================================================================
section "list.sh — --format json|md"

# json is the DEFAULT and byte-for-byte what an explicit --format json emits.
run 1 "INBOX_FILE=$INBOX_SESS" sh "$LIST" --all
DEFAULT_OUT=$CUR_OUT
run 1 "INBOX_FILE=$INBOX_SESS" sh "$LIST" --all --format json
check "list(--format json == default): identical stdout" "explicit json differs from default" \
	"$( [ "$CUR_OUT" = "$DEFAULT_OUT" ] && echo 0 || echo 1 )"

run 1 "INBOX_FILE=$INBOX_SESS" sh "$LIST" --all --format md
expect_rc "list(--format md): -> exit 0" 0
stdout_has "list(--format md): renders the list heading" "## Inbox —"
stdout_has "list(--format md): renders a bold global ordinal" "**1.**"
stdout_has "list(--format md): renders a sentence-cased project group header" "### Repo a"
TESTS_RUN=$((TESTS_RUN + 1))
if printf '%s\n' "$CUR_OUT" | grep -Fq -- "- Project:"; then
	fail "list(--format md): the per-item Project bullet is DROPPED in list mode" "found '- Project:' in: $CUR_OUT"
else
	pass "list(--format md): the per-item Project bullet is DROPPED in list mode"
fi

run 1 "INBOX_FILE=$INBOX_SESS" sh "$LIST" --processed --format md
expect_rc "list(--format md, processed label): -> exit 0" 0
stdout_has "list(--format md, processed label, none processed): no-items heading" "## Inbox — no processed items"

run 1 "INBOX_FILE=$WORK/does-not-exist/inbox.jsonl" sh "$LIST" --all --format md
expect_rc "list(--format md, absent file): -> exit 0" 0
stdout_has "list(--format md, absent file): renders the empty heading, not []" "## Inbox — no items"

run 1 "INBOX_FILE=$INBOX_SESS" sh "$LIST" --all --format xml
expect_rc "list(--format xml): -> exit 2" 2
stderr_has "list(--format xml): diagnostic" "invalid --format"

# --format md with render-md.sh absent from list.sh's own dir must
# fail closed (exit 1) with a clear diagnostic — never emit nothing. Run a
# COPY of list.sh from a dir that has no render-md.sh beside it, so its
# SCRIPT_DIR resolves to a location where the renderer genuinely isn't.
NORENDER_DIR="$WORK/norender"
mkdir -p "$NORENDER_DIR"
cp "$LIST" "$NORENDER_DIR/list.sh"
run 1 "INBOX_FILE=$INBOX_SESS" sh "$NORENDER_DIR/list.sh" --all --format md
expect_rc "list(--format md, render-md.sh missing): -> exit 1" 1
stderr_has "list(--format md, render-md.sh missing): diagnostic" "render-md.sh not found"
# json still works from that dir (render-md.sh is only needed for md).
run 1 "INBOX_FILE=$INBOX_SESS" sh "$NORENDER_DIR/list.sh" --all --format json
expect_rc "list(--format json, render-md.sh missing): still fine -> exit 0" 0

# --id / --ids with --format md label the heading "all" (neutral
# "item(s)"), NOT the "active" default — so a PROCESSED entry selected by id
# is never mislabeled "1 active item".
INBOX_IDLABEL="$WORK/case-idlabel/inbox.jsonl"
mkdir -p "$(dirname "$INBOX_IDLABEL")"
jq -c -n '{schema_version:"1.0",id:"20260105T000005Z-55555555",ts:"2026-01-05T00:00:05Z",text:"done",project:"repo-a",is_processed:true,note:null,processed_ts:"2026-01-06T00:00:00Z"}' >>"$INBOX_IDLABEL"
run 1 "INBOX_FILE=$INBOX_IDLABEL" sh "$LIST" --id "20260105T000005Z-55555555" --format md
expect_rc "list(--id + --format md, processed entry): -> exit 0" 0
stdout_has "list(--id + --format md): neutral 'item' heading" "## Inbox — 1 item"
TESTS_RUN=$((TESTS_RUN + 1))
if printf '%s\n' "$CUR_OUT" | grep -Fq -- "active item"; then
	fail "list(--id + --format md): heading is NOT mislabeled 'active'" "found 'active item' in: $CUR_OUT"
else
	pass "list(--id + --format md): heading is NOT mislabeled 'active'"
fi
run 1 "INBOX_FILE=$INBOX_IDLABEL" sh "$LIST" --ids "20260105T000005Z-55555555" --format md
expect_rc "list(--ids + --format md, processed entry): -> exit 0" 0
stdout_has "list(--ids + --format md): neutral 'item' heading" "## Inbox — 1 item"

# ===========================================================================
# process.sh — processed_ts stamped on flip, removed on --unprocess
# ===========================================================================
section "process.sh — processed_ts stamp lifecycle"
INBOX_PTS="$WORK/case-pts/inbox.jsonl"
mkdir -p "$(dirname "$INBOX_PTS")"
jq -c -n '{schema_version:"1.0",id:"20260101T000009Z-99999999",ts:"2026-01-01T00:00:09Z",text:"stamp me",project:"P",is_processed:false,note:null}' >>"$INBOX_PTS"

run 1 "INBOX_FILE=$INBOX_PTS" sh "$PROCESS" --id "20260101T000009Z-99999999"
expect_rc "process(pts flip): -> exit 0" 0
check "process(pts flip): processed_ts present and a string" "processed_ts missing or not a string" \
	"$( tail -n 1 "$INBOX_PTS" | jqr -e '(.processed_ts | type) == "string"' >/dev/null 2>&1 && echo 0 || echo 1 )"
check "process(pts flip): processed_ts is ISO-8601 Z (render-md-parseable)" "processed_ts wrong shape" \
	"$( tail -n 1 "$INBOX_PTS" | jqr -e '.processed_ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' >/dev/null 2>&1 && echo 0 || echo 1 )"

run 1 "INBOX_FILE=$INBOX_PTS" sh "$PROCESS" --id "20260101T000009Z-99999999" --unprocess
expect_rc "process(pts unprocess): -> exit 0" 0
check "process(pts unprocess): processed_ts REMOVED (key absent)" "processed_ts still present after unprocess" \
	"$( tail -n 1 "$INBOX_PTS" | jqr -e '(has("processed_ts")) | not' >/dev/null 2>&1 && echo 0 || echo 1 )"
check "process(pts unprocess): is_processed back to false" "is_processed not false" \
	"$( tail -n 1 "$INBOX_PTS" | jqr -e '.is_processed == false' >/dev/null 2>&1 && echo 0 || echo 1 )"

# Re-flip with a note: processed_ts is stamped AND the note stored together.
NOTE_PTS="$WORK/note-pts.md"
printf 'became ticket #7' >"$NOTE_PTS"
run 1 "INBOX_FILE=$INBOX_PTS" sh "$PROCESS" --id "20260101T000009Z-99999999" --note-file "$NOTE_PTS"
expect_rc "process(pts re-flip + note): -> exit 0" 0
check "process(pts re-flip + note): processed_ts re-stamped" "processed_ts missing on re-flip" \
	"$( tail -n 1 "$INBOX_PTS" | jqr -e '(.processed_ts | type) == "string"' >/dev/null 2>&1 && echo 0 || echo 1 )"
check "process(pts re-flip + note): note stored verbatim" "note mismatch" \
	"$( [ "$(tail -n 1 "$INBOX_PTS" | jqr -j '.note')" = "became ticket #7" ] && echo 0 || echo 1 )"

# ===========================================================================
# list.sh — the canonical order (project asc, CASE-INSENSITIVE by display name,
# no-project LAST; then id asc) is applied to the JSON result on EVERY path.
# The fixture's INSERTION order is deliberately NOT canonical, and it carries a
# CASE-FOLD DISCRIMINATOR — projects "Apple"/"apple" vs "Zebra": under a raw
# byte-order sort "Apple"(0x41) < "Zebra"(0x5A) < "apple"(0x61), which would
# SPLIT the apple entries around the Zebra group; only an `ascii_downcase` key
# keeps the two apples contiguous AND ahead of Zebra. So this fixture FAILS a
# case-sensitive sort, proving `ascii_downcase` is load-bearing.
# ===========================================================================
section "list.sh — canonical order (case-insensitive, no-project last, id secondary)"
INBOX_SORT="$WORK/case-sort/inbox.jsonl"
mkdir -p "$(dirname "$INBOX_SORT")"
# Insertion order (jumbled): Zebra/33333, (no project)/22222, apple/55555,
# Apple/11111, Zebra/44444. Canonical order MUST be:
#   Apple/11111, apple/55555  (project_key "apple", case-folded; id asc),
#   Zebra/33333, Zebra/44444  (project_key "zebra"; id asc),
#   (no project)/22222        (LAST, sorted by id).
{
	jq -c -n '{schema_version:"1.0",id:"20260101T000003Z-33333333",ts:"2026-01-01T00:00:03Z",text:"zebra three",project:"Zebra",is_processed:false,note:null}'
	jq -c -n '{schema_version:"1.0",id:"20260101T000002Z-22222222",ts:"2026-01-01T00:00:02Z",text:"no project",is_processed:false,note:null}'
	jq -c -n '{schema_version:"1.0",id:"20260101T000005Z-55555555",ts:"2026-01-01T00:00:05Z",text:"apple five",project:"apple",is_processed:false,note:null}'
	jq -c -n '{schema_version:"1.0",id:"20260101T000001Z-11111111",ts:"2026-01-01T00:00:01Z",text:"apple one",project:"Apple",is_processed:false,note:null}'
	jq -c -n '{schema_version:"1.0",id:"20260101T000004Z-44444444",ts:"2026-01-01T00:00:04Z",text:"zebra four",project:"Zebra",is_processed:false,note:null}'
} >>"$INBOX_SORT"

# The single canonical id order this run must produce — the anchor BOTH the
# json sort test and THE INVARIANT below assert against (a hardcoded EXPECT, so
# they fail if the sort is wrong/removed, not merely if json and md agree).
SORT_EXPECT_IDS="20260101T000001Z-11111111,20260101T000005Z-55555555,20260101T000003Z-33333333,20260101T000004Z-44444444,20260101T000002Z-22222222"
SORT_EXPECT_TEXTS=$(printf '%s\n' "apple one" "apple five" "zebra three" "zebra four" "no project")

run 1 "INBOX_FILE=$INBOX_SORT" sh "$LIST" --all
expect_rc "list(canonical sort): -> exit 0" 0
SORT_IDS=$(printf '%s' "$CUR_OUT" | jqr -r '[.[].id] | join(",")')
check "list(canonical sort): id sequence matches the hardcoded canonical EXPECT" \
	"got: $SORT_IDS" \
	"$( [ "$SORT_IDS" = "$SORT_EXPECT_IDS" ] && echo 0 || echo 1 )"
# The case-fold discriminator: the apple group (Apple, apple) is contiguous AND
# precedes the Zebra group — impossible under a raw case-SENSITIVE sort, which
# would interleave Zebra between "Apple" and "apple". Proves ascii_downcase.
check "list(canonical sort): case-folded apple group precedes Zebra (ascii_downcase load-bearing)" "case-folding broke" \
	"$( [ "$(printf '%s' "$CUR_OUT" | jqr -r '.[0].project')" = "Apple" ] && [ "$(printf '%s' "$CUR_OUT" | jqr -r '.[1].project')" = "apple" ] && [ "$(printf '%s' "$CUR_OUT" | jqr -r '.[2].project')" = "Zebra" ] && echo 0 || echo 1 )"
# The no-project entry is LAST despite being the 2nd inserted — proves the
# explicit partition, not empty-string byte order (which would sort it FIRST).
check "list(canonical sort): the no-project entry sorts LAST" "no-project not last" \
	"$( [ "$(printf '%s' "$CUR_OUT" | jqr -r '.[-1].id')" = "20260101T000002Z-22222222" ] && echo 0 || echo 1 )"

# ===========================================================================
# list.sh — a schema-VIOLATING but well-formed line (a non-string or
# empty-string `project`) must NOT abort the resilient read/sort, and must be
# treated as no-project (grouped under "### (no project)"). Regression guard:
# project_key/sentence_case must only ever see a non-empty string.
# ===========================================================================
section "list.sh — non-string / empty-string project is treated as no-project, never aborts"
INBOX_BADPROJ="$WORK/case-badproj/inbox.jsonl"
mkdir -p "$(dirname "$INBOX_BADPROJ")"
{
	jq -c -n '{schema_version:"1.0",id:"20260101T000010Z-aaaaaaaa",ts:"2026-01-01T00:00:10Z",text:"real one",project:"realproj",is_processed:false,note:null}'
	jq -c -n '{schema_version:"1.0",id:"20260101T000011Z-bbbbbbbb",ts:"2026-01-01T00:00:11Z",text:"num project",project:5,is_processed:false,note:null}'
	jq -c -n '{schema_version:"1.0",id:"20260101T000012Z-cccccccc",ts:"2026-01-01T00:00:12Z",text:"empty project",project:"",is_processed:false,note:null}'
} >>"$INBOX_BADPROJ"

# json path: the sort does not abort, all three survive, and the named entry
# leads while the non-string + empty ones fall to the no-project tail (by id).
run 1 "INBOX_FILE=$INBOX_BADPROJ" sh "$LIST" --all
expect_rc "list(bad-project, json): -> exit 0 (sort did NOT abort)" 0
check "list(bad-project, json): all 3 entries survive the read/sort" "expected length 3" \
	"$( [ "$(printf '%s' "$CUR_OUT" | jqr 'length')" -eq 3 ] && echo 0 || echo 1 )"
BADPROJ_IDS=$(printf '%s' "$CUR_OUT" | jqr -r '[.[].id] | join(",")')
check "list(bad-project, json): realproj leads; non-string(5) + empty fall to the no-project tail by id" \
	"got: $BADPROJ_IDS" \
	"$( [ "$BADPROJ_IDS" = "20260101T000010Z-aaaaaaaa,20260101T000011Z-bbbbbbbb,20260101T000012Z-cccccccc" ] && echo 0 || echo 1 )"

# md path: render does not abort; exactly two group headers — the real project
# and a single "### (no project)" covering BOTH the non-string and empty entries.
run 1 "INBOX_FILE=$INBOX_BADPROJ" sh "$LIST" --all --format md
expect_rc "list(bad-project, md): -> exit 0 (render did NOT abort)" 0
BADPROJ_HEADERS=$(printf '%s\n' "$CUR_OUT" | grep '^### ')
BADPROJ_HEADERS_EXPECT=$(printf '%s\n' "### Realproj" "### (no project)")
check "list(bad-project, md): headers are exactly '### Realproj' then '### (no project)'" \
	"got:$(printf '\n')$BADPROJ_HEADERS" \
	"$( [ "$BADPROJ_HEADERS" = "$BADPROJ_HEADERS_EXPECT" ] && echo 0 || echo 1 )"
stdout_has "list(bad-project, md): the non-string-project entry is still rendered" "num project"
stdout_has "list(bad-project, md): the empty-project entry is still rendered" "empty project"

# ===========================================================================
# THE INVARIANT — ordinal N in the rendered md maps to json[N-1] for the SAME
# filter. This is the "process item N targets the right record" guarantee: the
# human points at ordinal N in the list, the agent reads json[N-1].id off the
# parallel JSON, and they MUST be the same entry.
#
# It guards TWO things against a KNOWN canonical EXPECT (not merely md==json,
# which would still pass if the sort were removed from BOTH):
#   (1) list.sh's canonical ORDER — json .[].text must equal the hardcoded
#       SORT_EXPECT_TEXTS; and
#   (2) render-md.sh's ORDER-PRESERVATION — the md item sequence, extracted by
#       anchoring on the "**N.**" ordinal markers (NOT `grep '^> '`, which would
#       misread a multiline blockquote), must equal that same EXPECT.
# Removing/breaking the sort fails (1); a render-md that reordered fails (2).
# ===========================================================================
section "list.sh — INVARIANT: md ordinal N maps to json[N-1] (both vs a known EXPECT)"
run 1 "INBOX_FILE=$INBOX_SORT" sh "$LIST" --all --format json
INV_JSON_TEXTS=$(printf '%s' "$CUR_OUT" | jqr -r '.[].text')
check "list(invariant): json .[].text equals the hardcoded canonical EXPECT (sort is correct)" \
	"json != EXPECT$(printf '\n')json:$(printf '\n')$INV_JSON_TEXTS" \
	"$( [ "$INV_JSON_TEXTS" = "$SORT_EXPECT_TEXTS" ] && echo 0 || echo 1 )"
run 1 "INBOX_FILE=$INBOX_SORT" sh "$LIST" --all --format md
# Anchor on the "**N.**" ordinal line; the NEXT line is that item's blockquote,
# stripped of "> " -> the item's text, in render order.
INV_MD_TEXTS=$(printf '%s\n' "$CUR_OUT" | awk '/^\*\*[0-9]+\.\*\*$/ { grab=1; next } grab { sub(/^> /, ""); print; grab=0 }')
check "list(invariant): md item sequence (by **N.** ordinal) equals the same EXPECT (render preserves order)" \
	"md != EXPECT$(printf '\n')md:$(printf '\n')$INV_MD_TEXTS" \
	"$( [ "$INV_MD_TEXTS" = "$SORT_EXPECT_TEXTS" ] && echo 0 || echo 1 )"
# The ordinals themselves render as a contiguous 1..N in that same order.
INV_ORDINALS=$(printf '%s\n' "$CUR_OUT" | grep -Eo '^\*\*[0-9]+\.\*\*' | grep -Eo '[0-9]+' | tr '\n' ',')
check "list(invariant): md ordinals are a contiguous 1..5 in render order" "got: $INV_ORDINALS" \
	"$( [ "$INV_ORDINALS" = "1,2,3,4,5," ] && echo 0 || echo 1 )"

# ===========================================================================
# Summary
# ===========================================================================
printf '\n== summary ==\n'
printf 'ran %s checks, %s failed\n' "$TESTS_RUN" "$TESTS_FAIL"
[ "$TESTS_FAIL" -eq 0 ] || exit 1
printf 'ALL TESTS PASSED\n'
exit 0
