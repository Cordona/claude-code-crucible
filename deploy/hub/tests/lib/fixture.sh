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
# A partial --source (no gtd/, no accounts/, no CLAUDE.md) is a supported state,
# not a degraded one — see lib/hub-domains.sh's hub_domain_exists.
#
# Sourced by the test runners — never executed directly.

# --- Source-tree paths ------------------------------------------------------
FX_SD_DEVELOPERS='software-development/agents/developers'
FX_SD_SPECIALIST_SKILLS='software-development/agents/specialists/fixture-operator/skills'
FX_PM_AGENT_SKILLS='project-management/agents/pm-fixture/skills'

# The source paths a target-side symlink has to resolve to. Only the units some
# test actually plants are named; the rest are only ever written, never linked.
FX_SRC_ALPHA_DEV="$FX_SD_DEVELOPERS/alpha-developer.md"
FX_SRC_ALPHA_REVIEWER='software-development/agents/reviewers/tech/alpha-reviewer.md'
FX_SRC_ALPHA_STANDARD='software-development/shared/standards/tech/standard-alpha'
FX_SRC_BETA_DEV="$FX_SD_DEVELOPERS/beta-developer.md"
FX_SRC_GAMMA_DEV="$FX_SD_DEVELOPERS/gamma-developer.md"
FX_SRC_VCS_GITHUB="$FX_SD_SPECIALIST_SKILLS/procedure-gh-fixture"
FX_SRC_PM_TRACKER_GITHUB="$FX_PM_AGENT_SKILLS/procedure-gh-fixture-issues"

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

# fx_write_md PATH NAME -> one agent-shaped markdown file. The YAML frontmatter
# `name:` is the only thing discovery reads out of it (lib/hub-discovery.sh's
# hub_disc_resolve_names); the PATH is what decides which group it lands in.
fx_write_md() {
	mkdir -p "${1%/*}"
	printf -- '---\nname: %s\ndescription: a fixture unit.\n---\n\nFixture body.\n' "$2" >"$1"
}

# fx_write_skill DIR NAME -> one skill, i.e. a directory holding SKILL.md.
fx_write_skill() { fx_write_md "$1/SKILL.md" "$2"; }

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
