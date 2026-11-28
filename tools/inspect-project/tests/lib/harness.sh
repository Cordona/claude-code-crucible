# shellcheck shell=sh
#
# harness.sh — the runner primitives every inspect-project test suite is built
#              from: the isolated `run` core, the pass/fail counters, and the
#              assertion vocabulary.
#
# HOUSE STYLE. This is the same hand-rolled `sh` harness shape as
# procedure-jira/tests/lib/harness.sh (PATH-toolbox + `env -i` isolation +
# TESTS_RUN/TESTS_FAIL + expect_rc/stdout_has/...). It is a SIBLING COPY rather
# than a shared file on purpose: `tools/` and `project-management/` are separate
# deployables with no import path between them, and a test suite that reaches
# across that boundary breaks the moment either tree moves. The assertions this
# tool needs that Jira's does not (JSON field equality, real-git status identity,
# stub argv logs for three different stubs) live here.
#
# ISOLATION CONTRACT. Every command runs under `env -i` with an isolated HOME and
# TMPDIR and an explicit PATH. Nothing is inherited from the developer's real
# environment — which is what makes `$HOME/Applications/IntelliJ IDEA*.app`,
# `$HOME/.crucible-inspect-results` and `$HOME/Library/.../sonarlint-intellij`
# deterministic instead of "whatever this machine happens to have installed".
# The caller passes inspect-project-relevant variables (IDEA_BIN, SONAR_TOKEN,
# SONAR_HOST_URL, ...) per test as leading VAR=VALUE arguments, which `env`
# itself parses.
#
# Sourced by the test suites — never executed directly.

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

# harness_init WORK_DIR — capture the real PATH (needed to locate tools before
# any toolbox exists) and fix the isolated HOME/TMPDIR every harness_run uses.
harness_init() {
	HARNESS_WORK=$1
	HARNESS_HOME="$HARNESS_WORK/home"
	HARNESS_ORIG_PATH=$PATH
	mkdir -p "$HARNESS_HOME"
}

# link_tool TARGET_DIR TOOL — symlink the real TOOL into TARGET_DIR, resolving it
# against the ORIGINAL PATH. A missing tool is FATAL rather than a skipped test: a
# toolbox silently short one entry would fail every test downstream with an
# unrelated "not found", which is far harder to diagnose than this.
link_tool() {
	lt_target_dir=$1
	lt_tool_name=$2
	lt_tool_path=$(PATH="$HARNESS_ORIG_PATH" command -v "$lt_tool_name" 2>/dev/null || true)
	[ -n "$lt_tool_path" ] || { printf 'FATAL: required tool not found: %s\n' "$lt_tool_name" >&2; exit 1; }
	ln -s "$lt_tool_path" "$lt_target_dir/$lt_tool_name"
}

# real_tool TOOL -> the absolute path of TOOL on the ORIGINAL PATH. Used by the
# stubs that delegate to the real binary for the cases they do not fake.
real_tool() {
	rt_path=$(PATH="$HARNESS_ORIG_PATH" command -v "$1" 2>/dev/null || true)
	[ -n "$rt_path" ] || { printf 'FATAL: required tool not found: %s\n' "$1" >&2; exit 1; }
	printf '%s' "$rt_path"
}

# ---------------------------------------------------------------------------
# The runner
# ---------------------------------------------------------------------------
TESTS_RUN=0
TESTS_FAIL=0
TESTS_SKIP=0
CUR_OUT=""
CUR_ERR=""
CUR_RC=0

# harness_run PATH_VALUE [VAR=VALUE...] COMMAND... — run COMMAND under a fully
# isolated environment with PATH_VALUE as its PATH, capturing stdout/stderr/rc
# into $CUR_OUT/$CUR_ERR/$CUR_RC. `set +e` around the call is deliberate: a
# non-zero exit is the THING UNDER TEST here, not a harness failure.
#
# The forwarded variable list is two things: the stubs' control surface (see
# stubs.sh) and inspect-project's own documented environment contract ($IDEA_BIN,
# $SONAR_TOKEN, $SONAR_HOST_URL). Both are passed explicitly rather than exported,
# because `env -i` is the whole point: anything not named here does not exist
# inside the run. An EMPTY value is equivalent to unset for all three of the
# tool's variables — each is read through `${VAR:-...}`, which treats the two the
# same — so a suite selects one by assigning it and deselects it by clearing it.
harness_run() {
	hr_path=$1; shift
	set +e
	env -i \
		HOME="$HARNESS_HOME" \
		PATH="$hr_path" \
		TMPDIR="$HARNESS_WORK" \
		IDEA_BIN="${IDEA_BIN:-}" \
		SONAR_TOKEN="${SONAR_TOKEN:-}" \
		SONAR_HOST_URL="${SONAR_HOST_URL:-}" \
		UNIT_SONAR_HOST="${UNIT_SONAR_HOST:-}" \
		UNIT_SONAR_POLL_MAX_ATTEMPTS="${UNIT_SONAR_POLL_MAX_ATTEMPTS:-}" \
		UNIT_SONAR_POLL_INTERVAL="${UNIT_SONAR_POLL_INTERVAL:-}" \
		IDEA_STUB_ARGV_LOG="${IDEA_STUB_ARGV_LOG:-}" \
		IDEA_STUB_ENV_LOG="${IDEA_STUB_ENV_LOG:-}" \
		IDEA_STUB_EDIR_SRC="${IDEA_STUB_EDIR_SRC:-}" \
		IDEA_STUB_EDIR_AS_FILE="${IDEA_STUB_EDIR_AS_FILE:-}" \
		IDEA_STUB_EXIT="${IDEA_STUB_EXIT:-0}" \
		IDEA_STUB_SIGNAL_PARENT="${IDEA_STUB_SIGNAL_PARENT:-}" \
		SCANNER_STUB_ARGV_LOG="${SCANNER_STUB_ARGV_LOG:-}" \
		SCANNER_STUB_ENV_LOG="${SCANNER_STUB_ENV_LOG:-}" \
		SCANNER_STUB_REPORT_TASK="${SCANNER_STUB_REPORT_TASK:-}" \
		SCANNER_STUB_EXIT="${SCANNER_STUB_EXIT:-0}" \
		GIT_STUB_ARGV_LOG="${GIT_STUB_ARGV_LOG:-}" \
		GIT_STUB_FAIL_TOKENS="${GIT_STUB_FAIL_TOKENS:-}" \
		CURL_STUB_DIR="${CURL_STUB_DIR:-}" \
		CURL_STUB_ARGV_LOG="${CURL_STUB_ARGV_LOG:-}" \
		CURL_STUB_COUNTER="${CURL_STUB_COUNTER:-}" \
		CURL_STUB_CONFIG_LOG="${CURL_STUB_CONFIG_LOG:-}" \
		DATE_STUB_LOCAL="${DATE_STUB_LOCAL:-}" \
		DATE_STUB_UTC="${DATE_STUB_UTC:-}" \
		UNAME_STUB_S="${UNAME_STUB_S:-}" \
		TR_STUB_FAIL_NUL_CALL="${TR_STUB_FAIL_NUL_CALL:-}" \
		TR_STUB_NUL_COUNTER="${TR_STUB_NUL_COUNTER:-}" \
		MKTEMP_STUB_LOG="${MKTEMP_STUB_LOG:-}" \
		MKTEMP_STUB_FAIL_CURL_CONFIG="${MKTEMP_STUB_FAIL_CURL_CONFIG:-}" \
		CHMOD_STUB_MODE_600="${CHMOD_STUB_MODE_600:-}" \
		PS_STUB_ARGV_LOG="${PS_STUB_ARGV_LOG:-}" \
		PS_STUB_TABLE="${PS_STUB_TABLE:-}" \
		PS_STUB_FAIL="${PS_STUB_FAIL:-}" \
		"$@" >"$HARNESS_WORK/out" 2>"$HARNESS_WORK/err"
	CUR_RC=$?
	set -e
	CUR_OUT=$(cat "$HARNESS_WORK/out"); CUR_ERR=$(cat "$HARNESS_WORK/err")
	rm -f "$HARNESS_WORK/out" "$HARNESS_WORK/err"
	if [ "${VERBOSE:-0}" = "1" ]; then
		printf '    rc=%s\n' "$CUR_RC"
		printf '%s\n' "$CUR_OUT" | sed 's/^/    out| /'
		printf '%s\n' "$CUR_ERR" | sed 's/^/    err| /'
	fi
}

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------
pass() { printf '  ok   %s\n' "$1"; }

# fail NAME [DETAIL] — written as an `if` rather than an AND-list on purpose. As
# `[ -n "${2:-}" ] && printf ...`, a one-argument call left the AND-list's status
# non-zero in non-final position under `set -e`, aborting the whole suite instead
# of recording one failure — the worst possible moment for the harness itself to
# die.
fail() {
	printf '  FAIL %s\n' "$1"
	if [ -n "${2:-}" ]; then printf '       %s\n' "$2"; fi
	TESTS_FAIL=$((TESTS_FAIL + 1))
}

# skip NAME REASON — a section this HOST cannot exercise, counted separately from
# pass and fail. It exists for the one condition no test can control: a real
# `/Applications/IntelliJ IDEA*.app` on the machine running the suite (see
# run-resolution-tests.sh). Reporting that as a failure trains the reader to
# ignore a red suite, and reporting it as a pass claims coverage that did not
# happen — so it is neither.
skip() {
	TESTS_SKIP=$((TESTS_SKIP + 1))
	printf '  SKIP %s\n' "$1"
	printf '       %s\n' "$2"
}

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
	if printf '%s\n' "$CUR_OUT" | grep -Fq -- "$2"; then fail "$1" "stdout unexpectedly contains: $2
       stdout was: $CUR_OUT"
	else pass "$1"; fi
}

stderr_has() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if printf '%s\n' "$CUR_ERR" | grep -Fq -- "$2"; then pass "$1"
	else fail "$1" "stderr missing: $2
       stderr was: $CUR_ERR"; fi
}

# stderr_not_has — the stdout_not_has twin, for the case where TWO guards could
# each produce the same exit code and the test must prove WHICH one fired: an
# `expect_rc 1` alone passes for either, so the losing guard's diagnostic has to
# be asserted ABSENT for the ordering claim to mean anything.
stderr_not_has() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if printf '%s\n' "$CUR_ERR" | grep -Fq -- "$2"; then fail "$1" "stderr unexpectedly contains: $2
       stderr was: $CUR_ERR"
	else pass "$1"; fi
}

equals() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if [ "$2" = "$3" ]; then pass "$1"
	else fail "$1" "expected: $3
       got:      $2"; fi
}

path_exists() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if [ -e "$2" ]; then pass "$1"
	else fail "$1" "path does not exist: $2"; fi
}

path_absent() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if [ -e "$2" ] || [ -L "$2" ]; then fail "$1" "path unexpectedly exists: $2"
	else pass "$1"; fi
}

# path_is_symlink — `[ -L ]`, not `[ -e ]`, and that is the whole reason it
# exists. `[ -e ]` FOLLOWS a symlink and is therefore FALSE for a dangling one,
# so path_exists cannot make a claim about the dangling `-e` symlink
# lib/intellij.sh's reserve_idea_report_dir added `[ -L ]` to refuse — and a test
# that used path_exists there would fail for the wrong reason.
path_is_symlink() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if [ -L "$2" ]; then pass "$1"
	else fail "$1" "not a symlink (or absent): $2"; fi
}

file_has() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if [ -f "$2" ] && grep -Fq -- "$3" "$2"; then pass "$1"
	else fail "$1" "$2 missing: $3"; fi
}

# file_not_has — a SUBSTRING absence assertion, and the right tool for "this
# secret appears nowhere in that log".
#
# Deliberately NOT log_not_has_token (below), which is exact-line: a token can be
# leaked as PART of a larger argv token (`-u tok:`, `-Dsonar.token=tok`,
# `Authorization: Bearer tok`), and an exact-line match sees none of those. That
# gap was found by mutation: injecting `-u "$token:"` into the curl invocation left
# the exact-line assertion green. Use this for secrets, log_not_has_token for flags.
file_not_has() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if [ -f "$2" ] && grep -Fq -- "$3" "$2"; then
		fail "$1" "$2 unexpectedly contains: $3
       offending line(s): $(grep -F -- "$3" "$2" | head -3)"
	else pass "$1"; fi
}

# log_has_token / log_not_has_token — an EXACT-LINE match against a stub's argv
# log (one argv token per line, see stubs.sh), not a substring match.
# Deliberately stricter than file_has for flag assertions: a substring match on
# `-e` would also match inside an unrelated longer token — and for the token
# security assertions a substring match on the secret would match the `-K` config
# FILENAME line too, proving the opposite of what is claimed.
log_has_token() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if [ -f "$2" ] && grep -Fxq -- "$3" "$2"; then pass "$1"
	else fail "$1" "$2 is missing the exact token line: $3"; fi
}

log_not_has_token() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if [ -f "$2" ] && grep -Fxq -- "$3" "$2"; then fail "$1" "$2 unexpectedly contains the exact token line: $3"
	else pass "$1"; fi
}

# json_eq NAME FILE JQ_EXPR EXPECTED — the workhorse for both engines' output.
# `jq -c` so an array/object expectation is written as one compact literal, and a
# missing file fails with a named diagnostic instead of jq's own.
json_eq() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if [ ! -f "$2" ]; then fail "$1" "no such JSON file: $2"; return 0; fi
	je_got=$(jq -c "$3" "$2" 2>&1) || { fail "$1" "jq failed on $2: $je_got"; return 0; }
	if [ "$je_got" = "$4" ]; then pass "$1"
	else fail "$1" "jq $3 on $2
       expected: $4
       got:      $je_got"; fi
}

# json_golden NAME FILE GOLDEN — a STRICT WHOLE-DOCUMENT compare of FILE against
# a committed GOLDEN, keys sorted, with the one genuinely non-deterministic field
# masked: `.metadata.project` is an absolute mktemp path. (`generated_at` needs no
# mask — the stub clock makes it a constant; see lib/stubs.sh's init_date_stub.)
#
# WHY THIS EXISTS ALONGSIDE json_eq's field-level probes rather than instead of
# them. A field probe can only see the fields it names, so a metadata key that is
# silently ADDED, REMOVED or RENAMED is invisible to every one of them — the
# suite stays green while the engine's contract changes under its consumers. This
# is the assertion that fails on that, and it is deliberately strict (a bare `==`
# on the whole document) rather than a subset match, because a subset match has
# the same blind spot it is here to close.
#
# Regenerate deliberately: run the suite, read the printed diff, and update the
# golden only once each line of it is an intended change.
json_golden() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if [ ! -f "$2" ]; then fail "$1" "no such JSON file: $2"; return 0; fi
	if [ ! -f "$3" ]; then fail "$1" "no such golden file: $3"; return 0; fi
	if ! jq -S '.metadata.project = "<PROJECT>"' "$2" >"$HARNESS_WORK/golden-got" 2>&1; then
		fail "$1" "jq failed on $2: $(cat "$HARNESS_WORK/golden-got")"
		return 0
	fi
	if ! jq -S '.' "$3" >"$HARNESS_WORK/golden-want" 2>&1; then
		fail "$1" "jq failed on the golden $3: $(cat "$HARNESS_WORK/golden-want")"
		return 0
	fi
	if cmp -s "$HARNESS_WORK/golden-got" "$HARNESS_WORK/golden-want"; then pass "$1"
	else fail "$1" "$2 does not match the golden $3 (< golden, > actual):
$(diff "$HARNESS_WORK/golden-want" "$HARNESS_WORK/golden-got" | sed 's/^/       /')"; fi
	rm -f "$HARNESS_WORK/golden-got" "$HARNESS_WORK/golden-want"
}

# control_byte_count VALUE -> how many of the bytes lib/runtime.sh's
# strip_control_bytes drops (the C0 controls except tab and newline, plus DEL)
# VALUE still carries. A measurement fed to `equals`, not an assertion itself.
#
# WHY A COUNT AND NOT A SUBSTRING ASSERTION. The claim on the STDERR side is a
# NEGATIVE about a BYTE rather than about a string — "no ESC survived anywhere in
# this transcript" — which no `grep -F` needle written into a test's argument list
# can express readably. The claim on the STDOUT side is the OPPOSITE one (that
# channel is deliberately not filtered, so the byte must still be there), and one
# count expresses both against the ordinary `equals` assertion.
control_byte_count() {
	printf '%s' "$1" | tr -dc '\000-\010\013-\037\177' | wc -c | tr -d ' '
}

section() { printf '\n== %s ==\n' "$1"; }

summarize() {
	printf '\n%d tests, %d failed, %d skipped\n' "$TESTS_RUN" "$TESTS_FAIL" "$TESTS_SKIP"
	[ "$TESTS_FAIL" -eq 0 ]
}
