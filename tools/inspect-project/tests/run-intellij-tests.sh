#!/usr/bin/env sh
#
# run-intellij-tests.sh — the IntelliJ engine's output: the `./-e/` report
#                         directory workaround, language detection and coverage,
#                         the SonarLint profile signals, issue normalization, and
#                         --exclude-ids.
#
# THE ONE MECHANIC WORTH KNOWING BEFORE READING ANY TEST HERE. The IntelliJ CLI
# ignores the output path it is given and writes its report into `./-e/` at the
# project root instead (lib/intellij.sh mechanic 2). The `idea` stub therefore
# writes `./-e/` too — see lib/stubs.sh for why a stub that honoured the output
# argument would let these tests pass against a script that had LOST the
# workaround.
#
# WHAT IS ASSERTED. Almost everything here reads `intellij.json` with jq. That file
# IS the engine's contract: an agent consumes it, and every honesty signal the tool
# exists to provide (which languages the profile can actually check, whether
# Sonar's rules were even registered, how many findings were dropped) is a field in
# it. The fixture report directories under fixtures/edir-* are committed golden
# inputs, so what a test claims can be read next to what produced it.
#
# Usage:  sh run-intellij-tests.sh
#         VERBOSE=1 sh run-intellij-tests.sh
# Exit 0 = all passed, 1 = one or more failed.
#
set -eu

TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=SCRIPTDIR/lib/harness.sh
. "$TESTS_DIR/lib/harness.sh"
# shellcheck source=SCRIPTDIR/lib/stubs.sh
. "$TESTS_DIR/lib/stubs.sh"
# shellcheck source=SCRIPTDIR/lib/rig.sh
. "$TESTS_DIR/lib/rig.sh"

rig_setup "$TESTS_DIR" intellij

# `full` deliberately leaves $BIN_PS OFF PATH, so every test that is not about the
# single-instance preflight runs with `ps` genuinely absent — which is the
# preflight's documented "cannot tell, warn and proceed" path and therefore the
# state that must not disturb anything else the engine does. `full-ps` is the opt-in
# for the tests that need a process table to look at.
run() {
	r_selector=$1; shift
	case "$r_selector" in
		full) r_path="$BIN_DATE:$BIN_IDEA:$TOOLBOX" ;;
		full-ps) r_path="$BIN_DATE:$BIN_IDEA:$BIN_PS:$TOOLBOX" ;;
		*) printf 'FATAL: bad run() selector: %s\n' "$r_selector" >&2; exit 1 ;;
	esac
	harness_run "$r_path" "$@"
}

# OUT — the intellij.json the last `inspect` wrote. Set by inspect() so no test
# re-derives the documented run-directory layout by hand.
OUT=""

# RESOLVED_IDEA_BIN — the path every run below passes as --idea-bin, and therefore
# the exact path lib/intellij.sh resolves. Named once rather than spelled at both
# sites, because the single-instance preflight's fixture process tables have to
# carry the SAME path the tool resolves: spelled twice, a drift between them would
# turn the positive-match test into a second negative one, silently and greenly.
RESOLVED_IDEA_BIN="$BIN_IDEA/idea"

# inspect PROJECT RESULTS_TAG [DEVIATION...] [CLI_FLAG...] — one IntelliJ run at
# `all` scope, with $OUT pointed at its output file.
#
# EVERY STUB CONTROL IS RESET FIRST (rig.sh's rig_reset_stub_state) and every
# deviation is passed HERE, as an explicit argument, rather than assigned to a
# global before the call and assigned back after it. This suite is where that
# mattered most: it varies IDEA_STUB_EDIR_SRC across nearly thirty runs, so a test
# inserted between one of those sets and its reset would have silently exercised
# the previous fixture's report directory and still passed.
#
#   --edir SRC       the fixture report directory the CLI stub writes
#   --edir-as-file   the CLI stub leaves `-e` as a plain FILE, not a directory
#   --scope SCOPE    `changed-only` instead of `all`
#   --token VALUE    $SONAR_TOKEN in the environment this run INHERITS, which is
#                    the channel the tool recommends and therefore the one an
#                    operator really has exported when they invoke it
#   --ps-table FILE  put `ps` on PATH and have it serve FILE as the process table
#   --ps-fail        put `ps` on PATH and have it FAIL instead of answering
#
# The last two also switch the PATH selector, because `ps` is absent from the
# default one (see run() above) and a table nothing can read is not a scenario.
# Anything else is passed through to inspect-project itself.
inspect() {
	i_project=$1
	i_root=$(results_root "$2")
	shift 2
	rig_reset_stub_state
	IDEA_STUB_EDIR_SRC="$FIXTURES/edir-basic"
	i_scope=all
	i_selector=full
	while [ $# -gt 0 ]; do
		case "$1" in
			--edir)         IDEA_STUB_EDIR_SRC=$2; shift 2 ;;
			--edir-as-file) IDEA_STUB_EDIR_AS_FILE=1; shift ;;
			--scope)        i_scope=$2; shift 2 ;;
			--token)        SONAR_TOKEN=$2; shift 2 ;;
			--ps-table)     i_selector=full-ps; PS_STUB_TABLE=$2; shift 2 ;;
			--ps-fail)      i_selector=full-ps; PS_STUB_FAIL=1; shift ;;
			*) break ;;
		esac
	done
	rig_reset_logs
	run "$i_selector" "$INSPECT" --project "$i_project" --scope "$i_scope" --engine intellij \
		--output-root "$i_root" --idea-bin "$RESOLVED_IDEA_BIN" "$@"
	OUT="$(run_dir_of "$i_root" "${i_project##*/}")/intellij.json"
}

# coverage_of LANGUAGE -> that language's language_coverage entry as compact JSON.
coverage_of() {
	printf '.metadata.language_coverage[] | select(.language == "%s")' "$1"
}

BASIC_PROJECT=$(new_project basic src/main.rs README.md Cargo.toml)

# ===========================================================================
section "the ./-e/ report-directory workaround"
# ===========================================================================
inspect "$BASIC_PROJECT" edir --edir "$FIXTURES/edir-basic"
expect_rc "-e: the run succeeds" 0
log_has_token "-e: the CLI is passed the literal \`-e\` output token" "$IDEA_STUB_ARGV_LOG" "-e"
json_eq "-e: the findings really came from ./-e/, not from the path passed for output" \
	"$OUT" '[.issues[].id]' '["MyRule"]'
path_absent "-e: the report directory is removed from the project afterwards" \
	"$BASIC_PROJECT/-e"
json_eq "-e: source_inspection is an internal join key and never reaches the output" \
	"$OUT" '[.issues[] | has("source_inspection")] | unique' '[false]'

# --- a leading-dot file in the report directory is never read as a report ----
# WHAT THIS PINS, STATED ACCURATELY. collect_intellij_issues has no name-based
# skip for `.descriptions.json` and does not need one: it iterates
# `"$IDEA_EDIR"/*.json`, and a POSIX glob never matches a leading-dot name. An
# earlier version of this test claimed to make a `.descriptions`-stem GUARD's
# removal observable; that guard was unreachable dead code and has since been
# deleted, so the claim was false and is not made here.
#
# The property is still worth a test, because the GLOB is load-bearing and a
# future edit could widen it: `.descriptions.json` is the profile catalog, and
# reading it as a findings file would inject the whole profile into `issues[]`.
# The fixture's synthetic `problems` array is what makes that widening visible —
# the real file carries no such key, so without it the two behaviours look alike.
inspect "$BASIC_PROJECT" edir-dotfile-not-a-report --edir "$FIXTURES/edir-descriptions-with-problems"
expect_rc "-e: a report whose metadata file also carries findings still succeeds" 0
json_eq "-e: a findings-shaped payload in the leading-dot metadata file is NOT collected" \
	"$OUT" '[.issues[].id]' '["MyRule"]'
json_eq "-e: and its profile metadata is still read" \
	"$OUT" '.metadata.inspection_profile' '"Descriptions Carrying A Problems Array"'

# --- the report is found regardless of the caller's cwd ----------------------
# The CLI is invoked with cwd set to the project, so `./-e/` is the project's — but
# the SCRIPT's own cwd is wherever the caller happened to be, and reading the
# report must not depend on it.
CWD_SAVED=$(pwd)
cd "$WORK/logs"
inspect "$BASIC_PROJECT" edir-other-cwd --edir "$FIXTURES/edir-basic"
cd "$CWD_SAVED"
expect_rc "-e: a run started from an unrelated cwd succeeds" 0
json_eq "-e: and reads the same report" "$OUT" '[.issues[].id]' '["MyRule"]'

# --- a pre-existing ./-e/ is somebody else's, and is refused -----------------
# This script DELETES its report directory afterwards, so an existing one means
# either a previous run died hard or the path is genuinely the user's. Deleting
# somebody's directory to make room for a report is not a call this script may
# make — and these tests are what stop that from becoming one.
GUARD_PROJECT=$(new_project edirguard src/main.rs)
mkdir -p "$GUARD_PROJECT/-e/precious"
printf 'do not delete me\n' >"$GUARD_PROJECT/-e/precious/notes.txt"
inspect "$GUARD_PROJECT" edir-preexisting-dir
expect_rc "pre-existing -e directory: exit 1 rather than clobber it" 1
stderr_has "pre-existing -e directory: the path is named" "already exists in the target project"
stderr_has "pre-existing -e directory: the remedy is named" "move or remove it, then re-run"
file_has "pre-existing -e directory: its contents are untouched" \
	"$GUARD_PROJECT/-e/precious/notes.txt" "do not delete me"

FILE_GUARD=$(new_project edirfileguard src/main.rs)
printf 'a user file that happens to be named -e\n' >"$FILE_GUARD/-e"
inspect "$FILE_GUARD" edir-preexisting-file
expect_rc "pre-existing -e FILE: exit 1 as well, not only a directory" 1
file_has "pre-existing -e FILE: its content is untouched" \
	"$FILE_GUARD/-e" "a user file that happens to be named -e"

# ===========================================================================
section "the report directory's name is RESERVED, not merely checked"
# ===========================================================================
# `-e` is created by the CLI, so a bare `[ -e ] && refuse` leaves a window in
# which two concurrent runs on one project both pass the check, both let the CLI
# write `<project>/-e`, and the first to finish `rm -rf`s it out from under the
# other. The reservation is a `mkdir` of the SIBLING `-e.lock`, which is the atomic
# primitive that closes it.
LOCK_HAPPY=$(new_project lockhappy src/main.rs)
inspect "$LOCK_HAPPY" lock-happy
expect_rc "reservation: a run with nothing in the way succeeds" 0
# The claim that separates a RESERVATION from a check: the lock is really on disk
# for the whole length of the inspection, which is the only window in which it can
# be seen. See lib/stubs.sh's init_idea_stub for why the CLI stub records it.
log_has_token "reservation: the lock is HELD while the inspection runs, not merely tested for" \
	"$IDEA_STUB_ARGV_LOG" "EDIR_LOCK_PRESENT=yes"
path_absent "reservation: and releases the lock it took" "$LOCK_HAPPY/-e.lock"
path_absent "reservation: along with the report directory itself" "$LOCK_HAPPY/-e"

# --- a second concurrent run is REFUSED --------------------------------------
# The lock a live run is holding, stood in for by one already on disk: from this
# run's point of view those are the same thing, since the whole claim is that a
# `mkdir` which loses the race refuses instead of proceeding.
LOCK_HELD=$(new_project lockheld src/main.rs)
mkdir "$LOCK_HELD/-e.lock"
inspect "$LOCK_HELD" lock-held
expect_rc "concurrent run: refused with exit 1 rather than racing the other run" 1
stderr_has "concurrent run: the lock path is named" \
	"'$LOCK_HELD/-e.lock' already exists in the target project"
stderr_has "concurrent run: and the remedy explains what holding it means" \
	"another inspect-project run is inspecting it (or one died hard)"
equals "concurrent run: the CLI was never launched" \
	"$(grep -c . "$IDEA_STUB_ARGV_LOG" || true)" "0"
path_exists "concurrent run: the OTHER run's lock is left exactly where it was" \
	"$LOCK_HELD/-e.lock"

# --- a DANGLING symlink named -e is refused too ------------------------------
# `[ -e ]` FOLLOWS symlinks and is therefore FALSE for a dangling one, so this
# path slipped past the old check entirely — and was then followed by the CLI's own
# writes, landing the report wherever the link pointed. `[ -L ]` is what closes it.
LOCK_LINK=$(new_project locklink src/main.rs)
ln -s "$WORK/nowhere-at-all" "$LOCK_LINK/-e"
inspect "$LOCK_LINK" lock-dangling-symlink
expect_rc "dangling -e symlink: refused with exit 1" 1
stderr_has "dangling -e symlink: reported as an existing node in the project" \
	"'$LOCK_LINK/-e' already exists in the target project"
stderr_has "dangling -e symlink: with the remedy named" "move or remove it, then re-run"
path_is_symlink "dangling -e symlink: the user's own symlink is NOT deleted" "$LOCK_LINK/-e"
path_absent "dangling -e symlink: but the lock this run took IS released" "$LOCK_LINK/-e.lock"

# --- the CLI leaves a non-directory node at -e -------------------------------
# Whatever the CLI leaves at that path is this tool's own litter once the
# reservation succeeded, and leaving ANY of it behind makes every later run on that
# project refuse until a human deletes it by hand — which is what the old teardown
# did with both the node and the lock.
LOCK_FILE=$(new_project lockfile src/main.rs)
inspect "$LOCK_FILE" lock-node-not-a-dir --edir-as-file
expect_rc "-e left as a FILE: the run fails, because there is no report to read" 1
stderr_has "-e left as a FILE: reported as a missing report directory" \
	"wrote no report directory"
path_absent "-e left as a FILE: the teardown removes the node anyway" "$LOCK_FILE/-e"
path_absent "-e left as a FILE: AND the lock, so a later run is not blocked forever" \
	"$LOCK_FILE/-e.lock"

# ===========================================================================
section "the single-instance preflight — refused in milliseconds, not minutes"
# ===========================================================================
# IntelliJ's headless `inspect` CLI refuses to start while another instance of the
# SAME IDE is already running, which is the ORDINARY state of a developer's machine.
# Without the preflight that collision is discovered only by launching the CLI and
# waiting out the whole attempt for its own message to arrive via the log tail,
# several minutes later.
#
# WHY A FIXTURE PROCESS TABLE AND NOT REAL PROCESSES: see lib/stubs.sh's
# init_ps_stub. In short, most of the claims below are NEGATIVES about the WHOLE
# table ("nothing in it is the resolved binary"), which no real machine's table can
# support — not least because it would contain THIS SUITE'S OWN argv, which carries
# the resolved path via --idea-bin and is the precise false positive the argv[0]
# anchoring exists to avoid.
#
# The tables are generated rather than committed, for the same reason the
# absolute-file-URL fixture above is: every line has to name the resolved binary's
# real mktemp path.
mkdir -p "$WORK/pstables"

# ps_table NAME LINE... — a fixture process table, one process per LINE in the
# shape `ps -A -o pid= -o args=` emits, and print its path.
#
# The pids are written RIGHT-ALIGNED, as the real `ps` pads them, and that padding
# is load-bearing rather than cosmetic: it is what running_idea_pid's
# field-splitting `read` has to consume as a separator. The `IFS= read -r` the rest
# of lib/intellij.sh uses would instead put the whole line in the pid and leave the
# command line empty, matching nothing ever again.
ps_table() {
	pt_file="$WORK/pstables/$1"
	shift
	: >"$pt_file"
	for pt_line in "$@"; do printf '%s\n' "$pt_line" >>"$pt_file"; done
	printf '%s' "$pt_file"
}

# The POSIX request the tool makes, flattened to one line for a single assertion:
# `-A` for every process rather than this terminal's, and the `args` keyword both
# the BSD and procps userlands accept where `command` is a BSD-only spelling.
PS_REQUEST='-A|-o|pid=|-o|args=|'
ps_request_made() { tr '\n' '|' <"$PS_STUB_ARGV_LOG"; }

# REFUSAL_PREFIX — the needle every assertion below matches the refusal by, and
# deliberately the whole opening clause rather than the short "already running".
# The DEGRADATION WARNING contains that shorter phrase too — it names the check as
# the "is the IDE already running" preflight — so a `stderr_not_has "already
# running"` is really a claim about whichever of the two messages happened to be
# printed, not about the refusal. Found by mutation while writing this section:
# discarding the scan's result made four of the negative assertions fail for the
# warning appearing rather than for a run being refused.
REFUSAL_PREFIX='IntelliJ IDEA is already running (PID'

RUNNING_PID=4242
RUNNING_PID_WITH_ARGS=9001

# --- a process whose command line IS the resolved binary ---------------------
inspect "$BASIC_PROJECT" preflight-match \
	--ps-table "$(ps_table match "  $RUNNING_PID $RESOLVED_IDEA_BIN")"
expect_rc "preflight: an IDE already running from the resolved binary is refused" 1
stderr_has "preflight: and the refusal names the pid AND the binary it was found at" \
	"$REFUSAL_PREFIX $RUNNING_PID) from $RESOLVED_IDEA_BIN"
stderr_has "preflight: with the remedy, and why a second instance cannot be started" \
	"cannot start a second instance of that IDE"
equals "preflight: the CLI was never launched, which is the entire point of the check" \
	"$(grep -c . "$IDEA_STUB_ARGV_LOG" || true)" "0"
equals "preflight: the process table is asked for in the POSIX pid+args form both userlands accept" \
	"$(ps_request_made)" "$PS_REQUEST"

# --- the same process, started WITH arguments --------------------------------
# The anchored `case` pattern has two alternatives and each is separately
# reachable: the bare path matches a command line of nothing else, `"$bin "*` one
# that carries arguments — which is what a really-running IDE looks like. Deleting
# either alternative leaves the other's test green.
inspect "$BASIC_PROJECT" preflight-match-with-args \
	--ps-table "$(ps_table match-with-args " $RUNNING_PID_WITH_ARGS $RESOLVED_IDEA_BIN -Xmx2g /some/project")"
expect_rc "preflight: a running IDE that carries arguments is refused too" 1
stderr_has "preflight: and the pid reported is that process's" \
	"$REFUSAL_PREFIX $RUNNING_PID_WITH_ARGS) from $RESOLVED_IDEA_BIN"

# --- nothing in the table is the resolved binary -----------------------------
# The regression guard: with a table `ps` really did serve and no match in it, the
# run has to behave exactly as every other test in this suite does.
inspect "$BASIC_PROJECT" preflight-no-match \
	--ps-table "$(ps_table no-match \
		"  501 /sbin/launchd" \
		" 8123 /Applications/Firefox.app/Contents/MacOS/firefox" \
		" 9004 /usr/bin/vim notes.md")"
expect_rc "preflight: an unrelated process table does not block the run" 0
stderr_not_has "preflight: nothing is reported as already running" \
	"$REFUSAL_PREFIX"
stderr_not_has "preflight: nor is the scan reported as skipped, so \`ps\` really was read" \
	"could not read the process table"
log_has_token "preflight: the CLI is launched as usual" "$IDEA_STUB_ARGV_LOG" "inspect"
json_eq "preflight: and the output is the ordinary one" "$OUT" '[.issues[].id]' '["MyRule"]'

# --- the resolved path appears in a command line, but not at argv[0] ---------
# THE FALSE POSITIVE THIS TOOL WOULD OTHERWISE HAVE ABOUT ITSELF. A caller who
# passed --idea-bin has the resolved path in inspect-project's own argv, as does any
# editor, grep or sibling run that mentions it. The two lines below are those two
# shapes — the path inside a later token, and as a whole later token — and the naive
# anywhere-match (`case "$cmd" in *"$bin"*`) refuses the run on either of them.
inspect "$BASIC_PROJECT" preflight-not-at-argv0 \
	--ps-table "$(ps_table not-at-argv0 \
		" 7771 some-wrapper --idea-bin=$RESOLVED_IDEA_BIN --scope all" \
		" 7772 /usr/bin/grep -rl $RESOLVED_IDEA_BIN /tmp")"
expect_rc "preflight: the path appearing anywhere but argv[0] is not a running IDE" 0
stderr_not_has "preflight: so nothing is refused because of this tool's own command line" \
	"$REFUSAL_PREFIX"

# --- argv[0] EXTENDS the resolved path, with no separator --------------------
# A prefix match (`"$bin"*` in place of `"$bin"|"$bin "*`) accepts this, and a
# sibling JetBrains launcher whose name merely starts the same way is a real shape
# rather than a contrived one.
inspect "$BASIC_PROJECT" preflight-extends \
	--ps-table "$(ps_table extends " 7781 $RESOLVED_IDEA_BIN-ultimate /some/project")"
expect_rc "preflight: a command line that extends the path without a separator does not match" 0
stderr_not_has "preflight: so an extended argv[0] is not refused" \
	"$REFUSAL_PREFIX"

# --- argv[0] is a proper PREFIX of the resolved path, i.e. truncated ---------
# A truncated `ps` line loses its RIGHT end, so a shortened form of the very path
# being looked for is the one near-miss the table can genuinely contain. Matching it
# would refuse the run because of a process that is not the IDE at all.
TRUNCATED_IDEA_BIN=${RESOLVED_IDEA_BIN%?}
inspect "$BASIC_PROJECT" preflight-truncated \
	--ps-table "$(ps_table truncated " 7791 $TRUNCATED_IDEA_BIN")"
expect_rc "preflight: a truncated prefix of the resolved path does not match either" 0
stderr_not_has "preflight: so a truncated argv[0] is not refused" \
	"$REFUSAL_PREFIX"

# --- `ps` is on PATH but cannot read the table -------------------------------
# The `ps` a hardened or minimal container host gives. A scan that could not run is
# "cannot tell", never "nothing is running", and never a reason to fail an
# inspection that would otherwise work.
inspect "$BASIC_PROJECT" preflight-ps-fails --ps-fail
expect_rc "failing \`ps\`: the run proceeds — the preflight is an optimization, not a gate" 0
stderr_has "failing \`ps\`: the skipped preflight is announced, with what skipping it costs" \
	"the \"is the IDE already running\" preflight was skipped"
equals "failing \`ps\`: and \`ps\` really was invoked, so this is the FAILING path and not the absent one" \
	"$(ps_request_made)" "$PS_REQUEST"
json_eq "failing \`ps\`: the inspection still produces its ordinary output" \
	"$OUT" '[.issues[].id]' '["MyRule"]'

# --- `ps` is not on PATH at all: THE DEFAULT ENVIRONMENT OF THIS SUITE -------
# Every other test in this file runs with `ps` genuinely absent (see run() above),
# so all of them traverse this degradation path already — and not one of them says
# so, which would leave the tool's documented "cannot tell, warn and proceed"
# behaviour resting on an accident of the harness's PATH rather than on a claim
# somebody made on purpose. This is that claim, stated once, deliberately.
inspect "$BASIC_PROJECT" preflight-ps-absent
expect_rc "absent \`ps\`: the run proceeds, exactly as it does everywhere else in this suite" 0
stderr_has "absent \`ps\`: with the same skipped-preflight warning a failing \`ps\` produces" \
	"the \"is the IDE already running\" preflight was skipped"
equals "absent \`ps\`: and the stub was never reached, so \`ps\` was genuinely missing rather than serving an empty table" \
	"$(grep -c . "$PS_STUB_ARGV_LOG" || true)" "0"

# ===========================================================================
section "a report file that cannot be parsed is COUNTED, not just warned about"
# ===========================================================================
# The warning goes to stderr, which the machine channel an agent reads does not
# carry — so with every report file unparseable, `total_issues: 0` reads as
# "clean" with nothing in the JSON saying otherwise.
PARTIAL_PARSE=$(new_project partialparse src/main.rs)
inspect "$PARTIAL_PARSE" unparsed --edir "$FIXTURES/edir-one-malformed"
expect_rc "unparsed report: one bad file does not fail the run" 0
json_eq "unparsed report: the count reaches the machine-readable metadata" \
	"$OUT" '.metadata.unparsed_report_files' '1'
json_eq "unparsed report: and the GOOD file's findings are still collected" \
	"$OUT" '[.issues[].id]' '["GoodRule"]'
json_eq "unparsed report: so total_issues counts what survived, alongside the marker" \
	"$OUT" '[.metadata.total_issues, .metadata.unparsed_report_files]' '[1,1]'
stderr_has "unparsed report: the unreadable file is named" \
	"could not parse the IntelliJ report file"
stderr_has "unparsed report: and it says its findings are missing from the output" \
	"its findings are NOT in the output"

inspect "$PARTIAL_PARSE" unparsed-none
json_eq "unparsed report: a wholly readable report reports zero, not null" \
	"$OUT" '.metadata.unparsed_report_files' '0'

# ===========================================================================
section "detect_project_languages — the extension-to-label table"
# ===========================================================================
POLYGLOT=$(new_project polyglot \
	src/a.ts src/b.tsx src/c.js src/d.jsx main.rs README.md package.json \
	tsconfig.json5 config.yaml other.yml Cargo.toml script.sh query.sql \
	Main.java App.kt build.gradle.kts \
	page.html style.css pom.xml api.proto app.properties tool.py svc.go \
	rake.rb index.php Program.cs core.c core.h engine.cpp \
	.gitignore notes.unmappedext)
inspect "$POLYGLOT" languages --edir "$FIXTURES/edir-basic"
expect_rc "languages: the run succeeds" 0
json_eq "languages: every mapped extension becomes its IntelliJ label, distinct and sorted" \
	"$OUT" '.metadata.languages_detected_in_project' \
	'["C","C#","C++","CSS","Go","HTML","JAVA","JSON","JSON5","JavaScript","Markdown","PHP","Properties","Python","Ruby","Rust","SQL","Shell Script","TOML","TypeScript","XML","kotlin","protobuf","yaml"]'

CASED=$(new_project cased LIB.RS APP.TS)
inspect "$CASED" languages-case
json_eq "languages: an UPPERCASE extension still maps, because extensions are lowercased first" \
	"$OUT" '.metadata.languages_detected_in_project' '["Rust","TypeScript"]'

PRUNED=$(new_project pruned \
	keep.ts \
	node_modules/dep/skip.py .git/objects/skip.rb dist/skip.php build/skip.cs \
	target/skip.go vendor/skip.sql .wrangler/skip.html .idea/skip.xml \
	.scannerwork/skip.css)
inspect "$PRUNED" languages-pruned
json_eq "languages: every pruned directory's files are excluded from detection" \
	"$OUT" '.metadata.languages_detected_in_project' '["TypeScript"]'

# --- the five stages are separately checked, so a half-failed scan SAYS SO ----
# POSIX sh has no `pipefail`, so the single pipe this used to be reported only the
# LAST stage's status: an interrupted `find` produced an empty language list with
# no error, which is indistinguishable from a project written in nothing the table
# maps — and "empty means not-checked" blindness is the exact thing
# detect_project_languages exists to remove.
#
# An UNREADABLE SUBDIRECTORY is a real `find` failure rather than a simulated one:
# verified, BSD and GNU find both exit non-zero when they cannot descend. The
# fixture asserts that precondition itself first, so a host where it does not hold
# (a run as root) fails HERE, naming the reason, instead of leaving the section
# passing vacuously.
UNREADABLE=$(new_project unreadable keep.ts)
mkdir -p "$UNREADABLE/locked"
chmod 000 "$UNREADABLE/locked"
UNREADABLE_FIND_RC=0
find "$UNREADABLE" -type f -print >/dev/null 2>/dev/null || UNREADABLE_FIND_RC=$?
equals "find failure: the fixture really does make \`find\` itself fail" \
	"$([ "$UNREADABLE_FIND_RC" -ne 0 ] && printf 'find failed' || printf 'find succeeded')" \
	"find failed"

inspect "$UNREADABLE" languages-find-fails
chmod 755 "$UNREADABLE/locked"
expect_rc "find failure: the run still completes, because this is a disclosure not a fault" 0
stderr_has "find failure: the failed enumeration is announced, never silent" \
	"could not enumerate the files under $UNREADABLE"
stderr_has "find failure: and it says what the output will therefore be missing" \
	"intellij.json will report no detected languages and no coverage gaps"
json_eq "find failure: the empty list is what the JSON records" \
	"$OUT" '.metadata.languages_detected_in_project' '[]'
json_eq "find failure: with no coverage claimed for anything" \
	"$OUT" '.metadata.language_coverage' '[]'

# --- and the correct path still normalizes exactly as it did -----------------
# The regression guard on the refactor from one pipe to five stages, asserted
# end-to-end rather than stage by stage: every extension here is UPPERCASE (so the
# lowercasing stage is load-bearing — the label table matches lowercase only) and
# two of them map to the SAME label (so the collating stage is too).
#
# WHAT THIS DOES NOT CLAIM, checked by mutation rather than assumed: it does not
# pin the DISTINCT-extensions stage. Replacing that `sort -u` with a plain `cat`
# leaves this — and every other language assertion in the suite — green, because
# the labels are collated by a second `sort -u` at the end that subsumes it. That
# stage is a cost narrowing (tens of extensions instead of tens of thousands of
# files), not a correctness one, and pretending otherwise here would be a claim
# this test cannot back.
UPPER_CASE=$(new_project uppercase a.TS b.TSX c.RS d.MD)
inspect "$UPPER_CASE" languages-normalized
json_eq "languages: uppercase extensions still map, and two of one label collapse to one entry" \
	"$OUT" '.metadata.languages_detected_in_project' '["Markdown","Rust","TypeScript"]'

# ===========================================================================
section "language_coverage — the three ways a language can be covered or not"
# ===========================================================================
# When a language's plugin is not installed, the headless inspection reports ZERO
# findings for its files: no error, no warning, indistinguishable from clean code.
# These three statuses are the tool's answer to that, and they are the reason
# `intellij.json` can be trusted at all.
RUSTY=$(new_project rusty src/main.rs Cargo.toml)

inspect "$RUSTY" coverage-missing --edir "$FIXTURES/edir-basic"
json_eq "coverage: a language absent from the profile entirely is not_installed" \
	"$OUT" "$(coverage_of Rust)" \
	'{"language":"Rust","status":"not_installed","plugins":[]}'
json_eq "coverage: a language the profile DOES enable is covered, with its plugin named" \
	"$OUT" "$(coverage_of TOML)" \
	'{"language":"TOML","status":"covered","plugins":[{"plugin_id":"org.toml.lang","plugin_version":"262.8665.337"}]}'

inspect "$RUSTY" coverage-disabled --edir "$FIXTURES/edir-lang-disabled"
json_eq "coverage: a language present but switched OFF everywhere is disabled_in_profile" \
	"$OUT" "$(coverage_of Rust)" \
	'{"language":"Rust","status":"disabled_in_profile","plugins":[]}'

inspect "$RUSTY" coverage-plugins --edir "$FIXTURES/edir-plugin-dedup"
json_eq "coverage: two inspections from ONE plugin+version collapse to one plugins[] entry" \
	"$OUT" "$(coverage_of Rust)" \
	'{"language":"Rust","status":"covered","plugins":[{"plugin_id":"com.other.rust","plugin_version":"2.0"},{"plugin_id":"org.rust.lang","plugin_version":"1.0"}]}'
json_eq "coverage: another language's plugin does not leak into this one's plugins[]" \
	"$OUT" "[$(coverage_of Rust) | .plugins[].plugin_id] | index(\"org.toml.lang\")" 'null'

inspect "$RUSTY" coverage-case --edir "$FIXTURES/edir-lang-case"
json_eq "coverage: the language match is case-insensitive, so 'rUsT' covers 'Rust'" \
	"$OUT" "$(coverage_of Rust) | .status" '"covered"'

# ===========================================================================
section "an unreadable profile fails CONSERVATIVELY, never optimistically"
# ===========================================================================
# Every signal drops to the value that makes a caller DISTRUST an empty result set,
# because the alternative — reporting "covered" for a profile nobody could read —
# turns a broken run into a clean bill of health.
inspect "$RUSTY" profile-malformed --edir "$FIXTURES/edir-malformed"
expect_rc "unparseable .descriptions.json: the run still succeeds" 0
stderr_has "unparseable .descriptions.json: the degradation is announced" "could not parse"
json_eq "unparseable: the profile name is reported as unknown" \
	"$OUT" '.metadata.inspection_profile' '"unknown"'
json_eq "unparseable: every detected language degrades to not_installed" \
	"$OUT" '[.metadata.language_coverage[].status] | unique' '["not_installed"]'
json_eq "unparseable: both SonarLint signals degrade to false" \
	"$OUT" '[.metadata.sonarlint_rules_registered_in_profile, .metadata.sonarlint_rules_enabled_in_profile]' \
	'[false,false]'
json_eq "unparseable: the findings themselves are still collected" \
	"$OUT" '[.issues[].id]' '["MyRule"]'

inspect "$RUSTY" profile-absent --edir "$FIXTURES/edir-no-descriptions"
expect_rc "no .descriptions.json at all: the run still succeeds" 0
stderr_has "no .descriptions.json: the degradation is announced" "no .descriptions.json in"
json_eq "no .descriptions.json: the profile name is reported as unknown" \
	"$OUT" '.metadata.inspection_profile' '"unknown"'
json_eq "no .descriptions.json: the findings are still collected" \
	"$OUT" '[.issues[].id]' '["MyRule"]'

# ===========================================================================
section "the SonarLint profile signals are a pluginId match, NOT a text search"
# ===========================================================================
# An earlier version scanned the whole document for the word "sonar", which also
# matched the word appearing inside a rule's HTML description. Now that the
# per-entry schema is known the match is exact — and this is the test that pins the
# NEW behaviour, so a regression to the fuzzy scan fails loudly.
inspect "$RUSTY" sonarlint-description-only --edir "$FIXTURES/edir-sonar-in-description"
json_eq "sonarlint: 'sonar' in a rule DESCRIPTION alone registers nothing" \
	"$OUT" '[.metadata.sonarlint_rules_registered_in_profile, .metadata.sonarlint_rules_enabled_in_profile]' \
	'[false,false]'
stderr_has "sonarlint: the human summary warns that an empty Sonar result means \"not checked\"" \
	"a zero-Sonar result here means \"not checked\", not \"clean\""

inspect "$RUSTY" sonarlint-enabled --edir "$FIXTURES/edir-sonar-plugin-enabled"
json_eq "sonarlint: a pluginId mentioning sonar in MIXED case is both registered and enabled" \
	"$OUT" '[.metadata.sonarlint_rules_registered_in_profile, .metadata.sonarlint_rules_enabled_in_profile]' \
	'[true,true]'
stderr_not_has "sonarlint: and the \"not checked\" warning is then NOT printed" \
	"a zero-Sonar result here means"

inspect "$RUSTY" sonarlint-disabled --edir "$FIXTURES/edir-sonar-plugin-disabled"
json_eq "sonarlint: installed-but-switched-off is registered=true, enabled=false" \
	"$OUT" '[.metadata.sonarlint_rules_registered_in_profile, .metadata.sonarlint_rules_enabled_in_profile]' \
	'[true,false]'

# --- the separate, weaker "is the IDE plugin installed" signal --------------
inspect "$RUSTY" sonarlint-plugin-absent --edir "$FIXTURES/edir-basic"
json_eq "sonarlint plugin: absent from this HOME, so false" \
	"$OUT" '.metadata.sonarlint_plugin_installed' 'false'

mkdir -p "$HARNESS_HOME/Library/Application Support/JetBrains/IdeaIC2026.2/plugins/sonarlint-intellij"
inspect "$RUSTY" sonarlint-plugin-present
json_eq "sonarlint plugin: found under an IDE config directory, so true" \
	"$OUT" '.metadata.sonarlint_plugin_installed' 'true'
json_eq "sonarlint plugin: installed for the IDE is still NOT 'registered in this profile'" \
	"$OUT" '.metadata.sonarlint_rules_registered_in_profile' 'false'
rm -rf "$HARNESS_HOME/Library"

# ===========================================================================
section "issue normalization"
# ===========================================================================
SHAPES=$(new_project shapes src/a.ts src/b.ts src/c.ts)
inspect "$SHAPES" issue-shapes --edir "$FIXTURES/edir-issue-shapes"
expect_rc "issue shapes: the run succeeds" 0
json_eq "issue shapes: the \$PROJECT_DIR\$ macro is stripped to a project-relative path" \
	"$OUT" '[.issues[].file]' '["src/a.ts","src/b.ts","src/c.ts"]'
json_eq "issue shapes: a line given as a STRING is coerced to a number" \
	"$OUT" '.issues[0].line' '42'
json_eq "issue shapes: a missing line becomes null rather than a broken field" \
	"$OUT" '.issues[1].line' 'null'
json_eq "issue shapes: a missing problem_class falls back to the report file's own name" \
	"$OUT" '[.issues[0].id, .issues[1].id]' '["DefaultsProbe","DefaultsProbe"]'
json_eq "issue shapes: a missing severity becomes UNKNOWN, never empty" \
	"$OUT" '.issues[0].severity' '"UNKNOWN"'
json_eq "issue shapes: an explicit problem_class id wins over the file name" \
	"$OUT" '.issues[2].id' '"ExplicitId"'
json_eq "issue shapes: a missing language becomes null" "$OUT" '.issues[0].language' 'null'

# --- the OTHER file spelling the report uses -------------------------------
# lib/intellij.sh strips three prefixes because the report has been observed to
# spell `file` two ways. This fixture has to be generated rather than committed:
# the second spelling is a plain absolute URL, so it can only be written once the
# project's real temp path is known.
ABS_EDIR="$WORK/edir-absolute-url"
mkdir -p "$ABS_EDIR"
cp "$FIXTURES/edir-issue-shapes/.descriptions.json" "$ABS_EDIR/.descriptions.json"
jq -n --arg f "file://$SHAPES/src/a.ts" '{
	problems: [ { file: $f, line: 5, problem_class: { id: "AbsUrl", severity: "ERROR" }, description: "absolute file URL" } ]
}' >"$ABS_EDIR/AbsUrlRule.json"
inspect "$SHAPES" issue-absolute-url --edir "$ABS_EDIR"
json_eq "issue shapes: a plain absolute file:// URL is also reduced to a project-relative path" \
	"$OUT" '[.issues[].file]' '["src/a.ts"]'

# ===========================================================================
section "--exclude-ids: default, replace, extend, disable"
# ===========================================================================
# The fixture is built so BOTH matching modes are exercised: MyRule.json declares
# the id `MyRule` (an id match), while SpellCheckingInspection.json declares the id
# `Typo` (a REPORT-FILE match — the two diverge for several inspections, and the
# linguistic-noise defaults are named by file).

inspect "$BASIC_PROJECT" exclude-default --edir "$FIXTURES/edir-basic"
json_eq "exclude-ids default: the linguistic-noise list applies" \
	"$OUT" '.metadata.excluded_ids' \
	'["GrazieInspection","GrazieStyle","SpellCheckingInspection"]'
json_eq "exclude-ids default: a finding is matched by its REPORT FILE, not only its id" \
	"$OUT" '[.issues[].id]' '["MyRule"]'
json_eq "exclude-ids default: the drop is disclosed as a count" \
	"$OUT" '[.metadata.total_issues, .metadata.excluded_count]' '[1,1]'

inspect "$BASIC_PROJECT" exclude-replace --exclude-ids MyRule
json_eq "exclude-ids replace: a bare value REPLACES the default list outright" \
	"$OUT" '.metadata.excluded_ids' '["MyRule"]'
json_eq "exclude-ids replace: so the previously excluded finding comes back" \
	"$OUT" '[.issues[].id]' '["Typo"]'

inspect "$BASIC_PROJECT" exclude-extend --exclude-ids +MyRule
json_eq "exclude-ids extend: a leading + EXTENDS the default list" \
	"$OUT" '.metadata.excluded_ids' \
	'["GrazieInspection","GrazieStyle","SpellCheckingInspection","MyRule"]'
json_eq "exclude-ids extend: and both findings are dropped" "$OUT" '.issues' '[]'
json_eq "exclude-ids extend: with the count disclosing both" \
	"$OUT" '[.metadata.total_issues, .metadata.excluded_count]' '[0,2]'

inspect "$BASIC_PROJECT" exclude-none --exclude-ids ''
json_eq "exclude-ids empty: an empty value disables exclusion entirely" \
	"$OUT" '.metadata.excluded_ids' '[]'
json_eq "exclude-ids empty: so every finding is kept" \
	"$OUT" '[.issues[].id] | sort' '["MyRule","Typo"]'
json_eq "exclude-ids empty: and nothing is reported as excluded" \
	"$OUT" '.metadata.excluded_count' '0'

inspect "$BASIC_PROJECT" exclude-spaces --exclude-ids ' MyRule , Typo '
json_eq "exclude-ids: surrounding whitespace around each id is trimmed" \
	"$OUT" '.metadata.excluded_ids' '["MyRule","Typo"]'
json_eq "exclude-ids: so both are actually matched" "$OUT" '.issues' '[]'

# ===========================================================================
section "finding nothing is not a failure"
# ===========================================================================
inspect "$BASIC_PROJECT" empty-report --edir "$FIXTURES/edir-empty-report"
expect_rc "empty report: exit 0" 0
json_eq "empty report: an empty issues array, not a missing one" "$OUT" '.issues' '[]'
json_eq "empty report: and the counts agree" \
	"$OUT" '[.metadata.total_issues, .metadata.excluded_count]' '[0,0]'
json_eq "empty report: the profile is still reported" \
	"$OUT" '.metadata.inspection_profile' '"Nothing Fired"'

# ===========================================================================
section "the inspection child never inherits the Sonar token"
# ===========================================================================
# $SONAR_TOKEN is the channel this tool RECOMMENDS over --sonar-token, so an
# operator who followed that advice has it exported in the shell that starts the
# run — and IntelliJ's project import evaluates the project's OWN build logic
# (Gradle/Maven) and loads its plugins. Inheriting the token here would hand the
# inspected repository's code a live credential it has no use for, which is a
# least-privilege gap and not merely untidiness.
#
# THE `unset` IS SCOPED TO THAT CHILD'S SUBSHELL, which is why the CLI stub had to
# grow an environment recorder to observe it at all: nothing the parent process can
# be asked about afterwards shows the difference. See lib/stubs.sh's
# init_idea_stub. The companion half of this claim — that the SCANNER, the one
# child that genuinely needs the token, still gets it in the SAME run — is asserted
# in run-sonar-tests.sh, where a `--engine both` run launches both children.
TOKEN_PROJECT=$(new_project tokenproject src/main.rs)
INHERITED_TOKEN='squ_inherited_t0ken'

inspect "$TOKEN_PROJECT" token-not-inherited --token "$INHERITED_TOKEN"
expect_rc "token scrub: the run succeeds with a token exported around it" 0
log_has_token "token scrub: the inspection child's \$SONAR_TOKEN is unset, not inherited" \
	"$IDEA_STUB_ENV_LOG" "SONAR_TOKEN=<unset>"
file_not_has "token scrub: and the value is in no other variable of that child either" \
	"$IDEA_STUB_ENV_LOG" "$INHERITED_TOKEN"
# NOT ASSERTED HERE: "nor anywhere in the child's argv". The IntelliJ CLI has no
# token flag and this tool builds that argv from two fixed literal forms, so there
# is no mutation short of inventing a flag that could put it there — an assertion
# that cannot fail, unlike its counterpart in run-sonar-tests.sh, where
# `-Dsonar.token=` is a real alternative the tool deliberately does not use.

# The control that makes the assertion above mean something: the recorder really
# does see a variable that IS inherited, so "SONAR_TOKEN=<unset>" is the scrub
# working rather than the recorder seeing nothing at all.
log_has_token "token scrub: while a variable the run DOES pass through is visible to the recorder" \
	"$IDEA_STUB_ENV_LOG" "HOME=$HARNESS_HOME"

# ===========================================================================
section "a world-writable project directory is WARNED about, never refused"
# ===========================================================================
# lib/intellij.sh's reserve_idea_report_dir documents an accepted residual risk: a
# window remains between its refusal of a pre-planted `-e` and the CLI creating
# one, and a local user with WRITE ACCESS TO THE PROJECT DIRECTORY can win it by
# planting a symlink for the report to be written through. The assumption the tool
# therefore makes — that nobody else can write the project directory — is cheaply
# checkable in exactly one case, and that case is warned about.
#
# A WARNING AND NOT A REFUSAL, because the run is still the caller's to make; and
# GROUP-writability deliberately does NOT trigger it, because a per-user group with
# a 002 umask makes group-writable project directories ordinary on some systems and
# a warning there would be a false positive. The 0775 case below is the regression
# guard on that stated non-goal — without it, widening the permission test to
# `-perm -0022` would pass unnoticed.
WORLD_WRITABLE=$(new_project worldwritable src/main.rs)
chmod 0777 "$WORLD_WRITABLE"
inspect "$WORLD_WRITABLE" perm-world-writable
expect_rc "world-writable project: the run still succeeds — this is a warning, not a gate" 0
stderr_has "world-writable project: the directory is named as world-writable" \
	"$WORLD_WRITABLE is world-writable"
stderr_has "world-writable project: with the concrete attack and the remedy spelled out" \
	"any local user can plant a symlink at $WORLD_WRITABLE/-e in the window between this run's check and the IntelliJ CLI creating it"
path_exists "world-writable project: and the output was written all the same" "$OUT"

GROUP_WRITABLE=$(new_project groupwritable src/main.rs)
chmod 0775 "$GROUP_WRITABLE"
inspect "$GROUP_WRITABLE" perm-group-writable
expect_rc "group-writable project: the run succeeds" 0
stderr_not_has "group-writable project: NO warning — group-writable alone is a false positive" \
	"is world-writable"

PLAIN_PERMS=$(new_project plainperms src/main.rs)
chmod 0755 "$PLAIN_PERMS"
inspect "$PLAIN_PERMS" perm-plain
expect_rc "ordinary 0755 project: the run succeeds" 0
stderr_not_has "ordinary 0755 project: and says nothing about permissions" "is world-writable"

# ===========================================================================
section "project-derived text cannot inject an escape sequence into the terminal"
# ===========================================================================
# Almost everything this script's diagnostics interpolate is authored elsewhere: a
# report filename, an inspection profile name, a severity string, the tail of an
# external tool's log. A terminal INTERPRETS the C0 control bytes in that text — ESC
# starts an ANSI/OSC sequence that can rewrite what is already on screen, set the
# window title, or plant text in the operator's input buffer — so a maliciously
# named file in an inspected repository is a terminal-injection sink (CWE-150).
#
# TWO SITES, DELIBERATELY, because they are filtered by two different mechanisms
# and one test cannot cover both: the parse warning goes through lib/runtime.sh's
# warn(), while the severity breakdown pipes jq's output through
# strip_control_bytes directly and never touches a writer. The stdout counterpart —
# that the MACHINE channel is deliberately left byte-exact — lives in
# run-sonar-tests.sh, where the only stdout key carrying project-derived text is.
ESC=$(printf '\033')

# --- the report FILENAME, reaching stderr through warn() --------------------
# Generated rather than committed, for the reason the absolute-file-URL fixture
# above is: a filename carrying a raw ESC byte is not a thing to keep in a
# repository. The file is deliberately not JSON, so the parse warning that names it
# is the diagnostic under test.
ESC_NAME_EDIR="$WORK/edir-esc-report-name"
mkdir -p "$ESC_NAME_EDIR"
cp "$FIXTURES/edir-basic/.descriptions.json" "$ESC_NAME_EDIR/.descriptions.json"
printf 'not json at all\n' >"$ESC_NAME_EDIR/evil${ESC}[31mfile.json"

inspect "$BASIC_PROJECT" esc-report-name --edir "$ESC_NAME_EDIR"
expect_rc "ESC in a report filename: the run still succeeds" 0
equals "ESC in a report filename: stderr carries ZERO control bytes" \
	"$(control_byte_count "$CUR_ERR")" "0"
stderr_has "ESC in a report filename: while the real diagnostic around it is intact" \
	"could not parse the IntelliJ report file"
stderr_has "ESC in a report filename: and the name's printable remainder is still shown, so the file is identifiable" \
	"evil[31mfile.json"

# --- a SEVERITY string, reaching stderr through the breakdown renderer -------
ESC_SEVERITY_EDIR="$WORK/edir-esc-severity"
mkdir -p "$ESC_SEVERITY_EDIR"
cp "$FIXTURES/edir-basic/.descriptions.json" "$ESC_SEVERITY_EDIR/.descriptions.json"
jq -n --arg sev "WARN${ESC}[31mING" '{
	problems: [ { file: "file://$PROJECT_DIR$/src/main.rs", line: 1,
		problem_class: { id: "EscSeverity", severity: $sev }, description: "escape in a severity" } ]
}' >"$ESC_SEVERITY_EDIR/EscSeverity.json"

inspect "$BASIC_PROJECT" esc-severity --edir "$ESC_SEVERITY_EDIR"
expect_rc "ESC in a severity string: the run still succeeds" 0
equals "ESC in a severity string: stderr still carries ZERO control bytes" \
	"$(control_byte_count "$CUR_ERR")" "0"
stderr_has "ESC in a severity string: and the breakdown line still reports the finding" \
	"WARN[31mING: 1"
# NOT ASSERTED HERE, and the omission is deliberate: "intellij.json keeps the
# severity verbatim, escaped rather than stripped". It reads like the companion
# claim to the two above, but it cannot fail. A control byte only ever exists in a
# report file as a six-character backslash-u escape — that is how JSON carries one
# at all — so it is already ordinary printable text by the time this tool reads it,
# and jq re-emitting it is jq's behaviour rather than this tool's. Verified: a
# mutation that pipes the whole report through strip_control_bytes before jq sees
# it leaves such an assertion green, and no realistic mutation does not. Caught by
# mutation while writing this section, and left out rather than shipped as false
# confidence; intellij.json's shape is pinned by the golden document below.

# ===========================================================================
section "metadata records the run's own inputs"
# ===========================================================================
inspect "$BASIC_PROJECT" metadata --edir "$FIXTURES/edir-basic"
json_eq "metadata: the engine is named" "$OUT" '.metadata.engine' '"intellij-inspect"'
json_eq "metadata: the project path is recorded verbatim" \
	"$OUT" '.metadata.project' "\"$BASIC_PROJECT\""
json_eq "metadata: the project name is its real basename" \
	"$OUT" '.metadata.project_name' '"basic"'
json_eq "metadata: the scope is recorded" "$OUT" '.metadata.scope' '"all"'
json_eq "metadata: generated_at is the UTC stamp, not the local one" \
	"$OUT" '.metadata.generated_at' "\"$DATE_STUB_UTC\""

# --- the whole document, against a committed golden -------------------------
# Every assertion above this line is a FIELD PROBE, and a field probe can only see
# the field it names. A metadata key silently ADDED, REMOVED or RENAMED is
# therefore invisible to all of them together, while being exactly the kind of
# change that breaks the agents consuming this file. This is the one assertion that
# fails on it. See harness.sh's json_golden for the masking rule and for how to
# regenerate the golden deliberately.
json_golden "metadata: intellij.json matches the committed golden document, key for key" \
	"$OUT" "$FIXTURES/golden/intellij.json"

summarize
