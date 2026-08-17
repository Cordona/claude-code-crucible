# shellcheck shell=sh
#
# harness.sh — the runner primitives every Jira test harness is built from:
#              the PATH-toolbox builder, the isolated `run` core, the pass/fail
#              counters, and the assertion vocabulary.
#
# WHY IT EXISTS: these ~150 lines used to be pasted verbatim into
# run-engine-tests.sh, run-write-tests.sh and run-rig-tests.sh. The
# production-side "each skill deploys independently, so it duplicates rather
# than sources" rationale does not apply to tests/, which is never deployed —
# so the copies bought nothing and had already begun to drift.
#
# WHAT STAYS IN EACH HARNESS: its own `run()` wrapper. The three suites have
# genuinely different PATH-toolbox selectors (the engine suite has four:
# full/nocurl/nojq/fixedtime; the write suite two; the rig suite one), and that
# selector map is the part that is really per-suite. Each defines a one-line
# run() over harness_run below.
#
# ISOLATION CONTRACT: every command runs under `env -i` with an isolated HOME
# and TMPDIR and an explicit PATH. Nothing is inherited from the developer's
# real environment — the caller passes the jira.sh-relevant variables
# (JIRA_EMAIL, JIRA_TOKEN, JIRA_SITE, ...) per test as leading VAR=VALUE
# arguments, which `env` itself parses.
#
# Sourced by the test harnesses — never executed directly.

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

# harness_init WORK_DIR — capture the real PATH (needed to locate tools before
# any toolbox exists) and fix the isolated HOME/TMPDIR every harness_run uses.
# Call once, right after the harness mktemp's its WORK dir.
harness_init() {
	HARNESS_WORK=$1
	HARNESS_HOME="$HARNESS_WORK/home"
	HARNESS_ORIG_PATH=$PATH
}

# link_tool TARGET_DIR TOOL — symlink the real TOOL into TARGET_DIR, resolving
# it against the ORIGINAL PATH. A missing tool is FATAL rather than a skipped
# test: a toolbox silently short one entry would fail every test downstream
# with an unrelated "not found", which is far harder to diagnose than this.
link_tool() {
	lt_target_dir=$1
	lt_tool_name=$2
	lt_tool_path=$(PATH="$HARNESS_ORIG_PATH" command -v "$lt_tool_name" 2>/dev/null || true)
	[ -n "$lt_tool_path" ] || { printf 'FATAL: required tool not found: %s\n' "$lt_tool_name" >&2; exit 1; }
	ln -s "$lt_tool_path" "$lt_target_dir/$lt_tool_name"
}

# ---------------------------------------------------------------------------
# The runner
# ---------------------------------------------------------------------------
TESTS_RUN=0
TESTS_FAIL=0
CUR_OUT=""
CUR_ERR=""
CUR_RC=0

# harness_run PATH_VALUE [VAR=VALUE...] COMMAND... — run COMMAND under a fully
# isolated environment with PATH_VALUE as its PATH, capturing stdout/stderr/rc
# into $CUR_OUT/$CUR_ERR/$CUR_RC. `set +e` around the call is deliberate: a
# non-zero exit is the THING UNDER TEST here, not a harness failure.
harness_run() {
	hr_path=$1; shift
	set +e
	env -i \
		HOME="$HARNESS_HOME" \
		PATH="$hr_path" \
		TMPDIR="$HARNESS_WORK" \
		CURL_STUB_RESP_DIR="$CURL_STUB_RESP_DIR" \
		CURL_STUB_COUNTER_FILE="$CURL_STUB_COUNTER_FILE" \
		CURL_STUB_ARGV_LOG="$CURL_STUB_ARGV_LOG" \
		CURL_STUB_BODY_LOG_DIR="$CURL_STUB_BODY_LOG_DIR" \
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

stdout_not_has() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if printf '%s\n' "$CUR_OUT" | grep -Fq -- "$2"; then fail "$1" "stdout unexpectedly contains: $2"
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
# `expect_rc 2` alone passes for either, so the losing guard's diagnostic has to
# be asserted ABSENT for the ordering claim to mean anything.
stderr_not_has() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if printf '%s\n' "$CUR_ERR" | grep -Fq -- "$2"; then fail "$1" "stderr unexpectedly contains: $2"
	else pass "$1"; fi
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

# argv_log_has_token / argv_log_not_has_token — like file_has/file_not_has but
# an EXACT-LINE match against the argv log (one argv token per line, see
# curl-stub.sh), not a substring match. This is deliberately stricter than
# file_has for flag assertions: a substring match on "-L" would also match
# inside an unrelated longer token, silently proving nothing.
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
