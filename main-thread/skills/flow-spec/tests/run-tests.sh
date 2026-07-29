#!/usr/bin/env sh
#
# run-tests.sh — self-contained, zero-dependency POSIX test harness for the
#                flow-spec script suite (spec-create.sh, spec-approve.sh,
#                render-md.sh).
#
# WHY a hand-rolled harness (not bats), modeled on flow-inbox's own
# run-tests.sh: the scripts under test claim to run with no dependency
# beyond `jq` + coreutils, so the test harness must make the same claim.
#
# What it does:
#   * Builds an isolated PATH "toolbox" of symlinks to only the real tools
#     the scripts need, MINUS `jq` — jq lives in its OWN dir that a test
#     opts into via the `run`/`render_run` helpers' first argument, so
#     "jq absent" is exercised for real (leaving that dir off PATH).
#   * Every run of a script under test uses an isolated HOME/TMPDIR/work
#     dir via `env -i` — the real filesystem is never touched, and
#     spec-create.sh/spec-approve.sh only ever write under a fresh
#     per-test `--repo-root`/`--json-file` inside that work dir.
#   * Structural JSON assertions (required keys present, types, values) use
#     the REAL system jq (via $ORIG_PATH / the `jqr` wrapper), never the
#     isolated toolbox's — jq itself is the assertion tool, not the thing
#     under test in those checks. Fixture construction at the harness's own
#     top level (never inside `run`'s PATH-restricted env) uses the same
#     real jq, for the same reason.
#   * render-md.sh reads its document on stdin, so it gets its own
#     `render_run` helper (parallel to flow-inbox's) that redirects stdin
#     from a fixture file and keeps raw stdout in a file so golden
#     comparisons are BYTE-EXACT via `cmp` — a command-substitution capture
#     would strip the trailing newline and defeat that check.
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
CREATE="$SCRIPTS_DIR/spec-create.sh"
APPROVE="$SCRIPTS_DIR/spec-approve.sh"
RENDER="$SCRIPTS_DIR/render-md.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/flow-spec-tests.XXXXXX")
TOOLBOX="$WORK/toolbox"   # real tools (jq is NEVER here)
JQDIR="$WORK/jqbin"       # jq only (a test opts in via `run`'s first arg)
mkdir -p "$TOOLBOX" "$JQDIR" "$WORK/home"

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() { ec=$?; rm -rf "$WORK"; exit "$ec"; }
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Isolated PATH toolbox: symlink only the real tools the scripts under test
# need. jq is NEVER here (it lives only in $JQDIR, opted into per-run).
# ---------------------------------------------------------------------------
ORIG_PATH=$PATH
link_tool() {
	tp=$(PATH="$ORIG_PATH" command -v "$1" 2>/dev/null || true)
	[ -n "$tp" ] || { printf 'FATAL: required tool not found: %s\n' "$1" >&2; exit 1; }
	ln -s "$tp" "$TOOLBOX/$1"
}
for t in sh mktemp mkdir mv ln rm cat dirname basename date; do
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
#   Runs <cmd> (spec-create.sh / spec-approve.sh) under the isolated toolbox
#   PATH (+ jq only when with_jq=1), with an isolated HOME/TMPDIR. Leading
#   VAR=VALUE arguments are passed straight to `env`. Captures stdout,
#   stderr, exit code.
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
# stdin or a file arg. Assertions are the harness's own logic, not the
# thing under test.
jqr() { env PATH="$ORIG_PATH" jq "$@"; }

# ---------------------------------------------------------------------------
# render-md.sh test helpers. render-md.sh reads JSON on stdin, so `run`
# (which never redirects stdin) can't drive it — this pair feeds a fixture
# file on stdin under the same isolated env. Raw stdout is kept in a file so
# golden assertions can compare EXACT bytes (trailing newline included) via
# cmp — a command-substitution capture would strip the trailing newline and
# defeat the byte-exact check.
# ---------------------------------------------------------------------------
render_run() {
	# render_run <with_jq:0|1> <stdin_file> [extra render-md.sh args...]
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

# assert_golden NAME EXPECTED_FILE — the last render_run's stdout must be
# BYTE-IDENTICAL to EXPECTED_FILE (trailing newline included).
assert_golden() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if cmp -s "$2" "$WORK/render-out"; then pass "$1"
	else fail "$1" "byte mismatch vs golden; got:$(printf '\n')$(cat "$WORK/render-out")"; fi
}

# assert_no_stray_temp DIR PATTERN NAME — no file matching PATTERN survives
# under DIR (used for the atomic-rewrite / no-leftover-temp-file checks).
assert_no_stray_temp() {
	TESTS_RUN=$((TESTS_RUN + 1))
	found=$(find "$1" -maxdepth 1 -name "$2" -print 2>/dev/null)
	if [ -z "$found" ]; then pass "$3"
	else fail "$3" "found stray temp: $found"; fi
}

# ===========================================================================
# Fixtures (built with the REAL jq, at the harness's own top level)
# ===========================================================================
FULL_FIELDS="$WORK/full-fields.json"
jqr -n '{
  title: "Full Spec",
  repos_in_scope: [{repo:"app", tech:"Rust"}],
  goal: "Ship the full thing.",
  interface_contracts: [{repo:"app", exposes:["CLI foo"], consumes:[]}],
  non_goals: ["Not this"],
  constraints: ["Must be fast"],
  decision_log: [{fork:"sync or async?", decision:"async", why:"scales better"}],
  open_questions: ["What about retries?"]
}' >"$FULL_FIELDS"

MINIMAL_FIELDS="$WORK/minimal-fields.json"
jqr -n '{
  title: "Minimal Spec",
  repos_in_scope: [{repo:"app", tech:"Rust"}],
  goal: "Ship the minimal thing.",
  interface_contracts: [{repo:"app", exposes:[], consumes:[]}]
}' >"$MINIMAL_FIELDS"

MISSING_TITLE="$WORK/missing-title.json"
jqr 'del(.title)' "$MINIMAL_FIELDS" >"$MISSING_TITLE"
MISSING_REPOS="$WORK/missing-repos.json"
jqr 'del(.repos_in_scope)' "$MINIMAL_FIELDS" >"$MISSING_REPOS"
MISSING_GOAL="$WORK/missing-goal.json"
jqr 'del(.goal)' "$MINIMAL_FIELDS" >"$MISSING_GOAL"
MISSING_IFACE="$WORK/missing-iface.json"
jqr 'del(.interface_contracts)' "$MINIMAL_FIELDS" >"$MISSING_IFACE"
EMPTY_TITLE="$WORK/empty-title.json"
jqr '.title = ""' "$MINIMAL_FIELDS" >"$EMPTY_TITLE"
WRONG_TYPE_TITLE="$WORK/wrong-type-title.json"
jqr '.title = 123' "$MINIMAL_FIELDS" >"$WRONG_TYPE_TITLE"
WRONG_TYPE_REPOS="$WORK/wrong-type-repos.json"
jqr '.repos_in_scope = "not-an-array"' "$MINIMAL_FIELDS" >"$WRONG_TYPE_REPOS"
EMPTY_ARRAY_REPOS="$WORK/empty-array-repos.json"
jqr '.repos_in_scope = []' "$MINIMAL_FIELDS" >"$EMPTY_ARRAY_REPOS"
EMPTY_ARRAY_IFACE="$WORK/empty-array-iface.json"
jqr '.interface_contracts = []' "$MINIMAL_FIELDS" >"$EMPTY_ARRAY_IFACE"

NOT_JSON_FIELDS="$WORK/not-json.json"
printf 'not json at all {{{\n' >"$NOT_JSON_FIELDS"

NOT_OBJECT_FIELDS="$WORK/not-object.json"
printf '[]\n' >"$NOT_OBJECT_FIELDS"

# ===========================================================================
# spec-create.sh — usage / bad args
# ===========================================================================
section "spec-create.sh — usage / bad args"

run 1 sh "$CREATE" -h
expect_rc "create(usage): -h -> exit 0" 0
stdout_has "create(usage): help text" "Usage:"

run 1 sh "$CREATE" --bogus
expect_rc "create(unknown option): -> exit 2" 2
stderr_has "create(unknown option): diagnostic" "unknown option"

run 1 sh "$CREATE" --repo-root
expect_rc "create(--repo-root given with no value): -> exit 2" 2
stderr_has "create(--repo-root given with no value): diagnostic" "option --repo-root requires an argument"

REPO_OK="$WORK/repo-ok"
mkdir -p "$REPO_OK"

run 1 sh "$CREATE" --repo-root "$REPO_OK" --slug ok-slug --fields-file "$MINIMAL_FIELDS" extra-arg
expect_rc "create(extra positional arg): -> exit 2" 2
stderr_has "create(extra positional arg): diagnostic" "unexpected argument"

run 1 sh "$CREATE"
expect_rc "create(no args): -> exit 2" 2
stderr_has "create(no args): diagnostic" "--repo-root is required"

run 1 sh "$CREATE" --repo-root "$REPO_OK" --fields-file "$MINIMAL_FIELDS"
expect_rc "create(missing --slug): -> exit 2" 2
stderr_has "create(missing --slug): diagnostic" "--slug is required"

run 1 sh "$CREATE" --repo-root "$REPO_OK" --slug ok-slug
expect_rc "create(missing --fields-file): -> exit 2" 2
stderr_has "create(missing --fields-file): diagnostic" "--fields-file is required"

run 1 sh "$CREATE" --repo-root "$WORK/does-not-exist-repo" --slug ok-slug --fields-file "$MINIMAL_FIELDS"
expect_rc "create(--repo-root absent): -> exit 2" 2
stderr_has "create(--repo-root absent): diagnostic" "does not exist or is not a directory"

REPO_IS_FILE="$WORK/repo-is-a-file"
: >"$REPO_IS_FILE"
run 1 sh "$CREATE" --repo-root "$REPO_IS_FILE" --slug ok-slug --fields-file "$MINIMAL_FIELDS"
expect_rc "create(--repo-root is a file, not dir): -> exit 2" 2
stderr_has "create(--repo-root is a file, not dir): diagnostic" "does not exist or is not a directory"

# ===========================================================================
# spec-create.sh — invalid --slug
# ===========================================================================
section "spec-create.sh — invalid --slug"

for bad_slug in "Bad_Slug" "-leading-hyphen" "trailing-hyphen-" "double--hyphen" "UPPER"; do
	run 1 sh "$CREATE" --repo-root "$REPO_OK" --slug "$bad_slug" --fields-file "$MINIMAL_FIELDS"
	expect_rc "create(invalid slug '$bad_slug'): -> exit 2" 2
	stderr_has "create(invalid slug '$bad_slug'): diagnostic" "does not match"
done

# ===========================================================================
# spec-create.sh — --fields-file existence/readability
# ===========================================================================
section "spec-create.sh — --fields-file existence / readability"

run 1 sh "$CREATE" --repo-root "$REPO_OK" --slug ok-slug --fields-file "$WORK/does-not-exist.json"
expect_rc "create(--fields-file absent): -> exit 2" 2
stderr_has "create(--fields-file absent): diagnostic" "does not exist or is not readable"

UNREADABLE_FIELDS="$WORK/unreadable-fields.json"
cp "$MINIMAL_FIELDS" "$UNREADABLE_FIELDS"
chmod 000 "$UNREADABLE_FIELDS"
if [ "$(id -u)" != "0" ]; then
	run 1 sh "$CREATE" --repo-root "$REPO_OK" --slug ok-slug --fields-file "$UNREADABLE_FIELDS"
	expect_rc "create(--fields-file unreadable): -> exit 2" 2
	stderr_has "create(--fields-file unreadable): diagnostic" "does not exist or is not readable"
else
	printf '  skip create(--fields-file unreadable): running as root, permissions unenforced\n'
fi
chmod 644 "$UNREADABLE_FIELDS"

# ===========================================================================
# spec-create.sh — jq absent
# ===========================================================================
section "spec-create.sh — jq absent"

run 0 sh "$CREATE" --repo-root "$REPO_OK" --slug ok-slug --fields-file "$MINIMAL_FIELDS"
expect_rc "create(no-jq): -> exit 1" 1
stderr_has "create(no-jq): diagnostic" "jq is not installed"

# ===========================================================================
# spec-create.sh — malformed / non-object --fields-file (empirical exit code)
# ===========================================================================
section "spec-create.sh — malformed --fields-file"

run 1 sh "$CREATE" --repo-root "$REPO_OK" --slug malformed-slug --fields-file "$NOT_JSON_FIELDS"
expect_rc "create(--fields-file not valid JSON): -> exit 2 (verified empirically)" 2
stderr_has "create(--fields-file not valid JSON): diagnostic" "not valid JSON"

run 1 sh "$CREATE" --repo-root "$REPO_OK" --slug not-object-slug --fields-file "$NOT_OBJECT_FIELDS"
expect_rc "create(--fields-file is a JSON array, not object): -> exit 2 (verified empirically)" 2
stderr_has "create(--fields-file is a JSON array, not object): diagnostic" "must contain a single JSON object"

# ===========================================================================
# spec-create.sh — missing required fields
# ===========================================================================
section "spec-create.sh — missing required fields"

run 1 sh "$CREATE" --repo-root "$REPO_OK" --slug missing-title --fields-file "$MISSING_TITLE"
expect_rc "create(missing title): -> exit 2" 2
stderr_has "create(missing title): names the field" "missing required field 'title'"

run 1 sh "$CREATE" --repo-root "$REPO_OK" --slug missing-repos --fields-file "$MISSING_REPOS"
expect_rc "create(missing repos_in_scope): -> exit 2" 2
stderr_has "create(missing repos_in_scope): names the field" "missing required field 'repos_in_scope'"

run 1 sh "$CREATE" --repo-root "$REPO_OK" --slug missing-goal --fields-file "$MISSING_GOAL"
expect_rc "create(missing goal): -> exit 2" 2
stderr_has "create(missing goal): names the field" "missing required field 'goal'"

run 1 sh "$CREATE" --repo-root "$REPO_OK" --slug missing-iface --fields-file "$MISSING_IFACE"
expect_rc "create(missing interface_contracts): -> exit 2" 2
stderr_has "create(missing interface_contracts): names the field" "missing required field 'interface_contracts'"

run 1 sh "$CREATE" --repo-root "$REPO_OK" --slug empty-title --fields-file "$EMPTY_TITLE"
expect_rc "create(empty-string title, treated as missing): -> exit 2" 2
stderr_has "create(empty-string title, treated as missing): names the field" "missing required field 'title'"

run 1 sh "$CREATE" --repo-root "$REPO_OK" --slug wrong-type-title --fields-file "$WRONG_TYPE_TITLE"
expect_rc "create(title wrong type, a number not a string): -> exit 2" 2
stderr_has "create(title wrong type, a number not a string): names the field" "missing required field 'title'"

run 1 sh "$CREATE" --repo-root "$REPO_OK" --slug wrong-type-repos --fields-file "$WRONG_TYPE_REPOS"
expect_rc "create(repos_in_scope wrong type, a string not an array): -> exit 2" 2
stderr_has "create(repos_in_scope wrong type, a string not an array): names the field" "missing required field 'repos_in_scope'"

run 1 sh "$CREATE" --repo-root "$REPO_OK" --slug empty-array-repos --fields-file "$EMPTY_ARRAY_REPOS"
expect_rc "create(repos_in_scope present but an empty array): -> exit 2" 2
stderr_has "create(repos_in_scope present but an empty array): names the field" "missing required field 'repos_in_scope'"

run 1 sh "$CREATE" --repo-root "$REPO_OK" --slug empty-array-iface --fields-file "$EMPTY_ARRAY_IFACE"
expect_rc "create(interface_contracts present but an empty array): -> exit 2" 2
stderr_has "create(interface_contracts present but an empty array): names the field" "missing required field 'interface_contracts'"

# ===========================================================================
# spec-create.sh — decision_log[] per-item shape validation
# ===========================================================================
section "spec-create.sh — decision_log[] per-item shape validation"

DECISION_LOG_MISSING_WHY="$WORK/decision-log-missing-why.json"
jqr '.decision_log = [{fork:"sync or async?", decision:"async"}]' "$MINIMAL_FIELDS" >"$DECISION_LOG_MISSING_WHY"
run 1 sh "$CREATE" --repo-root "$REPO_OK" --slug decision-log-missing-why --fields-file "$DECISION_LOG_MISSING_WHY"
expect_rc "create(decision_log[] entry missing 'why'): -> exit 2" 2
stderr_has "create(decision_log[] entry missing 'why'): diagnostic" "decision_log[] entry must be an object"

DECISION_LOG_MISSING_FORK="$WORK/decision-log-missing-fork.json"
jqr '.decision_log = [{decision:"async", why:"scales better"}]' "$MINIMAL_FIELDS" >"$DECISION_LOG_MISSING_FORK"
run 1 sh "$CREATE" --repo-root "$REPO_OK" --slug decision-log-missing-fork --fields-file "$DECISION_LOG_MISSING_FORK"
expect_rc "create(decision_log[] entry missing 'fork'): -> exit 2" 2
stderr_has "create(decision_log[] entry missing 'fork'): diagnostic" "decision_log[] entry must be an object"

DECISION_LOG_MISSING_DECISION="$WORK/decision-log-missing-decision.json"
jqr '.decision_log = [{fork:"sync or async?", why:"scales better"}]' "$MINIMAL_FIELDS" >"$DECISION_LOG_MISSING_DECISION"
run 1 sh "$CREATE" --repo-root "$REPO_OK" --slug decision-log-missing-decision --fields-file "$DECISION_LOG_MISSING_DECISION"
expect_rc "create(decision_log[] entry missing 'decision'): -> exit 2" 2
stderr_has "create(decision_log[] entry missing 'decision'): diagnostic" "decision_log[] entry must be an object"

DECISION_LOG_EMPTY_WHY="$WORK/decision-log-empty-why.json"
jqr '.decision_log = [{fork:"f", decision:"d", why:""}]' "$MINIMAL_FIELDS" >"$DECISION_LOG_EMPTY_WHY"
run 1 sh "$CREATE" --repo-root "$REPO_OK" --slug decision-log-empty-why --fields-file "$DECISION_LOG_EMPTY_WHY"
expect_rc "create(decision_log[] entry has an empty-string 'why'): -> exit 2" 2
stderr_has "create(decision_log[] entry has an empty-string 'why'): diagnostic" "decision_log[] entry must be an object"

REPO_DLOG_OK="$WORK/repo-decision-log-ok"
mkdir -p "$REPO_DLOG_OK"
DECISION_LOG_WELLFORMED="$WORK/decision-log-wellformed.json"
jqr '.decision_log = [{fork:"sync or async?", decision:"async", why:"scales better"}, {fork:"REST or gRPC?", decision:"gRPC", why:"typed contract"}]' \
	"$MINIMAL_FIELDS" >"$DECISION_LOG_WELLFORMED"
run 1 sh "$CREATE" --repo-root "$REPO_DLOG_OK" --slug decision-log-ok --fields-file "$DECISION_LOG_WELLFORMED"
expect_rc "create(well-formed decision_log, all required keys present): -> exit 0 (regression)" 0
DLOG_OK_PATH=$(printf '%s\n' "$CUR_OUT" | sed -n 's/^SPEC_JSON=//p')
check "create(well-formed decision_log): passed through verbatim" "mismatch" \
	"$( [ "$(jqr -c '.decision_log' "$DLOG_OK_PATH")" = '[{"fork":"sync or async?","decision":"async","why":"scales better"},{"fork":"REST or gRPC?","decision":"gRPC","why":"typed contract"}]' ] && echo 0 || echo 1 )"

# ===========================================================================
# spec-create.sh — non_goals/constraints/open_questions[] per-item shape
# validation (each entry must be a non-empty string)
# ===========================================================================
section "spec-create.sh — non_goals/constraints/open_questions[] per-item shape validation"

NON_GOALS_BAD_ELEMENT="$WORK/non-goals-bad-element.json"
jqr '.non_goals = ["Not this", 5]' "$MINIMAL_FIELDS" >"$NON_GOALS_BAD_ELEMENT"
run 1 sh "$CREATE" --repo-root "$REPO_OK" --slug non-goals-bad-element --fields-file "$NON_GOALS_BAD_ELEMENT"
expect_rc "create(non_goals[] entry is a number, not a string): -> exit 2" 2
stderr_has "create(non_goals[] entry is a number, not a string): diagnostic" "'non_goals'[] entry must be a non-empty string"

CONSTRAINTS_BAD_ELEMENT="$WORK/constraints-bad-element.json"
jqr '.constraints = ["Must be fast", 5]' "$MINIMAL_FIELDS" >"$CONSTRAINTS_BAD_ELEMENT"
run 1 sh "$CREATE" --repo-root "$REPO_OK" --slug constraints-bad-element --fields-file "$CONSTRAINTS_BAD_ELEMENT"
expect_rc "create(constraints[] entry is a number, not a string): -> exit 2" 2
stderr_has "create(constraints[] entry is a number, not a string): diagnostic" "'constraints'[] entry must be a non-empty string"

OPEN_QUESTIONS_BAD_ELEMENT="$WORK/open-questions-bad-element.json"
jqr '.open_questions = ["What about retries?", 5]' "$MINIMAL_FIELDS" >"$OPEN_QUESTIONS_BAD_ELEMENT"
run 1 sh "$CREATE" --repo-root "$REPO_OK" --slug open-questions-bad-element --fields-file "$OPEN_QUESTIONS_BAD_ELEMENT"
expect_rc "create(open_questions[] entry is a number, not a string): -> exit 2" 2
stderr_has "create(open_questions[] entry is a number, not a string): diagnostic" "'open_questions'[] entry must be a non-empty string"

NON_GOALS_EMPTY_ELEMENT="$WORK/non-goals-empty-element.json"
jqr '.non_goals = ["ok", ""]' "$MINIMAL_FIELDS" >"$NON_GOALS_EMPTY_ELEMENT"
run 1 sh "$CREATE" --repo-root "$REPO_OK" --slug non-goals-empty-element --fields-file "$NON_GOALS_EMPTY_ELEMENT"
expect_rc "create(non_goals[] entry is an empty string): -> exit 2" 2
stderr_has "create(non_goals[] entry is an empty string): diagnostic" "'non_goals'[] entry must be a non-empty string"

REPO_OPT_ARRAYS_OK="$WORK/repo-optional-arrays-ok"
mkdir -p "$REPO_OPT_ARRAYS_OK"
WELLFORMED_OPTIONAL_ARRAYS="$WORK/wellformed-optional-arrays.json"
jqr '.non_goals = ["A", "B"] | .constraints = ["C", "D"] | .open_questions = ["E", "F"]' \
	"$MINIMAL_FIELDS" >"$WELLFORMED_OPTIONAL_ARRAYS"
run 1 sh "$CREATE" --repo-root "$REPO_OPT_ARRAYS_OK" --slug optional-arrays-ok --fields-file "$WELLFORMED_OPTIONAL_ARRAYS"
expect_rc "create(well-formed non_goals/constraints/open_questions, all-string arrays): -> exit 0 (regression)" 0
OPT_ARRAYS_OK_PATH=$(printf '%s\n' "$CUR_OUT" | sed -n 's/^SPEC_JSON=//p')
check "create(well-formed optional arrays): non_goals passed through" "mismatch" \
	"$( [ "$(jqr -c '.non_goals' "$OPT_ARRAYS_OK_PATH")" = '["A","B"]' ] && echo 0 || echo 1 )"
check "create(well-formed optional arrays): constraints passed through" "mismatch" \
	"$( [ "$(jqr -c '.constraints' "$OPT_ARRAYS_OK_PATH")" = '["C","D"]' ] && echo 0 || echo 1 )"
check "create(well-formed optional arrays): open_questions passed through" "mismatch" \
	"$( [ "$(jqr -c '.open_questions' "$OPT_ARRAYS_OK_PATH")" = '["E","F"]' ] && echo 0 || echo 1 )"

# ===========================================================================
# spec-create.sh — full fixture: all optional fields present
# ===========================================================================
section "spec-create.sh — full fixture (all optional fields present)"

REPO_FULL="$WORK/repo-full"
mkdir -p "$REPO_FULL"
run 1 sh "$CREATE" --repo-root "$REPO_FULL" --slug full-spec --fields-file "$FULL_FIELDS"
expect_rc "create(full fixture): -> exit 0" 0
stdout_has "create(full fixture): prints SPEC_JSON=" "SPEC_JSON="

FULL_SPEC_PATH=$(printf '%s\n' "$CUR_OUT" | sed -n 's/^SPEC_JSON=//p')
TESTS_RUN=$((TESTS_RUN + 1))
if [ -n "$FULL_SPEC_PATH" ] && [ -f "$FULL_SPEC_PATH" ]; then pass "create(full fixture): the printed SPEC_JSON path exists on disk"
else fail "create(full fixture): the printed SPEC_JSON path exists on disk" "path='$FULL_SPEC_PATH'"; fi

# stdout carries ONLY the SPEC_JSON= line, nothing else.
TESTS_RUN=$((TESTS_RUN + 1))
FULL_STDOUT_LINES=$(printf '%s\n' "$CUR_OUT" | wc -l | tr -d ' ')
if [ "$FULL_STDOUT_LINES" -eq 1 ] && [ "$CUR_OUT" = "SPEC_JSON=$FULL_SPEC_PATH" ]; then
	pass "create(full fixture): stdout is exactly one SPEC_JSON= line, nothing else"
else
	fail "create(full fixture): stdout is exactly one SPEC_JSON= line, nothing else" "got: $CUR_OUT"
fi

check "create(full fixture): schema_version == 1.0" "mismatch" \
	"$( [ "$(jqr -r '.schema_version' "$FULL_SPEC_PATH")" = "1.0" ] && echo 0 || echo 1 )"
check "create(full fixture): id == slug" "mismatch" \
	"$( [ "$(jqr -r '.id' "$FULL_SPEC_PATH")" = "full-spec" ] && echo 0 || echo 1 )"
check "create(full fixture): status == draft" "mismatch" \
	"$( [ "$(jqr -r '.status' "$FULL_SPEC_PATH")" = "draft" ] && echo 0 || echo 1 )"
check "create(full fixture): approved_by is ABSENT" "expected has(\"approved_by\") == false" \
	"$( jqr -e 'has("approved_by") | not' "$FULL_SPEC_PATH" >/dev/null 2>&1 && echo 0 || echo 1 )"
check "create(full fixture): approved_at is ABSENT" "expected has(\"approved_at\") == false" \
	"$( jqr -e 'has("approved_at") | not' "$FULL_SPEC_PATH" >/dev/null 2>&1 && echo 0 || echo 1 )"
check "create(full fixture): created matches YYYY-MM-DD" "does not match date shape" \
	"$( jqr -e '.created | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")' "$FULL_SPEC_PATH" >/dev/null 2>&1 && echo 0 || echo 1 )"
check "create(full fixture): non_goals passed through" "mismatch" \
	"$( [ "$(jqr -c '.non_goals' "$FULL_SPEC_PATH")" = '["Not this"]' ] && echo 0 || echo 1 )"
check "create(full fixture): constraints passed through" "mismatch" \
	"$( [ "$(jqr -c '.constraints' "$FULL_SPEC_PATH")" = '["Must be fast"]' ] && echo 0 || echo 1 )"
check "create(full fixture): open_questions passed through" "mismatch" \
	"$( [ "$(jqr -c '.open_questions' "$FULL_SPEC_PATH")" = '["What about retries?"]' ] && echo 0 || echo 1 )"
check "create(full fixture): decision_log passed through verbatim" "mismatch" \
	"$( [ "$(jqr -c '.decision_log' "$FULL_SPEC_PATH")" = '[{"fork":"sync or async?","decision":"async","why":"scales better"}]' ] && echo 0 || echo 1 )"
check "create(full fixture): repos_in_scope passed through" "mismatch" \
	"$( [ "$(jqr -c '.repos_in_scope' "$FULL_SPEC_PATH")" = '[{"repo":"app","tech":"Rust"}]' ] && echo 0 || echo 1 )"
check "create(full fixture): interface_contracts passed through" "mismatch" \
	"$( [ "$(jqr -c '.interface_contracts' "$FULL_SPEC_PATH")" = '[{"repo":"app","exposes":["CLI foo"],"consumes":[]}]' ] && echo 0 || echo 1 )"

# ===========================================================================
# spec-create.sh — minimal fixture: only required fields present
# ===========================================================================
section "spec-create.sh — minimal fixture (only required fields present)"

REPO_MIN="$WORK/repo-min"
mkdir -p "$REPO_MIN"
run 1 sh "$CREATE" --repo-root "$REPO_MIN" --slug minimal-spec --fields-file "$MINIMAL_FIELDS"
expect_rc "create(minimal fixture): -> exit 0" 0

MIN_SPEC_PATH=$(printf '%s\n' "$CUR_OUT" | sed -n 's/^SPEC_JSON=//p')
check "create(minimal fixture): status == draft" "mismatch" \
	"$( [ "$(jqr -r '.status' "$MIN_SPEC_PATH")" = "draft" ] && echo 0 || echo 1 )"
check "create(minimal fixture): approved_by is ABSENT" "expected absent" \
	"$( jqr -e 'has("approved_by") | not' "$MIN_SPEC_PATH" >/dev/null 2>&1 && echo 0 || echo 1 )"
check "create(minimal fixture): approved_at is ABSENT" "expected absent" \
	"$( jqr -e 'has("approved_at") | not' "$MIN_SPEC_PATH" >/dev/null 2>&1 && echo 0 || echo 1 )"
check "create(minimal fixture): decision_log DEFAULTS to []" "mismatch" \
	"$( [ "$(jqr -c '.decision_log' "$MIN_SPEC_PATH")" = '[]' ] && echo 0 || echo 1 )"
check "create(minimal fixture): non_goals key is OMITTED entirely (not present, not [])" "expected has(\"non_goals\") == false" \
	"$( jqr -e 'has("non_goals") | not' "$MIN_SPEC_PATH" >/dev/null 2>&1 && echo 0 || echo 1 )"
check "create(minimal fixture): constraints key is OMITTED entirely" "expected has(\"constraints\") == false" \
	"$( jqr -e 'has("constraints") | not' "$MIN_SPEC_PATH" >/dev/null 2>&1 && echo 0 || echo 1 )"
check "create(minimal fixture): open_questions key is OMITTED entirely" "expected has(\"open_questions\") == false" \
	"$( jqr -e 'has("open_questions") | not' "$MIN_SPEC_PATH" >/dev/null 2>&1 && echo 0 || echo 1 )"

# ===========================================================================
# spec-create.sh — refuses to overwrite an existing target
# ===========================================================================
section "spec-create.sh — refuses to overwrite an existing target"

REPO_DUP="$WORK/repo-dup"
mkdir -p "$REPO_DUP"
run 1 sh "$CREATE" --repo-root "$REPO_DUP" --slug dup-slug --fields-file "$MINIMAL_FIELDS"
expect_rc "create(dup, first create): -> exit 0" 0
DUP_SPEC_PATH=$(printf '%s\n' "$CUR_OUT" | sed -n 's/^SPEC_JSON=//p')
DUP_SNAPSHOT="$WORK/dup-snapshot.json"
cp "$DUP_SPEC_PATH" "$DUP_SNAPSHOT"
DUP_DIR=$(dirname "$DUP_SPEC_PATH")

run 1 sh "$CREATE" --repo-root "$REPO_DUP" --slug dup-slug --fields-file "$FULL_FIELDS"
expect_rc "create(dup, re-create over existing): -> exit 1" 1
stderr_has "create(dup, re-create over existing): diagnostic" "already exists"

TESTS_RUN=$((TESTS_RUN + 1))
if cmp -s "$DUP_SNAPSHOT" "$DUP_SPEC_PATH"; then pass "create(dup, re-create over existing): original file is byte-identical, untouched"
else fail "create(dup, re-create over existing): original file is byte-identical, untouched" "$(cmp "$DUP_SNAPSHOT" "$DUP_SPEC_PATH" 2>&1)"; fi

assert_no_stray_temp "$DUP_DIR" ".dup-slug.*" "create(dup, re-create over existing): no stray dup-slug temp file left behind"

# ===========================================================================
# spec-create.sh — the ln EEXIST atomicity path itself (not the `[ -e ]`
# fast-path above). A DANGLING symlink at the target path is invisible to
# `[ -e ]` (which follows symlinks and reports false for a broken one), so it
# reaches mktemp+ln — but the directory entry is still occupied, so the real
# `ln` hard-link-create fails with EEXIST regardless. This is the only way to
# drive the actual atomic-create guard instead of the cheaper pre-check.
# ===========================================================================
section "spec-create.sh — ln EEXIST atomicity (dangling symlink evades the -e fast-path)"

REPO_LNFAIL="$WORK/repo-lnfail"
mkdir -p "$REPO_LNFAIL"
run 1 sh "$CREATE" --repo-root "$REPO_LNFAIL" --slug ln-fail-slug --fields-file "$MINIMAL_FIELDS"
expect_rc "create(ln-fail, seed first create): -> exit 0" 0
LNFAIL_SPEC_PATH=$(printf '%s\n' "$CUR_OUT" | sed -n 's/^SPEC_JSON=//p')
LNFAIL_DIR=$(dirname "$LNFAIL_SPEC_PATH")

rm -f "$LNFAIL_SPEC_PATH"
ln -s "$WORK/does-not-exist-target" "$LNFAIL_SPEC_PATH"

TESTS_RUN=$((TESTS_RUN + 1))
if [ ! -e "$LNFAIL_SPEC_PATH" ] && [ -L "$LNFAIL_SPEC_PATH" ]; then
	pass "create(ln-fail): sanity — dangling symlink is invisible to -e but occupies the name"
else
	fail "create(ln-fail): sanity — dangling symlink is invisible to -e but occupies the name" "unexpected state at $LNFAIL_SPEC_PATH"
fi

run 1 sh "$CREATE" --repo-root "$REPO_LNFAIL" --slug ln-fail-slug --fields-file "$FULL_FIELDS"
expect_rc "create(ln-fail, real ln atomic-create fails): -> exit 1" 1
stderr_has "create(ln-fail, real ln atomic-create fails): diagnostic" "already exists"

TESTS_RUN=$((TESTS_RUN + 1))
if [ -L "$LNFAIL_SPEC_PATH" ] && [ ! -e "$LNFAIL_SPEC_PATH" ]; then
	pass "create(ln-fail, real ln atomic-create fails): target is still the untouched dangling symlink, never overwritten"
else
	fail "create(ln-fail, real ln atomic-create fails): target is still the untouched dangling symlink, never overwritten" "target was replaced"
fi

assert_no_stray_temp "$LNFAIL_DIR" ".ln-fail-slug.*" "create(ln-fail, real ln atomic-create fails): no stray temp file left behind"

# ===========================================================================
# render-md.sh needs some real spec documents; build them by hand here
# (decoupled from spec-create.sh's own output — a render-md.sh regression
# should not masquerade as a spec-create.sh one, and vice versa).
# ===========================================================================

# ===========================================================================
# spec-approve.sh — usage / bad args
# ===========================================================================
section "spec-approve.sh — usage / bad args"

run 1 sh "$APPROVE" -h
expect_rc "approve(usage): -h -> exit 0" 0
stdout_has "approve(usage): help text" "Usage:"

run 1 sh "$APPROVE" --bogus
expect_rc "approve(unknown option): -> exit 2" 2
stderr_has "approve(unknown option): diagnostic" "unknown option"

run 1 sh "$APPROVE" --json-file
expect_rc "approve(--json-file given with no value): -> exit 2" 2
stderr_has "approve(--json-file given with no value): diagnostic" "option --json-file requires an argument"

APPROVE_DRAFT_SRC="$WORK/approve-draft-src.json"
jqr -n '{
  schema_version: "1.0", id: "approve-me", title: "Approve Me",
  status: "draft", created: "2026-01-01",
  repos_in_scope: [{repo:"app", tech:"Rust"}],
  goal: "g",
  interface_contracts: [{repo:"app", exposes:[], consumes:[]}],
  decision_log: []
}' >"$APPROVE_DRAFT_SRC"

run 1 sh "$APPROVE" --json-file "$APPROVE_DRAFT_SRC" extra-arg
expect_rc "approve(extra positional arg): -> exit 2" 2
stderr_has "approve(extra positional arg): diagnostic" "unexpected argument"

run 1 sh "$APPROVE"
expect_rc "approve(no args): -> exit 2" 2
stderr_has "approve(no args): diagnostic" "--json-file is required"

run 1 sh "$APPROVE" --json-file "$APPROVE_DRAFT_SRC"
expect_rc "approve(missing --approved-by): -> exit 2" 2
stderr_has "approve(missing --approved-by): diagnostic" "--approved-by is required"

run 1 sh "$APPROVE" --json-file "$WORK/does-not-exist.json" --approved-by "the user"
expect_rc "approve(--json-file absent): -> exit 2" 2
stderr_has "approve(--json-file absent): diagnostic" "does not exist or is not readable"

UNREADABLE_APPROVE="$WORK/unreadable-approve.json"
cp "$APPROVE_DRAFT_SRC" "$UNREADABLE_APPROVE"
chmod 000 "$UNREADABLE_APPROVE"
if [ "$(id -u)" != "0" ]; then
	run 1 sh "$APPROVE" --json-file "$UNREADABLE_APPROVE" --approved-by "the user"
	expect_rc "approve(--json-file unreadable): -> exit 2" 2
	stderr_has "approve(--json-file unreadable): diagnostic" "does not exist or is not readable"
else
	printf '  skip approve(--json-file unreadable): running as root, permissions unenforced\n'
fi
chmod 644 "$UNREADABLE_APPROVE"

# ===========================================================================
# spec-approve.sh — jq absent
# ===========================================================================
section "spec-approve.sh — jq absent"

NOJQ_APPROVE="$WORK/nojq-approve.json"
cp "$APPROVE_DRAFT_SRC" "$NOJQ_APPROVE"
run 0 sh "$APPROVE" --json-file "$NOJQ_APPROVE" --approved-by "the user"
expect_rc "approve(no-jq): -> exit 1" 1
stderr_has "approve(no-jq): diagnostic" "jq is not installed"

# ===========================================================================
# spec-approve.sh — malformed / non-object --json-file (empirical exit code)
# ===========================================================================
section "spec-approve.sh — malformed --json-file"

MALFORMED_APPROVE="$WORK/malformed-approve.json"
printf 'not json at all {{{\n' >"$MALFORMED_APPROVE"
run 1 sh "$APPROVE" --json-file "$MALFORMED_APPROVE" --approved-by "the user"
expect_rc "approve(--json-file not valid JSON): -> exit 1 (verified empirically)" 1
stderr_has "approve(--json-file not valid JSON): diagnostic" "not valid JSON"

NOTOBJ_APPROVE="$WORK/notobj-approve.json"
printf '[]\n' >"$NOTOBJ_APPROVE"
run 1 sh "$APPROVE" --json-file "$NOTOBJ_APPROVE" --approved-by "the user"
expect_rc "approve(--json-file is a JSON array, not object): -> exit 1 (verified empirically)" 1
stderr_has "approve(--json-file is a JSON array, not object): diagnostic" "must contain a single JSON object"

# ===========================================================================
# spec-approve.sh — draft -> approved
# ===========================================================================
section "spec-approve.sh — draft -> approved"

APPROVE_FLIP="$WORK/approve-flip.json"
cp "$APPROVE_DRAFT_SRC" "$APPROVE_FLIP"
APPROVE_FLIP_DIR=$(dirname "$APPROVE_FLIP")

run 1 sh "$APPROVE" --json-file "$APPROVE_FLIP" --approved-by "the user"
expect_rc "approve(flip): -> exit 0" 0

# stdout carries ONLY the SPEC_JSON= line, nothing else. $APPROVE_FLIP is
# already absolute ($WORK is), so it's the exact expected value verbatim.
TESTS_RUN=$((TESTS_RUN + 1))
FLIP_STDOUT_LINES=$(printf '%s\n' "$CUR_OUT" | wc -l | tr -d ' ')
if [ "$FLIP_STDOUT_LINES" -eq 1 ] && [ "$CUR_OUT" = "SPEC_JSON=$APPROVE_FLIP" ]; then
	pass "approve(flip): stdout is exactly one SPEC_JSON= line, nothing else"
else
	fail "approve(flip): stdout is exactly one SPEC_JSON= line, nothing else" "got: $CUR_OUT"
fi

check "approve(flip): status == approved" "mismatch" \
	"$( [ "$(jqr -r '.status' "$APPROVE_FLIP")" = "approved" ] && echo 0 || echo 1 )"
check "approve(flip): approved_by == given name" "mismatch" \
	"$( [ "$(jqr -r '.approved_by' "$APPROVE_FLIP")" = "the user" ] && echo 0 || echo 1 )"
check "approve(flip): approved_at is a UTC instant" "does not match shape" \
	"$( jqr -e '.approved_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' "$APPROVE_FLIP" >/dev/null 2>&1 && echo 0 || echo 1 )"
check "approve(flip): created is UNTOUCHED" "mismatch" \
	"$( [ "$(jqr -r '.created' "$APPROVE_FLIP")" = "2026-01-01" ] && echo 0 || echo 1 )"

assert_no_stray_temp "$APPROVE_FLIP_DIR" ".approve-flip.json.*" "approve(flip): no stray rewrite temp file left behind after success"

# ===========================================================================
# spec-approve.sh — re-approving an already-approved doc
# ===========================================================================
section "spec-approve.sh — refuses to re-approve"

REAPPROVE_SNAPSHOT="$WORK/reapprove-snapshot.json"
cp "$APPROVE_FLIP" "$REAPPROVE_SNAPSHOT"

run 1 sh "$APPROVE" --json-file "$APPROVE_FLIP" --approved-by "someone else"
expect_rc "approve(re-approve, already approved): -> exit 1" 1
stderr_has "approve(re-approve, already approved): diagnostic" "refusing to approve"

TESTS_RUN=$((TESTS_RUN + 1))
if cmp -s "$REAPPROVE_SNAPSHOT" "$APPROVE_FLIP"; then pass "approve(re-approve, already approved): file is byte-identical, no changes made"
else fail "approve(re-approve, already approved): file is byte-identical, no changes made" "$(cmp "$REAPPROVE_SNAPSHOT" "$APPROVE_FLIP" 2>&1)"; fi

assert_no_stray_temp "$APPROVE_FLIP_DIR" ".approve-flip.json.*" "approve(re-approve, already approved): no stray rewrite temp file left behind after the rejected attempt"

# ===========================================================================
# spec-approve.sh — status key entirely absent (distinct from "present but
# not draft", covered above by the re-approve case)
# ===========================================================================
section "spec-approve.sh — status key entirely absent"

NO_STATUS_APPROVE="$WORK/no-status-approve.json"
jqr 'del(.status)' "$APPROVE_DRAFT_SRC" >"$NO_STATUS_APPROVE"
NO_STATUS_SNAPSHOT="$WORK/no-status-snapshot.json"
cp "$NO_STATUS_APPROVE" "$NO_STATUS_SNAPSHOT"

run 1 sh "$APPROVE" --json-file "$NO_STATUS_APPROVE" --approved-by "the user"
expect_rc "approve(status key entirely absent): -> exit 1" 1
stderr_has "approve(status key entirely absent): diagnostic shows the '<missing>' fallback" "status is '<missing>', not 'draft'"

TESTS_RUN=$((TESTS_RUN + 1))
if cmp -s "$NO_STATUS_SNAPSHOT" "$NO_STATUS_APPROVE"; then pass "approve(status key entirely absent): file is byte-identical, no changes made"
else fail "approve(status key entirely absent): file is byte-identical, no changes made" "$(cmp "$NO_STATUS_SNAPSHOT" "$NO_STATUS_APPROVE" 2>&1)"; fi

# ===========================================================================
# render-md.sh — usage / bad args
# ===========================================================================
section "render-md.sh — usage / bad args"

: >"$WORK/empty-stdin"

render_run 1 "$WORK/empty-stdin" -h
expect_rc "render(usage): -h -> exit 0" 0
stdout_has "render(usage): help text" "Usage:"

render_run 1 "$WORK/empty-stdin" --bogus
expect_rc "render(unknown option): -> exit 2" 2
stderr_has "render(unknown option): diagnostic" "unknown option"

render_run 1 "$WORK/empty-stdin" extra-arg
expect_rc "render(unexpected positional arg): -> exit 2" 2
stderr_has "render(unexpected positional arg): diagnostic" "unexpected argument"

# ===========================================================================
# render-md.sh — jq absent
# ===========================================================================
section "render-md.sh — jq absent"

render_run 0 "$WORK/empty-stdin"
expect_rc "render(no-jq): -> exit 1" 1
stderr_has "render(no-jq): diagnostic" "jq is not installed"

# ===========================================================================
# render-md.sh — invalid stdin (empirical exit codes, no partial output)
# ===========================================================================
section "render-md.sh — invalid stdin"

printf 'not json at all {{{\n' >"$WORK/render-notjson.json"
render_run 1 "$WORK/render-notjson.json"
expect_rc "render(non-JSON stdin): -> exit 1 (verified empirically)" 1
stderr_has "render(non-JSON stdin): diagnostic" "not valid JSON"
TESTS_RUN=$((TESTS_RUN + 1))
if [ -z "$CUR_OUT" ]; then pass "render(non-JSON stdin): no partial stdout"
else fail "render(non-JSON stdin): no partial stdout" "got: $CUR_OUT"; fi

printf '[]' >"$WORK/render-array.json"
render_run 1 "$WORK/render-array.json"
expect_rc "render(JSON array, not object): -> exit 1 (verified empirically)" 1
stderr_has "render(JSON array, not object): diagnostic" "must be a single spec-document JSON object"
TESTS_RUN=$((TESTS_RUN + 1))
if [ -z "$CUR_OUT" ]; then pass "render(JSON array, not object): no partial stdout"
else fail "render(JSON array, not object): no partial stdout" "got: $CUR_OUT"; fi

printf '5' >"$WORK/render-scalar.json"
render_run 1 "$WORK/render-scalar.json"
expect_rc "render(JSON scalar, not object): -> exit 1 (verified empirically)" 1
stderr_has "render(JSON scalar, not object): diagnostic" "must be a single spec-document JSON object"
TESTS_RUN=$((TESTS_RUN + 1))
if [ -z "$CUR_OUT" ]; then pass "render(JSON scalar, not object): no partial stdout"
else fail "render(JSON scalar, not object): no partial stdout" "got: $CUR_OUT"; fi

# no leftover mktemp slurp file after any of the above failure exits
assert_no_stray_temp "$WORK" "spec-render-md.*" "render(invalid stdin cases): no stray stdin-slurp temp file left behind"

# ===========================================================================
# render-md.sh — Template goldens
# ===========================================================================
section "render-md.sh — template goldens"

# Draft, minimal (no non_goals/constraints/open_questions, decision_log
# empty) — proves: no "Approved by" line while draft, the literal decision
# log placeholder, and that omitted optional keys leave NO dangling section.
DRAFT_MIN_DOC="$WORK/draft-min.json"
jqr -n '{
  schema_version:"1.0", id:"minimal-spec", title:"Minimal Spec",
  status:"draft", created:"2026-07-29",
  repos_in_scope:[{repo:"app", tech:"Rust"}],
  goal:"Ship the minimal thing.",
  interface_contracts:[{repo:"app", exposes:[], consumes:[]}],
  decision_log:[]
}' >"$DRAFT_MIN_DOC"

render_run 1 "$DRAFT_MIN_DOC"
expect_rc "render(draft, minimal): -> exit 0" 0
cat >"$WORK/draft-min.golden" <<'EOF'
# Spec: Minimal Spec

**Status:** draft
**Created:** 2026-07-29
**Repos in scope:** app (Rust)

## Goal
Ship the minimal thing.

## Interface contract

### app (Rust)
- Exposes: (none)
- Consumes: (none)

## Decision log
(none — no flow-decision panel ran for this spec)
EOF
assert_golden "render(draft, minimal): byte-exact golden" "$WORK/draft-min.golden"

TESTS_RUN=$((TESTS_RUN + 1))
if printf '%s\n' "$CUR_OUT" | grep -Fq -- "Approved by"; then
	fail "render(draft, minimal): no 'Approved by' line while draft" "found 'Approved by' in output"
else
	pass "render(draft, minimal): no 'Approved by' line while draft"
fi

for absent_heading in "## Non-goals" "## Constraints" "## Open questions"; do
	TESTS_RUN=$((TESTS_RUN + 1))
	if printf '%s\n' "$CUR_OUT" | grep -Fq -- "$absent_heading"; then
		fail "render(draft, minimal): omitted key leaves no dangling '$absent_heading' section" "heading present anyway"
	else
		pass "render(draft, minimal): omitted key leaves no dangling '$absent_heading' section"
	fi
done

# Approved, full (non_goals/constraints/open_questions present, decision_log
# with one entry) — proves: the "Approved by" line appears only now, and
# every optional section renders.
APPROVED_FULL_DOC="$WORK/approved-full.json"
jqr -n '{
  schema_version:"1.0", id:"cross-repo-job-submission",
  title:"Cross-repo job-submission contract",
  status:"approved", created:"2026-07-29",
  approved_by:"the user", approved_at:"2026-07-29T09:15:00Z",
  repos_in_scope:[{repo:"service-api", tech:"Kotlin"}, {repo:"core-engine", tech:"Rust"}],
  goal:"Let a user submit a job.",
  non_goals:["Job cancellation"],
  interface_contracts:[
    {repo:"service-api", exposes:["POST /v1/jobs"], consumes:["core-engine gRPC"]},
    {repo:"core-engine", exposes:[], consumes:[]}
  ],
  constraints:["jobId is UUID"],
  decision_log:[{fork:"sync or async?", decision:"async", why:"long running"}],
  open_questions:["progress format?"]
}' >"$APPROVED_FULL_DOC"

render_run 1 "$APPROVED_FULL_DOC"
expect_rc "render(approved, full): -> exit 0" 0
cat >"$WORK/approved-full.golden" <<'EOF'
# Spec: Cross-repo job-submission contract

**Status:** approved
**Created:** 2026-07-29
**Approved by:** the user, 2026-07-29T09:15:00Z
**Repos in scope:** service-api (Kotlin) · core-engine (Rust)

## Goal
Let a user submit a job.

## Non-goals
- Job cancellation

## Interface contract

### service-api (Kotlin)
- Exposes:
  - POST /v1/jobs
- Consumes:
  - core-engine gRPC

### core-engine (Rust)
- Exposes: (none)
- Consumes: (none)

## Constraints
- jobId is UUID

## Decision log
**sync or async?:** async — long running

## Open questions
- progress format?
EOF
assert_golden "render(approved, full): byte-exact golden" "$WORK/approved-full.golden"

TESTS_RUN=$((TESTS_RUN + 1))
if printf '%s\n' "$CUR_OUT" | grep -Fq -- "**Approved by:** the user, 2026-07-29T09:15:00Z"; then
	pass "render(approved, full): 'Approved by' line present now that status is approved"
else
	fail "render(approved, full): 'Approved by' line present now that status is approved" "not found"
fi

# interface_contracts entry whose repo has NO match in repos_in_scope — proves
# the tech-lookup fallback ($tech_by_repo[.repo] // "") renders an empty
# parenthetical rather than failing.
TECH_FALLBACK_DOC="$WORK/tech-fallback.json"
jqr -n '{
  schema_version:"1.0", id:"tech-fallback-spec", title:"Tech Fallback Spec",
  status:"draft", created:"2026-07-29",
  repos_in_scope:[{repo:"app", tech:"Rust"}],
  goal:"g",
  interface_contracts:[{repo:"unknown-repo", exposes:[], consumes:[]}],
  decision_log:[]
}' >"$TECH_FALLBACK_DOC"

render_run 1 "$TECH_FALLBACK_DOC"
expect_rc "render(interface repo with no repos_in_scope match): -> exit 0" 0
cat >"$WORK/tech-fallback.golden" <<'EOF'
# Spec: Tech Fallback Spec

**Status:** draft
**Created:** 2026-07-29
**Repos in scope:** app (Rust)

## Goal
g

## Interface contract

### unknown-repo ()
- Exposes: (none)
- Consumes: (none)

## Decision log
(none — no flow-decision panel ran for this spec)
EOF
assert_golden "render(interface repo with no repos_in_scope match): tech falls back to empty parenthetical" "$WORK/tech-fallback.golden"

# non_goals/constraints/open_questions each PRESENT but an empty array —
# proves the "(none)" body (distinct from the key being omitted entirely,
# which leaves no heading at all — see draft-min above).
EMPTY_OPTIONAL_ARRAYS_DOC="$WORK/empty-optional-arrays.json"
jqr -n '{
  schema_version:"1.0", id:"empty-optional-arrays-spec", title:"Empty Optional Arrays Spec",
  status:"draft", created:"2026-07-29",
  repos_in_scope:[{repo:"app", tech:"Rust"}],
  goal:"g",
  non_goals:[],
  interface_contracts:[{repo:"app", exposes:[], consumes:[]}],
  constraints:[],
  decision_log:[],
  open_questions:[]
}' >"$EMPTY_OPTIONAL_ARRAYS_DOC"

render_run 1 "$EMPTY_OPTIONAL_ARRAYS_DOC"
expect_rc "render(non_goals/constraints/open_questions present but empty): -> exit 0" 0
cat >"$WORK/empty-optional-arrays.golden" <<'EOF'
# Spec: Empty Optional Arrays Spec

**Status:** draft
**Created:** 2026-07-29
**Repos in scope:** app (Rust)

## Goal
g

## Non-goals
(none)

## Interface contract

### app (Rust)
- Exposes: (none)
- Consumes: (none)

## Constraints
(none)

## Decision log
(none — no flow-decision panel ran for this spec)

## Open questions
(none)
EOF
assert_golden "render(non_goals/constraints/open_questions present but empty): byte-exact golden, '(none)' body under each heading" "$WORK/empty-optional-arrays.golden"

# Non-empty decision_log with MULTIPLE entries — proves the join behavior
# (one "**fork:** decision — why" line per entry, newline-joined), isolated
# from the other optional sections.
MULTI_DECISION_DOC="$WORK/multi-decision.json"
jqr -n '{
  schema_version:"1.0", id:"multi-decision-spec", title:"Multi Decision Spec",
  status:"draft", created:"2026-07-29",
  repos_in_scope:[{repo:"app", tech:"Rust"}],
  goal:"g",
  interface_contracts:[{repo:"app", exposes:[], consumes:[]}],
  decision_log:[
    {fork:"sync or async?", decision:"async", why:"scales better"},
    {fork:"REST or gRPC?", decision:"gRPC", why:"typed contract"}
  ]
}' >"$MULTI_DECISION_DOC"

render_run 1 "$MULTI_DECISION_DOC"
expect_rc "render(multi-entry decision_log): -> exit 0" 0
cat >"$WORK/multi-decision.golden" <<'EOF'
# Spec: Multi Decision Spec

**Status:** draft
**Created:** 2026-07-29
**Repos in scope:** app (Rust)

## Goal
g

## Interface contract

### app (Rust)
- Exposes: (none)
- Consumes: (none)

## Decision log
**sync or async?:** async — scales better
**REST or gRPC?:** gRPC — typed contract
EOF
assert_golden "render(multi-entry decision_log): byte-exact golden" "$WORK/multi-decision.golden"

# No leftover mktemp slurp files after successful renders either.
assert_no_stray_temp "$WORK" "spec-render-md.*" "render(goldens): no stray stdin-slurp temp file left behind after success"

# ===========================================================================
# Summary
# ===========================================================================
printf '\n== summary ==\n'
printf 'ran %s checks, %s failed\n' "$TESTS_RUN" "$TESTS_FAIL"
[ "$TESTS_FAIL" -eq 0 ] || exit 1
printf 'ALL TESTS PASSED\n'
exit 0
