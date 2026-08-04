#!/usr/bin/env sh
# lib/hub-state.sh — THE install-state computation, at every granularity the
#                     screens need: per unit, per group, per row, per domain, and
#                     per NAMED FEATURE (an arbitrary subset of one group's
#                     units — see hub_domain_feature_rows). Every screen reads
#                     these; none re-derives its own.
#
# Sourced after lib/hub-common.sh, lib/hub-domains.sh and lib/hub-discovery.sh.
# Not executable on its own.
#
# The unit vocabulary is the spec's three states, unchanged:
#   installed  — a symlink at the target resolving to exactly this unit's src.
#   DIVERGED   — something occupies the target path but is not that symlink: a
#                framework symlink pointing at a different source, a symlink
#                resolving outside the framework, or a real file/dir.
#   available  — nothing occupies the target path.
# Plus one state that belongs to the TARGET rather than to a discovered unit:
#   ORPHANED   — a symlink the hub put there whose name no longer appears in
#                discovery at all (its source was deleted or renamed). Distinct
#                from DIVERGED, where the name is still discoverable.
#
# Portability: POSIX sh only.

# ---------------------------------------------------------------------------
# Per-unit state.
# ---------------------------------------------------------------------------

# hub_target_path KIND NAME TARGET_DIR -> the deployed path for one unit. The
# single place the target layout (agents/<name>.md, skills/<name>) is written
# down; every read and every write goes through it.
hub_target_path() {
	case $1 in
	agent) printf '%s/agents/%s.md\n' "$3" "$2" ;;
	skill) printf '%s/skills/%s\n' "$3" "$2" ;;
	*) die "hub_target_path: unknown kind '$1'" ;;
	esac
}

# hub_state_set KIND NAME SRC TARGET_DIR -> sets HUB_STATE to installed |
# DIVERGED | available.
#
# Sets a global instead of printing, deliberately: the caller runs this once per
# discovered unit (80+ today, and every screen does it), and `$(...)` around it
# would fork a subshell per unit for no reason. There is no printing wrapper:
# one existed, had zero callers, and documented an API nothing used.
hub_state_set() {
	hss_tp=$(hub_target_path "$1" "$2" "$4")
	if [ -h "$hss_tp" ]; then
		# A FAILED readlink is classified explicitly, never folded into the
		# comparison below with an empty string: "we could not learn where this
		# link points" is not evidence that it points at SRC. The same reasoning is
		# load-bearing in hub_path_state, whose SRC can legitimately be empty.
		if ! hss_raw=$(hub_readlink_abs "$hss_tp"); then
			HUB_STATE=DIVERGED
		elif [ "$hss_raw" = "$3" ]; then
			HUB_STATE=installed
		else
			HUB_STATE=DIVERGED
		fi
	elif [ -e "$hss_tp" ]; then
		HUB_STATE=DIVERGED
	else
		HUB_STATE=available
	fi
}

# ---------------------------------------------------------------------------
# The states table — HUB_UNITS plus a state column, computed once per screen.
# ---------------------------------------------------------------------------

# hub_states_build TARGET_DIR -> sets HUB_STATES to a table of
# "group<TAB>name<TAB>kind<TAB>src<TAB>display<TAB>state", in HUB_UNITS' own
# canonical order.
hub_states_build() {
	hub_discovery_require
	hsb_target=$1
	HUB_STATES="$(hub_mktemp_dir)/states.tsv"
	: >"$HUB_STATES"
	while IFS="$HUB_TAB" read -r hsb_group hsb_name hsb_kind hsb_src hsb_display; do
		[ -n "$hsb_name" ] || continue
		hub_state_set "$hsb_kind" "$hsb_name" "$hsb_src" "$hsb_target"
		printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
			"$hsb_group" "$hsb_name" "$hsb_kind" "$hsb_src" "$hsb_display" "$HUB_STATE" >>"$HUB_STATES"
	done <"$HUB_UNITS"
	HUB_STATES_TARGET=$hsb_target
}

hub_states_require() {
	[ -n "${HUB_STATES:-}" ] || die "hub_states_require: state has not been built (call hub_states_build first)"
}

# hub_state_counts -> sets HUB_COUNT_INSTALLED / _DIVERGED / _AVAILABLE /
# _DISCOVERED from HUB_STATES. One computation, reused by the status block
# only — List and Doctor deliberately compute their own row-level totals from
# HUB_ROWS instead (a different but equally correct granularity: HUB_ROWS
# collapses an atomic/selectable group's units into one row).
hub_state_counts() {
	hub_states_require
	# Counted inside awk (END { print n + 0 }) rather than piped through
	# `wc -l | tr -d ' '`: same answer, two fewer processes per count, and no
	# BSD/GNU padding to strip.
	HUB_COUNT_INSTALLED=$(awk -F '\t' '$6 == "installed" { n++ } END { print n + 0 }' "$HUB_STATES")
	HUB_COUNT_DIVERGED=$(awk -F '\t' '$6 == "DIVERGED" { n++ } END { print n + 0 }' "$HUB_STATES")
	HUB_COUNT_AVAILABLE=$(awk -F '\t' '$6 == "available" { n++ } END { print n + 0 }' "$HUB_STATES")
	HUB_COUNT_DISCOVERED=$((HUB_COUNT_INSTALLED + HUB_COUNT_DIVERGED + HUB_COUNT_AVAILABLE))
}

# hub_group_state_rows GROUP -> "name<TAB>kind<TAB>src<TAB>display<TAB>state" for
# every unit of GROUP, in HUB_STATES' canonical order.
#
# The states table's counterpart to lib/hub-discovery.sh's hub_group_units (the
# same projection plus the state column), for a caller that has to classify a
# group's units by what is actually AT THE TARGET. Without it such a caller reads
# the discovery table and re-runs hub_state_set per unit — which is a second
# derivation of a state this table already holds, and re-stats every file to
# reach the same answer.
#
# Safe to read with `read`, unlike the group table: every column here is
# non-empty for a discovered unit — name is charset-validated, kind and state are
# hub-generated words, src came from find(1), and display is at least a
# sentence-cased name (see lib/hub-common.sh's "THE TAB TRAP").
hub_group_state_rows() {
	hub_states_require
	hgsr_group="$1" awk -F '\t' -v OFS='\t' \
		'$1 == ENVIRON["hgsr_group"] { print $2, $3, $4, $5, $6 }' "$HUB_STATES"
}

# ---------------------------------------------------------------------------
# Per-group and per-domain state.
# ---------------------------------------------------------------------------

# hub_group_state GROUP -> installed (every unit installed) | partial (some
# unit present, whether installed or diverged, but not all installed) |
# available (no unit present at all).
#
# "partial" exists because a group is an intent, not a file: a technology whose
# reviewer was hand-deleted, or a Jira backend that got two of its three skills,
# is neither honestly "installed" nor honestly "available", and the screens that
# report it must be able to say so rather than round in either direction.
hub_group_state() {
	hub_states_require
	hgs_group="$1" awk -F '\t' '
		$1 == ENVIRON["hgs_group"] {
			total++
			if ($6 == "installed") installed++
			else if ($6 == "DIVERGED") present++
		}
		END {
			if (total == 0) { print "available"; exit }
			if (installed == total) { print "installed"; exit }
			if (installed + present == 0) { print "available"; exit }
			print "partial"
		}
	' "$HUB_STATES"
}

# hub_group_display_state GROUP -> the group's state in the DISPLAY vocabulary
# every screen shares with a unit's own state: installed | available | DIVERGED.
#
# THE one mapping between the two vocabularies. hub_group_state above answers a
# question about the GROUP ("are all, some or none of its units present"), and
# `partial` is a truthful answer to that question — but no screen has a fourth
# column for it, and every screen resolves it the same way: a partly-present
# technology or backend reads DIVERGED, because "select it to re-sync" is exactly
# the right next action for it.
#
# Written by hand as `[ "$x" != partial ] || x=DIVERGED` at three sites before
# this existed — hub_rows_build just below, hub-list.sh's
# hl_selectable_rows_build and hub-install.sh's own preview bucketing — which is
# precisely how three copies of one mapping drift the day the vocabulary grows a
# fourth word. hub-install.sh's copy is GONE: its preview now reads the `state`
# column of hub_domain_buckets below, which is put there by this function.
# hub-uninstall.sh's was the fourth and is gone too: it carried the raw `partial`
# in its SELECTABLE_ROWS state column and re-spelled the resolution as a
# `partial -> "diverged"` map inside its checklist awk; that column is now built by
# THIS function, so every screen that has to render a partly-present group asks the
# same one place what to call it. NOTHING outside this file spells the mapping any
# more.
#
# Prints rather than setting a global, matching hub_group_state (which it wraps)
# and every other per-group accessor: this runs once per GROUP, not once per unit,
# so the subshell cost hub_state_set exists to avoid does not arise here.
hub_group_display_state() {
	hgds_state=$(hub_group_state "$1")
	[ "$hgds_state" != partial ] || hgds_state=DIVERGED
	printf '%s\n' "$hgds_state"
}

# hub_state_collapse KEYED KEY -> "state<TAB>count<TAB>pending": the collapsed
# DISPLAY state (installed | available | DIVERGED), the unit count, and how many of
# those units are NOT already installed — over the rows of KEYED, a
# "key<TAB>state" table, whose key is exactly KEY. Prints "available<TAB>0<TAB>0"
# when KEY matches nothing.
#
# PENDING IS PART OF THE SAME COLLAPSE, not a second concern bolted on: collapsing
# N unit states into one row necessarily loses how many of them a re-install would
# actually write, and a consumer that reports a count beside the collapsed row
# needs exactly that number or its count contradicts its own screen's totals. It
# costs one accumulator in the pass that is already running. Its consumer is
# hub-install.sh's preview, which weights a collapsed line by the units it stands
# for; hub-list.sh ignores it, since a listing reports what IS rather than what
# would be written.
#
# THE ONE PLACE THE COLLAPSE ARITHMETIC LIVES, for a caller that needs it over an
# ARBITRARY SUBSET of units rather than over a whole group. hub_group_state above
# answers for a GROUP and can only ever answer for a group: its awk filters
# HUB_STATES by the group column, so a caller that has to collapse some other
# slice — a domain's baseline MINUS its lens reviewers, or the two units that make
# up one of lib/hub-domains.sh's features — cannot ask it and had no choice but to
# re-derive. hub-list.sh's hl_baseline_summary was that caller and carried a
# hand-written copy of this arithmetic; it now projects its own slice to a
# "key<TAB>state" table and calls this, as does hub_domain_feature_rows below.
# The two subsets are unrelated, the arithmetic is not.
#
# The vocabulary is the DISPLAY one, resolved here rather than by the caller: this
# collapses several unit states into one, and `partial` — hub_group_state's own
# fourth word — has no column on any screen (see hub_group_display_state, which
# owns that resolution for a GROUP). Written out as the three-way END block rather
# than by calling that function, because there is no group to hand it.
#
# KEYED IS READ BY awk ALONE, never by `read`, which is what makes an arbitrary
# key safe: a key is compared with an exact field equality, so one containing a
# regex metacharacter cannot match a row it should not (the same reason
# hub_remove_row_by_key in lib/hub-common.sh is awk rather than grep).
hub_state_collapse() {
	hsc_key="$2" awk -F '\t' -v OFS='\t' '
		$1 == ENVIRON["hsc_key"] {
			total++
			if ($2 == "installed") installed++
			else if ($2 == "DIVERGED") present++
		}
		END {
			if (total == 0) { print "available", 0, 0; exit }
			if (installed == total) s = "installed"
			else if (installed + present == 0) s = "available"
			else s = "DIVERGED"
			print s, total, total - installed
		}
	' "$1"
}

# hub_feature_counts DOMAIN KEYFILE OUTFILE -> "count<TAB>label", one line per
# feature DOMAIN declares that KEYFILE actually mentions, in the REGISTRY's own
# order. KEYFILE is a one-feature-key-per-line file — whatever set of units the
# calling screen has in hand, already classified by hub_domain_feature_of. A feature
# with no line in KEYFILE is SKIPPED, not emitted at zero.
#
# THE PROJECTION SIDE OF THE SAME COIN hub_state_collapse above is the arithmetic
# side of, which is why it lives beside it rather than in the features section
# further down: both take an arbitrary keyed subset of units and reduce it for a
# renderer, and neither knows or cares which screen is asking.
# hub_domain_feature_rows (in that section) is the STATE projection over the units a
# feature HAS; this is the COUNT projection over units a screen has already selected
# — the diverged ones on hub-doctor.sh, the ones a run actually wrote on
# hub-install.sh's receipt, the ones cascading out on hub-uninstall.sh. All three
# had hand-rolled the identical registry walk, awk counter and label hoist verbatim.
#
# COUNTING AND CLASSIFICATION ONLY — no rendering. Doctor pairs each count with a
# singular/plural tail, Install with an "(N items)" annotation suppressed at one,
# Uninstall with a trailing cascade reason; those are per-screen and stay there. The
# same boundary hub_domain_feature_rows draws by leaving its residual label empty.
#
# ZERO IS SKIPPED HERE, deliberately unlike hub_domain_feature_rows, which emits a
# zero-count row: that function answers "what is the state of every feature this
# domain declares", where a feature with no units left is a real answer a listing
# guards on. This one answers "which features does THIS SET touch", where a feature
# the set never mentions has nothing to render — all three call sites carried the
# identical `-gt 0 || continue` guard.
#
# THE LABEL IS ASSIGNED before it is printed, never inlined as a printf argument:
# hub_domain_feature_label DIES on a key its domain does not declare, and a die
# inside a command substitution used as an ARGUMENT is swallowed — the substitution
# yields empty, printf still succeeds, and a nameless "(2 items)" row lands in
# OUTFILE for a consumer to render. The same hoisting hub_domain_feature_rows and
# hub_rows_build both state.
#
# COUNT FIRST, LABEL LAST, per lib/hub-common.sh's "THE TAB TRAP": OUTFILE is read
# with `read` and IFS=TAB by every consumer, and while neither column can be empty
# here (the count is generated, the label dies rather than come back blank), the
# label is still the one that would be a display bug rather than a crash.
hub_feature_counts() {
	hfc_domain=$1
	hfc_keyfile=$2
	hfc_out=$3
	: >"$hfc_out"
	# Assigned rather than iterated as `for … in $(…)`, the same shape
	# hub_domain_feature_rows uses, so the two registry walks read alike.
	hfc_keys=$(hub_domain_feature_keys "$hfc_domain")
	for hfc_key in $hfc_keys; do
		hfc_n=$(hfc_key="$hfc_key" awk \
			'$0 == ENVIRON["hfc_key"] { n++ } END { print n + 0 }' "$hfc_keyfile")
		[ "$hfc_n" -gt 0 ] || continue
		hfc_label=$(hub_domain_feature_label "$hfc_domain" "$hfc_key")
		printf '%s\t%s\n' "$hfc_n" "$hfc_label" >>"$hfc_out"
	done
}

# hub_domain_state DOMAIN -> the domain's own state, in hub_group_state's
# vocabulary (installed | partial | available), defined as the state of the content
# the domain installs UNCONDITIONALLY once it is chosen: its BASELINE group, or —
# for a domain that has none — its own selectable content
# (hub_domain_content_groups). A domain with its baseline in place but no
# technology/backend selected is still "installed"; the sub-selection detail is
# reported separately (hub_domain_detail).
#
# NOT `hub_group_key "$HUB_GROUP_PREFIX_BASELINE" "$1"` CONSTRUCTED BLIND, which is
# what this was: for a domain with no baseline group that names a row that does not
# exist, and hub_group_state answers `available` for a group with zero units. This
# function feeds the PUBLISHED HUB_DOMAIN_<n>_STATE field of --format=env|json (and
# the status screen's own glyph), so the blind construction published "not installed"
# for such a domain permanently, however much of it was actually at the target.
#
# THE MULTI-GROUP AGGREGATION exists because the `else` branch can legitimately
# return more than one group. It is hub_group_state's own three-way answer lifted one
# level: every group installed -> installed, none present at all -> available,
# anything in between -> partial. A `for` over an unquoted command substitution, the
# same shape hub_domain_detail below uses, so the counters live in this shell rather
# than in a pipeline subshell that would discard them (group keys hold no separator —
# see lib/hub-domains.sh's hub_sd_tech_key on the charset gate that guarantees it).
hub_domain_state() {
	hds_baseline=$(hub_domain_baseline_group "$1")
	if [ -n "$hds_baseline" ]; then
		hub_group_state "$hds_baseline"
		return 0
	fi
	hds_total=0
	hds_installed=0
	hds_absent=0
	for hds_group in $(hub_domain_content_groups "$1"); do
		hds_total=$((hds_total + 1))
		case $(hub_group_state "$hds_group") in
		installed) hds_installed=$((hds_installed + 1)) ;;
		available) hds_absent=$((hds_absent + 1)) ;;
		esac
	done
	if [ "$hds_total" -eq 0 ] || [ "$hds_absent" -eq "$hds_total" ]; then
		printf 'available\n'
	elif [ "$hds_installed" -eq "$hds_total" ]; then
		printf 'installed\n'
	else
		printf 'partial\n'
	fi
}

# hub_domain_detail DOMAIN -> the parenthetical the status block appends to a
# domain's line, or empty when the domain has no sub-selection (spec §7:
# "(2/9 technologies)", "(GitHub, Jira)").
#
# The backend arm joins the groups' own labels, which are BARE now ("GitHub", not
# "GitHub backend") — correct here without qualification, since the label this
# parenthetical is appended to is the domain's own.
hub_domain_detail() {
	hdd_domain=$1
	case $(hub_domain_selection_kind "$hdd_domain") in
	technology)
		hdd_total=0
		hdd_installed=0
		for hdd_group in $(hub_selectable_groups technology); do
			hdd_total=$((hdd_total + 1))
			[ "$(hub_group_state "$hdd_group")" = available ] || hdd_installed=$((hdd_installed + 1))
		done
		printf '(%s/%s %s)' "$hdd_installed" "$hdd_total" "$(hub_plural "$hdd_total" technology technologies)"
		;;
	pm-backend)
		hdd_labels=""
		for hdd_group in $(hub_selectable_groups pm-backend); do
			[ "$(hub_group_state "$hdd_group")" = available ] && continue
			hdd_labels=$(hub_join_append "$hdd_labels" "$(hub_group_field "$hdd_group" 2)" ', ')
		done
		# No fallback "(no backend)" text: a Project Management with zero
		# backends selected cannot actually be installed (the empty-selection
		# rule blocks confirming with none), so this branch is reached ONLY when
		# the domain itself is not installed at all — where printing anything
		# here duplicated "not installed" with a second, confusing claim about a
		# "backend" that was never really the subject. Same "nothing to say"
		# treatment as the `*)` arm below.
		[ -z "$hdd_labels" ] || printf '(%s)' "$hdd_labels"
		;;
	*) printf '' ;;
	esac
}

# ---------------------------------------------------------------------------
# The rows projection — the PER-UNIT table, read today by Doctor's
# diverged-components section and by List's env/json payload (plus
# hub-uninstall.sh's --components per-unit vocabulary and its --all expansion,
# both of which resolve a NAME against it rather than rendering it).
#
# It is NOT what any interactive CHECKLIST shows: each screen's checklist is its
# own, coarser projection over the same states — hub-list.sh's
# hl_selectable_rows_build, hub-uninstall.sh's SELECTABLE_ROWS — because a human
# picks a technology or a backend while Doctor has to be able to name "Security
# review lens" specifically. Both granularities are deliberate; this one is the
# fine-grained end.
# ---------------------------------------------------------------------------

# hub_rows_build -> sets HUB_ROWS to "rowkey<TAB>group<TAB>display<TAB>state",
# in canonical order, where an ATOMIC group collapses to exactly one row and
# every other group contributes one row per unit.
#
# An atomic row's state is the group's own aggregate state, mapped into the
# same three-word row vocabulary the rest of the table uses (a partly-present
# backend reads DIVERGED) — through hub_group_display_state, which owns that
# mapping for every screen, never a fourth hand-written copy of it here.
#
# Iterates GROUP KEYS (a single-column stream) and asks the group table for the
# atomic flag through hub_group_field, rather than `read`-ing that table's eight
# columns directly: it has legitimately empty middle columns, and `read` with
# IFS=TAB collapses them, which shifted `atomic` out of position in exactly the
# four non-selectable groups. See lib/hub-common.sh's "THE TAB TRAP".
hub_rows_build() {
	hub_states_require
	HUB_ROWS="$(hub_mktemp_dir)/rows.tsv"
	: >"$HUB_ROWS"
	hrb_keys="$(hub_mktemp_dir)/group-keys.txt"
	hub_group_keys >"$hrb_keys"
	while IFS= read -r hrb_group; do
		[ -n "$hrb_group" ] || continue
		hrb_atomic=$(hub_group_field "$hrb_group" 7)
		if [ "$hrb_atomic" = 1 ]; then
			hrb_state=$(hub_group_display_state "$hrb_group")
			# EVERY substitution assigned before the printf, never inlined as an
			# argument: hub_group_row_key DIES on a non-atomic group and
			# hub_group_field dies (via hub_discovery_require) on an unbuilt
			# discovery, and a die inside a command substitution used as an ARGUMENT
			# is swallowed — the substitution yields empty, printf still succeeds,
			# and a malformed row lands in HUB_ROWS. The atomic=1 guard above happens
			# to match hub_group_row_key's success condition today, and the
			# hub_states_require at the top happens to imply discovery is built, but
			# both invariants live in other files with nothing structurally enforcing
			# them, so let the exit status reach the shell.
			hrb_rowkey=$(hub_group_row_key "$hrb_group")
			hrb_label=$(hub_group_field "$hrb_group" 2)
			printf '%s\t%s\t%s\t%s\n' \
				"$hrb_rowkey" "$hrb_group" "$hrb_label" "$hrb_state" >>"$HUB_ROWS"
		else
			hrb_group="$hrb_group" awk -F '\t' -v OFS='\t' \
				'$1 == ENVIRON["hrb_group"] { print $2, $1, $5, $6 }' "$HUB_STATES" >>"$HUB_ROWS"
		fi
	done <"$hrb_keys"
}

# ---------------------------------------------------------------------------
# The bucket projection — the PER-DOMAIN table, at the granularity the SCREENS
# reason in rather than the granularity the filesystem has.
#
# HUB_ROWS above is the fine-grained end: one row per unit, every unit, no
# domain structure. This is the other end — for ONE domain, the four kinds of
# thing its screens actually talk about:
#
#   selectable  one row per technology / backend, at the group's own aggregate
#               display state. A technology is ONE thing a human picks (its
#               developer, reviewer and standard travel together), which is why
#               its two agent units are represented by this row and never
#               emitted individually.
#   standard    one row per per-technology standard skill, by unit.
#   lens        one row per lens reviewer agent, by unit.
#   baseline    one row per remaining baseline unit, by unit.
#
# TWO screens group by domain and need some subset of exactly this, and BOTH now
# consume it. hub-list.sh's hl_buckets_build materializes the stream once per
# screen and hl_selectable_rows_build / hl_lens_rows_build / hl_baseline_summary
# are three filters on its `bucket` column. hub-install.sh's hi_preview_domain
# calls this once per domain and its hi_bucket_add_row / hi_bucket_add_rows /
# hi_bucket_lookup are filters on the same two columns; the hand-rolled derivation
# it used to carry (a `partial`->DIVERGED mapping of its own, plus its own src-path
# lens/baseline split behind a `[ "$domain" = software-development ]` literal) is
# gone. The two screens differ in what they do with the stream, not in how it is
# derived — List groups by state, Install keeps only what is changing — so the
# derivation is shared here and the FILTERING stays each screen's own. There is
# deliberately no shared printer: the screens answer genuinely different questions
# and one renderer for them costs more than it saves.
#
# INSTALL'S RESULT SCREEN IS NOT A CONSUMER, and cannot become one: it reports what
# one apply run actually WROTE, and this table is a projection of HUB_STATES as it
# was BEFORE those writes (re-deriving it after would read `installed` for every
# unit, touched or not). It groups by the plan's own group column instead — see
# hub-install.sh's "Result blocks" section.
#
# DOCTOR IS NOT A BUCKET CONSUMER, and must not be turned into one. Its
# diverged-components section has to name a technology's INDIVIDUAL agents
# ("Python agent developer" specifically, when only its reviewer diverged), and
# this table structurally cannot say that: a technology is ONE collapsed
# `selectable` row at the GROUP's aggregate state, by design (see the bucket list
# above). Doctor therefore stays on HUB_ROWS, which is unit-level — the same
# reason the group table's `atomic` column deliberately leaves a technology
# non-atomic (see lib/hub-domains.sh's "WHICH GROUPS ARE ATOMIC"). If Doctor's
# presentation is ever refactored, the primitives to reach for are
# hub_group_display_state and hub_src_in_dir applied to HUB_ROWS-derived data, NOT
# a switch of its data source to this function.
# ---------------------------------------------------------------------------

# hub_domain_buckets DOMAIN OUTFILE -> one
# "bucket<TAB>groupkey<TAB>state<TAB>display" row per thing DOMAIN's screens can
# name, in canonical order: each selectable group followed by its own standards,
# then the domain's baseline units in HUB_STATES' canonical order, each tagged
# `lens` or `baseline`.
#
# THE BASELINE IS ONE PASS, so lens rows are INTERLEAVED among plain baseline rows
# rather than grouped ahead of them — and the ONLY ordering guarantee this function
# makes about the baseline section is HUB_STATES' own. That is a deliberate choice,
# not an accident of the loop: grouping in the STREAM would buy nothing, because
# every consumer has to select a bucket before it renders anything anyway, and
# selecting `bucket == lens` yields the lenses together for free. Emitting them
# grouped would instead mean walking the same baseline unit list twice. A consumer
# that needs the lenses adjacent must therefore filter or sort on the `bucket`
# column and must NOT rely on the raw row order to do it for them.
#
# BUCKET is the closed set selectable | standard | lens | baseline. STATE is
# always the DISPLAY vocabulary (installed | available | DIVERGED) — a unit's own
# state already is, and a selectable group's aggregate is put there by
# hub_group_display_state, so no consumer has to remember which of the two
# vocabularies a given row speaks.
#
# COLUMN ORDER, per lib/hub-common.sh's "THE TAB TRAP": bucket, groupkey and
# state are hub-generated words that can never be empty, so none of them can
# collapse under `read`. Display goes LAST because it is the only column whose
# emptiness is POSSIBLE — which is exactly why it is placed there, on the same
# reasoning SELECTABLE_ROWS states in hub-uninstall.sh. A unit display is at least
# a sentence-cased name (the charset guarantees a non-empty name), and a GROUP
# label is now equally safe but by a DIFFERENT guarantee, which is why it still
# goes last: a technology key comes from stripping a role suffix off a developer
# agent's basename, and lib/hub-domains.sh's hub_sd_tech_key gates that derived key
# on HUB_NAME_CHARSET_RE, so a file named exactly `-developer.md` is now skipped at
# discovery rather than yielding an empty key and hence an empty label. That gate
# lives in another file and protects one of the four group kinds; being last is
# what keeps this column harmless if some future group kind ever labels itself
# from a source this hub does not gate.
#
# ZERO HARDCODED NAMES, including the two SPLITS that look domain-specific:
#   * WHICH GROUPS ARE SELECTABLE comes from the group table's own role+domain
#     columns (hub_domain_selectable_groups), and WHETHER THERE IS A BASELINE AT ALL
#     from hub_domain_baseline_group — so a domain that is its own single selectable
#     group (GTD) contributes exactly one `selectable` row, no `standard` rows and no
#     `baseline` rows, with no test for it here. A CONSUMER THAT RENDERS PER DOMAIN
#     MUST THEREFORE NOT ASSUME the `selectable` bucket means "a technology or a
#     backend": for a domain that declares features, the feature projection below
#     already reports that same content by name, and hub-list.sh suppresses the
#     duplicate row for exactly that reason.
#   * WHICH BASELINE UNITS ARE LENSES is the src-path test, and ONLY the
#     src-path test (hub_src_in_dir against HUB_SD_DIR_LENS_REVIEWERS) — the same
#     classification hub-list.sh's hl_lens_rows_build and hub-install.sh's preview
#     bucketing each applied by hand before both moved onto this stream. Both
#     paired it with a `[ "$domain" = software-development ]` guard; that guard was
#     REDUNDANT rather than load-bearing, since Software Development's tree is the
#     only one carrying that subtree, so the domain literal is not copied into a
#     file that has none. If a second domain ever grows lens reviewers, itemizing
#     them instead of folding them into an anonymous baseline count is the right
#     behavior anyway — which is exactly what made the guard safe to drop rather
#     than merely unnecessary.
#
# The SHARED cross-domain group is not here, and that is not an omission: it
# belongs to no domain (its whole point is that two of them pull it in), it is
# installed once and removed on the retention rule above, and every screen
# already prints it as its own block outside the per-domain loop.
#
# VARIABLE PREFIX: hdbk_, not hdb_. POSIX sh has no `local`, so a per-function
# prefix IS the scoping mechanism in this codebase, and hdb_ is already
# lib/hub-discovery.sh's hub_discovery_build — where hdb_src means the FRAMEWORK
# SOURCE ROOT, not one unit's src path. Two functions sharing a prefix with
# different meanings for the same name is how a caller/callee pair silently
# clobbers the other's state.
#
# ===========================================================================
# NON-RE-ENTRANCY CONTRACT — this function must not be called from inside a
# loop that is reading either of its own two scratch files, or OUTFILE.
# ===========================================================================
# HUB_BUCKETS_DIR is a PROCESS-WIDE cache (created once, deliberately — see the
# scratch-directory note in the body) and the two files under it,
# groups.txt / units.tsv, are FIXED PATHS rewritten in place on every call. Both
# are also read back by `done <"$file"` redirects inside this very function, and a
# POSIX sh redirect holds an open descriptor on the file it was opened from — so a
# nested call that truncates and rewrites the same path while an outer loop is
# still reading it hands that outer loop a torn or empty stream, with no error
# anywhere. OUTFILE has the same shape from the caller's side: both consumers pass
# a fixed path (hub-list.sh's HL_BUCKETS via hl_bb_tmp, hub-install.sh's
# HI_BUCKETS), so a nested call would rewrite the table its caller is mid-way
# through filtering.
#
# TODAY'S CALLERS ARE SAFE BY SHAPE, NOT BY LUCK, and this contract is what keeps
# them that way: every one of them drives this function from a plain `for` loop
# over a domain list (hub-list.sh's hl_buckets_build over HUB_DOMAIN_KEYS,
# hub-install.sh's hi_preview's domain loop, which walks one domain fully through
# hi_preview_domain before starting the next). A `for` over an already-materialized
# word list holds no descriptor and reads no file, so one domain's call cannot
# overlap the next one's. A future caller that wants this per-domain table INSIDE a
# `while read` over a bucket stream must either copy the stream it is iterating to
# a path of its own first, or take a per-call hub_mktemp_dir instead of the shared
# HUB_BUCKETS_DIR — it must NOT simply nest. The same top-level-only discipline
# lib/hub-discovery.sh states for hub_disc_begin_group, for the same class of
# reason.
hub_domain_buckets() {
	hdbk_domain=$1
	hdbk_out=$2
	hub_states_require
	: >"$hdbk_out"

	# The scratch directory is created ONCE per process, not per call, for the
	# reason hub_shared_consumers_remaining states below: this is called once per
	# domain and potentially once per domain PER STATUS GROUP by a screen that
	# re-derives per section, and a fresh hub_mktemp_dir each time would leave one
	# directory per call behind for the lifetime of the workspace.
	if [ -z "${HUB_BUCKETS_DIR:-}" ]; then
		HUB_BUCKETS_DIR=$(hub_mktemp_dir)
	fi
	hdbk_groups="$HUB_BUCKETS_DIR/groups.txt"
	hdbk_units="$HUB_BUCKETS_DIR/units.tsv"

	hub_domain_selectable_groups "$hdbk_domain" >"$hdbk_groups"
	while IFS= read -r hdbk_group; do
		[ -n "$hdbk_group" ] || continue
		# BOTH assigned before the printf, never inlined as arguments — the same
		# hazard hub_rows_build states above: hub_group_display_state wraps
		# hub_group_state, which calls hub_states_require and DIES when the states
		# table is unbuilt, and hub_group_field calls hub_discovery_require which
		# dies the same way. A die inside a command substitution used as a printf
		# ARGUMENT is swallowed — the substitution yields empty, printf still
		# succeeds, and a malformed row lands in OUTFILE. The hub_states_require
		# above happens to cover the first of the two today, but that is one guard
		# in this function standing in for a contract enforced in two others.
		hdbk_state=$(hub_group_display_state "$hdbk_group")
		hdbk_label=$(hub_group_field "$hdbk_group" 2)
		printf '%s\t%s\t%s\t%s\n' selectable "$hdbk_group" \
			"$hdbk_state" "$hdbk_label" >>"$hdbk_out"
		# The group's own per-technology standard, by unit and at its own unit
		# state — NOT at the group's aggregate above. The two can legitimately
		# disagree (a technology whose standard alone is diverged is `partial` as a
		# group), and both facts are wanted: the aggregate is what a human picks,
		# the unit state is what a standards line reports.
		hub_group_state_rows "$hdbk_group" >"$hdbk_units"
		while IFS="$HUB_TAB" read -r _ _ hdbk_src hdbk_display hdbk_unit_state; do
			[ -n "$hdbk_src" ] || continue
			hub_src_in_dir "$hdbk_src" "$HUB_SD_DIR_SHARED_TECH_STANDARDS" || continue
			printf '%s\t%s\t%s\t%s\n' standard "$hdbk_group" "$hdbk_unit_state" "$hdbk_display" >>"$hdbk_out"
		done <"$hdbk_units"
	done <"$hdbk_groups"

	# THE ACCESSOR, never a constructed `baseline:<domain>`: a domain that has no
	# baseline group contributes no baseline rows at all, and the honest way to say
	# that is to ask. Constructing the key instead named a nonexistent group, whose
	# state rows are empty — the same zero rows, reached by accident rather than on
	# purpose, and only because hub_group_state_rows happens to match nothing.
	hdbk_baseline=$(hub_domain_baseline_group "$hdbk_domain")
	[ -n "$hdbk_baseline" ] || return 0
	hub_group_state_rows "$hdbk_baseline" >"$hdbk_units"
	while IFS="$HUB_TAB" read -r _ _ hdbk_src hdbk_display hdbk_unit_state; do
		[ -n "$hdbk_src" ] || continue
		# An `if`, never `hub_src_in_dir … && hdbk_bucket=lens || hdbk_bucket=baseline`:
		# a predicate returning 1 as the last command of a loop body trips the
		# caller's `set -e`, and the baseline arm is the common case.
		if hub_src_in_dir "$hdbk_src" "$HUB_SD_DIR_LENS_REVIEWERS"; then
			hdbk_bucket=lens
		else
			hdbk_bucket=baseline
		fi
		printf '%s\t%s\t%s\t%s\n' "$hdbk_bucket" "$hdbk_baseline" "$hdbk_unit_state" "$hdbk_display" >>"$hdbk_out"
	done <"$hdbk_units"
}

# ---------------------------------------------------------------------------
# The FEATURE projection — one row per NAMED FEATURE of a domain that declares
# any, at that feature's own collapsed state.
#
# lib/hub-domains.sh §4b owns what a feature IS and why exactly one domain has
# them; this owns computing their STATE. It is a third granularity beside
# HUB_ROWS (per unit) and hub_domain_buckets (per thing a domain's screens name),
# and it exists because neither of those can express it: a feature is a SUBSET of
# one group's units, and both of those tables key state to a whole group or to a
# single unit.
# ---------------------------------------------------------------------------

# hub_domain_feature_rows DOMAIN OUTFILE -> "state<TAB>count<TAB>pending<TAB>label",
# one row per feature DOMAIN declares (in the registry's own order) PLUS one final
# RESIDUAL row for the content units no feature claims. Writes an EMPTY OUTFILE
# for a domain that declares no features, which is every domain but GTD today —
# and which is the test every consumer uses to decide between its feature path
# and its ordinary collapsed-baseline path.
#
# COUNT vs PENDING: count is how many units the feature HAS, pending how many of
# them are not already installed. A listing wants the first, a dry run wants the
# second — see hub_state_collapse, which computes both in one pass and states why.
#
# THE RESIDUAL ROW carries an EMPTY LABEL, deliberately, and is what makes this
# projection exhaustive over the domain's content: only the calling screen knows
# what to call an anonymous remainder ("Framework baseline (N items)" on List and
# Doctor, "new baseline (N items)" on Install's preview), so the label is left for
# it to supply. Every other consumer contract in this hub would have the
# nullable column last for the reason lib/hub-common.sh's "THE TAB TRAP" gives,
# and it is last here too: state and count are hub-generated and can never be
# empty, so a `read` with IFS=TAB cannot shift.
#
# A ZERO-COUNT ROW IS STILL EMITTED — for a feature whose units are all gone from
# the source, and for the residual in the normal case where every unit is claimed.
# Consumers guard on the count, exactly as hub-list.sh already guards its
# collapsed baseline line on `HL_BS_COUNT -gt 0`; suppressing them here would make
# "the registry declares this feature" and "this screen mentions it" two different
# questions answered in two places.
#
# LENS REVIEWERS ARE EXCLUDED before classification, so a featured domain that
# ever grew them keeps them itemized by name (which every screen does for a lens)
# instead of silently folding them into a feature or into the residual. The test is
# hub_src_in_dir, the canonical spelling, the same call hub_domain_buckets makes
# for the same split. GTD's tree carries no such subtree today, so this is
# forward-looking rather than load-bearing — stated because it is not obvious that
# a positive path test for `agents/` would otherwise claim
# `agents/reviewers/lens/*` as a capture feature.
#
# NON-RE-ENTRANCY CONTRACT, identical in shape and reason to hub_domain_buckets'
# above: HUB_FEATURES_DIR is a process-wide cache and the three files under it are
# FIXED PATHS rewritten in place per call, two of which are read back by a
# `done <"$file"` redirect inside this very function. A nested call that rewrites
# those paths while an outer loop still holds a descriptor on one hands that loop a
# torn stream with no error anywhere. Today's callers drive this from a plain `for`
# over a domain list, or once per domain before rendering, so none of them can
# overlap; a future caller that wants this table INSIDE a `while read` over its own
# output must copy that output to a path of its own first.
hub_domain_feature_rows() {
	hdfr_domain=$1
	hdfr_out=$2
	# REQUIRED FIRST, before the "does this domain declare features" shortcut below,
	# even though the empty-features path reads no state at all. A contract that
	# holds only for some arguments is not a contract: a caller that forgot
	# hub_states_build would get a clean empty file for Software Development and a
	# die for GTD, which is a bug that only shows up on one domain.
	hub_states_require
	: >"$hdfr_out"
	hdfr_keys=$(hub_domain_feature_keys "$hdfr_domain")
	[ -n "$hdfr_keys" ] || return 0

	# Created ONCE per process, for the reason hub_domain_buckets gives: this runs
	# once per domain and, on a screen that renders per status group, once per
	# domain per group — a fresh hub_mktemp_dir each time would leave one directory
	# per call behind for the lifetime of the workspace.
	if [ -z "${HUB_FEATURES_DIR:-}" ]; then
		HUB_FEATURES_DIR=$(hub_mktemp_dir)
	fi
	hdfr_units="$HUB_FEATURES_DIR/units.tsv"
	hdfr_keyed="$HUB_FEATURES_DIR/keyed.tsv"
	hdfr_groups="$HUB_FEATURES_DIR/groups.txt"

	# THE UNITS COME FROM hub_domain_content_groups, not from a constructed
	# `baseline:<domain>`: features partition the content a domain installs
	# unconditionally, and for a domain that has no baseline group that content lives
	# in its own selectable group instead (see that accessor). Hardcoding the baseline
	# key here made the whole projection silently EMPTY for such a domain — which is
	# the test every consumer uses to choose its no-features path, so all of them
	# would have quietly fallen back to one anonymous collapsed line.
	#
	# Concatenated rather than one group per pass: a feature is a subset of the
	# domain's content, and which group each unit came from is not part of the
	# classification (hub_domain_feature_of reads the src path alone).
	hub_domain_content_groups "$hdfr_domain" >"$hdfr_groups"
	: >"$hdfr_units"
	while IFS= read -r hdfr_group; do
		[ -n "$hdfr_group" ] || continue
		hub_group_state_rows "$hdfr_group" >>"$hdfr_units"
	done <"$hdfr_groups"
	: >"$hdfr_keyed"
	while IFS="$HUB_TAB" read -r _ _ hdfr_src _ hdfr_state; do
		[ -n "$hdfr_src" ] || continue
		# An `if`, never `hub_src_in_dir … && continue`: a predicate returning 1 as
		# the last command of a loop body trips the caller's `set -e`, and the
		# not-a-lens arm is the common case. Same shape the baseline walk above uses.
		if hub_src_in_dir "$hdfr_src" "$HUB_SD_DIR_LENS_REVIEWERS"; then
			continue
		fi
		hdfr_key=$(hub_domain_feature_of "$hdfr_domain" "$hdfr_src")
		[ -n "$hdfr_key" ] || hdfr_key=$HUB_FEATURE_RESIDUAL_KEY
		printf '%s\t%s\n' "$hdfr_key" "$hdfr_state" >>"$hdfr_keyed"
	done <"$hdfr_units"

	for hdfr_key in $hdfr_keys; do
		# BOTH assigned before the printf, never inlined as arguments:
		# hub_domain_feature_label DIES on a key its domain does not declare, and a
		# die inside a command substitution used as an ARGUMENT is swallowed — the
		# substitution yields empty, printf still succeeds, and a nameless row lands
		# in OUTFILE, which a consumer would then render as a bare glyph. The same
		# hazard hub_rows_build and hub_domain_buckets both state.
		hdfr_collapsed=$(hub_state_collapse "$hdfr_keyed" "$hdfr_key")
		hdfr_label=$(hub_domain_feature_label "$hdfr_domain" "$hdfr_key")
		printf '%s\t%s\n' "$hdfr_collapsed" "$hdfr_label" >>"$hdfr_out"
	done
	hdfr_collapsed=$(hub_state_collapse "$hdfr_keyed" "$HUB_FEATURE_RESIDUAL_KEY")
	printf '%s\t\n' "$hdfr_collapsed" >>"$hdfr_out"
}

# ---------------------------------------------------------------------------
# The retention rule — "would this group still be there afterwards".
# ---------------------------------------------------------------------------

# hub_group_remains_present GROUP REMOVAL_UNITS -> exit 0 when GROUP would STILL
# have at least one PRESENT unit once the units listed in REMOVAL_UNITS (column 1
# = unit name) come out, i.e. the group keeps a live footprint at the target.
#
# THE one place "does this group survive this removal" is decided, and both
# directions of the retention rule ask it: the cross-domain consumer test below,
# and hub-uninstall.sh's per-domain baseline cascade (a domain's baseline comes
# out once none of its own selectable groups survives). Two copies of this awk
# is exactly how the two would drift apart.
#
# A per-UNIT test, deliberately: a group being partially dismantled in the same
# action is judged on what will actually be left, not on what was there when the
# screen was drawn.
#
# "PRESENT" IS `$6 != "available"` — installed OR DIVERGED — and that width is the
# whole point of the name. It is deliberately the SAME test every screen's own
# checklist projection applies when it decides a group is still there and still
# offerable (hub_group_state != available, i.e. `installed` or `partial`; see
# hub-uninstall.sh's SELECTABLE_ROWS and hub-list.sh's hl_selectable_rows_build).
# A stricter `$6 == "installed"` made the two disagree, and the disagreement was
# visible on screen: a domain holding one healthy technology and one fully
# DIVERGED one, asked to remove only the healthy one, cascaded its baseline out
# under the message "nothing installed requires it any more" — while the diverged
# technology's files sat right there at the target, still listed as removable on
# the very checklist that had just been drawn, and needing that baseline the
# moment the user went to Install to repair them. A unit that occupies its path is
# a footprint that has to be reasoned about, whatever it currently points at.
#
# The width also makes both directions of the rule more CONSERVATIVE, which is the
# correct bias for a destructive action: a present-but-diverged consumer now holds
# a shared unit back (KEPT) and stops it cascading out, rather than the reverse.
#
# FNR == NR is NOT sufficient on its own to mean "still reading the first file":
# when the first file is EMPTY, awk never reads a record from it, so the second
# file's first record also satisfies FNR == NR and would be mis-filed as a
# removal entry. Anchoring on FILENAME == ARGV[1] as well makes the phase test
# say what it means. (An empty removal set is a legitimate state, so this is
# reachable, not theoretical.)
hub_group_remains_present() {
	hub_states_require
	hgrp_left=$(hgrp_group="$1" awk -F '\t' '
		FNR == NR && FILENAME == ARGV[1] { removing[$1] = 1; next }
		$1 == ENVIRON["hgrp_group"] && $6 != "available" && !($2 in removing) { print 1; exit }
	' "$2" "$HUB_STATES")
	[ -n "$hgrp_left" ]
}

# hub_shared_consumers_remaining GROUP REMOVAL_UNITS -> one consumer group key
# per line for every consumer of the shared GROUP that would STILL be present
# after the units listed in REMOVAL_UNITS (column 1 = unit name) come out. Empty
# output means the shared group has no consumer left and may be removed.
#
# This is the whole cross-domain rule: accounts/'s git-auth procedure is pulled
# in once by Software Development's baseline and once by Project Management's
# GitHub backend, deduplicated on install, and removed on uninstall only when
# NEITHER consumer remains. Whether a consumer "remains" is
# hub_group_remains_present's answer, above — the same predicate the per-domain
# baseline cascade uses, so the two cannot disagree about what "still there after
# this removal" means.
hub_shared_consumers_remaining() {
	hscr_group=$1
	hscr_removal=$2
	# MATERIALIZED to a file, then read with a redirect — never
	# `hub_shared_consumers … | while read`. POSIX sh has no `pipefail`, so a
	# pipeline reports only its LAST command's status: a hub_shared_consumers that
	# DIED (it dies by contract on an unknown shared group) would hand the loop an
	# empty stream, the loop would succeed, and this function would report "no
	# consumer remains" — flipping the caller straight to the CASCADE branch and
	# removing a shared unit on the strength of an error nobody saw. With the
	# redirect the producer's own failure reaches the shell before the loop runs.
	# The other two consumers of hub_shared_consumers (hub-uninstall.sh's
	# HU_CONSUMER_NOTES, hub-doctor.sh's GitHub-consumer scan) already do it this
	# way; this was the last one that did not.
	#
	# The scratch path is created ONCE per process, not per call: this runs inside a
	# loop over the shared groups, and a fresh hub_mktemp_dir each time would leave
	# one directory per group behind for the lifetime of the workspace.
	if [ -z "${HUB_SHARED_REMAINING_FILE:-}" ]; then
		HUB_SHARED_REMAINING_FILE="$(hub_mktemp_dir)/shared-consumers.tsv"
	fi
	hub_shared_consumers "$hscr_group" >"$HUB_SHARED_REMAINING_FILE"
	while IFS="$HUB_TAB" read -r hscr_consumer _; do
		[ -n "$hscr_consumer" ] || continue
		# An `if`, not `hub_group_remains_present … && printf …`: the AND-list's own
		# non-zero status would be the last command of this loop body and would trip
		# the caller's `set -e` on every consumer that is NOT remaining, which is the
		# common case.
		if hub_group_remains_present "$hscr_consumer" "$hscr_removal"; then
			printf '%s\n' "$hscr_consumer"
		fi
	done <"$HUB_SHARED_REMAINING_FILE"
}

# ---------------------------------------------------------------------------
# Orphan detection.
# ---------------------------------------------------------------------------

# hub_orphaned_units TARGET_DIR -> "name<TAB>kind" for every symlink the hub
# placed under TARGET_DIR/agents or TARGET_DIR/skills whose name no longer
# appears anywhere in discovery.
#
# Deliberately `-type l`, never an existence test: the whole point is to also
# find a DANGLING symlink whose source vanished, which an existence-based scan
# would silently skip — exactly the case this exists to catch. A non-symlink
# entry is never reported: the hub only ever creates symlinks, so anything else
# is a foreign file, which is a different (already-guarded) concern.
#
# Zero hardcoded names: both sides are generic scans, so adding, removing,
# renaming or relocating any artifact anywhere is picked up with no code change.
hub_orphaned_units() {
	hub_discovery_require
	hou_target=$1
	hou_known="$(hub_mktemp_dir)/known-names.txt"
	awk -F '\t' '{ print $2 }' "$HUB_UNITS" | LC_ALL=C sort -u >"$hou_known"
	# awk, never sed, for the "basename<TAB>kind" transform. `\t` in a sed
	# REPLACEMENT is a GNU extension: BSD/macOS sed emits a literal backslash-t
	# instead of a TAB, which collapsed both columns into one token
	# ("python-developertagent"), left the kind column empty, and made the
	# grep -qxF known-name test below fail for EVERY row — reporting the entire
	# installed set as orphaned on the hub's primary platform. awk's `"\t"` inside
	# a string is specified by POSIX and behaves identically on both userlands.
	{
		find "$hou_target/agents" -maxdepth 1 -type l -name '*.md' 2>/dev/null |
			awk -v kind=agent '{ name = $0; sub(/.*\//, "", name); sub(/\.md$/, "", name); print name "\t" kind }'
		find "$hou_target/skills" -maxdepth 1 -type l 2>/dev/null |
			awk -v kind=skill '{ name = $0; sub(/.*\//, "", name); print name "\t" kind }'
	} | LC_ALL=C sort -u | while IFS="$HUB_TAB" read -r hou_name hou_kind; do
		[ -n "$hou_name" ] || continue
		grep -qxF -- "$hou_name" "$hou_known" || printf '%s\t%s\n' "$hou_name" "$hou_kind"
	done
}
