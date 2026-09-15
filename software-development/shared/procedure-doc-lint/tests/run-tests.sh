#!/usr/bin/env sh
#
# run-tests.sh — self-contained, zero-dependency POSIX test harness for
#                doc-lint.sh.
#
# WHY a hand-rolled harness (not bats): mirrors the procedure-git-ops /
# procedure-inbox-capture test harnesses exactly (same shape, same
# assertion helpers) — the whole point of this suite is "runs on any
# machine with no dependencies", which a bats-core requirement would
# contradict.
#
# WHAT THIS PROVES: doc-lint.sh is pure text processing (no git, no
# network, no mutation) — so, unlike procedure-git-ops, there is no
# separate "stub vs. real" split. Every case here runs the REAL script
# against a REAL fixture file and is a full, real proof of behavior, not
# a stand-in for one.
#
# Usage:  sh run-tests.sh              # run all tests
#         VERBOSE=1 sh run-tests.sh
#         (also runs green under dash: dash run-tests.sh)
#
# Exit 0 = all passed, 1 = one or more failed.
#
set -eu

TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
SCRIPTS_DIR=$(cd "$TESTS_DIR/../scripts" && pwd)
FIXTURES_DIR="$TESTS_DIR/fixtures"
DOCLINT="$SCRIPTS_DIR/doc-lint.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/doc-lint-tests.XXXXXX")
# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Runner primitives
# ---------------------------------------------------------------------------
TESTS_RUN=0
TESTS_FAIL=0
CUR_OUT=""
CUR_ERR=""
CUR_RC=0

# run <cmd> [args...] — runs <cmd>, captures stdout, stderr, exit code.
run() {
	set +e
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
	else fail "$1" "stdout missing: $2"; fi
}

stdout_lacks() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if printf '%s\n' "$CUR_OUT" | grep -Fq -- "$2"; then fail "$1" "stdout unexpectedly contains: $2"
	else pass "$1"; fi
}

stderr_has() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if printf '%s\n' "$CUR_ERR" | grep -Fq -- "$2"; then pass "$1"
	else fail "$1" "stderr missing: $2"; fi
}

section() { printf '\n== %s ==\n' "$1"; }

# ===========================================================================
# Usage / argument errors
# ===========================================================================
section "usage / argument errors"

run sh "$DOCLINT" -h
expect_rc "help: -h -> exit 0" 0
stdout_has "help: shows usage" "Usage:"

run sh "$DOCLINT"
expect_rc "missing --file: -> exit 2" 2
stderr_has "missing --file: diagnostic" "--file is required"

run sh "$DOCLINT" --bogus
expect_rc "unknown option: -> exit 2" 2

run sh "$DOCLINT" --file "$FIXTURES_DIR/clean.md" extra-arg
expect_rc "unexpected positional arg: -> exit 2" 2

run sh "$DOCLINT" --file "$WORK/does-not-exist.md"
expect_rc "nonexistent file: -> exit 2" 2
stderr_has "nonexistent file: diagnostic" "does not exist"

# ===========================================================================
# Clean pass
# ===========================================================================
section "clean fixture — zero violations"

run sh "$DOCLINT" --file "$FIXTURES_DIR/clean.md"
expect_rc "clean: -> exit 0" 0
stdout_has "clean: DOCLINT_VIOLATIONS=0" "DOCLINT_VIOLATIONS=0"
stdout_has "clean: DOCLINT_BARE_FENCES=0" "DOCLINT_BARE_FENCES=0"
stdout_has "clean: DOCLINT_TICKET_IDS=0" "DOCLINT_TICKET_IDS=0"
stdout_has "clean: DOCLINT_LOCAL_PATHS=0" "DOCLINT_LOCAL_PATHS=0"
stdout_has "clean: DOCLINT_SINGLE_ITEM_LISTS=0" "DOCLINT_SINGLE_ITEM_LISTS=0"
stdout_lacks "clean: no itemized violation line (file:line:)" "clean.md:"

# ===========================================================================
# Bare fence
# ===========================================================================
section "bare-fence fixture"

run sh "$DOCLINT" --file "$FIXTURES_DIR/bare-fence.md"
expect_rc "bare-fence: -> exit 1" 1
stdout_has "bare-fence: DOCLINT_VIOLATIONS=1" "DOCLINT_VIOLATIONS=1"
stdout_has "bare-fence: DOCLINT_BARE_FENCES=1" "DOCLINT_BARE_FENCES=1"
stdout_has "bare-fence: itemized at line 5" "bare-fence.md:5: BARE_FENCE"
stdout_lacks "bare-fence: the tagged fence is NOT flagged" "bare-fence.md:11: BARE_FENCE"

# ===========================================================================
# Ticket ID
# ===========================================================================
section "ticket-id fixture"

run sh "$DOCLINT" --file "$FIXTURES_DIR/ticket-id.md"
expect_rc "ticket-id: -> exit 1" 1
stdout_has "ticket-id: itemized at line 3" "ticket-id.md:3: TICKET_ID"
stdout_lacks "ticket-id: report never echoes the matched identifier" "PROJ-4821"

# ===========================================================================
# Ticket-ID allowlist — false positives on common technical-standard
# prefixes must lint clean; a real ticket-ID-shaped string with an
# unlisted prefix must still trigger, even on the same line as an
# allowlisted mention.
# ===========================================================================
section "ticket-id-allowlist-clean fixture — known standard prefixes never flagged"

run sh "$DOCLINT" --file "$FIXTURES_DIR/ticket-id-allowlist-clean.md"
expect_rc "ticket-id-allowlist-clean: -> exit 0" 0
stdout_has "ticket-id-allowlist-clean: DOCLINT_VIOLATIONS=0" "DOCLINT_VIOLATIONS=0"
stdout_has "ticket-id-allowlist-clean: DOCLINT_TICKET_IDS=0" "DOCLINT_TICKET_IDS=0"

section "ticket-id-not-allowlisted fixture — real ticket IDs still trigger"

run sh "$DOCLINT" --file "$FIXTURES_DIR/ticket-id-not-allowlisted.md"
expect_rc "ticket-id-not-allowlisted: -> exit 1" 1
stdout_has "ticket-id-not-allowlisted: DOCLINT_TICKET_IDS=3" "DOCLINT_TICKET_IDS=3"
stdout_has "ticket-id-not-allowlisted: COTE-1543 flagged at line 3" "ticket-id-not-allowlisted.md:3: TICKET_ID"
stdout_has "ticket-id-not-allowlisted: PROJ-99 flagged at line 5" "ticket-id-not-allowlisted.md:5: TICKET_ID"
stdout_lacks "ticket-id-not-allowlisted: pure standard-mention line 8 NOT flagged" "ticket-id-not-allowlisted.md:8: TICKET_ID"
stdout_has "ticket-id-not-allowlisted: mixed real-ID+standard line 11 still flagged" "ticket-id-not-allowlisted.md:11: TICKET_ID"

section "ticket-id-allowlist — --allow-ticket-prefixes suppresses a domain-specific prefix for this run only"

printf '# Doc\n\nSee FOOBAR-42, a made-up domain standard, not a ticket.\n' >"$WORK/custom-allowlist.md"

run sh "$DOCLINT" --file "$WORK/custom-allowlist.md"
expect_rc "custom-allowlist: without the flag -> exit 1 (flagged)" 1

run sh "$DOCLINT" --file "$WORK/custom-allowlist.md" --allow-ticket-prefixes "FOOBAR"
expect_rc "custom-allowlist: with --allow-ticket-prefixes FOOBAR -> exit 0" 0
stdout_has "custom-allowlist: DOCLINT_TICKET_IDS=0 once allowed" "DOCLINT_TICKET_IDS=0"

run sh "$DOCLINT" --file "$FIXTURES_DIR/ticket-id-not-allowlisted.md" --allow-ticket-prefixes "FOOBAR"
expect_rc "custom-allowlist: an unrelated extra prefix does not suppress a real ticket ID -> exit 1" 1

# ===========================================================================
# Local path
# ===========================================================================
section "local-path fixture"

run sh "$DOCLINT" --file "$FIXTURES_DIR/local-path.md"
expect_rc "local-path: -> exit 1" 1
stdout_has "local-path: DOCLINT_LOCAL_PATHS=3" "DOCLINT_LOCAL_PATHS=3"
stdout_has "local-path: /Users/ flagged at line 3" "local-path.md:3: LOCAL_PATH"
stdout_has "local-path: /home/ flagged at line 5" "local-path.md:5: LOCAL_PATH"
stdout_has "local-path: C:\\Users\\ flagged at line 7" "local-path.md:7: LOCAL_PATH"
stdout_lacks "local-path: report never echoes the matched path" "/Users/example"

# ===========================================================================
# Single-item list
# ===========================================================================
section "single-item-list fixture"

run sh "$DOCLINT" --file "$FIXTURES_DIR/single-item-list.md"
expect_rc "single-item-list: -> exit 1" 1
stdout_has "single-item-list: DOCLINT_SINGLE_ITEM_LISTS=2" "DOCLINT_SINGLE_ITEM_LISTS=2"
stdout_has "single-item-list: bulleted lone item at line 5" "single-item-list.md:5: SINGLE_ITEM_LIST"
stdout_has "single-item-list: numbered lone item at line 9" "single-item-list.md:9: SINGLE_ITEM_LIST"

# ===========================================================================
# Adjacent single-item lists — two genuinely distinct single-item lists,
# each pair back-to-back with NO blank line between its two items: a bullet
# marker change (lines 10-11), then a bullet-to-ordered transition (lines
# 13-14). Under CommonMark a marker-character or ordered/unordered
# transition starts a NEW list, so all four lines are independently
# single-item lists and must all be flagged — not merged into two
# two-item blocks that would wrongly report zero violations.
# ===========================================================================
section "adjacent-single-item-lists fixture — marker change starts a new block"

run sh "$DOCLINT" --file "$FIXTURES_DIR/adjacent-single-item-lists.md"
expect_rc "adjacent-single-item-lists: -> exit 1" 1
stdout_has "adjacent-single-item-lists: DOCLINT_SINGLE_ITEM_LISTS=4" "DOCLINT_SINGLE_ITEM_LISTS=4"
stdout_has "adjacent-single-item-lists: bullet-to-bullet, first item at line 10" "adjacent-single-item-lists.md:10: SINGLE_ITEM_LIST"
stdout_has "adjacent-single-item-lists: bullet-to-bullet, second item at line 11" "adjacent-single-item-lists.md:11: SINGLE_ITEM_LIST"
stdout_has "adjacent-single-item-lists: bullet-to-ordered, first item at line 13" "adjacent-single-item-lists.md:13: SINGLE_ITEM_LIST"
stdout_has "adjacent-single-item-lists: bullet-to-ordered, second item at line 14" "adjacent-single-item-lists.md:14: SINGLE_ITEM_LIST"

section "ad-hoc — bullet-marker change with no blank line: '- item A' / '* item B'"
printf '# Doc\n\n- item A\n* item B\n' >"$WORK/marker-change-bullet.md"
run sh "$DOCLINT" --file "$WORK/marker-change-bullet.md"
expect_rc "marker-change-bullet: -> exit 1" 1
stdout_has "marker-change-bullet: DOCLINT_SINGLE_ITEM_LISTS=2" "DOCLINT_SINGLE_ITEM_LISTS=2"
stdout_has "marker-change-bullet: '- item A' flagged at line 3" "marker-change-bullet.md:3: SINGLE_ITEM_LIST"
stdout_has "marker-change-bullet: '* item B' flagged at line 4" "marker-change-bullet.md:4: SINGLE_ITEM_LIST"

section "ad-hoc — bullet-to-ordered transition with no blank line: '- item A' / '1. item B'"
printf '# Doc\n\n- item A\n1. item B\n' >"$WORK/marker-change-ordered.md"
run sh "$DOCLINT" --file "$WORK/marker-change-ordered.md"
expect_rc "marker-change-ordered: -> exit 1" 1
stdout_has "marker-change-ordered: DOCLINT_SINGLE_ITEM_LISTS=2" "DOCLINT_SINGLE_ITEM_LISTS=2"
stdout_has "marker-change-ordered: '- item A' flagged at line 3" "marker-change-ordered.md:3: SINGLE_ITEM_LIST"
stdout_has "marker-change-ordered: '1. item B' flagged at line 4" "marker-change-ordered.md:4: SINGLE_ITEM_LIST"

section "ad-hoc — should-NOT-regress: a consistent-marker multi-item list is never flagged"
printf '# Doc\n\n- a\n- b\n- c\n' >"$WORK/consistent-multi-item.md"
run sh "$DOCLINT" --file "$WORK/consistent-multi-item.md"
expect_rc "consistent-multi-item: -> exit 0" 0
stdout_has "consistent-multi-item: DOCLINT_SINGLE_ITEM_LISTS=0" "DOCLINT_SINGLE_ITEM_LISTS=0"

# ===========================================================================
# Ad-hoc structural cases not worth a whole fixture file
# ===========================================================================
section "ad-hoc — a real multi-item list is never flagged"
printf '# Doc\n\nIntro.\n\n- one\n- two\n- three\n' >"$WORK/multi-item.md"
run sh "$DOCLINT" --file "$WORK/multi-item.md"
expect_rc "multi-item: -> exit 0" 0
stdout_has "multi-item: DOCLINT_SINGLE_ITEM_LISTS=0" "DOCLINT_SINGLE_ITEM_LISTS=0"

section "ad-hoc — a loose (blank-line-separated) multi-item list is never flagged"
printf '# Doc\n\nIntro.\n\n- one\n\n- two\n\n- three\n' >"$WORK/loose-list.md"
run sh "$DOCLINT" --file "$WORK/loose-list.md"
expect_rc "loose-list: -> exit 0" 0
stdout_has "loose-list: DOCLINT_SINGLE_ITEM_LISTS=0" "DOCLINT_SINGLE_ITEM_LISTS=0"

section "ad-hoc — a single-item list at end of file (no trailing hard break) is still flagged"
printf '# Doc\n\nIntro.\n\n- only one\n' >"$WORK/eof-list.md"
run sh "$DOCLINT" --file "$WORK/eof-list.md"
expect_rc "eof-list: -> exit 1" 1
stdout_has "eof-list: DOCLINT_SINGLE_ITEM_LISTS=1" "DOCLINT_SINGLE_ITEM_LISTS=1"

section "ad-hoc — an untagged fence with only whitespace after the backticks is still bare"
# shellcheck disable=SC2016  # the literal ``` here is a markdown fence, not command substitution
printf '# Doc\n\n```   \necho hi\n```\n' >"$WORK/whitespace-fence.md"
run sh "$DOCLINT" --file "$WORK/whitespace-fence.md"
expect_rc "whitespace-fence: -> exit 1" 1
stdout_has "whitespace-fence: DOCLINT_BARE_FENCES=1" "DOCLINT_BARE_FENCES=1"

section "ad-hoc — a language tag with leading whitespace after the backticks is NOT bare"
# shellcheck disable=SC2016  # the literal ``` here is a markdown fence, not command substitution
printf '# Doc\n\n``` bash\necho hi\n```\n' >"$WORK/spaced-tag.md"
run sh "$DOCLINT" --file "$WORK/spaced-tag.md"
expect_rc "spaced-tag: -> exit 0" 0
stdout_has "spaced-tag: DOCLINT_BARE_FENCES=0" "DOCLINT_BARE_FENCES=0"

section "ad-hoc — an indented fence (inside a list item) is still checked"
# shellcheck disable=SC2016  # the literal ``` here is a markdown fence, not command substitution
printf '# Doc\n\n- a step:\n\n  ```\n  echo hi\n  ```\n' >"$WORK/indented-fence.md"
run sh "$DOCLINT" --file "$WORK/indented-fence.md"
expect_rc "indented-fence: -> exit 1" 1
stdout_has "indented-fence: DOCLINT_BARE_FENCES=1" "DOCLINT_BARE_FENCES=1"

section "ad-hoc — a fenced code block containing list-like lines is not linted as a list"
# shellcheck disable=SC2016  # the literal ``` here is a markdown fence, not command substitution
printf '# Doc\n\n```text\n- one\n```\n' >"$WORK/fenced-list-like.md"
run sh "$DOCLINT" --file "$WORK/fenced-list-like.md"
expect_rc "fenced-list-like: -> exit 0" 0
stdout_has "fenced-list-like: DOCLINT_SINGLE_ITEM_LISTS=0" "DOCLINT_SINGLE_ITEM_LISTS=0"

section "ad-hoc — multiple violation kinds on the same file are all reported"
# shellcheck disable=SC2016  # the literal ``` here is a markdown fence, not command substitution
printf '# Doc\n\nSee PROJ-9 at /Users/x/y.\n\n```\ncode\n```\n\n- lone\n' >"$WORK/combo.md"
run sh "$DOCLINT" --file "$WORK/combo.md"
expect_rc "combo: -> exit 1" 1
stdout_has "combo: DOCLINT_VIOLATIONS=4" "DOCLINT_VIOLATIONS=4"
stdout_has "combo: ticket id counted" "DOCLINT_TICKET_IDS=1"
stdout_has "combo: local path counted" "DOCLINT_LOCAL_PATHS=1"
stdout_has "combo: bare fence counted" "DOCLINT_BARE_FENCES=1"
stdout_has "combo: single-item list counted" "DOCLINT_SINGLE_ITEM_LISTS=1"

# ===========================================================================
# Summary
# ===========================================================================
printf '\n== summary ==\n'
printf 'ran %s checks, %s failed\n' "$TESTS_RUN" "$TESTS_FAIL"
[ "$TESTS_FAIL" -eq 0 ] || exit 1
printf 'ALL TESTS PASSED\n'
exit 0
