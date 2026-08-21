# shellcheck shell=sh
#
# harness.sh — the runner primitives every Management Hub test harness is built
#              from: the isolated PATH-toolbox builder, the `env -i` run core,
#              the pass/fail counters, and the assertion vocabulary.
#
# WHY A HAND-ROLLED HARNESS AT ALL (not bats): the same reason
# accounts/procedure-github-auth/tests/run-tests.sh states — these scripts must
# run on any machine with no dependencies, and requiring bats-core would
# contradict that. This needs only a POSIX sh plus the coreutils that already
# ship on macOS (BSD) and Linux (GNU).
#
# WHY IT IS A SHARED FILE rather than pasted into each runner: the same rationale
# project-management/.../procedure-jira/tests/lib/harness.sh states for its own
# extraction — the production-side "each skill deploys independently, so it
# duplicates rather than sources" argument does not apply to tests/, which is
# never deployed, so copies buy nothing and drift.
#
# WHAT STAYS IN EACH RUNNER: how it EXECUTES the thing under test. The
# non-interactive suite runs hub-install.sh directly through harness_run; the
# interactive suite drives it through expect(1) on a pty, because the interactive
# path is gated on hub_is_tty. Only the shared bookkeeping lives here.
#
# Sourced by the test runners — never executed directly.

# HARNESS_TOOLS — every real tool the hub's own scripts invoke, established by
# reading deploy/hub/. jq is DELIBERATELY ABSENT: it is needed only for
# --format=json, so a suite that never asks for that format must stay green
# without it, and putting it here would break the zero-dependency guarantee
# above. A suite that DOES exercise --format=json adds it through
# harness_link_optional_tool below and skips its own cases when it is missing.
HARNESS_TOOLS='sh env awk sed grep find sort tr cut head tail cat wc rm mkdir
	mktemp ln cp mv touch dirname basename readlink date printf pwd'

# harness_init WORK -> build the isolated toolbox and HOME under WORK, and point
# harness_run at them. WORK must already exist and must be CANONICAL (created
# through `cd … && pwd -P`) — see harness_run for why that is load-bearing.
# Dies rather than skipping when a required tool is missing: a silently thinner
# PATH would make the hub fail for a reason that has nothing to do with the code.
harness_init() {
	HARNESS_WORK=$1
	HARNESS_TOOLBOX="$HARNESS_WORK/toolbox"
	HARNESS_HOME="$HARNESS_WORK/home"
	mkdir -p "$HARNESS_TOOLBOX" "$HARNESS_HOME"
	# KEPT for harness_link_optional_tool's own lookups, which run long after this
	# function returns and must resolve against the REAL PATH rather than the
	# toolbox that has replaced it in every process under test.
	HARNESS_REAL_PATH=$PATH
	for harness_tool in $HARNESS_TOOLS; do
		harness_tool_path=$(harness_which "$harness_tool")
		[ -n "$harness_tool_path" ] || {
			printf 'FATAL: required tool not found: %s\n' "$harness_tool" >&2
			exit 1
		}
		ln -s "$harness_tool_path" "$HARNESS_TOOLBOX/$harness_tool"
	done
}

# harness_which NAME -> NAME's real-PATH location, or empty when the machine does
# not have it. Never dies, so both the required and the optional caller can decide
# for themselves what an absence means.
harness_which() {
	PATH="$HARNESS_REAL_PATH" command -v "$1" 2>/dev/null || true
}

# harness_link_optional_tool NAME -> add NAME to the toolbox when this machine has
# it; exit 1 when it does not. The OPT-IN counterpart to HARNESS_TOOLS, which dies
# on an absence because every entry there is required by the code under test on
# every path.
#
# An optional tool's absence must SKIP the cases that need it — the convention
# run-tests-interactive.sh already applies to expect(1) — never fail the run and
# never silently thin the PATH for the cases that do not need it.
harness_link_optional_tool() {
	harness_opt_path=$(harness_which "$1")
	[ -n "$harness_opt_path" ] || return 1
	[ -e "$HARNESS_TOOLBOX/$1" ] || ln -s "$harness_opt_path" "$HARNESS_TOOLBOX/$1"
}

TESTS_RUN=0
TESTS_FAIL=0
CUR_OUT=""
CUR_ERR=""
CUR_RC=0

# harness_capture <cmd> [args...] -> run <cmd> with stdin on /dev/null,
# capturing stdout, stderr and the exit code into CUR_OUT / CUR_ERR / CUR_RC.
#
# stdin is /dev/null: nothing reached through here may prompt on the harness's
# own stdin, so a read that blocks is a failure to surface rather than a wait to
# satisfy. (The interactive runner's expect(1) does not read this stdin — it
# drives a pty of its own.)
#
# The UN-ISOLATED core. harness_run just below adds the env -i isolation and is
# what a runner normally wants; the interactive runner has to reach a tool that
# is deliberately NOT in the toolbox (expect), so it calls this directly and
# isolates the process expect spawns instead.
harness_capture() {
	set +e
	"$@" </dev/null >"$HARNESS_WORK/out" 2>"$HARNESS_WORK/err"
	CUR_RC=$?
	set -e
	CUR_OUT=$(cat "$HARNESS_WORK/out")
	CUR_ERR=$(cat "$HARNESS_WORK/err")
	rm -f "$HARNESS_WORK/out" "$HARNESS_WORK/err"
	if [ "${VERBOSE:-0}" = "1" ]; then
		printf '    rc=%s\n' "$CUR_RC"
		printf '%s\n' "$CUR_OUT" | sed 's/^/    out| /'
		printf '%s\n' "$CUR_ERR" | sed 's/^/    err| /'
	fi
}

# harness_run [VAR=VALUE ...] <cmd> [args...] -> harness_capture, plus the
# `env -i` isolation every hub script under test runs in: the toolbox PATH and an
# isolated HOME/TMPDIR. Leading VAR=VALUE arguments are passed straight to `env`.
harness_run() {
	harness_capture env -i \
		HOME="$HARNESS_HOME" \
		PATH="$HARNESS_TOOLBOX" \
		TMPDIR="$HARNESS_WORK" \
		"$@"
}

pass() { printf '  ok   %s\n' "$1"; }
fail() {
	printf '  FAIL %s\n' "$1"
	[ -n "${2:-}" ] && printf '       %s\n' "$2"
	TESTS_FAIL=$((TESTS_FAIL + 1))
}
skip() { printf '  skip %s\n' "$1"; }

# expect_ok NAME DIAGNOSTIC STATUS -> the generic assertion, and the only one
# taking both its status and its failure diagnostic as arguments rather than
# reading CUR_RC / CUR_OUT / CUR_ERR itself.
expect_ok() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if [ "$3" -eq 0 ]; then pass "$1"; else fail "$1" "$2"; fi
}

expect_rc() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if [ "$CUR_RC" -eq "$2" ]; then pass "$1"
	else fail "$1" "expected exit $2, got $CUR_RC; stderr: $CUR_ERR"; fi
}

# `grep -Fq --` on every matcher below, never a bare `grep -Fq "$2"`: an EXPECTED
# STRING THAT STARTS WITH `-` IS READ AS AN OPTION otherwise, and the failure is not
# a false pass but a confusing one — grep exits 2 with its own usage text, the
# assertion reports "missing" for a string that is present, and the noise looks like
# a harness crash rather than a quoting bug. Reached the moment an assertion names a
# FLAG, which every usage-error diagnostic does (`--baseline-only requires
# --domains`). The `--` is the POSIX end-of-options marker and is honored by BSD and
# GNU grep alike.
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

# stdout_is — exact whole-stdout compare, for a call whose entire output IS the
# answer. A `has` check there would pass on a SUPERSET, which is precisely the
# over-wide answer some of those calls exist to prevent.
stdout_is() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if [ "$CUR_OUT" = "$2" ]; then pass "$1"
	else fail "$1" "expected stdout [$2], got [$CUR_OUT]"; fi
}

# stderr_has — the HUMAN channel, which under --format=env|json is where the hub
# puts everything that is not the machine payload (its fd 3 is stderr there; see
# hub-install.sh's own fd-3 block). A no-op exit's MESSAGE is the only thing that
# says WHICH no-op path fired, and it lives there rather than on stdout — so
# without this, two different no-op exits are indistinguishable and an assertion
# about "the field is emitted on THIS path" cannot name the path.
stderr_has() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if printf '%s\n' "$CUR_ERR" | grep -Fq -- "$2"; then pass "$1"
	else fail "$1" "stderr missing: $2"; fi
}

# stderr_lacks — the negative half of stderr_has, and it earns a place beside it for
# the same reason stdout_lacks does: two diagnostics that BOTH apply to one argument
# list are told apart by which one did NOT print. A usage error's exit status is the
# same either way, so the absent message is the only observable difference.
stderr_lacks() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if printf '%s\n' "$CUR_ERR" | grep -Fq -- "$2"; then fail "$1" "stderr unexpectedly contains: $2"
	else pass "$1"; fi
}

# stderr_has_line — WHOLE-LINE compare (`grep -Fqx`), the per-line counterpart of
# stdout_is, for a rendered line whose ABSENT content is the assertion.
#
# WHY A SUBSTRING MATCH CANNOT EXPRESS THIS: a checklist's hint line grows an extra
# segment at its FRONT when the caller offers an extra key, so every substring of the
# plain line is still a substring of the augmented one — `stderr_has` on it passes
# either way and verifies nothing about the segment's absence. Pinning the whole line
# is what makes "this line has no extra segment" falsifiable, in the one direction a
# `lacks` check cannot reach (there is no string to name when the thing under test is
# a prefix that was not added).
stderr_has_line() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if printf '%s\n' "$CUR_ERR" | grep -Fqx -- "$2"; then pass "$1"
	else fail "$1" "no stderr line is exactly: $2"; fi
}

# stdout_json_is NAME FILTER EXPECTED -> parse the WHOLE stdout as one JSON
# document, apply jq FILTER to it, and compare the compact result to EXPECTED.
#
# A grep for a field's text would also pass on a payload that is two documents
# concatenated, or a bare key=value line printed beside a document — which is
# precisely the shape a payload assembled by MERGING a field into another
# function's JSON can get wrong. Parsing is what makes "still one valid document"
# part of the assertion rather than an assumption.
#
# jq comes from the TEST process's own PATH, not the toolbox: this is the
# harness inspecting a captured payload, not the code under test running a tool.
# The caller is responsible for having gated its section on jq's presence.
stdout_json_is() {
	TESTS_RUN=$((TESTS_RUN + 1))
	# 2>&1 so a parse failure's own diagnostic becomes the reported value: "not one
	# valid JSON document" is the finding, and jq's line/column is what locates it.
	if ! sji_actual=$(printf '%s\n' "$CUR_OUT" | jq -c "$2" 2>&1); then
		fail "$1" "stdout is not one valid JSON document; jq said: $sji_actual"
		return 0
	fi
	if [ "$sji_actual" = "$3" ]; then pass "$1"
	else fail "$1" "expected $2 to be [$3], got [$sji_actual]"; fi
}

path_exists() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if [ -e "$2" ]; then pass "$1"
	else fail "$1" "expected to exist: $2"; fi
}

path_absent() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if [ -e "$2" ]; then fail "$1" "expected NOT to exist: $2"
	else pass "$1"; fi
}

section() { printf '\n== %s ==\n' "$1"; }

# harness_summary -> the trailing count block, and the process exit status.
harness_summary() {
	printf '\n== summary ==\n'
	printf 'ran %s checks, %s failed\n' "$TESTS_RUN" "$TESTS_FAIL"
	[ "$TESTS_FAIL" -eq 0 ] || exit 1
	printf 'ALL TESTS PASSED\n'
	exit 0
}
