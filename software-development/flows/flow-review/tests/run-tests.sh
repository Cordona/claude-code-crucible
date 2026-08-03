#!/usr/bin/env sh
#
# run-tests.sh — self-contained, zero-dependency POSIX test harness for the
#                flow-review durable-artifact script suite (review-create.sh,
#                review-add-round.sh, review-update-status.sh, render-md.sh).
#
# WHY a hand-rolled harness (not bats), modeled on flow-inbox's
# tests/run-tests.sh: the scripts under test claim to run with no dependency
# beyond `jq` + coreutils, so the test harness must make the same claim.
#
# What it does:
#   * Builds an isolated PATH "toolbox" of symlinks to only the real tools the
#     scripts need, MINUS `jq` — jq lives in its OWN dir that a test opts
#     into via the `run`/`render_run` helpers' first argument, so "jq absent"
#     is exercised for real (leaving that dir off PATH).
#   * Every run of a script under test uses a fresh --repo-root / --json-file
#     under an isolated WORK dir, with an isolated HOME/TMPDIR — the real
#     filesystem is never touched.
#   * Structural/value assertions (jq filters over the produced JSON) use the
#     REAL system jq (via $ORIG_PATH, the `jqr` helper), never the isolated
#     toolbox — jq is the assertion tool here, not the thing under test.
#   * Everything runs under `env -i` and is cleaned up on exit.
#
# Usage:  sh run-tests.sh              # run all tests
#         VERBOSE=1 sh run-tests.sh
#
# Exit 0 = all passed, 1 = one or more failed.
#
set -eu

# ---------------------------------------------------------------------------
# Locations
# ---------------------------------------------------------------------------
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
SCRIPTS_DIR=$(cd "$TESTS_DIR/../scripts" && pwd)
CREATE="$SCRIPTS_DIR/review-create.sh"
ADD_ROUND="$SCRIPTS_DIR/review-add-round.sh"
UPDATE_STATUS="$SCRIPTS_DIR/review-update-status.sh"
RENDER="$SCRIPTS_DIR/render-md.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/flow-review-tests.XXXXXX")
TOOLBOX="$WORK/toolbox"   # real tools (jq is NEVER here)
JQDIR="$WORK/jqbin"       # jq only (a test opts in via `run`'s first arg)
mkdir -p "$TOOLBOX" "$JQDIR" "$WORK/home"

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

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
for t in sh mktemp mkdir rm mv dirname date cat basename chmod; do
	link_tool "$t"
done
jq_real=$(PATH="$ORIG_PATH" command -v jq 2>/dev/null || true)
[ -n "$jq_real" ] || { printf 'FATAL: jq not found on the real PATH\n' >&2; exit 1; }
ln -s "$jq_real" "$JQDIR/jq"

TODAY=$(date -u +%Y-%m-%d)
YEAR=${TODAY%%-*}
_REST=${TODAY#*-}
MONTH=${_REST%%-*}
DAY=${_REST#*-}

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
#   with an isolated HOME/TMPDIR. Leading VAR=VALUE arguments are passed
#   straight to `env`. Captures stdout, stderr, exit code.
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

# render_run <with_jq:0|1> <stdin_file> [render-md args...]
#   render-md.sh reads JSON on stdin, so `run` (which never redirects stdin)
#   can't drive it. Raw stdout is kept in a file so byte-exact golden
#   comparisons (cmp) aren't defeated by command-substitution's newline strip.
render_run() {
	rr_jq=$1; rr_input=$2; shift 2
	rr_path="$TOOLBOX"
	[ "$rr_jq" = "1" ] && rr_path="$JQDIR:$TOOLBOX"
	set +e
	env -i HOME="$WORK/home" PATH="$rr_path" TMPDIR="$WORK" \
		sh "$RENDER" "$@" <"$rr_input" >"$WORK/render-out" 2>"$WORK/render-err"
	CUR_RC=$?
	set -e
	CUR_OUT=$(cat "$WORK/render-out"); CUR_ERR=$(cat "$WORK/render-err")
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

stdout_is() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if [ "$CUR_OUT" = "$2" ]; then pass "$1"
	else fail "$1" "expected stdout exactly '$2', got '$CUR_OUT'"; fi
}

section() { printf '\n== %s ==\n' "$1"; }

# jqr FILTER [FILE] — run the REAL system jq (never the isolated toolbox).
# Assertions are the harness's own logic, not the thing under test.
jqr() { env PATH="$ORIG_PATH" jq "$@"; }

# assert_golden NAME EXPECTED_FILE — the last render_run's raw stdout must be
# BYTE-IDENTICAL to EXPECTED_FILE (single trailing newline included).
assert_golden() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if cmp -s "$2" "$WORK/render-out"; then pass "$1"
	else fail "$1" "byte mismatch vs golden; got:$(printf '\n')$(cat "$WORK/render-out")"; fi
}

# review_json_path OUT — extracts the path from a `REVIEW_JSON=<path>` stdout
# line produced by review-create.sh / review-add-round.sh.
review_json_path() { printf '%s\n' "$1" | sed -n 's/^REVIEW_JSON=//p'; }

# finding_of FILE ID — the one finding object with the given id, canonicalized
# (compact, sorted keys) for stable string/deep-equality comparison.
finding_of() { jqr -cS --arg id "$2" '.findings[] | select(.id == $id)' "$1"; }

# rwx_to_octal_digit RWX — converts one "rwx"-style permission triplet to its
# octal digit, via `case` (not `&&`/`||` chaining, which would let a
# non-matching final case become the whole statement's exit status under
# `set -e`). Same helper as flow-inbox/tests/run-tests.sh's perm_octal.
rwx_to_octal_digit() {
	grp=$1
	val=0
	case "$grp" in r??) val=$((val + 4)) ;; esac
	case "$grp" in ?w?) val=$((val + 2)) ;; esac
	case "$grp" in ??x|??s|??t) val=$((val + 1)) ;; esac
	printf '%s' "$val"
}

# mode_of FILE — the file's permission bits as a 3-digit octal string (e.g.
# "644"), via `ls -ld` (never the isolated toolbox — `ls` isn't one of the
# tools the scripts under test call, so it has no place in TOOLBOX; this is
# an assertion tool, same rationale as jqr). Portable across BSD (macOS) and
# GNU `ls` with no branching on `stat`'s GNU-vs-BSD flag syntax (GNU:
# -c '%a'; BSD: -f '%Lp') — the exact hazard flow-inbox/tests/run-tests.sh's
# own perm_octal was built to avoid; this mirrors that technique.
mode_of() {
	# shellcheck disable=SC2012  # `ls -ld` is deliberate here, not `find` — it
	# avoids branching on GNU vs BSD `stat` flag syntax (see the comment above).
	modestr=$(env PATH="$ORIG_PATH" ls -ld "$1" | awk '{print $1}')
	owner=$(printf '%s' "$modestr" | cut -c2-4)
	group=$(printf '%s' "$modestr" | cut -c5-7)
	other=$(printf '%s' "$modestr" | cut -c8-10)
	printf '%s%s%s' "$(rwx_to_octal_digit "$owner")" "$(rwx_to_octal_digit "$group")" "$(rwx_to_octal_digit "$other")"
}

# ===========================================================================
# review-create.sh — usage / --help / unknown args
# ===========================================================================
section "review-create.sh — usage / --help / unknown args"

run 1 sh "$CREATE" -h
expect_rc "create(usage): -h -> exit 0" 0
stdout_has "create(usage): help text" "Usage:"

run 1 sh "$CREATE" --bogus-flag
expect_rc "create(unknown option): -> exit 2" 2
stderr_has "create(unknown option): diagnostic" "unknown option"

REPO_HELP="$WORK/repo-help"; mkdir -p "$REPO_HELP"
FIELDS_MINIMAL="$WORK/fields-minimal.json"
cat >"$FIELDS_MINIMAL" <<'EOF'
{"repo": "minimal-repo", "reviewers": ["kotlin-reviewer"], "findings": []}
EOF
run 1 sh "$CREATE" --repo-root "$REPO_HELP" --slug ok-slug --fields-file "$FIELDS_MINIMAL" extra-positional-arg
expect_rc "create(extra positional arg): -> exit 2" 2
stderr_has "create(extra positional arg): diagnostic" "unexpected argument"

run 0 "$CREATE" --repo-root "$REPO_HELP" --slug ok-slug-nojq --fields-file "$FIELDS_MINIMAL"
expect_rc "create(no-jq): -> exit 1" 1
stderr_has "create(no-jq): diagnostic" "jq is not installed"

# ===========================================================================
# review-create.sh — required-option guards / nonexistent --repo-root
# (TEST-008)
# ===========================================================================
section "review-create.sh — required-option guards / nonexistent --repo-root"

run 1 sh "$CREATE" --slug ok-slug --fields-file "$FIELDS_MINIMAL"
expect_rc "create(missing --repo-root): -> exit 2" 2
stderr_has "create(missing --repo-root): diagnostic" "--repo-root is required"

run 1 sh "$CREATE" --repo-root "$REPO_HELP" --fields-file "$FIELDS_MINIMAL"
expect_rc "create(missing --slug): -> exit 2" 2
stderr_has "create(missing --slug): diagnostic" "--slug is required"

run 1 sh "$CREATE" --repo-root "$REPO_HELP" --slug ok-slug
expect_rc "create(missing --fields-file): -> exit 2" 2
stderr_has "create(missing --fields-file): diagnostic" "--fields-file is required"

run 1 sh "$CREATE" --repo-root "$WORK/does-not-exist-dir" --slug ok-slug --fields-file "$FIELDS_MINIMAL"
expect_rc "create(nonexistent --repo-root): -> exit 2" 2
stderr_has "create(nonexistent --repo-root): diagnostic" "does not exist or is not a directory"

# TEST-009: --fields-file pointing at a nonexistent path.
run 1 sh "$CREATE" --repo-root "$REPO_HELP" --slug ok-slug --fields-file "$WORK/does-not-exist-fields.json"
expect_rc "create(nonexistent --fields-file): -> exit 2" 2
stderr_has "create(nonexistent --fields-file): diagnostic" "does not exist or is not readable"

# ===========================================================================
# review-create.sh — invalid --slug / empty reviewers / bad finding id /
# missing required finding field (all usage errors -> exit 2)
# ===========================================================================
section "review-create.sh — usage-level validation errors"

REPO_ERR="$WORK/repo-errcases"; mkdir -p "$REPO_ERR"

run 1 sh "$CREATE" --repo-root "$REPO_ERR" --slug "Not_Valid_Slug" --fields-file "$FIELDS_MINIMAL"
expect_rc "create(invalid --slug): -> exit 2" 2
stderr_has "create(invalid --slug): diagnostic" "invalid --slug"

FIELDS_EMPTY_REVIEWERS="$WORK/fields-empty-reviewers.json"
cat >"$FIELDS_EMPTY_REVIEWERS" <<'EOF'
{"repo": "x", "reviewers": [], "findings": []}
EOF
run 1 sh "$CREATE" --repo-root "$REPO_ERR" --slug empty-reviewers --fields-file "$FIELDS_EMPTY_REVIEWERS"
expect_rc "create(empty reviewers): -> exit 2" 2
stderr_has "create(empty reviewers): diagnostic" "failed validation"

FIELDS_BAD_ID="$WORK/fields-bad-id.json"
cat >"$FIELDS_BAD_ID" <<'EOF'
{
  "repo": "x", "reviewers": ["r1"],
  "findings": [
    {"id": "sec-1", "reviewer": "r1", "severity": "HIGH", "category": "c",
     "locations": ["f.kt:1"], "problem": "p", "fix": "f"}
  ]
}
EOF
run 1 sh "$CREATE" --repo-root "$REPO_ERR" --slug bad-id --fields-file "$FIELDS_BAD_ID"
expect_rc "create(invalid finding id pattern): -> exit 2" 2
stderr_has "create(invalid finding id pattern): diagnostic" "failed validation"

FIELDS_MISSING_FIELD="$WORK/fields-missing-field.json"
cat >"$FIELDS_MISSING_FIELD" <<'EOF'
{
  "repo": "x", "reviewers": ["r1"],
  "findings": [
    {"id": "SEC-001", "reviewer": "r1", "severity": "HIGH", "category": "c",
     "locations": ["f.kt:1"], "problem": "p"}
  ]
}
EOF
run 1 sh "$CREATE" --repo-root "$REPO_ERR" --slug missing-field --fields-file "$FIELDS_MISSING_FIELD"
expect_rc "create(missing required finding field 'fix'): -> exit 2" 2
stderr_has "create(missing required finding field 'fix'): diagnostic" "failed validation"

# ===========================================================================
# review-create.sh — creation with 2 findings (HIGH + LOW): schema-valid
# output, caller-supplied status/tracked_status/first_seen IGNORED, mechanical
# summary/verdict, REVIEW_JSON=<path> printed on stdout and nothing else.
# ===========================================================================
section "review-create.sh — creation, override-ignored, mechanical verdict"

REPO_MAIN="$WORK/repo-main"; mkdir -p "$REPO_MAIN"
ABS_REPO_MAIN=$(cd "$REPO_MAIN" && pwd)
FIELDS_R1="$WORK/fields-r1.json"
cat >"$FIELDS_R1" <<'EOF'
{
  "repo": "demo-repo",
  "reviewers": ["kotlin-reviewer", "lens-security-reviewer"],
  "findings": [
    {
      "id": "SEC-001",
      "reviewer": "lens-security-reviewer",
      "severity": "HIGH",
      "category": "input-validation",
      "locations": ["src/main/kotlin/Foo.kt:10"],
      "problem": "jobId not validated as UUID",
      "fix": "validate against a UUID regex",
      "status": "RESOLVED",
      "tracked_status": "APPROVED",
      "first_seen": "2000-01-01"
    },
    {
      "id": "CLEAN-002",
      "reviewer": "lens-clean-code-reviewer",
      "severity": "LOW",
      "category": "naming",
      "locations": ["src/main/kotlin/Bar.kt:5"],
      "problem": "parameter named data conveys nothing",
      "fix": "rename to jobInput"
    }
  ]
}
EOF

run 1 sh "$CREATE" --repo-root "$REPO_MAIN" --slug demo-repo --fields-file "$FIELDS_R1"
expect_rc "create(main): -> exit 0" 0

EXPECTED_JSON="$ABS_REPO_MAIN/.crucible/docs/reviews/$YEAR/$MONTH/$DAY/demo-repo.json"
stdout_is "create(main): stdout is exactly REVIEW_JSON=<path>, nothing else" "REVIEW_JSON=$EXPECTED_JSON"

TESTS_RUN=$((TESTS_RUN + 1))
if [ -f "$EXPECTED_JSON" ]; then pass "create(main): artifact file exists at the expected path"
else fail "create(main): artifact file exists at the expected path" "not found: $EXPECTED_JSON"; fi

TESTS_RUN=$((TESTS_RUN + 1))
if [ "$(mode_of "$EXPECTED_JSON")" = "644" ]; then
	pass "create(main): artifact file written with mode 644 (not 600)"
else
	fail "create(main): artifact file written with mode 644 (not 600)" "got mode $(mode_of "$EXPECTED_JSON")"
fi

check "create(main): SEC-001 status forced to NEW (caller's RESOLVED ignored)" "expected NEW" \
	"$( [ "$(jqr -r '.findings[] | select(.id=="SEC-001") | .status' "$EXPECTED_JSON")" = "NEW" ] && echo 0 || echo 1 )"
check "create(main): SEC-001 tracked_status forced to PENDING (caller's APPROVED ignored)" "expected PENDING" \
	"$( [ "$(jqr -r '.findings[] | select(.id=="SEC-001") | .tracked_status' "$EXPECTED_JSON")" = "PENDING" ] && echo 0 || echo 1 )"
check "create(main): SEC-001 first_seen forced to created date (caller's 2000-01-01 ignored)" "expected $TODAY" \
	"$( [ "$(jqr -r '.findings[] | select(.id=="SEC-001") | .first_seen' "$EXPECTED_JSON")" = "$TODAY" ] && echo 0 || echo 1 )"
check "create(main): CLEAN-002 (no caller status given) also defaults to NEW/PENDING/today" "mismatch" \
	"$( jqr -e --arg t "$TODAY" '.findings[] | select(.id=="CLEAN-002") | .status=="NEW" and .tracked_status=="PENDING" and .first_seen==$t' "$EXPECTED_JSON" >/dev/null 2>&1 && echo 0 || echo 1 )"

check "create(main): summary.open.high == 1" "mismatch" \
	"$( [ "$(jqr -r '.summary.open.high' "$EXPECTED_JSON")" = "1" ] && echo 0 || echo 1 )"
check "create(main): summary.open.low == 1" "mismatch" \
	"$( [ "$(jqr -r '.summary.open.low' "$EXPECTED_JSON")" = "1" ] && echo 0 || echo 1 )"
check "create(main): summary.new == 2" "mismatch" \
	"$( [ "$(jqr -r '.summary.new' "$EXPECTED_JSON")" = "2" ] && echo 0 || echo 1 )"
check "create(main): overall_verdict == CHANGES_REQUIRED (HIGH open)" "mismatch" \
	"$( [ "$(jqr -r '.overall_verdict' "$EXPECTED_JSON")" = "CHANGES_REQUIRED" ] && echo 0 || echo 1 )"
check "create(main): document validates against additionalProperties:false top-level shape" "unexpected top-level key" \
	"$( jqr -e '(keys | sort) == (["created","findings","id","last_updated","overall_verdict","repo","rounds","schema_version","summary"] | sort)' "$EXPECTED_JSON" >/dev/null 2>&1 && echo 0 || echo 1 )"

# ---------------------------------------------------------------------------
# Re-running create against an existing target file: exit 1, refuses to
# overwrite, original untouched.
# ---------------------------------------------------------------------------
SNAPSHOT_BEFORE="$WORK/demo-repo-before-rerun.json"
cp "$EXPECTED_JSON" "$SNAPSHOT_BEFORE"

run 1 sh "$CREATE" --repo-root "$REPO_MAIN" --slug demo-repo --fields-file "$FIELDS_R1"
expect_rc "create(re-run, existing target): -> exit 1" 1
stderr_has "create(re-run, existing target): diagnostic" "refusing to overwrite"
TESTS_RUN=$((TESTS_RUN + 1))
if cmp -s "$SNAPSHOT_BEFORE" "$EXPECTED_JSON"; then pass "create(re-run, existing target): original file byte-identical (untouched)"
else fail "create(re-run, existing target): original file byte-identical (untouched)" "$(cmp "$SNAPSHOT_BEFORE" "$EXPECTED_JSON" 2>&1)"; fi

# ===========================================================================
# review-create.sh — optional spec_ref is included when given (TEST-003)
# ===========================================================================
section "review-create.sh — optional spec_ref conditional inclusion"

REPO_SPECREF="$WORK/repo-specref"; mkdir -p "$REPO_SPECREF"
FIELDS_SPECREF="$WORK/fields-specref.json"
cat >"$FIELDS_SPECREF" <<'EOF'
{
  "repo": "specref-repo",
  "spec_ref": ".crucible/docs/specs/2026/07/29/demo-spec.json",
  "reviewers": ["kotlin-reviewer"],
  "findings": []
}
EOF

run 1 sh "$CREATE" --repo-root "$REPO_SPECREF" --slug specref-repo --fields-file "$FIELDS_SPECREF"
expect_rc "create(spec_ref): -> exit 0" 0
SPECREF_JSON=$(review_json_path "$CUR_OUT")

check "create(spec_ref): top-level spec_ref key present with the given value" "mismatch" \
	"$( [ "$(jqr -r '.spec_ref' "$SPECREF_JSON")" = ".crucible/docs/specs/2026/07/29/demo-spec.json" ] && echo 0 || echo 1 )"

# ===========================================================================
# review-create.sh — stray-key stripping on finding reconstruction (TEST-004)
# ===========================================================================
section "review-create.sh — stray-key stripping"

REPO_STRAYKEY="$WORK/repo-straykey"; mkdir -p "$REPO_STRAYKEY"
FIELDS_STRAYKEY="$WORK/fields-straykey.json"
cat >"$FIELDS_STRAYKEY" <<'EOF'
{
  "repo": "straykey-repo",
  "reviewers": ["r1"],
  "findings": [
    { "id": "STR-001", "reviewer": "r1", "severity": "LOW", "category": "c",
      "locations": ["f.kt:1"], "problem": "p", "fix": "f",
      "bogusKey": "must not survive reconstruction" }
  ]
}
EOF

run 1 sh "$CREATE" --repo-root "$REPO_STRAYKEY" --slug straykey-repo --fields-file "$FIELDS_STRAYKEY"
expect_rc "create(stray key): -> exit 0" 0
STRAYKEY_JSON=$(review_json_path "$CUR_OUT")

check "create(stray key): STR-001 has no bogusKey (finding reconstructed field-by-field)" "bogusKey leaked through" \
	"$( jqr -e '.findings[] | select(.id=="STR-001") | has("bogusKey") | not' "$STRAYKEY_JSON" >/dev/null 2>&1 && echo 0 || echo 1 )"

# ===========================================================================
# review-add-round.sh — usage / --help / unknown args / jq-absent
# ===========================================================================
section "review-add-round.sh — usage / --help / unknown args / jq-absent"

run 1 sh "$ADD_ROUND" -h
expect_rc "add-round(usage): -h -> exit 0" 0
stdout_has "add-round(usage): help text" "Usage:"

run 1 sh "$ADD_ROUND" --bogus-flag
expect_rc "add-round(unknown option): -> exit 2" 2
stderr_has "add-round(unknown option): diagnostic" "unknown option"

FIELDS_ROUND2_MINIMAL="$WORK/fields-round2-minimal.json"
cat >"$FIELDS_ROUND2_MINIMAL" <<'EOF'
{"round": 2, "reviewers": ["kotlin-reviewer"], "findings": []}
EOF
run 1 sh "$ADD_ROUND" --json-file "$EXPECTED_JSON" --fields-file "$FIELDS_ROUND2_MINIMAL" extra-arg
expect_rc "add-round(extra positional arg): -> exit 2" 2
stderr_has "add-round(extra positional arg): diagnostic" "unexpected argument"

NOT_AN_ARTIFACT="$WORK/not-an-artifact.json"
printf '{"just": "some object"}' >"$NOT_AN_ARTIFACT"
run 1 sh "$ADD_ROUND" --json-file "$NOT_AN_ARTIFACT" --fields-file "$FIELDS_ROUND2_MINIMAL"
expect_rc "add-round(--json-file not a review artifact): -> exit 1" 1
stderr_has "add-round(--json-file not a review artifact): diagnostic" "not a valid review artifact"

run 0 sh "$ADD_ROUND" --json-file "$EXPECTED_JSON" --fields-file "$FIELDS_ROUND2_MINIMAL"
expect_rc "add-round(no-jq): -> exit 1" 1
stderr_has "add-round(no-jq): diagnostic" "jq is not installed"

# ===========================================================================
# review-add-round.sh — required-option guards (TEST-008)
# ===========================================================================
section "review-add-round.sh — required-option guards"

run 1 sh "$ADD_ROUND" --fields-file "$FIELDS_ROUND2_MINIMAL"
expect_rc "add-round(missing --json-file): -> exit 2" 2
stderr_has "add-round(missing --json-file): diagnostic" "--json-file is required"

run 1 sh "$ADD_ROUND" --json-file "$EXPECTED_JSON"
expect_rc "add-round(missing --fields-file): -> exit 2" 2
stderr_has "add-round(missing --fields-file): diagnostic" "--fields-file is required"

# TEST-009: --json-file / --fields-file each pointing at a nonexistent path.
run 1 sh "$ADD_ROUND" --json-file "$WORK/does-not-exist-review.json" --fields-file "$FIELDS_ROUND2_MINIMAL"
expect_rc "add-round(nonexistent --json-file): -> exit 1" 1
stderr_has "add-round(nonexistent --json-file): diagnostic" "does not exist or is not readable"

run 1 sh "$ADD_ROUND" --json-file "$EXPECTED_JSON" --fields-file "$WORK/does-not-exist-fields.json"
expect_rc "add-round(nonexistent --fields-file): -> exit 2" 2
stderr_has "add-round(nonexistent --fields-file): diagnostic" "does not exist or is not readable"

# ===========================================================================
# review-add-round.sh — round 2: partial-update merge (CLEAN-002), full
# resolution of an existing finding (SEC-001), brand-new finding append
# (MED-001); recomputed verdict is APPROVED_WITH_FOLLOWUPS (MEDIUM+LOW open).
# ===========================================================================
section "review-add-round.sh — merge / append / fresh recompute"

CLEAN_002_BEFORE=$(finding_of "$EXPECTED_JSON" "CLEAN-002")

FIELDS_ROUND2="$WORK/fields-round2.json"
cat >"$FIELDS_ROUND2" <<'EOF'
{
  "round": 2,
  "reviewers": ["kotlin-reviewer"],
  "findings": [
    { "id": "SEC-001", "status": "RESOLVED", "tracked_status": "APPROVED" },
    { "id": "CLEAN-002", "tracked_status": "IN_PROGRESS" },
    {
      "id": "MED-001",
      "reviewer": "lens-performance-reviewer",
      "tracked_status": "PENDING",
      "severity": "MEDIUM",
      "category": "n-plus-one",
      "locations": ["src/main/kotlin/Baz.kt:1"],
      "problem": "n+1 query in the batch loader",
      "fix": "batch-load in one query"
    }
  ]
}
EOF

run 1 sh "$ADD_ROUND" --json-file "$EXPECTED_JSON" --fields-file "$FIELDS_ROUND2"
expect_rc "add-round(round 2): -> exit 0" 0
stdout_is "add-round(round 2): stdout is exactly REVIEW_JSON=<path>" "REVIEW_JSON=$EXPECTED_JSON"

check "add-round(round 2): SEC-001 fully resolved (status)" "mismatch" \
	"$( [ "$(jqr -r '.findings[] | select(.id=="SEC-001") | .status' "$EXPECTED_JSON")" = "RESOLVED" ] && echo 0 || echo 1 )"
check "add-round(round 2): SEC-001 fully resolved (tracked_status)" "mismatch" \
	"$( [ "$(jqr -r '.findings[] | select(.id=="SEC-001") | .tracked_status' "$EXPECTED_JSON")" = "APPROVED" ] && echo 0 || echo 1 )"

# CLEAN-002: only tracked_status was given in the update entry — every other
# key (id/reviewer/status/severity/category/locations/first_seen/problem/fix)
# must be byte-identical to what it was BEFORE round 2, and there must still
# be exactly ONE CLEAN-002 finding (never duplicated).
CLEAN_002_AFTER=$(finding_of "$EXPECTED_JSON" "CLEAN-002")
check "add-round(round 2): CLEAN-002 tracked_status flipped to IN_PROGRESS" "mismatch" \
	"$( [ "$(jqr -r '.findings[] | select(.id=="CLEAN-002") | .tracked_status' "$EXPECTED_JSON")" = "IN_PROGRESS" ] && echo 0 || echo 1 )"
check "add-round(round 2): CLEAN-002 partial update touches ONLY tracked_status (every other field unchanged)" "before != after apart from tracked_status" \
	"$( [ "$(printf '%s' "$CLEAN_002_BEFORE" | jqr 'del(.tracked_status)')" = "$(printf '%s' "$CLEAN_002_AFTER" | jqr 'del(.tracked_status)')" ] && echo 0 || echo 1 )"
check "add-round(round 2): CLEAN-002 was never duplicated (exactly one match)" "expected exactly 1" \
	"$( [ "$(jqr '[.findings[] | select(.id=="CLEAN-002")] | length' "$EXPECTED_JSON")" -eq 1 ] && echo 0 || echo 1 )"

check "add-round(round 2): MED-001 appended as a brand-new finding" "expected exactly 1" \
	"$( [ "$(jqr '[.findings[] | select(.id=="MED-001")] | length' "$EXPECTED_JSON")" -eq 1 ] && echo 0 || echo 1 )"
check "add-round(round 2): MED-001 defaults status to NEW" "mismatch" \
	"$( [ "$(jqr -r '.findings[] | select(.id=="MED-001") | .status' "$EXPECTED_JSON")" = "NEW" ] && echo 0 || echo 1 )"
check "add-round(round 2): MED-001 defaults first_seen to this round's date" "expected $TODAY" \
	"$( [ "$(jqr -r '.findings[] | select(.id=="MED-001") | .first_seen' "$EXPECTED_JSON")" = "$TODAY" ] && echo 0 || echo 1 )"

check "add-round(round 2): findings[] now has exactly 3 entries (no dupes, one append)" "expected 3" \
	"$( [ "$(jqr '.findings | length' "$EXPECTED_JSON")" -eq 3 ] && echo 0 || echo 1 )"
check "add-round(round 2): rounds[] now has exactly 2 entries" "expected 2" \
	"$( [ "$(jqr '.rounds | length' "$EXPECTED_JSON")" -eq 2 ] && echo 0 || echo 1 )"

# TEST-001: the appended rounds[] entry, deep-equality checked (not just
# array length) — round/generated/reviewers all correct.
EXPECTED_ROUND2_ENTRY=$(jqr -cS -n --arg d "$TODAY" '{round:2, generated:$d, reviewers:["kotlin-reviewer"]}')
check "add-round(round 2): appended rounds[] entry deep-equals {round:2, generated:today, reviewers:[kotlin-reviewer]}" "mismatch" \
	"$( [ "$(jqr -cS '.rounds[1]' "$EXPECTED_JSON")" = "$EXPECTED_ROUND2_ENTRY" ] && echo 0 || echo 1 )"

check "add-round(round 2): overall_verdict recomputed FRESH as APPROVED_WITH_FOLLOWUPS (MEDIUM+LOW open)" "mismatch" \
	"$( [ "$(jqr -r '.overall_verdict' "$EXPECTED_JSON")" = "APPROVED_WITH_FOLLOWUPS" ] && echo 0 || echo 1 )"
check "add-round(round 2): summary.open.high == 0 (SEC-001 resolved)" "mismatch" \
	"$( [ "$(jqr -r '.summary.open.high' "$EXPECTED_JSON")" = "0" ] && echo 0 || echo 1 )"
check "add-round(round 2): summary.open.medium == 1 (MED-001)" "mismatch" \
	"$( [ "$(jqr -r '.summary.open.medium' "$EXPECTED_JSON")" = "1" ] && echo 0 || echo 1 )"
check "add-round(round 2): summary.resolved == 1" "mismatch" \
	"$( [ "$(jqr -r '.summary.resolved' "$EXPECTED_JSON")" = "1" ] && echo 0 || echo 1 )"
check "add-round(round 2): last_updated == today" "mismatch" \
	"$( [ "$(jqr -r '.last_updated' "$EXPECTED_JSON")" = "$TODAY" ] && echo 0 || echo 1 )"

TESTS_RUN=$((TESTS_RUN + 1))
if [ "$(mode_of "$EXPECTED_JSON")" = "644" ]; then
	pass "add-round(round 2): rewritten artifact file still mode 644 (not 600)"
else
	fail "add-round(round 2): rewritten artifact file still mode 644 (not 600)" "got mode $(mode_of "$EXPECTED_JSON")"
fi

TESTS_RUN=$((TESTS_RUN + 1))
if [ -z "$(find "$(dirname "$EXPECTED_JSON")" -maxdepth 1 -name '.tmp.*' -print 2>/dev/null)" ]; then
	pass "add-round(round 2): atomic rewrite left no stray temp file on success"
else
	fail "add-round(round 2): atomic rewrite left no stray temp file on success" "a .tmp.* file is present"
fi

# ---------------------------------------------------------------------------
# Duplicate round number -> exit 1, no changes made.
# ---------------------------------------------------------------------------
SNAPSHOT_BEFORE_DUP="$WORK/demo-repo-before-dup-round.json"
cp "$EXPECTED_JSON" "$SNAPSHOT_BEFORE_DUP"

run 1 sh "$ADD_ROUND" --json-file "$EXPECTED_JSON" --fields-file "$FIELDS_ROUND2"
expect_rc "add-round(duplicate round 2): -> exit 1" 1
stderr_has "add-round(duplicate round 2): diagnostic" "already exists"
TESTS_RUN=$((TESTS_RUN + 1))
if cmp -s "$SNAPSHOT_BEFORE_DUP" "$EXPECTED_JSON"; then pass "add-round(duplicate round 2): file byte-identical (no changes made)"
else fail "add-round(duplicate round 2): file byte-identical (no changes made)" "$(cmp "$SNAPSHOT_BEFORE_DUP" "$EXPECTED_JSON" 2>&1)"; fi
TESTS_RUN=$((TESTS_RUN + 1))
if [ -z "$(find "$(dirname "$EXPECTED_JSON")" -maxdepth 1 -name '.tmp.*' -print 2>/dev/null)" ]; then
	pass "add-round(duplicate round 2): no stray temp file left behind on failure"
else
	fail "add-round(duplicate round 2): no stray temp file left behind on failure" "a .tmp.* file is present"
fi

# ===========================================================================
# review-add-round.sh — own fields-file/entry validation negative paths
# (TEST-002), against a dedicated isolated fixture so they never interact
# with the main flow's evolving EXPECTED_JSON / round numbering.
# ===========================================================================
section "review-add-round.sh — own validation negative paths"

REPO_VALIDATION="$WORK/repo-validation"; mkdir -p "$REPO_VALIDATION"
FIELDS_VALIDATION_R1="$WORK/fields-validation-r1.json"
cat >"$FIELDS_VALIDATION_R1" <<'EOF'
{
  "repo": "validation-fixture",
  "reviewers": ["r1"],
  "findings": [
    { "id": "VAL-001", "reviewer": "r1", "severity": "HIGH", "category": "c",
      "locations": ["f.kt:1"], "problem": "p", "fix": "f" }
  ]
}
EOF
run 1 sh "$CREATE" --repo-root "$REPO_VALIDATION" --slug validation-fixture --fields-file "$FIELDS_VALIDATION_R1"
expect_rc "add-round(validation fixture): create -> exit 0" 0
VALIDATION_JSON=$(review_json_path "$CUR_OUT")

FIELDS_ROUND_ZERO="$WORK/fields-round-zero.json"
cat >"$FIELDS_ROUND_ZERO" <<'EOF'
{"round": 0, "reviewers": ["r1"], "findings": []}
EOF
run 1 sh "$ADD_ROUND" --json-file "$VALIDATION_JSON" --fields-file "$FIELDS_ROUND_ZERO"
expect_rc "add-round(round 0): -> exit 2" 2
stderr_has "add-round(round 0): diagnostic" "failed validation"

FIELDS_ROUND_NONINT="$WORK/fields-round-nonint.json"
cat >"$FIELDS_ROUND_NONINT" <<'EOF'
{"round": 1.5, "reviewers": ["r1"], "findings": []}
EOF
run 1 sh "$ADD_ROUND" --json-file "$VALIDATION_JSON" --fields-file "$FIELDS_ROUND_NONINT"
expect_rc "add-round(non-integer round): -> exit 2" 2
stderr_has "add-round(non-integer round): diagnostic" "failed validation"

FIELDS_NEW_MISSING_FIELD="$WORK/fields-new-missing-field.json"
cat >"$FIELDS_NEW_MISSING_FIELD" <<'EOF'
{
  "round": 5, "reviewers": ["r1"],
  "findings": [
    { "id": "NEW-777", "reviewer": "r1", "tracked_status": "PENDING",
      "severity": "LOW", "category": "c", "locations": ["f.kt:1"], "problem": "p" }
  ]
}
EOF
run 1 sh "$ADD_ROUND" --json-file "$VALIDATION_JSON" --fields-file "$FIELDS_NEW_MISSING_FIELD"
expect_rc "add-round(new finding missing required field 'fix'): -> exit 2" 2
stderr_has "add-round(new finding missing required field 'fix'): diagnostic" "invalid finding entry"

FIELDS_UPDATE_BAD_SEVERITY="$WORK/fields-update-bad-severity.json"
cat >"$FIELDS_UPDATE_BAD_SEVERITY" <<'EOF'
{"round": 10, "reviewers": ["r1"], "findings": [ { "id": "VAL-001", "severity": "NOT_A_SEVERITY" } ]}
EOF
run 1 sh "$ADD_ROUND" --json-file "$VALIDATION_JSON" --fields-file "$FIELDS_UPDATE_BAD_SEVERITY"
expect_rc "add-round(update entry invalid severity): -> exit 2" 2
stderr_has "add-round(update entry invalid severity): diagnostic" "invalid finding entry"

FIELDS_UPDATE_BAD_STATUS="$WORK/fields-update-bad-status.json"
cat >"$FIELDS_UPDATE_BAD_STATUS" <<'EOF'
{"round": 11, "reviewers": ["r1"], "findings": [ { "id": "VAL-001", "status": "NOT_A_STATUS" } ]}
EOF
run 1 sh "$ADD_ROUND" --json-file "$VALIDATION_JSON" --fields-file "$FIELDS_UPDATE_BAD_STATUS"
expect_rc "add-round(update entry invalid status): -> exit 2" 2
stderr_has "add-round(update entry invalid status): diagnostic" "invalid finding entry"

# ---------------------------------------------------------------------------
# The HIGH-severity gap this fix closed: an UPDATE-branch entry giving a
# malformed reviewer/fix/addressed_in_round was previously accepted
# (unvalidated) and would have silently corrupted the matched finding.
# ---------------------------------------------------------------------------
FIELDS_UPDATE_BAD_REVIEWER="$WORK/fields-update-bad-reviewer.json"
cat >"$FIELDS_UPDATE_BAD_REVIEWER" <<'EOF'
{"round": 6, "reviewers": ["r1"], "findings": [ { "id": "VAL-001", "reviewer": "" } ]}
EOF
run 1 sh "$ADD_ROUND" --json-file "$VALIDATION_JSON" --fields-file "$FIELDS_UPDATE_BAD_REVIEWER"
expect_rc "add-round(update entry invalid reviewer, empty string): -> exit 2" 2
stderr_has "add-round(update entry invalid reviewer, empty string): diagnostic" "invalid finding entry"

FIELDS_UPDATE_BAD_FIX="$WORK/fields-update-bad-fix.json"
cat >"$FIELDS_UPDATE_BAD_FIX" <<'EOF'
{"round": 7, "reviewers": ["r1"], "findings": [ { "id": "VAL-001", "fix": "" } ]}
EOF
run 1 sh "$ADD_ROUND" --json-file "$VALIDATION_JSON" --fields-file "$FIELDS_UPDATE_BAD_FIX"
expect_rc "add-round(update entry invalid fix, empty string): -> exit 2" 2
stderr_has "add-round(update entry invalid fix, empty string): diagnostic" "invalid finding entry"

FIELDS_UPDATE_BAD_ROUND_REF="$WORK/fields-update-bad-round-ref.json"
cat >"$FIELDS_UPDATE_BAD_ROUND_REF" <<'EOF'
{"round": 8, "reviewers": ["r1"], "findings": [ { "id": "VAL-001", "addressed_in_round": 0 } ]}
EOF
run 1 sh "$ADD_ROUND" --json-file "$VALIDATION_JSON" --fields-file "$FIELDS_UPDATE_BAD_ROUND_REF"
expect_rc "add-round(update entry invalid addressed_in_round, 0): -> exit 2" 2
stderr_has "add-round(update entry invalid addressed_in_round, 0): diagnostic" "invalid finding entry"

# ---------------------------------------------------------------------------
# Regression test for the HIGH-severity gap on the NEW-finding path (distinct
# from the update-branch coverage above): a brand-new finding entry (id NOT
# already present in the artifact, so it takes the "new" branch of the
# validator's if/else) giving an invalid status must be rejected, not
# silently accepted with the bogus value written to disk.
# ---------------------------------------------------------------------------
FIELDS_NEW_BAD_STATUS="$WORK/fields-new-bad-status.json"
cat >"$FIELDS_NEW_BAD_STATUS" <<'EOF'
{
  "round": 12, "reviewers": ["r1"],
  "findings": [
    { "id": "NEW-888", "reviewer": "r1", "tracked_status": "PENDING",
      "severity": "LOW", "category": "c", "locations": ["f.kt:1"], "problem": "p", "fix": "f",
      "status": "BOGUS" }
  ]
}
EOF
run 1 sh "$ADD_ROUND" --json-file "$VALIDATION_JSON" --fields-file "$FIELDS_NEW_BAD_STATUS"
expect_rc "add-round(NEW finding entry invalid status): -> exit 2" 2
stderr_has "add-round(NEW finding entry invalid status): diagnostic" "invalid finding entry"

# ===========================================================================
# review-add-round.sh — pick_known strips a stray key on BOTH the new-finding
# and the update-entry path (TEST-004)
# ===========================================================================
section "review-add-round.sh — pick_known stray-key stripping"

FIELDS_PICK_KNOWN="$WORK/fields-pick-known.json"
cat >"$FIELDS_PICK_KNOWN" <<'EOF'
{
  "round": 9, "reviewers": ["r1"],
  "findings": [
    { "id": "STR-777", "reviewer": "r1", "tracked_status": "PENDING", "severity": "LOW",
      "category": "c", "locations": ["f.kt:1"], "problem": "p", "fix": "f",
      "bogusKey": "must not survive" },
    { "id": "VAL-001", "tracked_status": "IN_PROGRESS", "bogusKey": "must not survive either" }
  ]
}
EOF
run 1 sh "$ADD_ROUND" --json-file "$VALIDATION_JSON" --fields-file "$FIELDS_PICK_KNOWN"
expect_rc "add-round(pick_known): -> exit 0" 0

check "add-round(pick_known): brand-new STR-777 has no bogusKey" "bogusKey leaked through" \
	"$( jqr -e '.findings[] | select(.id=="STR-777") | has("bogusKey") | not' "$VALIDATION_JSON" >/dev/null 2>&1 && echo 0 || echo 1 )"
check "add-round(pick_known): updated VAL-001 has no bogusKey" "bogusKey leaked through" \
	"$( jqr -e '.findings[] | select(.id=="VAL-001") | has("bogusKey") | not' "$VALIDATION_JSON" >/dev/null 2>&1 && echo 0 || echo 1 )"

# ===========================================================================
# review-add-round.sh — first_seen immutability (UPDATE) and format
# validation (NEW): the HIGH-severity gap where an UPDATE entry could
# overwrite a finding's frozen-at-creation first_seen with an arbitrary
# caller-supplied value, and a NEW finding's first_seen was never
# format-checked.
# ===========================================================================
section "review-add-round.sh — first_seen immutability / format validation"

VAL_001_FIRST_SEEN_BEFORE=$(jqr -r '.findings[] | select(.id=="VAL-001") | .first_seen' "$VALIDATION_JSON")

# ---------------------------------------------------------------------------
# UPDATE entry supplying a DIFFERENT first_seen than the finding currently
# has: the value is silently ignored (excluded from the merge entirely, not
# rejected) — first_seen is frozen at creation, so ANY caller-supplied value
# on an update is inert. tracked_status is flipped in the same entry to
# confirm the rest of the update still applies normally alongside the ignore.
# ---------------------------------------------------------------------------
FIELDS_UPDATE_DIFFERENT_FIRST_SEEN="$WORK/fields-update-different-first-seen.json"
cat >"$FIELDS_UPDATE_DIFFERENT_FIRST_SEEN" <<'EOF'
{"round": 13, "reviewers": ["r1"], "findings": [ { "id": "VAL-001", "first_seen": "2000-01-01", "tracked_status": "APPROVED" } ]}
EOF
run 1 sh "$ADD_ROUND" --json-file "$VALIDATION_JSON" --fields-file "$FIELDS_UPDATE_DIFFERENT_FIRST_SEEN"
expect_rc "add-round(update entry with different first_seen): -> exit 0" 0
check "add-round(update entry with different first_seen): VAL-001.first_seen unchanged (caller's 2000-01-01 ignored)" "expected $VAL_001_FIRST_SEEN_BEFORE" \
	"$( [ "$(jqr -r '.findings[] | select(.id=="VAL-001") | .first_seen' "$VALIDATION_JSON")" = "$VAL_001_FIRST_SEEN_BEFORE" ] && echo 0 || echo 1 )"
check "add-round(update entry with different first_seen): tracked_status still applied (rest of the update went through)" "mismatch" \
	"$( [ "$(jqr -r '.findings[] | select(.id=="VAL-001") | .tracked_status' "$VALIDATION_JSON")" = "APPROVED" ] && echo 0 || echo 1 )"

# ---------------------------------------------------------------------------
# UPDATE entry supplying a first_seen EQUAL to the existing value (a no-op):
# must not be unexpectedly rejected. Relevant because this fix took the
# "always ignore" route (exclude the key from the merge) rather than "reject
# any given value" — a same-value update must succeed exactly like any other.
# ---------------------------------------------------------------------------
FIELDS_UPDATE_SAME_FIRST_SEEN="$WORK/fields-update-same-first-seen.json"
cat >"$FIELDS_UPDATE_SAME_FIRST_SEEN" <<EOF
{"round": 14, "reviewers": ["r1"], "findings": [ { "id": "VAL-001", "first_seen": "$VAL_001_FIRST_SEEN_BEFORE", "tracked_status": "PENDING" } ]}
EOF
run 1 sh "$ADD_ROUND" --json-file "$VALIDATION_JSON" --fields-file "$FIELDS_UPDATE_SAME_FIRST_SEEN"
expect_rc "add-round(update entry with first_seen equal to existing value): -> exit 0 (not rejected)" 0
check "add-round(update entry with first_seen equal to existing value): VAL-001.first_seen still unchanged" "expected $VAL_001_FIRST_SEEN_BEFORE" \
	"$( [ "$(jqr -r '.findings[] | select(.id=="VAL-001") | .first_seen' "$VALIDATION_JSON")" = "$VAL_001_FIRST_SEEN_BEFORE" ] && echo 0 || echo 1 )"

# ---------------------------------------------------------------------------
# NEW-finding entry with a malformed first_seen -> exit 2, rejected before any
# write (format validation via is_iso_date).
# ---------------------------------------------------------------------------
FIELDS_NEW_BAD_FIRST_SEEN="$WORK/fields-new-bad-first-seen.json"
cat >"$FIELDS_NEW_BAD_FIRST_SEEN" <<'EOF'
{
  "round": 15, "reviewers": ["r1"],
  "findings": [
    { "id": "NEW-333", "reviewer": "r1", "tracked_status": "PENDING",
      "severity": "LOW", "category": "c", "locations": ["f.kt:1"], "problem": "p", "fix": "f",
      "first_seen": "not-a-date" }
  ]
}
EOF
run 1 sh "$ADD_ROUND" --json-file "$VALIDATION_JSON" --fields-file "$FIELDS_NEW_BAD_FIRST_SEEN"
expect_rc "add-round(NEW finding entry malformed first_seen): -> exit 2" 2
stderr_has "add-round(NEW finding entry malformed first_seen): diagnostic" "invalid finding entry"

# ---------------------------------------------------------------------------
# NEW-finding entry with a valid, explicit first_seen -> accepted, and the
# EXACT given value (not today's date) is what gets persisted.
# ---------------------------------------------------------------------------
FIELDS_NEW_EXPLICIT_FIRST_SEEN="$WORK/fields-new-explicit-first-seen.json"
cat >"$FIELDS_NEW_EXPLICIT_FIRST_SEEN" <<'EOF'
{
  "round": 16, "reviewers": ["r1"],
  "findings": [
    { "id": "NEW-444", "reviewer": "r1", "tracked_status": "PENDING",
      "severity": "LOW", "category": "c", "locations": ["f.kt:1"], "problem": "p", "fix": "f",
      "first_seen": "2020-06-15" }
  ]
}
EOF
run 1 sh "$ADD_ROUND" --json-file "$VALIDATION_JSON" --fields-file "$FIELDS_NEW_EXPLICIT_FIRST_SEEN"
expect_rc "add-round(NEW finding entry explicit valid first_seen): -> exit 0" 0
check "add-round(NEW finding entry explicit valid first_seen): NEW-444.first_seen == 2020-06-15 (exact given value persisted, not today)" "mismatch" \
	"$( [ "$(jqr -r '.findings[] | select(.id=="NEW-444") | .first_seen' "$VALIDATION_JSON")" = "2020-06-15" ] && echo 0 || echo 1 )"

# ---------------------------------------------------------------------------
# NEW-finding entry with first_seen OMITTED -> defaults to this round's date
# (today), same default behavior already covered for review-create.sh /
# round 2's MED-001 above.
# ---------------------------------------------------------------------------
FIELDS_NEW_OMITTED_FIRST_SEEN="$WORK/fields-new-omitted-first-seen.json"
cat >"$FIELDS_NEW_OMITTED_FIRST_SEEN" <<'EOF'
{
  "round": 17, "reviewers": ["r1"],
  "findings": [
    { "id": "NEW-555", "reviewer": "r1", "tracked_status": "PENDING",
      "severity": "LOW", "category": "c", "locations": ["f.kt:1"], "problem": "p", "fix": "f" }
  ]
}
EOF
run 1 sh "$ADD_ROUND" --json-file "$VALIDATION_JSON" --fields-file "$FIELDS_NEW_OMITTED_FIRST_SEEN"
expect_rc "add-round(NEW finding entry first_seen omitted): -> exit 0" 0
check "add-round(NEW finding entry first_seen omitted): NEW-555.first_seen defaults to today ($TODAY)" "mismatch" \
	"$( [ "$(jqr -r '.findings[] | select(.id=="NEW-555") | .first_seen' "$VALIDATION_JSON")" = "$TODAY" ] && echo 0 || echo 1 )"

# ===========================================================================
# review-update-status.sh — usage / --help / unknown args / jq-absent
# ===========================================================================
section "review-update-status.sh — usage / --help / unknown args / jq-absent"

run 1 sh "$UPDATE_STATUS" -h
expect_rc "update-status(usage): -h -> exit 0" 0
stdout_has "update-status(usage): help text" "Usage:"

run 1 sh "$UPDATE_STATUS" --bogus-flag
expect_rc "update-status(unknown option): -> exit 2" 2
stderr_has "update-status(unknown option): diagnostic" "unknown option"

run 1 sh "$UPDATE_STATUS" --json-file "$EXPECTED_JSON" --id CLEAN-002 --status RESOLVED extra-arg
expect_rc "update-status(extra positional arg): -> exit 2" 2
stderr_has "update-status(extra positional arg): diagnostic" "unexpected argument"

run 0 sh "$UPDATE_STATUS" --json-file "$EXPECTED_JSON" --id CLEAN-002 --status RESOLVED
expect_rc "update-status(no-jq): -> exit 1" 1
stderr_has "update-status(no-jq): diagnostic" "jq is not installed"

# ===========================================================================
# review-update-status.sh — required-option guards (TEST-008)
# ===========================================================================
section "review-update-status.sh — required-option guards"

run 1 sh "$UPDATE_STATUS" --id CLEAN-002 --status RESOLVED
expect_rc "update-status(missing --json-file): -> exit 2" 2
stderr_has "update-status(missing --json-file): diagnostic" "--json-file is required"

run 1 sh "$UPDATE_STATUS" --json-file "$EXPECTED_JSON" --status RESOLVED
expect_rc "update-status(missing --id): -> exit 2" 2
stderr_has "update-status(missing --id): diagnostic" "--id is required"

# ===========================================================================
# review-update-status.sh — own --json-file guards: missing / not a review
# artifact (TEST-006)
# ===========================================================================
section "review-update-status.sh — own --json-file guards"

run 1 sh "$UPDATE_STATUS" --json-file "$WORK/does-not-exist.json" --id CLEAN-002 --status RESOLVED
expect_rc "update-status(missing --json-file path): -> exit 1" 1
stderr_has "update-status(missing --json-file path): diagnostic" "does not exist"

NOT_AN_ARTIFACT2="$WORK/not-an-artifact2.json"
printf '{"just": "some object"}' >"$NOT_AN_ARTIFACT2"
run 1 sh "$UPDATE_STATUS" --json-file "$NOT_AN_ARTIFACT2" --id CLEAN-002 --status RESOLVED
expect_rc "update-status(--json-file not a review artifact): -> exit 1" 1
stderr_has "update-status(--json-file not a review artifact): diagnostic" "not a valid review artifact"

# The [ ! -r ] branch: an existing, well-formed file that is unreadable.
# Skipped under root, where chmod 000 has no enforcement effect (same
# guarded pattern as flow-spec/tests/run-tests.sh).
UNREADABLE_ARTIFACT="$WORK/unreadable-artifact.json"
cp "$EXPECTED_JSON" "$UNREADABLE_ARTIFACT"
chmod 000 "$UNREADABLE_ARTIFACT"
if [ "$(id -u)" != "0" ]; then
	run 1 sh "$UPDATE_STATUS" --json-file "$UNREADABLE_ARTIFACT" --id CLEAN-002 --status RESOLVED
	expect_rc "update-status(--json-file unreadable): -> exit 1" 1
	stderr_has "update-status(--json-file unreadable): diagnostic" "does not exist or is not readable"
else
	printf '  skip update-status(--json-file unreadable): running as root, permissions unenforced\n'
fi
chmod 644 "$UNREADABLE_ARTIFACT"

# ===========================================================================
# review-update-status.sh — validation errors (all before any write)
# ===========================================================================
section "review-update-status.sh — validation errors"

run 1 sh "$UPDATE_STATUS" --json-file "$EXPECTED_JSON" --id NOPE-999
expect_rc "update-status(no field given): -> exit 2" 2
stderr_has "update-status(no field given): diagnostic" "at least one of"

run 1 sh "$UPDATE_STATUS" --json-file "$EXPECTED_JSON" --id CLEAN-002 --status BOGUS
expect_rc "update-status(invalid --status): -> exit 2" 2
stderr_has "update-status(invalid --status): diagnostic" "invalid --status"

run 1 sh "$UPDATE_STATUS" --json-file "$EXPECTED_JSON" --id CLEAN-002 --tracked-status BOGUS
expect_rc "update-status(invalid --tracked-status): -> exit 2" 2
stderr_has "update-status(invalid --tracked-status): diagnostic" "invalid --tracked-status"

run 1 sh "$UPDATE_STATUS" --json-file "$EXPECTED_JSON" --id CLEAN-002 --addressed-in-round 0
expect_rc "update-status(invalid --addressed-in-round, leading zero): -> exit 2" 2
stderr_has "update-status(invalid --addressed-in-round, leading zero): diagnostic" "invalid --addressed-in-round"

SNAPSHOT_BEFORE_NOMATCH="$WORK/demo-repo-before-nomatch.json"
cp "$EXPECTED_JSON" "$SNAPSHOT_BEFORE_NOMATCH"
run 1 sh "$UPDATE_STATUS" --json-file "$EXPECTED_JSON" --id NOPE-999 --status RESOLVED
expect_rc "update-status(nonexistent id): -> exit 1" 1
stderr_has "update-status(nonexistent id): diagnostic" "expected exactly one"
TESTS_RUN=$((TESTS_RUN + 1))
if cmp -s "$SNAPSHOT_BEFORE_NOMATCH" "$EXPECTED_JSON"; then pass "update-status(nonexistent id): file byte-identical (untouched)"
else fail "update-status(nonexistent id): file byte-identical (untouched)" "$(cmp "$SNAPSHOT_BEFORE_NOMATCH" "$EXPECTED_JSON" 2>&1)"; fi

# ===========================================================================
# review-update-status.sh — successful flips, only the given field(s) change,
# chained through to overall_verdict == APPROVED.
# ===========================================================================
section "review-update-status.sh — successful flips / chain to APPROVED"

SEC_001_BEFORE_FLIP=$(finding_of "$EXPECTED_JSON" "SEC-001")
MED_001_BEFORE_FLIP=$(finding_of "$EXPECTED_JSON" "MED-001")

# Flip 1: CLEAN-002 (LOW), --status only — tracked_status (IN_PROGRESS, from
# round 2) must be left untouched, and every OTHER finding must be untouched.
run 1 sh "$UPDATE_STATUS" --json-file "$EXPECTED_JSON" --id CLEAN-002 --status RESOLVED
expect_rc "update-status(flip CLEAN-002 status only): -> exit 0" 0
stdout_is "update-status(flip CLEAN-002 status only): stdout is exactly REVIEW_UPDATED=<id>" "REVIEW_UPDATED=CLEAN-002"

check "update-status(flip 1): CLEAN-002.status == RESOLVED" "mismatch" \
	"$( [ "$(jqr -r '.findings[] | select(.id=="CLEAN-002") | .status' "$EXPECTED_JSON")" = "RESOLVED" ] && echo 0 || echo 1 )"
check "update-status(flip 1): CLEAN-002.tracked_status left UNTOUCHED at IN_PROGRESS (only --status was given)" "mismatch" \
	"$( [ "$(jqr -r '.findings[] | select(.id=="CLEAN-002") | .tracked_status' "$EXPECTED_JSON")" = "IN_PROGRESS" ] && echo 0 || echo 1 )"
check "update-status(flip 1): SEC-001 entirely untouched" "SEC-001 changed" \
	"$( [ "$(finding_of "$EXPECTED_JSON" "SEC-001")" = "$SEC_001_BEFORE_FLIP" ] && echo 0 || echo 1 )"
check "update-status(flip 1): MED-001 entirely untouched" "MED-001 changed" \
	"$( [ "$(finding_of "$EXPECTED_JSON" "MED-001")" = "$MED_001_BEFORE_FLIP" ] && echo 0 || echo 1 )"
check "update-status(flip 1): overall_verdict still APPROVED_WITH_FOLLOWUPS (MED-001 still open)" "mismatch" \
	"$( [ "$(jqr -r '.overall_verdict' "$EXPECTED_JSON")" = "APPROVED_WITH_FOLLOWUPS" ] && echo 0 || echo 1 )"
check "update-status(flip 1): last_updated == today" "mismatch" \
	"$( [ "$(jqr -r '.last_updated' "$EXPECTED_JSON")" = "$TODAY" ] && echo 0 || echo 1 )"

TESTS_RUN=$((TESTS_RUN + 1))
if [ "$(mode_of "$EXPECTED_JSON")" = "644" ]; then
	pass "update-status(flip 1): rewritten artifact file still mode 644 (not 600)"
else
	fail "update-status(flip 1): rewritten artifact file still mode 644 (not 600)" "got mode $(mode_of "$EXPECTED_JSON")"
fi

# Flip 2: MED-001 (the last remaining open finding) -> status + tracked_status
# + addressed_in_round all together -> overall_verdict becomes APPROVED.
run 1 sh "$UPDATE_STATUS" --json-file "$EXPECTED_JSON" --id MED-001 --status RESOLVED --tracked-status APPROVED --addressed-in-round 2
expect_rc "update-status(flip MED-001, final): -> exit 0" 0

check "update-status(flip 2): MED-001.status == RESOLVED" "mismatch" \
	"$( [ "$(jqr -r '.findings[] | select(.id=="MED-001") | .status' "$EXPECTED_JSON")" = "RESOLVED" ] && echo 0 || echo 1 )"
check "update-status(flip 2): MED-001.tracked_status == APPROVED" "mismatch" \
	"$( [ "$(jqr -r '.findings[] | select(.id=="MED-001") | .tracked_status' "$EXPECTED_JSON")" = "APPROVED" ] && echo 0 || echo 1 )"
check "update-status(flip 2): MED-001.addressed_in_round == 2" "mismatch" \
	"$( [ "$(jqr -r '.findings[] | select(.id=="MED-001") | .addressed_in_round' "$EXPECTED_JSON")" = "2" ] && echo 0 || echo 1 )"
check "update-status(flip 2): overall_verdict recomputed FRESH as APPROVED (nothing left open)" "mismatch" \
	"$( [ "$(jqr -r '.overall_verdict' "$EXPECTED_JSON")" = "APPROVED" ] && echo 0 || echo 1 )"
check "update-status(flip 2): summary.resolved == 3, all open counts 0" "mismatch" \
	"$( jqr -e '.summary.resolved == 3 and .summary.open.critical == 0 and .summary.open.high == 0 and .summary.open.medium == 0 and .summary.open.low == 0' "$EXPECTED_JSON" >/dev/null 2>&1 && echo 0 || echo 1 )"

# ===========================================================================
# review-update-status.sh — ACK and REGRESSED statuses (TEST-005), against a
# dedicated isolated fixture (two findings: HIGH + MEDIUM).
# ===========================================================================
section "review-update-status.sh — ACK and REGRESSED"

REPO_ACKREG="$WORK/repo-ackreg"; mkdir -p "$REPO_ACKREG"
FIELDS_ACKREG="$WORK/fields-ackreg.json"
cat >"$FIELDS_ACKREG" <<'EOF'
{
  "repo": "ackreg-repo",
  "reviewers": ["r1"],
  "findings": [
    { "id": "ACK-001", "reviewer": "r1", "severity": "HIGH", "category": "c",
      "locations": ["f.kt:1"], "problem": "p1", "fix": "f1" },
    { "id": "REG-002", "reviewer": "r1", "severity": "MEDIUM", "category": "c",
      "locations": ["f.kt:2"], "problem": "p2", "fix": "f2" }
  ]
}
EOF
run 1 sh "$CREATE" --repo-root "$REPO_ACKREG" --slug ackreg-repo --fields-file "$FIELDS_ACKREG"
expect_rc "update-status(ackreg fixture): create -> exit 0" 0
ACKREG_JSON=$(review_json_path "$CUR_OUT")

# ACK-001 -> ACK: does NOT count as open (open_counts only tallies
# NEW/OPEN/REGRESSED), so open.high drops to 0; REG-002 (still NEW/MEDIUM)
# keeps the verdict at APPROVED_WITH_FOLLOWUPS.
run 1 sh "$UPDATE_STATUS" --json-file "$ACKREG_JSON" --id ACK-001 --status ACK
expect_rc "update-status(ACK-001 -> ACK): -> exit 0" 0
check "update-status(ACK-001 -> ACK): summary.ack == 1" "mismatch" \
	"$( [ "$(jqr -r '.summary.ack' "$ACKREG_JSON")" = "1" ] && echo 0 || echo 1 )"
check "update-status(ACK-001 -> ACK): summary.open.high == 0 (ACK not counted as open)" "mismatch" \
	"$( [ "$(jqr -r '.summary.open.high' "$ACKREG_JSON")" = "0" ] && echo 0 || echo 1 )"
check "update-status(ACK-001 -> ACK): overall_verdict still APPROVED_WITH_FOLLOWUPS (REG-002 still open)" "mismatch" \
	"$( [ "$(jqr -r '.overall_verdict' "$ACKREG_JSON")" = "APPROVED_WITH_FOLLOWUPS" ] && echo 0 || echo 1 )"

# Resolve REG-002 to reach a fully-closed baseline (open.medium -> 0).
run 1 sh "$UPDATE_STATUS" --json-file "$ACKREG_JSON" --id REG-002 --status RESOLVED
expect_rc "update-status(REG-002 -> RESOLVED): -> exit 0" 0
check "update-status(REG-002 -> RESOLVED): open.medium == 0, verdict APPROVED" "mismatch" \
	"$( jqr -e '.summary.open.medium == 0 and .overall_verdict == "APPROVED"' "$ACKREG_JSON" >/dev/null 2>&1 && echo 0 || echo 1 )"

# REG-002 -> REGRESSED: REGRESSED DOES count as open, so open.medium goes
# back to 1 and summary.resolved drops back to 0; ACK-001's ack count is
# untouched by this second finding's transition.
run 1 sh "$UPDATE_STATUS" --json-file "$ACKREG_JSON" --id REG-002 --status REGRESSED
expect_rc "update-status(REG-002 -> REGRESSED): -> exit 0" 0
check "update-status(REG-002 -> REGRESSED): summary.open.medium == 1 (REGRESSED counts as open)" "mismatch" \
	"$( [ "$(jqr -r '.summary.open.medium' "$ACKREG_JSON")" = "1" ] && echo 0 || echo 1 )"
check "update-status(REG-002 -> REGRESSED): summary.resolved == 0" "mismatch" \
	"$( [ "$(jqr -r '.summary.resolved' "$ACKREG_JSON")" = "0" ] && echo 0 || echo 1 )"
check "update-status(REG-002 -> REGRESSED): overall_verdict back to APPROVED_WITH_FOLLOWUPS" "mismatch" \
	"$( [ "$(jqr -r '.overall_verdict' "$ACKREG_JSON")" = "APPROVED_WITH_FOLLOWUPS" ] && echo 0 || echo 1 )"
check "update-status(REG-002 -> REGRESSED): summary.ack unaffected, still 1" "mismatch" \
	"$( [ "$(jqr -r '.summary.ack' "$ACKREG_JSON")" = "1" ] && echo 0 || echo 1 )"

# ===========================================================================
# render-md.sh — usage / --help / unknown args / jq-absent
# ===========================================================================
section "render-md.sh — usage / --help / unknown args / jq-absent"

run 1 sh "$RENDER" -h
expect_rc "render(usage): -h -> exit 0" 0
stdout_has "render(usage): help text" "Usage:"

run 1 sh "$RENDER" --bogus-flag
expect_rc "render(unknown option): -> exit 2" 2
stderr_has "render(unknown option): diagnostic" "unknown option"

printf '{}' >"$WORK/render-empty-obj.json"
run 1 sh "$RENDER" --summary extra-positional <"$WORK/render-empty-obj.json"
expect_rc "render(extra positional arg): -> exit 2" 2
stderr_has "render(extra positional arg): diagnostic" "unexpected argument"

render_run 0 "$WORK/render-empty-obj.json"
expect_rc "render(no-jq): -> exit 1" 1
stderr_has "render(no-jq): diagnostic" "jq is not installed"

# ===========================================================================
# render-md.sh — invalid input shapes
# ===========================================================================
section "render-md.sh — invalid input shapes"

printf 'not json at all' >"$WORK/render-notjson.json"
render_run 1 "$WORK/render-notjson.json"
expect_rc "render(non-JSON stdin): -> documented exit 1" 1
stderr_has "render(non-JSON stdin): diagnostic" "not valid JSON"

printf '[1,2,3]' >"$WORK/render-array.json"
render_run 1 "$WORK/render-array.json"
expect_rc "render(non-object JSON, an array): -> documented exit 1" 1
stderr_has "render(non-object JSON, an array): diagnostic" "must be one review-artifact JSON object"

printf '"just a string"' >"$WORK/render-scalar.json"
render_run 1 "$WORK/render-scalar.json"
expect_rc "render(non-object JSON, a scalar): -> documented exit 1" 1
stderr_has "render(non-object JSON, a scalar): diagnostic" "must be one review-artifact JSON object"

# ===========================================================================
# render-md.sh — full-mode golden, byte-exact against SKILL.md §4c's template
# ===========================================================================
section "render-md.sh — full-mode golden (with spec_ref, multi-location)"

RENDER_FULL="$WORK/render-full.json"
cat >"$RENDER_FULL" <<'EOF'
{
  "schema_version": "1.0",
  "id": "service-api",
  "repo": "service-api",
  "spec_ref": ".crucible/docs/specs/2026/07/29/cross-repo-job-submission.json",
  "created": "2026-07-29",
  "last_updated": "2026-07-29",
  "rounds": [
    { "round": 1, "generated": "2026-07-29", "reviewers": ["kotlin-reviewer", "lens-security-reviewer"] }
  ],
  "overall_verdict": "APPROVED_WITH_FOLLOWUPS",
  "summary": { "open": { "critical": 0, "high": 0, "medium": 1, "low": 1 }, "resolved": 0, "new": 2, "ack": 0 },
  "findings": [
    {
      "id": "SEC-001",
      "reviewer": "lens-security-reviewer",
      "status": "NEW",
      "tracked_status": "IN_PROGRESS",
      "severity": "MEDIUM",
      "category": "input-validation",
      "locations": ["src/main/kotlin/JobController.kt:42", "src/main/kotlin/JobController.kt:50"],
      "first_seen": "2026-07-29",
      "problem": "jobId path param not validated as UUID before the repository lookup",
      "fix": "validate against a UUID regex before querying; return 400 on mismatch"
    },
    {
      "id": "CLEAN-002",
      "reviewer": "lens-clean-code-reviewer",
      "status": "NEW",
      "tracked_status": "PENDING",
      "severity": "LOW",
      "category": "naming",
      "locations": ["src/main/kotlin/JobService.kt:18"],
      "first_seen": "2026-07-29",
      "problem": "parameter named data conveys nothing about its shape",
      "fix": "rename to jobInput, matching the spec's input field"
    }
  ]
}
EOF

render_run 1 "$RENDER_FULL"
expect_rc "render(full, with spec_ref): -> exit 0" 0
cat >"$WORK/render-full.golden" <<'EOF'
# Review: service-api

**Repo:** service-api
**Spec:** .crucible/docs/specs/2026/07/29/cross-repo-job-submission.json
**Started:** 2026-07-29 · **Last updated:** 2026-07-29
**Round:** 1 (of 3 max)
**Verdict:** APPROVED_WITH_FOLLOWUPS

## Round history
- Round 1: kotlin-reviewer, lens-security-reviewer

## Findings

### SEC-001 — MEDIUM
**Tracked status:** in_progress · **Finding status:** new
**Reviewer:** lens-security-reviewer
**File:** src/main/kotlin/JobController.kt:42

jobId path param not validated as UUID before the repository lookup
→ Fix: validate against a UUID regex before querying; return 400 on mismatch

### CLEAN-002 — LOW
**Tracked status:** pending · **Finding status:** new
**Reviewer:** lens-clean-code-reviewer
**File:** src/main/kotlin/JobService.kt:18

parameter named data conveys nothing about its shape
→ Fix: rename to jobInput, matching the spec's input field
EOF
assert_golden "render(full, with spec_ref): byte-exact against §4c template" "$WORK/render-full.golden"

# ---------------------------------------------------------------------------
# Same document minus spec_ref: the **Spec:** line must be ABSENT ENTIRELY,
# not blank.
# ---------------------------------------------------------------------------
RENDER_NO_SPEC="$WORK/render-no-spec.json"
jqr 'del(.spec_ref)' "$RENDER_FULL" >"$RENDER_NO_SPEC"
render_run 1 "$RENDER_NO_SPEC"
expect_rc "render(full, no spec_ref): -> exit 0" 0
cat >"$WORK/render-no-spec.golden" <<'EOF'
# Review: service-api

**Repo:** service-api
**Started:** 2026-07-29 · **Last updated:** 2026-07-29
**Round:** 1 (of 3 max)
**Verdict:** APPROVED_WITH_FOLLOWUPS

## Round history
- Round 1: kotlin-reviewer, lens-security-reviewer

## Findings

### SEC-001 — MEDIUM
**Tracked status:** in_progress · **Finding status:** new
**Reviewer:** lens-security-reviewer
**File:** src/main/kotlin/JobController.kt:42

jobId path param not validated as UUID before the repository lookup
→ Fix: validate against a UUID regex before querying; return 400 on mismatch

### CLEAN-002 — LOW
**Tracked status:** pending · **Finding status:** new
**Reviewer:** lens-clean-code-reviewer
**File:** src/main/kotlin/JobService.kt:18

parameter named data conveys nothing about its shape
→ Fix: rename to jobInput, matching the spec's input field
EOF
assert_golden "render(full, no spec_ref): Spec line absent entirely" "$WORK/render-no-spec.golden"

TESTS_RUN=$((TESTS_RUN + 1))
if grep -Fq -- '**Spec:**' "$WORK/render-no-spec.golden"; then
	fail "render(sanity): golden fixture itself must not contain a Spec line" "golden is wrong"
else
	pass "render(sanity): golden fixture itself has no Spec line (confirms the assertion is meaningful)"
fi

# ---------------------------------------------------------------------------
# Empty findings: [] -> just the "## Findings" heading, nothing under it.
# ---------------------------------------------------------------------------
RENDER_EMPTY_FINDINGS="$WORK/render-empty-findings.json"
jqr '.findings = []' "$RENDER_FULL" >"$RENDER_EMPTY_FINDINGS"
render_run 1 "$RENDER_EMPTY_FINDINGS"
expect_rc "render(empty findings): -> exit 0" 0
cat >"$WORK/render-empty-findings.golden" <<'EOF'
# Review: service-api

**Repo:** service-api
**Spec:** .crucible/docs/specs/2026/07/29/cross-repo-job-submission.json
**Started:** 2026-07-29 · **Last updated:** 2026-07-29
**Round:** 1 (of 3 max)
**Verdict:** APPROVED_WITH_FOLLOWUPS

## Round history
- Round 1: kotlin-reviewer, lens-security-reviewer

## Findings
EOF
assert_golden "render(empty findings): heading only, no dangling blank line" "$WORK/render-empty-findings.golden"

# ---------------------------------------------------------------------------
# --summary mode: a short verdict+counts line only — no findings, no round
# history.
# ---------------------------------------------------------------------------
render_run 1 "$RENDER_FULL" --summary
expect_rc "render(--summary): -> exit 0" 0
cat >"$WORK/render-summary.golden" <<'EOF'
Verdict: APPROVED_WITH_FOLLOWUPS — open: 0 critical, 0 high, 1 medium, 1 low
EOF
assert_golden "render(--summary): byte-exact short line" "$WORK/render-summary.golden"
TESTS_RUN=$((TESTS_RUN + 1))
if printf '%s' "$(cat "$WORK/render-out")" | grep -Fq '## Findings'; then
	fail "render(--summary): must not contain findings/round-history sections" "found '## Findings' in --summary output"
else
	pass "render(--summary): must not contain findings/round-history sections"
fi

# ===========================================================================
# Summary
# ===========================================================================
printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAIL"
if [ "$TESTS_FAIL" -eq 0 ]; then
	exit 0
else
	exit 1
fi
