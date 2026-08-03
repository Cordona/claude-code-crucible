#!/usr/bin/env sh
# hub-list.sh — Capability: List. Every discovered component, grouped by STATUS
#                and nothing else: Installed, Available, Diverged (plus
#                Orphaned when any exists).
#
# Usage:
#   hub-list.sh [--target DIR] [--source DIR] [--format=text|env|json]
#               [--no-color] [-h|--help]
#
# Output (text): three status groups, in that fixed order. NOT grouped by
#   domain, and no selectable/baseline distinction is shown — an installed item
#   is just installed, regardless of which domain or which mechanism put it
#   there. An empty group is omitted rather than rendered as a header over
#   nothing; when every group is empty, one explicit line says so.
#
#   Within a status group the rows sit under a domain sub-header, then under one
#   final sub-header for whatever belongs to no domain at all (the cross-domain
#   shared auth procedure) — see hl_nondomain_rows_build, which exists because that
#   last sub-header was MISSING and the machine formats below reported a component
#   this screen did not.
#
#   NO ROW IS EVER ELIDED, at any scale. The "... and N more, one line each in
#   the real output" annotations in the spec's mockups are mockup shorthand
#   meaning "the real screen lists them all" — this is the real screen.
#
#   A fourth "Orphaned" group appears ONLY when a dangling link exists (a
#   symlink the hub placed whose source has since been deleted or renamed).
#   That group is not in the spec's mockup, and is included deliberately: the
#   machine formats below report orphans, and a fact an agent can read while a
#   human cannot is exactly the capability gap the parity requirement forbids.
#   In the normal case it is invisible, so it costs the screen nothing.
#
# Output (env/json): the four counts plus one indexed row per component
#   (key/display/state/group), in the same canonical order the text screen uses.
#
#   WHICH FIELDS ARE STABLE: the FIELD SET is a closed contract (a new field is an
#   addition; a removed or renamed one is a break), and within a row `key`, `group`
#   and a selection key are the STABLE IDENTITY a caller should match on. The
#   display-valued fields — HUB_ITEM_<N>_DISPLAY / items[].display here,
#   hub-doctor.sh's HUB_DIVERGED_<N>_NAME / diverged[], and hub-accounts.sh's
#   HUB_*_USED_BY — are PRESENTATION and may be reworded without notice, exactly as
#   the text screen's own lines may be. Match on key, not on display text.
#
# Exit codes: 0 always (read-only, cannot fail on valid input); 2 usage error.
#
# Portability: POSIX sh only. jq is required ONLY for --format=json.
set -eu

HUB_PROG="crucible-hub list"
HUB_DIR0=$(dirname "$0")
. "$HUB_DIR0/lib/hub-common.sh"
. "$HUB_DIR0/lib/hub-domains.sh"
. "$HUB_DIR0/lib/hub-render.sh"
. "$HUB_DIR0/lib/hub-nav.sh"
. "$HUB_DIR0/lib/hub-discovery.sh"
. "$HUB_DIR0/lib/hub-state.sh"

hub_workspace_init

usage() {
	cat <<EOF
Usage: $HUB_PROG [--target DIR] [--source DIR] [--format=text|env|json] [--no-color] [-h|--help]

Every discovered component, grouped by status: installed, available, diverged.

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

hub_discovery_build "$FRAMEWORK_ROOT"
hub_states_build "$TARGET_DIR"
hub_rows_build

ORPHANS="$HUB_WORK/orphans.tsv"
hub_orphaned_units "$TARGET_DIR" >"$ORPHANS"
ORPHAN_COUNT=$(hub_count_lines "$ORPHANS")

# Row-level counts, not unit-level: an atomic group is ONE row, so the numbers
# here are what the screen actually shows. hub_state_counts' unit-level figures
# are a different (also correct) view and are what the status block reports.
ROW_TOTAL=$(hub_count_lines "$HUB_ROWS")

# Built once, read repeatedly by the text-format domain/status grouping below.
HL_DOMAIN_TMP="$HUB_WORK/domain-rows.txt"
HL_BS_TMP="$HUB_WORK/baseline-summary.tsv"
HL_BS_KEYED="$HUB_WORK/baseline-keyed.tsv"
HL_FEAT_TMP="$HUB_WORK/domain-feature-lines.txt"

# hl_rows_of_state STATE -> the rows in one status group, canonical order.
hl_rows_of_state() {
	hl_ros_state="$1" awk -F '\t' '$4 == ENVIRON["hl_ros_state"]' "$HUB_ROWS"
}

# ---------------------------------------------------------------------------
# TEXT-format-only presentation grouping. env/json stay flat and per-unit (see
# above) — this reshaping is purely a human-scan concern, not a machine-payload
# one, per the same split the confirm screen already draws between "fully
# itemized, machine-relevant" and "collapsed for scannability".
#
# A live test session found the flat, unsorted per-unit list unreadable at real
# scale (agent+skill pairs for every technology, every lens reviewer and its own
# rubric standard, every flow/specialist — 40+ lines with no structure). Four
# changes, all driven by PATH SHAPE / NAMING PATTERN, never a name list, so
# adding, removing or renaming anything within an existing domain still needs
# zero changes here:
#   1. Rows are grouped by DOMAIN under each status heading (still status-first,
#      per round 6 — domain is now a sub-header, not the primary axis).
#   2. A technology's dev+reviewer pair collapses to ONE row per technology (see
#      hl_selectable_rows_build) and renders under its domain.
#   3. A domain's baseline (flows/specialists/build+review facades) collapses to
#      one "Framework baseline (N items)" line, EXCEPT its lens reviewers, which
#      are itemized by name (they are individually nameable things, unlike pure
#      plumbing), and EXCEPT the NAMED FEATURES of a domain that declares any,
#      which get one line each (see hl_domain_feature_lines). Each lens's own
#      rubric standard is NOT itemized and folds into the collapsed count — see
#      hl_lens_rows_build on why. Only Software Development's tree carries lens
#      reviewers today and only GTD declares features, so only those two
#      baselines actually split; both splits are keyed on data (the bucket
#      column, the registry's feature list), never on a domain literal, so a
#      second domain acquiring either would split with no edit here.
#   4. A group that belongs to no domain at all — the cross-domain shared auth
#      procedure — renders under its own trailing sub-header, per status group.
#      See hl_nondomain_rows_build: it was previously rendered NOWHERE on this
#      screen while --format=env/json reported it, which is the parity gap this
#      file's own header forbids.
#
# ALL THREE reshapings are FILTERS over ONE shared classification —
# lib/hub-state.sh's hub_domain_buckets, materialized once by hl_buckets_build
# below — never this file's own second derivation of it. That is why no path
# shape, no directory constant and no state-vocabulary mapping appears anywhere
# below: the stream's `bucket` column already answers "selectable, standard, lens
# or plain baseline", and its `state` column is already in the display vocabulary
# (a partly-present group resolved to DIVERGED by hub_group_display_state).
# ---------------------------------------------------------------------------

# hl_buckets_build -> sets HL_BUCKETS to "domain<TAB>bucket<TAB>state<TAB>display",
# lib/hub-state.sh's hub_domain_buckets stream for every domain the framework
# source actually ships, concatenated in HUB_DOMAIN_KEYS order and tagged with the
# domain each row came from.
#
# THE single classification the three projections below all filter. Each of them
# used to derive its own: hl_selectable_rows_build carried a hand-written copy of
# hub_group_display_state's partial->DIVERGED mapping, and hl_lens_rows_build and
# hl_baseline_summary carried a private awk `in_dir` apiece — two of the five
# spellings of hub_src_in_dir that lib/hub-domains.sh names as the ones expected
# to go. A screen that classifies is a screen that drifts from the classifier.
#
# Built ONCE for the whole screen, not once per status group: the three status
# groups are three filters over the same answer, and hub_domain_buckets runs an
# awk per selectable group per call.
#
# The domain column is prepended from the LOOP VARIABLE rather than parsed back
# out of a group key: hub_domain_selectable_groups selects a group precisely BY
# the group table's domain column, so the loop variable already IS that column's
# value for a selectable row, and a baseline group is keyed on the domain in the
# first place. Nothing here re-derives it.
#
# Domains absent from the source are skipped on hub_domain_exists, the same test
# hl_print_status_group applies before rendering one — a source shipping only some
# domains is legitimate (see lib/hub-domains.sh), and a domain nothing renders
# needs no rows.
#
# COLUMN ORDER follows hub_domain_buckets' own rule (lib/hub-common.sh's "THE TAB
# TRAP"): domain, bucket and state are hub-generated words that can never be
# empty, and display — the only column whose emptiness is possible — stays last.
# The `groupkey` column is dropped: no projection on this screen names a group.
hl_buckets_build() {
	HL_BUCKETS="$HUB_WORK/buckets.tsv"
	hl_bb_tmp="$HUB_WORK/domain-buckets.tsv"
	: >"$HL_BUCKETS"
	for hl_bb_domain in $HUB_DOMAIN_KEYS; do
		hub_domain_exists "$FRAMEWORK_ROOT" "$hl_bb_domain" || continue
		hub_domain_buckets "$hl_bb_domain" "$hl_bb_tmp"
		hl_bb_dom="$hl_bb_domain" awk -F '\t' -v OFS='\t' \
			'{ print ENVIRON["hl_bb_dom"], $1, $3, $4 }' "$hl_bb_tmp" >>"$HL_BUCKETS"
	done
}

# hl_selectable_rows_build -> sets HL_SEL to "domain<TAB>display<TAB>state" for
# every SELECTABLE GROUP (technology or pm-backend) — ONE row per group, using
# the group's own aggregate state and its own display label, regardless of how
# many units the group holds.
#
# A filter on HL_BUCKETS' `selectable` bucket, which already IS that projection:
# hub_domain_buckets collapses a technology to one row because a technology is one
# thing a human picks, and puts its aggregate through hub_group_display_state, so
# a partly-present group arrives here reading DIVERGED with no mapping of our own.
#
# Deliberately NOT built from HUB_ROWS: that table is per-UNIT for every
# non-atomic group (hub_rows_build only collapses a group the group table marks
# atomic, i.e. a pm-backend), which is what Doctor's diverged-components section
# and this screen's own per-unit env/json payload need — but reusing it HERE would
# show "Python agent developer"/"Python agent reviewer" as two List rows, the exact
# clutter this rewrite exists to remove. Uninstall's checklist makes the same
# collapse for its own reasons and by its own projection (its SELECTABLE_ROWS);
# neither screen changes what hub_rows_build itself produces.
hl_selectable_rows_build() {
	HL_SEL="$HUB_WORK/sel-rows.tsv"
	awk -F '\t' -v OFS='\t' '$2 == "selectable" { print $1, $4, $3 }' "$HL_BUCKETS" >"$HL_SEL"
}

# hl_domain_rows DOMAIN STATE -> one display name per line, this domain's
# selectable rows in STATE.
hl_domain_rows() {
	hl_dr_dom="$1" hl_dr_state="$2" awk -F '\t' \
		'$1 == ENVIRON["hl_dr_dom"] && $3 == ENVIRON["hl_dr_state"] { print $2 }' "$HL_SEL"
}

# hl_domain_lens_rows DOMAIN STATE -> one display name per line, this domain's LENS
# rows in STATE. The lens-bucket counterpart of hl_domain_rows above, filtered by
# the same two columns on the same shape of table, which is the whole point of
# HL_LENS carrying its domain column (see hl_lens_rows_build).
hl_domain_lens_rows() {
	hl_dlr_dom="$1" hl_dlr_state="$2" awk -F '\t' \
		'$1 == ENVIRON["hl_dlr_dom"] && $3 == ENVIRON["hl_dlr_state"] { print $2 }' "$HL_LENS"
}

# hl_lens_rows_build -> sets HL_LENS to "domain<TAB>display<TAB>state", one row per
# LENS REVIEWER unit — using the unit's own already-computed display name
# (hub-discovery.sh's display pass already names it "{Name} review lens") and its
# own unit state directly, never re-derived.
#
# THE DOMAIN COLUMN IS CARRIED, not dropped, and that is what lets
# hl_print_status_group filter these rows the same way it filters every other
# projection — by the domain it is currently rendering. It used to project only
# display+state, which left the renderer with no way to ask "are these lenses
# THIS domain's" and forced it to guard the whole lens block behind a literal
# `[ "$hl_domain" = software-development ]` instead. That literal was a name
# hardcoded into a screen whose entire design is "zero hardcoded names", it was
# the exact domain literal hub_domain_buckets had just finished removing from two
# files (see its "ZERO HARDCODED NAMES" note), and it was also WRONG the moment a
# second domain grew lens reviewers: hub_domain_buckets emits a `lens` row for any
# domain whose tree carries the subtree, so those rows existed in HL_BUCKETS and
# were rendered under Software Development's sub-header regardless of which domain
# they belonged to. Filtering on the column the stream already provides fixes the
# misattribution and deletes the literal in one move.
#
# A filter on HL_BUCKETS' `lens` bucket. WHICH baseline units are lenses is
# hub_domain_buckets' answer, from the one src-path test (hub_src_in_dir against
# HUB_SD_DIR_LENS_REVIEWERS); this function no longer carries its own awk copy of
# that test, nor the `baseline:software-development` group key it used to pair the
# copy with. Software Development is the only domain whose tree holds that
# subtree, so the bucket is empty for the others without a domain literal here.
#
# Deliberately does NOT also try to itemize/pair each lens's own rubric standard
# by matching names: a lens reviewer's name and its standard's name are not
# always the same key after stripping their respective prefixes/suffixes
# (`lens-test-quality-reviewer` binds `standard-testing`, not a nonexistent
# `standard-test-quality`) — a real edge case this exact function hit and got
# wrong on the first pass, inventing a fake ninth "Testing review lens" entry.
# Matching by SRC PATH alone (is this unit under agents/reviewers/lens/, full
# stop) has no such failure mode.
#
# ===========================================================================
# THE AUTHORITATIVE RULE: A STANDARD IS NEVER AN INDIVIDUALLY NAMED ROW.
# ===========================================================================
# Stated here because this is the function whose exclusion establishes it, and
# stated ONCE — every other screen defers to this paragraph rather than repeating
# or contradicting it (hub-install.sh's hi_bucket_reset now points here).
#
# Both kinds of standard fold into whatever already names their owner, and neither
# is ever a row of its own:
#   * a LENS's own rubric standard (`standard-testing`) lives under shared/, so
#     hub_domain_buckets buckets it `baseline` and it folds into the collapsed
#     "Framework baseline (N items)" count below.
#   * a TECHNOLOGY's standard (`standard-python`) is a unit of that technology's
#     GROUP, so hl_selectable_rows_build's one-row-per-group collapse already
#     accounts for it — which is why this screen has never needed, and still has
#     no, filter on hub_domain_buckets' `standard` bucket.
# The two mechanisms differ; the rule they produce is the same one, and it is the
# same rule a baseline unit gets: the individually nameable things on this hub's
# screens are technologies, backends and lens reviewers. Nothing else.
hl_lens_rows_build() {
	HL_LENS="$HUB_WORK/lens-rows.tsv"
	awk -F '\t' -v OFS='\t' '$2 == "lens" { print $1, $4, $3 }' "$HL_BUCKETS" >"$HL_LENS"
}

# hl_features_build -> sets HL_FEATURES to
# "domain<TAB>state<TAB>count<TAB>pending<TAB>label", lib/hub-state.sh's
# hub_domain_feature_rows stream for every domain the source ships, tagged with
# the domain each row came from. Empty overall when no domain declares features.
#
# The `pending` column is carried through untouched and read by nothing on this
# screen: a listing reports what IS installed, never what a re-install would write
# (that is hub-install.sh's preview). It stays in the stream rather than being
# projected away so this file's shape matches the library's own row contract, which
# is what makes the column indices below checkable against one documented source.
#
# THE FEATURE COUNTERPART OF hl_buckets_build, built the same way and for the same
# reason: one materialization per SCREEN rather than one per status group, since
# the three status groups are three filters over the same answer and
# hub_domain_feature_rows runs an awk per feature per call.
#
# It is a SEPARATE stream from HL_BUCKETS rather than a fifth bucket, because a
# feature is not the same shape as a bucket row: a bucket row is one unit or one
# whole group at one state, while a feature is a SUBSET of a group's units and
# needs its own collapsed state and its own unit count. Adding a column to the
# bucket table to carry that would have moved every existing consumer's awk field
# indices — in two screens — to serve one domain.
#
# The domain column is prepended from the LOOP VARIABLE, exactly as
# hl_buckets_build does it and for the same reason: the loop variable already IS
# the domain each row belongs to, so nothing here re-derives it.
hl_features_build() {
	HL_FEATURES="$HUB_WORK/feature-rows.tsv"
	hl_fb_tmp="$HUB_WORK/domain-features.tsv"
	: >"$HL_FEATURES"
	for hl_fb_domain in $HUB_DOMAIN_KEYS; do
		hub_domain_exists "$FRAMEWORK_ROOT" "$hl_fb_domain" || continue
		hub_domain_feature_rows "$hl_fb_domain" "$hl_fb_tmp"
		hl_fb_dom="$hl_fb_domain" awk -F '\t' -v OFS='\t' \
			'{ print ENVIRON["hl_fb_dom"], $1, $2, $3, $4 }' "$hl_fb_tmp" >>"$HL_FEATURES"
	done
}

# hl_domain_feature_lines DOMAIN STATE -> one label per line, this domain's NAMED
# FEATURES that are in STATE and actually have units.
#
# The RESIDUAL row is excluded by `$5 != ""`: it carries no label because it is
# the anonymous remainder, and hl_baseline_summary below is what reports it — as
# the same collapsed "Framework baseline (N items)" line every other domain's
# baseline gets. The zero-count guard is the same one the collapsed line applies
# (see hub_domain_feature_rows on why a zero-count row is emitted at all).
hl_domain_feature_lines() {
	hl_dfl_dom="$1" hl_dfl_state="$2" awk -F '\t' \
		'$1 == ENVIRON["hl_dfl_dom"] && $2 == ENVIRON["hl_dfl_state"] && $3 > 0 && $5 != "" { print $5 }' \
		"$HL_FEATURES"
}

# hl_baseline_summary DOMAIN -> sets HL_BS_STATE / HL_BS_COUNT to this domain's
# baseline aggregate: the state and item count of the collapsed
# "Framework baseline (N items)" line.
#
# THE LENS EXCLUSION IS THE BUCKET, not a second pass. A lens reviewer unit is
# tagged `lens` by hub_domain_buckets and is therefore not a `baseline` row at
# all, so counting the `baseline` bucket counts exactly the units
# hl_lens_rows_build does NOT itemize — with no in_dir test, no domain literal and
# no EXCLUDE_LENS argument for a caller to get right. Each lens's own rubric
# standard still folds into this count: it does not live under the lens-reviewer
# subtree, so hub_domain_buckets buckets it `baseline`, per hl_lens_rows_build's
# header comment on why standards aren't itemized.
#
# THE DENOMINATOR IS PICKED HERE, the arithmetic is not. hub_group_display_state
# answers for the WHOLE baseline group — lenses and featured units included —
# which is the wrong denominator for a line that excludes both, and
# hub_domain_buckets emits the baseline per UNIT precisely so a consumer can pick
# its own. What this function does NOT do any more is spell the collapse out: the
# three-way "installed only when every counted unit is installed, available only
# when none is present at all, DIVERGED for every mix" arithmetic is
# lib/hub-state.sh's hub_state_collapse, which hub_domain_feature_rows also calls
# for its own (unrelated) subset. This projects its slice to that function's
# "key<TAB>state" shape and asks.
#
# A FEATURED DOMAIN SHORT-CIRCUITS onto the RESIDUAL row hub_domain_feature_rows
# already computed for it, and must: this function's own slice is the whole
# `baseline` bucket, which for such a domain still contains every unit its named
# feature lines have just reported. Counting them here as well would print
# "Framework baseline (3 items)" underneath the two lines that account for all
# three. The residual row is the SAME arithmetic over the units no feature claims
# — normally none, in which case the count is 0 and the caller's own
# `HL_BS_COUNT -gt 0` guard drops the line entirely.
hl_baseline_summary() {
	hl_bs_domain=$1
	hl_bs_residual=$(hl_bs_domain="$hl_bs_domain" awk -F '\t' -v OFS='\t' \
		'$1 == ENVIRON["hl_bs_domain"] && $5 == "" { print $2, $3, $4; exit }' "$HL_FEATURES")
	if [ -n "$hl_bs_residual" ]; then
		printf '%s\n' "$hl_bs_residual" >"$HL_BS_TMP"
	else
		awk -F '\t' -v OFS='\t' '$2 == "baseline" { print $1, $3 }' \
			"$HL_BUCKETS" >"$HL_BS_KEYED"
		hub_state_collapse "$HL_BS_KEYED" "$hl_bs_domain" >"$HL_BS_TMP"
	fi
	# THREE fields, not two, and the third DISCARDED into `_` — this hub's own
	# throwaway name (lib/hub-state.sh's own baseline walks read `_ _ src` the same
	# way). hub_state_collapse's third column is the pending count, which a LISTING
	# has no use for (see hl_features_build), but reading only two names would leave
	# the tab and that value inside HL_BS_COUNT, which the caller compares with
	# `-gt` — a shell arithmetic error rather than a wrong number.
	IFS="$HUB_TAB" read -r HL_BS_STATE HL_BS_COUNT _ <"$HL_BS_TMP"
}

# THE COLLAPSED BASELINE LINE'S LABEL is lib/hub-domains.sh's HUB_BASELINE_LABEL,
# read straight from the registry by hl_print_status_group below.
#
# It used to be a local constant here (HL_BASELINE_LABEL), and before that a
# function with a GTD arm calling GTD's baseline "Inbox capture", because GTD's
# whole footprint is nameable in a way the other domains' plumbing is not. That arm
# is GONE, superseded rather than merely deleted: GTD's footprint is now reported by
# its two NAMED FEATURE lines (hl_domain_feature_lines), which say strictly more
# than one borrowed label did — it named only the first of the two capabilities and
# silently covered the second. Keeping both mechanisms would have meant two places
# deciding what GTD's baseline is called.
#
# The local constant then went the same way and for the same reason: hub-doctor.sh
# and hub-install.sh produce this identical line, and all three sites carried a
# comment asserting their wording matched the other two. See HUB_BASELINE_LABEL's
# own header on why one constant replaces three prose assertions.

# hl_nondomain_rows_build -> sets HL_NONDOMAIN to "group<TAB>display<TAB>state" for
# every HUB_ROWS row whose group belongs to NO registered domain. Today that is
# exactly the cross-domain shared group (accounts/'s git-auth procedure).
#
# WHY THIS EXISTS AT ALL — THE TEXT SCREEN WAS LOSING A ROW. Every projection this
# screen renders is derived from HL_BUCKETS, and HL_BUCKETS is a concatenation of
# per-domain hub_domain_buckets streams, which deliberately EXCLUDE the shared group
# (it belongs to no domain — see that function's own header). The renderer below
# then iterates HUB_DOMAIN_KEYS, so a group outside the registry had no loop
# iteration that could ever reach it: `shared:git-auth` was simply absent from the
# text screen, in every status group, while this same script's --format=env and
# --format=json reported it per unit straight out of HUB_ROWS. That is precisely the
# capability gap this file's own header calls forbidden, in the direction that is
# easier to miss — a fact an AGENT can read while a HUMAN cannot.
#
# THE FIX IS hub-doctor.sh'S, APPLIED HERE. Doctor hit the identical problem in
# this same refactor and solved it by streaming HUB_ROWS in canonical order and
# synthesizing a heading from the group table whenever a row's domain is not one of
# the registry's keys (see hd_domain_heading, which states why the HUB_DOMAIN_KEYS
# shape cannot render a cross-domain unit). This screen keeps its domain loop — its
# whole structure is domain sub-headers, and the baseline summary line genuinely is
# per-domain — and adds the same non-domain pass after it, headed by the same
# group label Doctor uses.
#
# THE TEST IS "NOT A REGISTERED DOMAIN", not "role == shared", and the difference is
# what makes the two passes provably EXHAUSTIVE over HUB_ROWS: a group's domain
# column either holds one of the registry's keys or it does not, so no row can fall
# outside both passes. A role-name filter would silently drop a group carrying some
# third role — which is exactly the class of bug this function exists to fix, and
# the same argument hub-install.sh's hi_result_nondomain_blocks makes for its own
# two halves.
#
# ITERATES GROUP KEYS and asks hub_group_field for the domain, rather than reading
# the group table with `read`: that table has legitimately empty middle columns and
# `read` with IFS=TAB collapses them (lib/hub-common.sh's "THE TAB TRAP"). The
# resulting key list is then joined against HUB_ROWS in one awk pass, with the usual
# FILENAME == ARGV[1] phase anchor — an EMPTY key list is a legitimate state (a
# source with no shared group at all), and a bare FNR == NR would misfile HUB_ROWS'
# first record as a wanted key.
#
# COLUMN ORDER, per "THE TAB TRAP": group and state are hub-generated words that can
# never be empty, and display — the only column whose emptiness is even possible —
# goes last. Read by awk only, in any case.
hl_nondomain_rows_build() {
	HL_NONDOMAIN="$HUB_WORK/nondomain-rows.tsv"
	hl_nrb_keys="$HUB_WORK/nondomain-all-groups.txt"
	hl_nrb_wanted="$HUB_WORK/nondomain-groups.txt"
	: >"$hl_nrb_wanted"
	hub_group_keys >"$hl_nrb_keys"
	while IFS= read -r hl_nrb_group; do
		[ -n "$hl_nrb_group" ] || continue
		hl_nrb_domain=$(hub_group_field "$hl_nrb_group" 3)
		# An `if`, never `hub_domain_is_registered … && continue`: a predicate
		# returning 1 as the last command of a loop body trips `set -e`, and the
		# registered case is the common one. Same shape lib/hub-state.sh's own
		# baseline walk states.
		if hub_domain_is_registered "$hl_nrb_domain"; then
			continue
		fi
		printf '%s\n' "$hl_nrb_group" >>"$hl_nrb_wanted"
	done <"$hl_nrb_keys"
	awk -F '\t' -v OFS='\t' '
		FNR == NR && FILENAME == ARGV[1] { want[$1] = 1; next }
		($2 in want) { print $2, $3, $4 }
	' "$hl_nrb_wanted" "$HUB_ROWS" >"$HL_NONDOMAIN"
}

# hl_psg_heading_once -> write the status heading the first time this status group
# has anything to show, and never again.
#
# HL_PSG_ANY / HL_PSG_HEADING are shared with hl_print_nondomain_groups rather than
# passed, because the heading belongs to the whole STATUS GROUP while the two passes
# that can trigger it are separate functions: the domain loop may qualify nothing
# and the cross-domain pass may still qualify something, and "Installed" must be
# printed exactly once either way. Uppercase, per this hub's convention for state
# that deliberately outlives one function (hub-doctor.sh's own
# HD_DIVERGED_HEADING_WRITTEN does the same job for the same reason).
hl_psg_heading_once() {
	[ "$HL_PSG_ANY" -eq 0 ] || return 0
	printf '\n%s\n' "$HL_PSG_HEADING"
	HL_PSG_ANY=1
}

# hl_print_status_group HEADING STATE -> the heading, then one domain sub-header
# per domain that has at least one row in STATE (its selectable rows, its own lens
# rows, and/or its baseline summary line), then one sub-header per non-domain group
# with a row in STATE, or nothing at all when nothing qualifies.
#
# VARIABLE PREFIX: hl_psg_, per-function, like every other function on this screen
# (hl_bb_, hl_bs_, hl_ros_, hl_dr_). POSIX sh has no `local`, so the prefix IS the
# scoping mechanism — the rule lib/hub-state.sh's hub_domain_buckets states in full —
# and the bare hl_state / hl_domain / hl_display names this used to carry were
# shared with three sibling functions on the same screen. hl_state in particular was
# BOTH this function's loop-invariant state argument and hl_rows_of_state's awk
# ENVIRON key, which is a clobber waiting for the day one of them is called from
# inside the other.
hl_print_status_group() {
	HL_PSG_HEADING=$1
	HL_PSG_ANY=0
	hl_psg_state=$2
	# Hoisted out of the row loop, not called per row: it is a closed lookup that
	# DIES on an unknown state, and a die inside a command substitution used as a
	# printf ARGUMENT is swallowed — the substitution yields empty, printf still
	# succeeds, and every row silently loses its glyph. The state is invariant for
	# the whole group, so this also drops one fork per rendered row.
	hl_psg_glyph=$(hub_glyph_for_state "$hl_psg_state")
	for hl_psg_domain in $HUB_DOMAIN_KEYS; do
		hub_domain_exists "$FRAMEWORK_ROOT" "$hl_psg_domain" || continue
		hl_domain_rows "$hl_psg_domain" "$hl_psg_state" >"$HL_DOMAIN_TMP"
		# THIS DOMAIN's lens rows, filtered by HL_LENS' own domain column — no
		# `= software-development` literal any more. See hl_lens_rows_build on why
		# that literal was both a hardcoded name and a misattribution bug.
		hl_domain_lens_rows "$hl_psg_domain" "$hl_psg_state" >>"$HL_DOMAIN_TMP"
		# THIS DOMAIN's named features, kept in a file of their own as well as
		# appended to the row list: the atomicity hint below is printed only when a
		# feature line was actually rendered in THIS status group, and that is the
		# only thing that can answer it (a domain's features can land in two
		# different status groups, and the hint belongs under each).
		hl_domain_feature_lines "$hl_psg_domain" "$hl_psg_state" >"$HL_FEAT_TMP"
		cat "$HL_FEAT_TMP" >>"$HL_DOMAIN_TMP"
		hl_baseline_summary "$hl_psg_domain"
		hl_psg_bs_line=""
		if [ "$HL_BS_STATE" = "$hl_psg_state" ] && [ "$HL_BS_COUNT" -gt 0 ]; then
			hl_psg_bs_line=$(printf '%s (%s %s)' "$HUB_BASELINE_LABEL" \
				"$HL_BS_COUNT" "$(hub_plural "$HL_BS_COUNT" item items)")
		fi
		[ -s "$HL_DOMAIN_TMP" ] || [ -n "$hl_psg_bs_line" ] || continue
		hl_psg_heading_once
		# Assigned, not inlined as the printf argument: hub_domain_label is a closed
		# lookup that dies on a key outside its set, and a swallowed die here leaves
		# a domain's whole block standing under an empty sub-header.
		hl_psg_label=$(hub_domain_label "$hl_psg_domain")
		printf '  %s\n' "$hl_psg_label"
		while IFS= read -r hl_psg_display; do
			[ -n "$hl_psg_display" ] || continue
			printf '    %s %s\n' "$hl_psg_glyph" "$hl_psg_display"
		done <"$HL_DOMAIN_TMP"
		[ -z "$hl_psg_bs_line" ] || printf '    %s %s\n' "$hl_psg_glyph" "$hl_psg_bs_line"
		hl_print_feature_hint "$hl_psg_domain"
	done
	hl_print_nondomain_groups "$hl_psg_state" "$hl_psg_glyph"
}

# hl_print_feature_hint DOMAIN -> the dimmed atomicity advisory under DOMAIN's
# feature lines, or nothing when this status group rendered none of them.
#
# DIMMED, never plain: it is secondary to the lines above it — the same treatment
# every advisory in this hub gets, through hub_dim (lib/hub-render.sh's
# HUB_DIM_COLOR). Indented to the ITEM TEXT column, two past the item indent, so
# it reads as an annotation on the lines above rather than as a third glyph-less
# item.
#
# GUARDED ON HL_FEAT_TMP, not on "does this domain declare features": a featured
# domain contributes lines to whichever status groups its features are actually in,
# and the hint must appear under each of those and under none of the others. It is
# guarded on the hint TEXT as well, so a future domain that declares features but
# no advisory prints no blank dimmed line.
hl_print_feature_hint() {
	[ -s "$HL_FEAT_TMP" ] || return 0
	hl_pfh_hint=$(hub_domain_feature_hint "$1")
	[ -n "$hl_pfh_hint" ] || return 0
	printf '      %s\n' "$(hub_dim "$hl_pfh_hint")"
}

# hl_print_nondomain_groups STATE GLYPH -> one sub-header plus its rows for every
# non-domain group holding a row in STATE, under the status heading the domain loop
# above may or may not have already written (hl_psg_heading_once owns that).
#
# Called from hl_print_status_group only, and AFTER its domain loop, so the
# registry's own domains keep the canonical order they have everywhere in this hub
# and the group that belongs to none of them lands last — the same placement
# lib/hub-discovery.sh gives it in the tables themselves ("cross-domain last") and
# the same placement hub-install.sh's result and preview screens give it.
#
# GROUPS IN FIRST-SEEN ORDER, taken from HL_NONDOMAIN itself, which inherits
# HUB_ROWS' canonical order — never awk's unspecified for-in order. Same shape
# hub-uninstall.sh's hu_cascade_items uses to list its own cascade groups.
#
# The heading is the GROUP's own label from the group table ("Cross-domain"), which
# is what hub-doctor.sh's hd_domain_heading falls back to for exactly this group,
# with the same group-key fallback for a label that somehow came back empty.
hl_print_nondomain_groups() {
	hl_png_state=$1
	hl_png_glyph=$2
	hl_png_groups="$HUB_WORK/nondomain-group-order.txt"
	hl_png_tmp="$HUB_WORK/nondomain-display.txt"
	awk -F '\t' '!($1 in seen) { seen[$1] = 1; print $1 }' "$HL_NONDOMAIN" >"$hl_png_groups"
	while IFS= read -r hl_png_group; do
		[ -n "$hl_png_group" ] || continue
		hl_png_group="$hl_png_group" hl_png_state="$hl_png_state" awk -F '\t' \
			'$1 == ENVIRON["hl_png_group"] && $3 == ENVIRON["hl_png_state"] { print $2 }' \
			"$HL_NONDOMAIN" >"$hl_png_tmp"
		[ -s "$hl_png_tmp" ] || continue
		hl_png_label=$(hub_group_field "$hl_png_group" 2)
		hl_psg_heading_once
		printf '  %s\n' "${hl_png_label:-$hl_png_group}"
		while IFS= read -r hl_png_display; do
			[ -n "$hl_png_display" ] || continue
			printf '    %s %s\n' "$hl_png_glyph" "$hl_png_display"
		done <"$hl_png_tmp"
	done <"$hl_png_groups"
}

case $OPT_FORMAT in
env)
	hub_env_kv HUB_STATUS ok
	hub_env_kv HUB_ACTION list
	hub_env_kv HUB_ROW_COUNT "$ROW_TOTAL"
	hub_env_kv HUB_ORPHANED_COUNT "$ORPHAN_COUNT"
	HL_N=0
	while IFS="$HUB_TAB" read -r HL_KEY HL_GROUP HL_DISPLAY HL_STATE; do
		[ -n "$HL_KEY" ] || continue
		HL_N=$((HL_N + 1))
		hub_env_kv "HUB_ITEM_${HL_N}_KEY" "$HL_KEY"
		hub_env_kv "HUB_ITEM_${HL_N}_DISPLAY" "$HL_DISPLAY"
		hub_env_kv "HUB_ITEM_${HL_N}_STATE" "$HL_STATE"
		hub_env_kv "HUB_ITEM_${HL_N}_GROUP" "$HL_GROUP"
	done <"$HUB_ROWS"
	while IFS="$HUB_TAB" read -r HL_KEY _; do
		[ -n "$HL_KEY" ] || continue
		HL_N=$((HL_N + 1))
		hub_env_kv "HUB_ITEM_${HL_N}_KEY" "$HL_KEY"
		hub_env_kv "HUB_ITEM_${HL_N}_DISPLAY" "$HL_KEY"
		hub_env_kv "HUB_ITEM_${HL_N}_STATE" ORPHANED
		hub_env_kv "HUB_ITEM_${HL_N}_GROUP" ''
	done <"$ORPHANS"
	;;
json)
	have jq || die "--format=json requires jq, which is not installed"
	HL_JSON="$(hub_mktemp_dir)/rows.json"
	: >"$HL_JSON"
	while IFS="$HUB_TAB" read -r HL_KEY HL_GROUP HL_DISPLAY HL_STATE; do
		[ -n "$HL_KEY" ] || continue
		jq -cn --arg key "$HL_KEY" --arg display "$HL_DISPLAY" \
			--arg state "$HL_STATE" --arg group "$HL_GROUP" \
			'{key:$key, display:$display, state:$state, group:$group}' >>"$HL_JSON"
	done <"$HUB_ROWS"
	while IFS="$HUB_TAB" read -r HL_KEY _; do
		[ -n "$HL_KEY" ] || continue
		jq -cn --arg key "$HL_KEY" \
			'{key:$key, display:$key, state:"ORPHANED", group:""}' >>"$HL_JSON"
	done <"$ORPHANS"
	jq -n --argjson row_count "$ROW_TOTAL" --argjson orphaned_count "$ORPHAN_COUNT" \
		--slurpfile items "$HL_JSON" \
		'{status:"ok", action:"list", row_count:$row_count, orphaned_count:$orphaned_count, items:$items}'
	;;
text)
	hub_print_header 'Components — discovered'

	if [ "$ROW_TOTAL" -eq 0 ] && [ "$ORPHAN_COUNT" -eq 0 ]; then
		printf '\n  (no components discovered in %s)\n' "$FRAMEWORK_ROOT"
		exit 0
	fi

	hl_buckets_build
	hl_selectable_rows_build
	hl_lens_rows_build
	hl_features_build
	hl_nondomain_rows_build

	hl_print_status_group Installed installed
	hl_print_status_group Available available
	hl_print_status_group Diverged DIVERGED

	if [ "$ORPHAN_COUNT" -gt 0 ]; then
		printf '\nOrphaned\n'
		while IFS="$HUB_TAB" read -r HL_KEY _; do
			[ -n "$HL_KEY" ] || continue
			printf '  %s %s\n' "$(hub_glyph_fail)" "$HL_KEY"
		done <"$ORPHANS"
	fi

	# The separating blank line belongs to the advisory BLOCK, not to its first
	# line: attaching it to the diverged advisory meant an orphan-only listing
	# (diverged count zero) printed its advisory flush against the last row.
	HL_DIVERGED_FILE="$HUB_WORK/diverged-rows.tsv"
	hl_rows_of_state DIVERGED >"$HL_DIVERGED_FILE"
	DIVERGED_ROWS=$(hub_count_lines "$HL_DIVERGED_FILE")
	if [ "$DIVERGED_ROWS" -gt 0 ] || [ "$ORPHAN_COUNT" -gt 0 ]; then
		printf '\n'
	fi
	if [ "$DIVERGED_ROWS" -gt 0 ]; then
		printf '  %s Diverged items re-sync the next time you run "Install" and choose them.\n' "$(hub_glyph_arrow)"
	fi
	if [ "$ORPHAN_COUNT" -gt 0 ]; then
		printf '  %s Orphaned items point at sources that no longer exist — run "Uninstall" and choose them to clear the stale links.\n' "$(hub_glyph_arrow)"
	fi

	if hub_interactive; then
		HL_PAUSE=0
		hub_press_key_to_continue || HL_PAUSE=$?
		[ "$HL_PAUSE" -ne 3 ] || exit 3
	fi
	;;
esac

exit 0
