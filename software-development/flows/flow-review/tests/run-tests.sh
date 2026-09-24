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

# The harness's own umask baseline, pinned BEFORE the first `run`.
#
# WHY pinned rather than inherited: the scripts under test publish at
# 0666 & ~umask (deliberately, so a restrictive umask is honored rather than
# widened), and umask is carried by the PROCESS, not the environment — `env -i`
# in run()/render_run() does not reset it. Every "mode is 644" assertion below
# would therefore fail under an invoking shell with umask 027/077, with the
# exact message of the bug that behavior FIXED ("still mode 644 (not 600)") —
# a correct binary spuriously red in a hardened environment.
#
# Pinning the baseline is preferred over deriving each expected mode from
# $(umask): deriving would re-implement the production script's own
# `0666 & ~umask` arithmetic in the assertion, so a regression in that formula
# would change both sides at once and stay invisible. A fixed baseline keeps
# the expected mode a literal the test states independently, and the
# umask-respecting behavior itself is covered separately (and explicitly, at
# two different umasks) by the dedicated section further down.
HARNESS_UMASK=022
umask "$HARNESS_UMASK"

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

# The complete set of real tools the scripts under test invoke. Named once so
# a section that needs to build a SECOND toolbox with one tool replaced by a
# stub (see the SIGTERM-during-publish section) mirrors this list rather than
# re-listing it and drifting.
REQUIRED_TOOLS='sh mktemp mkdir rm mv dirname date cat basename chmod'

link_tool_into() {
	lti_dir=$1
	tp=$(PATH="$ORIG_PATH" command -v "$2" 2>/dev/null || true)
	[ -n "$tp" ] || { printf 'FATAL: required tool not found: %s\n' "$2" >&2; exit 1; }
	ln -s "$tp" "$lti_dir/$2"
}
link_tool() { link_tool_into "$TOOLBOX" "$1"; }
for t in $REQUIRED_TOOLS; do
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
#
#   $RUN_TOOLBOX selects WHICH toolbox directory supplies those real tools:
#   $TOOLBOX for every ordinary test. A section that must replace one tool
#   with a stub points it at its own directory for the single run that needs
#   it and restores it immediately afterwards — the same save/restore shape
#   the umask section uses.
RUN_TOOLBOX=$TOOLBOX
run() {
	r_jq=$1; shift
	r_path="$RUN_TOOLBOX"
	[ "$r_jq" = "1" ] && r_path="$JQDIR:$RUN_TOOLBOX"
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
#
#   Unlike run(), this deliberately has NO $RUN_TOOLBOX equivalent and always
#   uses $TOOLBOX: render-md.sh is a pure transform with no publish step, so no
#   test here needs one of its tools replaced by a stub. Adding the override
#   unused would be a mechanism with nothing exercising it, and would also make
#   a stray un-restored $RUN_TOOLBOX from a stub section silently reach the
#   renderer — which today it cannot.
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

stderr_lacks() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if printf '%s\n' "$CUR_ERR" | grep -Fq -- "$2"; then fail "$1" "stderr unexpectedly contains: $2"
	else pass "$1"; fi
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

# write_golden FILE — reads golden text on stdin and writes FILE with every
# `<HB>` sentinel expanded to CommonMark's hard line break (two trailing
# spaces, written `··` in SKILL.md §5c).
#
# WHY a sentinel rather than two literal trailing spaces inside the heredocs
# below: those spaces are load-bearing output bytes that trailing-whitespace
# stripping (editors' strip-on-save, formatters, patch tooling) removes
# silently and routinely — a golden carrying them literally decays into a
# permanently-red byte mismatch whose diff is invisible on screen. `<HB>` is
# visible, greppable, and cannot be stripped by accident; this substitution is
# what puts the real bytes on disk, and assert_hard_break_count() below
# verifies it actually did.
write_golden() {
	sed 's/<HB>$/  /' >"$1"
}

# assert_hard_break_count NAME EXPECTED_COUNT GOLDEN_FILE — how many lines of
# GOLDEN_FILE end in a hard line break (two trailing spaces).
#
# WHY a fixture-integrity guard: it confirms write_golden's substitution
# really happened, so a typo'd sentinel or a missing one fails by NAME instead
# of as an inscrutable byte mismatch. Same spirit as the existing "golden
# fixture itself must not contain a Spec line" self-check further down.
assert_hard_break_count() {
	TESTS_RUN=$((TESTS_RUN + 1))
	ahbc_found=$(grep -c '  $' "$3" || true)
	if [ "$ahbc_found" -eq "$2" ]; then pass "$1"
	else fail "$1" "expected $2 hard-break line(s) (two trailing spaces) in $3, found $ahbc_found — did an editor strip trailing whitespace?"; fi
}

# render_out_line_count_is NAME EREGEX EXPECTED_COUNT — how many lines of the
# last render_run's raw stdout match EREGEX. Used to assert that an artifact
# value contributed NO new document structure (a forged heading, a second
# Verdict line) beyond the one line it legitimately belongs on.
render_out_line_count_is() {
	TESTS_RUN=$((TESTS_RUN + 1))
	rolci_found=$(grep -Ec -- "$2" "$WORK/render-out" || true)
	if [ "$rolci_found" -eq "$3" ]; then pass "$1"
	else fail "$1" "expected $3 line(s) matching /$2/ in the render, found $rolci_found"; fi
}

# render_out_has_line NAME LINE — the last render_run's raw stdout contains
# LINE as a WHOLE line, compared as a fixed string. Used where the subject is
# one exact rendered line (an escaped `problem`) and a full golden would bury
# it under a document's worth of unrelated bytes.
render_out_has_line() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if grep -Fxq -- "$2" "$WORK/render-out"; then pass "$1"
	else fail "$1" "no line equal to [$2] in the render; got:$(printf '\n')$(cat "$WORK/render-out")"; fi
}

# assert_no_artifact NAME DIR — no artifact JSON exists anywhere under DIR.
# A rejection that still left a document behind is not a rejection, so every
# reject-before-write case asserts this alongside its exit code.
assert_no_artifact() {
	TESTS_RUN=$((TESTS_RUN + 1))
	ana_found=$(find "$2" -name '*.json' -print 2>/dev/null)
	if [ -z "$ana_found" ]; then pass "$1"
	else fail "$1" "expected no artifact JSON under $2, found: $ana_found"; fi
}

# assert_dir_empty NAME DIR — DIR contains no entries at all, of any kind.
# Stricter than assert_no_artifact (which only looks for *.json): a
# containment refusal that fired only AFTER `mkdir -p` would leave a real
# directory tree at the redirected location outside the repo, with no JSON in
# it — invisible to a JSON-only check, and exactly what the refusal's own
# diagnostic claims did not happen.
assert_dir_empty() {
	TESTS_RUN=$((TESTS_RUN + 1))
	ade_found=$(find "$2" -mindepth 1 -print 2>/dev/null)
	if [ -z "$ade_found" ]; then pass "$1"
	else fail "$1" "expected $2 to be empty, found: $ade_found"; fi
}

# assert_file_unchanged NAME SNAPSHOT FILE — FILE is byte-identical to
# SNAPSHOT, i.e. a rejected operation mutated nothing.
assert_file_unchanged() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if cmp -s "$2" "$3"; then pass "$1"
	else fail "$1" "$(cmp "$2" "$3" 2>&1)"; fi
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
# The sibling render's path, which review-add-round.sh and
# review-update-status.sh both print as a re-render nudge (and which
# review-create.sh deliberately does not — see its stdout assertion below).
EXPECTED_MD="${EXPECTED_JSON%.json}.md"
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
# review-create.sh — trust-boundary rejections that must write NOTHING: a
# multi-document --fields-file, duplicate finding ids, and the \A…\z-anchored
# slug / finding-id patterns. Every case asserts the rejection AND that no
# artifact reached the disk — "rejected" is only half the property, "and
# nothing was written" is the other half.
# ===========================================================================
section "review-create.sh — multi-document / duplicate-id / anchored-pattern rejections"

REPO_TRUST="$WORK/repo-trust"; mkdir -p "$REPO_TRUST"

# ---------------------------------------------------------------------------
# The HIGH-severity validation bypass: `jq -e FILTER file` reports the exit
# status of the LAST document it produced, while the build step reads the
# FIRST (--slurpfile + $fields_arr[0]). A file holding {invalid}{valid} could
# therefore pass validation on document 2 and then be BUILT from the
# unvalidated document 1. Document 1 below is invalid (empty reviewers[]) and
# document 2 is valid, so ANY artifact appearing here is the bypass itself:
# nothing that passed validation could have produced one.
# ---------------------------------------------------------------------------
FIELDS_MULTIDOC="$WORK/fields-multidoc.json"
printf '%s' '{"repo": "doc-one", "reviewers": [], "findings": []}{"repo": "doc-two", "reviewers": ["r1"], "findings": []}' >"$FIELDS_MULTIDOC"

run 1 sh "$CREATE" --repo-root "$REPO_TRUST" --slug multidoc-repo --fields-file "$FIELDS_MULTIDOC"
expect_rc "create(multi-document --fields-file): -> exit 2" 2
stderr_has "create(multi-document --fields-file): diagnostic names the one-document rule" "must hold exactly ONE JSON document"
assert_no_artifact "create(multi-document --fields-file): built nothing from the unvalidated first document" "$REPO_TRUST"

# ---------------------------------------------------------------------------
# Duplicate finding ids: every sibling script keys on the id, so a persisted
# duplicate makes review-update-status.sh refuse the finding outright and
# review-add-round.sh apply one update entry to both copies.
# ---------------------------------------------------------------------------
FIELDS_DUP_IDS="$WORK/fields-duplicate-ids.json"
cat >"$FIELDS_DUP_IDS" <<'EOF'
{
  "repo": "dup-repo",
  "reviewers": ["r1"],
  "findings": [
    { "id": "DUP-001", "reviewer": "r1", "severity": "LOW", "category": "c",
      "locations": ["f.kt:1"], "problem": "p1", "fix": "f1" },
    { "id": "DUP-001", "reviewer": "r1", "severity": "HIGH", "category": "c",
      "locations": ["f.kt:2"], "problem": "p2", "fix": "f2" }
  ]
}
EOF
run 1 sh "$CREATE" --repo-root "$REPO_TRUST" --slug dup-repo --fields-file "$FIELDS_DUP_IDS"
expect_rc "create(duplicate finding ids in round-1 payload): -> exit 2" 2
stderr_has "create(duplicate finding ids in round-1 payload): diagnostic" "duplicate finding ids"
assert_no_artifact "create(duplicate finding ids in round-1 payload): nothing written" "$REPO_TRUST"

# ---------------------------------------------------------------------------
# The \A…\z anchor fix, on both patterns it protects. jq's Oniguruma treats
# `$` as END-OF-LINE, so the earlier `^…$` anchoring accepted a value with a
# TRAILING NEWLINE — which then reached a filename and the document's id (the
# slug) or the persisted finding (the id). The literal newline inside the
# single-quoted assignment below IS the test input; a `$(…)` substitution
# would strip it and silently test nothing.
# ---------------------------------------------------------------------------
SLUG_TRAILING_NEWLINE='ok-slug
'
run 1 sh "$CREATE" --repo-root "$REPO_TRUST" --slug "$SLUG_TRAILING_NEWLINE" --fields-file "$FIELDS_MINIMAL"
expect_rc "create(--slug with a trailing newline): -> exit 2" 2
stderr_has "create(--slug with a trailing newline): diagnostic" "invalid --slug"
assert_no_artifact "create(--slug with a trailing newline): no newline-named file written" "$REPO_TRUST"

FIELDS_ID_TRAILING_NEWLINE="$WORK/fields-id-trailing-newline.json"
cat >"$FIELDS_ID_TRAILING_NEWLINE" <<'EOF'
{
  "repo": "nlid-repo",
  "reviewers": ["r1"],
  "findings": [
    { "id": "SEC-001\n", "reviewer": "r1", "severity": "LOW", "category": "c",
      "locations": ["f.kt:1"], "problem": "p", "fix": "f" }
  ]
}
EOF
run 1 sh "$CREATE" --repo-root "$REPO_TRUST" --slug nlid-repo --fields-file "$FIELDS_ID_TRAILING_NEWLINE"
expect_rc "create(finding id with a trailing newline): -> exit 2" 2
stderr_has "create(finding id with a trailing newline): diagnostic" "failed validation"
assert_no_artifact "create(finding id with a trailing newline): nothing written" "$REPO_TRUST"

# ===========================================================================
# review-create.sh — containment: a symlinked .crucible must never redirect
# the write outside --repo-root. mkdir -p follows a symlinked path component
# silently, so the guard has to compare PHYSICAL paths; the artifact landing
# outside the repo is the failure this pins.
# ===========================================================================
section "review-create.sh — symlinked .crucible containment"

REPO_SYMLINK="$WORK/repo-symlink"; mkdir -p "$REPO_SYMLINK"
OUTSIDE_REPO="$WORK/outside-the-repo"; mkdir -p "$OUTSIDE_REPO"
ln -s "$OUTSIDE_REPO" "$REPO_SYMLINK/.crucible"

run 1 sh "$CREATE" --repo-root "$REPO_SYMLINK" --slug escapee-repo --fields-file "$FIELDS_MINIMAL"
expect_rc "create(symlinked .crucible): -> exit 1" 1
stderr_has "create(symlinked .crucible): diagnostic names the containment refusal" "refusing to write outside the repo root"
assert_no_artifact "create(symlinked .crucible): nothing written to the symlink target outside the repo" "$OUTSIDE_REPO"
# The refusal's own diagnostic claims "no directories were created" — that is
# the phase-1 (pre-mkdir) guarantee, and it is a separate property from "no
# JSON was written". A guard that fired only after `mkdir -p` would satisfy
# assert_no_artifact above while having already built the whole
# docs/reviews/YYYY/MM/DD tree outside the repo.
assert_dir_empty "create(symlinked .crucible): refused BEFORE mkdir — not one directory created outside the repo root" "$OUTSIDE_REPO"

# ---------------------------------------------------------------------------
# The same escape one level DEEPER: .crucible is a genuine in-repo directory
# and .crucible/docs is the symlink. Distinct from the case above because the
# ancestor walk now has to descend THROUGH a legitimate segment before it
# reaches the redirected one — a guard that only inspected the first path
# component under the repo root would pass the case above and miss this.
# ---------------------------------------------------------------------------
REPO_SYMLINK_DEEP="$WORK/repo-symlink-deep"; mkdir -p "$REPO_SYMLINK_DEEP/.crucible"
OUTSIDE_REPO_DEEP="$WORK/outside-the-repo-deep"; mkdir -p "$OUTSIDE_REPO_DEEP"
ln -s "$OUTSIDE_REPO_DEEP" "$REPO_SYMLINK_DEEP/.crucible/docs"

run 1 sh "$CREATE" --repo-root "$REPO_SYMLINK_DEEP" --slug escapee-deep --fields-file "$FIELDS_MINIMAL"
expect_rc "create(symlinked .crucible/docs): -> exit 1" 1
stderr_has "create(symlinked .crucible/docs): diagnostic names the containment refusal" "refusing to write outside the repo root"
assert_no_artifact "create(symlinked .crucible/docs): nothing written to the symlink target outside the repo" "$OUTSIDE_REPO_DEEP"
assert_dir_empty "create(symlinked .crucible/docs): refused BEFORE mkdir — not one directory created outside the repo root" "$OUTSIDE_REPO_DEEP"

# ===========================================================================
# review-create.sh — the published mode is 0666 masked by the CALLER'S OWN
# umask, never a forced 644 (which would silently widen a deliberately
# restrictive umask). $HARNESS_UMASK — the known baseline pinned in the
# Locations block, NOT an unknown ambient value — is restored immediately
# after each run, since every other mode assertion in this file expects the
# 644 that baseline produces.
# ===========================================================================
section "review-create.sh — published file mode respects the caller's umask"

REPO_UMASK_LOOSE="$WORK/repo-umask-loose"; mkdir -p "$REPO_UMASK_LOOSE"
umask 022
run 1 sh "$CREATE" --repo-root "$REPO_UMASK_LOOSE" --slug umask-loose --fields-file "$FIELDS_MINIMAL"
umask "$HARNESS_UMASK"
expect_rc "create(umask 022): -> exit 0" 0
UMASK_LOOSE_JSON=$(review_json_path "$CUR_OUT")
check "create(umask 022): published mode is 644 (0666 & ~022)" "mismatch" \
	"$( [ "$(mode_of "$UMASK_LOOSE_JSON")" = "644" ] && echo 0 || echo 1 )"

REPO_UMASK_TIGHT="$WORK/repo-umask-tight"; mkdir -p "$REPO_UMASK_TIGHT"
umask 027
run 1 sh "$CREATE" --repo-root "$REPO_UMASK_TIGHT" --slug umask-tight --fields-file "$FIELDS_MINIMAL"
umask "$HARNESS_UMASK"
expect_rc "create(umask 027): -> exit 0" 0
UMASK_TIGHT_JSON=$(review_json_path "$CUR_OUT")
check "create(umask 027): published mode is 640 (0666 & ~027) — the tighter umask is honored, not widened to 644" "mismatch" \
	"$( [ "$(mode_of "$UMASK_TIGHT_JSON")" = "640" ] && echo 0 || echo 1 )"

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
# Two stdout keys, in this order and nothing else: this script mutates only the
# JSON, so REVIEW_MD= names the now-stale sibling render as a re-render nudge.
# (review-create.sh still prints REVIEW_JSON= alone — a known, deliberately
# flagged inconsistency, asserted as-is further up.)
stdout_is "add-round(round 2): stdout is exactly REVIEW_JSON=<path> then REVIEW_MD=<path>" \
	"$(printf 'REVIEW_JSON=%s\nREVIEW_MD=%s' "$EXPECTED_JSON" "$EXPECTED_MD")"

check "add-round(round 2): SEC-001 fully resolved (status)" "mismatch" \
	"$( [ "$(jqr -r '.findings[] | select(.id=="SEC-001") | .status' "$EXPECTED_JSON")" = "RESOLVED" ] && echo 0 || echo 1 )"
check "add-round(round 2): SEC-001 fully resolved (tracked_status)" "mismatch" \
	"$( [ "$(jqr -r '.findings[] | select(.id=="SEC-001") | .tracked_status' "$EXPECTED_JSON")" = "APPROVED" ] && echo 0 || echo 1 )"

# CLEAN-002: only tracked_status was given in the update entry, so exactly TWO
# fields may differ from what the finding was BEFORE round 2 —
#   tracked_status  the caller's own update (-> IN_PROGRESS), and
#   status          the carried-over NEW -> OPEN flip the script applies to
#                     every finding from an earlier round before merging this
#                     round's entries: "NEW" means "first reported THIS round",
#                     so a round-1 finding claiming NEW once round 2 exists
#                     would be a standing lie that also inflates summary.new.
# Everything else (id/reviewer/severity/category/locations/first_seen/problem/
# fix) must be byte-identical, and there must still be exactly ONE CLEAN-002.
#
# Asserted as ONE deep-equality against the expected post-round-2 object
# rather than a del()-both-fields comparison: del() would only prove those two
# keys were excluded from the check, never that they hold the RIGHT values,
# and would silently keep passing if the flip regressed to leaving status NEW.
CLEAN_002_AFTER=$(finding_of "$EXPECTED_JSON" "CLEAN-002")
check "add-round(round 2): CLEAN-002 tracked_status flipped to IN_PROGRESS" "mismatch" \
	"$( [ "$(jqr -r '.findings[] | select(.id=="CLEAN-002") | .tracked_status' "$EXPECTED_JSON")" = "IN_PROGRESS" ] && echo 0 || echo 1 )"
check "add-round(round 2): CLEAN-002 carried-over status flipped NEW -> OPEN" "expected OPEN" \
	"$( [ "$(jqr -r '.findings[] | select(.id=="CLEAN-002") | .status' "$EXPECTED_JSON")" = "OPEN" ] && echo 0 || echo 1 )"
check "add-round(round 2): CLEAN-002 was status NEW before this round (the flip above has something to flip)" "expected NEW" \
	"$( [ "$(printf '%s' "$CLEAN_002_BEFORE" | jqr -r '.status')" = "NEW" ] && echo 0 || echo 1 )"
CLEAN_002_EXPECTED=$(printf '%s' "$CLEAN_002_BEFORE" | jqr -cS '.tracked_status = "IN_PROGRESS" | .status = "OPEN"')
check "add-round(round 2): CLEAN-002 partial update touches ONLY tracked_status (-> IN_PROGRESS) and the carried-over status (NEW -> OPEN); every other field unchanged" "before-plus-expected-deltas != after" \
	"$( [ "$CLEAN_002_EXPECTED" = "$CLEAN_002_AFTER" ] && echo 0 || echo 1 )"
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
# review-add-round.sh — --fields-file rejection diagnostics: WHICH entry,
# WHICH field, and WHY, beneath the headline the cases above already match.
#
# WHY these assert whole diagnostic lines, not just the headline: the detail
# pass falls back SILENTLY to the bare headline when its own jq program fails
# or prints nothing, so a broken diagnostic would leave every headline-only
# assertion above green.
#
# A dedicated fixture (round 1, findings DIA-001 + DIA-002). Every case here
# is a rejection, which writes nothing, so round 2 stays newer than the newest
# recorded round throughout and each case reaches entry validation.
# ===========================================================================
section "review-add-round.sh — --fields-file rejection diagnostics"

REPO_DIAGNOSTICS="$WORK/repo-diagnostics"; mkdir -p "$REPO_DIAGNOSTICS"
FIELDS_DIAGNOSTICS_R1="$WORK/fields-diagnostics-r1.json"
cat >"$FIELDS_DIAGNOSTICS_R1" <<'EOF'
{
  "repo": "diagnostics-fixture",
  "reviewers": ["r1"],
  "findings": [
    { "id": "DIA-001", "reviewer": "r1", "severity": "HIGH", "category": "c",
      "locations": ["f.kt:1"], "problem": "p", "fix": "f" },
    { "id": "DIA-002", "reviewer": "r1", "severity": "LOW", "category": "c",
      "locations": ["f.kt:2"], "problem": "p", "fix": "f" }
  ]
}
EOF
run 1 sh "$CREATE" --repo-root "$REPO_DIAGNOSTICS" --slug diagnostics-fixture --fields-file "$FIELDS_DIAGNOSTICS_R1"
expect_rc "add-round(diag fixture): create -> exit 0" 0
DIAGNOSTICS_JSON=$(review_json_path "$CUR_OUT")

# The section's data-driven case runners, for rows whose whole subject is one
# diagnostic line. expect_fields_file_diagnostic LABEL FIELDS_JSON
# EXPECTED_LINE: FIELDS_JSON is rejected with exit 2 and EXPECTED_LINE appears
# on stderr. A row that must show a second line asserts it right after.
expect_fields_file_diagnostic() {
	effd_fields="$WORK/fields-diag-case.json"
	printf '%s\n' "$2" >"$effd_fields"
	run 1 sh "$ADD_ROUND" --json-file "$DIAGNOSTICS_JSON" --fields-file "$effd_fields"
	expect_rc "add-round(diag: $1): -> exit 2" 2
	stderr_has "add-round(diag: $1): detail line" "$3"
}

# expect_entry_diagnostic LABEL ENTRY_JSON EXPECTED_LINE — the same, with
# ENTRY_JSON as the only findings entry of an otherwise valid round 2.
expect_entry_diagnostic() {
	expect_fields_file_diagnostic "$1" "{\"round\": 2, \"reviewers\": [\"r1\"], \"findings\": [ $2 ]}" "$3"
}

DIA_001_UPDATE_LINE='  findings[0] id "DIA-001" — UPDATE (id already in artifact): '

FIELDS_DIAG_NEW_MISSING_FIX="$WORK/fields-diag-new-missing-fix.json"
cat >"$FIELDS_DIAG_NEW_MISSING_FIX" <<'EOF'
{"round": 2, "reviewers": ["r1"], "findings": [
  { "id": "NEW-101", "reviewer": "r1", "tracked_status": "PENDING", "severity": "LOW",
    "category": "c", "locations": ["f.kt:1"], "problem": "p" } ]}
EOF
run 1 sh "$ADD_ROUND" --json-file "$DIAGNOSTICS_JSON" --fields-file "$FIELDS_DIAG_NEW_MISSING_FIX"
expect_rc "add-round(diag: NEW entry missing fix): -> exit 2" 2
stderr_has "add-round(diag: NEW entry missing fix): names the entry index, id, classification and missing field" \
	'  findings[0] id "NEW-101" — NEW (id not in artifact): missing required field "fix"'
stderr_lacks "add-round(diag: NEW entry missing fix): no usage dump on a data error" "Usage:"

# The real-world trap: an update-shaped entry whose id is not in the artifact
# is NEW, so it is judged against the full NEW shape.
FIELDS_DIAG_UPDATE_SHAPED_UNKNOWN_ID="$WORK/fields-diag-update-shaped-unknown-id.json"
cat >"$FIELDS_DIAG_UPDATE_SHAPED_UNKNOWN_ID" <<'EOF'
{"round": 2, "reviewers": ["r1"], "findings": [ { "id": "XXX-999", "status": "RESOLVED", "fix": "done" } ]}
EOF
run 1 sh "$ADD_ROUND" --json-file "$DIAGNOSTICS_JSON" --fields-file "$FIELDS_DIAG_UPDATE_SHAPED_UNKNOWN_ID"
expect_rc "add-round(diag: update-shaped entry, unknown id): -> exit 2" 2
stderr_has "add-round(diag: update-shaped entry, unknown id): classified NEW because the id is not in the artifact" \
	'  findings[0] id "XXX-999" — NEW (id not in artifact): missing required field "reviewer"'
stderr_has "add-round(diag: update-shaped entry, unknown id): every missing NEW field is listed, not just the first" \
	'  findings[0] id "XXX-999" — NEW (id not in artifact): missing required field "problem"'
stderr_lacks "add-round(diag: update-shaped entry, unknown id): never labeled UPDATE" "UPDATE (id already in artifact)"

FIELDS_DIAG_UPDATE_BAD_SEVERITY="$WORK/fields-diag-update-bad-severity.json"
cat >"$FIELDS_DIAG_UPDATE_BAD_SEVERITY" <<'EOF'
{"round": 2, "reviewers": ["r1"], "findings": [ { "id": "DIA-001", "severity": "URGENT" } ]}
EOF
run 1 sh "$ADD_ROUND" --json-file "$DIAGNOSTICS_JSON" --fields-file "$FIELDS_DIAG_UPDATE_BAD_SEVERITY"
expect_rc "add-round(diag: UPDATE entry bad severity): -> exit 2" 2
stderr_has "add-round(diag: UPDATE entry bad severity): classified UPDATE and lists the allowed severities" \
	'  findings[0] id "DIA-001" — UPDATE (id already in artifact): severity "URGENT" is not one of CRITICAL | HIGH | MEDIUM | LOW'

FIELDS_DIAG_TWO_OF_THREE_BAD="$WORK/fields-diag-two-of-three-bad.json"
cat >"$FIELDS_DIAG_TWO_OF_THREE_BAD" <<'EOF'
{"round": 2, "reviewers": ["r1"], "findings": [
  { "id": "DIA-001", "tracked_status": "DONE" },
  { "id": "DIA-002", "status": "RESOLVED" },
  { "id": "NEW-102", "reviewer": "r1", "tracked_status": "PENDING", "severity": "LOW",
    "category": "c", "locations": [""], "problem": "p", "fix": "f" } ]}
EOF
run 1 sh "$ADD_ROUND" --json-file "$DIAGNOSTICS_JSON" --fields-file "$FIELDS_DIAG_TWO_OF_THREE_BAD"
expect_rc "add-round(diag: entries 0 and 2 bad, 1 valid): -> exit 2" 2
stderr_has "add-round(diag: entries 0 and 2 bad, 1 valid): entry 0 reported with the allowed tracked_status values" \
	'  findings[0] id "DIA-001" — UPDATE (id already in artifact): tracked_status "DONE" is not one of PENDING | IN_PROGRESS | APPROVED | APPROVED_WITH_FOLLOWUPS'
stderr_has "add-round(diag: entries 0 and 2 bad, 1 valid): entry 2 reported in the same run, naming the bad locations element" \
	'  findings[2] id "NEW-102" — NEW (id not in artifact): locations[0] must be a non-empty string (got "")'
stderr_lacks "add-round(diag: entries 0 and 2 bad, 1 valid): the valid entry 1 is not reported" "findings[1]"

FIELDS_DIAG_EMPTY_REVIEWERS="$WORK/fields-diag-empty-reviewers.json"
cat >"$FIELDS_DIAG_EMPTY_REVIEWERS" <<'EOF'
{"round": 2, "reviewers": [], "findings": []}
EOF
run 1 sh "$ADD_ROUND" --json-file "$DIAGNOSTICS_JSON" --fields-file "$FIELDS_DIAG_EMPTY_REVIEWERS"
expect_rc "add-round(diag: shape, empty reviewers): -> exit 2" 2
stderr_has "add-round(diag: shape, empty reviewers): names the failing top-level field" \
	'  reviewers must be a non-empty array of non-empty strings (got an empty array)'
stderr_lacks "add-round(diag: shape, empty reviewers): no usage dump on a data error" "Usage:"

expect_fields_file_diagnostic "shape, top level is an array" '[1]' \
	'  the top level must be a JSON object (got a JSON array)'
expect_fields_file_diagnostic "shape, round absent" '{"reviewers": ["r1"], "findings": []}' \
	'  missing required field "round"'
expect_fields_file_diagnostic "shape, round explicit null" '{"round": null, "reviewers": ["r1"], "findings": []}' \
	'  round is null (an explicit null is rejected)'
expect_fields_file_diagnostic "shape, round 1.5" '{"round": 1.5, "reviewers": ["r1"], "findings": []}' \
	'  round must be an integer >= 1 (got 1.5)'
expect_fields_file_diagnostic "shape, reviewers with an empty element" '{"round": 2, "reviewers": ["r1", ""], "findings": []}' \
	'  reviewers[1] must be a non-empty string (got "")'
expect_fields_file_diagnostic "shape, findings absent" '{"round": 2, "reviewers": ["r1"]}' \
	'  missing required field "findings"'
expect_fields_file_diagnostic "shape, findings is an object" '{"round": 2, "reviewers": ["r1"], "findings": {}}' \
	'  findings must be an array, may be [] (got a JSON object)'
expect_fields_file_diagnostic "shape, round 0 AND findings a string" '{"round": 0, "reviewers": ["r1"], "findings": "x"}' \
	'  round must be an integer >= 1 (got 0)'
stderr_has "add-round(diag: shape, round 0 AND findings a string): the second failing field is reported in the same run" \
	'  findings must be an array, may be [] (got "x")'

FIELDS_DIAG_NON_OBJECT_ENTRY="$WORK/fields-diag-non-object-entry.json"
cat >"$FIELDS_DIAG_NON_OBJECT_ENTRY" <<'EOF'
{"round": 2, "reviewers": ["r1"], "findings": [ 42 ]}
EOF
run 1 sh "$ADD_ROUND" --json-file "$DIAGNOSTICS_JSON" --fields-file "$FIELDS_DIAG_NON_OBJECT_ENTRY"
expect_rc "add-round(diag: non-object entry 42): -> exit 2" 2
stderr_has "add-round(diag: non-object entry 42): reported as not a JSON object" \
	'  findings[0] is not a JSON object (got 42)'

FIELDS_DIAG_AIR_ABOVE_ROUND="$WORK/fields-diag-air-above-round.json"
cat >"$FIELDS_DIAG_AIR_ABOVE_ROUND" <<'EOF'
{"round": 2, "reviewers": ["r1"], "findings": [ { "id": "DIA-001", "addressed_in_round": 3 } ]}
EOF
run 1 sh "$ADD_ROUND" --json-file "$DIAGNOSTICS_JSON" --fields-file "$FIELDS_DIAG_AIR_ABOVE_ROUND"
expect_rc "add-round(diag: addressed_in_round 3 while appending round 2): -> exit 2" 2
stderr_has "add-round(diag: addressed_in_round 3 while appending round 2): states the bound it exceeded" \
	'  findings[0] id "DIA-001" — UPDATE (id already in artifact): addressed_in_round 3 is above the maximum of 2 (the round being appended)'

FIELDS_DIAG_AIR_WITH_PENDING="$WORK/fields-diag-air-with-pending.json"
cat >"$FIELDS_DIAG_AIR_WITH_PENDING" <<'EOF'
{"round": 2, "reviewers": ["r1"], "findings": [ { "id": "DIA-001", "tracked_status": "PENDING", "addressed_in_round": 2 } ]}
EOF
run 1 sh "$ADD_ROUND" --json-file "$DIAGNOSTICS_JSON" --fields-file "$FIELDS_DIAG_AIR_WITH_PENDING"
expect_rc "add-round(diag: addressed_in_round alongside PENDING): -> exit 2" 2
stderr_has "add-round(diag: addressed_in_round alongside PENDING): names the contradiction" \
	'  findings[0] id "DIA-001" — UPDATE (id already in artifact): addressed_in_round must be omitted while tracked_status is "PENDING"'

FIELDS_DIAG_EXPLICIT_NULL="$WORK/fields-diag-explicit-null.json"
cat >"$FIELDS_DIAG_EXPLICIT_NULL" <<'EOF'
{"round": 2, "reviewers": ["r1"], "findings": [ { "id": "DIA-001", "fix": null } ]}
EOF
run 1 sh "$ADD_ROUND" --json-file "$DIAGNOSTICS_JSON" --fields-file "$FIELDS_DIAG_EXPLICIT_NULL"
expect_rc "add-round(diag: UPDATE entry explicit null fix): -> exit 2" 2
stderr_has "add-round(diag: UPDATE entry explicit null fix): says the null itself is rejected, not that fix is missing" \
	'  findings[0] id "DIA-001" — UPDATE (id already in artifact): fix is null (an explicit null is rejected)'

expect_entry_diagnostic "UPDATE reviewer empty string" '{"id": "DIA-001", "reviewer": ""}' \
	"$DIA_001_UPDATE_LINE"'reviewer must be a non-empty string (got "")'
expect_entry_diagnostic "UPDATE category a number" '{"id": "DIA-001", "category": 5}' \
	"$DIA_001_UPDATE_LINE"'category must be a non-empty string (got 5)'
expect_entry_diagnostic "UPDATE status BOGUS" '{"id": "DIA-001", "status": "BOGUS"}' \
	"$DIA_001_UPDATE_LINE"'status "BOGUS" is not one of NEW | OPEN | RESOLVED | REGRESSED | ACK'
expect_entry_diagnostic "UPDATE locations empty array" '{"id": "DIA-001", "locations": []}' \
	"$DIA_001_UPDATE_LINE"'locations must be a non-empty array of non-empty strings (got an empty array)'
expect_entry_diagnostic "UPDATE locations a bare string" '{"id": "DIA-001", "locations": "f.kt:1"}' \
	"$DIA_001_UPDATE_LINE"'locations must be a non-empty array of non-empty strings (got "f.kt:1")'
expect_entry_diagnostic "UPDATE addressed_in_round 1.5" '{"id": "DIA-001", "addressed_in_round": 1.5}' \
	"$DIA_001_UPDATE_LINE"'addressed_in_round must be an integer (got 1.5)'
expect_entry_diagnostic "UPDATE addressed_in_round 0" '{"id": "DIA-001", "addressed_in_round": 0}' \
	"$DIA_001_UPDATE_LINE"'addressed_in_round 0 is below the minimum of 1'
# first_seen on an UPDATE is ignored rather than validated, so only a NEW
# entry can reach this reason.
expect_entry_diagnostic "NEW first_seen not zero-padded" \
	'{"id": "NEW-103", "reviewer": "r1", "tracked_status": "PENDING", "severity": "LOW", "category": "c", "locations": ["f.kt:1"], "problem": "p", "fix": "f", "first_seen": "2020-6-15"}' \
	'  findings[0] id "NEW-103" — NEW (id not in artifact): first_seen must be a YYYY-MM-DD date string (got "2020-6-15")'

# Truncation boundary: 80 chars is the limit (shown whole), 81 is over it.
DIAG_EIGHTY_X=$(jqr -rn '"X" * 80')
FIELDS_DIAG_SEVERITY_80="$WORK/fields-diag-severity-80.json"
jqr -n '{round: 2, reviewers: ["r1"], findings: [ { id: "DIA-001", severity: ("X" * 80) } ]}' >"$FIELDS_DIAG_SEVERITY_80"
run 1 sh "$ADD_ROUND" --json-file "$DIAGNOSTICS_JSON" --fields-file "$FIELDS_DIAG_SEVERITY_80"
expect_rc "add-round(diag: 80-char severity): -> exit 2" 2
stderr_has "add-round(diag: 80-char severity): value shown whole" \
	"severity \"$DIAG_EIGHTY_X\" is not one of"
stderr_lacks "add-round(diag: 80-char severity): not marked truncated" "(truncated)"

FIELDS_DIAG_LONG_SEVERITY="$WORK/fields-diag-long-severity.json"
jqr -n '{round: 2, reviewers: ["r1"], findings: [ { id: "DIA-001", severity: ("X" * 81) } ]}' >"$FIELDS_DIAG_LONG_SEVERITY"
run 1 sh "$ADD_ROUND" --json-file "$DIAGNOSTICS_JSON" --fields-file "$FIELDS_DIAG_LONG_SEVERITY"
expect_rc "add-round(diag: 81-char severity): -> exit 2" 2
stderr_has "add-round(diag: 81-char severity): value cut to 80 chars and marked truncated" \
	"severity \"$DIAG_EIGHTY_X\" (truncated) is not one of"
stderr_lacks "add-round(diag: 81-char severity): no 81st char of the value echoed" "${DIAG_EIGHTY_X}X"

# Far past the limit, where "cut to 80" and "drop the last char" differ — the
# 81-char row cannot tell them apart.
FIELDS_DIAG_VERY_LONG_SEVERITY="$WORK/fields-diag-very-long-severity.json"
jqr -n '{round: 2, reviewers: ["r1"], findings: [ { id: "DIA-001", severity: ("X" * 200) } ]}' >"$FIELDS_DIAG_VERY_LONG_SEVERITY"
run 1 sh "$ADD_ROUND" --json-file "$DIAGNOSTICS_JSON" --fields-file "$FIELDS_DIAG_VERY_LONG_SEVERITY"
expect_rc "add-round(diag: 200-char severity): -> exit 2" 2
stderr_has "add-round(diag: 200-char severity): value cut to exactly 80 chars and marked truncated" \
	"severity \"$DIAG_EIGHTY_X\" (truncated) is not one of"
stderr_lacks "add-round(diag: 200-char severity): no 81st char of the value echoed" "${DIAG_EIGHTY_X}X"

# ESC is supplied as the JSON escape \u001b because jq rejects a raw control
# byte inside a JSON string; the PARSED value still carries a raw ESC. U+009B
# (the 8-bit CSI) is legal raw in JSON, so it is written as its UTF-8 bytes.
DIAG_RAW_ESC=$(printf '\033')
DIAG_RAW_C1_CSI=$(printf '\302\233')
FIELDS_DIAG_CONTROL_BYTES="$WORK/fields-diag-control-bytes.json"
printf '{"round": 2, "reviewers": ["r1"], "findings": [ { "id": "EVIL\\u001b[31m-001%sx", "reviewer": "r1", "tracked_status": "PENDING", "severity": "LOW%s", "category": "c", "locations": ["f.kt:1"], "problem": "p", "fix": "f" } ]}\n' \
	"$DIAG_RAW_C1_CSI" "$DIAG_RAW_C1_CSI" >"$FIELDS_DIAG_CONTROL_BYTES"
run 1 sh "$ADD_ROUND" --json-file "$DIAGNOSTICS_JSON" --fields-file "$FIELDS_DIAG_CONTROL_BYTES"
expect_rc "add-round(diag: ESC and C1 in caller values): -> exit 2" 2
stderr_has "add-round(diag: ESC and C1 in caller values): id shown with both control chars escaped" \
	'id "EVIL\u001b[31m-001\u009bx" does not match the id format'
stderr_has "add-round(diag: ESC and C1 in caller values): enum value shown with C1 escaped" \
	'severity "LOW\u009b" is not one of'
stderr_lacks "add-round(diag: ESC and C1 in caller values): no raw ESC byte reaches stderr" "$DIAG_RAW_ESC"
stderr_lacks "add-round(diag: ESC and C1 in caller values): no raw C1 CSI reaches stderr" "$DIAG_RAW_C1_CSI"

# The other half of the no-usage-on-data-errors change: a FLAG error still
# prints the usage block (the section at the top of the add-round tests only
# asserts its diagnostic line).
run 1 sh "$ADD_ROUND" --bogus-flag
expect_rc "add-round(diag: unknown option): -> exit 2" 2
stderr_has "add-round(diag: unknown option): usage block still printed for a flag error" "Usage:"

# copy_add_round_with_sabotage DIR SED_SCRIPT — DIR/review-add-round.sh is the
# script under test rewritten by SED_SCRIPT, with lib/ beside it because the
# script resolves its library relative to itself. The real script is never
# touched.
copy_add_round_with_sabotage() {
	mkdir -p "$1/lib"
	cp "$SCRIPTS_DIR/lib/review-aggregates.jq" "$1/lib/"
	sed "$2" "$ADD_ROUND" >"$1/review-add-round.sh"
}

# The fallback: a copy of the script whose diagnostic jq no longer compiles
# (a renamed `shown` def) must still reject with the bare headline.
copy_add_round_with_sabotage "$WORK/diag-sabotaged" 's/^def shown:$/def shown_renamed:/'
DIAG_SABOTAGED_ADD_ROUND="$WORK/diag-sabotaged/review-add-round.sh"
check "add-round(diag fallback): sabotage actually applied to the copy" "no 'def shown_renamed:' line in $DIAG_SABOTAGED_ADD_ROUND" \
	"$( grep -qx 'def shown_renamed:' "$DIAG_SABOTAGED_ADD_ROUND" && echo 0 || echo 1 )"

run 1 sh "$DIAG_SABOTAGED_ADD_ROUND" --json-file "$DIAGNOSTICS_JSON" --fields-file "$FIELDS_DIAG_NEW_MISSING_FIX"
expect_rc "add-round(diag fallback, entry): still rejects -> exit 2" 2
stderr_has "add-round(diag fallback, entry): bare headline printed" \
	"review-add-round.sh: error: --fields-file has an invalid finding entry (see review-add-round.sh --help for the new-vs-update shape)"
stderr_lacks "add-round(diag fallback, entry): headline not left dangling with a colon" "new-vs-update shape):"
stderr_lacks "add-round(diag fallback, entry): no per-entry detail" "findings[0]"
stderr_lacks "add-round(diag fallback, entry): the failed diagnostic's jq error is not leaked" "jq: "

run 1 sh "$DIAG_SABOTAGED_ADD_ROUND" --json-file "$DIAGNOSTICS_JSON" --fields-file "$FIELDS_DIAG_EMPTY_REVIEWERS"
expect_rc "add-round(diag fallback, shape): still rejects -> exit 2" 2
stderr_has "add-round(diag fallback, shape): bare headline printed" \
	"review-add-round.sh: error: --fields-file failed validation (round/reviewers/findings shape) — see review-add-round.sh --help"
stderr_lacks "add-round(diag fallback, shape): headline not left dangling with a colon" "--help:"
stderr_lacks "add-round(diag fallback, shape): no per-field detail" "reviewers must be"

# The fallback's other trigger: a diagnostic that runs cleanly but prints
# nothing must not leave a headline promising detail that never follows.
# The rewritten line ends BOTH diagnostic programs (shape and entries); the
# guard requires both, since a copy with only one silenced would run the
# other unsabotaged and fail below for a harness reason, not a product one.
copy_add_round_with_sabotage "$WORK/diag-silent" 's/^| "  " + \.$/| empty/'
DIAG_SILENT_ADD_ROUND="$WORK/diag-silent/review-add-round.sh"
check "add-round(diag fallback, silent): sabotage silenced both diagnostic programs in the copy" "expected 2 '| empty' lines in $DIAG_SILENT_ADD_ROUND" \
	"$( [ "$(grep -cx '| empty' "$DIAG_SILENT_ADD_ROUND")" -eq 2 ] && echo 0 || echo 1 )"

run 1 sh "$DIAG_SILENT_ADD_ROUND" --json-file "$DIAGNOSTICS_JSON" --fields-file "$FIELDS_DIAG_NEW_MISSING_FIX"
expect_rc "add-round(diag fallback, silent): still rejects -> exit 2" 2
stderr_has "add-round(diag fallback, silent): bare headline printed" \
	"review-add-round.sh: error: --fields-file has an invalid finding entry (see review-add-round.sh --help for the new-vs-update shape)"
stderr_lacks "add-round(diag fallback, silent): headline not left dangling with a colon" "new-vs-update shape):"

# ===========================================================================
# review-add-round.sh — a stray key never reaches the artifact, on BOTH the
# new-finding and the update-entry path (TEST-004)
#
# The entry validator rejects any key outside the known finding fields, so a
# stray key stops the whole round before the merge runs. The merge's
# pick_known_* allow-lists still strip unknown keys as defense in depth, but
# no fields file can reach them with one any more, so that stripping is no
# longer observable through the CLI and is not tested here.
# ===========================================================================
section "review-add-round.sh — stray key rejected on a NEW and an UPDATE entry"

SNAPSHOT_PICK_KNOWN="$WORK/validation-before-pick-known.json"
cp "$VALIDATION_JSON" "$SNAPSHOT_PICK_KNOWN"

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
expect_rc "add-round(stray key): -> exit 2" 2
stderr_has "add-round(stray key): brand-new STR-777 rejected, naming bogusKey" \
	'  findings[0] id "STR-777" — NEW (id not in artifact): unknown field "bogusKey"'
stderr_has "add-round(stray key): update to VAL-001 rejected, naming bogusKey" \
	'  findings[1] id "VAL-001" — UPDATE (id already in artifact): unknown field "bogusKey"'
assert_file_unchanged "add-round(stray key): artifact untouched — neither entry, nor bogusKey, was written" "$SNAPSHOT_PICK_KNOWN" "$VALIDATION_JSON"

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
# review-add-round.sh — multi-document --fields-file, round monotonicity, and
# the addressed_in_round upper bound, on a DEDICATED fixture so the round
# numbering here is independent of the fixtures above.
# ===========================================================================
section "review-add-round.sh — multi-document / monotonicity / addressed_in_round bound"

REPO_ROUNDS="$WORK/repo-rounds"; mkdir -p "$REPO_ROUNDS"
FIELDS_ROUNDS_R1="$WORK/fields-rounds-r1.json"
cat >"$FIELDS_ROUNDS_R1" <<'EOF'
{
  "repo": "rounds-fixture",
  "reviewers": ["r1"],
  "findings": [
    { "id": "MON-001", "reviewer": "r1", "severity": "LOW", "category": "c",
      "locations": ["f.kt:1"], "problem": "p", "fix": "f" }
  ]
}
EOF
run 1 sh "$CREATE" --repo-root "$REPO_ROUNDS" --slug rounds-fixture --fields-file "$FIELDS_ROUNDS_R1"
expect_rc "add-round(rounds fixture): create -> exit 0" 0
ROUNDS_JSON=$(review_json_path "$CUR_OUT")

# ---------------------------------------------------------------------------
# Same HIGH-severity bypass as review-create.sh's, on the merge path: document
# 1 carries an invalid update entry ("status": "BOGUS") and document 2 is
# valid, so validation passing on document 2 while the MERGE reads document 1
# would write the bogus status straight onto MON-001.
# ---------------------------------------------------------------------------
SNAPSHOT_ROUNDS_R1="$WORK/rounds-fixture-after-create.json"
cp "$ROUNDS_JSON" "$SNAPSHOT_ROUNDS_R1"

FIELDS_ADDROUND_MULTIDOC="$WORK/fields-addround-multidoc.json"
printf '%s' '{"round": 50, "reviewers": ["r1"], "findings": [{"id": "MON-001", "status": "BOGUS"}]}{"round": 50, "reviewers": ["r1"], "findings": []}' >"$FIELDS_ADDROUND_MULTIDOC"

run 1 sh "$ADD_ROUND" --json-file "$ROUNDS_JSON" --fields-file "$FIELDS_ADDROUND_MULTIDOC"
expect_rc "add-round(multi-document --fields-file): -> exit 2" 2
stderr_has "add-round(multi-document --fields-file): diagnostic names the one-document rule" "must hold exactly ONE JSON document"
assert_file_unchanged "add-round(multi-document --fields-file): merged nothing from the unvalidated first document" "$SNAPSHOT_ROUNDS_R1" "$ROUNDS_JSON"

# Round 3 appended over round 1 — a legitimate forward jump, and the state the
# stale-round rejection below needs (newest recorded round becomes 3).
FIELDS_ROUNDS_R3="$WORK/fields-rounds-r3.json"
cat >"$FIELDS_ROUNDS_R3" <<'EOF'
{"round": 3, "reviewers": ["r1"], "findings": []}
EOF
run 1 sh "$ADD_ROUND" --json-file "$ROUNDS_JSON" --fields-file "$FIELDS_ROUNDS_R3"
expect_rc "add-round(round 3 over round 1): forward jump accepted -> exit 0" 0
check "add-round(round 3 over round 1): rounds[] is now [1, 3]" "mismatch" \
	"$( [ "$(jqr -c '[.rounds[].round]' "$ROUNDS_JSON")" = "[1,3]" ] && echo 0 || echo 1 )"

# ---------------------------------------------------------------------------
# Monotonicity: round 2 is NOT a duplicate (only 1 and 3 are recorded), so
# only the strictly-greater-than-max rule can reject it. Distinct from the
# duplicate-round case covered further up.
# ---------------------------------------------------------------------------
SNAPSHOT_ROUNDS_R3="$WORK/rounds-fixture-after-round3.json"
cp "$ROUNDS_JSON" "$SNAPSHOT_ROUNDS_R3"

FIELDS_ROUNDS_STALE="$WORK/fields-rounds-stale.json"
cat >"$FIELDS_ROUNDS_STALE" <<'EOF'
{"round": 2, "reviewers": ["r1"], "findings": []}
EOF
run 1 sh "$ADD_ROUND" --json-file "$ROUNDS_JSON" --fields-file "$FIELDS_ROUNDS_STALE"
expect_rc "add-round(round 2 after round 3, not a duplicate): -> exit 1" 1
stderr_has "add-round(round 2 after round 3, not a duplicate): diagnostic names the ascending-order rule" "is not newer than the newest recorded round"
assert_file_unchanged "add-round(round 2 after round 3, not a duplicate): file untouched" "$SNAPSHOT_ROUNDS_R3" "$ROUNDS_JSON"

# ---------------------------------------------------------------------------
# addressed_in_round may cite THIS round (the round being appended verified
# the fix) but never a round that has not run. Both sides are asserted: 5 is
# rejected while appending round 4, and 4 is accepted and persisted — so the
# bound is genuinely "> this round", not "reject anything".
# ---------------------------------------------------------------------------
FIELDS_AIR_BEYOND="$WORK/fields-air-beyond-round.json"
cat >"$FIELDS_AIR_BEYOND" <<'EOF'
{"round": 4, "reviewers": ["r1"], "findings": [ { "id": "MON-001", "addressed_in_round": 5 } ]}
EOF
run 1 sh "$ADD_ROUND" --json-file "$ROUNDS_JSON" --fields-file "$FIELDS_AIR_BEYOND"
expect_rc "add-round(addressed_in_round 5 while appending round 4): -> exit 2" 2
stderr_has "add-round(addressed_in_round 5 while appending round 4): diagnostic" "invalid finding entry"
assert_file_unchanged "add-round(addressed_in_round 5 while appending round 4): file untouched" "$SNAPSHOT_ROUNDS_R3" "$ROUNDS_JSON"

FIELDS_AIR_THIS_ROUND="$WORK/fields-air-this-round.json"
cat >"$FIELDS_AIR_THIS_ROUND" <<'EOF'
{"round": 4, "reviewers": ["r1"], "findings": [ { "id": "MON-001", "addressed_in_round": 4, "status": "RESOLVED", "tracked_status": "APPROVED" } ]}
EOF
run 1 sh "$ADD_ROUND" --json-file "$ROUNDS_JSON" --fields-file "$FIELDS_AIR_THIS_ROUND"
expect_rc "add-round(addressed_in_round 4 while appending round 4): accepted -> exit 0" 0
check "add-round(addressed_in_round 4 while appending round 4): MON-001.addressed_in_round persisted as 4" "mismatch" \
	"$( [ "$(jqr -r '.findings[] | select(.id=="MON-001") | .addressed_in_round' "$ROUNDS_JSON")" = "4" ] && echo 0 || echo 1 )"

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
# Same two-key contract as review-add-round.sh: the flipped id, then the
# now-stale sibling render's path — and nothing else.
stdout_is "update-status(flip CLEAN-002 status only): stdout is exactly REVIEW_UPDATED=<id> then REVIEW_MD=<path>" \
	"$(printf 'REVIEW_UPDATED=%s\nREVIEW_MD=%s' "CLEAN-002" "$EXPECTED_MD")"

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
# review-update-status.sh — addressed_in_round: the newest-recorded-round
# upper bound, the contradictory-option rejections, and the two ways the key
# is REMOVED (never set to null, which review-artifact.schema.json rejects):
# the explicit --clear-addressed-in-round flag and the automatic clear that
# --tracked-status PENDING/IN_PROGRESS performs.
#
# Runs against the ackreg fixture, whose rounds[] holds round 1 only — so 1 is
# the only citable round and 2 is out of bounds.
# ===========================================================================
section "review-update-status.sh — addressed_in_round bound and clear paths"

SNAPSHOT_ACKREG="$WORK/ackreg-before-air.json"
cp "$ACKREG_JSON" "$SNAPSHOT_ACKREG"

run 1 sh "$UPDATE_STATUS" --json-file "$ACKREG_JSON" --id ACK-001 --addressed-in-round 2
expect_rc "update-status(--addressed-in-round 2, newest recorded round is 1): -> exit 2" 2
stderr_has "update-status(--addressed-in-round 2, newest recorded round is 1): diagnostic" "exceeds the newest recorded round"
assert_file_unchanged "update-status(--addressed-in-round 2, newest recorded round is 1): file untouched" "$SNAPSHOT_ACKREG" "$ACKREG_JSON"

run 1 sh "$UPDATE_STATUS" --json-file "$ACKREG_JSON" --id ACK-001 --addressed-in-round 1 --clear-addressed-in-round
expect_rc "update-status(--addressed-in-round with --clear-addressed-in-round): -> exit 2" 2
stderr_has "update-status(--addressed-in-round with --clear-addressed-in-round): diagnostic" "mutually exclusive"
assert_file_unchanged "update-status(--addressed-in-round with --clear-addressed-in-round): file untouched" "$SNAPSHOT_ACKREG" "$ACKREG_JSON"

# --tracked-status PENDING/IN_PROGRESS clears addressed_in_round, so supplying
# one explicitly alongside either state is the caller contradicting itself —
# rejected rather than silently discarded.
run 1 sh "$UPDATE_STATUS" --json-file "$ACKREG_JSON" --id ACK-001 --addressed-in-round 1 --tracked-status PENDING
expect_rc "update-status(--addressed-in-round with --tracked-status PENDING): -> exit 2" 2
stderr_has "update-status(--addressed-in-round with --tracked-status PENDING): diagnostic" "cannot be combined with"
assert_file_unchanged "update-status(--addressed-in-round with --tracked-status PENDING): file untouched" "$SNAPSHOT_ACKREG" "$ACKREG_JSON"

# Clear path 1 — the explicit flag. Set the key first, so the clear has
# something real to remove.
run 1 sh "$UPDATE_STATUS" --json-file "$ACKREG_JSON" --id ACK-001 --addressed-in-round 1
expect_rc "update-status(set ACK-001 addressed_in_round 1): -> exit 0" 0
check "update-status(set ACK-001 addressed_in_round 1): key present with value 1" "mismatch" \
	"$( [ "$(jqr -r '.findings[] | select(.id=="ACK-001") | .addressed_in_round' "$ACKREG_JSON")" = "1" ] && echo 0 || echo 1 )"

ACK_001_WITH_AIR=$(finding_of "$ACKREG_JSON" "ACK-001")

run 1 sh "$UPDATE_STATUS" --json-file "$ACKREG_JSON" --id ACK-001 --clear-addressed-in-round
expect_rc "update-status(--clear-addressed-in-round): -> exit 0" 0
check "update-status(--clear-addressed-in-round): addressed_in_round REMOVED, not set to null" "key still present" \
	"$( jqr -e '.findings[] | select(.id=="ACK-001") | has("addressed_in_round") | not' "$ACKREG_JSON" >/dev/null 2>&1 && echo 0 || echo 1 )"
check "update-status(--clear-addressed-in-round): removing the key is the ONLY change to ACK-001" "another field changed too" \
	"$( [ "$(printf '%s' "$ACK_001_WITH_AIR" | jqr -cS 'del(.addressed_in_round)')" = "$(finding_of "$ACKREG_JSON" "ACK-001")" ] && echo 0 || echo 1 )"

# Clear path 2 — the automatic clear on a PENDING/IN_PROGRESS transition, with
# no --clear flag given at all.
run 1 sh "$UPDATE_STATUS" --json-file "$ACKREG_JSON" --id ACK-001 --addressed-in-round 1
expect_rc "update-status(re-set ACK-001 addressed_in_round 1 for the auto-clear path): -> exit 0" 0
run 1 sh "$UPDATE_STATUS" --json-file "$ACKREG_JSON" --id ACK-001 --tracked-status IN_PROGRESS
expect_rc "update-status(--tracked-status IN_PROGRESS, no --clear flag): -> exit 0" 0
check "update-status(--tracked-status IN_PROGRESS, no --clear flag): addressed_in_round auto-REMOVED, not set to null" "key still present" \
	"$( jqr -e '.findings[] | select(.id=="ACK-001") | has("addressed_in_round") | not' "$ACKREG_JSON" >/dev/null 2>&1 && echo 0 || echo 1 )"
check "update-status(--tracked-status IN_PROGRESS, no --clear flag): the requested tracked_status still applied" "mismatch" \
	"$( [ "$(jqr -r '.findings[] | select(.id=="ACK-001") | .tracked_status' "$ACKREG_JSON")" = "IN_PROGRESS" ] && echo 0 || echo 1 )"

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
# render-md.sh — full-mode goldens. Each golden below is DERIVED from
# SKILL.md §5c's template and pins the renderer's output to it byte-for-byte;
# nothing here reads SKILL.md, so a drift between the skill and these
# fixtures is not something the harness can catch.
#
# Every golden here ends its intra-block lines with the `<HB>` sentinel —
# CommonMark's hard line break (SKILL.md §5c writes it `··`), expanded to the
# two real trailing spaces by write_golden() and then confirmed present by
# assert_hard_break_count(). See write_golden()'s own WHY for why the sentinel
# exists instead of literal trailing spaces in these heredocs.
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
write_golden "$WORK/render-full.golden" <<'EOF'
# Review: service-api

**Repo:** service-api<HB>
**Spec:** .crucible/docs/specs/2026/07/29/cross-repo-job-submission.json<HB>
**Started:** 2026-07-29 · **Last updated:** 2026-07-29<HB>
**Round:** 1<HB>
**Verdict:** APPROVED_WITH_FOLLOWUPS

## Round history
- Round 1: kotlin-reviewer, lens-security-reviewer

## Findings

### SEC-001 — MEDIUM
**Tracked status:** in_progress · **Finding status:** new<HB>
**Reviewer:** lens-security-reviewer<HB>
**File:** src/main/kotlin/JobController.kt:42

jobId path param not validated as UUID before the repository lookup<HB>
→ Fix: validate against a UUID regex before querying; return 400 on mismatch

### CLEAN-002 — LOW
**Tracked status:** pending · **Finding status:** new<HB>
**Reviewer:** lens-clean-code-reviewer<HB>
**File:** src/main/kotlin/JobService.kt:18

parameter named data conveys nothing about its shape<HB>
→ Fix: rename to jobInput, matching the spec's input field
EOF
assert_hard_break_count "render(full, with spec_ref): golden carries all 10 hard breaks (4 metadata + 3 per finding)" 10 "$WORK/render-full.golden"
assert_golden "render(full, with spec_ref): byte-exact against the §5c-derived render" "$WORK/render-full.golden"

# ---------------------------------------------------------------------------
# Same document minus spec_ref: the **Spec:** line must be ABSENT ENTIRELY,
# not blank.
# ---------------------------------------------------------------------------
RENDER_NO_SPEC="$WORK/render-no-spec.json"
jqr 'del(.spec_ref)' "$RENDER_FULL" >"$RENDER_NO_SPEC"
render_run 1 "$RENDER_NO_SPEC"
expect_rc "render(full, no spec_ref): -> exit 0" 0
write_golden "$WORK/render-no-spec.golden" <<'EOF'
# Review: service-api

**Repo:** service-api<HB>
**Started:** 2026-07-29 · **Last updated:** 2026-07-29<HB>
**Round:** 1<HB>
**Verdict:** APPROVED_WITH_FOLLOWUPS

## Round history
- Round 1: kotlin-reviewer, lens-security-reviewer

## Findings

### SEC-001 — MEDIUM
**Tracked status:** in_progress · **Finding status:** new<HB>
**Reviewer:** lens-security-reviewer<HB>
**File:** src/main/kotlin/JobController.kt:42

jobId path param not validated as UUID before the repository lookup<HB>
→ Fix: validate against a UUID regex before querying; return 400 on mismatch

### CLEAN-002 — LOW
**Tracked status:** pending · **Finding status:** new<HB>
**Reviewer:** lens-clean-code-reviewer<HB>
**File:** src/main/kotlin/JobService.kt:18

parameter named data conveys nothing about its shape<HB>
→ Fix: rename to jobInput, matching the spec's input field
EOF
assert_hard_break_count "render(full, no spec_ref): golden carries 9 hard breaks (3 metadata, no Spec line + 3 per finding)" 9 "$WORK/render-no-spec.golden"
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
write_golden "$WORK/render-empty-findings.golden" <<'EOF'
# Review: service-api

**Repo:** service-api<HB>
**Spec:** .crucible/docs/specs/2026/07/29/cross-repo-job-submission.json<HB>
**Started:** 2026-07-29 · **Last updated:** 2026-07-29<HB>
**Round:** 1<HB>
**Verdict:** APPROVED_WITH_FOLLOWUPS

## Round history
- Round 1: kotlin-reviewer, lens-security-reviewer

## Findings
EOF
assert_hard_break_count "render(empty findings): golden carries 4 hard breaks (metadata only, no finding blocks)" 4 "$WORK/render-empty-findings.golden"
assert_golden "render(empty findings): heading only, no dangling blank line" "$WORK/render-empty-findings.golden"

# ---------------------------------------------------------------------------
# Two rounds: the **Round:** line is DERIVED from `.rounds | length` (not a
# literal 1), and ## Round history emits one line per entry. Every golden
# above uses a single-round artifact, where a hardcoded 1 and a single
# history line would pass identically — this is the fixture that separates
# the derivation from that coincidence.
# ---------------------------------------------------------------------------
RENDER_TWO_ROUNDS="$WORK/render-two-rounds.json"
jqr '.rounds += [{ "round": 2, "generated": "2026-08-03", "reviewers": ["kotlin-reviewer"] }]' \
	"$RENDER_FULL" >"$RENDER_TWO_ROUNDS"
render_run 1 "$RENDER_TWO_ROUNDS"
expect_rc "render(two rounds): -> exit 0" 0
write_golden "$WORK/render-two-rounds.golden" <<'EOF'
# Review: service-api

**Repo:** service-api<HB>
**Spec:** .crucible/docs/specs/2026/07/29/cross-repo-job-submission.json<HB>
**Started:** 2026-07-29 · **Last updated:** 2026-07-29<HB>
**Round:** 2<HB>
**Verdict:** APPROVED_WITH_FOLLOWUPS

## Round history
- Round 1: kotlin-reviewer, lens-security-reviewer
- Round 2: kotlin-reviewer

## Findings

### SEC-001 — MEDIUM
**Tracked status:** in_progress · **Finding status:** new<HB>
**Reviewer:** lens-security-reviewer<HB>
**File:** src/main/kotlin/JobController.kt:42

jobId path param not validated as UUID before the repository lookup<HB>
→ Fix: validate against a UUID regex before querying; return 400 on mismatch

### CLEAN-002 — LOW
**Tracked status:** pending · **Finding status:** new<HB>
**Reviewer:** lens-clean-code-reviewer<HB>
**File:** src/main/kotlin/JobService.kt:18

parameter named data conveys nothing about its shape<HB>
→ Fix: rename to jobInput, matching the spec's input field
EOF
assert_hard_break_count "render(two rounds): golden carries all 10 hard breaks (a second history line adds none)" 10 "$WORK/render-two-rounds.golden"
assert_golden "render(two rounds): Round count derived from .rounds length, one history line per round" "$WORK/render-two-rounds.golden"

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
# render-md.sh — the artifact-shape precondition, on BOTH render paths. "Is a
# JSON object" is not enough: a wrong-shaped object used to flow straight into
# the templates and render plausible-looking garbage — `Verdict:  — open: null
# critical, …` for --summary, which is precisely the blocking check a caller
# trusts — or crash jq outright. Each case must instead be a documented exit
# 1, with the shape diagnostic and NO output at all.
# ===========================================================================
section "render-md.sh — artifact-shape precondition (both modes)"

# The section's data-driven case runner: one mutation of the known-good full
# artifact, asserted identically in full and --summary mode. Kept local to the
# section rather than up with the harness primitives because these six
# assertions are this section's subject, not a general-purpose helper.
#
# The rows below cover ALL SEVEN clauses of the guard's conjunction — one row
# per clause. A clause with no row is a clause that could be deleted from the
# guard with the suite staying green.
expect_render_shape_rejection() {
	ersr_label=$1
	jqr "$2" "$RENDER_FULL" >"$WORK/render-badshape.json"

	render_run 1 "$WORK/render-badshape.json"
	expect_rc "render(full, $ersr_label): -> documented exit 1" 1
	stderr_has "render(full, $ersr_label): shape diagnostic" "not shaped like a review artifact"
	stderr_lacks "render(full, $ersr_label): no raw jq crash leaked to stderr" "jq: error"
	stdout_is "render(full, $ersr_label): renders nothing at all" ""

	render_run 1 "$WORK/render-badshape.json" --summary
	expect_rc "render(--summary, $ersr_label): -> documented exit 1" 1
	stderr_has "render(--summary, $ersr_label): shape diagnostic" "not shaped like a review artifact"
	stderr_lacks "render(--summary, $ersr_label): no raw jq crash leaked to stderr" "jq: error"
	stdout_is "render(--summary, $ersr_label): emits no verdict line at all" ""
}

expect_render_shape_rejection "missing .summary" 'del(.summary)'
expect_render_shape_rejection "missing .overall_verdict" 'del(.overall_verdict)'
expect_render_shape_rejection "wrong-typed .findings (object, not array)" '.findings = {"leading": "nowhere"}'
expect_render_shape_rejection "wrong-typed .rounds (object, not array)" '.rounds = {}'
expect_render_shape_rejection "wrong-typed .repo (number, not string)" '.repo = 42'
expect_render_shape_rejection "missing .created" 'del(.created)'
expect_render_shape_rejection "missing .last_updated" 'del(.last_updated)'

# ===========================================================================
# render-md.sh — Markdown-STRUCTURE injection is neutralized. Execution is
# only half the threat: finding text describes an arbitrary, possibly
# adversarial target repo, and a `problem`/`fix` string carrying embedded
# newlines could otherwise forge document structure — a fabricated
# `### FAKE-ID — CRITICAL` block, a bogus `**Verdict:**` line, an invented
# round-history bullet — all reading as the renderer's own output. Every
# interpolated value goes through `neutralize` first, so an artifact value can
# contribute inline text to the line it belongs on and nothing else.
#
# The fixture injects into FOUR distinct call sites, not just the finding text,
# because `neutralize` is applied per-interpolation and could regress at any
# one of them independently:
#   .problem / .fix           — the finding block
#   .repo                     — reaches BOTH the `# Review:` heading and the
#                                 `**Repo:**` metadata line
#   .rounds[].reviewers[]     — reaches the `- Round N: …` history bullets
# The last two are caller-supplied and validated by review-create.sh as
# non-empty STRINGS only, with no control-character restriction — so they can
# genuinely carry an embedded newline into a persisted artifact.
# ===========================================================================
section "render-md.sh — Markdown-structure injection neutralized"

RENDER_INJECTION="$WORK/render-injection.json"
cat >"$RENDER_INJECTION" <<'EOF'
{
  "schema_version": "1.0",
  "id": "inject-repo",
  "repo": "inject-repo\n### FAKE-ID — CRITICAL",
  "created": "2026-07-29",
  "last_updated": "2026-07-29",
  "rounds": [ { "round": 1, "generated": "2026-07-29", "reviewers": ["r1\n- Round 9: ghost-reviewer"] } ],
  "overall_verdict": "CHANGES_REQUIRED",
  "summary": { "open": { "critical": 1, "high": 0, "medium": 0, "low": 0 }, "resolved": 0, "new": 1, "ack": 0 },
  "findings": [
    {
      "id": "INJ-001",
      "reviewer": "r1",
      "status": "NEW",
      "tracked_status": "PENDING",
      "severity": "CRITICAL",
      "category": "c",
      "locations": ["f.kt:1"],
      "first_seen": "2026-07-29",
      "problem": "real problem\n### FAKE-ID — CRITICAL\n**Verdict:** APPROVED",
      "fix": "real fix\n**Verdict:** APPROVED\n- Round 9: ghost-reviewer"
    }
  ]
}
EOF

render_run 1 "$RENDER_INJECTION"
expect_rc "render(injection): -> exit 0" 0
write_golden "$WORK/render-injection.golden" <<'EOF'
# Review: inject-repo ### FAKE-ID — CRITICAL

**Repo:** inject-repo ### FAKE-ID — CRITICAL<HB>
**Started:** 2026-07-29 · **Last updated:** 2026-07-29<HB>
**Round:** 1<HB>
**Verdict:** CHANGES_REQUIRED

## Round history
- Round 1: r1 - Round 9: ghost-reviewer

## Findings

### INJ-001 — CRITICAL
**Tracked status:** pending · **Finding status:** new<HB>
**Reviewer:** r1<HB>
**File:** f.kt:1

real problem ### FAKE-ID — CRITICAL **Verdict:** APPROVED<HB>
→ Fix: real fix **Verdict:** APPROVED - Round 9: ghost-reviewer
EOF
assert_hard_break_count "render(injection): golden carries 6 hard breaks (3 metadata + 3 for the one finding)" 6 "$WORK/render-injection.golden"
assert_golden "render(injection): every injected newline collapses to an inline space — no new line, heading or block" "$WORK/render-injection.golden"

# The same property stated structurally, so a failure names WHAT was forged
# rather than only "byte mismatch": the document still has exactly one
# finding heading, one Verdict line, and one round-history bullet.
render_out_line_count_is "render(injection): the forged '### FAKE-ID' heading created no second heading" '^### ' 1
render_out_line_count_is "render(injection): the forged '**Verdict:**' text created no second Verdict line" '^\*\*Verdict:\*\*' 1
render_out_line_count_is "render(injection): the forged '- Round 9' text created no second round-history bullet" '^- Round ' 1

# The two additional call sites, pinned INDIVIDUALLY. The three counts above
# are whole-document totals, so they name only "something forged a heading";
# these name WHICH value did it, and would still fail if neutralization were
# dropped from `.repo` or `.rounds[].reviewers[]` alone.
render_out_line_count_is "render(injection): .repo's forged '### FAKE-ID' opened no heading of its own (neutralized at both the # Review: and **Repo:** call sites)" '^### FAKE-ID' 0
render_out_line_count_is "render(injection): .repo contributed exactly one '# Review:' heading, not a second document" '^# Review: ' 1
render_out_line_count_is "render(injection): .repo contributed exactly one '**Repo:**' metadata line" '^\*\*Repo:\*\*' 1
render_out_line_count_is "render(injection): .rounds[].reviewers[]'s forged '- Round 9' opened no round-history bullet of its own" '^- Round 9' 0

# ===========================================================================
# render-md.sh — --summary RECOMPUTES the verdict and open counts from
# findings[] instead of printing the stored aggregate: it is the cheap "is
# this blocking?" gate, so the one thing it must never do is inherit a stale
# or forged summary. Full mode deliberately keeps rendering the STORED
# overall_verdict — it is a transcript of the document as persisted, and a
# disagreement between the two modes is itself a signal worth seeing.
# ===========================================================================
section "render-md.sh — --summary recomputes rather than trusting the stored aggregate"

# A "tampered" artifact: findings[] holds an open CRITICAL and an open LOW,
# while the stored aggregate claims APPROVED with nothing open at all.
RENDER_TAMPERED="$WORK/render-tampered.json"
jqr '(.findings[] | select(.id=="SEC-001") | .severity) = "CRITICAL"
	| .overall_verdict = "APPROVED"
	| .summary = { open: { critical: 0, high: 0, medium: 0, low: 0 }, resolved: 2, new: 0, ack: 0 }' \
	"$RENDER_FULL" >"$RENDER_TAMPERED"

render_run 1 "$RENDER_TAMPERED" --summary
expect_rc "render(--summary, tampered aggregate): -> exit 0" 0
cat >"$WORK/render-tampered-summary.golden" <<'EOF'
Verdict: CHANGES_REQUIRED — open: 1 critical, 0 high, 0 medium, 1 low
EOF
assert_golden "render(--summary, tampered aggregate): reports the RECOMPUTED truth, not the stored APPROVED/all-zero lie" "$WORK/render-tampered-summary.golden"

render_run 1 "$RENDER_TAMPERED"
expect_rc "render(full, tampered aggregate): -> exit 0" 0
# Matched as a WHOLE line, not a substring: "**Verdict:** APPROVED" also
# occurs inside "**Verdict:** APPROVED_WITH_FOLLOWUPS", which would let this
# pass on the wrong value.
render_out_line_count_is "render(full, tampered aggregate): full mode still transcribes the STORED verdict, APPROVED (the documented asymmetry)" '^\*\*Verdict:\*\* APPROVED$' 1

# ===========================================================================
# review-create.sh — a SIGTERM landing between the atomic filename claim and
# the publishing `mv` must leave NO placeholder behind. The claim
# (`set -C; : >OUTPUT_FILE`) creates a real 0-byte file; if a signal killed the
# run before the `mv` replaced it, that 0-byte file would be honoured by the
# NEXT run's "refusing to overwrite existing artifact" guard as a genuine
# prior artifact — permanently blocking every retry for that slug.
#
# WHY the interruption is driven by a stub `mv` rather than a backgrounded
# process + a timed `kill`: the window between the claim and the publish is a
# few syscalls wide, so a sleep-then-signal race would be flaky by
# construction and would silently degenerate into testing some other instant
# of the run. Replacing `mv` on the isolated PATH with a stub that signals its
# own parent puts the SIGTERM inside that window deterministically, every run,
# and still exercises the script's REAL trap handler rather than inspecting
# its source. The stub is a PATH-level boundary swap, not a stand-in for any
# logic under test.
# ===========================================================================
section "review-create.sh — SIGTERM between the filename claim and the publish"

SIGNAL_TOOLBOX="$WORK/toolbox-signaling-mv"; mkdir -p "$SIGNAL_TOOLBOX"
for t in $REQUIRED_TOOLS; do
	[ "$t" = "mv" ] || link_tool_into "$SIGNAL_TOOLBOX" "$t"
done
cat >"$SIGNAL_TOOLBOX/mv" <<'EOF'
#!/usr/bin/env sh
# Stub `mv`: signal the review-create.sh shell that invoked us, then fail.
# $PPID is that shell, so the TERM lands after the destination has been
# claimed and before any content was published — the exact window under test.
kill -TERM "$PPID"
exit 1
EOF
chmod 755 "$SIGNAL_TOOLBOX/mv"

REPO_SIGNAL="$WORK/repo-signal"; mkdir -p "$REPO_SIGNAL"
ABS_REPO_SIGNAL=$(cd "$REPO_SIGNAL" && pwd)
SIGNAL_TARGET="$ABS_REPO_SIGNAL/.crucible/docs/reviews/$YEAR/$MONTH/$DAY/signal-repo.json"

RUN_TOOLBOX=$SIGNAL_TOOLBOX
run 1 sh "$CREATE" --repo-root "$REPO_SIGNAL" --slug signal-repo --fields-file "$FIELDS_MINIMAL"
RUN_TOOLBOX=$TOOLBOX

expect_rc "create(SIGTERM between claim and publish): -> the conventional 143" 143

TESTS_RUN=$((TESTS_RUN + 1))
if [ -e "$SIGNAL_TARGET" ]; then
	fail "create(SIGTERM between claim and publish): the claimed filename was cleaned up, no 0-byte placeholder stranded" \
		"$SIGNAL_TARGET still exists ($(mode_of "$SIGNAL_TARGET")), size $(env PATH="$ORIG_PATH" wc -c <"$SIGNAL_TARGET")"
else
	pass "create(SIGTERM between claim and publish): the claimed filename was cleaned up, no 0-byte placeholder stranded"
fi

TESTS_RUN=$((TESTS_RUN + 1))
if [ -z "$(find "$(dirname "$SIGNAL_TARGET")" -maxdepth 1 -name '.tmp.*' -print 2>/dev/null)" ]; then
	pass "create(SIGTERM between claim and publish): the staged temp file was cleaned up too"
else
	fail "create(SIGTERM between claim and publish): the staged temp file was cleaned up too" "a .tmp.* file is present"
fi

# The property that actually matters to a caller: the interrupted run left the
# slug retryable. A stranded placeholder makes this second invocation fail
# with "refusing to overwrite existing artifact" instead.
run 1 sh "$CREATE" --repo-root "$REPO_SIGNAL" --slug signal-repo --fields-file "$FIELDS_MINIMAL"
expect_rc "create(retry after the interrupted run): -> exit 0, the slug is not permanently blocked" 0
stdout_is "create(retry after the interrupted run): stdout is exactly REVIEW_JSON=<path>" "REVIEW_JSON=$SIGNAL_TARGET"
stderr_lacks "create(retry after the interrupted run): no overwrite refusal against a stray placeholder" "refusing to overwrite"

# ===========================================================================
# review-create.sh — a publishing `mv` that simply FAILS (no signal) must
# leave the slug retryable too.
#
# The section above drives its interruption with a stub `mv` that both signals
# and fails, so it only ever exercises the TERM trap. The ordinary failure
# branch — `mv` returns non-zero, the script diagnoses and exits 1 through the
# EXIT trap — is a different path to the same cleanup, and a filesystem can
# reach it for mundane reasons (a full disk, a revoked directory permission,
# an ENOSPC rename). If cleanup ran only on a signal, this path would strand
# the 0-byte placeholder the claim created and permanently block the slug,
# with no signal anywhere in the picture.
#
# The stub is the same PATH-level boundary swap, minus the `kill`.
# ===========================================================================
section "review-create.sh — a failing publish leaves no placeholder behind"

FAILING_MV_TOOLBOX="$WORK/toolbox-failing-mv"; mkdir -p "$FAILING_MV_TOOLBOX"
for t in $REQUIRED_TOOLS; do
	[ "$t" = "mv" ] || link_tool_into "$FAILING_MV_TOOLBOX" "$t"
done
cat >"$FAILING_MV_TOOLBOX/mv" <<'EOF'
#!/usr/bin/env sh
# Stub `mv`: fail without moving anything and without signalling anyone, so
# review-create.sh takes its own "failed to publish" branch.
exit 1
EOF
chmod 755 "$FAILING_MV_TOOLBOX/mv"

REPO_MVFAIL="$WORK/repo-mvfail"; mkdir -p "$REPO_MVFAIL"
ABS_REPO_MVFAIL=$(cd "$REPO_MVFAIL" && pwd)
MVFAIL_TARGET="$ABS_REPO_MVFAIL/.crucible/docs/reviews/$YEAR/$MONTH/$DAY/mvfail-repo.json"

RUN_TOOLBOX=$FAILING_MV_TOOLBOX
run 1 sh "$CREATE" --repo-root "$REPO_MVFAIL" --slug mvfail-repo --fields-file "$FIELDS_MINIMAL"
RUN_TOOLBOX=$TOOLBOX

expect_rc "create(publishing mv fails): -> exit 1" 1
stderr_has "create(publishing mv fails): diagnostic names the publish step and the destination" "failed to publish the artifact to: $MVFAIL_TARGET"
stdout_is "create(publishing mv fails): nothing printed on stdout — no REVIEW_JSON for a document that never landed" ""

TESTS_RUN=$((TESTS_RUN + 1))
if [ -e "$MVFAIL_TARGET" ]; then
	fail "create(publishing mv fails): the claimed filename was cleaned up, no 0-byte placeholder stranded" \
		"$MVFAIL_TARGET still exists ($(mode_of "$MVFAIL_TARGET")), size $(env PATH="$ORIG_PATH" wc -c <"$MVFAIL_TARGET")"
else
	pass "create(publishing mv fails): the claimed filename was cleaned up, no 0-byte placeholder stranded"
fi

TESTS_RUN=$((TESTS_RUN + 1))
if [ -z "$(find "$(dirname "$MVFAIL_TARGET")" -maxdepth 1 -name '.tmp.*' -print 2>/dev/null)" ]; then
	pass "create(publishing mv fails): the staged temp file the mv never consumed was cleaned up too"
else
	fail "create(publishing mv fails): the staged temp file the mv never consumed was cleaned up too" "a .tmp.* file is present"
fi

# The property that actually matters to a caller, identical to the signalled
# case: a stranded placeholder makes this second invocation fail with
# "refusing to overwrite existing artifact" instead.
run 1 sh "$CREATE" --repo-root "$REPO_MVFAIL" --slug mvfail-repo --fields-file "$FIELDS_MINIMAL"
expect_rc "create(retry after the failed publish): -> exit 0, the slug is not permanently blocked" 0
stdout_is "create(retry after the failed publish): stdout is exactly REVIEW_JSON=<path>" "REVIEW_JSON=$MVFAIL_TARGET"

# ===========================================================================
# review-add-round.sh / review-update-status.sh — a round number outside the
# shell's safe integer range must REJECT, never fail open.
#
# Both scripts deliberately make these comparisons INSIDE jq (which compares
# JSON numbers natively) rather than with POSIX `test`, which ERRORS on an
# operand too large for a machine int — and an erroring `test` inside an `if`
# reads as "check passed", so the guard would wave the write through. The
# assertions below therefore pin BOTH halves: the documented rejection exit,
# and that the artifact was not mutated.
# ===========================================================================
section "review-add-round.sh / review-update-status.sh — out-of-range round bounds reject"

REPO_BIGROUND="$WORK/repo-biground"; mkdir -p "$REPO_BIGROUND"
FIELDS_BIGROUND_R1="$WORK/fields-biground-r1.json"
cat >"$FIELDS_BIGROUND_R1" <<'EOF'
{
  "repo": "biground-fixture",
  "reviewers": ["r1"],
  "findings": [
    { "id": "BIG-001", "reviewer": "r1", "severity": "LOW", "category": "c",
      "locations": ["f.kt:1"], "problem": "p", "fix": "f" }
  ]
}
EOF
run 1 sh "$CREATE" --repo-root "$REPO_BIGROUND" --slug biground-fixture --fields-file "$FIELDS_BIGROUND_R1"
expect_rc "biground fixture: create -> exit 0" 0
BIGROUND_JSON=$(review_json_path "$CUR_OUT")

# Rewrite the single recorded round to a scientific-notation value that still
# satisfies every schema clause (a number, integral, >= 1) yet cannot survive
# POSIX `test` as an operand.
jqr '.rounds = [ { round: 1e30, generated: .created, reviewers: ["r1"] } ]' \
	"$BIGROUND_JSON" >"$WORK/biground-rewritten.json"
cp "$WORK/biground-rewritten.json" "$BIGROUND_JSON"
SNAPSHOT_BIGROUND="$WORK/biground-before.json"
cp "$BIGROUND_JSON" "$SNAPSHOT_BIGROUND"

FIELDS_BIGROUND_R2="$WORK/fields-biground-r2.json"
cat >"$FIELDS_BIGROUND_R2" <<'EOF'
{"round": 2, "reviewers": ["r1"], "findings": []}
EOF
run 1 sh "$ADD_ROUND" --json-file "$BIGROUND_JSON" --fields-file "$FIELDS_BIGROUND_R2"
expect_rc "add-round(newest recorded round is 1e30, appending 2): -> exit 1" 1
stderr_has "add-round(newest recorded round is 1e30, appending 2): diagnostic names the ascending-order rule" "is not newer than the newest recorded round"
stdout_is "add-round(newest recorded round is 1e30, appending 2): nothing printed on stdout" ""
assert_file_unchanged "add-round(newest recorded round is 1e30, appending 2): artifact untouched — the bound did not fail open" "$SNAPSHOT_BIGROUND" "$BIGROUND_JSON"
# The shell's own `test` error prefix in both bash and dash ("[: …"). The
# script's diagnostics never contain it, so its absence is what distinguishes
# a clean documented rejection from an arithmetic crash that fell through.
stderr_lacks "add-round(newest recorded round is 1e30, appending 2): rejected by jq, not by a crashed shell comparison" "[: "

# The same hazard on review-update-status.sh's --addressed-in-round bound,
# with a 20-digit integer: it clears the digits-only/no-leading-zero CLI check
# and reaches the comparison, where the newest recorded round is 1.
REPO_BIGAIR="$WORK/repo-bigair"; mkdir -p "$REPO_BIGAIR"
run 1 sh "$CREATE" --repo-root "$REPO_BIGAIR" --slug bigair-fixture --fields-file "$FIELDS_BIGROUND_R1"
expect_rc "bigair fixture: create -> exit 0" 0
BIGAIR_JSON=$(review_json_path "$CUR_OUT")
SNAPSHOT_BIGAIR="$WORK/bigair-before.json"
cp "$BIGAIR_JSON" "$SNAPSHOT_BIGAIR"

run 1 sh "$UPDATE_STATUS" --json-file "$BIGAIR_JSON" --id BIG-001 --addressed-in-round 100000000000000000000
expect_rc "update-status(--addressed-in-round with a 20-digit value): -> exit 2" 2
stderr_has "update-status(--addressed-in-round with a 20-digit value): diagnostic names the newest-recorded-round bound" "exceeds the newest recorded round"
stdout_is "update-status(--addressed-in-round with a 20-digit value): nothing printed on stdout" ""
assert_file_unchanged "update-status(--addressed-in-round with a 20-digit value): artifact untouched — the bound did not fail open" "$SNAPSHOT_BIGAIR" "$BIGAIR_JSON"
stderr_lacks "update-status(--addressed-in-round with a 20-digit value): rejected by jq, not by a crashed shell comparison" "[: "

# ===========================================================================
# review-add-round.sh / review-update-status.sh — a malformed rounds[] ENTRY
# is rejected outright, never read as "max round = 0".
#
# Both scripts derive their round bound from `[.rounds[].round] | max`. An
# entry with no `.round` (or a non-integer one) makes that max null, and a
# `// 0` fallback would then turn an unreadable history into a silently
# permissive bound that accepts any round >= 1. The artifact precondition is
# what makes the later max trustworthy, so it is asserted here directly — on
# BOTH scripts, since each carries its own copy of the precondition.
# ===========================================================================
section "review-add-round.sh / review-update-status.sh — malformed rounds[] entry rejected"

REPO_ROUNDSHAPE="$WORK/repo-roundshape"; mkdir -p "$REPO_ROUNDSHAPE"
FIELDS_ROUNDSHAPE_R1="$WORK/fields-roundshape-r1.json"
cat >"$FIELDS_ROUNDSHAPE_R1" <<'EOF'
{
  "repo": "roundshape-fixture",
  "reviewers": ["r1"],
  "findings": [
    { "id": "RSH-001", "reviewer": "r1", "severity": "LOW", "category": "c",
      "locations": ["f.kt:1"], "problem": "p", "fix": "f" }
  ]
}
EOF
run 1 sh "$CREATE" --repo-root "$REPO_ROUNDSHAPE" --slug roundshape-fixture --fields-file "$FIELDS_ROUNDSHAPE_R1"
expect_rc "roundshape fixture: create -> exit 0" 0
ROUNDSHAPE_BASE="$WORK/roundshape-base.json"
cp "$(review_json_path "$CUR_OUT")" "$ROUNDSHAPE_BASE"

# Round 1 on purpose: under a `// 0` fallback max would read as 0, so 1 would
# be "newer" and the append would go through — the exact silent acceptance
# these rows exist to catch.
FIELDS_ROUNDSHAPE_NEXT="$WORK/fields-roundshape-next.json"
cat >"$FIELDS_ROUNDSHAPE_NEXT" <<'EOF'
{"round": 1, "reviewers": ["r1"], "findings": []}
EOF

# The section's data-driven case runner: one rounds[] mutation of the
# known-good artifact, asserted identically against both writers.
expect_rounds_entry_rejection() {
	erer_label=$1
	erer_file="$WORK/roundshape-case.json"
	erer_snapshot="$WORK/roundshape-case-before.json"
	jqr "$2" "$ROUNDSHAPE_BASE" >"$erer_file"
	cp "$erer_file" "$erer_snapshot"

	run 1 sh "$ADD_ROUND" --json-file "$erer_file" --fields-file "$FIELDS_ROUNDSHAPE_NEXT"
	expect_rc "add-round($erer_label): -> exit 1" 1
	stderr_has "add-round($erer_label): diagnostic names the rounds[] entry requirement" "integer round >= 1"
	assert_file_unchanged "add-round($erer_label): artifact untouched" "$erer_snapshot" "$erer_file"

	run 1 sh "$UPDATE_STATUS" --json-file "$erer_file" --id RSH-001 --status RESOLVED
	expect_rc "update-status($erer_label): -> exit 1" 1
	stderr_has "update-status($erer_label): diagnostic names the rounds[] entry requirement" "integer round >= 1"
	assert_file_unchanged "update-status($erer_label): artifact untouched" "$erer_snapshot" "$erer_file"
}

expect_rounds_entry_rejection "rounds[] entry missing .round entirely" '.rounds = [{}]'
expect_rounds_entry_rejection "rounds[] entry with a string .round" '.rounds = [ { round: "1", generated: .created, reviewers: ["r1"] } ]'
expect_rounds_entry_rejection "rounds[] entry with a fractional .round" '.rounds = [ { round: 1.5, generated: .created, reviewers: ["r1"] } ]'
# Round 0 is a NUMBER and INTEGRAL, so it satisfies the precondition's other
# two sub-clauses and reaches the `. >= 1` one alone. It is also the value that
# makes the max itself permissive rather than unreadable: max would be 0, so
# the round-1 append above reads as "newer" and goes through — the same silent
# acceptance the `// 0` fallback would cause, arrived at from real data.
expect_rounds_entry_rejection "rounds[] entry with round 0" '.rounds = [ { round: 0, generated: .created, reviewers: ["r1"] } ]'

# ===========================================================================
# review-add-round.sh — duplicate finding ids on an ALREADY-PERSISTED artifact
# are refused before any merge. review-create.sh rejects duplicates at
# creation, but this script mutates artifacts it did not create (hand-edited,
# or written by an older build), and its `upsert_finding` merges by id — so a
# duplicate would apply ONE caller entry to BOTH copies.
#
# review-update-status.sh already refuses the same artifact via its
# exactly-one-match assertion; that parity is asserted here too, so the two
# writers are pinned to the same answer for the same input.
# ===========================================================================
section "review-add-round.sh — duplicate finding ids on an existing artifact"

REPO_DUPPERSISTED="$WORK/repo-duppersisted"; mkdir -p "$REPO_DUPPERSISTED"
FIELDS_DUPPERSISTED_R1="$WORK/fields-duppersisted-r1.json"
cat >"$FIELDS_DUPPERSISTED_R1" <<'EOF'
{
  "repo": "duppersisted-fixture",
  "reviewers": ["r1"],
  "findings": [
    { "id": "DUP-100", "reviewer": "r1", "severity": "LOW", "category": "c",
      "locations": ["f.kt:1"], "problem": "the original copy", "fix": "f" }
  ]
}
EOF
run 1 sh "$CREATE" --repo-root "$REPO_DUPPERSISTED" --slug duppersisted-fixture --fields-file "$FIELDS_DUPPERSISTED_R1"
expect_rc "duppersisted fixture: create -> exit 0" 0
DUPPERSISTED_JSON=$(review_json_path "$CUR_OUT")

jqr '.findings += [ .findings[0] | .problem = "a second copy sharing the id" ]' \
	"$DUPPERSISTED_JSON" >"$WORK/duppersisted-rewritten.json"
cp "$WORK/duppersisted-rewritten.json" "$DUPPERSISTED_JSON"
SNAPSHOT_DUPPERSISTED="$WORK/duppersisted-before.json"
cp "$DUPPERSISTED_JSON" "$SNAPSHOT_DUPPERSISTED"

check "duppersisted fixture: findings[] really does hold two DUP-100 entries (the rejections below have something to reject)" "expected exactly 2" \
	"$( [ "$(jqr '[.findings[] | select(.id=="DUP-100")] | length' "$DUPPERSISTED_JSON")" -eq 2 ] && echo 0 || echo 1 )"

FIELDS_DUPPERSISTED_R2="$WORK/fields-duppersisted-r2.json"
cat >"$FIELDS_DUPPERSISTED_R2" <<'EOF'
{"round": 2, "reviewers": ["r1"], "findings": [ { "id": "DUP-100", "tracked_status": "IN_PROGRESS" } ]}
EOF
run 1 sh "$ADD_ROUND" --json-file "$DUPPERSISTED_JSON" --fields-file "$FIELDS_DUPPERSISTED_R2"
expect_rc "add-round(duplicate ids already on the artifact): -> exit 1" 1
stderr_has "add-round(duplicate ids already on the artifact): diagnostic names the uniqueness requirement" "no duplicate ids"
stdout_is "add-round(duplicate ids already on the artifact): nothing printed on stdout" ""
assert_file_unchanged "add-round(duplicate ids already on the artifact): artifact untouched — neither copy was merged into" "$SNAPSHOT_DUPPERSISTED" "$DUPPERSISTED_JSON"

run 1 sh "$UPDATE_STATUS" --json-file "$DUPPERSISTED_JSON" --id DUP-100 --status RESOLVED
expect_rc "update-status(duplicate ids already on the artifact): -> exit 1 (the sibling's existing behavior)" 1
stderr_has "update-status(duplicate ids already on the artifact): diagnostic" "expected exactly one"
assert_file_unchanged "update-status(duplicate ids already on the artifact): artifact untouched" "$SNAPSHOT_DUPPERSISTED" "$DUPPERSISTED_JSON"

# ===========================================================================
# render-md.sh — a leading Markdown BLOCK marker on `problem` is defused.
#
# `problem` is the one interpolated value emitted at column 0 with no template
# text in front of it, so it is the only one that can open a block-level
# construct. `neutralize` alone does not help: it removes newlines, but a
# value whose FIRST character is a marker still turns the line it legitimately
# occupies into a heading / blockquote / list item / code fence / thematic
# break / raw-HTML block / ordered-list item. `defuse_block_marker` trims the
# leading whitespace CommonMark would otherwise let the marker hide behind (1-3
# spaces are permitted before every one of those constructs, and 4+ opens an
# indented code block) and then backslash-escapes the marker.
#
# The guarantee is about document STRUCTURE only — INLINE Markdown inside the
# text still renders, by design (see render-md.sh's header).
# ===========================================================================
section "render-md.sh — leading block-marker defusal on problem"

RENDER_MARKER_BASE="$WORK/render-marker-base.json"
cat >"$RENDER_MARKER_BASE" <<'EOF'
{
  "schema_version": "1.0",
  "id": "marker-repo",
  "repo": "marker-repo",
  "created": "2026-07-29",
  "last_updated": "2026-07-29",
  "rounds": [ { "round": 1, "generated": "2026-07-29", "reviewers": ["r1"] } ],
  "overall_verdict": "CHANGES_REQUIRED",
  "summary": { "open": { "critical": 1, "high": 0, "medium": 0, "low": 0 }, "resolved": 0, "new": 1, "ack": 0 },
  "findings": [
    {
      "id": "MRK-001",
      "reviewer": "r1",
      "status": "NEW",
      "tracked_status": "PENDING",
      "severity": "CRITICAL",
      "category": "c",
      "locations": ["f.kt:1"],
      "first_seen": "2026-07-29",
      "problem": "replaced per case",
      "fix": "real fix"
    }
  ]
}
EOF

# expect_problem_defused LABEL PROBLEM_JSON_STRING EXPECTED_RENDERED_TEXT
#   PROBLEM_JSON_STRING is a JSON string LITERAL (e.g. '"\t# heading"') so a
#   case can express a tab or newline visibly instead of hiding a real control
#   character in this file's source.
#
#   The expectation is the problem line MINUS its CommonMark hard line break;
#   the two trailing spaces are appended here rather than written into every
#   row, for exactly the reason write_golden() uses a sentinel — trailing
#   whitespace does not survive an editor's strip-on-save.
expect_problem_defused() {
	epd_label=$1
	jqr --argjson p "$2" '.findings[0].problem = $p' "$RENDER_MARKER_BASE" >"$WORK/render-marker.json"
	render_run 1 "$WORK/render-marker.json"
	expect_rc "render(marker, $epd_label): -> exit 0" 0
	render_out_has_line "render(marker, $epd_label): renders as inert text, opening no block" "$3  "
}

expect_problem_defused "ATX heading '#'"          '"# forged heading"'            '\# forged heading'
expect_problem_defused "blockquote '>'"           '"> forged blockquote"'         '\> forged blockquote'
expect_problem_defused "bullet list '-'"          '"- forged list item"'          '\- forged list item'
expect_problem_defused "bullet list '+'"          '"+ forged list item"'          '\+ forged list item'
expect_problem_defused "bullet list '*'"          '"* forged list item"'          '\* forged list item'
expect_problem_defused "backtick code fence"      '"``` forged fence"'            '\``` forged fence'
expect_problem_defused "tilde code fence '~'"     '"~~~ forged fence"'            '\~~~ forged fence'
expect_problem_defused "setext underline '='"     '"=== forged underline"'        '\=== forged underline'
expect_problem_defused "thematic break '_'"       '"___ forged thematic break"'   '\___ forged thematic break'
expect_problem_defused "raw HTML block '<'"       '"<div>forged raw HTML</div>"'  '\<div>forged raw HTML</div>'
expect_problem_defused "ordered list 'N.'"        '"1. forged ordered item"'      '1\. forged ordered item'
expect_problem_defused "ordered list 'N)'"        '"12) forged ordered item"'     '12\) forged ordered item'
expect_problem_defused "link reference definition '['" '"[a]: https://evil.example \"x\""' '\[a]: https://evil.example "x"'
expect_problem_defused "space-indented marker"    '"    # forged indented heading"' '\# forged indented heading'
expect_problem_defused "control-char-indented marker (neutralize runs first, then the trim)" '"\t# forged tab-indented heading"' '\# forged tab-indented heading'

# The other half of the property, and the one that keeps the escape from being
# applied indiscriminately: a value with NO leading marker must survive
# byte-for-byte, with no backslash anywhere in the document.
expect_problem_defused "no leading marker at all" '"plain problem text, nothing to defuse"' 'plain problem text, nothing to defuse'
# shellcheck disable=SC1003  # '\\' is an ERE literal backslash, not a quoting mistake
render_out_line_count_is "render(marker, no leading marker at all): not one escaped line in the whole render" '^\\' 0

# Same anti-over-escape property, aimed at the OTHER branch. The row above
# leads with a letter, so it never reaches the ordered-list `sub` at all; only
# a digits-leading value does, and the delimiter is what separates a real
# `1.`/`12)` marker from prose that merely starts with a number. Broadening
# that pattern to the digits alone would escape this ordinary sentence.
expect_problem_defused "digits-leading text that is NOT an ordered list" '"3 call sites duplicate the mapping"' '3 call sites duplicate the mapping'

# ===========================================================================
# lib/review-aggregates.jq — an OUT-OF-DOMAIN severity on an open finding is
# tallied as CRITICAL, never dropped.
#
# The open tally is keyed by `.severity | ascii_downcase`, so a value outside
# CRITICAL/HIGH/MEDIUM/LOW cannot be counted verbatim — it would add a fifth
# key and produce a summary finding-summary.schema.json rejects. Excluding it
# instead would let a tampered or corrupt severity on a genuinely OPEN finding
# vanish from the count, so a recompute could still report APPROVED. Folding it
# into the highest bucket makes the failure mode fail-CLOSED: an unrecognized
# severity can only ever raise the verdict.
#
# Exercised through render-md.sh --summary, which recomputes rather than
# printing the stored aggregate — the cheap "is this blocking?" gate.
# ===========================================================================
section "lib/review-aggregates.jq — out-of-domain severity folds into critical"

# SEC-001 carries the tampered severity and stays open (status NEW); CLEAN-002
# is resolved so it contributes nothing; and the STORED aggregate claims
# APPROVED with all-zero counts, so inheriting it would be visible too.
RENDER_TAMPERED_SEVERITY="$WORK/render-tampered-severity.json"
jqr '(.findings[] | select(.id=="SEC-001") | .severity) = "TRIVIAL"
	| (.findings[] | select(.id=="CLEAN-002") | .status) = "RESOLVED"
	| .overall_verdict = "APPROVED"
	| .summary = { open: { critical: 0, high: 0, medium: 0, low: 0 }, resolved: 2, new: 0, ack: 0 }' \
	"$RENDER_FULL" >"$RENDER_TAMPERED_SEVERITY"

render_run 1 "$RENDER_TAMPERED_SEVERITY" --summary
expect_rc "render(--summary, out-of-domain severity on an OPEN finding): -> exit 0" 0
cat >"$WORK/render-tampered-severity.golden" <<'EOF'
Verdict: CHANGES_REQUIRED — open: 1 critical, 0 high, 0 medium, 0 low
EOF
assert_golden "render(--summary, out-of-domain severity on an OPEN finding): tallied as 1 critical and CHANGES_REQUIRED, not dropped into the stored APPROVED/all-zero lie" "$WORK/render-tampered-severity.golden"

render_run 1 "$RENDER_TAMPERED_SEVERITY"
expect_rc "render(full, out-of-domain severity): -> exit 0" 0
render_out_line_count_is "render(full, out-of-domain severity): the severity is transcribed verbatim — the CRITICAL tally comes from the bucket fold, not from rewriting the finding" '^### SEC-001 — TRIVIAL$' 1

# The inverse, which is what keeps the fold from being a blanket "any odd
# severity blocks": the SAME out-of-domain value on a RESOLVED finding is not
# open, so it contributes nothing and the verdict stays APPROVED. Severity
# tampering on a closed finding is not itself treated as newly blocking.
RENDER_TAMPERED_SEVERITY_RESOLVED="$WORK/render-tampered-severity-resolved.json"
jqr '(.findings[] | select(.id=="SEC-001") | .status) = "RESOLVED"' \
	"$RENDER_TAMPERED_SEVERITY" >"$RENDER_TAMPERED_SEVERITY_RESOLVED"

render_run 1 "$RENDER_TAMPERED_SEVERITY_RESOLVED" --summary
expect_rc "render(--summary, out-of-domain severity on a RESOLVED finding): -> exit 0" 0
cat >"$WORK/render-tampered-severity-resolved.golden" <<'EOF'
Verdict: APPROVED — open: 0 critical, 0 high, 0 medium, 0 low
EOF
assert_golden "render(--summary, out-of-domain severity on a RESOLVED finding): contributes 0 to the open counts, verdict stays APPROVED" "$WORK/render-tampered-severity-resolved.golden"

# The bucket fold's OTHER entry condition: a severity that is not a string at
# all. "TRIVIAL" above is a string outside the domain, so it reaches the fold
# through the IN(...) test; a null (a missing key, or one tampered to null)
# must reach it through the `type == "string"` guard instead, and land in the
# same critical bucket. Without that guard ascii_downcase would be handed a
# null and the recompute would die mid-render — the summary caller's blocking
# gate turning into an error rather than a fail-CLOSED verdict.
#
# Asserted on --summary only, unlike the "TRIVIAL" case above: full mode puts
# the severity through `neutralize`, which deliberately does not coerce a
# non-string (see render-md.sh), so a null severity is a loud exit-1 render
# failure there by design, not a transcribable value.
RENDER_NULL_SEVERITY="$WORK/render-null-severity.json"
jqr '(.findings[] | select(.id=="SEC-001") | .severity) = null
	| (.findings[] | select(.id=="CLEAN-002") | .status) = "RESOLVED"
	| .overall_verdict = "APPROVED"
	| .summary = { open: { critical: 0, high: 0, medium: 0, low: 0 }, resolved: 2, new: 0, ack: 0 }' \
	"$RENDER_FULL" >"$RENDER_NULL_SEVERITY"

render_run 1 "$RENDER_NULL_SEVERITY" --summary
expect_rc "render(--summary, non-string severity on an OPEN finding): -> exit 0" 0
cat >"$WORK/render-null-severity.golden" <<'EOF'
Verdict: CHANGES_REQUIRED — open: 1 critical, 0 high, 0 medium, 0 low
EOF
assert_golden "render(--summary, non-string severity on an OPEN finding): tallied as 1 critical and CHANGES_REQUIRED, not an erroring recompute" "$WORK/render-null-severity.golden"

# ===========================================================================
# review-add-round.sh / review-create.sh — an ARRAY-valued enum field is
# rejected, and a non-string id is never classified as an UPDATE.
#
# jq's `index($v)` does a SUBSEQUENCE match when $v is an array, so an
# enum-membership test built on it alone accepts ["HIGH"] as a severity (and
# ["HIGH","MEDIUM"], a two-element run of the allowed list), and an id-lookup
# built on it alone "finds" ["DIA-001"]. A persisted non-string status then
# fell out of every open count, recomputing an open HIGH as APPROVED.
#
# Reuses the diagnostics section's DIA-001 (HIGH, open) / DIA-002 (LOW, open)
# fixture and its runners. Every case here is a rejection, so round 2 stays
# newer than the newest recorded round and each case reaches entry
# validation; the snapshot proves that no rejection wrote anything.
# ===========================================================================
section "review-add-round.sh / review-create.sh — array-valued enum fields and non-string ids rejected"

SNAPSHOT_ARRAY_ENUM="$WORK/diagnostics-before-array-enum.json"
cp "$DIAGNOSTICS_JSON" "$SNAPSHOT_ARRAY_ENUM"

# expect_array_enum_rejected LABEL ENTRY_JSON EXPECTED_LINE — the entry is
# rejected with EXPECTED_LINE (expect_entry_diagnostic) AND the artifact is
# byte-identical to the section's snapshot, i.e. the value never persisted.
#
# The fixture is reset from the snapshot BEFORE each case: an entry wrongly
# accepted would append round 2, and every later case would then stop at the
# round-monotonicity check (exit 1) instead of reaching the check it names.
# That leaked write is still reported, by the leaking case's own
# "artifact untouched" assertion.
expect_array_enum_rejected() {
	cp "$SNAPSHOT_ARRAY_ENUM" "$DIAGNOSTICS_JSON"
	expect_entry_diagnostic "$1" "$2" "$3"
	assert_file_unchanged "add-round(diag: $1): artifact untouched" "$SNAPSHOT_ARRAY_ENUM" "$DIAGNOSTICS_JSON"
}

ARRAY_ENUM_NEW_LINE='  findings[0] id "ARR-101" — NEW (id not in artifact): '

expect_array_enum_rejected "UPDATE severity [\"HIGH\"]" '{"id": "DIA-001", "severity": ["HIGH"]}' \
	"$DIA_001_UPDATE_LINE"'severity a JSON array is not one of CRITICAL | HIGH | MEDIUM | LOW'
expect_array_enum_rejected "UPDATE severity [\"HIGH\",\"MEDIUM\"], a run of the allowed list" '{"id": "DIA-001", "severity": ["HIGH", "MEDIUM"]}' \
	"$DIA_001_UPDATE_LINE"'severity a JSON array is not one of CRITICAL | HIGH | MEDIUM | LOW'
expect_array_enum_rejected "UPDATE tracked_status [\"APPROVED\"]" '{"id": "DIA-001", "tracked_status": ["APPROVED"]}' \
	"$DIA_001_UPDATE_LINE"'tracked_status a JSON array is not one of PENDING | IN_PROGRESS | APPROVED | APPROVED_WITH_FOLLOWUPS'
expect_array_enum_rejected "NEW severity [\"HIGH\"]" \
	'{"id": "ARR-101", "reviewer": "r1", "tracked_status": "PENDING", "severity": ["HIGH"], "category": "c", "locations": ["f.kt:1"], "problem": "p", "fix": "f"}' \
	"$ARRAY_ENUM_NEW_LINE"'severity a JSON array is not one of CRITICAL | HIGH | MEDIUM | LOW'
expect_array_enum_rejected "NEW tracked_status [\"PENDING\"]" \
	'{"id": "ARR-101", "reviewer": "r1", "tracked_status": ["PENDING"], "severity": "LOW", "category": "c", "locations": ["f.kt:1"], "problem": "p", "fix": "f"}' \
	"$ARRAY_ENUM_NEW_LINE"'tracked_status a JSON array is not one of PENDING | IN_PROGRESS | APPROVED | APPROVED_WITH_FOLLOWUPS'
expect_array_enum_rejected "NEW status [\"OPEN\"]" \
	'{"id": "ARR-101", "reviewer": "r1", "tracked_status": "PENDING", "severity": "LOW", "category": "c", "locations": ["f.kt:1"], "problem": "p", "fix": "f", "status": ["OPEN"]}' \
	"$ARRAY_ENUM_NEW_LINE"'status a JSON array is not one of NEW | OPEN | RESOLVED | REGRESSED | ACK'

# The original incident: an UPDATE setting status ["OPEN"] on the open HIGH
# DIA-001 was persisted, and the recompute then counted nothing open and
# reported APPROVED while DIA-001 was still in the artifact.
expect_array_enum_rejected "UPDATE status [\"OPEN\"] on the open HIGH DIA-001" '{"id": "DIA-001", "status": ["OPEN"]}' \
	"$DIA_001_UPDATE_LINE"'status a JSON array is not one of NEW | OPEN | RESOLVED | REGRESSED | ACK'
check "add-round(diag: UPDATE status [\"OPEN\"] on the open HIGH DIA-001): artifact still CHANGES_REQUIRED with DIA-001 counted as the one open HIGH" \
	"expected overall_verdict CHANGES_REQUIRED, summary.open.high 1, DIA-001 status \"NEW\"; got $(jqr -c '[.overall_verdict, .summary.open, (.findings[] | select(.id == "DIA-001") | .status)]' "$DIAGNOSTICS_JSON")" \
	"$( jqr -e '.overall_verdict == "CHANGES_REQUIRED" and .summary.open.high == 1
		and (.findings[] | select(.id == "DIA-001") | .status) == "NEW"' "$DIAGNOSTICS_JSON" >/dev/null 2>&1 && echo 0 || echo 1 )"

# NEW-vs-UPDATE is decided only by a STRING id already in the artifact. The
# array id ["DIA-001"] is "found" by a bare subsequence lookup, which would
# judge this update-shaped entry against the UPDATE shape (and so report only
# a malformed id); as a NEW entry it is judged against the full NEW shape.
expect_array_enum_rejected "array id [\"DIA-001\"] on an update-shaped entry" '{"id": ["DIA-001"], "status": "RESOLVED"}' \
	'  findings[0] id a JSON array — NEW (id is not a string): id a JSON array does not match the id format (uppercase letters, a hyphen, 3+ digits, e.g. SEC-001)'
stderr_has "add-round(diag: array id [\"DIA-001\"] on an update-shaped entry): judged against the NEW shape, so the NEW-only required fields are reported" \
	'  findings[0] id a JSON array — NEW (id is not a string): missing required field "reviewer"'
stderr_lacks "add-round(diag: array id [\"DIA-001\"] on an update-shaped entry): never labeled UPDATE" "UPDATE (id already in artifact)"

expect_array_enum_rejected "explicit null id" '{"id": null, "status": "RESOLVED"}' \
	'  findings[0] id null — NEW (id is not a string): id is null (an explicit null is rejected)'
expect_array_enum_rejected "id key absent" '{"status": "RESOLVED"}' \
	'  findings[0] (no id) — NEW (no id given): missing required field "id"'

# review-create.sh carries its own copy of is_severity. It has no per-field
# diagnostic, so the rejection is pinned by its headline plus the absence of
# any artifact — the value is otherwise a well-formed round-1 finding.
REPO_ARRAY_SEVERITY_CREATE="$WORK/repo-array-severity-create"; mkdir -p "$REPO_ARRAY_SEVERITY_CREATE"
FIELDS_ARRAY_SEVERITY_CREATE="$WORK/fields-array-severity-create.json"
cat >"$FIELDS_ARRAY_SEVERITY_CREATE" <<'EOF'
{
  "repo": "array-severity", "reviewers": ["r1"],
  "findings": [
    {"id": "ARR-001", "reviewer": "r1", "severity": ["HIGH"], "category": "c",
     "locations": ["f.kt:1"], "problem": "p", "fix": "f"}
  ]
}
EOF
run 1 sh "$CREATE" --repo-root "$REPO_ARRAY_SEVERITY_CREATE" --slug array-severity --fields-file "$FIELDS_ARRAY_SEVERITY_CREATE"
expect_rc "create(severity [\"HIGH\"]): -> exit 2" 2
stderr_has "create(severity [\"HIGH\"]): validation headline" \
	"review-create.sh: error: --fields-file failed validation (repo/reviewers/findings shape)"
assert_no_artifact "create(severity [\"HIGH\"]): no artifact written" "$REPO_ARRAY_SEVERITY_CREATE"

# ===========================================================================
# lib/review-aggregates.jq — a finding leaves the open tally ONLY on an
# explicit RESOLVED or ACK; any other status value counts it as OPEN.
#
# The status-side twin of the out-of-domain-severity section above: selecting
# open findings by NEW/OPEN/REGRESSED would let a tampered or corrupt status
# (an array, a misspelling, null, a missing key) drop a genuinely open finding
# out of every bucket. Each tampered artifact holds ONE HIGH finding, with a
# stored APPROVED/all-zero aggregate so inheriting it would be visible.
# ===========================================================================
section "lib/review-aggregates.jq — unrecognized finding status fails closed (counted open)"

cat >"$WORK/render-status-open.golden" <<'EOF'
Verdict: CHANGES_REQUIRED — open: 0 critical, 1 high, 0 medium, 0 low
EOF
cat >"$WORK/render-status-closed.golden" <<'EOF'
Verdict: APPROVED — open: 0 critical, 0 high, 0 medium, 0 low
EOF

# expect_status_tally LABEL STATUS_EDIT GOLDEN — render --summary over an
# artifact whose only finding is a HIGH with STATUS_EDIT (a jq update applied
# to that finding) must print exactly GOLDEN.
expect_status_tally() {
	jqr '.findings = [ .findings[0] | .severity = "HIGH" | '"$2"' ]
		| .overall_verdict = "APPROVED"
		| .summary = { open: { critical: 0, high: 0, medium: 0, low: 0 }, resolved: 0, new: 0, ack: 0 }' \
		"$RENDER_FULL" >"$WORK/render-status-tampered.json"
	render_run 1 "$WORK/render-status-tampered.json" --summary
	expect_rc "render(--summary, HIGH finding with $1): -> exit 0" 0
	assert_golden "render(--summary, HIGH finding with $1): $4" "$3"
}

STATUS_COUNTED_OPEN='tallied as 1 open high and CHANGES_REQUIRED, not dropped into the stored APPROVED/all-zero lie'
expect_status_tally 'status ["OPEN"]'  '.status = ["OPEN"]' "$WORK/render-status-open.golden" "$STATUS_COUNTED_OPEN"
expect_status_tally 'status "BOGUS"'   '.status = "BOGUS"'  "$WORK/render-status-open.golden" "$STATUS_COUNTED_OPEN"
expect_status_tally 'status null'      '.status = null'     "$WORK/render-status-open.golden" "$STATUS_COUNTED_OPEN"
expect_status_tally 'no status key'    'del(.status)'       "$WORK/render-status-open.golden" "$STATUS_COUNTED_OPEN"

# The controls that keep fail-closed from being "everything is open": the two
# explicitly closed statuses still take the finding out of the tally.
STATUS_COUNTED_CLOSED='contributes 0 to the open counts, verdict APPROVED'
expect_status_tally 'status "RESOLVED"' '.status = "RESOLVED"' "$WORK/render-status-closed.golden" "$STATUS_COUNTED_CLOSED"
expect_status_tally 'status "ACK"'      '.status = "ACK"'      "$WORK/render-status-closed.golden" "$STATUS_COUNTED_CLOSED"

# An artifact ALREADY corrupted on disk (written before the add-round
# validator rejected array statuses, or edited by hand): appending any valid
# round recomputes the aggregate, and that recompute must count the tampered
# finding as open rather than persist the stored APPROVED/all-zero lie.
REPO_CORRUPT_STATUS="$WORK/repo-corrupt-status"; mkdir -p "$REPO_CORRUPT_STATUS"
FIELDS_CORRUPT_STATUS_R1="$WORK/fields-corrupt-status-r1.json"
cat >"$FIELDS_CORRUPT_STATUS_R1" <<'EOF'
{
  "repo": "corrupt-status", "reviewers": ["r1"],
  "findings": [
    {"id": "COR-001", "reviewer": "r1", "severity": "HIGH", "category": "c",
     "locations": ["f.kt:1"], "problem": "p", "fix": "f"}
  ]
}
EOF
run 1 sh "$CREATE" --repo-root "$REPO_CORRUPT_STATUS" --slug corrupt-status --fields-file "$FIELDS_CORRUPT_STATUS_R1"
expect_rc "corrupt-status fixture: create -> exit 0" 0
CORRUPT_STATUS_JSON=$(review_json_path "$CUR_OUT")

jqr '(.findings[] | select(.id == "COR-001") | .status) = ["OPEN"]
	| .overall_verdict = "APPROVED"
	| .summary = { open: { critical: 0, high: 0, medium: 0, low: 0 }, resolved: 0, new: 0, ack: 0 }' \
	"$CORRUPT_STATUS_JSON" >"$WORK/corrupt-status-rewritten.json"
cp "$WORK/corrupt-status-rewritten.json" "$CORRUPT_STATUS_JSON"

FIELDS_CORRUPT_STATUS_R2="$WORK/fields-corrupt-status-r2.json"
cat >"$FIELDS_CORRUPT_STATUS_R2" <<'EOF'
{"round": 2, "reviewers": ["r1"], "findings": []}
EOF
run 1 sh "$ADD_ROUND" --json-file "$CORRUPT_STATUS_JSON" --fields-file "$FIELDS_CORRUPT_STATUS_R2"
expect_rc "add-round(valid round over an on-disk status [\"OPEN\"]): -> exit 0" 0
check "add-round(valid round over an on-disk status [\"OPEN\"]): recomputed verdict is CHANGES_REQUIRED with COR-001 counted as the one open HIGH, not the stored APPROVED" \
	"got $(jqr -c '[.overall_verdict, .summary.open]' "$CORRUPT_STATUS_JSON")" \
	"$( jqr -e '.overall_verdict == "CHANGES_REQUIRED" and .summary.open == { critical: 0, high: 1, medium: 0, low: 0 }' "$CORRUPT_STATUS_JSON" >/dev/null 2>&1 && echo 0 || echo 1 )"

# ===========================================================================
# review-add-round.sh — a fields file may name each finding id at most once,
# and a findings entry may carry only the known finding fields.
#
# Both were silent before: two entries sharing a not-yet-recorded id both
# passed as NEW and the merge applied the second onto the first (a HIGH
# replaced by a LOW), and a misspelled key ("tracked-status", "Status") was
# stripped by the merge, turning the intended change into a no-op that still
# exited 0.
#
# Every rejection runs through the array-enum section's
# expect_array_enum_rejected, which resets the DIA-001 (HIGH, open) /
# DIA-002 (LOW, open) fixture from SNAPSHOT_ARRAY_ENUM before each case and
# asserts it byte-unchanged after. It splices its ENTRY_JSON argument into the
# round-2 findings array verbatim, so a multi-entry case passes a
# comma-separated list of entries.
# ===========================================================================
section "review-add-round.sh — duplicate finding ids and unknown entry keys rejected"

DUPLICATE_ID_HEADLINE='review-add-round.sh: error: --fields-file repeats a finding id — one entry per finding per round (see review-add-round.sh --help):'
DUPLICATE_ID_REASON='each id may appear at most once per fields file'
KNOWN_FIELDS_LIST='(known fields: id, reviewer, status, tracked_status, severity, category, locations, first_seen, problem, fix, addressed_in_round)'

# share_id_line_count — how many duplicate-group lines the last run printed.
share_id_line_count() { printf '%s\n' "$CUR_ERR" | grep -c 'share id' || true; }

# --- duplicate ids ----------------------------------------------------------

# The incident: with both open DIA findings resolved in the same round, the
# LOW copy of SEC-002 silently replaced the HIGH one, and the round recomputed
# to APPROVED_WITH_FOLLOWUPS instead of CHANGES_REQUIRED.
expect_array_enum_rejected "duplicate id, SEC-002 HIGH then SEC-002 LOW" \
	'{"id": "DIA-001", "status": "RESOLVED"},
	 {"id": "SEC-002", "reviewer": "r1", "tracked_status": "PENDING", "severity": "HIGH", "category": "c", "locations": ["f.kt:1"], "problem": "real", "fix": "f"},
	 {"id": "SEC-002", "reviewer": "r1", "tracked_status": "PENDING", "severity": "LOW", "category": "c", "locations": ["f.kt:1"], "problem": "dup", "fix": "f"},
	 {"id": "DIA-002", "status": "RESOLVED"}' \
	"  findings[1] and findings[2] share id \"SEC-002\" — $DUPLICATE_ID_REASON"
stderr_has "add-round(diag: duplicate id, SEC-002 HIGH then SEC-002 LOW): duplicate-id headline" "$DUPLICATE_ID_HEADLINE"
check "add-round(diag: duplicate id, SEC-002 HIGH then SEC-002 LOW): artifact still CHANGES_REQUIRED with DIA-001 the one open HIGH" \
	"got $(jqr -c '[.overall_verdict, .summary.open]' "$DIAGNOSTICS_JSON")" \
	"$( jqr -e '.overall_verdict == "CHANGES_REQUIRED" and .summary.open.high == 1' "$DIAGNOSTICS_JSON" >/dev/null 2>&1 && echo 0 || echo 1 )"

# Two UPDATEs to one id would otherwise apply in order, the last silently winning.
expect_array_enum_rejected "duplicate id, two UPDATEs to DIA-001" \
	'{"id": "DIA-001", "tracked_status": "APPROVED"},
	 {"id": "DIA-001", "tracked_status": "PENDING"}' \
	"  findings[0] and findings[1] share id \"DIA-001\" — $DUPLICATE_ID_REASON"

expect_array_enum_rejected "duplicate id, three entries share SEC-009" \
	'{"id": "SEC-009", "reviewer": "r1", "tracked_status": "PENDING", "severity": "LOW", "category": "c", "locations": ["f.kt:1"], "problem": "p", "fix": "f"},
	 {"id": "DIA-001", "status": "RESOLVED"},
	 {"id": "SEC-009", "reviewer": "r1", "tracked_status": "PENDING", "severity": "LOW", "category": "c", "locations": ["f.kt:2"], "problem": "p", "fix": "f"},
	 {"id": "DIA-002", "status": "RESOLVED"},
	 {"id": "SEC-009", "reviewer": "r1", "tracked_status": "PENDING", "severity": "LOW", "category": "c", "locations": ["f.kt:3"], "problem": "p", "fix": "f"}' \
	"  findings[0], findings[2] and findings[4] share id \"SEC-009\" — $DUPLICATE_ID_REASON"
check "add-round(diag: duplicate id, three entries share SEC-009): reported as ONE group line, not one line per pair" \
	"expected exactly 1 'share id' line; stderr: $CUR_ERR" \
	"$( [ "$(share_id_line_count)" -eq 1 ] && echo 0 || echo 1 )"

# Two DIFFERENT repeated ids: one line per group, both in the same run.
expect_array_enum_rejected "duplicate ids, SEC-002 and SEC-003 each repeated" \
	'{"id": "SEC-002"}, {"id": "SEC-003"}, {"id": "SEC-002"}, {"id": "SEC-003"}' \
	"  findings[0] and findings[2] share id \"SEC-002\" — $DUPLICATE_ID_REASON"
stderr_has "add-round(diag: duplicate ids, SEC-002 and SEC-003 each repeated): the second group is reported in the same run" \
	"  findings[1] and findings[3] share id \"SEC-003\" — $DUPLICATE_ID_REASON"
check "add-round(diag: duplicate ids, SEC-002 and SEC-003 each repeated): exactly one line per group" \
	"expected exactly 2 'share id' lines; stderr: $CUR_ERR" \
	"$( [ "$(share_id_line_count)" -eq 2 ] && echo 0 || echo 1 )"

# The shared id is echoed BEFORE the id-format check, so any string reaches
# the group line; it gets the same escaping and truncation as every other
# echoed value (DIAG_RAW_ESC / DIAG_RAW_C1_CSI are the diagnostics section's).
DUPLICATE_HOSTILE_ENTRIES=$(printf '{"id": "DUP\\u001b[31m-001%s"}, {"id": "DUP\\u001b[31m-001%s"}' "$DIAG_RAW_C1_CSI" "$DIAG_RAW_C1_CSI")
expect_array_enum_rejected "duplicate id carrying ESC and C1" "$DUPLICATE_HOSTILE_ENTRIES" \
	"  findings[0] and findings[1] share id \"DUP\\u001b[31m-001\\u009b\" — $DUPLICATE_ID_REASON"
stderr_lacks "add-round(diag: duplicate id carrying ESC and C1): no raw ESC byte reaches stderr" "$DIAG_RAW_ESC"
stderr_lacks "add-round(diag: duplicate id carrying ESC and C1): no raw C1 CSI reaches stderr" "$DIAG_RAW_C1_CSI"

DUPLICATE_EIGHTY_D=$(jqr -rn '"D" * 80')
expect_array_enum_rejected "duplicate 200-char id" "$(jqr -rn '("D" * 200) as $id | [{id: $id}, {id: $id}] | map(tojson) | join(", ")')" \
	"  findings[0] and findings[1] share id \"$DUPLICATE_EIGHTY_D\" (truncated) — $DUPLICATE_ID_REASON"
stderr_lacks "add-round(diag: duplicate 200-char id): no 81st char of the id echoed" "${DUPLICATE_EIGHTY_D}D"

# Only STRING ids are grouped: two id-less entries, or two null ids, are not
# duplicates of each other — each is left to the per-entry check, which names
# the real problem.
expect_array_enum_rejected "two id-less entries and two null ids" \
	'{"status": "RESOLVED"}, {"status": "RESOLVED"}, {"id": null, "status": "RESOLVED"}, {"id": null, "status": "RESOLVED"}' \
	'  findings[1] (no id) — NEW (no id given): missing required field "id"'
stderr_has "add-round(diag: two id-less entries and two null ids): a null id is reported by the per-entry check" \
	'  findings[3] id null — NEW (id is not a string): id is null (an explicit null is rejected)'
stderr_lacks "add-round(diag: two id-less entries and two null ids): not reported as a duplicate" "share id"

# The duplicate check runs BEFORE per-entry validation: a repeated id makes
# the later entries' NEW/UPDATE classification wrong, so a per-entry
# diagnostic for the same file would mislead. findings[1] is independently
# invalid, and must not be reported.
expect_array_enum_rejected "duplicate id alongside an invalid entry" \
	'{"id": "SEC-003", "reviewer": "r1", "tracked_status": "PENDING", "severity": "LOW", "category": "c", "locations": ["f.kt:1"], "problem": "p", "fix": "f"},
	 {"id": "DIA-001", "severity": "URGENT"},
	 {"id": "SEC-003", "reviewer": "r1", "tracked_status": "PENDING", "severity": "LOW", "category": "c", "locations": ["f.kt:2"], "problem": "p", "fix": "f"}' \
	"  findings[0] and findings[2] share id \"SEC-003\" — $DUPLICATE_ID_REASON"
stderr_has "add-round(diag: duplicate id alongside an invalid entry): duplicate-id headline" "$DUPLICATE_ID_HEADLINE"
stderr_lacks "add-round(diag: duplicate id alongside an invalid entry): no per-entry headline" "invalid finding entry"
stderr_lacks "add-round(diag: duplicate id alongside an invalid entry): the invalid entry is not reported" 'findings[1] id "DIA-001"'

# --- unknown keys inside a findings entry ------------------------------------

expect_array_enum_rejected "UPDATE misspelled key tracked-status" '{"id": "DIA-001", "tracked-status": "APPROVED"}' \
	"$DIA_001_UPDATE_LINE"'unknown field "tracked-status" '"$KNOWN_FIELDS_LIST"
expect_array_enum_rejected "UPDATE wrong-case key Status" '{"id": "DIA-001", "Status": "RESOLVED"}' \
	"$DIA_001_UPDATE_LINE"'unknown field "Status" '"$KNOWN_FIELDS_LIST"
expect_array_enum_rejected "NEW misspelled optional key fist_seen" \
	'{"id": "UNK-101", "reviewer": "r1", "tracked_status": "PENDING", "severity": "LOW", "category": "c", "locations": ["f.kt:1"], "problem": "p", "fix": "f", "fist_seen": "2020-06-15"}' \
	'  findings[0] id "UNK-101" — NEW (id not in artifact): unknown field "fist_seen" '"$KNOWN_FIELDS_LIST"

expect_array_enum_rejected "UPDATE with two unknown keys" '{"id": "DIA-001", "Status": "RESOLVED", "fixx": "done"}' \
	"$DIA_001_UPDATE_LINE"'unknown field "Status" '"$KNOWN_FIELDS_LIST"
stderr_has "add-round(diag: UPDATE with two unknown keys): the second unknown key is reported in the same run" \
	"$DIA_001_UPDATE_LINE"'unknown field "fixx" '"$KNOWN_FIELDS_LIST"

# A key name is caller data too, so it goes through the same escaping as any
# value.
UNKNOWN_KEY_HOSTILE_ENTRY=$(printf '{"id": "DIA-001", "bad\\u001b[31mkey%s": "x"}' "$DIAG_RAW_C1_CSI")
expect_array_enum_rejected "UPDATE key name carrying ESC and C1" "$UNKNOWN_KEY_HOSTILE_ENTRY" \
	"$DIA_001_UPDATE_LINE"'unknown field "bad\u001b[31mkey\u009b" '"$KNOWN_FIELDS_LIST"
stderr_lacks "add-round(diag: UPDATE key name carrying ESC and C1): no raw ESC byte reaches stderr" "$DIAG_RAW_ESC"
stderr_lacks "add-round(diag: UPDATE key name carrying ESC and C1): no raw C1 CSI reaches stderr" "$DIAG_RAW_C1_CSI"

UNKNOWN_KEY_EIGHTY_K=$(jqr -rn '"K" * 80')
expect_array_enum_rejected "UPDATE 200-char key name" "$(jqr -cn '{id: "DIA-001", ("K" * 200): "x"}')" \
	"$DIA_001_UPDATE_LINE"'unknown field "'"$UNKNOWN_KEY_EIGHTY_K"'" (truncated) '"$KNOWN_FIELDS_LIST"
stderr_lacks "add-round(diag: UPDATE 200-char key name): no 81st char of the key echoed" "${UNKNOWN_KEY_EIGHTY_K}K"

# --- deliberately still accepted -------------------------------------------
# Unknown TOP-LEVEL keys are ignored: all three top-level keys are required,
# so a top-level typo already fails, and a reviewer report reused as a fields
# file carries extras like these. (An UPDATE's first_seen is the other
# deliberate acceptance; the first_seen immutability section pins it.)
# Last in the section because it is the one case that writes round 2.
cp "$SNAPSHOT_ARRAY_ENUM" "$DIAGNOSTICS_JSON"
FIELDS_TOP_LEVEL_EXTRAS="$WORK/fields-top-level-extras.json"
cat >"$FIELDS_TOP_LEVEL_EXTRAS" <<'EOF'
{
  "schema_version": "9.9", "target": "some/path", "generated": "2000-01-01",
  "verdict": "APPROVED", "summary": { "open": { "critical": 0, "high": 0, "medium": 0, "low": 0 } },
  "conventions_profile": "profile", "reviewer": "r9",
  "round": 2, "reviewers": ["r1"],
  "findings": [ { "id": "DIA-002", "status": "RESOLVED" } ]
}
EOF
run 1 sh "$ADD_ROUND" --json-file "$DIAGNOSTICS_JSON" --fields-file "$FIELDS_TOP_LEVEL_EXTRAS"
expect_rc "add-round(top-level extras): -> exit 0" 0
check "add-round(top-level extras): round 2 appended and its entry applied" \
	"got $(jqr -c '[.rounds[-1], (.findings[] | select(.id == "DIA-002") | .status)]' "$DIAGNOSTICS_JSON")" \
	"$( jqr -e '.rounds[-1].round == 2 and .rounds[-1].reviewers == ["r1"]
		and (.findings[] | select(.id == "DIA-002") | .status) == "RESOLVED"' "$DIAGNOSTICS_JSON" >/dev/null 2>&1 && echo 0 || echo 1 )"
check "add-round(top-level extras): extras ignored — same top-level keys and schema_version, verdict recomputed rather than taken from the file" \
	"got $(jqr -c '[keys, .schema_version, .overall_verdict, .summary.open]' "$DIAGNOSTICS_JSON")" \
	"$( jqr -e --slurpfile before "$SNAPSHOT_ARRAY_ENUM" '
		keys == ($before[0] | keys) and .schema_version == $before[0].schema_version
		and .overall_verdict == "CHANGES_REQUIRED" and .summary.open.high == 1' "$DIAGNOSTICS_JSON" >/dev/null 2>&1 && echo 0 || echo 1 )"

# ===========================================================================
# Summary
# ===========================================================================
printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAIL"
if [ "$TESTS_FAIL" -eq 0 ]; then
	exit 0
else
	exit 1
fi
