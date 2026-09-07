# shellcheck shell=sh
# shellcheck disable=SC2034  # the FX_* path constants are consumed by the sourcing runners, which shellcheck cannot see from here
#
# fixture.sh — the SYNTHETIC framework source tree every Management Hub install
#              test runs against, plus the helpers that put a --target into a
#              chosen install state.
#
# WHY SYNTHETIC, not this repo's own software-development/ tree: the real
# technology set changes whenever a technology pair is added or removed, which
# would silently rewrite every expected group list in these suites; and a
# purpose-built tree can give each technology a different UNIT COUNT, which is
# what makes every lib/hub-state.sh hub_group_state answer reachable:
#
#   alpha  developer + reviewer + standard (3 units) — link one of the three and
#          the group reads `partial`; the INCOMPLETE flavour of partial.
#   beta   developer only (1 unit)                   — link it and the group
#          reads `installed`.
#   gamma  developer only (1 unit)                   — put a plain FILE at its
#          deployed path and the group reads `partial`; the DIVERGED flavour.
#   (link nothing at all and a group reads `available`.)
#
# The two specialist skills are named so lib/hub-domains.sh's hub_sd_vcs_of
# classifies them by token (gh -> github, glab -> gitlab), which is what gives
# Software Development its SECOND selection kind — the `vcs` kind whose presence
# must NOT exempt an empty `technology` selection. Project Management is shipped
# too, as a second MANDATORY-kind domain: `pm-tracker` on a single-kind domain,
# so a block there cannot be an accident of the optional-kind path, and a MIXED
# --domains selection has a second domain to iterate to.
#
# GTD is shipped as the third registered domain because it is the registry's only
# domain whose selection kind is `none` AND whose whole footprint is one `atomic:`
# group rather than a `baseline:` group (lib/hub-domains.sh's GROUP KEY GRAMMAR).
# That combination makes it the only reachable case of TWO separate rules at once:
# it is VACUOUSLY eligible for a required-only install (no mandatory kind can be
# unanswered), and it is simultaneously NOT actionable (with no baseline group,
# hub_domain_pending_baseline reports nothing pending), so it must succeed under
# --baseline-only while never being offered by the `r` key or named in either
# Required-install block. Neither half is observable on a two-domain fixture.
#
# A partial --source (no accounts/, no CLAUDE.md) is a supported state, not a
# degraded one — see lib/hub-domains.sh's hub_domain_exists.
#
# A SECOND, much smaller tree lives at the bottom of this file (fx_build_color_source)
# for the cosmetic `color:` check alone; its own block states why it is separate.
#
# Sourced by the test runners — never executed directly.

# --- Source-tree paths ------------------------------------------------------
FX_SD_DEVELOPERS='software-development/agents/developers'
FX_SD_SPECIALIST_SKILLS='software-development/agents/specialists/fixture-operator/skills'
FX_PM_AGENT_SKILLS='project-management/agents/pm-fixture/skills'
FX_GTD_AGENT='gtd/agents/gtd-fixture-writer'

# The source paths a target-side symlink has to resolve to. Only the units some
# test actually plants are named; the rest are only ever written, never linked.
FX_SRC_ALPHA_DEV="$FX_SD_DEVELOPERS/alpha-developer.md"
FX_SRC_ALPHA_REVIEWER='software-development/agents/reviewers/tech/alpha-reviewer.md'
FX_SRC_ALPHA_STANDARD='software-development/shared/standards/tech/standard-alpha'
FX_SRC_BETA_DEV="$FX_SD_DEVELOPERS/beta-developer.md"
FX_SRC_GAMMA_DEV="$FX_SD_DEVELOPERS/gamma-developer.md"
FX_SRC_VCS_GITHUB="$FX_SD_SPECIALIST_SKILLS/procedure-gh-fixture"
FX_SRC_PM_TRACKER_GITHUB="$FX_PM_AGENT_SKILLS/procedure-gh-fixture-issues"

# Software Development's BASELINE units — the three that install unconditionally
# the moment the domain is picked, named here because fx_link_sd_baseline below
# plants all three to reach the "eligible, but nothing left to install" state.
FX_SRC_LENS='software-development/agents/reviewers/lens/lens-fixture-reviewer.md'
FX_SRC_SPECIALIST='software-development/agents/specialists/fixture-operator/fixture-operator.md'
FX_SRC_FLOW='software-development/flows/flow-fixture'
FX_SRC_PM_AGENT='project-management/agents/pm-fixture/pm-fixture.md'
FX_SRC_PM_FLOW='project-management/flows/flow-pm-fixture'

# --- Deployed (target-side) paths -------------------------------------------
#
# The deployed layout (agents/<name>.md, skills/<name>) is written out here
# rather than read back from lib/hub-state.sh's hub_target_path: a test that
# derived the layout from the code under test could not notice that code getting
# the layout wrong.
FX_DEPLOYED_ALPHA_DEV='agents/alpha-developer.md'
FX_DEPLOYED_ALPHA_REVIEWER='agents/alpha-reviewer.md'
FX_DEPLOYED_ALPHA_STANDARD='skills/standard-alpha'
FX_DEPLOYED_BETA_DEV='agents/beta-developer.md'
FX_DEPLOYED_GAMMA_DEV='agents/gamma-developer.md'
FX_DEPLOYED_LENS='agents/lens-fixture-reviewer.md'
FX_DEPLOYED_SPECIALIST='agents/fixture-operator.md'
FX_DEPLOYED_FLOW='skills/flow-fixture'
FX_DEPLOYED_VCS_GITHUB='skills/procedure-gh-fixture'
FX_DEPLOYED_VCS_GITLAB='skills/procedure-glab-fixture'
FX_DEPLOYED_PM_AGENT='agents/pm-fixture.md'
FX_DEPLOYED_PM_FLOW='skills/flow-pm-fixture'
FX_DEPLOYED_PM_TRACKER_GITHUB='skills/procedure-gh-fixture-issues'
FX_DEPLOYED_PM_TRACKER_JIRA='skills/procedure-jira-fixture'
FX_DEPLOYED_GTD_AGENT='agents/gtd-fixture-writer.md'
FX_DEPLOYED_GTD_CAPTURE='skills/procedure-gtd-fixture-capture'
FX_DEPLOYED_GTD_FLOW='skills/flow-gtd-fixture'

# fx_write_md PATH NAME [COLOR] -> one agent-shaped markdown file. The YAML
# frontmatter `name:` is what discovery reads for identity (lib/hub-discovery.sh's
# hub_disc_resolve_names); the PATH is what decides which group it lands in.
#
# COLOR is the optional badge tint hub_disc_resolve_colors reads. An omitted or
# empty COLOR writes NO `color:` line at all, which is that check's `missing`
# status — the shape almost every framework unit really has, and the reason this
# is one writer with an optional field rather than two copies of the template.
fx_write_md() {
	mkdir -p "${1%/*}"
	{
		printf -- '---\nname: %s\n' "$2"
		[ -z "${3:-}" ] || printf -- 'color: %s\n' "$3"
		printf -- 'description: a fixture unit.\n---\n\nFixture body.\n'
	} >"$1"
}

# fx_write_skill DIR NAME [COLOR] -> one skill, i.e. a directory holding SKILL.md.
fx_write_skill() { fx_write_md "$1/SKILL.md" "$2" "${3:-}"; }

# fx_build_source DIR -> write the whole fixture tree under DIR and remember it
# as the source every later fx_link resolves against. DIR must be CANONICAL
# (created through `cd … && pwd -P`): --source is canonicalized by the hub
# (hub_realpath) and a planted symlink is compared byte-for-byte against that
# canonical path (lib/hub-state.sh's hub_state_set), so on macOS — where /tmp is
# itself a symlink to /private/tmp — an uncanonicalized path would make every
# planted symlink read DIVERGED instead of `installed`.
fx_build_source() {
	FX_SRC=$1
	fx_write_md "$FX_SRC/$FX_SRC_ALPHA_DEV" alpha-developer
	fx_write_md "$FX_SRC/$FX_SRC_BETA_DEV" beta-developer
	fx_write_md "$FX_SRC/$FX_SD_DEVELOPERS/gamma-developer.md" gamma-developer
	fx_write_md "$FX_SRC/software-development/agents/reviewers/tech/alpha-reviewer.md" alpha-reviewer
	fx_write_skill "$FX_SRC/software-development/shared/standards/tech/standard-alpha" standard-alpha
	fx_write_md "$FX_SRC/software-development/agents/reviewers/lens/lens-fixture-reviewer.md" lens-fixture-reviewer
	fx_write_md "$FX_SRC/software-development/agents/specialists/fixture-operator/fixture-operator.md" fixture-operator
	fx_write_skill "$FX_SRC/$FX_SRC_VCS_GITHUB" procedure-gh-fixture
	fx_write_skill "$FX_SRC/$FX_SD_SPECIALIST_SKILLS/procedure-glab-fixture" procedure-glab-fixture
	fx_write_skill "$FX_SRC/software-development/flows/flow-fixture" flow-fixture
	fx_write_md "$FX_SRC/project-management/agents/pm-fixture/pm-fixture.md" pm-fixture
	fx_write_skill "$FX_SRC/$FX_SRC_PM_TRACKER_GITHUB" procedure-gh-fixture-issues
	fx_write_skill "$FX_SRC/$FX_PM_AGENT_SKILLS/procedure-jira-fixture" procedure-jira-fixture
	fx_write_skill "$FX_SRC/project-management/flows/flow-pm-fixture" flow-pm-fixture
	# GTD's three units, in the two subtrees lib/hub-discovery.sh's hub_disc_gtd
	# walks: an agent (with a skill nested under it, the shape its `-maxdepth 2`
	# agent walk exists for) and a flow. All three land in the one `atomic:gtd`
	# group — see this file's header for why that group shape is the point.
	fx_write_md "$FX_SRC/$FX_GTD_AGENT/gtd-fixture-writer.md" gtd-fixture-writer
	fx_write_skill "$FX_SRC/$FX_GTD_AGENT/skills/procedure-gtd-fixture-capture" procedure-gtd-fixture-capture
	fx_write_skill "$FX_SRC/gtd/flows/flow-gtd-fixture" flow-gtd-fixture
}

# fx_target_reset DIR -> DIR as a pristine, empty deployment target.
fx_target_reset() {
	rm -rf "$1"
	mkdir -p "$1/agents" "$1/skills"
}

# fx_link TARGET DEPLOYED_RELPATH SRC_RELPATH -> the symlink that makes one unit
# read `installed`: a link at its deployed path resolving to exactly its source.
fx_link() { ln -s "$FX_SRC/$3" "$1/$2"; }

# fx_occupy TARGET DEPLOYED_RELPATH -> a non-framework regular file at a unit's
# deployed path, which reads DIVERGED and so makes its group read `partial`.
fx_occupy() { printf 'not a framework symlink\n' >"$1/$2"; }

# fx_link_every_technology TARGET -> every unit of every technology group linked,
# so ALL THREE technology groups read `installed` and none is left available.
#
# That is a distinct target state from "one technology installed", not a stronger
# version of it, and it is the one both entry points have to agree about: with no
# candidate left, the interactive walk never RENDERS the technology screen (its rows
# file is empty) while the non-interactive loop still reaches the empty-selection
# guard, so the same target is judged by two different pieces of code. Shared here
# rather than written out in each runner precisely so the two suites cannot drift
# into asserting parity between two different fixtures.
#
# alpha's THREE units are all linked deliberately: a group is `installed` only when
# every unit is, and linking just its developer would leave it `partial` and still
# offered as a row.
fx_link_every_technology() {
	fx_link "$1" "$FX_DEPLOYED_ALPHA_DEV" "$FX_SRC_ALPHA_DEV"
	fx_link "$1" "$FX_DEPLOYED_ALPHA_REVIEWER" "$FX_SRC_ALPHA_REVIEWER"
	fx_link "$1" "$FX_DEPLOYED_ALPHA_STANDARD" "$FX_SRC_ALPHA_STANDARD"
	fx_link "$1" "$FX_DEPLOYED_BETA_DEV" "$FX_SRC_BETA_DEV"
	fx_link "$1" "$FX_DEPLOYED_GAMMA_DEV" "$FX_SRC_GAMMA_DEV"
}

# fx_link_sd_baseline TARGET -> every unit of Software Development's BASELINE
# linked, so the domain has NO never-installed required content left.
#
# The third distinct target state the required-only routes turn on, and the only
# one that separates their two preconditions: a domain here is still ELIGIBLE (a
# technology is present, so no mandatory kind is unanswered) yet no longer
# ACTIONABLE (nothing of its baseline is missing), which is exactly the state that
# must hide the `r` key and the Required-install block while leaving the domain
# itself perfectly installable through its own screens. Paired with fx_link of one
# technology by every caller — this helper alone leaves the domain ineligible.
fx_link_sd_baseline() {
	fx_link "$1" "$FX_DEPLOYED_LENS" "$FX_SRC_LENS"
	fx_link "$1" "$FX_DEPLOYED_SPECIALIST" "$FX_SRC_SPECIALIST"
	fx_link "$1" "$FX_DEPLOYED_FLOW" "$FX_SRC_FLOW"
}

# fx_link_pm_baseline TARGET -> the same state for Project Management's two baseline
# units. Its own helper rather than a `fx_link_every_baseline` covering both, because
# the two domains are put into that state for different reasons in different cases and
# a combined helper would force every caller to take both.
fx_link_pm_baseline() {
	fx_link "$1" "$FX_DEPLOYED_PM_AGENT" "$FX_SRC_PM_AGENT"
	fx_link "$1" "$FX_DEPLOYED_PM_FLOW" "$FX_SRC_PM_FLOW"
}

# --- The badge-color tree ---------------------------------------------------
#
# A SECOND source tree, self-contained here rather than folded into
# fx_build_source above, and that is the point of it: the primary tree is shared
# with run-tests-interactive.sh, whose expect(1) screens are compared as bytes, so
# a `color:` warning printed on every run there would be a captured-screen change
# in a suite that has nothing to do with badge colors.
#
# It also puts every status hub_disc_resolve_colors can report into ONE discovery
# run, which is what lets a `silent` assertion mean anything: the silent statuses
# are observed on the same run as the warned ones, so a mutation that deletes the
# check fails the positive half of the section instead of quietly satisfying its
# negative half.

# The name `badname-developer.md` declares. Shared with the assertion that reads
# the rejection diagnostic back, because the offending name is quoted in it.
FX_COLOR_BADNAME='../../pwned'

# Source-relative paths, one per case, named after the status each one provokes:
#
#   BROKEN        color: white -> the one confirmed-broken value: warns, installs
#   UNRECOGNIZED  color: whyte -> on neither list: warns, installs
#   OK            color: teal  -> on the known palette: silent
#   ABSENT        no color: at all -> the optional field omitted: silent
#   BADNAME       color: white AND an illegal `name:` -> rejected by the name
#                 check, and must NOT also collect a note about its badge tint
#   SKILL         a SKILL carrying color: white in its own frontmatter -> a skill
#                 is never scanned at all. Real frontmatter rather than a body
#                 line deliberately: the scan only ever reads the frontmatter
#                 block, so a body line would read `missing` even with the
#                 kind narrowing removed, and the assertion could not fail.
FX_COLOR_SRC_BROKEN="$FX_SD_DEVELOPERS/brokencolor-developer.md"
FX_COLOR_SRC_UNRECOGNIZED="$FX_SD_DEVELOPERS/typocolor-developer.md"
FX_COLOR_SRC_OK="$FX_SD_DEVELOPERS/goodcolor-developer.md"
FX_COLOR_SRC_ABSENT="$FX_SD_DEVELOPERS/nocolor-developer.md"
FX_COLOR_SRC_BADNAME="$FX_SD_DEVELOPERS/badname-developer.md"
FX_COLOR_SRC_SKILL='software-development/shared/standards/tech/standard-goodcolor/SKILL.md'

FX_COLOR_DEPLOYED_BROKEN='agents/brokencolor-developer.md'
FX_COLOR_DEPLOYED_UNRECOGNIZED='agents/typocolor-developer.md'

# fx_build_color_source DIR -> that tree. Every unit is a lone
# `{key}-developer.md` because one file is all a technology group needs to exist,
# and this tree is only ever discovered and installed by its own section.
fx_build_color_source() {
	fx_write_md "$1/$FX_COLOR_SRC_BROKEN" brokencolor-developer white
	fx_write_md "$1/$FX_COLOR_SRC_UNRECOGNIZED" typocolor-developer whyte
	fx_write_md "$1/$FX_COLOR_SRC_OK" goodcolor-developer teal
	fx_write_md "$1/$FX_COLOR_SRC_ABSENT" nocolor-developer
	fx_write_md "$1/$FX_COLOR_SRC_BADNAME" "$FX_COLOR_BADNAME" white
	fx_write_skill "${1}/${FX_COLOR_SRC_SKILL%/SKILL.md}" standard-goodcolor white
}
