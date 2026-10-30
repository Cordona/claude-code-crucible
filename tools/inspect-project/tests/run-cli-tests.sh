#!/usr/bin/env sh
#
# run-cli-tests.sh — the command-line contract: argument parsing and validation,
#                    the exit-code vocabulary, the two output channels, and the
#                    dated run-directory layout.
#
# THE THREE EXIT CODES ARE THE CONTRACT, and separating them is most of this file:
#   0  the requested engines ran — INCLUDING when they found problems
#   1  something the caller asked for could not be done
#   2  the caller's own argv was wrong
# Several tests here assert an exit code AND assert the losing diagnostic ABSENT,
# because two different guards can produce the same code and only the message
# proves which one fired.
#
# THE CLOCK IS STUBBED (lib/stubs.sh's init_date_stub), which is what turns
# `<output-root>/YYYY/MM/DD/<project>/<HH-MM-SS>` from "a plausible-looking path" into
# an exact assertable string — and it is the only way to reach the same-second
# collision path deliberately instead of by luck.
#
# Usage:  sh run-cli-tests.sh
#         VERBOSE=1 sh run-cli-tests.sh
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

rig_setup "$TESTS_DIR" cli

# A second toolbox that is short exactly one tool, so "jq is not installed" is
# exercised by jq genuinely not being there.
NOJQ_BOX="$WORK/toolbox-nojq"
mkdir -p "$NOJQ_BOX"
for cli_tool in sh date uname mktemp mkdir rmdir rm cp cat sleep chmod tr sed \
	grep sort head tail wc find cut ls
do
	link_tool "$NOJQ_BOX" "$cli_tool"
done

run() {
	r_selector=$1; shift
	case "$r_selector" in
		full) r_path="$BIN_DATE:$BIN_IDEA:$TOOLBOX" ;;
		nojq) r_path="$BIN_DATE:$BIN_IDEA:$NOJQ_BOX" ;;
		*) printf 'FATAL: bad run() selector: %s\n' "$r_selector" >&2; exit 1 ;;
	esac
	harness_run "$r_path" "$@"
}

PROJECT=$(new_project cliproj src/main.rs)
IDEA_STUB_EDIR_SRC="$FIXTURES/edir-basic"

# inspect RESULTS_TAG [FLAGS...] — a complete, valid flag set. Tests that are about
# a MISSING or WRONG flag call `run` directly instead; this helper is for the ones
# that need a run to actually happen.
inspect() {
	i_root=$(results_root "$1")
	shift
	rig_reset_logs
	run full "$INSPECT" --project "$PROJECT" --scope all --engine intellij \
		--output-root "$i_root" --idea-bin "$BIN_IDEA/idea" "$@"
}

# ===========================================================================
section "--help"
# ===========================================================================
run full "$INSPECT" --help
expect_rc "--help: exit 0" 0
stdout_has "--help: the usage line is on STDOUT, because help was asked for" \
	"Usage: inspect-project.sh --project /abs/path"
stdout_has "--help: the documented output layout is shown" \
	"<output-root>/YYYY/MM/DD/<project-name>/<HH-MM-SS>/{intellij.json,sonar.json}"
stdout_has "--help: the machine keys are documented" "INSPECT_SONAR_SKIPPED_REASON=<text>"
stdout_has "--help: the default exclusion list is shown, not just described" \
	"Default: GrazieInspection,GrazieStyle,SpellCheckingInspection"
stdout_has "--help: the default output root is resolved against this HOME" \
	"Default: $HARNESS_HOME/.crucible-inspect-results"
stdout_has "--help: --sonar-token's argv exposure is documented at the flag" \
	"PREFER \$SONAR_TOKEN"

run full "$INSPECT" -h
expect_rc "-h: the short form behaves identically" 0
stdout_has "-h: same usage text" "Usage: inspect-project.sh --project /abs/path"

# ===========================================================================
section "usage errors exit 2, and say which value was wrong"
# ===========================================================================
run full "$INSPECT" --project "$PROJECT" --scope sideways --engine intellij
expect_rc "bad --scope: exit 2" 2
stderr_has "bad --scope: the rejected value is quoted back" \
	"--scope must be 'all' or 'changed-only', got: sideways"
stderr_has "bad --scope: the usage text accompanies the error" \
	"Usage: inspect-project.sh --project /abs/path"

run full "$INSPECT" --project "$PROJECT" --scope all --engine sideways
expect_rc "bad --engine: exit 2" 2
stderr_has "bad --engine: the rejected value is quoted back" \
	"--engine must be 'intellij', 'sonar' or 'both', got: sideways"

run full "$INSPECT" --project relative/path --scope all --engine intellij
expect_rc "relative --project: exit 2" 2
stderr_has "relative --project: the requirement is stated" \
	"--project must be an absolute path, got: relative/path"

run full "$INSPECT" --project "$WORK/no-such-directory" --scope all --engine intellij
expect_rc "non-existent --project: exit 2" 2
stderr_has "non-existent --project: the path is named" \
	"--project is not a directory: $WORK/no-such-directory"
stderr_not_has "non-existent --project: no usage dump — the value's shape was fine, the path was not" \
	"Usage: inspect-project.sh"

run full "$INSPECT" --project "$PROJECT" --scope all --engine intellij --output-root rel/out
expect_rc "relative --output-root: exit 2" 2
stderr_has "relative --output-root: the requirement is stated" \
	"--output-root must be an absolute path, got: rel/out"

run full "$INSPECT" --project "$PROJECT" --scope all --engine intellij --frobnicate
expect_rc "unknown option: exit 2" 2
stderr_has "unknown option: the offending flag is named" "unknown option: --frobnicate"

run full "$INSPECT" --project "$PROJECT" --scope all --engine intellij stray-word
expect_rc "stray positional argument: exit 2" 2
stderr_has "stray positional argument: it is quoted back" "unexpected argument: stray-word"

run full "$INSPECT" --scope all --engine intellij --project
expect_rc "a flag with no value: exit 2" 2
stderr_has "a flag with no value: the flag is named" "option --project requires an argument"

run full "$INSPECT" --project "$PROJECT" --scope '' --engine intellij
expect_rc "a flag with an EMPTY value: exit 2, because empty is a caller mistake here" 2
stderr_has "a flag with an empty value: the flag is named" "option --scope requires an argument"

run full "$INSPECT" --project "$PROJECT" --scope all --engine intellij --exclude-ids
expect_rc "--exclude-ids with no value at all: exit 2" 2
stderr_has "--exclude-ids with no value: the flag is named" \
	"option --exclude-ids requires an argument"

# ===========================================================================
section "validation happens BEFORE any tool check or prompt"
# ===========================================================================
# A caller's own typo should surface as a usage error, not as "jq is missing" and
# not as "there is no terminal to prompt on". stderr_not_has is what makes this an
# ORDERING claim rather than two independent passes.
run full "$INSPECT" --scope sideways
expect_rc "ordering: a bad value beats the incomplete-flag-set check" 2
stderr_has "ordering: the value error is what is reported" "--scope must be 'all' or 'changed-only'"
stderr_not_has "ordering: and NOT the missing-flags error" \
	"are all required when there is no terminal to prompt on"

run nojq "$INSPECT" --scope sideways
expect_rc "ordering: a bad value also beats the jq check" 2
stderr_has "ordering: the value error is still what is reported" \
	"--scope must be 'all' or 'changed-only'"
stderr_not_has "ordering: and NOT the missing-tool error" "jq is not installed"

# ===========================================================================
section "an incomplete flag set with no terminal is a usage error, never a prompt"
# ===========================================================================
# A script or an agent invoking this with a missing flag must fail fast and be told
# which values are collected interactively — not block forever on a read nobody
# will answer.
run full "$INSPECT" --project "$PROJECT" --scope all
expect_rc "no --engine and no tty: exit 2" 2
stderr_has "no --engine and no tty: the three interactive values are named" \
	"--project, --scope and --engine are all required when there is no terminal to prompt on"
stderr_has "no --engine and no tty: the usage text accompanies it" \
	"(no flags — collect the same values interactively)"

run full "$INSPECT"
expect_rc "no flags at all and no tty: exit 2" 2
stderr_has "no flags at all and no tty: same diagnostic" \
	"are all required when there is no terminal to prompt on"

# ===========================================================================
section "a required tool that is absent exits 1, not 2"
# ===========================================================================
run nojq "$INSPECT" --project "$PROJECT" --scope all --engine intellij \
	--output-root "$(results_root nojq)" --idea-bin "$BIN_IDEA/idea"
expect_rc "jq absent: exit 1, because this is not the caller's mistake" 1
stderr_has "jq absent: the tool is named" "jq is not installed"
stderr_has "jq absent: with somewhere to get it" "install it (e.g. https://jqlang.org)"

# ===========================================================================
section "the two output channels"
# ===========================================================================
inspect channels
expect_rc "channels: the run succeeds" 0
equals "channels: stdout carries NOTHING but INSPECT_* lines" \
	"$(printf '%s\n' "$CUR_OUT" | grep -cv '^INSPECT_' || true)" "0"
stdout_has "channels: the run directory is announced" \
	"INSPECT_RUN_DIR=$(run_dir_of "$WORK/results/channels" cliproj)"
stdout_has "channels: and the file the IntelliJ engine wrote" \
	"INSPECT_INTELLIJ_OUTPUT=$(run_dir_of "$WORK/results/channels" cliproj)/intellij.json"
stdout_not_has "channels: no Sonar key, because Sonar never ran" "INSPECT_SONAR"
stderr_has "channels: the human summary is on stderr, where it cannot corrupt the payload" \
	"Inspection complete."
stderr_has "channels: including the severity breakdown" "WARNING: 1"

# ===========================================================================
section "the dated run-directory layout"
# ===========================================================================
LAYOUT_ROOT=$(results_root layout)
rig_reset_logs
run full "$INSPECT" --project "$PROJECT" --scope all --engine intellij \
	--output-root "$LAYOUT_ROOT" --idea-bin "$BIN_IDEA/idea"
expect_rc "layout: the first run succeeds" 0
path_exists "layout: <root>/YYYY/MM/DD/<project>/<HH-MM-SS>/intellij.json exists" \
	"$(run_dir_of "$LAYOUT_ROOT" cliproj)/intellij.json"

# --- two runs of one project inside the same second -------------------------
# The clock is stubbed, so both runs see the identical stamp: exactly the collision
# `mkdir`'s own atomic failure is there to resolve.
rig_reset_logs
run full "$INSPECT" --project "$PROJECT" --scope all --engine intellij \
	--output-root "$LAYOUT_ROOT" --idea-bin "$BIN_IDEA/idea"
expect_rc "layout: a second run in the same second succeeds" 0
stdout_has "layout: and is filed under a -2 suffix rather than overwriting the first" \
	"INSPECT_RUN_DIR=$(run_dir_of "$LAYOUT_ROOT" cliproj -2)"
path_exists "layout: the first run's output is still there" \
	"$(run_dir_of "$LAYOUT_ROOT" cliproj)/intellij.json"

rig_reset_logs
run full "$INSPECT" --project "$PROJECT" --scope all --engine intellij \
	--output-root "$LAYOUT_ROOT" --idea-bin "$BIN_IDEA/idea"
stdout_has "layout: a third run takes -3" \
	"INSPECT_RUN_DIR=$(run_dir_of "$LAYOUT_ROOT" cliproj -3)"

# --- and the suffix search is bounded --------------------------------------
FULL_ROOT=$(results_root layout-full)
FULL_BASE="$FULL_ROOT/${DATE_STUB_LOCAL%/*}/cliproj"
mkdir -p "$FULL_BASE/${DATE_STUB_LOCAL##*/}"
occupied=2
while [ "$occupied" -le 100 ]; do
	mkdir -p "$FULL_BASE/${DATE_STUB_LOCAL##*/}-$occupied"
	occupied=$((occupied + 1))
done
rig_reset_logs
run full "$INSPECT" --project "$PROJECT" --scope all --engine intellij \
	--output-root "$FULL_ROOT" --idea-bin "$BIN_IDEA/idea"
expect_rc "layout: an exhausted suffix search fails instead of looping" 1
stderr_has "layout: with the bound named" \
	"could not find an unused run directory under $FULL_BASE after 100 attempts"

# --- a failed run leaves no dated marker behind ----------------------------
IDEA_STUB_EDIR_SRC=""
IDEA_STUB_EXIT=4
EMPTY_ROOT=$(results_root layout-empty)
rig_reset_logs
run full "$INSPECT" --project "$PROJECT" --scope all --engine intellij \
	--output-root "$EMPTY_ROOT" --idea-bin "$BIN_IDEA/idea"
expect_rc "layout: a run that produces nothing fails" 1
path_absent "layout: and its empty run directory is removed" \
	"$(run_dir_of "$EMPTY_ROOT" cliproj)"
path_exists "layout: while the dated parent path stays, being shared" \
	"$EMPTY_ROOT/${DATE_STUB_LOCAL%/*}/cliproj"
IDEA_STUB_EDIR_SRC="$FIXTURES/edir-basic"
IDEA_STUB_EXIT=0

# ===========================================================================
section "a project name is sanitized for the PATH but recorded verbatim in the JSON"
# ===========================================================================
# The metadata should say what the directory is actually called; the filesystem
# should not be steered by it.
ODD_PROJECT=$(new_project 'we!rd name' src/main.rs)
ODD_ROOT=$(results_root odd)
rig_reset_logs
run full "$INSPECT" --project "$ODD_PROJECT" --scope all --engine intellij \
	--output-root "$ODD_ROOT" --idea-bin "$BIN_IDEA/idea"
expect_rc "odd project name: the run succeeds" 0
stdout_has "odd project name: every byte outside [A-Za-z0-9._-] becomes _ in the path" \
	"INSPECT_RUN_DIR=$(run_dir_of "$ODD_ROOT" we_rd_name)"
json_eq "odd project name: the JSON still records the real directory name" \
	"$(run_dir_of "$ODD_ROOT" we_rd_name)/intellij.json" \
	'.metadata.project_name' "\"we!rd name\""

# ===========================================================================
section "a project basename of . or .. cannot steer where results land"
# ===========================================================================
# --project is deliberately NOT canonicalized, so `/some/dir/..` and `/some/dir/.`
# reach the run-directory layout with `..` and `.` as the project's BASENAME. Left
# alone, `..` as a path component under --output-root would file the results one
# level ABOVE the dated tree the caller named — so both are mapped to the literal
# `project` component. The metadata still records the basename verbatim, for the
# same reason as the section above.
NESTED_PROJECT=$(new_project nested inner/main.rs)

DOTDOT_ROOT=$(results_root dotdot)
rig_reset_logs
run full "$INSPECT" --project "$NESTED_PROJECT/inner/.." --scope all --engine intellij \
	--output-root "$DOTDOT_ROOT" --idea-bin "$BIN_IDEA/idea"
expect_rc "basename '..': the run succeeds" 0
stdout_has "basename '..': the run directory carries the literal \`project\` component, never \`..\`" \
	"INSPECT_RUN_DIR=$(run_dir_of "$DOTDOT_ROOT" project)"
path_exists "basename '..': and that is where the engine's output actually landed" \
	"$(run_dir_of "$DOTDOT_ROOT" project)/intellij.json"
equals "basename '..': nothing else was created under the dated path" \
	"$(ls "$DOTDOT_ROOT/${DATE_STUB_LOCAL%/*}")" "project"
json_eq "basename '..': the JSON still records the real basename, unsanitized" \
	"$(run_dir_of "$DOTDOT_ROOT" project)/intellij.json" \
	'.metadata.project_name' '".."'
json_eq "basename '..': and the project path exactly as it was given, uncanonicalized" \
	"$(run_dir_of "$DOTDOT_ROOT" project)/intellij.json" \
	'.metadata.project' "\"$NESTED_PROJECT/inner/..\""

DOT_ROOT=$(results_root dot)
rig_reset_logs
run full "$INSPECT" --project "$NESTED_PROJECT/." --scope all --engine intellij \
	--output-root "$DOT_ROOT" --idea-bin "$BIN_IDEA/idea"
expect_rc "basename '.': the run succeeds" 0
stdout_has "basename '.': mapped to \`project\` too, so a run cannot be filed into the dated directory itself" \
	"INSPECT_RUN_DIR=$(run_dir_of "$DOT_ROOT" project)"
equals "basename '.': nothing else was created under the dated path" \
	"$(ls "$DOT_ROOT/${DATE_STUB_LOCAL%/*}")" "project"
json_eq "basename '.': the JSON still records the real basename" \
	"$(run_dir_of "$DOT_ROOT" project)/intellij.json" \
	'.metadata.project_name' '"."'

# --- and `/`, whose basename is empty ---------------------------------------
# `--project /` is the ONE input whose basename is empty (strip_trailing_slashes
# keeps `/` itself, and `${var##*/}` on it yields nothing), so it is how the empty
# case of the mapping is reached from the CLI at all.
#
# THE ENGINE IS DELIBERATELY MADE TO FAIL, at the earliest step after the run
# directory is created: an unresolvable --idea-bin. `/` is not writable and a
# language scan of it would walk the entire filesystem, so a completing run is not
# available here — but prepare_run_dir has already built the layout by then, and
# the teardown removes only the EMPTY leaf, leaving the sanitized component itself
# observable. (The same "the dated parent path stays, being shared" property the
# failed-run section above relies on.)
#
# HONEST SCOPE. What this proves is the run-dir component for `/`; it does not
# reach sanitize_path_component's own `''` arm, which is unreachable from this
# call site — inspect-project.sh substitutes `project` for an empty basename
# before calling it, and `tr` cannot empty a non-empty string. That arm is
# defence in depth with no CLI-observable behaviour of its own, so nothing here
# claims to cover it.
ROOTDIR_ROOT=$(results_root rootdir)
rig_reset_logs
run full "$INSPECT" --project / --scope all --engine intellij \
	--output-root "$ROOTDIR_ROOT" --idea-bin "$WORK/no-such-idea"
expect_rc "basename '': the run fails at the unresolvable binary, before any engine touches \`/\`" 1
stderr_has "basename '': and fails for that reason, not for the project path" \
	"--idea-bin is not an executable file: $WORK/no-such-idea"
path_exists "basename '': the run directory was still laid out under the literal \`project\` component" \
	"$ROOTDIR_ROOT/${DATE_STUB_LOCAL%/*}/project"
equals "basename '': and nowhere else under the dated path" \
	"$(ls "$ROOTDIR_ROOT/${DATE_STUB_LOCAL%/*}")" "project"

# ===========================================================================
section "trailing slashes and the -- terminator"
# ===========================================================================
SLASH_ROOT=$(results_root slashes)
rig_reset_logs
run full "$INSPECT" --project "$PROJECT/" --scope all --engine intellij \
	--output-root "$SLASH_ROOT/" --idea-bin "$BIN_IDEA/idea" --
expect_rc "trailing slashes: accepted, and \`--\` ends the option list" 0
stdout_has "trailing slashes: neither produces a doubled separator in the layout" \
	"INSPECT_RUN_DIR=$(run_dir_of "$SLASH_ROOT" cliproj)"
json_eq "trailing slashes: nor a trailing one in the recorded project path" \
	"$(run_dir_of "$SLASH_ROOT" cliproj)/intellij.json" \
	'.metadata.project' "\"$PROJECT\""

summarize
