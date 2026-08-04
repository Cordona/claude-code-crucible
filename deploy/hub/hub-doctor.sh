#!/usr/bin/env sh
# hub-doctor.sh — Capability: Doctor. Required tools, diverged components and
#                  Accounts — plus a summary and next steps scoped to only
#                  those things.
#
# Doctor deliberately does NOT list installed-and-healthy components — List
# owns "what is installed", Doctor owns "can the environment actually run it".
# Divergence (installed, but the linked copy no longer matches source) is a
# health fact under that same charter, which is why it gets its own section
# here too, even though List and Uninstall also report it from their own
# angle (what to add back, what to remove). ORPHANING — a link this hub placed
# whose source is gone — is the same charter's other half and gets its own section
# for the same reason: lib/hub-state.sh defines the two as peer target states, and
# an orphan is the strictly worse of them (a diverged link still resolves to
# something; a dangling one resolves to nothing).
#
# The DEFINITION of "diverged" is derived once, per unit, by lib/hub-state.sh; what
# differs between screens is only the granularity each PROJECTS it at. Doctor and
# List's payload read hub_rows_build/HUB_ROWS as-is, because this section has to be
# able to name "Security review lens" specifically. Uninstall's CHECKLIST marks
# divergence from its own coarser SELECTABLE_ROWS projection instead — a human picks
# a technology, not a lens — so it is a second projection of the same states, never
# a second derivation of what "diverged" means. See the in-body note at the
# diverged-components section below.
#
# Doctor's own TEXT screen then groups and partly collapses those per-unit rows for
# readability, while --format=env/json keep emitting them flat and per-unit. That
# split is deliberate and is stated in full at the rendering section below: the
# machine payload is a contract, the human screen is a presentation.
#
# Usage:
#   hub-doctor.sh [--target DIR] [--source DIR] [--format=text|env|json]
#                 [--no-color] [-h|--help]
#
# A finding is a PROBLEM when something installed cannot work, and a NOTE when
# it only matters for something not installed (yet). "Jira not authenticated" on
# a machine with no Jira backend is a note; the same line with the Jira backend
# installed is a problem. Reporting both at the same severity would train the
# reader to ignore the screen.
#
# NOTE on the required-tools table: it lives in lib/hub-tools.sh rather than
# being scraped out of another script's human-facing diagnostics. That text is
# documented as human-facing, not a machine contract, so parsing it would be a
# brittle inter-process text dependency. Doctor is its SOLE consumer today (the
# Main-menu banner that was the second one is gone), and it stays in a lib because
# it is the framework's definition of "required": the next surface that needs that
# fact must read this table rather than grow a second, drifting copy of it.
#
# Exit codes: 0 on a normal report (Doctor's own diagnostics never fail the
#   run); 1 on an unresolvable --source or a missing jq dependency for
#   --format=json; 2 on a usage error; 3 if the user quits from the
#   interactive pause.
#
# Portability: POSIX sh only. jq is required ONLY for --format=json.
set -eu

HUB_PROG="crucible-hub doctor"
HUB_DIR0=$(dirname "$0")
. "$HUB_DIR0/lib/hub-common.sh"
. "$HUB_DIR0/lib/hub-domains.sh"
. "$HUB_DIR0/lib/hub-render.sh"
. "$HUB_DIR0/lib/hub-nav.sh"
. "$HUB_DIR0/lib/hub-tools.sh"
. "$HUB_DIR0/lib/hub-discovery.sh"
. "$HUB_DIR0/lib/hub-state.sh"

hub_workspace_init

usage() {
	cat <<EOF
Usage: $HUB_PROG [--target DIR] [--source DIR] [--format=text|env|json] [--no-color] [-h|--help]

Required tools and account health for this environment.

Options:
  --target DIR   Deployed config dir to inspect (default: \$HOME/.claude).
  --source DIR   Framework root to scan (default: the hub's own tree).
  --format FMT   text (default) | env | json.
  --no-color     Disable ANSI color.
  -h, --help     Show this help.
EOF
}

OPT_TARGET=""
OPT_SOURCE=""
OPT_FORMAT=text
HUB_NO_COLOR=${HUB_NO_COLOR:-0}

while [ $# -gt 0 ]; do
	if hub_try_common_opt "$1" "${2:-}" "$#"; then
		shift "$HUB_COMMON_OPT_SHIFT"
		continue
	fi
	case $1 in
	-h | --help)
		usage
		exit 0
		;;
	*) die_usage "unknown argument: $1" ;;
	esac
done

hub_validate_format text env json

[ -n "$OPT_TARGET" ] || OPT_TARGET=$(hub_default_target)
[ -n "$OPT_SOURCE" ] || OPT_SOURCE=$(hub_default_source)
TARGET_DIR=$(hub_abspath "$OPT_TARGET")
FRAMEWORK_ROOT=$(hub_realpath "$OPT_SOURCE") || die "cannot resolve --source: $OPT_SOURCE"

# ---------------------------------------------------------------------------
# Required tools — the table itself lives in lib/hub-tools.sh; this script only
# renders and judges it, and is its only consumer.
# ---------------------------------------------------------------------------
TOOLS="$HUB_WORK/tools.tsv"
hub_tools_build "$TOOLS"

# ---------------------------------------------------------------------------
# Accounts — delegated, never reimplemented.
#
# Reporting an account state means RUNNING a discovered auth-status script, so
# hub-accounts.sh gates that execution on the --source being this hub's own
# framework tree (its header states the rule in full). Doctor inherits the gate
# rather than restating it: on the default source the two scripts run exactly as
# before, and on a foreign --source they are skipped here — both of Doctor's calls
# redirect stdout, so hub_is_tty is false in the child and it can never stop to
# prompt inside a diagnostic. HUB_GH_STATE_KNOWN / HUB_JIRA_STATE_KNOWN report
# which of the two happened, so Doctor can say "not checked" instead of inventing
# "not authenticated".
# ---------------------------------------------------------------------------
ACCOUNTS_ENV="$HUB_WORK/accounts.env"
"$HUB_DIR0/hub-accounts.sh" status \
	--source "$FRAMEWORK_ROOT" --target "$TARGET_DIR" --format=env >"$ACCOUNTS_ENV" 2>/dev/null || :

# Only the fields Doctor's own JUDGEMENT depends on are read here (via
# lib/hub-common.sh's hub_env_field — one implementation, with the rationale for
# why the naive grep|sed pipeline does not work, shared with hub-accounts.sh
# rather than copied into it). The account NAMES and hosts are deliberately not:
# the Accounts block below is rendered by delegating to hub-accounts.sh's own text
# output, so re-reading those values here would be a second, drift-prone copy of a
# display this script does not own.
GH_INSTALLED=$(hub_env_field "$ACCOUNTS_ENV" HUB_GH_INSTALLED false)
GH_AUTHENTICATED=$(hub_env_field "$ACCOUNTS_ENV" HUB_GH_AUTHENTICATED false)
GH_STATE_KNOWN=$(hub_env_field "$ACCOUNTS_ENV" HUB_GH_STATE_KNOWN false)
JIRA_CONFIGURED=$(hub_env_field "$ACCOUNTS_ENV" HUB_JIRA_CONFIGURED false)
JIRA_STATE_KNOWN=$(hub_env_field "$ACCOUNTS_ENV" HUB_JIRA_STATE_KNOWN false)
JIRA_BACKEND_INSTALLED=$(hub_env_field "$ACCOUNTS_ENV" HUB_JIRA_BACKEND_INSTALLED false)

# Whether anything that needs GitHub auth is actually installed, answered by the
# same cross-domain consumer rule the installer uses — not a second list.
hub_discovery_build "$FRAMEWORK_ROOT"
hub_states_build "$TARGET_DIR"

# ---------------------------------------------------------------------------
# Diverged components — a live test session made the case that divergence
# ("installed, but the linked copy no longer matches source") is exactly a
# health-check fact, not just a List/Status footnote: a diverged component may
# not run the way its source now expects. hub_rows_build/HUB_ROWS is List's own
# table, reused as-is (never re-derived) so this can never drift from what List
# calls diverged — and PER-UNIT granularity is the point here: this section has
# to be able to name "Security review lens" specifically, not the bundle it sits
# in. (Uninstall reads HUB_ROWS too, for --components' per-unit vocabulary and
# --all, but its CHECKLIST is a coarser, technology-level projection of its own —
# see its SELECTABLE_ROWS. The two granularities are deliberate.)
# ---------------------------------------------------------------------------
hub_rows_build
DIVERGED_ROWS="$HUB_WORK/diverged-rows.tsv"
awk -F '\t' '$4 == "DIVERGED"' "$HUB_ROWS" >"$DIVERGED_ROWS"
DIVERGED_ITEMS="$HUB_WORK/diverged-items.txt"
awk -F '\t' '{ print $3 }' "$DIVERGED_ROWS" >"$DIVERGED_ITEMS"
DIVERGED_COUNT=$(hub_count_lines "$DIVERGED_ITEMS")

# ---------------------------------------------------------------------------
# Orphaned components — the other half of the same charter, and it was missing.
#
# lib/hub-state.sh defines ORPHANED as a PEER of DIVERGED: a symlink this hub
# placed whose source has since been deleted or renamed. List surfaces it (its own
# fourth status group plus its env/json payload) and Uninstall offers it for
# removal, but Doctor — whose whole charter is "can the environment actually run
# it" — reported only divergence. A DANGLING link is the strictly worse of the two
# facts: a diverged component still resolves to something, an orphan resolves to
# nothing at all, so anything that loads it fails outright. A health screen that
# reports the recoverable case and silently omits the broken one inverts its own
# severity ordering.
#
# hub_orphaned_units is the SAME primitive List and Uninstall call — never a second
# scan of the target — so the three screens cannot disagree about what is orphaned.
# It requires discovery (the whole test is "this name appears nowhere in
# discovery"), which is why this sits after hub_discovery_build above.
#
# NOTHING TO COLLAPSE, and that is structural rather than an exemption from the
# conventions the diverged section follows: an orphan has no group and no domain by
# definition — a name that no longer appears in discovery cannot be attributed to a
# technology or a baseline — so there is no group label to collapse to and no
# domain sub-header to render under. The rendered lines are therefore flat, at the
# same depth the diverged section's own items sit at, which is also exactly how
# List renders its Orphaned group.
#
# DELIBERATELY NOT ADDED TO PROBLEMS/NOTES: HUB_PROBLEM_* / HUB_NOTE_* /
# HUB_STEP_* and their json counterparts are a published closed payload, and
# folding orphans into them would silently change every existing caller's counts.
# The finding is reported on the TEXT screen only, exactly as the diverged
# section's own grouping is text-only; an agent already reads orphans from List's
# payload, which reports them per unit. Giving Doctor's own payload an
# HUB_ORPHANED_COUNT field is a contract ADDITION and belongs in its own change.
# ---------------------------------------------------------------------------
HD_ORPHANS="$HUB_WORK/orphans.tsv"
hub_orphaned_units "$TARGET_DIR" >"$HD_ORPHANS"
HD_ORPHAN_COUNT=$(hub_count_lines "$HD_ORPHANS")

# ---------------------------------------------------------------------------
# Diverged components — the TEXT projection, and ONLY the text projection.
#
# DIVERGED_ITEMS above is the machine contract (HUB_DIVERGED_COUNT /
# HUB_DIVERGED_N_NAME, and json's diverged[]): flat, per unit, unchanged by
# anything below. Everything in this block runs inside the `text` branch and
# reshapes the SAME rows for a human, the same split hub-list.sh already draws
# between its per-unit payload and its grouped screen.
#
# WHAT "UNCHANGED" COVERS — the FIELDS, not every VALUE. The field set is the closed
# contract (adding one is an addition, removing or renaming one is a break), and
# HUB_DIVERGED_<N>_NAME / diverged[] are DISPLAY-VALUED: they carry a unit's
# human-facing name, which is presentation and may be reworded without notice, just
# as the text lines below may. A caller that must recognize a specific component
# should match on the identity fields hub-list.sh's payload publishes (key, group),
# never on display text — see that file's own "Output (env/json)" note, which states
# the same rule for the same reason.
#
# WHY: the flat per-unit list stopped being readable the moment a change touched
# more than one thing. Every technology contributed three lines of its own
# ("Python agent developer", "Python agent reviewer", "Python standard") with no
# domain structure, so a seven-unit report read as seven unrelated failures
# rather than as "two technologies and one lens" — and the repair for all three
# lines of a technology is the SAME single re-selection.
#
# Four rules, all derived from the group table, the registry and path SHAPE, never
# from a name list — so adding, removing or renaming any artifact still needs zero
# changes here:
#   1. rows are grouped under a DOMAIN sub-header (hub-list.sh's convention).
#   2. a unit of a domain that declares NAMED FEATURES is reported under its
#      feature's name (see hd_diverged_classify, which is reached BEFORE rule 3 for
#      such a domain whatever its group's role).
#   3. a SELECTABLE group (a technology, a backend) collapses to ONE line at the
#      group's own label, because the group is exactly what the human re-selects
#      to repair it. Its state comes from hub_group_display_state — the shared
#      owner of the `partial -> DIVERGED` mapping — rather than being inferred
#      here from "one of its units happened to be diverged".
#   4. a LENS reviewer stays itemized by name (individually nameable, exactly as
#      hub-list.sh treats it), and so does the cross-domain shared unit; the
#      remaining baseline plumbing collapses to a count, but only from TWO up,
#      since naming one costs the same line as counting it.
#
# DOCTOR STILL READS HUB_ROWS, and switching it to hub_domain_buckets would be
# wrong even though the rules above resemble that table's buckets. Two
# reasons, neither of them cosmetic: a bucket stream is PER DOMAIN, and it
# deliberately excludes the cross-domain shared group (see its own header) — so
# the domain loop it forces would silently drop a diverged auth procedure, which
# is exactly the class of health fact this screen exists to report; and it emits a
# `standard` row per technology standard, which rule 2 folds back into its
# technology anyway. lib/hub-state.sh's "DOCTOR IS NOT A BUCKET CONSUMER" names
# hub_group_display_state and hub_src_in_dir over HUB_ROWS-derived data as the
# primitives to reach for if this presentation were ever refactored; that is
# precisely what this block does.
# ---------------------------------------------------------------------------
HD_DIVERGED_PLAN="$HUB_WORK/diverged-plan.tsv"
HD_DIVERGED_TEXT="$HUB_WORK/diverged-text.txt"
HD_DIVERGED_PENDING="$HUB_WORK/diverged-baseline-pending.txt"
HD_DIVERGED_FEATURES="$HUB_WORK/diverged-feature-pending.txt"
HD_FEATURE_COUNTS="$HUB_WORK/diverged-feature-counts.tsv"

# The two tails an item line can carry. Spelled once each: three call sites emit
# an item, and a per-site copy is how the singular and the plural drift apart.
HD_TAIL_SINGULAR='installed copy no longer matches source'
HD_TAIL_PLURAL='installed copies no longer match source'

# hd_diverged_plan_build OUTFILE -> one
# "role<TAB>domain<TAB>group<TAB>text<TAB>src" line per DIVERGED row, in
# HUB_ROWS' canonical order, where text is the group's own label for a selectable
# row and the unit's own display for every other row.
#
# ONE awk over three tables rather than a hub_group_field call per row: the group
# facts (role, domain, label) live in HUB_GROUPS, and the unit's src — which only
# the lens test needs, and which HUB_ROWS deliberately does not carry — lives in
# HUB_STATES. Neither table may be read with `read` (both have legitimately empty
# middle columns; see lib/hub-common.sh's "THE TAB TRAP"), which is why the join
# is awk's and only this function's OUTPUT is shaped for `read`.
#
# The phase test is FILENAME == ARGV[n], never FNR == NR: with three inputs the
# NR trick cannot name the middle file at all, and an empty first file would make
# the second file's first record satisfy it anyway — the same trap
# lib/hub-discovery.sh states for its own two-file joins.
#
# COLUMN ORDER, per "THE TAB TRAP": role, domain and group are hub-generated
# words that can never be empty — and the two fallbacks below are what make that
# true rather than merely likely. A group missing from HUB_GROUPS is structurally
# impossible (both tables come from the same discovery), but a lookup miss must
# not silently DROP a diverged component from a health report, and an empty
# leading column would collapse the whole row under `read`. text is given the
# same treatment (a group label can be empty in the `-developer.md` edge case
# lib/hub-state.sh documents), which leaves src — empty for an atomic row, which
# stands for a group rather than for one unit — as the only nullable column, and
# therefore last.
hd_diverged_plan_build() {
	awk -F '\t' -v OFS='\t' '
		FILENAME == ARGV[1] { role[$1] = $4; domain[$1] = $3; label[$1] = $2; next }
		FILENAME == ARGV[2] { src[$2] = $4; next }
		{
			g = $2
			r = role[g]; d = domain[g]
			if (r == "") r = "unclassified"
			if (d == "") d = g
			text = (r == "selectable") ? label[g] : $3
			if (text == "") text = g
			print r, d, g, text, src[$1]
		}
	' "$HUB_GROUPS" "$HUB_STATES" "$DIVERGED_ROWS" >"$1"
}

# hd_diverged_classify OUTFILE DOMAIN SRC TEXT -> file ONE diverged unit of a
# domain's own content: emitted immediately when it is a lens reviewer, held back
# under its FEATURE's key when a feature claims it, held back for the anonymous count
# otherwise. Both held-back sets are emitted later by hd_diverged_flush_pending.
#
# TWO CALLERS, and extracting it is what lets them share one classification: a
# `baseline` row, and any row of a domain that declares FEATURES (whatever its role —
# a domain that is its own single selectable group has no baseline row at all). Before
# this was a function the classification lived inside the `baseline` case arm, so the
# second caller could only have had a copy of it.
#
# THE LENS TEST RUNS FIRST, BEFORE the feature classification, and the order is
# load-bearing rather than stylistic — it is the order lib/hub-state.sh's
# hub_domain_feature_rows applies for the same reason. hub_domain_feature_of
# classifies by PATH SHAPE with positive tests, so a featured domain that ever grew a
# lens subtree would have its `agents/reviewers/lens/*` units claimed as a `capture`
# feature by an `agents/` test that ran first, and rule 4 above (a lens stays itemized
# by name) would silently stop applying to it. Unreachable today — GTD ships no lens
# subtree — and cheap to get right while both classifiers agree.
#
# A guard clause with a `return`, not an `elif` after the feature test: the two
# questions are not alternatives at the same level, one gates the other. (It was a
# `continue` while this was inline in the loop; a function cannot continue its
# caller's loop, and the caller now has nothing left to do after this returns anyway.)
hd_diverged_classify() {
	hd_dc_out=$1
	hd_dc_domain=$2
	hd_dc_src=$3
	hd_dc_text=$4
	if hub_src_in_dir "$hd_dc_src" "$HUB_SD_DIR_LENS_REVIEWERS"; then
		hd_diverged_emit "$hd_dc_out" "$hd_dc_text" "$HD_TAIL_SINGULAR"
		return 0
	fi
	# A unit belonging to one of its domain's NAMED FEATURES is reported under the
	# FEATURE's name — never its own, and never folded into the anonymous count. GTD's
	# three units are two capabilities, and "Inbox triage — installed copy no longer
	# matches source" is the actionable fact where "Framework baseline (1 item)" told
	# the reader only that something somewhere under a domain broke. Held back like the
	# plain baseline units and for the same reason: the collapse has to see all of a
	# domain's rows before it can name a feature exactly once.
	hd_dc_feature=$(hub_domain_feature_of "$hd_dc_domain" "$hd_dc_src")
	if [ -n "$hd_dc_feature" ]; then
		printf '%s\n' "$hd_dc_feature" >>"$HD_DIVERGED_FEATURES"
	else
		printf '%s\n' "$hd_dc_text" >>"$HD_DIVERGED_PENDING"
	fi
}

# hd_diverged_render OUTFILE -> the section body (domain sub-headers and item
# lines) into OUTFILE, and sets HD_DIVERGED_LINES to the number of ITEM lines
# written. That figure is what the section heading counts, deliberately instead
# of DIVERGED_COUNT: the heading counts what the reader can see, while
# DIVERGED_COUNT stays the unit-level figure the machine formats report.
hd_diverged_render() {
	hd_dr_out=$1
	: >"$hd_dr_out"
	: >"$HD_DIVERGED_PENDING"
	: >"$HD_DIVERGED_FEATURES"
	HD_DIVERGED_LINES=0
	HD_DIVERGED_HEADING=""
	HD_DIVERGED_HEADING_WRITTEN=1
	hd_dr_domain=""
	hd_dr_group=""
	hd_dr_first=1
	while IFS="$HUB_TAB" read -r hd_dr_role hd_dr_dom hd_dr_grp hd_dr_text hd_dr_src; do
		[ -n "$hd_dr_grp" ] || continue
		if [ "$hd_dr_first" -eq 1 ] || [ "$hd_dr_dom" != "$hd_dr_domain" ]; then
			# The domain's named features and its plain baseline units are held back
			# until its section ends, so their lines land under their OWN heading.
			# FLUSHED WITH hd_dr_domain, the OUTGOING domain — it is still the previous
			# value at this point, which is exactly whose pending rows are being
			# emitted. On the very first row it is the empty string, and the flush is a
			# no-op there because nothing has been held back yet.
			hd_diverged_flush_pending "$hd_dr_out" "$hd_dr_domain"
			HD_DIVERGED_HEADING=$(hd_domain_heading "$hd_dr_dom" "$hd_dr_grp")
			HD_DIVERGED_HEADING_WRITTEN=0
			hd_dr_first=0
			hd_dr_domain=$hd_dr_dom
			hd_dr_group=""
		fi
		# THE FEATURE TEST COMES BEFORE THE ROLE DISPATCH, and the order is what makes
		# a featured domain report the same way here as on every other screen. A domain
		# that is its own single selectable group (GTD) carries `role=selectable`, so
		# the `selectable` arm below would collapse all of its diverged units into ONE
		# line at the domain label — turning hd_diverged_flush_pending's whole feature
		# loop into dead code for the only domain that has features, and telling the
		# reader "something under GTD broke" where "Inbox triage" is the actionable
		# fact. Routed to the same classifier the `baseline` arm uses.
		hd_dr_features=$(hub_domain_feature_keys "$hd_dr_dom")
		if [ -n "$hd_dr_features" ]; then
			hd_diverged_classify "$hd_dr_out" "$hd_dr_dom" "$hd_dr_src" "$hd_dr_text"
			continue
		fi
		case $hd_dr_role in
		selectable)
			# A group's rows are contiguous in canonical order, so "same group as
			# the previous row" is all the collapse needs — no accumulator.
			[ "$hd_dr_grp" != "$hd_dr_group" ] || continue
			hd_dr_group=$hd_dr_grp
			# ASSIGNED, never inlined as the `[` word: hub_group_display_state wraps
			# hub_group_state, which calls hub_states_require and DIES when the states
			# table is unbuilt — and a die inside a command substitution used as an
			# ARGUMENT is swallowed. The substitution yields empty, `[ "" = DIVERGED ]`
			# is simply false, and every diverged technology silently vanishes from a
			# HEALTH report that still exits 0. Letting the exit status reach the shell
			# is the same hoisting lib/hub-state.sh's hub_rows_build and
			# hub_domain_buckets both state, and hub-install.sh's hi_shared_heading and
			# hi_result_domain_block both apply.
			hd_dr_gstate=$(hub_group_display_state "$hd_dr_grp")
			[ "$hd_dr_gstate" = DIVERGED ] || continue
			hd_diverged_emit "$hd_dr_out" "$hd_dr_text" "$HD_TAIL_SINGULAR"
			;;
		baseline) hd_diverged_classify "$hd_dr_out" "$hd_dr_dom" "$hd_dr_src" "$hd_dr_text" ;;
		# Everything else is named, never counted. Today that is the cross-domain
		# shared unit — one individually nameable thing (an auth procedure) rather
		# than plumbing — plus the plan's `unclassified` fallback, which lands here
		# precisely so a row whose group facts could not be read is still reported
		# by name instead of vanishing into a count.
		*) hd_diverged_emit "$hd_dr_out" "$hd_dr_text" "$HD_TAIL_SINGULAR" ;;
		esac
	done <"$HD_DIVERGED_PLAN"
	hd_diverged_flush_pending "$hd_dr_out" "$hd_dr_domain"
}

# hd_domain_heading DOMAIN GROUP -> the sub-header for one domain section.
#
# The registry owns the label for a real domain; a group that belongs to NO
# domain names itself from the group table instead (the cross-domain shared
# group, whose domain column is a placeholder hub_domain_label would rightly die
# on). This is why Doctor streams rows in canonical order instead of iterating
# HUB_DOMAIN_KEYS the way hub-list.sh does: that shape cannot render a
# cross-domain unit at all, and a diverged auth procedure is precisely the kind
# of health fact this screen exists to report. (hub-list.sh's text screen now
# renders such a group too, from its own direction — a trailing non-domain block
# after its HUB_DOMAIN_KEYS loop, headed by this same group label.)
#
# The registry-membership test is hub_domain_is_registered, the registry's own
# predicate, not a `for` loop over HUB_DOMAIN_KEYS spelled here: that loop was one
# of two ad hoc copies of a question lib/hub-domains.sh now owns (see its header).
hd_domain_heading() {
	if hub_domain_is_registered "$1"; then
		hub_domain_label "$1"
		return 0
	fi
	hd_dh_label=$(hub_group_field "$2" 2)
	printf '%s' "${hd_dh_label:-$1}"
}

# hd_diverged_flush_pending OUTFILE DOMAIN -> emits DOMAIN's held-back lines: one
# per NAMED FEATURE that has a diverged unit, then the collapsed line for whatever
# plain baseline units are left, then clears both.
#
# FEATURES FIRST, and in the REGISTRY's own order — lib/hub-state.sh's
# hub_feature_counts, the shared projection all three feature-aware screens now call,
# rather than a fourth hand-written copy of the same registry walk, awk counter and
# label hoist. It hands back "count<TAB>label" per feature this domain's diverged
# rows actually touched, and everything below is this screen's own rendering (the
# singular/plural tail, the glyph, the emit). Features outrank the anonymous count
# because a named capability is the actionable fact on a health report, and the
# reading order then matches List's and the install preview's.
#
# DOMAIN is passed in rather than read from a global because this is called at the
# point one domain's section ENDS, where the render loop's own domain variable still
# holds the outgoing domain — see its call site.
#
# NO ATOMICITY HINT HERE, unlike List and the install preview: this screen reports
# what is broken and carries no selection advice anywhere else either (see
# hub_domain_feature_hint's own note).
#
# ALWAYS COLLAPSED, INCLUDING AT ONE, and the single-unit case is deliberately NOT
# special-cased any more. It used to name that one unit ("a `1 baseline component`
# line costs exactly the line naming it would"), which is true about line economy
# and wrong about the rule: a baseline item's individual identity is surfaced
# NOWHERE in this hub's UI, in any state, on any screen — hub-install.sh's
# hi_bucket_reset states that convention in full and hub-list.sh implements it
# unconditionally, collapsing even a one-item baseline to "(1 item)". A health
# screen that alone names "Flow implementation" told the reader a name no other
# screen will ever repeat back to them, and named it for the one thing they cannot
# individually act on (the repair is re-selecting the whole domain either way).
#
# From two up the count was always the point — Software Development's baseline
# alone is 40+ units of flows, specialists and facades, and itemizing them buries
# the technologies and lenses above them in noise.
#
# THE LABEL is lib/hub-domains.sh's HUB_BASELINE_LABEL plus "(N items)", the same
# line hub-list.sh's collapsed baseline and hub-install.sh's hi_result_baseline_line
# both produce, replacing this screen's own "N baseline components". The wording used
# to be a literal here, on List and on Install, each asserting in a comment that it
# matched the other two; it is one registry constant now (see its own header). The
# three screens agreed on that wording for every domain but GTD, which List alone
# used to call "Inbox capture"; that disagreement is gone — GTD's units are named by
# their FEATURES on all three screens now, and this label is what an anonymous
# remainder is called everywhere.
hd_diverged_flush_pending() {
	hd_fp_out=$1
	hd_fp_domain=$2
	hub_feature_counts "$hd_fp_domain" "$HD_DIVERGED_FEATURES" "$HD_FEATURE_COUNTS"
	# Read with a redirect, never `hub_feature_counts … | while read`: POSIX sh has no
	# `lastpipe`, so the loop body would run in a subshell and hd_diverged_emit's
	# HD_DIVERGED_LINES increment — the figure this section's own heading counts —
	# would be lost the moment the pipeline ended.
	while IFS="$HUB_TAB" read -r hd_fp_n hd_fp_label; do
		[ -n "$hd_fp_n" ] || continue
		# The tail counts the DIVERGED units behind the name, not the feature's total:
		# a feature whose one skill of two diverged has a single mismatched copy.
		hd_fp_tail=$HD_TAIL_PLURAL
		[ "$hd_fp_n" -gt 1 ] || hd_fp_tail=$HD_TAIL_SINGULAR
		hd_diverged_emit "$hd_fp_out" "$hd_fp_label" "$hd_fp_tail"
	done <"$HD_FEATURE_COUNTS"
	: >"$HD_DIVERGED_FEATURES"
	hd_fp_count=$(hub_count_lines "$HD_DIVERGED_PENDING")
	if [ "$hd_fp_count" -gt 0 ]; then
		hd_fp_label=$(printf '%s (%s %s)' "$HUB_BASELINE_LABEL" "$hd_fp_count" \
			"$(hub_plural "$hd_fp_count" item items)")
		hd_fp_tail=$HD_TAIL_PLURAL
		[ "$hd_fp_count" -gt 1 ] || hd_fp_tail=$HD_TAIL_SINGULAR
		hd_diverged_emit "$hd_fp_out" "$hd_fp_label" "$hd_fp_tail"
	fi
	: >"$HD_DIVERGED_PENDING"
}

# hd_diverged_emit OUTFILE TEXT TAIL -> one item line, writing the pending domain
# sub-header first if this is the domain's first item.
#
# The heading is written HERE rather than at the domain change so a domain whose
# rows all collapse into something else can never leave a header standing over
# nothing — the same "heading on the first qualifying row" shape hub-list.sh's
# hl_print_status_group uses. Owning the line count alongside it keeps the two
# from disagreeing about how many items were actually rendered.
hd_diverged_emit() {
	if [ "$HD_DIVERGED_HEADING_WRITTEN" -eq 0 ]; then
		printf '    %s\n' "$HD_DIVERGED_HEADING" >>"$1"
		HD_DIVERGED_HEADING_WRITTEN=1
	fi
	printf '      %s %s — %s\n' "$(hub_glyph_warn)" "$2" "$3" >>"$1"
	HD_DIVERGED_LINES=$((HD_DIVERGED_LINES + 1))
}

GH_CONSUMER_INSTALLED=false
# Materialized to a file, then read with a redirect. A `while read ... <<EOF
# $(cmd) EOF` heredoc-wrapped command substitution parses, but it is the
# construction hub-uninstall.sh's own comment calls out as unsafe and avoids; all
# three consumers of hub_shared_consumers now read it the same, plainer way.
HD_CONSUMERS="$HUB_WORK/shared-consumers.tsv"
hub_shared_consumers "$HUB_SHARED_GIT_AUTH_GROUP" >"$HD_CONSUMERS"
while IFS="$HUB_TAB" read -r HD_CONSUMER _; do
	[ -n "$HD_CONSUMER" ] || continue
	[ "$(hub_group_state "$HD_CONSUMER")" = available ] || GH_CONSUMER_INSTALLED=true
done <"$HD_CONSUMERS"

# ---------------------------------------------------------------------------
# Findings. PROBLEMS and NOTES are separate files so the summary heading can
# count each honestly instead of lumping them into one severity.
# ---------------------------------------------------------------------------
PROBLEMS="$HUB_WORK/problems.txt"
NOTES="$HUB_WORK/notes.txt"
STEPS="$HUB_WORK/steps.txt"
: >"$PROBLEMS"
: >"$NOTES"
: >"$STEPS"

while IFS="$HUB_TAB" read -r _ HD_PRIMARY HD_STATE HD_FALLBACK; do
	[ -n "$HD_PRIMARY" ] || continue
	case $HD_STATE in
	missing)
		printf '%s missing — %s\n' "$(hub_tool_label "$HD_PRIMARY")" "$(hub_tool_reason "$HD_PRIMARY")" >>"$PROBLEMS"
		printf 'install %s — macOS: %s%sLinux: %s\n' \
			"$(hub_tool_label "$HD_PRIMARY")" "$(hub_tool_install_macos "$HD_PRIMARY")" \
			"$(hub_sep_text)" "$(hub_tool_install_linux "$HD_PRIMARY")" >>"$STEPS"
		;;
	ok-fallback)
		printf '%s missing (%s present, so signing still works)\n' \
			"$(hub_tool_label "$HD_PRIMARY")" "$(hub_tool_label "$HD_FALLBACK")" >>"$NOTES"
		printf '(optional) install %s — %s already satisfies this requirement, so this is non-blocking\n' \
			"$(hub_tool_label "$HD_PRIMARY")" "$(hub_tool_label "$HD_FALLBACK")" >>"$STEPS"
		;;
	esac
done <"$TOOLS"

if [ "$GH_STATE_KNOWN" != true ]; then
	# NOT the same finding as "not authenticated", and never reported as one: the
	# status script was not run (a foreign --source, or none found), so the state is
	# genuinely unknown and asserting either answer would be a guess.
	printf 'GitHub auth state not checked — open "Accounts" to check it interactively\n' >>"$NOTES"
elif [ "$GH_INSTALLED" = true ] && [ "$GH_AUTHENTICATED" != true ]; then
	if [ "$GH_CONSUMER_INSTALLED" = true ]; then
		printf 'GitHub not authenticated (required by an installed domain)\n' >>"$PROBLEMS"
	else
		printf 'GitHub not authenticated (only relevant once you install a domain that needs it)\n' >>"$NOTES"
	fi
	# hub_arrow_text, not hub_glyph_arrow: these next-step lines are emitted
	# VERBATIM as machine payload under --format=env/json (HUB_STEP_N_NAME /
	# steps[]), so a coloured glyph would embed an ANSI escape inside a value a
	# caller parses. The text helper still honours --accessible.
	printf 'Accounts %s authenticate GitHub\n' "$(hub_arrow_text)" >>"$STEPS"
fi

if [ "$JIRA_STATE_KNOWN" != true ]; then
	printf 'Jira auth state not checked — open "Accounts" to check it interactively\n' >>"$NOTES"
elif [ "$JIRA_CONFIGURED" != true ]; then
	if [ "$JIRA_BACKEND_INSTALLED" = true ]; then
		printf 'Jira not authenticated (the Jira backend is installed and needs it)\n' >>"$PROBLEMS"
	else
		printf 'Jira not authenticated (only relevant if you install the Jira backend)\n' >>"$NOTES"
	fi
	printf 'Accounts %s configure Jira\n' "$(hub_arrow_text)" >>"$STEPS"
fi

PROBLEM_COUNT=$(hub_count_lines "$PROBLEMS")
NOTE_COUNT=$(hub_count_lines "$NOTES")
STEP_COUNT=$(hub_count_lines "$STEPS")

case $OPT_FORMAT in
env)
	hub_env_kv HUB_STATUS ok
	hub_env_kv HUB_ACTION doctor
	hub_env_kv HUB_GH_AUTHENTICATED "$GH_AUTHENTICATED"
	hub_env_kv HUB_GH_STATE_KNOWN "$GH_STATE_KNOWN"
	hub_env_kv HUB_JIRA_CONFIGURED "$JIRA_CONFIGURED"
	hub_env_kv HUB_JIRA_STATE_KNOWN "$JIRA_STATE_KNOWN"
	hub_env_kv HUB_DIVERGED_COUNT "$DIVERGED_COUNT"
	hub_emit_itemized_env HUB_DIVERGED "$DIVERGED_ITEMS"
	HD_N=0
	while IFS="$HUB_TAB" read -r _ HD_PRIMARY HD_STATE HD_FALLBACK; do
		[ -n "$HD_PRIMARY" ] || continue
		HD_N=$((HD_N + 1))
		hub_env_kv "HUB_TOOL_${HD_N}_NAME" "$HD_PRIMARY"
		hub_env_kv "HUB_TOOL_${HD_N}_STATE" "$HD_STATE"
		# FALLBACK is emitted here as well as in the JSON branch: env and json are
		# two first-class equivalent renderings, and an ok-fallback state is
		# uninterpretable without knowing WHICH alternative satisfied the slot.
		hub_env_kv "HUB_TOOL_${HD_N}_FALLBACK" "$HD_FALLBACK"
	done <"$TOOLS"
	hub_env_kv HUB_TOOL_COUNT "$HD_N"
	hub_emit_itemized_env HUB_PROBLEM "$PROBLEMS"
	hub_emit_itemized_env HUB_NOTE "$NOTES"
	hub_emit_itemized_env HUB_STEP "$STEPS"
	;;
json)
	have jq || die "--format=json requires jq, which is not installed"
	HD_TOOL_JSON="$(hub_mktemp_dir)/tools.json"
	: >"$HD_TOOL_JSON"
	while IFS="$HUB_TAB" read -r _ HD_PRIMARY HD_STATE HD_FALLBACK; do
		[ -n "$HD_PRIMARY" ] || continue
		jq -cn --arg name "$HD_PRIMARY" --arg fallback "$HD_FALLBACK" --arg state "$HD_STATE" \
			'{name:$name, fallback:$fallback, state:$state}' >>"$HD_TOOL_JSON"
	done <"$TOOLS"
	HD_PROBLEM_JSON=$(hub_itemized_json_array "$PROBLEMS")
	HD_NOTE_JSON=$(hub_itemized_json_array "$NOTES")
	HD_STEP_JSON=$(hub_itemized_json_array "$STEPS")
	HD_DIVERGED_JSON=$(hub_itemized_json_array "$DIVERGED_ITEMS")
	jq -n \
		--argjson gh_authenticated "$([ "$GH_AUTHENTICATED" = true ] && printf true || printf false)" \
		--argjson gh_state_known "$([ "$GH_STATE_KNOWN" = true ] && printf true || printf false)" \
		--argjson jira_configured "$([ "$JIRA_CONFIGURED" = true ] && printf true || printf false)" \
		--argjson jira_state_known "$([ "$JIRA_STATE_KNOWN" = true ] && printf true || printf false)" \
		--argjson diverged_count "$DIVERGED_COUNT" \
		--slurpfile tools "$HD_TOOL_JSON" \
		--slurpfile problems "$HD_PROBLEM_JSON" \
		--slurpfile notes "$HD_NOTE_JSON" \
		--slurpfile steps "$HD_STEP_JSON" \
		--slurpfile diverged "$HD_DIVERGED_JSON" \
		'{status:"ok", action:"doctor", gh_authenticated:$gh_authenticated,
		  gh_state_known:$gh_state_known,
		  jira_configured:$jira_configured, jira_state_known:$jira_state_known,
		  diverged_count:$diverged_count, diverged:$diverged,
		  tools:$tools, problems:$problems, notes:$notes, steps:$steps}'
	;;
text)
	hub_print_header "crucible-hub doctor — $TARGET_DIR"
	printf '\n  Required tools\n'
	# Glyph now LEADS the tool name (✓/✗, matching every other status line in
	# this hub) instead of a trailing bare "ok"/nothing — a live test session
	# found the un-glyphed "ok" rows inconsistent with Accounts' own
	# glyph-first lines right below them on this same screen.
	while IFS="$HUB_TAB" read -r _ HD_PRIMARY HD_STATE HD_FALLBACK; do
		[ -n "$HD_PRIMARY" ] || continue
		case $HD_STATE in
		ok) printf '    %s %s\n' "$(hub_glyph_ok)" "$(hub_tool_label "$HD_PRIMARY")" ;;
		ok-fallback)
			printf '    %s %s   missing (%s ok — satisfies the requirement, non-blocking)\n' \
				"$(hub_glyph_ok)" "$(hub_tool_label "$HD_PRIMARY")" "$(hub_tool_label "$HD_FALLBACK")"
			;;
		missing)
			printf '    %s %s   — %s\n' "$(hub_glyph_fail)" "$(hub_tool_label "$HD_PRIMARY")" "$(hub_tool_reason "$HD_PRIMARY")"
			printf '        macOS:  %s\n' "$(hub_tool_install_macos "$HD_PRIMARY")"
			printf '        Linux:  %s\n' "$(hub_tool_install_linux "$HD_PRIMARY")"
			;;
		esac
	done <"$TOOLS"

	# Rendered before it is printed, because the heading counts the LINES the
	# grouping produced (two diverged technologies and a lens read "(3)", not
	# "(7)") and that figure is not known until the body exists. The count is
	# also what gates the section: DIVERGED_COUNT alone would print a heading
	# over an empty body if the render ever dropped every row.
	HD_DIVERGED_LINES=0
	if [ "$DIVERGED_COUNT" -gt 0 ]; then
		hd_diverged_plan_build "$HD_DIVERGED_PLAN"
		hd_diverged_render "$HD_DIVERGED_TEXT"
	fi
	if [ "$HD_DIVERGED_LINES" -gt 0 ]; then
		printf '\n  Diverged components (%s):\n' "$HD_DIVERGED_LINES"
		cat "$HD_DIVERGED_TEXT"
		printf '    Run "Install" and re-select these to re-sync (see "List" for full detail).\n'
	fi

	# The orphan section, beside the diverged one and after it: divergence is the
	# recoverable fault and its repair is "Install", an orphan is the unrecoverable
	# one and its only repair is "Uninstall", so the two carry different next steps
	# and cannot share a block. Flat lines, no sub-header — see the section's own
	# header above on why an orphan has nothing to collapse to. The glyph is
	# hub_glyph_fail, not hub_glyph_warn: this is the broken case, and List marks it
	# the same way.
	if [ "$HD_ORPHAN_COUNT" -gt 0 ]; then
		printf '\n  Orphaned components (%s):\n' "$HD_ORPHAN_COUNT"
		while IFS="$HUB_TAB" read -r HD_ORPHAN_NAME _; do
			[ -n "$HD_ORPHAN_NAME" ] || continue
			printf '    %s %s — source no longer exists\n' "$(hub_glyph_fail)" "$HD_ORPHAN_NAME"
		done <"$HD_ORPHANS"
		printf '    Run "Uninstall" and choose these to clear the stale links.\n'
	fi

	printf '\n  Accounts\n'
	# HUB_STDOUT_IS_TTY / HUB_NO_COLOR are passed into the CHILD's own
	# environment explicitly here, rather than left for it to decide on its
	# own: hub-accounts.sh is a separate process piped into `sed`, so ITS OWN
	# `[ -t 1 ]` sees the pipe this indent redirect creates, not the real
	# terminal several levels up — silently disabling color in exactly this
	# delegated block even when Doctor's own directly-printed lines above it
	# stayed colored. See lib/hub-common.sh's HUB_STDOUT_IS_TTY comment for the
	# full mechanism; this line is the fix, applied at the one call site that
	# hits it.
	#
	# CAPTURED TO A FILE FIRST, then indented from it — never piped straight into
	# `sed`. A pipeline's exit status is its LAST command's, so `sed` reported 0 no
	# matter what the delegate did: a delegate that died outright (its own "N
	# executables named X found; refusing to guess", say) rendered an EMPTY Accounts
	# block with no diagnostic at all, and Doctor still exited 0 claiming a clean
	# report. Doctor's charter is still "report, never fail" — hence the explicit
	# unavailable line rather than a die — but an empty block with no explanation is
	# not a report.
	HD_ACCOUNTS_TEXT="$HUB_WORK/accounts.txt"
	HD_ACCOUNTS_ERR="$HUB_WORK/accounts-text.stderr"
	HD_ACCOUNTS_RC=0
	HUB_STDOUT_IS_TTY=$HUB_STDOUT_IS_TTY HUB_NO_COLOR=$HUB_NO_COLOR \
		"$HUB_DIR0/hub-accounts.sh" status --source "$FRAMEWORK_ROOT" --target "$TARGET_DIR" \
		--format=text >"$HD_ACCOUNTS_TEXT" 2>"$HD_ACCOUNTS_ERR" || HD_ACCOUNTS_RC=$?
	if [ "$HD_ACCOUNTS_RC" -eq 0 ] && [ -s "$HD_ACCOUNTS_TEXT" ]; then
		sed 's/^/  /' <"$HD_ACCOUNTS_TEXT"
	else
		# The delegate's own first stderr line is the reason where it left one; a
		# delegate that died silently at least gets its exit status named.
		HD_ACCOUNTS_WHY=$(awk 'NF { print; exit }' "$HD_ACCOUNTS_ERR")
		[ -n "$HD_ACCOUNTS_WHY" ] ||
			HD_ACCOUNTS_WHY="hub-accounts.sh status exited $HD_ACCOUNTS_RC with no output"
		printf '    %s Accounts status unavailable — %s\n' "$(hub_glyph_fail)" "$HD_ACCOUNTS_WHY"
	fi

	printf '\n'
	if [ "$PROBLEM_COUNT" -gt 0 ] && [ "$NOTE_COUNT" -gt 0 ]; then
		printf '  Summary: %s %s, %s %s\n' \
			"$PROBLEM_COUNT" "$(hub_plural "$PROBLEM_COUNT" problem problems)" \
			"$NOTE_COUNT" "$(hub_plural "$NOTE_COUNT" note notes)"
	elif [ "$PROBLEM_COUNT" -gt 0 ]; then
		printf '  Summary: %s %s\n' "$PROBLEM_COUNT" "$(hub_plural "$PROBLEM_COUNT" problem problems)"
	elif [ "$NOTE_COUNT" -gt 0 ]; then
		printf '  Summary: %s %s\n' "$NOTE_COUNT" "$(hub_plural "$NOTE_COUNT" note notes)"
	fi
	# No "everything is healthy" line at all when there is nothing to report: a
	# live test session flagged it as redundant against a screen that already
	# shows nothing but green checkmarks — repeating "healthy" a second time
	# added a line without adding information.
	while IFS= read -r HD_LINE; do
		[ -n "$HD_LINE" ] || continue
		printf '    - %s\n' "$HD_LINE"
	done <"$PROBLEMS"
	while IFS= read -r HD_LINE; do
		[ -n "$HD_LINE" ] || continue
		printf '    - %s\n' "$HD_LINE"
	done <"$NOTES"

	if [ "$STEP_COUNT" -gt 0 ]; then
		printf '\n  Suggested next steps (%s):\n' "$STEP_COUNT"
		HD_N=0
		while IFS= read -r HD_LINE; do
			[ -n "$HD_LINE" ] || continue
			HD_N=$((HD_N + 1))
			printf '    %s) %s\n' "$HD_N" "$HD_LINE"
		done <"$STEPS"
	fi

	if hub_interactive; then
		HD_PAUSE=0
		hub_press_key_to_continue || HD_PAUSE=$?
		[ "$HD_PAUSE" -ne 3 ] || exit 3
	fi
	;;
esac

exit 0
