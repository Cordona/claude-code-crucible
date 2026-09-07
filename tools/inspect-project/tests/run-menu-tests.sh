#!/usr/bin/env sh
#
# run-menu-tests.sh — the interactive menu: the four questions, the global
#                     ?/b/q keys, the validation loops, and the [Y/n] git-staging
#                     confirmation.
#
# HOW THE MENU IS REACHED AT ALL. inspect-project.sh drops into the menu only when
# stdin AND stderr are both terminals, so a pipe cannot get there — that refusal is
# deliberate and is itself tested in run-cli-tests.sh. This suite supplies a real
# pseudo-terminal through lib/pty-drive.py; read that file's docstring for the fd
# layout, and in particular for why stdout is left on a PIPE (so the "stdout is the
# machine channel, and the menu must not corrupt it" contract stays assertable).
#
# WHERE EACH ASSERTION LOOKS. Every prompt, every diagnostic and the whole human
# summary are written to stderr, i.e. to the terminal, so they arrive in $CUR_ERR
# as one transcript. The INSPECT_* payload arrives separately in $CUR_OUT. The
# scripted keystrokes are echoed by the tty and therefore appear in the transcript
# too — harmless for substring assertions, but it does mean the transcript is not a
# faithful record of prompt-vs-answer ORDER, so nothing here asserts ordering.
#
# Usage:  sh run-menu-tests.sh
#         VERBOSE=1 sh run-menu-tests.sh
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
# shellcheck source=SCRIPTDIR/lib/gitfixture.sh
. "$TESTS_DIR/lib/gitfixture.sh"

rig_setup "$TESTS_DIR" menu

PYTHON3=$(real_tool python3)
PTY_DRIVER="$TESTS_DIR/lib/pty-drive.py"
MENU_INPUT="$WORK/menu-input"

# A terminal read blocks forever, so a menu that asks one more question than the
# scripted input answers would hang this suite instead of failing it. The deadline
# turns that into a red test. Generous relative to a real run here (the whole
# suite completes in seconds) because it is a backstop, not a performance budget.
MENU_TIMEOUT_SECONDS=45

run() {
	r_selector=$1; shift
	case "$r_selector" in
		full) r_path="$BIN_GIT:$BIN_DATE:$BIN_IDEA:$TOOLBOX" ;;
		*) printf 'FATAL: bad run() selector: %s\n' "$r_selector" >&2; exit 1 ;;
	esac
	harness_run "$r_path" "$PYTHON3" "$PTY_DRIVER" \
		--timeout "$MENU_TIMEOUT_SECONDS" --input "$MENU_INPUT" -- "$@"
}

# feed LINE... — the keystroke script for the next menu run, one line per argument.
feed() {
	: >"$MENU_INPUT"
	for f_line in "$@"; do
		printf '%s\n' "$f_line" >>"$MENU_INPUT"
	done
}

# menu_run — start inspect-project with NO flags at all, which is what makes it
# collect all four values interactively. $IDEA_BIN carries the stub, because the
# menu never asks which binary to use.
menu_run() {
	rig_reset_logs
	run full "$INSPECT"
}

PROJECT=$(new_project menuproj src/main.rs)
IDEA_STUB_EDIR_SRC="$FIXTURES/edir-basic"
IDEA_BIN="$BIN_IDEA/idea"

# ===========================================================================
section "the four questions, answered by name and by number"
# ===========================================================================
WALK_ROOT=$(results_root walk)
feed "$PROJECT" all intellij "$WALK_ROOT"
menu_run
expect_rc "walkthrough: answering every question by name completes the run" 0
stderr_has "walkthrough: the menu announces itself" \
	"no complete flag set given, collecting the values interactively"
stderr_has "walkthrough: the global keys are advertised up front" "?  help    b  back    q  quit"
stderr_has "walkthrough: the project question is asked" "Project to inspect (absolute path)"
stderr_has "walkthrough: the scope options are listed" "1) all           inspect the whole project"
stderr_has "walkthrough: the engine options are listed" \
	"1) intellij  IntelliJ IDEA headless inspections"
stderr_has "walkthrough: the results directory is asked for" "Results directory"
stdout_has "walkthrough: and the run lands where the menu was told" \
	"INSPECT_RUN_DIR=$(run_dir_of "$WALK_ROOT" menuproj)"
path_exists "walkthrough: with the engine's output written" \
	"$(run_dir_of "$WALK_ROOT" menuproj)/intellij.json"

NUMBERED_ROOT=$(results_root numbered)
feed "$PROJECT" 1 1 "$NUMBERED_ROOT"
menu_run
expect_rc "walkthrough: the same answers given as numbers work identically" 0
stdout_has "walkthrough: same destination" \
	"INSPECT_RUN_DIR=$(run_dir_of "$NUMBERED_ROOT" menuproj)"

# --- Enter accepts every default -------------------------------------------
# Using each value as its question's DEFAULT rather than skipping the question is
# what keeps back-navigation a plain decrement over a fixed list.
feed "$PROJECT" "" "" ""
menu_run
expect_rc "defaults: Enter takes the shown default at scope, engine and results dir" 0
stderr_has "defaults: the scope default is shown" "[all]"
stderr_has "defaults: the engine default is shown" "[intellij]"
stderr_has "defaults: the results-directory default is this HOME's results tree" \
	"[$HARNESS_HOME/.crucible-inspect-results]"
stdout_has "defaults: and that default is where the run lands" \
	"INSPECT_RUN_DIR=$(run_dir_of "$HARNESS_HOME/.crucible-inspect-results" menuproj)"
rm -rf "$HARNESS_HOME/.crucible-inspect-results"

# ===========================================================================
section "the global keys: ? help, b back, q quit"
# ===========================================================================
feed q
menu_run
expect_rc "quit: exit 0 — declining to run is not an error" 0
stderr_has "quit: and it says nothing was changed" "Quit. Nothing changed."
equals "quit: no machine payload at all, because no run happened" "$CUR_OUT" ""

feed quit
menu_run
expect_rc "quit: the spelled-out form works too" 0
stderr_has "quit: same message" "Quit. Nothing changed."

feed '?' '' q
menu_run
expect_rc "help: ? shows help, Enter returns, and the walk continues" 0
stderr_has "help: the help header is shown" "inspect-project — Help"
stderr_has "help: navigation is documented" "b, back      go back one question"
stderr_has "help: the two scopes are explained" "changed-only  inspect only what differs from HEAD"
stderr_has "help: Sonar's three availability requirements are explained" \
	"Sonar needs all three of: sonar-scanner on PATH, a server answering UP, and"
stderr_has "help: and how to leave it" "Press Enter to return."

feed b q
menu_run
expect_rc "back: b on the FIRST question stays put rather than quitting" 0
stderr_has "back: and says so" "Already at the first question."
stderr_has "back: quitting is still the explicit q" "Quit. Nothing changed."

feed "$PROJECT" b q
menu_run
expect_rc "back: b on the second question returns to the first" 0
stderr_has "back: the project question is re-asked with the answer already given as its default" \
	"[$PROJECT]"

# ===========================================================================
section "every answer is validated in place, and a bad one re-asks"
# ===========================================================================
feed relative/path q
menu_run
expect_rc "bad project: rejected and re-asked, then quit" 0
stderr_has "bad project: a relative path is refused" "the project path must be absolute: relative/path"

feed "$WORK/no-such-dir" q
menu_run
stderr_has "bad project: a path that is not a directory is refused" \
	"not a directory: $WORK/no-such-dir"

feed "$PROJECT" sideways q
menu_run
stderr_has "bad scope: the value is quoted back" "not a scope: sideways"

feed "$PROJECT" all banana q
menu_run
stderr_has "bad engine: the value is quoted back" "not an engine: banana"

feed "$PROJECT" all sonar q
menu_run
stderr_has "unavailable engine: sonar cannot be chosen while it is unavailable" \
	"sonar is unavailable:"
stderr_has "unavailable engine: with the two usable alternatives named" \
	"choose intellij, or both (which will run IntelliJ alone)"
stderr_has "unavailable engine: and the option list labels it UNAVAILABLE with the reason" \
	"2) sonar     UNAVAILABLE —"

feed "$PROJECT" all intellij rel/out q
menu_run
stderr_has "bad results directory: a relative path is refused" \
	"the results directory must be an absolute path: rel/out"

# --- a stdin that goes away is a quit, never a silent default ---------------
# An interactive prompt whose input has gone away must not accept its own default.
# The scripted EOT is how that is reached without closing the pty and racing a
# SIGHUP against the script's own teardown.
: >"$MENU_INPUT"
printf '\004' >>"$MENU_INPUT"
menu_run
expect_rc "closed stdin: read as a quit" 0
stderr_has "closed stdin: and reported as one" "Quit. Nothing changed."
equals "closed stdin: nothing was run" "$CUR_OUT" ""

# ===========================================================================
section "the git-staging confirmation"
# ===========================================================================
# It fires ONLY for the one combination that touches the caller's index: the
# IntelliJ engine at changed-only scope. An unannounced `git add -A` in somebody's
# repository is the kind of surprise no result is worth.
MENU_REPO="$WORK/projects/menurepo"
git_init_repo "$MENU_REPO"
git_seed_mixed_changes "$MENU_REPO" ""
REPO_BEFORE=$(git_status_snapshot "$MENU_REPO")

CONFIRM_ROOT=$(results_root confirm)
feed "$MENU_REPO" changed-only intellij "$CONFIRM_ROOT" ""
menu_run
expect_rc "confirmation: an empty answer at [Y/n] proceeds" 0
stderr_has "confirmation: it explains why the index has to be touched" \
	"changed-only scope needs IntelliJ's \`-changes\` mode, which reads the git index."
stderr_has "confirmation: step 1 — record what is staged" "1. record which paths are currently staged"
stderr_has "confirmation: step 2 — stage everything" \
	"2. run \`git add -A\` so every change is visible to the inspection"
stderr_has "confirmation: step 3 — the inspection" "3. run the inspection"
stderr_has "confirmation: step 4 — the restore" \
	"4. unstage everything, then re-stage exactly the paths from step 1"
stderr_has "confirmation: it promises nothing is committed" \
	"Nothing is committed and no file content is changed."
stderr_has "confirmation: it discloses the known limitation up front" \
	"Rename detection and partial (\`git add -p\`)"
stdout_has "confirmation: and the run then happens" \
	"INSPECT_RUN_DIR=$(run_dir_of "$CONFIRM_ROOT" menurepo)"
equals "confirmation: with the index restored afterwards" \
	"$(git_status_snapshot "$MENU_REPO")" "$REPO_BEFORE"

feed "$MENU_REPO" changed-only intellij "$(results_root confirm-y)" y
menu_run
expect_rc "confirmation: an explicit y proceeds too" 0
stdout_has "confirmation: and runs" "INSPECT_RUN_DIR="

DECLINE_ROOT=$(results_root confirm-declined)
feed "$MENU_REPO" changed-only intellij "$DECLINE_ROOT" n
menu_run
expect_rc "declined: exit 0 — declining is not a failure" 0
stderr_has "declined: and it says nothing changed" "Declined. Nothing changed."
equals "declined: no machine payload, because nothing ran" "$CUR_OUT" ""
equals "declined: and the index was never touched" \
	"$(git_status_snapshot "$MENU_REPO")" "$REPO_BEFORE"
path_absent "declined: no results directory was created either" \
	"$(run_dir_of "$DECLINE_ROOT" menurepo)"

# Neither is a stdin that has gone away. This is the consent gate for the one
# mutation the tool makes to the caller's repository, so an EOF here must NOT be
# read as the prompt's own "Enter means yes" default.
: >"$MENU_INPUT"
printf '%s\nchanged-only\nintellij\n%s\n' "$MENU_REPO" "$(results_root confirm-eof)" >>"$MENU_INPUT"
printf '\004' >>"$MENU_INPUT"
menu_run
expect_rc "closed stdin at the confirmation: exit 0" 0
stderr_has "closed stdin at the confirmation: read as a quit, not as consent" \
	"Quit. Nothing changed."
equals "closed stdin at the confirmation: the index was never touched" \
	"$(git_status_snapshot "$MENU_REPO")" "$REPO_BEFORE"
equals "closed stdin at the confirmation: nothing ran" "$CUR_OUT" ""

# Garbage is never read as consent — the safer reading of a [Y/n] prompt.
feed "$MENU_REPO" changed-only intellij "$(results_root confirm-garbage)" "maybe later"
menu_run
expect_rc "declined: an unrecognized answer declines rather than proceeding" 0
stderr_has "declined: reported as a decline" "Declined. Nothing changed."
equals "declined: nothing ran" "$CUR_OUT" ""

# `?` is a GLOBAL key, so it has to work at the [Y/n] tier too — and it must
# RE-ASK rather than count as an answer. A `?` silently read as a decline would
# abandon the run, and read as consent it would stage the caller's index on a
# keystroke that asked a question. The two prompt lines are what proves which
# happened: help, then the same question again.
HELP_CONFIRM_ROOT=$(results_root confirm-help)
feed "$MENU_REPO" changed-only intellij "$HELP_CONFIRM_ROOT" '?' '' ''
menu_run
expect_rc "? at the confirmation: exit 0" 0
stderr_has "? at the confirmation: the help header is shown" "inspect-project — Help"
stderr_has "? at the confirmation: and how to leave it" "Press Enter to return."
equals "? at the confirmation: the [Y/n] question is asked a SECOND time, not answered by the \`?\`" \
	"$(printf '%s\n' "$CUR_ERR" | grep -Fc 'Proceed? [Y/n]' || true)" "2"
stdout_has "? at the confirmation: and the empty answer that follows still proceeds" \
	"INSPECT_RUN_DIR=$(run_dir_of "$HELP_CONFIRM_ROOT" menurepo)"
stderr_not_has "? at the confirmation: the \`?\` was never read as a decline" \
	"Declined. Nothing changed."
equals "? at the confirmation: with the index restored afterwards" \
	"$(git_status_snapshot "$MENU_REPO")" "$REPO_BEFORE"

feed "$MENU_REPO" changed-only intellij "$(results_root confirm-back)" b "$(results_root confirm-back2)" ""
menu_run
expect_rc "confirmation: b steps back to the results-directory question" 0
stdout_has "confirmation: and the second answer is the one that takes effect" \
	"INSPECT_RUN_DIR=$(run_dir_of "$WORK/results/confirm-back2" menurepo)"

# --- and it stays silent for every other combination ------------------------
feed "$MENU_REPO" all intellij "$(results_root noconfirm-all)"
menu_run
expect_rc "no confirmation: 'all' scope stages nothing, so nothing is asked" 0
stderr_not_has "no confirmation: the staging explanation is absent" \
	"changed-only scope needs IntelliJ's"

# ===========================================================================
section "a Sonar skip reason exists on this path, and must NOT be reported"
# ===========================================================================
# The menu probes Sonar on EVERY run just to label its own option, so a skip reason
# is populated here even when the caller then chooses `intellij`. Reporting
# "Sonar was skipped" to that caller would be both noise and untrue — nothing was
# skipped — and it would make the two entry paths' stdout differ for identical
# effective inputs. This is the ONE path on which that can happen, so it is the
# only place the distinction is testable.
feed "$PROJECT" all intellij "$(results_root menu-skipreason)"
menu_run
expect_rc "menu + engine intellij: exit 0" 0
stderr_has "menu + engine intellij: the menu really did probe Sonar and find it unavailable" \
	"2) sonar     UNAVAILABLE —"
stdout_not_has "menu + engine intellij: yet no skip reason is emitted, because nothing was skipped" \
	"INSPECT_SONAR_SKIPPED_REASON"

# ===========================================================================
section "changing the project answer re-probes Sonar instead of reusing the verdict"
# ===========================================================================
# detect_sonar is idempotent by design — the menu labels its `sonar` option from
# the verdict and the run then reuses it rather than re-probing the server. One of
# its three checks is PATH-DEPENDENT (Sonar config in the project), so going back
# and naming a different project has to invalidate that verdict, or the engine
# question labels the new project with the old project's reason.
#
# THE OBSERVABLE IS THE REASON TEXT, and the two fixtures are built so the two
# verdicts cannot produce the same one: neither project can reach Sonar (no
# sonar-scanner and no curl in this suite's toolbox, so both are unavailable
# either way), but only the SECOND is missing Sonar config — and the config clause
# names the project it was checked against. So "no Sonar project config under
# <second project>" is a string the first project's verdict can never contain.
SONAR_CONFIGURED=$(new_project menuwithsonarconfig sonar-project.properties src/main.rs)
SONAR_BARE=$(new_project menunosonarconfig src/main.rs)

REPROBE_ROOT=$(results_root reprobe)
feed "$SONAR_CONFIGURED" all b b "$SONAR_BARE" all intellij "$REPROBE_ROOT"
menu_run
expect_rc "re-probe: the walk with two b steps and a changed project completes" 0
stderr_not_has "re-probe: the first project's verdict found its Sonar config, so no config clause for it" \
	"no Sonar project config under $SONAR_CONFIGURED"
stderr_has "re-probe: while the second project's verdict names ITS missing config — a fresh check, not the cached one" \
	"no Sonar project config under $SONAR_BARE"
stdout_has "re-probe: and the run lands on the project answered second" \
	"INSPECT_RUN_DIR=$(run_dir_of "$REPROBE_ROOT" menunosonarconfig)"

# ===========================================================================
section "both entry paths produce the same machine output"
# ===========================================================================
# The claim in inspect-project.sh's header: for the same effective inputs, stdout is
# byte-identical however the values were collected. The two runs must use different
# output roots (a same-second collision would otherwise give the second one a `-2`
# suffix), so the root is masked out of both before comparing — the only thing that
# legitimately differs.
FLAG_ROOT=$(results_root parity-flags)
rig_reset_logs
harness_run "$BIN_GIT:$BIN_DATE:$BIN_IDEA:$TOOLBOX" "$INSPECT" \
	--project "$PROJECT" --scope all --engine intellij --output-root "$FLAG_ROOT"
expect_rc "parity: the flag path succeeds" 0
PARITY_FLAGS=$(printf '%s\n' "$CUR_OUT" | sed "s|$FLAG_ROOT|<ROOT>|g")

MENU_ROOT=$(results_root parity-menu)
feed "$PROJECT" all intellij "$MENU_ROOT"
menu_run
expect_rc "parity: the menu path succeeds" 0
PARITY_MENU=$(printf '%s\n' "$CUR_OUT" | sed "s|$MENU_ROOT|<ROOT>|g")

equals "parity: stdout is identical once the output root is masked" \
	"$PARITY_MENU" "$PARITY_FLAGS"

summarize
