#!/usr/bin/env sh
#
# run-tests-interactive.sh — the INTERACTIVE copy of hub-install.sh's
#                            empty-selection guard (hi_select_interactive), which
#                            run-tests.sh cannot reach.
#
# WHY A SEPARATE, OPT-IN RUNNER: the interactive path is gated on hub_is_tty, so
# driving it needs a pty, which needs expect(1) — and expect is not universally
# installed, while the whole point of this repo's harnesses is "runs on any
# machine with no dependencies" (lib/harness.sh). Keeping it out of run-tests.sh
# is what lets that guarantee stay true: this runner SKIPS cleanly, loudly, and
# with exit 0 when expect is absent, and run-tests.sh remains the suite that must
# pass everywhere.
#
# WHAT IT VERIFIES: the interactive twin of the three non-interactive verdicts
# that matter most — an empty technology selection is REFUSED on a target holding
# nothing of that kind, ACCEPTED once the domain already holds something of it,
# and REFUSED again when the only thing present belongs to the domain's OTHER
# selection kind. The pty driving itself lives in lib/drive-empty-technology.exp;
# every assertion is here, on the same vocabulary run-tests.sh uses.
#
# Usage:  sh run-tests-interactive.sh
#         VERBOSE=1 sh run-tests-interactive.sh
#
# Exit 0 = all passed, or expect(1) is absent and the suite skipped.
# Exit 1 = one or more failed.
#
set -eu

TESTS_DIR=$(cd "$(dirname "$0")" && pwd -P)
HUB_DIR=$(cd "$TESTS_DIR/.." && pwd -P)
INSTALL="$HUB_DIR/hub-install.sh"
DRIVER="$TESTS_DIR/lib/drive-empty-technology.exp"
DESELECT_DRIVER="$TESTS_DIR/lib/drive-deselect-baseline-only.exp"
RETRACT_DRIVER="$TESTS_DIR/lib/drive-retract-baseline-only.exp"
SKIPPED_SCREEN_DRIVER="$TESTS_DIR/lib/drive-skipped-screen-baseline-only.exp"

# shellcheck source=SCRIPTDIR/lib/harness.sh
. "$TESTS_DIR/lib/harness.sh"
# shellcheck source=SCRIPTDIR/lib/fixture.sh
. "$TESTS_DIR/lib/fixture.sh"

if ! command -v expect >/dev/null 2>&1; then
	section "hub-install.sh — the interactive empty-selection guard"
	skip 'the whole suite: expect(1) is not installed, and a pty cannot be driven without it'
	printf '\n(install expect to run these — run-tests.sh covers everything reachable without it)\n'
	exit 0
fi

# -P: see fx_build_source's own note on why the fixture path must be canonical.
WORK=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/hub-install-interactive-tests.XXXXXX")" && pwd -P)
SRC="$WORK/source"

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

harness_init "$WORK"
fx_build_source "$SRC"

# EXPORTED, and read back by the driver as $env(...) rather than repeated as
# literals there: every marker assertion below is a grep for one of these strings,
# so a driver holding its own copy could drift into emitting a marker no assertion
# looks for — and a stdout_lacks on the stale spelling would then pass vacuously,
# reporting a guard verdict nobody actually observed.
export REFUSED_MARKER='MARKER:EMPTY-SELECTION-REFUSED'
export ACCEPTED_MARKER='MARKER:CONFIRM-REACHED'
export APPLIED_MARKER='MARKER:APPLIED'
export DESELECTED_MARKER='MARKER:DOMAIN-DESELECTED'
export CHOSE_MARKER='MARKER:TECHNOLOGY-CHOSEN'
export BASELINE_MARKER='MARKER:BASELINE-ONLY='

# drive_empty_technology TARGET -> walk the onboarding checklists against TARGET
# up to an empty technology selection, capturing the driver's marker.
#
# harness_capture rather than harness_run: expect must be resolved from the real
# PATH because it is deliberately absent from the toolbox, and the driver applies
# the identical env -i isolation to the hub process it spawns.
drive_empty_technology() {
	harness_capture expect -f "$DRIVER" \
		"$SRC" "$1" "$INSTALL" "$HARNESS_HOME" "$HARNESS_TOOLBOX"
}

# drive_baseline_only DRIVER TARGET -> one of the HUB_BASELINE_ONLY walks against
# TARGET. The driver is a parameter here, unlike drive_empty_technology above, because
# those three cases differ in their key sequence rather than only in the target state —
# which is exactly why they are three scripts (see lib/drive-baseline-only-common.exp)
# rather than one script with a mode argument.
drive_baseline_only() {
	harness_capture expect -f "$1" \
		"$SRC" "$2" "$INSTALL" "$HARNESS_HOME" "$HARNESS_TOOLBOX"
}

section "interactive: empty technology selection, target holds NOTHING of that kind"
TARGET_FRESH="$WORK/target-fresh"
fx_target_reset "$TARGET_FRESH"
drive_empty_technology "$TARGET_FRESH"
expect_ok "interactive(empty/fresh): no screen stalled" "driver said: $CUR_OUT" "$CUR_RC"
stdout_has "interactive(empty/fresh): the empty-selection rule refused and re-prompted" "$REFUSED_MARKER"
stdout_lacks "interactive(empty/fresh): the confirm prompt was NOT reached" "$ACCEPTED_MARKER"
path_absent "interactive(empty/fresh): nothing was installed" "$TARGET_FRESH/$FX_DEPLOYED_LENS"

section "interactive: empty technology selection, one technology already present"
TARGET_INSTALLED="$WORK/target-installed"
fx_target_reset "$TARGET_INSTALLED"
fx_link "$TARGET_INSTALLED" "$FX_DEPLOYED_BETA_DEV" "$FX_SRC_BETA_DEV"
drive_empty_technology "$TARGET_INSTALLED"
expect_ok "interactive(empty/installed): no screen stalled" "driver said: $CUR_OUT" "$CUR_RC"
stdout_has "interactive(empty/installed): the walk advanced to the confirm prompt" "$ACCEPTED_MARKER"
stdout_has "interactive(empty/installed): the confirmed install reached its Result screen" "$APPLIED_MARKER"
stdout_lacks "interactive(empty/installed): the empty-selection rule did NOT fire" "$REFUSED_MARKER"
path_exists "interactive(empty/installed): baseline lens reviewer installed" "$TARGET_INSTALLED/$FX_DEPLOYED_LENS"
path_exists "interactive(empty/installed): baseline flow installed" "$TARGET_INSTALLED/$FX_DEPLOYED_FLOW"
path_absent "interactive(empty/installed): no declined technology installed" "$TARGET_INSTALLED/$FX_DEPLOYED_ALPHA_DEV"

section "interactive: empty technology selection, only the domain's OTHER kind present"
# The interactive twin of run-tests.sh's own domain-and-kind scoping case: a VCS
# host of this same domain is installed, and it must not answer for the technology
# screen.
TARGET_OTHER_KIND="$WORK/target-other-kind"
fx_target_reset "$TARGET_OTHER_KIND"
fx_link "$TARGET_OTHER_KIND" "$FX_DEPLOYED_VCS_GITHUB" "$FX_SRC_VCS_GITHUB"
drive_empty_technology "$TARGET_OTHER_KIND"
expect_ok "interactive(empty/other-kind-present): no screen stalled" "driver said: $CUR_OUT" "$CUR_RC"
stdout_has "interactive(empty/other-kind-present): the empty-selection rule refused and re-prompted" "$REFUSED_MARKER"
stdout_lacks "interactive(empty/other-kind-present): the confirm prompt was NOT reached" "$ACCEPTED_MARKER"
path_absent "interactive(empty/other-kind-present): nothing was installed" "$TARGET_OTHER_KIND/$FX_DEPLOYED_LENS"

# ===========================================================================
# HUB_BASELINE_ONLY and `b` — the one part of that field's contract no
# non-interactive case can reach.
#
# The field is an ACCUMULATOR written mid-walk, and only the interactive walk can
# revisit the domains checklist and take a domain back out AFTER it has recorded
# itself. A domain that installs nothing must not still be named in the payload,
# and the truncation that ensures it must not also discard the domain that is
# still selected — two failures with one screen between them, which is why this
# case asserts on a value rather than on a marker's presence.
# ===========================================================================
section "interactive: a domain de-selected after recording itself leaves HUB_BASELINE_ONLY"
# BOTH kinds already present, one per domain, so both domains' empty mandatory
# sub-selections are accepted and both record themselves before anything is
# de-selected. Without both, the walk never has a stale name to leave behind.
TARGET_DESELECT="$WORK/target-deselect"
fx_target_reset "$TARGET_DESELECT"
fx_link "$TARGET_DESELECT" "$FX_DEPLOYED_BETA_DEV" "$FX_SRC_BETA_DEV"
fx_link "$TARGET_DESELECT" "$FX_DEPLOYED_PM_TRACKER_GITHUB" "$FX_SRC_PM_TRACKER_GITHUB"
drive_baseline_only "$DESELECT_DRIVER" "$TARGET_DESELECT"
expect_ok "interactive(deselect): no screen stalled" "driver said: $CUR_OUT" "$CUR_RC"
stdout_has "interactive(deselect): the walk really did re-enter the domains screen and untick one" \
	"$DESELECTED_MARKER"
stdout_has "interactive(deselect): the confirmed install reached its machine payload" "$APPLIED_MARKER"
# The <> delimiters are the assertion: a bare "…=software-development" would also
# match a payload that went on to name project-management after it, which is
# exactly the stale value this case exists to catch.
stdout_has "interactive(deselect): the de-selected domain is GONE from HUB_BASELINE_ONLY, the surviving one is not" \
	"$BASELINE_MARKER<software-development>"
path_exists "interactive(deselect): the surviving domain's baseline was installed" \
	"$TARGET_DESELECT/$FX_DEPLOYED_LENS"
path_absent "interactive(deselect): the de-selected domain's baseline was NOT installed" \
	"$TARGET_DESELECT/$FX_DEPLOYED_PM_AGENT"

section "interactive: going back and ANSWERING a declined screen retracts the record"
# The sibling of the case above, on the route its truncation cannot see: `b` from
# the confirm screen re-enters the sub-selection screen directly, never the domains
# checklist, so only that screen's own second answer can undo its first. A payload
# naming a baseline-only domain beside the technology it just installed is worse than
# a stale one — it inverts the field's meaning for a caller acting on it.
TARGET_RETRACT="$WORK/target-retract"
fx_target_reset "$TARGET_RETRACT"
fx_link "$TARGET_RETRACT" "$FX_DEPLOYED_BETA_DEV" "$FX_SRC_BETA_DEV"
drive_baseline_only "$RETRACT_DRIVER" "$TARGET_RETRACT"
expect_ok "interactive(retract): no screen stalled" "driver said: $CUR_OUT" "$CUR_RC"
stdout_has "interactive(retract): the walk really did go back and pick a technology" "$CHOSE_MARKER"
stdout_has "interactive(retract): the confirmed install reached its machine payload" "$APPLIED_MARKER"
stdout_has "interactive(retract): HUB_BASELINE_ONLY is EMPTY, not the domain it named before" \
	"$BASELINE_MARKER<>"
path_exists "interactive(retract): the chosen technology really was installed" \
	"$TARGET_RETRACT/$FX_DEPLOYED_ALPHA_DEV"

section "interactive: a screen SKIPPED for having no candidates left is still baseline-only"
# THE ENTRY-POINT PARITY HALF. Every technology is already installed, so this walk
# never renders the technology screen at all and records on the way past it, while
# run-tests.sh's install(all-candidates-installed) reaches the empty-selection guard
# on the identical fixture and records there. Two code paths, one published value —
# the claim is only meaningful if both halves assert the same string.
TARGET_SKIPPED="$WORK/target-skipped-screen"
fx_target_reset "$TARGET_SKIPPED"
fx_link_every_technology "$TARGET_SKIPPED"
drive_baseline_only "$SKIPPED_SCREEN_DRIVER" "$TARGET_SKIPPED"
expect_ok "interactive(skipped-screen): no screen stalled" "driver said: $CUR_OUT" "$CUR_RC"
stdout_has "interactive(skipped-screen): the confirmed install reached its machine payload" "$APPLIED_MARKER"
stdout_has "interactive(skipped-screen): HUB_BASELINE_ONLY names the domain, as the non-interactive half does" \
	"$BASELINE_MARKER<software-development>"
path_exists "interactive(skipped-screen): the baseline really was installed" \
	"$TARGET_SKIPPED/$FX_DEPLOYED_LENS"

harness_summary
