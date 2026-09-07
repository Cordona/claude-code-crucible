# shellcheck shell=sh
#
# rig.sh — the per-suite setup every inspect-project suite performs identically:
#          locate the script under test, build the isolated PATH toolbox, write
#          the four stubs into four separate directories, and provide the fixture
#          builders (projects, report directories) more than one suite needs.
#
# WHAT DELIBERATELY STAYS PER-SUITE: each suite's own `run()` selector map. The
# suites need genuinely different PATH compositions — the resolution suite is
# entirely about which of `idea`/a shim/an app bundle exists, the Sonar suite
# about `sonar-scanner` and `curl` being present or absent — and a single shared
# selector map would have to enumerate every combination of five stub
# directories. Same split, same reason, as procedure-jira/tests/lib/harness.sh.
#
# Sourced by the test suites — never executed directly. Requires harness.sh and
# stubs.sh to have been sourced first.
#
# shellcheck disable=SC2034  # file-wide, deliberately: declaring the location and stub-control globals the SUITES and harness_run read IS this file's job, and shellcheck cannot see a reader in a sibling file — the same directive, for the same reason, as the production lib/runtime.sh

# ---------------------------------------------------------------------------
# rig_setup TESTS_DIR SUITE_TAG — everything a suite needs before its first
# assertion. Sets the WORK/TOOLBOX/BIN_* location globals, links the real tools,
# writes the stubs, installs the teardown trap, and fixes the stub clock.
# ---------------------------------------------------------------------------
rig_setup() {
	TESTS_DIR=$1
	TOOL_DIR=$(cd "$TESTS_DIR/.." && pwd)
	INSPECT="$TOOL_DIR/inspect-project.sh"
	FIXTURES="$TESTS_DIR/fixtures"
	[ -x "$INSPECT" ] || { printf 'FATAL: not executable: %s\n' "$INSPECT" >&2; exit 1; }

	WORK=$(mktemp -d "${TMPDIR:-/tmp}/inspect-$2-tests.XXXXXX")
	TOOLBOX="$WORK/toolbox"
	BIN_IDEA="$WORK/bin-idea"
	BIN_SCANNER="$WORK/bin-scanner"
	BIN_CURL="$WORK/bin-curl"
	BIN_DATE="$WORK/bin-date"
	BIN_UNAME="$WORK/bin-uname"
	BIN_GIT="$WORK/bin-git"
	BIN_TR="$WORK/bin-tr"
	BIN_MKTEMP="$WORK/bin-mktemp"
	BIN_CHMOD="$WORK/bin-chmod"
	BIN_PS="$WORK/bin-ps"
	mkdir -p "$TOOLBOX" "$BIN_IDEA" "$BIN_SCANNER" "$BIN_CURL" "$BIN_DATE" \
		"$BIN_UNAME" "$BIN_GIT" "$BIN_TR" "$BIN_MKTEMP" "$BIN_CHMOD" "$BIN_PS" \
		"$WORK/projects" "$WORK/results" "$WORK/logs"

	# shellcheck disable=SC2329  # invoked indirectly via the trap below
	rig_teardown() { rm -rf "$WORK"; }
	trap rig_teardown EXIT INT TERM

	harness_init "$WORK"

	# The isolated toolbox. dirname/readlink/realpath/basename are DELIBERATELY
	# ABSENT, and that absence is a load-bearing regression guard rather than an
	# oversight: inspect-project.sh's Portability header promises it resolves lib/
	# from its own $0 with pure parameter expansion, and a future regression to
	# `SCRIPT_DIR=$(dirname "$0")` must break these suites loudly instead of
	# passing green. Adding any of the four back here silently voids that claim.
	# `git` and `ps` are deliberately NOT here either, for a different reason: each
	# lives only in its own directory ($BIN_GIT's pass-through recorder, $BIN_PS's
	# fixture process table), so a selector that omits that directory exercises
	# "git is not on PATH" / "`ps` is not on PATH" for real — the second of which is
	# the IntelliJ preflight's documented degradation path.
	#
	# `env` is here for the TESTS' own use, not the script's: it is how a suite
	# hands inspect-project an inherited $GIT_DIR/$GIT_WORK_TREE the way a git hook
	# or `git bisect run` would (see run-git-tests.sh). harness_run cannot forward
	# those through its own `env -i` list, because git treats an EMPTY $GIT_DIR as a
	# broken repository rather than as unset — verified: `GIT_DIR= git status`
	# exits 128 — so they have to be absent unless a test is deliberately setting
	# one.
	for rs_tool in sh env jq date uname mktemp mkdir rmdir rm cp cat sleep \
		chmod tr sed grep sort head tail wc find cut ls
	do
		link_tool "$TOOLBOX" "$rs_tool"
	done

	init_idea_stub "$BIN_IDEA"
	init_scanner_stub "$BIN_SCANNER"
	init_curl_stub "$BIN_CURL" "$WORK"
	init_date_stub "$BIN_DATE"
	init_uname_stub "$BIN_UNAME"
	init_git_recorder "$BIN_GIT"
	init_tr_stub "$BIN_TR"
	init_mktemp_stub "$BIN_MKTEMP"
	init_chmod_stub "$BIN_CHMOD"
	init_ps_stub "$BIN_PS"

	IDEA_STUB_ARGV_LOG="$WORK/logs/idea-argv.log"
	IDEA_STUB_ENV_LOG="$WORK/logs/idea-env.log"
	SCANNER_STUB_ARGV_LOG="$WORK/logs/scanner-argv.log"
	SCANNER_STUB_ENV_LOG="$WORK/logs/scanner-env.log"
	GIT_STUB_ARGV_LOG="$WORK/logs/git-argv.log"
	MKTEMP_STUB_LOG="$WORK/logs/mktemp.log"
	PS_STUB_ARGV_LOG="$WORK/logs/ps-argv.log"
	TR_STUB_NUL_COUNTER="$WORK/logs/tr-nul-counter"

	rig_reset_stub_state
}

# rig_reset_stub_state — put EVERY stub control and every forwarded environment
# variable back to its default, in ONE place.
#
# WHY THIS IS AN ENFORCED RESET AND NOT A CONVENTION. Before it existed, a test
# that needed a deviation set the control, ran, and set it back by hand. That
# works right up until someone inserts a test between the set and the reset: the
# inserted test then runs the PREVIOUS test's scenario, silently, and still passes
# — it is asserting something true of a run it did not mean to make. There is no
# way to see that in review, because the bug is the DISTANCE between two correct
# lines. Every suite's own `inspect()`/`run()` helper calls this first, so a
# deviation cannot outlive the one run it was written for, and every deviation is
# passed to that helper as an explicit argument instead of being left lying around
# in a global.
#
# The stub clock lives here too: every suite that asserts on the run directory's
# name or on `generated_at` reads it, and the same-second collision path is only
# reachable because two consecutive runs see the identical local stamp.
rig_reset_stub_state() {
	DATE_STUB_LOCAL='2026/08/26/12-34-56'
	DATE_STUB_UTC='2026-08-26T10:34:56Z'
	UNAME_STUB_S=Darwin

	IDEA_STUB_EDIR_SRC=""
	IDEA_STUB_EDIR_AS_FILE=""
	IDEA_STUB_EXIT=0
	IDEA_STUB_SIGNAL_PARENT=""
	SCANNER_STUB_REPORT_TASK=""
	SCANNER_STUB_EXIT=0
	GIT_STUB_FAIL_TOKENS=""
	TR_STUB_FAIL_NUL_CALL=""
	MKTEMP_STUB_FAIL_CURL_CONFIG=""
	CHMOD_STUB_MODE_600=""
	PS_STUB_TABLE=""
	PS_STUB_FAIL=""

	# inspect-project's own environment contract, cleared by default so no test
	# inherits another's. Empty is equivalent to unset for all three (see
	# harness_run).
	IDEA_BIN=""
	SONAR_TOKEN=""
	SONAR_HOST_URL=""
	UNIT_SONAR_HOST=""
	UNIT_SONAR_POLL_MAX_ATTEMPTS=""
	UNIT_SONAR_POLL_INTERVAL=""
}

# rig_reset_logs — empty every stub's logs and counters. Call before EVERY test,
# so no assertion can read the invocation record of a previous one.
rig_reset_logs() {
	: >"$IDEA_STUB_ARGV_LOG"
	: >"$IDEA_STUB_ENV_LOG"
	: >"$SCANNER_STUB_ARGV_LOG"
	: >"$SCANNER_STUB_ENV_LOG"
	: >"$GIT_STUB_ARGV_LOG"
	: >"$MKTEMP_STUB_LOG"
	: >"$PS_STUB_ARGV_LOG"
	printf '0' >"$TR_STUB_NUL_COUNTER"
}

# ---------------------------------------------------------------------------
# Fixture builders
# ---------------------------------------------------------------------------

# new_project NAME [RELATIVE_PATH...] — a fresh project directory under
# $WORK/projects containing one empty file per RELATIVE_PATH, and print its
# absolute path. The paths' EXTENSIONS are the point: they are what
# detect_project_languages maps to language labels.
new_project() {
	np_name=$1
	shift
	np_dir="$WORK/projects/$np_name"
	rm -rf "$np_dir"
	mkdir -p "$np_dir"
	for np_rel in "$@"; do
		case "$np_rel" in
			*/*) mkdir -p "$np_dir/${np_rel%/*}" ;;
		esac
		: >"$np_dir/$np_rel"
	done
	printf '%s' "$np_dir"
}

# results_root NAME -> a fresh, empty --output-root. One per test, so a run
# directory assertion cannot see another test's tree.
results_root() {
	rr_dir="$WORK/results/$1"
	rm -rf "$rr_dir"
	mkdir -p "$rr_dir"
	printf '%s' "$rr_dir"
}

# run_dir_of ROOT NAME [SUFFIX] -> the run directory the documented layout
# (`<output-root>/YYYY/MM/DD/<project-name>/<HH-MM-SS>`) puts a run in, given the
# stub clock. SUFFIX is the collision discriminator (`-2`, `-3`, ...).
#
# The date and time halves are split out of the ONE stub stamp rather than spelled
# twice, so a test can never assert against a layout the stub clock never served.
run_dir_of() {
	printf '%s/%s/%s/%s%s' "$1" "${DATE_STUB_LOCAL%/*}" "$2" "${DATE_STUB_LOCAL##*/}" "${3:-}"
}
