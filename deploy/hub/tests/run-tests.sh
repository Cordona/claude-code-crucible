#!/usr/bin/env sh
#
# run-tests.sh — the Management Hub's INSTALL sub-selection rules, at the two
#                boundaries a non-TTY test process can reach: hub-install.sh's
#                NON-INTERACTIVE empty-selection guard, and the
#                hub_domain_selectable_groups_of_kind accessor that guard is
#                built on.
#
# The shared machinery lives in lib/: the runner primitives and the isolated
# PATH toolbox in lib/harness.sh (which also states why this is hand-rolled
# rather than bats), the synthetic --source tree and the target-state helpers in
# lib/fixture.sh. Read those two first; this file is only the cases.
#
# THE INTERACTIVE COPY OF THE SAME GUARD lives in run-tests-interactive.sh — a
# separate runner because reaching it needs a pty (hub_is_tty gates the whole
# interactive path), which needs expect(1), which is not universally installed.
# That runner self-skips when expect is absent, so this file stays the one that
# must pass everywhere.
#
# Usage:  sh run-tests.sh              # run all tests
#         VERBOSE=1 sh run-tests.sh
#         (also runs green under dash: dash run-tests.sh)
#
# Exit 0 = all passed, 1 = one or more failed.
#
set -eu

TESTS_DIR=$(cd "$(dirname "$0")" && pwd -P)
HUB_DIR=$(cd "$TESTS_DIR/.." && pwd -P)
INSTALL="$HUB_DIR/hub-install.sh"
HUB_LIB="$HUB_DIR/lib"

# shellcheck source=SCRIPTDIR/lib/harness.sh
. "$TESTS_DIR/lib/harness.sh"
# shellcheck source=SCRIPTDIR/lib/fixture.sh
. "$TESTS_DIR/lib/fixture.sh"

# -P: see fx_build_source's own note on why the fixture path must be canonical.
WORK=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/hub-install-tests.XXXXXX")" && pwd -P)
SRC="$WORK/source"

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

harness_init "$WORK"
fx_build_source "$SRC"

# ---------------------------------------------------------------------------
# The two things this suite EXECUTES.
# ---------------------------------------------------------------------------

# invoke_install TARGET [FLAG ...] -> hub-install.sh against the fixture source
# and TARGET with only the flags EVERY case shares: machine-facing and byte-clean
# (--non-interactive --no-color). MODE — --apply and --format= — is the caller's,
# because the HUB_BASELINE_ONLY sections below vary it deliberately: the field's
# contract is "on every ok exit", and the dry-run no-op and the JSON merge path
# are exits only a different mode reaches.
#
# The SELECTION flags deliberately stay at each call site too — they are what each
# case is about, and burying them here would hide the difference between cases.
invoke_install() {
	ii_target=$1
	shift
	harness_run sh "$INSTALL" --source "$SRC" --target "$ii_target" \
		--non-interactive --no-color "$@"
}

# run_install TARGET [FLAG ...] -> invoke_install in the mode most cases share:
# writing and env-formatted (--apply --format=env). --format=env also moves the
# human preview to fd 3 -> stderr, so stdout is nothing but the machine payload
# the assertions read.
#
# The two mode flags are bound HERE rather than repeated at each call site because
# a case that silently lost one of them — an omitted --apply turning a writing run
# into a preview — is exactly the failure that hid in seven copy-pasted
# invocations before this existed. The few cases that call invoke_install directly
# are safe from that by construction: each of them asserts the no-op MESSAGE its
# own mode produces, so a gained or lost --apply fails the case outright rather
# than quietly weakening it.
run_install() {
	ri_target=$1
	shift
	invoke_install "$ri_target" --apply --format=env "$@"
}

# probe_groups DOMAIN KIND -> hub_domain_selectable_groups_of_kind at its OWN
# boundary. The hub libraries are sourceable, so the accessor is asked directly
# instead of being inferred from a capability script's behaviour. That is what
# reaches the two answers no capability script can: the registry ships no two
# domains sharing one selection kind, so "another domain's groups of MY kind"
# and "my own OTHER kind's groups" are only observable here.
PROBE="$WORK/probe-groups-of-kind.sh"
cat >"$PROBE" <<'PROBE_EOF'
set -eu
. "$HUB_LIB/hub-common.sh"
. "$HUB_LIB/hub-domains.sh"
. "$HUB_LIB/hub-discovery.sh"
hub_workspace_init
hub_discovery_build "$1"
hub_domain_selectable_groups_of_kind "$2" "$3"
PROBE_EOF
probe_groups() { harness_run "HUB_LIB=$HUB_LIB" sh "$PROBE" "$SRC" "$1" "$2"; }

# ===========================================================================
# lib/hub-discovery.sh — hub_domain_selectable_groups_of_kind
# ===========================================================================
section "hub_domain_selectable_groups_of_kind — the domain AND kind intersection"

probe_groups software-development technology
expect_rc "accessor(sd/technology): -> exit 0" 0
stdout_is "accessor(sd/technology): every technology group, and no VCS group of the same domain" \
	'tech:alpha
tech:beta
tech:gamma'

probe_groups software-development vcs
expect_rc "accessor(sd/vcs): -> exit 0" 0
stdout_is "accessor(sd/vcs): every VCS group, and no technology group of the same domain" \
	'vcs:github
vcs:gitlab'

probe_groups project-management pm-tracker
expect_rc "accessor(pm/pm-tracker): -> exit 0" 0
stdout_is "accessor(pm/pm-tracker): every tracker group of its own domain" \
	'pm-tracker:github
pm-tracker:jira'

# The two cross-products, each killing exactly one of the two half-answers the
# accessor exists to replace: a KIND-only filter would hand Project Management
# Software Development's three technology groups, and a DOMAIN-only filter would
# hand this same query Project Management's two tracker groups.
#
# EACH PAIRS ITS stdout_is WITH AN expect_rc, and that is not ceremony: an empty
# stdout is also what a probe that DIED produces (bad arguments, an unsourceable
# library, a renamed accessor), so the emptiness assertion alone would keep
# passing while verifying nothing. These two are the only checks anywhere that
# pin the accessor's DOMAIN filter, so they are the last place to leave a
# same-answer-for-the-wrong-reason hole.
probe_groups project-management technology
expect_rc "accessor(pm/technology): -> exit 0" 0
stdout_is "accessor(pm/technology): another domain's kind yields NOTHING" ''

probe_groups software-development pm-tracker
expect_rc "accessor(sd/pm-tracker): -> exit 0" 0
stdout_is "accessor(sd/pm-tracker): a kind this domain does not have yields NOTHING" ''

# An EMPTY kind is a caller bug, not a narrower query: the group table stamps an
# empty selkind on exactly the rows no sub-selection screen governs (a domain's
# baseline, an atomic domain's one group, every shared row), so answering it would
# hand hi_domain_kind_has_present a baseline match to read as "something of this
# kind is present" — disarming the guard. Asserted on stderr as well as the exit
# code, because a refusal a caller cannot read is not much better than a wrong
# answer.
probe_groups project-management ''
expect_rc "accessor(pm/empty-kind): dies rather than answering -> exit 1" 1
stdout_is "accessor(pm/empty-kind): emits no group list at all" ''
expect_ok "accessor(pm/empty-kind): the diagnostic names the accessor and the domain" \
	"stderr did not name both; got: $CUR_ERR" \
	"$(printf '%s\n' "$CUR_ERR" | grep -Fq 'hub_domain_selectable_groups_of_kind' &&
		printf '%s\n' "$CUR_ERR" | grep -Fq 'project-management' && echo 0 || echo 1)"

# ===========================================================================
# hub-install.sh — the non-interactive empty-selection guard.
#
# Every case names its domain(s) with --domains and omits that kind's own flag,
# which is how a machine caller expresses "nothing selected".
# ===========================================================================
# Each message is matched on an APOSTROPHE-FREE span of itself. hub_env_quote
# single-quotes every env value and escapes an interior apostrophe as '\'', so the
# domain messages ("doesn't", "can't") do not appear verbatim in the payload —
# matching across one would assert the quoting rather than the message. The spans
# below still identify WHICH domain blocked, which is the whole point of the check.
BLOCKED_SD_MESSAGE='do anything without at least one technology'
BLOCKED_PM_MESSAGE='create or update tracked work without at least one tracker'

section "empty technology selection, target holds NOTHING of that kind -> blocked"
TARGET_FRESH="$WORK/target-fresh"
fx_target_reset "$TARGET_FRESH"
run_install "$TARGET_FRESH" --domains=software-development
expect_rc "install(empty/fresh): -> exit 1" 1
stdout_has "install(empty/fresh): HUB_STATUS=blocked" "HUB_STATUS='blocked'"
stdout_has "install(empty/fresh): reason is selection_required" "HUB_BLOCKED_REASON='selection_required'"
stdout_has "install(empty/fresh): message names the domain that blocked" "$BLOCKED_SD_MESSAGE"
# HUB_BASELINE_ONLY belongs to the `ok` contract only (see hub-install.sh's own
# header entry for it): a refusal names its reason, and a field that also appeared
# on a blocked payload would say a domain got a baseline that nothing installed.
stdout_lacks "install(empty/fresh): a blocked payload carries no HUB_BASELINE_ONLY" "HUB_BASELINE_ONLY"
path_absent "install(empty/fresh): nothing was installed" "$TARGET_FRESH/$FX_DEPLOYED_LENS"

section "empty technology selection, one technology already INSTALLED -> baseline only"
TARGET_INSTALLED="$WORK/target-installed"
fx_target_reset "$TARGET_INSTALLED"
fx_link "$TARGET_INSTALLED" "$FX_DEPLOYED_BETA_DEV" "$FX_SRC_BETA_DEV"
run_install "$TARGET_INSTALLED" --domains=software-development
expect_rc "install(empty/installed): -> exit 0" 0
stdout_has "install(empty/installed): HUB_STATUS=ok" "HUB_STATUS='ok'"
stdout_lacks "install(empty/installed): not blocked" "HUB_BLOCKED_REASON"
stdout_has "install(empty/installed): the declined kind stays empty in the receipt" "HUB_TECHNOLOGIES=''"
# THE FIELD THAT TELLS THE TWO EMPTY RECEIPTS APART. HUB_TECHNOLOGIES='' alone is
# byte-identical to what a caller that simply forgot --technologies would get from
# a blocked run's absent receipt, so this is the only thing in the payload that
# says the empty selection was ACCEPTED, and why.
stdout_has "install(empty/installed): HUB_BASELINE_ONLY names the exempted domain" \
	"HUB_BASELINE_ONLY='software-development'"
path_exists "install(empty/installed): baseline lens reviewer installed" "$TARGET_INSTALLED/$FX_DEPLOYED_LENS"
path_exists "install(empty/installed): baseline specialist installed" "$TARGET_INSTALLED/$FX_DEPLOYED_SPECIALIST"
path_exists "install(empty/installed): baseline flow installed" "$TARGET_INSTALLED/$FX_DEPLOYED_FLOW"
path_absent "install(empty/installed): declined technology's developer NOT installed" "$TARGET_INSTALLED/$FX_DEPLOYED_ALPHA_DEV"
path_absent "install(empty/installed): declined technology's reviewer NOT installed" "$TARGET_INSTALLED/$FX_DEPLOYED_ALPHA_REVIEWER"
path_absent "install(empty/installed): declined technology's standard NOT installed" "$TARGET_INSTALLED/$FX_DEPLOYED_ALPHA_STANDARD"
path_absent "install(empty/installed): the other declined technology NOT installed" "$TARGET_INSTALLED/$FX_DEPLOYED_GAMMA_DEV"
path_absent "install(empty/installed): unselected VCS host NOT installed" "$TARGET_INSTALLED/$FX_DEPLOYED_VCS_GITHUB"
path_absent "install(empty/installed): the other unselected VCS host NOT installed" "$TARGET_INSTALLED/$FX_DEPLOYED_VCS_GITLAB"

section "empty technology selection, one technology PARTIAL (incomplete) -> baseline only"
# alpha holds three units and only its developer is linked, so the group is
# neither installed nor available.
TARGET_PARTIAL="$WORK/target-partial"
fx_target_reset "$TARGET_PARTIAL"
fx_link "$TARGET_PARTIAL" "$FX_DEPLOYED_ALPHA_DEV" "$FX_SRC_ALPHA_DEV"
run_install "$TARGET_PARTIAL" --domains=software-development
expect_rc "install(empty/partial-incomplete): -> exit 0" 0
stdout_has "install(empty/partial-incomplete): HUB_STATUS=ok" "HUB_STATUS='ok'"
stdout_lacks "install(empty/partial-incomplete): not blocked" "HUB_BLOCKED_REASON"
stdout_has "install(empty/partial-incomplete): HUB_BASELINE_ONLY names the exempted domain" \
	"HUB_BASELINE_ONLY='software-development'"
path_exists "install(empty/partial-incomplete): baseline installed" "$TARGET_PARTIAL/$FX_DEPLOYED_LENS"
path_absent "install(empty/partial-incomplete): the partial technology is NOT completed" "$TARGET_PARTIAL/$FX_DEPLOYED_ALPHA_REVIEWER"
path_absent "install(empty/partial-incomplete): its standard is NOT completed" "$TARGET_PARTIAL/$FX_DEPLOYED_ALPHA_STANDARD"

section "empty technology selection, one technology PARTIAL (diverged) -> baseline only"
# gamma holds ONE unit and a non-framework file occupies its deployed path, so
# the group's only unit reads DIVERGED — present, but nothing installed. The
# exemption is stated in terms of PRESENCE, so this must exempt exactly as an
# incomplete group does, and must then install the baseline for real rather than
# merely decline to block.
TARGET_DIVERGED="$WORK/target-diverged"
fx_target_reset "$TARGET_DIVERGED"
fx_occupy "$TARGET_DIVERGED" "$FX_DEPLOYED_GAMMA_DEV"
run_install "$TARGET_DIVERGED" --domains=software-development
expect_rc "install(empty/partial-diverged): -> exit 0" 0
stdout_has "install(empty/partial-diverged): HUB_STATUS=ok" "HUB_STATUS='ok'"
stdout_lacks "install(empty/partial-diverged): not blocked" "HUB_BLOCKED_REASON"
stdout_has "install(empty/partial-diverged): HUB_BASELINE_ONLY names the exempted domain" \
	"HUB_BASELINE_ONLY='software-development'"
path_exists "install(empty/partial-diverged): baseline lens reviewer installed" "$TARGET_DIVERGED/$FX_DEPLOYED_LENS"
path_exists "install(empty/partial-diverged): baseline flow installed" "$TARGET_DIVERGED/$FX_DEPLOYED_FLOW"
path_absent "install(empty/partial-diverged): the declined technology installed nothing" "$TARGET_DIVERGED/$FX_DEPLOYED_ALPHA_DEV"
# NO ASSERTION THAT THE DIVERGED OCCUPANT SURVIVED, deliberately. It does survive,
# but nothing this suite can change makes it stop: lib/hub-symlink.sh's
# hub_symlink_at classifies a non-framework file as foreign and refuses it
# unconditionally, so such an assertion holds whatever the empty-selection guard
# decides — it would document hub-symlink.sh's occupant policy while appearing to
# verify this guard, and would keep passing with the guard inverted. The
# path_absent above is the falsifiable form of "the declined kind installed
# nothing".

section "empty technology selection, only the domain's OTHER kind present -> blocked"
# The scoping case a DOMAIN-only predicate gets wrong: a VCS host of THIS SAME
# DOMAIN is installed, and asking "does this domain have anything selectable
# present" would say yes and exempt the technology screen. Asking per-kind says
# no, and blocks.
#
# The mirror direction is unreachable by construction: `vcs` is an OPTIONAL kind
# (hub_selection_kind_optional), so an empty VCS selection never consults the
# exemption at all.
TARGET_OTHER_KIND="$WORK/target-other-kind"
fx_target_reset "$TARGET_OTHER_KIND"
fx_link "$TARGET_OTHER_KIND" "$FX_DEPLOYED_VCS_GITHUB" "$FX_SRC_VCS_GITHUB"
run_install "$TARGET_OTHER_KIND" --domains=software-development
expect_rc "install(empty/other-kind-present): -> exit 1" 1
stdout_has "install(empty/other-kind-present): HUB_STATUS=blocked" "HUB_STATUS='blocked'"
stdout_has "install(empty/other-kind-present): reason is selection_required" "HUB_BLOCKED_REASON='selection_required'"
stdout_has "install(empty/other-kind-present): message names the technology screen" "$BLOCKED_SD_MESSAGE"
path_absent "install(empty/other-kind-present): nothing was installed" "$TARGET_OTHER_KIND/$FX_DEPLOYED_LENS"

section "empty tracker selection on a single-kind domain, fresh target -> blocked"
# The sibling of the fresh-target case on a domain whose ONLY kind is mandatory,
# so the optional-kind path cannot be involved in the answer either way.
TARGET_PM_FRESH="$WORK/target-pm-fresh"
fx_target_reset "$TARGET_PM_FRESH"
run_install "$TARGET_PM_FRESH" --domains=project-management
expect_rc "install(empty/pm-fresh): -> exit 1" 1
stdout_has "install(empty/pm-fresh): HUB_STATUS=blocked" "HUB_STATUS='blocked'"
stdout_has "install(empty/pm-fresh): reason is selection_required" "HUB_BLOCKED_REASON='selection_required'"
stdout_has "install(empty/pm-fresh): message names the domain that blocked" "$BLOCKED_PM_MESSAGE"

section "a present group of a DIFFERENT kind in another domain -> still blocked"
# WHAT THIS DOES AND DOES NOT VERIFY, stated because the obvious reading is wrong:
# a Software Development TECHNOLOGY is present and the query is Project
# Management's PM-TRACKER, so the two differ in kind as well as domain — even a
# domain-filter-dropped accessor would find no tracker here and would still
# block. This is therefore a second mandatory-kind regression guard, NOT the
# same-kind-across-domains case.
#
# That case — one domain's present group exempting a DIFFERENT domain's empty
# selection of the SAME kind — is unreachable through any capability script with
# the shipped registry, because every selection kind maps to exactly one domain
# (hub_selection_kind_domain). It is covered by the accessor probe's
# accessor(pm/technology) check instead, which is where it IS reachable.
TARGET_PM_CROSS="$WORK/target-pm-cross"
fx_target_reset "$TARGET_PM_CROSS"
fx_link "$TARGET_PM_CROSS" "$FX_DEPLOYED_BETA_DEV" "$FX_SRC_BETA_DEV"
run_install "$TARGET_PM_CROSS" --domains=project-management
expect_rc "install(empty/pm-other-domain): -> exit 1" 1
stdout_has "install(empty/pm-other-domain): HUB_STATUS=blocked" "HUB_STATUS='blocked'"
stdout_has "install(empty/pm-other-domain): reason is selection_required" "HUB_BLOCKED_REASON='selection_required'"
stdout_has "install(empty/pm-other-domain): message names Project Management, not the domain that has content" \
	"$BLOCKED_PM_MESSAGE"

# ===========================================================================
# MIXED --domains selections — the guard's per-domain loop.
#
# Every case above names ONE domain, so the loop over SEL_DOMAINS runs once and
# cannot distinguish "asked about the domain it is currently on" from "asked
# about a fixed domain". These three name TWO, and between them pin both halves
# of that: the loop keeps going past a domain it exempted, and each iteration
# asks about ITS OWN domain.
# ===========================================================================
MIXED_DOMAINS='--domains=software-development,project-management'

section "mixed selection, the FIRST domain is exempt -> the second still blocks"
TARGET_MIXED_SD="$WORK/target-mixed-sd"
fx_target_reset "$TARGET_MIXED_SD"
fx_link "$TARGET_MIXED_SD" "$FX_DEPLOYED_BETA_DEV" "$FX_SRC_BETA_DEV"
run_install "$TARGET_MIXED_SD" "$MIXED_DOMAINS"
expect_rc "install(mixed/sd-exempt): -> exit 1" 1
stdout_has "install(mixed/sd-exempt): HUB_STATUS=blocked" "HUB_STATUS='blocked'"
stdout_has "install(mixed/sd-exempt): reason is selection_required" "HUB_BLOCKED_REASON='selection_required'"
stdout_has "install(mixed/sd-exempt): the LATER domain's message, so the loop did not stop at the exempt one" \
	"$BLOCKED_PM_MESSAGE"
path_absent "install(mixed/sd-exempt): nothing was installed" "$TARGET_MIXED_SD/$FX_DEPLOYED_LENS"

section "mixed selection, the SECOND domain is exempt -> the first still blocks"
TARGET_MIXED_PM="$WORK/target-mixed-pm"
fx_target_reset "$TARGET_MIXED_PM"
fx_link "$TARGET_MIXED_PM" "$FX_DEPLOYED_PM_TRACKER_GITHUB" "$FX_SRC_PM_TRACKER_GITHUB"
run_install "$TARGET_MIXED_PM" "$MIXED_DOMAINS"
expect_rc "install(mixed/pm-exempt): -> exit 1" 1
stdout_has "install(mixed/pm-exempt): HUB_STATUS=blocked" "HUB_STATUS='blocked'"
stdout_has "install(mixed/pm-exempt): reason is selection_required" "HUB_BLOCKED_REASON='selection_required'"
stdout_has "install(mixed/pm-exempt): the EARLIER domain's message, so a later exemption did not clear it" \
	"$BLOCKED_SD_MESSAGE"
path_absent "install(mixed/pm-exempt): nothing was installed" "$TARGET_MIXED_PM/$FX_DEPLOYED_PM_AGENT"

section "mixed selection, BOTH domains exempt -> both baselines, nothing else"
# THE CASE THAT PINS THE DOMAIN ARGUMENT ITSELF, and the reason the two sections
# above do not: each of them has one domain that holds nothing of the queried
# kind, so a predicate handed a FIXED domain instead of the loop's own still
# answers "nothing present" and still blocks — same verdict, wrong reason. Here
# BOTH domains genuinely hold something of their OWN kind, so any fixed domain
# argument makes the other domain's iteration answer "nothing present" and block,
# while the correct per-domain question exempts both and installs.
TARGET_MIXED_BOTH="$WORK/target-mixed-both"
fx_target_reset "$TARGET_MIXED_BOTH"
fx_link "$TARGET_MIXED_BOTH" "$FX_DEPLOYED_BETA_DEV" "$FX_SRC_BETA_DEV"
fx_link "$TARGET_MIXED_BOTH" "$FX_DEPLOYED_PM_TRACKER_GITHUB" "$FX_SRC_PM_TRACKER_GITHUB"
run_install "$TARGET_MIXED_BOTH" "$MIXED_DOMAINS"
expect_rc "install(mixed/both-exempt): -> exit 0" 0
stdout_has "install(mixed/both-exempt): HUB_STATUS=ok" "HUB_STATUS='ok'"
stdout_lacks "install(mixed/both-exempt): not blocked" "HUB_BLOCKED_REASON"
stdout_has "install(mixed/both-exempt): both domains in the receipt" \
	"HUB_DOMAINS='software-development,project-management'"
stdout_has "install(mixed/both-exempt): the declined technology kind stays empty" "HUB_TECHNOLOGIES=''"
stdout_has "install(mixed/both-exempt): the declined tracker kind stays empty" "HUB_PM_TRACKERS=''"
# BOTH exempted domains, comma-separated: the accumulator is a list, not a flag,
# and a per-run "was anything exempted" boolean — or a record that stopped at the
# first domain — would leave a caller unable to tell which of its two domains got
# reduced to a baseline. Order is asserted separately below, against a reversed
# --domains, since this selection happens to match registry order too.
stdout_has "install(mixed/both-exempt): HUB_BASELINE_ONLY names BOTH exempted domains" \
	"HUB_BASELINE_ONLY='software-development,project-management'"
path_exists "install(mixed/both-exempt): the first domain's baseline installed" "$TARGET_MIXED_BOTH/$FX_DEPLOYED_LENS"
path_exists "install(mixed/both-exempt): the second domain's baseline agent installed" "$TARGET_MIXED_BOTH/$FX_DEPLOYED_PM_AGENT"
path_exists "install(mixed/both-exempt): the second domain's baseline flow installed" "$TARGET_MIXED_BOTH/$FX_DEPLOYED_PM_FLOW"
path_absent "install(mixed/both-exempt): no declined technology installed" "$TARGET_MIXED_BOTH/$FX_DEPLOYED_ALPHA_DEV"
path_absent "install(mixed/both-exempt): no declined tracker installed" "$TARGET_MIXED_BOTH/$FX_DEPLOYED_PM_TRACKER_JIRA"

section "a NON-empty selection is unaffected by the exemption"
TARGET_CHOSEN="$WORK/target-chosen"
fx_target_reset "$TARGET_CHOSEN"
run_install "$TARGET_CHOSEN" --domains=software-development --technologies=alpha,gamma
expect_rc "install(chosen): -> exit 0" 0
stdout_has "install(chosen): HUB_STATUS=ok" "HUB_STATUS='ok'"
stdout_has "install(chosen): the receipt names exactly what was chosen" "HUB_TECHNOLOGIES='alpha,gamma'"
stdout_has "install(chosen): HUB_BASELINE_ONLY is empty when nothing was exempted" "HUB_BASELINE_ONLY=''"
path_exists "install(chosen): chosen technology's developer installed" "$TARGET_CHOSEN/$FX_DEPLOYED_ALPHA_DEV"
path_exists "install(chosen): chosen technology's reviewer installed" "$TARGET_CHOSEN/$FX_DEPLOYED_ALPHA_REVIEWER"
path_exists "install(chosen): chosen technology's standard installed" "$TARGET_CHOSEN/$FX_DEPLOYED_ALPHA_STANDARD"
path_exists "install(chosen): the other chosen technology installed" "$TARGET_CHOSEN/$FX_DEPLOYED_GAMMA_DEV"
path_exists "install(chosen): baseline installed alongside" "$TARGET_CHOSEN/$FX_DEPLOYED_LENS"
path_absent "install(chosen): the unchosen technology NOT installed" "$TARGET_CHOSEN/$FX_DEPLOYED_BETA_DEV"

# ===========================================================================
# HUB_BASELINE_ONLY / baseline_only — the payload field naming every domain whose
# MANDATORY sub-selection was accepted EMPTY under the already-present exemption.
#
# The sections above assert it on the paths they already run (a full apply, a
# two-domain apply, a blocked refusal, a non-empty selection). These add the parts
# of its contract no case above reaches: it is documented as appearing on EVERY ok
# exit — so each no-op exit needs its own case — it is a JSON ARRAY under
# --format=json, where it is MERGED into a payload another function built, and it
# names only the domains exempted for THIS reason, in the order they were
# selected.
# ===========================================================================
BASELINE_ONLY_SD="HUB_BASELINE_ONLY='software-development'"

section "no-op exit: nothing left to do -> the field still names the exempted domain"
# TWO RUNS ON ONE TARGET, and the second is the case: the first leaves the domain
# fully installed, so the second finds ATTEMPT_COUNT 0 and takes the up-to-date
# no-op exit while the exemption fires exactly as it did before. Without the field
# there, a caller polling an already-provisioned target cannot tell a domain that
# is complete from one that has only ever had its baseline.
#
# THE MESSAGE IS ASSERTED ON stderr, not stdout: under --format=env the hub's
# human channel is fd 3 -> stderr, and the message is the only thing that names
# WHICH of the ok exits this was. Without it this case is indistinguishable from
# the success path it is here to be distinguished from.
TARGET_UPTODATE="$WORK/target-uptodate"
fx_target_reset "$TARGET_UPTODATE"
fx_link "$TARGET_UPTODATE" "$FX_DEPLOYED_BETA_DEV" "$FX_SRC_BETA_DEV"
run_install "$TARGET_UPTODATE" --domains=software-development
expect_rc "install(noop/up-to-date): the priming install succeeded -> exit 0" 0
run_install "$TARGET_UPTODATE" --domains=software-development
expect_rc "install(noop/up-to-date): -> exit 0" 0
stderr_has "install(noop/up-to-date): it really was the up-to-date no-op exit" \
	'Already up to date. Nothing to do.'
stdout_has "install(noop/up-to-date): HUB_STATUS=ok" "HUB_STATUS='ok'"
stdout_has "install(noop/up-to-date): nothing was applied" "HUB_APPLIED='false'"
stdout_has "install(noop/up-to-date): HUB_BASELINE_ONLY names the exempted domain" "$BASELINE_ONLY_SD"

section "no-op exit: a dry run -> the field still names the exempted domain"
# invoke_install, not run_install: the ABSENCE of --apply is what this case is
# about, so the mode cannot come from a helper that binds it. The message
# assertion below is what makes that absence falsifiable rather than assumed.
TARGET_DRY_RUN="$WORK/target-dry-run"
fx_target_reset "$TARGET_DRY_RUN"
fx_link "$TARGET_DRY_RUN" "$FX_DEPLOYED_BETA_DEV" "$FX_SRC_BETA_DEV"
invoke_install "$TARGET_DRY_RUN" --format=env --domains=software-development
expect_rc "install(noop/dry-run): -> exit 0" 0
stderr_has "install(noop/dry-run): it really was the without---apply no-op exit" \
	'Nothing changed. Re-run with --apply to install.'
stdout_has "install(noop/dry-run): HUB_STATUS=ok" "HUB_STATUS='ok'"
stdout_has "install(noop/dry-run): nothing was applied" "HUB_APPLIED='false'"
stdout_has "install(noop/dry-run): HUB_BASELINE_ONLY names the exempted domain" "$BASELINE_ONLY_SD"
path_absent "install(noop/dry-run): the preview wrote nothing" "$TARGET_DRY_RUN/$FX_DEPLOYED_LENS"

section "an OPTIONAL kind's empty selection is NOT a baseline-only exemption"
# The exclusion the field's own contract states, and the one an over-wide record
# gets wrong. Every ingredient of the exemption is present here — an empty
# selection of the `vcs` kind, and a vcs group already installed for the exemption
# to key off — EXCEPT that `vcs` was never mandatory, so declining it is a genuine
# answer ("no PR/MR automation") rather than a request reduced to a baseline.
#
# THE PRESENT vcs GROUP IS WHAT MAKES THIS FALSIFIABLE. On a fresh target the
# optional clause could be dropped entirely and the run would merely BLOCK, which
# a payload assertion also notices but for the wrong reason. With github already
# there, dropping that clause changes nothing except that this domain starts
# appearing in HUB_BASELINE_ONLY — which is exactly the finding, and nothing else.
TARGET_OPTIONAL_KIND="$WORK/target-optional-kind"
fx_target_reset "$TARGET_OPTIONAL_KIND"
fx_link "$TARGET_OPTIONAL_KIND" "$FX_DEPLOYED_VCS_GITHUB" "$FX_SRC_VCS_GITHUB"
run_install "$TARGET_OPTIONAL_KIND" --domains=software-development --technologies=alpha
expect_rc "install(optional-kind): -> exit 0" 0
stdout_has "install(optional-kind): the mandatory kind really was answered" "HUB_TECHNOLOGIES='alpha'"
stdout_has "install(optional-kind): the optional kind really was left empty" "HUB_SD_VCS=''"
stdout_has "install(optional-kind): HUB_BASELINE_ONLY stays empty" "HUB_BASELINE_ONLY=''"

section "EVERY candidate of the mandatory kind already installed -> still baseline-only"
# The neighbouring target state to the sections above, and the one the two entry
# points reach by different code: with no candidate left, the interactive walk's
# technology screen has no rows to render and is skipped outright, while this loop
# has no rows file and still reaches the empty-selection guard. The field is
# documented as publishing the same value for the same target either way, so this
# is one half of that claim — run-tests-interactive.sh asserts the other half
# against the identical fixture helper.
TARGET_ALL_TECH="$WORK/target-all-technologies"
fx_target_reset "$TARGET_ALL_TECH"
fx_link_every_technology "$TARGET_ALL_TECH"
run_install "$TARGET_ALL_TECH" --domains=software-development
expect_rc "install(all-candidates-installed): -> exit 0" 0
stdout_has "install(all-candidates-installed): HUB_STATUS=ok" "HUB_STATUS='ok'"
stdout_has "install(all-candidates-installed): the declined kind stays empty in the receipt" "HUB_TECHNOLOGIES=''"
stdout_has "install(all-candidates-installed): HUB_BASELINE_ONLY names the exempted domain" "$BASELINE_ONLY_SD"
path_exists "install(all-candidates-installed): the baseline was installed" "$TARGET_ALL_TECH/$FX_DEPLOYED_LENS"

section "two exempted domains are listed in the order they were SELECTED"
# The same target as mixed/both-exempt, asked for in the OPPOSITE order. That
# section's own selection happens to match the registry's domain order, so it
# cannot tell "the order the caller asked in" from "the order the registry lists"
# — and the two answers are equally plausible readings of a payload built by a
# loop. Reversing the flag makes them different strings.
TARGET_ORDER="$WORK/target-baseline-only-order"
fx_target_reset "$TARGET_ORDER"
fx_link "$TARGET_ORDER" "$FX_DEPLOYED_BETA_DEV" "$FX_SRC_BETA_DEV"
fx_link "$TARGET_ORDER" "$FX_DEPLOYED_PM_TRACKER_GITHUB" "$FX_SRC_PM_TRACKER_GITHUB"
run_install "$TARGET_ORDER" --domains=project-management,software-development
expect_rc "install(baseline-only/order): -> exit 0" 0
stdout_has "install(baseline-only/order): the receipt kept the caller's own domain order" \
	"HUB_DOMAINS='project-management,software-development'"
stdout_has "install(baseline-only/order): HUB_BASELINE_ONLY kept it too" \
	"HUB_BASELINE_ONLY='project-management,software-development'"

section "--format=json: baseline_only is an array, and the merged payload stays one document"
# THE ONE SECTION THAT NEEDS jq, and the only reason it is opt-in: --format=json
# requires jq in the hub's own PATH (hub-install.sh dies without it), and
# lib/harness.sh keeps jq out of the toolbox so every other case stays green on a
# machine that has none. Same skip-cleanly convention run-tests-interactive.sh
# applies to expect(1).
#
# WHY THIS IS NOT A stdout_has ON THE env FIELD IN DISGUISE: under --format=json
# the field is not printed alongside the shared ok payload, it is MERGED INTO it
# with jq, and the two ways that can break are both invisible to a text match — a
# key=value line printed beside the document, or two documents concatenated. Both
# are caught by parsing, and the second only by counting the documents, since jq
# accepts a STREAM of them without complaint.
if harness_link_optional_tool jq; then
	TARGET_JSON="$WORK/target-json"

	# The MERGE path: a no-op exit, where baseline_only is added to a document
	# hub_ok_exit built rather than emitted by this script's own jq invocation.
	fx_target_reset "$TARGET_JSON"
	fx_link "$TARGET_JSON" "$FX_DEPLOYED_BETA_DEV" "$FX_SRC_BETA_DEV"
	invoke_install "$TARGET_JSON" --format=json --domains=software-development
	expect_rc "install(json/noop): -> exit 0" 0
	stdout_json_is "install(json/noop): stdout is exactly ONE document, not a stream of two" \
		'[., inputs] | length' '1'
	stdout_json_is "install(json/noop): the shared payload's own status survived the merge" \
		'.status' '"ok"'
	stdout_json_is "install(json/noop): so did the message naming which no-op exit this was" \
		'.message' '"Nothing changed. Re-run with --apply to install."'
	stdout_json_is "install(json/noop): baseline_only is an ARRAY naming the exempted domain" \
		'.baseline_only' '["software-development"]'

	# The merge path's EMPTY case: an empty CSV must become [], never [""] — the
	# distinction a caller's own `length` check turns on.
	fx_target_reset "$TARGET_JSON"
	invoke_install "$TARGET_JSON" --format=json --domains=software-development --technologies=alpha
	expect_rc "install(json/noop-empty): -> exit 0" 0
	stdout_json_is "install(json/noop-empty): nothing exempted is an EMPTY array, not [\"\"]" \
		'.baseline_only' '[]'

	# The NATIVE path: the success payload, where baseline_only is one key among
	# the Result stage's own jq -n construction rather than a merge.
	fx_target_reset "$TARGET_JSON"
	fx_link "$TARGET_JSON" "$FX_DEPLOYED_BETA_DEV" "$FX_SRC_BETA_DEV"
	invoke_install "$TARGET_JSON" --apply --format=json --domains=software-development
	expect_rc "install(json/applied): -> exit 0" 0
	stdout_json_is "install(json/applied): stdout is exactly ONE document" '[., inputs] | length' '1'
	stdout_json_is "install(json/applied): it really was the applied payload" '.applied' 'true'
	stdout_json_is "install(json/applied): baseline_only names the exempted domain" \
		'.baseline_only' '["software-development"]'
	path_exists "install(json/applied): the baseline really was installed" \
		"$TARGET_JSON/$FX_DEPLOYED_LENS"
else
	skip 'the --format=json cases: jq is not installed, and --format=json requires it'
fi

harness_summary
