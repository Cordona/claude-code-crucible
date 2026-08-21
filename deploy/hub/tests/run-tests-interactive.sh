#!/usr/bin/env sh
#
# run-tests-interactive.sh — everything about hub-install.sh's interactive walk
#                            (hi_select_interactive) that run-tests.sh cannot reach:
#                            the INTERACTIVE copy of the empty-selection guard, the
#                            `r` required-only key, and the two screens' own
#                            Required-install blocks.
#
# WHY A SEPARATE, OPT-IN RUNNER: the interactive path is gated on hub_is_tty, so
# driving it needs a pty, which needs expect(1) — and expect is not universally
# installed, while the whole point of this repo's harnesses is "runs on any
# machine with no dependencies" (lib/harness.sh). Keeping it out of run-tests.sh
# is what lets that guarantee stay true: this runner SKIPS cleanly, loudly, and
# with exit 0 when expect is absent, and run-tests.sh remains the suite that must
# pass everywhere.
#
# WHAT IT VERIFIES, in three groups:
#   * the interactive twin of the three non-interactive verdicts that matter most —
#     an empty technology selection is REFUSED on a target holding nothing of that
#     kind, ACCEPTED once the domain already holds something of it, and REFUSED
#     again when the only thing present belongs to the domain's OTHER selection kind.
#   * HUB_BASELINE_ONLY's mid-walk transitions, which need a screen to go BACK to:
#     de-selecting a domain that already recorded itself, answering a screen that
#     already declined, and a screen skipped for having no candidates left.
#   * the `r` required-only key and the two Required-install blocks derived from the
#     same candidate list — including the ALREADY-ANSWERED exemption on BOTH a
#     mandatory and an optional pick, and the fact that `r` adds to a hand-made
#     selection rather than replacing it. All of those exist only on a route that
#     walks back to the domains checklist.
# The pty driving lives in the lib/drive-*.exp scripts; every assertion is here, on
# the same vocabulary run-tests.sh uses.
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
SCREENS_DRIVER="$TESTS_DIR/lib/drive-required-only-screens.exp"
REQUIRED_ONLY_DRIVER="$TESTS_DIR/lib/drive-required-only-key.exp"
EXEMPT_DRIVER="$TESTS_DIR/lib/drive-required-only-exempt.exp"
EXEMPT_OPTIONAL_DRIVER="$TESTS_DIR/lib/drive-required-only-exempt-optional.exp"
PRESERVES_TICK_DRIVER="$TESTS_DIR/lib/drive-required-only-preserves-tick.exp"

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
export EXEMPT_MARKER='MARKER:REQUIRED-ONLY-EXEMPTED'

# SCREEN_MARKER is a PREFIX, not a verdict, and it is the only marker here that is:
# drive-required-only-screens.exp echoes a whole rendered screen back one line at a
# time under `<SCREEN_MARKER><stage>|`, because the lines under test are ones that may
# legitimately not exist (see that driver's own header on why a match cannot express
# that). The two composed prefixes below are what the assertions actually name, so no
# case has to re-spell the stage.
export SCREEN_MARKER='MARKER:SCREEN:'
SCREEN_DOMAINS="${SCREEN_MARKER}domains|"
SCREEN_SUBSELECTION="${SCREEN_MARKER}subselection|"

# THE SCREEN TEXT UNDER TEST, spelled here rather than in a driver for the same reason
# every marker is: these are the assertions, and a driver that carried its own copy
# could emit or await a string no assertion looks for, so a `lacks` check on the stale
# spelling would pass while observing nothing.
#
# REQUIRED_ONLY_KEY and EXEMPT_NOTICE are EXPORTED because the drivers type/await them;
# the two label constants are not, because only the assertions below read them.
export REQUIRED_ONLY_KEY=r
export EXEMPT_NOTICE='already has a selection of its own'
REQUIRED_ONLY_HINT='r: install required only for the domains listed above'
REQUIRED_INSTALL_LEAD='  Required install:'

# FIRST_SUBSELECTION_ROW — the POSITIVE anchor for every `lacks` assertion made about a
# sub-selection screen. Software Development's first sub-selection step is its VCS
# screen (lib/hub-domains.sh's hub_domain_selection_kind lists `vcs` before
# `technology`), and its first row is the same on every target state used below, since
# no case here installs a VCS host. An anchor is needed because a driver that died
# before rendering would otherwise satisfy the absence checks while observing nothing.
FIRST_SUBSELECTION_ROW='  [ ]  1. GitHub'

# GTD_ROW — the POSITIVE anchor for every assertion that GTD is correctly EXCLUDED from
# a Required-install block or from `r`'s candidate set. GTD is the fixture's
# vacuously-eligible-but-never-actionable domain (lib/fixture.sh's header states why it
# is shipped at all), and every claim about its exclusion is an ABSENCE — which would
# hold just as well if GTD had stopped being offered as a row in the first place, or if
# its fixture subtree were mistyped. Asserting the row itself is what keeps those three
# exclusion checks attached to a domain that is demonstrably on the screen.
GTD_ROW='  [ ]  3. Getting Things Done (GTD)'

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

# drive_screens TARGET DOMAIN -> render Install's two checklist screens against TARGET,
# ticking DOMAIN to reach the second one, and capture the driver's line-by-line dump of
# both. A separate helper from drive_baseline_only above only because this driver takes
# a sixth argument; the isolation and the marker contract are identical.
drive_screens() {
	harness_capture expect -f "$SCREENS_DRIVER" \
		"$SRC" "$1" "$INSTALL" "$HARNESS_HOME" "$HARNESS_TOOLBOX" "$2"
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

# ===========================================================================
# `r` — the domains checklist's required-only shortcut, and the two screen blocks
# derived from the same candidate list.
#
# ONE LIST, TWO CONSUMERS, and that is why they are tested together: what the screens
# call "Required install" is exactly what `r` can act on (hub-install.sh's
# hi_baseline_only_candidates feeds both), so a case that pinned only one of them would
# leave the other free to advertise an action that refuses, or to hide one that works.
#
# THREE TARGET STATES, because the candidate rule is a CONJUNCTION and each state kills
# one half of it:
#   fresh    nothing of a mandatory kind present -> not ELIGIBLE
#   synced   present, but no baseline unit missing -> not ACTIONABLE
#   eligible both halves hold -> the key and the blocks appear
# The middle one is the case a single-clause implementation passes: it would offer `r`
# on a target where pressing it installs nothing at all.
# ===========================================================================
section "interactive: a never-touched domain is on neither screen's Required install, and hides r"
# EVERY offered domain here is untouched, so no candidate exists at all. Getting Things
# Done is the sharpest of the three: with no mandatory kind it is VACUOUSLY eligible,
# so it passes the half of the rule this target defeats for the other two — and it is
# still absent, because with no baseline group it has nothing pending to install.
TARGET_SCREENS_FRESH="$WORK/target-screens-fresh"
fx_target_reset "$TARGET_SCREENS_FRESH"
drive_screens "$TARGET_SCREENS_FRESH" software-development
expect_ok "interactive(screens/fresh): no screen stalled" "driver said: $CUR_OUT" "$CUR_RC"
# The POSITIVE anchor for the two absences below. Without it a driver that died before
# rendering anything would satisfy both `lacks` checks while observing nothing.
stdout_has "interactive(screens/fresh): the domains checklist really did render" \
	"$SCREEN_DOMAINS  [ ]  1. Software Development"
stdout_has "interactive(screens/fresh): the vacuously-eligible domain IS offered as a row" \
	"$SCREEN_DOMAINS$GTD_ROW"
stdout_lacks "interactive(screens/fresh): the domains checklist offers no r key" \
	"$SCREEN_DOMAINS$REQUIRED_ONLY_HINT"
stdout_lacks "interactive(screens/fresh): and heads no Required install block" \
	"$SCREEN_DOMAINS$REQUIRED_INSTALL_LEAD"
stdout_has "interactive(screens/fresh): the sub-selection screen really did render" \
	"$SCREEN_SUBSELECTION$FIRST_SUBSELECTION_ROW"
stdout_lacks "interactive(screens/fresh): the sub-selection screen heads none either" \
	"$SCREEN_SUBSELECTION$REQUIRED_INSTALL_LEAD"

section "interactive: an ELIGIBLE domain puts its required content on both screens, and offers r"
# One technology present per domain, so both are eligible, and neither baseline has been
# installed, so both are actionable.
TARGET_SCREENS_ELIGIBLE="$WORK/target-screens-eligible"
fx_target_reset "$TARGET_SCREENS_ELIGIBLE"
fx_link "$TARGET_SCREENS_ELIGIBLE" "$FX_DEPLOYED_BETA_DEV" "$FX_SRC_BETA_DEV"
fx_link "$TARGET_SCREENS_ELIGIBLE" "$FX_DEPLOYED_PM_TRACKER_GITHUB" "$FX_SRC_PM_TRACKER_GITHUB"
drive_screens "$TARGET_SCREENS_ELIGIBLE" software-development
expect_ok "interactive(screens/eligible): no screen stalled" "driver said: $CUR_OUT" "$CUR_RC"
stdout_has "interactive(screens/eligible): the r key leads the domains checklist's hint line" \
	"$SCREEN_DOMAINS$REQUIRED_ONLY_HINT"
stdout_has "interactive(screens/eligible): the domains checklist heads a Required install block" \
	"$SCREEN_DOMAINS$REQUIRED_INSTALL_LEAD"
# ATTRIBUTED AND ITEMIZED, not merely headed: this screen spans every offered domain, so
# a block that named units without saying whose they are would be unreadable, and one
# that named domains without their units would say nothing about what arrives.
stdout_has "interactive(screens/eligible): under a sub-header naming the first domain" \
	"$SCREEN_DOMAINS    Software Development"
stdout_has "interactive(screens/eligible): with that domain's pending units itemized by name" \
	"$SCREEN_DOMAINS      + Fixture review lens"
stdout_has "interactive(screens/eligible): and the SECOND eligible domain listed too" \
	"$SCREEN_DOMAINS    Project Management"
stdout_has "interactive(screens/eligible): with its own units, so the block is not one domain's" \
	"$SCREEN_DOMAINS      + Flow pm fixture"
# GTD is offered on this same screen and is still excluded — the fresh case's point,
# re-asserted where the block demonstrably exists, so the absence cannot be the
# block's own. Its ROW is asserted first, so the absence cannot be GTD's own either.
stdout_has "interactive(screens/eligible): the vacuously-eligible domain IS offered as a row" \
	"$SCREEN_DOMAINS$GTD_ROW"
stdout_lacks "interactive(screens/eligible): but the domain with nothing pending stays out of the block" \
	"$SCREEN_DOMAINS    Getting Things Done"
# The sub-selection screen's own copy: same units, one indent level shallower, and NO
# domain sub-header, because this screen's title already names its single domain.
stdout_has "interactive(screens/eligible): the sub-selection screen heads its own block" \
	"$SCREEN_SUBSELECTION$REQUIRED_INSTALL_LEAD"
stdout_has "interactive(screens/eligible): itemizing the same units, unattributed" \
	"$SCREEN_SUBSELECTION    + Fixture review lens"
stdout_lacks "interactive(screens/eligible): with no domain sub-header its title already carries" \
	"$SCREEN_SUBSELECTION    Software Development"

section "interactive: an eligible domain whose baseline is ALREADY SYNCED hides r again"
# THE CASE A SINGLE-CLAUSE RULE PASSES. Both domains hold a selectable group AND their
# whole baseline, so both are ELIGIBLE and neither is ACTIONABLE — and both are still
# OFFERED as rows, since each has technologies or trackers left. `r` here would promise
# a no-op, and the Required-install block would head an empty section.
TARGET_SCREENS_SYNCED="$WORK/target-screens-synced"
fx_target_reset "$TARGET_SCREENS_SYNCED"
fx_link "$TARGET_SCREENS_SYNCED" "$FX_DEPLOYED_BETA_DEV" "$FX_SRC_BETA_DEV"
fx_link "$TARGET_SCREENS_SYNCED" "$FX_DEPLOYED_PM_TRACKER_GITHUB" "$FX_SRC_PM_TRACKER_GITHUB"
fx_link_sd_baseline "$TARGET_SCREENS_SYNCED"
fx_link_pm_baseline "$TARGET_SCREENS_SYNCED"
drive_screens "$TARGET_SCREENS_SYNCED" software-development
expect_ok "interactive(screens/synced): no screen stalled" "driver said: $CUR_OUT" "$CUR_RC"
stdout_has "interactive(screens/synced): the domain is still OFFERED, so this is not an empty screen" \
	"$SCREEN_DOMAINS  [ ]  1. Software Development"
stdout_lacks "interactive(screens/synced): but no r key, because pressing it would add nothing" \
	"$SCREEN_DOMAINS$REQUIRED_ONLY_HINT"
stdout_lacks "interactive(screens/synced): and no Required install block on the domains screen" \
	"$SCREEN_DOMAINS$REQUIRED_INSTALL_LEAD"
stdout_has "interactive(screens/synced): the sub-selection screen really did render" \
	"$SCREEN_SUBSELECTION$FIRST_SUBSELECTION_ROW"
stdout_lacks "interactive(screens/synced): nor on the sub-selection screen" \
	"$SCREEN_SUBSELECTION$REQUIRED_INSTALL_LEAD"

section "interactive: r selects every candidate, skips their screens, and records them all"
# The same target as interactive(screens/eligible), driven instead of inspected. Two
# candidates, so the record is asserted as a LIST — a per-run flag or a walk that
# stopped at the first candidate would leave the second domain installed and unnamed.
TARGET_REQUIRED_ONLY="$WORK/target-required-only"
fx_target_reset "$TARGET_REQUIRED_ONLY"
fx_link "$TARGET_REQUIRED_ONLY" "$FX_DEPLOYED_BETA_DEV" "$FX_SRC_BETA_DEV"
fx_link "$TARGET_REQUIRED_ONLY" "$FX_DEPLOYED_PM_TRACKER_GITHUB" "$FX_SRC_PM_TRACKER_GITHUB"
drive_baseline_only "$REQUIRED_ONLY_DRIVER" "$TARGET_REQUIRED_ONLY"
# THE SCREENS WERE SKIPPED, and this exit status is the whole assertion: the driver sends
# nothing at all between `r` and the confirm gate, so a sub-selection screen that still
# rendered would stall the walk and time this out non-zero.
expect_ok "interactive(required-only): no sub-selection screen intercepted the walk" \
	"driver said: $CUR_OUT" "$CUR_RC"
stdout_has "interactive(required-only): the confirmed install reached its machine payload" "$APPLIED_MARKER"
# The <> delimiters are the assertion, per interactive(deselect)'s own note: a bare
# "…=software-development" would also match a payload naming only the first candidate.
stdout_has "interactive(required-only): HUB_BASELINE_ONLY names BOTH candidates, in row order" \
	"$BASELINE_MARKER<software-development,project-management>"
path_exists "interactive(required-only): the first candidate's baseline was installed" \
	"$TARGET_REQUIRED_ONLY/$FX_DEPLOYED_LENS"
path_exists "interactive(required-only): and the rest of it" \
	"$TARGET_REQUIRED_ONLY/$FX_DEPLOYED_FLOW"
path_exists "interactive(required-only): the second candidate's baseline agent was installed" \
	"$TARGET_REQUIRED_ONLY/$FX_DEPLOYED_PM_AGENT"
path_exists "interactive(required-only): and its flow" \
	"$TARGET_REQUIRED_ONLY/$FX_DEPLOYED_PM_FLOW"
# REQUIRED ONLY, so every kind's selection stayed empty — the shortcut must not be able
# to reach a plan a hand-walked selection could not.
path_absent "interactive(required-only): no technology was chosen on the user's behalf" \
	"$TARGET_REQUIRED_ONLY/$FX_DEPLOYED_ALPHA_DEV"
path_absent "interactive(required-only): nor the other one" \
	"$TARGET_REQUIRED_ONLY/$FX_DEPLOYED_GAMMA_DEV"
path_absent "interactive(required-only): no VCS host either, though its kind is optional" \
	"$TARGET_REQUIRED_ONLY/$FX_DEPLOYED_VCS_GITHUB"
path_absent "interactive(required-only): no unselected tracker" \
	"$TARGET_REQUIRED_ONLY/$FX_DEPLOYED_PM_TRACKER_JIRA"
# THE NON-CANDIDATE DOMAIN ON THE SAME SCREEN. GTD is offered, is vacuously eligible,
# and has nothing pending — so `r` must not have selected it, which is only observable
# as an absence on disk. The driver echoes the screen `r` was pressed on for exactly
# this pairing: the absence means "not selected" only once the row is shown to have been
# there to select.
stdout_has "interactive(required-only): the non-candidate domain WAS offered on the screen r acted on" \
	"$SCREEN_DOMAINS$GTD_ROW"
path_absent "interactive(required-only): and r still did not select it" \
	"$TARGET_REQUIRED_ONLY/$FX_DEPLOYED_GTD_AGENT"

section "interactive: r leaves an ALREADY-ANSWERED domain completely alone, and says so"
# The bug this exists for: `r` used to reduce a candidate that already held a real pick,
# deleting a choice the user made deliberately with nothing on screen having warned it
# could. Same target as the case above, so the two differ in exactly one thing — one
# domain has been answered before `r` is pressed.
TARGET_EXEMPT="$WORK/target-required-only-exempt"
fx_target_reset "$TARGET_EXEMPT"
fx_link "$TARGET_EXEMPT" "$FX_DEPLOYED_BETA_DEV" "$FX_SRC_BETA_DEV"
fx_link "$TARGET_EXEMPT" "$FX_DEPLOYED_PM_TRACKER_GITHUB" "$FX_SRC_PM_TRACKER_GITHUB"
drive_baseline_only "$EXEMPT_DRIVER" "$TARGET_EXEMPT"
expect_ok "interactive(exempt): no screen stalled" "driver said: $CUR_OUT" "$CUR_RC"
stdout_has "interactive(exempt): the walk really did pick a technology before pressing r" "$CHOSE_MARKER"
stdout_has "interactive(exempt): r announced on the human channel that it left that domain alone" \
	"$EXEMPT_MARKER"
stdout_has "interactive(exempt): the confirmed install reached its machine payload" "$APPLIED_MARKER"
# THE FIELD IS THE OTHER HALF OF THE EXEMPTION. The reduced domain must be named and the
# exempt one must not — a payload naming both would claim a baseline-only install for
# the very domain whose technology it just installed, which inverts the field's meaning
# for a caller acting on it.
stdout_has "interactive(exempt): HUB_BASELINE_ONLY names ONLY the domain r actually reduced" \
	"$BASELINE_MARKER<project-management>"
# THE PICK SURVIVED — all three of its units, so this is the technology group's install
# rather than a stray file.
path_exists "interactive(exempt): the hand-picked technology's developer was installed" \
	"$TARGET_EXEMPT/$FX_DEPLOYED_ALPHA_DEV"
path_exists "interactive(exempt): its reviewer too" "$TARGET_EXEMPT/$FX_DEPLOYED_ALPHA_REVIEWER"
path_exists "interactive(exempt): and its standard" "$TARGET_EXEMPT/$FX_DEPLOYED_ALPHA_STANDARD"
path_absent "interactive(exempt): the technology NOT picked stayed out" \
	"$TARGET_EXEMPT/$FX_DEPLOYED_GAMMA_DEV"
path_exists "interactive(exempt): the reduced domain still got its own baseline" \
	"$TARGET_EXEMPT/$FX_DEPLOYED_PM_AGENT"
path_absent "interactive(exempt): with no tracker chosen for it" \
	"$TARGET_EXEMPT/$FX_DEPLOYED_PM_TRACKER_JIRA"

section "interactive: an OPTIONAL kind's pick counts as answered too, and r honors it"
# THE OTHER HALF of hi_domain_already_answered's "ANY kind is enough, mandatory or
# optional" contract. The case above answers the MANDATORY kind, which leaves the
# optional half of that predicate's loop unobserved — a version that only counted a
# mandatory pick passes every assertion up to here, while reducing a domain whose VCS
# host the user deliberately chose.
#
# WHAT TELLS THE TWO APART, stated because the obvious candidate does NOT:
# HUB_BASELINE_ONLY names this domain either way, correctly — its mandatory technology
# selection really was left empty and accepted, and a non-empty OPTIONAL selection never
# retracts that record (the field's own contract excludes the optional kind entirely).
# The observable difference is the NOTICE, the two screens that follow it, and the ORDER
# of the recorded domains: an exempt domain records itself LATE, at its own re-walked
# screen, while a reduced one records during `r` and so lands first.
TARGET_EXEMPT_OPTIONAL="$WORK/target-required-only-exempt-optional"
fx_target_reset "$TARGET_EXEMPT_OPTIONAL"
fx_link "$TARGET_EXEMPT_OPTIONAL" "$FX_DEPLOYED_BETA_DEV" "$FX_SRC_BETA_DEV"
fx_link "$TARGET_EXEMPT_OPTIONAL" "$FX_DEPLOYED_PM_TRACKER_GITHUB" "$FX_SRC_PM_TRACKER_GITHUB"
drive_baseline_only "$EXEMPT_OPTIONAL_DRIVER" "$TARGET_EXEMPT_OPTIONAL"
expect_ok "interactive(exempt-optional): no screen stalled" "driver said: $CUR_OUT" "$CUR_RC"
stdout_has "interactive(exempt-optional): the walk really did pick a VCS host before pressing r" \
	"$CHOSE_MARKER"
stdout_has "interactive(exempt-optional): r announced that an OPTIONAL pick alone left the domain alone" \
	"$EXEMPT_MARKER"
stdout_has "interactive(exempt-optional): the confirmed install reached its machine payload" "$APPLIED_MARKER"
# ORDER IS THE ASSERTION HERE, not membership: the exempt domain records itself at its
# own re-walked screen and therefore lands SECOND, where a reduced one would have
# recorded during `r` and led the list.
stdout_has "interactive(exempt-optional): the exempt domain recorded itself LAST, at its own screen" \
	"$BASELINE_MARKER<project-management,software-development>"
path_exists "interactive(exempt-optional): the hand-picked VCS host was installed" \
	"$TARGET_EXEMPT_OPTIONAL/$FX_DEPLOYED_VCS_GITHUB"
path_absent "interactive(exempt-optional): the VCS host NOT picked stayed out" \
	"$TARGET_EXEMPT_OPTIONAL/$FX_DEPLOYED_VCS_GITLAB"
path_absent "interactive(exempt-optional): the mandatory kind really was declined" \
	"$TARGET_EXEMPT_OPTIONAL/$FX_DEPLOYED_ALPHA_DEV"
path_exists "interactive(exempt-optional): the exempt domain still got its baseline" \
	"$TARGET_EXEMPT_OPTIONAL/$FX_DEPLOYED_LENS"
path_exists "interactive(exempt-optional): so did the reduced one" \
	"$TARGET_EXEMPT_OPTIONAL/$FX_DEPLOYED_PM_AGENT"
path_absent "interactive(exempt-optional): with no tracker chosen for it" \
	"$TARGET_EXEMPT_OPTIONAL/$FX_DEPLOYED_PM_TRACKER_JIRA"

section "interactive: r ADDS to a hand-made selection rather than replacing it"
# hi_baseline_only_select is "APPENDED AND THEN DEDUPLICATED, never written over the
# top", and every case above is blind to that: either nothing is ticked before `r`, or
# every ticked domain is also a candidate, and in both shapes an overwrite is
# byte-identical to the append.
#
# THE FIXTURE IS WHAT MAKES IT OBSERVABLE. Software Development holds a technology, so
# it IS a candidate; Project Management has never been touched, so it is offered as a
# row but is NOT one. Ticking the non-candidate gives `r` something to lose that its own
# list cannot put back — the same silent-selection-loss class as the bug the exemption
# above exists for.
TARGET_PRESERVES_TICK="$WORK/target-required-only-preserves-tick"
fx_target_reset "$TARGET_PRESERVES_TICK"
fx_link "$TARGET_PRESERVES_TICK" "$FX_DEPLOYED_BETA_DEV" "$FX_SRC_BETA_DEV"
drive_baseline_only "$PRESERVES_TICK_DRIVER" "$TARGET_PRESERVES_TICK"
# THE EXIT STATUS IS THE PRIMARY ASSERTION: with the selection overwritten, `r`'s own
# candidate is the only domain left and every one of its steps is then removed, so the
# walk jumps straight to the confirm gate and the driver times out waiting for the
# ticked domain's tracker screen.
expect_ok "interactive(preserves-tick): the hand-ticked domain's own screen still followed r" \
	"driver said: $CUR_OUT" "$CUR_RC"
# THE FIXTURE'S OWN PREMISE, read off the screen `r` was pressed on rather than assumed:
# the tick landed on the NON-candidate, the candidate was offered beside it, and `r` was
# advertised at all.
stdout_has "interactive(preserves-tick): the hand-tick landed on the non-candidate domain" \
	"$SCREEN_DOMAINS  [x]  2. Project Management"
stdout_has "interactive(preserves-tick): exactly one domain was ticked by hand" \
	"$SCREEN_DOMAINS  1 selected"
stdout_has "interactive(preserves-tick): the candidate r acts on was offered beside it" \
	"$SCREEN_DOMAINS  [ ]  1. Software Development"
stdout_has "interactive(preserves-tick): and r was on offer" "$SCREEN_DOMAINS$REQUIRED_ONLY_HINT"
# ONLY the candidate is named under Required install, which is what makes the ticked
# domain a genuine non-candidate rather than a second one `r` happened to reach.
stdout_lacks "interactive(preserves-tick): the never-touched domain is not a candidate" \
	"$SCREEN_DOMAINS    Project Management"
stdout_has "interactive(preserves-tick): a tracker was chosen on the surviving screen" "$CHOSE_MARKER"
stdout_has "interactive(preserves-tick): the confirmed install reached its machine payload" "$APPLIED_MARKER"
stdout_has "interactive(preserves-tick): HUB_BASELINE_ONLY names only the domain r reduced" \
	"$BASELINE_MARKER<software-development>"
path_exists "interactive(preserves-tick): the tracker picked on that screen was installed" \
	"$TARGET_PRESERVES_TICK/$FX_DEPLOYED_PM_TRACKER_GITHUB"
path_exists "interactive(preserves-tick): so was the hand-ticked domain's own baseline" \
	"$TARGET_PRESERVES_TICK/$FX_DEPLOYED_PM_AGENT"
path_exists "interactive(preserves-tick): and the candidate's, which is what r added" \
	"$TARGET_PRESERVES_TICK/$FX_DEPLOYED_LENS"
path_absent "interactive(preserves-tick): r chose no technology for the candidate" \
	"$TARGET_PRESERVES_TICK/$FX_DEPLOYED_ALPHA_DEV"
# NO "and the unchosen tracker stayed out" ASSERTION HERE, deliberately. Installing the
# tracker the user did not name needs the tracker screen's own toggle to over-select,
# and any such change also breaks the "1 selected" tally this driver waits on — so the
# walk stalls and nothing installs, leaving the same absence the correct behaviour
# leaves. interactive(required-only) is where that claim IS falsifiable, because there
# the screen is skipped rather than walked.

harness_summary
