#!/usr/bin/env sh
# lib/hub-domains.sh — the DOMAIN REGISTRY and the STRUCTURAL RULES that
#                       define what a path shape means. This is where every fact
#                       about a domain is DECLARED; it is not the only file a new
#                       domain touches (see the blast radius below).
#
# Sourced after lib/hub-common.sh. Not executable on its own.
#
# ===========================================================================
# THE ZERO-HARDCODED-NAMES CONTRACT
# ===========================================================================
# This file contains NO list of specific agent/skill names, and neither does
# any other file in the hub. Adding, removing or renaming an artifact WITHIN an
# existing domain requires zero changes anywhere: every unit is found by walking
# a path shape at runtime (lib/hub-discovery.sh applies the rules stated below).
#
# What IS encoded here, deliberately and by design:
#   1. The three domains that exist, their display labels and their blurbs.
#   2. The directory names each domain's structure uses (flows/, shared/,
#      agents/developers/, ...) — a path SHAPE, never an item name.
#   3. The naming PATTERNS the display layer and the backend classifier read
#      (role suffixes, type-word prefixes, the jira/gh tokens in
#      hub_pm_backend_of) — patterns, never name lists.
#   4. The ONE cross-domain shared unit and its consumers (see
#      hub_shared_consumers). There is exactly one such unit in the framework
#      today; a small explicit named rule is correct here and a fully generic
#      "cross-domain dependency declaration" system would be premature
#      abstraction (YAGNI).
#   5. The FEATURE names of the one domain that has any (GTD — see §4b). Their
#      LABELS are editorial and cannot be derived, exactly as a domain's own
#      label cannot; their MEMBERSHIP is a path shape like everything else here,
#      so a unit renamed inside GTD still needs no change.
#
# ===========================================================================
# THE BLAST RADIUS OF A FOURTH DOMAIN — stated honestly
# ===========================================================================
# Adding a domain is NOT one registry entry, and this comment used to claim it
# was. What it actually costs, exhaustively:
#
#   THIS FILE
#     * HUB_DOMAIN_KEYS, plus an arm in hub_domain_label /
#       hub_domain_short_label / hub_domain_blurb / hub_domain_selection_kind
#       (four closed lookups that deliberately die on an unknown key rather than
#       degrade), and hub_domain_empty_selection_message when the new domain has
#       a sub-selection.
#     * IF the new domain introduces a sub-selection kind that does not already
#       exist: one arm each in hub_selection_kind_prefix /
#       hub_selection_kind_prompt / hub_selection_kind_noun /
#       hub_selection_kind_flag, plus the directory-shape constants its own
#       structure uses. A domain that REUSES an existing kind (technology or
#       pm-backend) costs none of this.
#     * hub_shared_consumers, only if the new domain consumes a cross-domain
#       unit.
#
#   lib/hub-discovery.sh
#     * one arm in hub_disc_collect's per-domain case dispatch, plus the
#       hub_disc_<domain> walker that arm calls (its structure is its own; the
#       three existing walkers share no shape beyond emitting candidates).
#     * hub_disc_render_tables' domain_label() awk function takes one more
#       -v label.
#     * IF the domain introduces a NEW selection kind: one more arm in
#       hub_disc_render_tables' PASS 2 group-metadata chain — the
#       has_group_prefix(group, p_tech) / p_pm_backend ladder is what stamps a
#       group's role/domain/selkind/selkey/atomic and builds its label, so a new
#       kind's groups fall through to the baseline arm without it and are never
#       selectable at all. Its group-key prefix constant is passed in via -v like
#       the existing four, never spelled as an awk literal.
#
#   hub-install.sh
#     * A domain REUSING an existing selection kind: nothing. The selection walk,
#       the "which step comes next" derivation, the per-domain preview blocks, the
#       plan-group assembly, --all's select-everything expansion and the flag
#       validation all iterate HUB_DOMAIN_KEYS / hi_selection_kinds and ask
#       hub_domain_selection_kind / hub_domain_label, so no edit is needed. (--all
#       and flag validation used to name SEL_TECHNOLOGIES / SEL_BACKENDS
#       literally, which made a third domain on an existing kind silently
#       unselectable by flag while the interactive walk offered it — the exact
#       invisible failure this comment previously claimed could not happen.)
#     * A domain with a NEW selection kind touches these, and only these:
#         - hi_flag_value — map the kind to the OPT_ variable its own new --flag
#           fills. That flag also needs its case arms in the argument parser, so
#           this one is irreducible rather than an oversight.
#         - hi_selection_rows — only IF the new kind's checklist rows need a
#           per-kind annotation the way `pm-backend` does (it adds a hint); a kind
#           whose rows are plain label+state needs no arm at all.
#         - hub_selection_kind_needs_domain — only IF a bare row label of the new
#           kind would be ambiguous on a screen that shows no domain heading. A
#           kind whose labels name themselves (as `technology`'s do) needs no arm;
#           the predicate's default is "no".
#         - hi_preview_domain's two per-kind tests — the `= technology` guard that
#           decides whether a selected key ALSO has a standard to walk (in both the
#           selected loop and the already-installed scan), and hub-install.sh's own
#           `= software-development` test that splits Software Development's
#           baseline into lens reviewers and the rest. A new kind that has neither
#           a per-key standard nor a split baseline needs neither.
#         - hi_selection_kind_noun_plural — only if the new noun's plural is
#           irregular; the regular "+s" fallback covers the rest.
#       (This list previously named hi_preview_selectable_blocks, a function that
#       no longer exists — the preview was rebuilt around hi_preview_domain plus
#       the hi_bucket_* accumulators, and the generic per-domain renderer that
#       entry warned would say something false about one of the kinds is in fact
#       what ships today: the per-kind prose comes from the registry's own nouns
#       and labels, so there is nothing left to special-case per kind in the
#       rendering itself.)
#     * THE ONE REMAINING GENUINE LIMITATION, stated because it is not obvious:
#       a selection file and a rows file are named after the KIND
#       (hi_sel_file/hi_rows_file), so TWO domains sharing one kind would share
#       one selection file and render the same sub-selection screen once per
#       domain — hi_steps_build emits one step per selected domain that has a
#       sub-selection. Nothing today does this (each of the three domains has a
#       distinct kind or none), and the per-kind naming is what buys the
#       zero-edit reuse above; a second domain on an existing kind would need
#       these files keyed by domain+kind instead.
#
#   Everything else (hub-list.sh, hub-status.sh, hub-uninstall.sh,
#   hub-doctor.sh, lib/hub-state.sh) is domain-agnostic and needs no edit.
#
#   * ONE SELECTIVE-UNINSTALL CONSEQUENCE, free of edits but not of behavior: a
#     domain whose selection kind is `none` (today, GTD) cannot be removed
#     selectively at all — only `--all` reaches it. hub-uninstall.sh's baseline
#     cascade keys off "does this domain still have a selectable group present",
#     and a domain with no selectable groups has an always-empty set that must not
#     be read as "nothing needs this any more". A new `none` domain inherits that
#     property automatically; a new domain on an existing kind does not have it.
#
# ===========================================================================
# GROUP KEY GRAMMAR
# ===========================================================================
# Every discovered unit belongs to exactly one GROUP. A group is the atom of
# install/uninstall intent, and its metadata is derived by PARSING its key —
# there is no separate group-metadata table to keep in sync:
#
#   baseline:<domain>      installed unconditionally the moment <domain> is
#                          chosen; never a selectable row.
#   tech:<key>             Software Development's per-technology fan-out; one
#                          group per discovered developer agent.
#   pm-backend:<key>       Project Management's backend fan-out (github|jira).
#   shared:<key>           cross-domain, installed once, removed only when no
#                          consumer remains.
#
# The four prefixes are CONSTANTS below and the key is always built by
# hub_group_key — never by string concatenation at a call site, and never parsed
# by a magic substr() offset. Both were done by hand before this pass (~10 sites
# and three offsets), which is exactly how a grammar documented in one place
# drifts from the code that implements it.
#
# Portability: POSIX sh only.

# ---------------------------------------------------------------------------
# 1. The domain registry.
# ---------------------------------------------------------------------------

# HUB_DOMAIN_KEYS — every domain, in the canonical order every screen renders
# them in (onboarding checklist, status block, previews, List).
HUB_DOMAIN_KEYS='software-development project-management gtd'

# hub_domain_label DOMAIN -> the Title Case display name used on the
# onboarding checklist and in preview headings. NOT derived from the key by
# mechanical case conversion: "software-development" would sentence-case to
# "Software development", and the spec's own screens read "Software
# Development".
hub_domain_label() {
	case $1 in
	software-development) printf 'Software Development' ;;
	project-management) printf 'Project Management' ;;
	gtd) printf 'Getting Things Done (GTD)' ;;
	*) die "hub_domain_label: unknown domain '$1'" ;;
	esac
}

# hub_domain_short_label DOMAIN -> the shorter form the status block uses
# (spec §7: "Getting Things Done:" without the parenthetical, since the block
# is already a labeled vertical list and the acronym adds nothing there).
hub_domain_short_label() {
	case $1 in
	gtd) printf 'Getting Things Done' ;;
	*) hub_domain_label "$1" ;;
	esac
}

# hub_domain_blurb DOMAIN -> the one-line "what this domain gives you" text
# shown beside each row on the onboarding checklist.
#
# EACH BLURB TRACKS ITS OWN DOMAIN'S ACTUAL STRUCTURE, and GTD's is the one that
# can now be checked against something: the registry declares exactly TWO named
# features for it (HUB_GTD_FEATURE_KEYS below), so a blurb reading "capture,
# triage, process an inbox" promised a third capability no screen names and no
# feature exists for. Software Development's and Project Management's each track
# their own shape the same way — the technology pair plus its shared plumbing, and
# the two backends.
hub_domain_blurb() {
	case $1 in
	software-development) printf 'technologies, review swarm, git ops' ;;
	project-management) printf 'GitHub/Jira ticket authoring' ;;
	gtd) printf 'capture and triage an inbox' ;;
	*) die "hub_domain_blurb: unknown domain '$1'" ;;
	esac
}

# hub_domain_selection_kind DOMAIN -> which sub-selection screen this domain
# needs after the onboarding checklist, or "none":
#   technology  -> Software Development's technology multi-select (spec §3)
#   pm-backend  -> Project Management's backend multi-select (spec §4)
#   none        -> GTD: self-contained, no fan-out, no screen (spec §5). A `none`
#                  domain is also UNREACHABLE BY SELECTIVE UNINSTALL — only
#                  `--all` removes it. It has no selectable groups, so it has no
#                  consumer set for hub-uninstall.sh's baseline cascade to key
#                  off, and an always-empty set read as "nothing needs this any
#                  more" would sweep the domain out on every unrelated uninstall.
#                  A deliberate consequence, stated at hub-uninstall.sh's own
#                  "THE DOMAIN BASELINE RULE".
hub_domain_selection_kind() {
	case $1 in
	software-development) printf 'technology' ;;
	project-management) printf 'pm-backend' ;;
	gtd) printf 'none' ;;
	*) die "hub_domain_selection_kind: unknown domain '$1'" ;;
	esac
}

# hub_domain_empty_selection_message DOMAIN -> the inline block message shown
# when a domain that needs a sub-selection was given none (spec §3/§4's
# "Empty-selection rule"). The interactive screens print this and re-prompt;
# the non-interactive path prints it and exits blocked.
hub_domain_empty_selection_message() {
	case $1 in
	software-development)
		printf 'Software Development doesn'\''t do anything without at least one technology. Choose at least one, or press "b" to remove Software Development from your selection.'
		;;
	project-management)
		printf 'Project Management can'\''t create or update tracked work without at least one backend. Choose GitHub, Jira, or both, or press "b" to remove Project Management from your selection.'
		;;
	*) die "hub_domain_empty_selection_message: domain '$1' has no sub-selection" ;;
	esac
}

# hub_domain_root SRC DOMAIN -> the domain's own subtree in the framework
# source. The one place a domain key becomes a directory name.
hub_domain_root() {
	printf '%s/%s' "$1" "$2"
}

# hub_domain_exists SRC DOMAIN -> 0 when the domain's subtree is present in
# SRC. A framework source that ships only some domains (a partial checkout, a
# custom --source) is a legitimate state, not an error.
hub_domain_exists() {
	[ -d "$(hub_domain_root "$1" "$2")" ]
}

# hub_domain_is_registered DOMAIN -> exit 0 when DOMAIN is one of the registry's
# own domain keys. The `_shared` sentinel lib/hub-discovery.sh writes into a shared
# group's domain column is deliberately not one of them, and neither is the empty
# string.
#
# THE REGISTRY-MEMBERSHIP QUESTION, which is NOT hub_domain_exists' question:
# `exists` asks about a SOURCE TREE ("did this --source ship the domain's
# subtree"), this asks about the REGISTRY ("is this key a domain at all"). The two
# were conflated nowhere, but the second had no owner: hub-install.sh carried this
# `case` glob as its own hi_domain_is_registered and hub-doctor.sh carried an
# equivalent `for` loop over HUB_DOMAIN_KEYS inside hd_domain_heading, which is two
# spellings of a registry predicate while every other one (hub_domain_label,
# hub_domain_selection_kind, hub_domain_exists) has exactly one. Both call it now.
#
# A `case` glob over the space-padded key list, not a `for` loop: it is one test
# instead of one per domain, and it needs no loop variable to leak. HUB_DOMAIN_KEYS
# holds shell words, so " $1 " can only match a whole key.
#
# RETURNS a status rather than printing, because every caller is a test. Unlike its
# four closed-lookup neighbours it deliberately does NOT die on an unknown key: "is
# this a domain" is a question whose honest answer for a non-domain is `no`, which
# is the whole reason both call sites ask it.
hub_domain_is_registered() {
	case " $HUB_DOMAIN_KEYS " in
	*" $1 "*) return 0 ;;
	esac
	return 1
}

# ---------------------------------------------------------------------------
# 2. The group-key grammar — constructed and parsed in one place only.
# ---------------------------------------------------------------------------

# The four group-key prefixes. Spelled ONCE here; every producer builds a key
# with hub_group_key and every parser (including lib/hub-discovery.sh's awk,
# which receives them via -v) reads them from these constants.
HUB_GROUP_PREFIX_BASELINE='baseline'
HUB_GROUP_PREFIX_TECH='tech'
HUB_GROUP_PREFIX_PM_BACKEND='pm-backend'
HUB_GROUP_PREFIX_SHARED='shared'

# hub_group_key PREFIX KEY -> the group key for one of the four kinds, e.g.
# `hub_group_key "$HUB_GROUP_PREFIX_TECH" python` -> "tech:python". THE
# constructor: no call site anywhere writes the ":" itself.
hub_group_key() {
	printf '%s:%s' "$1" "$2"
}

# WHICH GROUPS ARE ATOMIC — and the two different questions that phrase asks.
#
# There is no shared `hub_group_is_atomic` helper, deliberately. One existed, and
# it answered only the ROW-PROJECTION question ("does this group collapse to one
# row in hub_rows_build/HUB_ROWS") while carrying a name that invited a reader to
# take it for the REMOVAL question too. Both answers are already sourced
# authoritatively elsewhere, so the helper was a second spelling of a fact that has
# an owner:
#
#   ROW PROJECTION — the group table's own `atomic` column (set once in
#     lib/hub-discovery.sh, read by hub_rows_build via hub_group_field … 7). Only a
#     Project Management backend is atomic there: its skills always travel together
#     as one backend unit, which is why it has a row key of its own (below). A
#     technology group is deliberately NOT atomic in this projection — HUB_ROWS is
#     what Doctor's diverged-components section and List's env/json payload read,
#     and both must be able to name "Python agent reviewer" specifically.
#
#   REMOVAL COVERAGE — hub-uninstall.sh's own hu_removal_is_atomic, where EVERY
#     selectable group is atomic, technology included: a developer, its reviewer and
#     its standard are one thing a human installs and one thing a human removes.
#
# Keeping them apart is not about what a widening would break; it is that they are
# different questions with different right answers for the same group. A technology
# is one removable thing AND several nameable rows, simultaneously, and one
# predicate cannot honestly say both. Which rows a SCREEN shows is a third thing
# again: each screen's own coarser projection (hub-list.sh's
# hl_selectable_rows_build, hub-uninstall.sh's SELECTABLE_ROWS).

# hub_group_row_key GROUP -> the stable, lowercase-kebab identifier an ATOMIC
# group is named by in LIST's per-unit vocabulary and in `--components`, so the row
# List names and the flag token an agent passes are the same token — the
# human/agent parity requirement, at row granularity. Non-atomic groups have no
# row key of their own: each of their units is its own row, named by the unit.
#
# NOT the interactive uninstall checklist's vocabulary: that screen toggles a
# selectable group's SELKEY (hub_selection_keys' column, e.g. `github` /
# `python`), not this row key. `--components` accepts both, and resolves either to
# the whole group.
hub_group_row_key() {
	case $1 in
	"$HUB_GROUP_PREFIX_PM_BACKEND":*) printf '%s-backend' "${1#"$HUB_GROUP_PREFIX_PM_BACKEND":}" ;;
	*) die "hub_group_row_key: group '$1' is not atomic and has no row key" ;;
	esac
}

# ---------------------------------------------------------------------------
# 2b. Sub-selection kinds — everything the interactive walk and the flag layer
#     need to know about a kind, keyed by the kind and never by a domain name.
# ---------------------------------------------------------------------------
#
# hub_domain_selection_kind (above) answers "which kind does this domain need".
# These four answer "what does a kind look like", so hub-install.sh can drive its
# whole selection walk, its preview and its flag validation off the registry
# instead of testing for the literal strings "software-development" and
# "project-management" — which is what made a fourth domain a multi-file edit.
#
# Each dies on an unknown kind rather than degrading: an empty prompt or an empty
# flag name in an error message is a false answer, not a lesser one (the same
# fail-loud convention as hub_domain_label and lib/hub-tools.sh's lookups).

# hub_selection_kind_prefix KIND -> the group-key prefix a selectable group of
# this kind carries. The one place "technology" (the kind) is mapped to "tech"
# (the prefix); the two are deliberately different words and were previously
# bridged by hand at every call site.
hub_selection_kind_prefix() {
	case $1 in
	technology) printf '%s' "$HUB_GROUP_PREFIX_TECH" ;;
	pm-backend) printf '%s' "$HUB_GROUP_PREFIX_PM_BACKEND" ;;
	*) die "hub_selection_kind_prefix: unknown selection kind '$1'" ;;
	esac
}

# hub_selection_kind_prompt KIND -> the sub-selection screen's title suffix,
# appended to the domain's own label ("Software Development — select
# technologies").
hub_selection_kind_prompt() {
	case $1 in
	technology) printf 'select technologies' ;;
	pm-backend) printf 'select backend(s)' ;;
	*) die "hub_selection_kind_prompt: unknown selection kind '$1'" ;;
	esac
}

# hub_selection_kind_noun KIND -> the singular noun for one candidate of this
# kind, used by the unsatisfiable-domain message ("No technology was found in
# ...").
hub_selection_kind_noun() {
	case $1 in
	technology) printf 'technology' ;;
	pm-backend) printf 'backend' ;;
	*) die "hub_selection_kind_noun: unknown selection kind '$1'" ;;
	esac
}

# hub_selection_kind_flag KIND -> the flag an agent passes to select this kind,
# named in usage errors so the message points at the flag the caller actually
# used.
hub_selection_kind_flag() {
	case $1 in
	technology) printf '%s' '--technologies' ;;
	pm-backend) printf '%s' '--pm-backends' ;;
	*) die "hub_selection_kind_flag: unknown selection kind '$1'" ;;
	esac
}

# hub_selection_kind_needs_domain KIND -> exit 0 when a row of this kind cannot
# stand alone: its label names a THING (a service, a product) rather than naming
# itself, so a screen that shows no domain heading must qualify it with the
# domain's own label — "Project Management (GitHub)", not a bare "GitHub".
#
# WHY THE TWO KINDS DIFFER, since the asymmetry looks arbitrary until it is
# stated: a `technology` label IS the answer to "what is this row" — "Java",
# "Python", "Shell script" name themselves and nothing else in this hub is
# called that. A `pm-backend` label is the name of an external service, and
# "GitHub" on a line of its own says nothing about which of the several GitHub
# things the hub touches (the backend, the CLI, the auth account) it means.
# Before this predicate the group label carried a literal " backend" suffix to
# close that gap, which meant every screen that DID show a "Project Management"
# heading printed the domain twice ("Project Management / GitHub backend") and
# one screen — Install's own sub-selection, already titled "select backend(s)" —
# had to strip the suffix back off. Qualifying at the two context-free surfaces
# instead of suffixing at all of them inverts that default: the bare label is
# now correct everywhere a heading is visible, and only the two screens with no
# heading pay for the disambiguation.
#
# RETURNS A STATUS rather than printing, because every caller is a test, and it
# deliberately does NOT die on an unknown kind — unlike its four closed-lookup
# neighbours above. "Does a row of this kind need its domain spelled out" has an
# honest answer for a non-selectable group (whose selkind column is legitimately
# EMPTY): no. Dying would make hub_group_label_in_context, which asks this of
# whatever group it is handed, usable on selectable groups only. Same reasoning
# hub_domain_is_registered states for its own non-dying shape.
hub_selection_kind_needs_domain() {
	case $1 in
	pm-backend) return 0 ;;
	esac
	return 1
}

# ---------------------------------------------------------------------------
# 2c. The path-shape predicate — "which family of units is this".
# ---------------------------------------------------------------------------

# hub_src_in_dir SRC DIR -> exit 0 when SRC lies inside a directory named DIR,
# i.e. when the path contains "/DIR/". THE test that makes every classification
# in this hub a path SHAPE rather than a name list: a lens reviewer is a unit
# under HUB_SD_DIR_LENS_REVIEWERS, a per-technology standard is one under
# HUB_SD_DIR_SHARED_TECH_STANDARDS, and neither fact needs a single item name.
#
# A literal SUBSTRING test on "/DIR/", never a regex and never an anchored
# prefix:
#   * a regex would let a directory constant containing a metacharacter change
#     what matches — the same rule lib/hub-discovery.sh's display pass already
#     states for its own copy of this test. The glob is QUOTED ("*\"/$2/\"*") for
#     exactly that reason: an unquoted $2 would be re-globbed by `case` itself.
#   * an anchored test would need the framework root, which most callers do not
#     hold, and DIR is a multi-segment shape ("agents/reviewers/lens") already
#     specific enough that an accidental match within a domain's own structure is
#     not a real risk.
#
# THE ONE REAL FALSE-MATCH VECTOR, stated because the paragraph above is about
# the DOMAIN subtree and does not cover it: SRC is a full path, so the matched
# segment sequence may also occur in the FRAMEWORK SOURCE ROOT's own prefix. A
# `--source /x/agents/reviewers/lens/some-repo` makes every unit under that
# source match DIR="agents/reviewers/lens" regardless of which domain it is in,
# because the test is unanchored by design. This is a pre-existing property of
# every spelling of this test (see the count below), not something this function
# introduced; it is disclosed here because this is now the canonical documented
# version. Anchoring it would mean threading the framework root through every
# caller, which is the cost the second bullet above declines to pay.
#
# THE TWO SPELLINGS THAT EXIST TODAY. This is the canonical shell one; the other is
#   * lib/hub-discovery.sh's awk `in_dir` — STAYS INDEPENDENT ON PURPOSE. Its
#     display pass opens every candidate itself and must remain a single awk
#     process for the whole tree (see that file's PERFORMANCE note), so it cannot
#     invoke a shell function at all:
#
#         function in_dir(src, dir) { return index(src, "/" dir "/") > 0 }
#
# There were FIVE. Three went: hub-list.sh's two awk copies (hl_lens_rows_build,
# hl_baseline_summary) and hub-install.sh's inline `case $src in *"/$dir/"*)`
# in/out arms, all of which now filter hub_domain_buckets' `bucket` column
# instead — which is what this note said they should do.
#
# `case` with a "*/DIR/*" glob and awk's index() ask the identical question:
# does the literal string "/DIR/" occur anywhere in SRC. A NEW caller must grow
# no third spelling — it consumes hub_domain_buckets' `bucket` column, or calls
# this function. There are two callers that legitimately cannot use that column and
# so call this directly: hub-install.sh's Result screen (it reports what one apply
# run WROTE, which a projection of the pre-apply state cannot express), and
# hub_domain_feature_of below plus lib/hub-state.sh's hub_domain_feature_rows (a
# feature is a SUBSET of a group's units, which that table has no column for).
hub_src_in_dir() {
	case $1 in
	*"/$2/"*) return 0 ;;
	esac
	return 1
}

# ---------------------------------------------------------------------------
# 3. Software Development's structural rules.
# ---------------------------------------------------------------------------

# HUB_SD_TECH_AGENT_SUFFIXES — the suffixes a developer-agent filename may end
# with, longest-first. A technology KEY is the developer agent's basename with
# one of these stripped. Two suffixes exist because one agent in the framework
# is named "-engineer" rather than "-developer"; this is a PATTERN, so a future
# "-architect" would be one entry here, never a name list.
HUB_SD_TECH_AGENT_SUFFIXES='-developer -engineer'

# hub_sd_tech_key BASENAME -> the technology key for a developer agent's
# basename (no .md), i.e. the basename with its role suffix stripped. Prints
# nothing and returns 1 when BASENAME carries no recognized suffix — a file
# under agents/developers/ that is not a developer agent is skipped, never
# silently treated as a technology named after itself.
#
# THE DERIVED KEY IS CHARSET-VALIDATED, against the same HUB_NAME_CHARSET_RE a
# unit NAME is gated by, and it also returns 1 (prints nothing) on a mismatch —
# the same skip, reported by the caller's own warning.
#
# WHY A KEY NEEDS THE GATE AS MUCH AS A NAME DOES, stated because the two arrive
# from different places and only the name's gate was obvious: a unit name is read
# from YAML frontmatter and becomes a FILENAME under --target, which is what
# lib/hub-common.sh's charset note is written about. This key is read from a raw
# FILE BASENAME instead — nothing upstream constrains it — and it becomes a GROUP
# KEY (hub_group_key -> "tech:<key>"), which several call sites iterate through an
# UNQUOTED command substitution: hub-install.sh's hi_selection_rows and
# hi_domain_pending (`for g in $(hub_selectable_groups …)`), hub-uninstall.sh's
# SELECTABLE_ROWS build (`for g in $(hub_groups_of_role selectable)`), and
# hub_domain_detail in lib/hub-state.sh. A foreign --source holding
# `agents/developers/my tech-developer.md` therefore word-split ONE group into two
# bogus ones, and `*-developer.md` GLOBBED against the working directory — both
# silently, both on a path that then drives install and removal decisions. The
# unquoted `for` is the intended split of a one-key-per-line stream and stays; what
# was missing is the guarantee that a key contains no separator and no
# metacharacter, which is exactly what this charset already promises for a name.
#
# Validated HERE, at the ONE point the key is derived, so every consumer inherits
# the guarantee without repeating the check — the same choke-point argument
# lib/hub-discovery.sh's hub_disc_resolve_names makes for unit names. An empty key
# (a file named exactly `-developer.md`) falls out of the same test, since the
# charset requires a leading alphanumeric.
#
# grep -Eq against the shared constant, never an equivalent `case` glob: the
# charset has exactly ONE spelling in this hub (lib/hub-common.sh's
# HUB_NAME_CHARSET_RE), and a second, hand-translated one here is the drift this
# file's own conventions exist to prevent. It costs one fork per developer agent,
# at discovery time only.
hub_sd_tech_key() {
	for hstk_suffix in $HUB_SD_TECH_AGENT_SUFFIXES; do
		case $1 in
		*"$hstk_suffix")
			hstk_key=${1%"$hstk_suffix"}
			printf '%s' "$hstk_key" | grep -Eq "$HUB_NAME_CHARSET_RE" || return 1
			printf '%s\n' "$hstk_key"
			return 0
			;;
		esac
	done
	return 1
}

# The subtree names Software Development's structure uses. Path shapes, not
# item names. HUB_SD_DIR_SHARED_TECH_STANDARDS is DERIVED from its own parent
# rather than spelled independently, so the two can never disagree about where
# standards live.
HUB_SD_DIR_FLOWS='flows'
HUB_SD_DIR_SHARED='shared'
HUB_SD_DIR_SHARED_STANDARDS='shared/standards'
HUB_SD_DIR_SHARED_TECH_STANDARDS="$HUB_SD_DIR_SHARED_STANDARDS/tech"
HUB_SD_DIR_DEVELOPERS='agents/developers'
HUB_SD_DIR_TECH_REVIEWERS='agents/reviewers/tech'
HUB_SD_DIR_LENS_REVIEWERS='agents/reviewers/lens'
HUB_SD_DIR_SPECIALISTS='agents/specialists'

# The naming PATTERNS the display layer reads. These are not item names: each is
# a role suffix or a type-word prefix that classifies a whole family, and the
# display awk in lib/hub-discovery.sh receives them via -v rather than re-spelling
# them as its own literals — extending HUB_SD_TECH_AGENT_SUFFIXES used to change
# discovery while silently leaving display naming behind.
HUB_SD_TECH_REVIEWER_SUFFIX='-reviewer'
HUB_SD_LENS_AGENT_PREFIX='lens-'
HUB_STANDARD_SKILL_PREFIX='standard-'
HUB_PROCEDURE_SKILL_PREFIX='procedure-'

# hub_sd_tech_reviewer_path SRC KEY -> where a technology's reviewer agent
# would live. The caller tests existence; a technology with no reviewer
# counterpart is legitimate (a lone `tests-developer`-shaped agent pairs with
# the baseline lens reviewers, which need no per-technology handling because
# lenses are unconditional baseline).
hub_sd_tech_reviewer_path() {
	printf '%s/%s/%s%s.md' "$(hub_domain_root "$1" software-development)" \
		"$HUB_SD_DIR_TECH_REVIEWERS" "$2" "$HUB_SD_TECH_REVIEWER_SUFFIX"
}

# hub_sd_tech_standard_path SRC KEY -> where a technology's standard skill
# directory would live. The caller tests existence.
hub_sd_tech_standard_path() {
	printf '%s/%s/%s%s' "$(hub_domain_root "$1" software-development)" \
		"$HUB_SD_DIR_SHARED_TECH_STANDARDS" "$HUB_STANDARD_SKILL_PREFIX" "$2"
}

# ---------------------------------------------------------------------------
# 4. Project Management's structural rules.
# ---------------------------------------------------------------------------

HUB_PM_DIR_FLOWS='flows'

# The agents subtree and the per-agent skills subdirectory — both PATH SHAPES,
# neither an item name. These two replace an earlier pair of constants that
# spelled the literal segment `agents/project-manager`, which was the ONE place
# in the whole hub where an actual agent name was embedded in code: renaming the
# agent's directory silently emptied Project Management's baseline and all of its
# backends. Project Management's agents are now walked exactly the way Software
# Development's specialists are (agents/*/*.md, then each agent's own skills/),
# so a rename needs zero hub changes and the zero-hardcoded-names contract holds
# without an exception.
HUB_PM_DIR_AGENTS='agents'
HUB_PM_AGENT_SKILLS_SUBDIR='skills'

# HUB_PM_BACKEND_KEYS — the backends, in the order the selection screen shows
# them.
HUB_PM_BACKEND_KEYS='github jira'

# hub_pm_backend_hint KEY -> the backend row's "what it does" blurb (spec §4).
hub_pm_backend_hint() {
	case $1 in
	github) printf 'issues' ;;
	jira) printf 'tickets, workflow' ;;
	*) printf '' ;;
	esac
}

# hub_pm_backend_of SKILL_DIR_NAME -> which backend a project-manager skill
# belongs to (github | jira), or empty for a baseline skill.
#
# Classification is by TOKEN, not substring: the skill directory name is split
# on "-" and a token must match EXACTLY. A substring test would be actively
# wrong — "standard-backlog-artifacts" contains the letters "g","h" adjacently
# in no token, but a future "flow-oversight"/"standard-highlight" would contain
# a literal "gh" substring and be misclassified as a GitHub backend skill.
# Token matching is the pattern that actually expresses the intent.
#
# Jira is tested first, so a hypothetical name carrying both tokens resolves to
# Jira rather than to whichever test happened to run first. Stated explicitly
# because a silent precedence is exactly the kind of thing that rots.
hub_pm_backend_of() {
	hpbo_name=$1
	hpbo_rest=$hpbo_name
	hpbo_has_jira=0
	hpbo_has_github=0
	while [ -n "$hpbo_rest" ]; do
		case $hpbo_rest in
		*-*)
			hpbo_token=${hpbo_rest%%-*}
			hpbo_rest=${hpbo_rest#*-}
			;;
		*)
			hpbo_token=$hpbo_rest
			hpbo_rest=""
			;;
		esac
		case $hpbo_token in
		jira) hpbo_has_jira=1 ;;
		gh | github) hpbo_has_github=1 ;;
		esac
	done
	if [ "$hpbo_has_jira" -eq 1 ]; then
		printf 'jira\n'
	elif [ "$hpbo_has_github" -eq 1 ]; then
		printf 'github\n'
	else
		printf '\n'
	fi
}

# ---------------------------------------------------------------------------
# 4b. Getting Things Done's structural rules, plus the one thing no other domain
#     has: NAMED FEATURES inside its baseline.
# ---------------------------------------------------------------------------
#
# Two constants, for the two subtrees GTD's walk and its feature classifier
# need. HUB_GTD_DIR_AGENTS exists for the same reason Software Development's and
# Project Management's do: the agents/ segment was the last inline directory
# literal in a discovery walker, so the three domains now express the identical
# shape the identical way. HUB_GTD_DIR_FLOWS is the other half of that shape,
# and is what hub_domain_feature_of tests below.
HUB_GTD_DIR_AGENTS='agents'
HUB_GTD_DIR_FLOWS='flows'

# ===========================================================================
# DOMAIN FEATURES — why exactly one domain declares them, and no other should
# be given them to look consistent.
# ===========================================================================
# Every domain's baseline collapses to one anonymous "Framework baseline
# (N items)" line, because a baseline genuinely IS a miscellany: Software
# Development's is 36 units of flows, specialists and shared facades, and no
# reader can act on any one of them individually (the repair for all of them is
# re-selecting the domain). Naming them would be naming plumbing.
#
# GTD is the one domain where that is false. Its whole footprint is TWO
# capabilities a human recognizes and would ask for by name — capturing a
# thought into the inbox, and triaging the inbox afterwards — and hiding both
# behind "Framework baseline (3 items)" told the reader the domain has nothing
# nameable in it when it has exactly two things. A live test session asked what
# GTD actually installs and the screens could not answer.
#
# A FEATURE IS NOT A UNIT, and that is the whole point. "Inbox capture" is an
# AGENT (gtd-inbox-writer) plus the skill nested under it (procedure-inbox-
# capture): the agent is the executor for its own skill, so a row per unit would
# show implementation plumbing — two rows for one capability — while a row per
# feature shows the capability. "Inbox triage" happens to be one unit today
# (flow-inbox); it gets its own line because it is its own capability, not
# because of its unit count.
#
# FEATURES ARE PRESENTATION ONLY. They change no group, no unit, no install or
# removal atom, and no machine payload: HUB_UNITS, HUB_GROUPS, HUB_ROWS and
# every --format=env/json field still see GTD's three units and its one
# `baseline:gtd` group, exactly as before. A feature is a way of GROUPING those
# units on a human-facing line — the same kind of thing the collapsed baseline
# count already is, just named. In particular GTD remains atomic and remains
# unreachable by selective uninstall (its selection kind is `none`; see
# hub_domain_selection_kind), which is precisely what hub_domain_feature_hint
# below exists to say out loud.
#
# WHY THIS IS A REGISTRY ENTRY AND NOT A GENERIC MECHANISM: the labels cannot be
# derived. "flow-inbox" sentence-cases to "Flow inbox", never to "Inbox
# triage" — a feature's name is editorial, in exactly the way
# hub_domain_label's own labels are (see its header on why "Software
# Development" is not derived from its key either). What IS derived is
# MEMBERSHIP: which units belong to which feature is a path-shape test, so
# adding, renaming or removing a unit inside GTD still needs no change here.

# HUB_GTD_FEATURE_KEYS — GTD's features, in the order every screen renders them.
HUB_GTD_FEATURE_KEYS='capture triage'

# HUB_FEATURE_RESIDUAL_KEY — the key a domain's baseline unit gets when NO
# declared feature claims it. Spelled with parentheses so it can never collide
# with a real feature key (HUB_NAME_CHARSET_RE admits neither character), and it
# is deliberately a value rather than the empty string: the classification table
# it lands in is filtered by an exact awk field comparison, and an empty key
# there would be indistinguishable from a malformed row.
#
# A residual unit is NOT an error and is never dropped: it folds into the same
# collapsed "Framework baseline (N items)" line every other domain's baseline
# gets, which is exactly the presentation GTD's units had before features
# existed. That is what keeps the classifier TOTAL — a unit added to GTD outside
# both of its two subtrees degrades to the previous behavior instead of
# vanishing from a screen or being filed under a feature it is not part of.
HUB_FEATURE_RESIDUAL_KEY='(residual)'

# HUB_BASELINE_LABEL — what an ANONYMOUS baseline remainder is called, on every
# screen that renders one: hub-list.sh's collapsed line, hub-doctor.sh's diverged
# report, hub-install.sh's receipt, and the RESIDUAL of a featured domain on all
# three.
#
# BESIDE THE RESIDUAL KEY because it is the other half of the same registry fact:
# HUB_FEATURE_RESIDUAL_KEY names the bucket an unclaimed baseline unit lands in,
# this names the line that bucket renders as. It used to be a named constant on
# List (HL_BASELINE_LABEL) and a raw printf literal on the other two screens, each
# carrying a comment asserting that its wording matched the other two — a
# convention enforced by prose in three places, which is how three spellings of one
# label drift apart. One constant enforces it by construction.
#
# NOT a lookup and not per-domain: there is exactly one answer for every domain
# (see the DOMAIN FEATURES note above on why a baseline genuinely is a miscellany).
# The "(N items)" annotation stays each screen's own, since only the screen knows
# what it is counting there.
HUB_BASELINE_LABEL='Framework baseline'

# hub_domain_feature_keys DOMAIN -> DOMAIN's feature keys as shell words, or
# nothing at all for a domain that declares none.
#
# EMPTY OUTPUT IS THE "no features" ANSWER, and this deliberately does not die on
# an unknown key: every consumer asks it of whichever domain it is currently
# rendering, and two of them (hub-doctor.sh's diverged walk, which is driven by
# a row's own domain column) can legitimately ask about the cross-domain
# placeholder. "Does this domain declare features" has an honest `none` answer
# for anything that is not GTD. Same non-dying shape, for the same reason, as
# hub_domain_is_registered and hub_selection_kind_needs_domain.
hub_domain_feature_keys() {
	case $1 in
	gtd) printf '%s' "$HUB_GTD_FEATURE_KEYS" ;;
	esac
}

# hub_domain_feature_label DOMAIN KEY -> the feature's human-facing name.
#
# A closed lookup that DIES on an unknown pair, like hub_domain_label and every
# other label lookup in this file: every caller reaches it with a key that came
# out of hub_domain_feature_keys, so an unknown pair means the registry
# contradicts itself, and an empty label would put a nameless row on a screen.
hub_domain_feature_label() {
	case $1 in
	gtd)
		case $2 in
		capture) printf 'Inbox capture' ;;
		triage) printf 'Inbox triage' ;;
		*) die "hub_domain_feature_label: domain '$1' has no feature '$2'" ;;
		esac
		;;
	*) die "hub_domain_feature_label: domain '$1' declares no features" ;;
	esac
}

# hub_domain_feature_of DOMAIN SRC -> which of DOMAIN's features the unit at SRC
# belongs to, or nothing when no feature claims it (see
# HUB_FEATURE_RESIDUAL_KEY on what happens then).
#
# PATH SHAPE ONLY, never a unit name, so GTD's units can be renamed, split or
# added to freely:
#   <domain>/flows/**    -> triage — the inbox flow IS the triage capability.
#   <domain>/agents/**   -> capture — the writer agent and every skill nested
#                           beneath it are one capability; the agent is the
#                           executor for its own skill, which is why they share
#                           a line rather than getting one each.
#
# PRECEDENCE: flows/ IS TESTED FIRST, so a path lying inside both subtrees (a flow
# nested somewhere under agents/) resolves to `triage` rather than to whichever arm
# happened to run first. Stated for the same reason hub_pm_backend_of states its own
# Jira-first precedence a few functions above: with two independent path tests and
# one answer, a silent precedence is exactly the kind of thing that rots.
#
# BOTH TESTS ARE POSITIVE, with no catch-all arm, and that is the choice that
# makes the classifier safe rather than merely total: an unrecognized shape
# falls through to the residual (the anonymous baseline line) instead of being
# absorbed into whichever feature the last arm happened to name. Absorbing it
# would put a unit under a capability it is not part of, and say so with
# confidence on a consent screen.
#
# hub_src_in_dir is the canonical spelling of the "is this path inside a
# directory named X" test (see its own header, which asks a new caller to either
# consume hub_domain_buckets' bucket column or call it — a feature is neither a
# bucket nor derivable from one, so this calls it).
hub_domain_feature_of() {
	case $1 in
	gtd)
		if hub_src_in_dir "$2" "$HUB_GTD_DIR_FLOWS"; then
			printf 'triage'
		elif hub_src_in_dir "$2" "$HUB_GTD_DIR_AGENTS"; then
			printf 'capture'
		fi
		;;
	esac
}

# hub_domain_feature_hint DOMAIN -> the one-line advisory a screen prints under
# DOMAIN's feature lines, or nothing for a domain with no features.
#
# WHY THE HINT EXISTS AT ALL: naming two features invites the reader to assume
# they can pick one. They cannot — GTD's selection kind is `none`, so both
# features arrive and leave together and neither is ever a checkbox
# (hub_domain_selection_kind's own note on what `none` costs). The hint is the
# only place a screen says that, and it is why splitting one line into two is
# not a promise of finer control.
#
# It is rendered DIMMED by every screen that shows it, and Doctor deliberately
# does NOT show it: a health report states facts about what is broken and
# carries no selection advice anywhere else either.
hub_domain_feature_hint() {
	case $1 in
	gtd) printf 'installs & uninstalls together' ;;
	esac
}

# ---------------------------------------------------------------------------
# 5. The cross-domain rule — exactly one shared unit exists today.
# ---------------------------------------------------------------------------

HUB_ACCOUNTS_DIR='accounts'

# HUB_SHARED_GIT_AUTH_GROUP — the group key for the shared GitHub-auth
# procedure. Its UNIT is discovered from the filesystem (whatever skill lives
# under accounts/), so renaming that skill needs no change here; only the
# group key and its consumer list are encoded.
HUB_SHARED_GIT_AUTH_GROUP=$(hub_group_key "$HUB_GROUP_PREFIX_SHARED" git-auth)

# hub_shared_consumers GROUP -> one "consumer-group<TAB>annotation" line per
# group that structurally requires this shared group. The annotation is the
# "required by:" text the install preview prints (spec §6).
#
# Both consumers are structural facts, not per-item lookups:
#   * Software Development's baseline always needs GitHub auth, because the
#     git-operator specialist it always installs performs push/PR operations.
#   * Project Management's GitHub backend always needs GitHub auth, because a
#     GitHub backend inherently does.
# There is no Jira equivalent: Jira's own auth procedure lives INSIDE Project
# Management's Jira backend, not under accounts/, because only the
# project-manager agent uses it.
#
# THE BACKEND CONSUMER NAMES ITSELF THROUGH hub_group_label_in_context, not through
# a hand-written "Project Management (GitHub backend)". Every surface this
# annotation reaches is heading-less (hub-accounts.sh's "used by:" line,
# hub-install.sh's "required by:" block, hub-uninstall.sh's "Kept" note), which is
# precisely the condition that function exists for — and the hand-written string had
# drifted: the group label itself is BARE now ("GitHub"), so the accounts screen
# showed "Project Management (GitHub backend)" four lines above its own freshly-bare
# "Project Management (Jira)", two spellings of one concept on one screen.
#
# EVERY accessor result is assigned before it is used, never inlined as a printf
# argument: hub_domain_label dies on a key outside its closed set and
# hub_group_label_in_context dies (via hub_discovery_require) on an unbuilt
# discovery, and a die inside a command substitution used as an ARGUMENT is
# swallowed — printf still succeeds and the annotation loses its subject, on lines
# that tell a user which installed thing still needs an auth procedure.
hub_shared_consumers() {
	case $1 in
	"$HUB_SHARED_GIT_AUTH_GROUP")
		hshc_sd_group=$(hub_group_key "$HUB_GROUP_PREFIX_BASELINE" software-development)
		hshc_sd_label=$(hub_domain_label software-development)
		printf '%s\t%s (git operator, baseline)\n' "$hshc_sd_group" "$hshc_sd_label"
		hshc_pm_group=$(hub_group_key "$HUB_GROUP_PREFIX_PM_BACKEND" github)
		hshc_pm_label=$(hub_group_label_in_context "$hshc_pm_group")
		# A source shipping NO GitHub backend has no group row to name, so the
		# qualified form comes back empty; the domain alone is then the honest subject
		# — never an empty annotation, which would render as a bare comma on the
		# "used by:" line.
		#
		# An `if`, never `[ -n … ] || hshc_pm_label=$(…)`: an assignment on the right of
		# `||` is exempt from `set -e`, which would swallow a die inside the substitution
		# and leave the annotation empty — the very thing this fallback exists to prevent.
		if [ -z "$hshc_pm_label" ]; then
			hshc_pm_label=$(hub_domain_label project-management)
		fi
		printf '%s\t%s\n' "$hshc_pm_group" "$hshc_pm_label"
		;;
	*) die "hub_shared_consumers: unknown shared group '$1'" ;;
	esac
}

# ---------------------------------------------------------------------------
# 6. The first-run bundle (CLAUDE.md + the contract schemas).
# ---------------------------------------------------------------------------
#
# CLAUDE.md and every */contracts/*.schema.json install together, first-run
# only, and are NOT part of any domain's baseline count — they are the
# framework's own operating contract and data schemas, not a domain's
# capability. The gate is CLAUDE.md's OWN symlink state (see
# lib/hub-bundle.sh's hub_bundle_state): under the previous tier model this
# was keyed off a whole curated "core tier" being fully linked; with no core
# tier left, CLAUDE.md is the single, self-evident marker of "has this hub
# ever bootstrapped this target".

HUB_BUNDLE_CONFIG_NAME='CLAUDE.md'
HUB_BUNDLE_CONTRACTS_SUBDIR='crucible/contracts'
