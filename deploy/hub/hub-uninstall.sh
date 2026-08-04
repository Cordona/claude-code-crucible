#!/usr/bin/env sh
# hub-uninstall.sh — Capability: uninstall, selective and complete. One script,
#                     for the same reason install is one script: "uninstall all"
#                     is the select-everything case of the same pipeline, not a
#                     second feature.
#
# Usage:
#   hub-uninstall.sh [--components=a,b | --all] [--apply] [--non-interactive]
#                    [--confirm=UNINSTALL] [--restore-backup=TIMESTAMP|none]
#                    [--accessible] [--details] [--target DIR] [--source DIR]
#                    [--format=text|env|json] [--no-color] [-h|--help]
#
#   --components CSV      Remove exactly these components, named by the SAME
#                          SELECTION keys the interactive checklist shows and
#                          accepts: one token per TECHNOLOGY (its developer,
#                          reviewer and standard always travel together), per
#                          Project Management BACKEND (whose skills likewise do),
#                          or per SELF-CONTAINED DOMAIN — one whose whole footprint
#                          is a single removable thing, named by its domain key
#                          (today: gtd). HUB_ROWS' per-unit keys — the ones List
#                          and Doctor name, e.g. "java-reviewer" — are still
#                          accepted, so anything already scripted against them
#                          keeps working; a per-unit key belonging to any of the
#                          three now resolves to that whole thing rather than to
#                          the one unit, because the bundle is what a human
#                          installs and removes. Mutually exclusive with --all.
#   --all                 Remove everything installed, plus CLAUDE.md and the
#                          contract schemas. The one critical-tier flow.
#   --confirm=UNINSTALL   Required alongside --apply --all when there is no
#                          terminal to confirm at (on a TTY, the typed-phrase
#                          prompt substitutes). Absent under --non-interactive,
#                          the command fails loud rather than assuming consent.
#   --restore-backup TS   --all only: restore the CLAUDE.md.backup.* stamped TS,
#                          or, with "none", restore nothing at all. HONOURED
#                          WHATEVER THE BACKUP COUNT IS — it used to be read only
#                          when more than one backup existed, so "none" alongside
#                          exactly one backup was silently ignored and that backup
#                          was restored (and consumed) anyway. A TS matching no
#                          existing backup is a usage error, not a no-op. Absent,
#                          one backup restores itself and several prompt (or block,
#                          with --non-interactive).
#   --apply               Perform the writes. Absent: preview only — on EVERY
#                          path, including a TTY. A flag-driven selection without
#                          --apply prints its preview and stops there, never
#                          reaching the confirm prompt. Only the pure interactive
#                          checklist walk confirms-then-writes.
#   --non-interactive     Never prompt; requires --components or --all.
#   --accessible          Render the ASCII fallback for every non-ASCII SYMBOL:
#                          glyphs, hint/list separators and the truncation
#                          ellipsis. Em-dashes inside free prose message text are
#                          deliberately left as-is (see lib/hub-render.sh's
#                          HUB_ASCII note). Opt-in only, never auto-detected.
#   --details             Result screen: itemize instead of summarizing. Only a
#                          BULK (--all) result summarizes by default; a SELECTIVE
#                          result always itemizes, so this flag changes nothing
#                          there.
#   --target/--source/--format/--no-color/-h  as elsewhere.
#
# WHAT THIS CAPABILITY OFFERS AS SELECTABLE, and why it is not HUB_ROWS:
#   Every SELECTABLE group is offered, and nothing else — one row per TECHNOLOGY,
#   one per PROJECT MANAGEMENT BACKEND, and one per SELF-CONTAINED DOMAIN (a domain
#   whose whole footprint is its one group; today, GTD). No baseline unit, no review
#   lens, no flow, specialist or facade appears on the checklist at all. A
#   technology is ONE removable thing whose developer/reviewer/standard travel
#   together, the same way a backend's skills already did — and a self-contained
#   domain is one removable thing for the same reason, at domain scale.
#
#   hub_rows_build/HUB_ROWS is deliberately NOT the source of that list, and is
#   left exactly as it was: its full per-unit granularity is what Doctor's
#   diverged-components section needs ("Security review lens", specifically, not
#   "Software Development") and what List reports. It is still what --components'
#   per-unit vocabulary and --all resolve against. The checklist reads
#   SELECTABLE_ROWS instead (see its own section below).
#
# THE DOMAIN BASELINE RULE — the CASCADE direction below, scoped to ONE domain:
#   A domain's baseline (for Software Development, that includes its review
#   lenses — they are part of the baseline bundle, not a separate concept) is
#   never individually selectable and never individually removable. It comes out
#   by CASCADE, once the removal leaves that domain with ZERO PRESENT
#   technologies/backends, and is announced in the same "Also removing" block as
#   the cross-domain cascade below — because it IS that rule, with a different
#   consumer set: the domain's own selectable groups instead of a cross-domain
#   registry list. Its trigger is the same deliberately WIDE condition (see the
#   paragraph at the end of this block): "nothing installed needs it any more",
#   not "this removal takes its last consumer".
#
#   "PRESENT", not "installed": a DIVERGED technology counts as still needing its
#   domain's baseline. It is exactly the test the checklist itself applies when it
#   decides that technology is still offerable, and the two must agree — otherwise
#   the baseline cascades out under "nothing installed requires it any more" while
#   a diverged technology's files sit right there at the target, needing that
#   baseline the moment the user goes to Install to repair them. See
#   hu_domain_selection_remains and lib/hub-state.sh's hub_group_remains_present.
#
#   ONE LINE, NOT THIRTY, on screen: a cascaded baseline is announced as
#   "<Domain> baseline (N items)" rather than one row per unit, for the same reason
#   the "Remove:" block collapses a technology to one line and List collapses the
#   same set to "Framework baseline (N items)". See the "Also removing" block. The
#   Result screen's receipt collapses both the same way, counting only the units that
#   ACTUALLY came out, so a partial removal reads "(2 items)" where the preview
#   promised three (see hu_result_remove_items).
#
#   A domain with NO selection kind at all (today, GTD) is untouched by this whole
#   mechanism, and now for a structural reason rather than as a carve-out: it has NO
#   BASELINE GROUP to cascade. Its one group is `atomic:<domain>` with
#   `role=selectable` (see lib/hub-domains.sh's GROUP KEY GRAMMAR), so it is
#   SELECTED like any other selectable group and never cascaded — and the domain loop
#   below skips it on its selection kind, which is what stops an always-empty
#   consumer set from being read as "nothing remains" and sweeping the domain out on
#   every unrelated uninstall. Both halves matter: the group shape is why there is
#   nothing to sweep, the loop guard is why nothing tries.
#
# THE CROSS-DOMAIN RETENTION RULE, applied here, and it runs in BOTH directions:
#   * KEPT — a shared unit (today, the GitHub-auth procedure) that IS in the
#     removal set is held back when at least one consumer remains installed. Said
#     so on screen, in its own "Kept" block, rather than blocked: nothing the user
#     asked for is refused, a genuinely still-needed prerequisite simply is not
#     garbage yet.
#   * CASCADE — a shared unit that is NOT in the removal set comes out anyway once
#     NO consumer of it is left installed. Without this the rule only ever
#     accumulated: removing every consumer left the shared unit installed forever,
#     reachable by nothing, and no selection of components could ever clear it.
#     Previewed as its own explicit "Also removing" block, never silently.
#
#     The condition is "nothing installed requires it any more", which is WIDER
#     than "this removal takes its last consumer": on a hand-meddled target whose
#     consumers were already removed by other means, an unrelated uninstall also
#     sweeps the unit out. That is the correct behavior — it is exactly the
#     unreachable leftover this direction of the rule exists to collect, and
#     narrowing the trigger to "a consumer is present AND in this removal set"
#     would make that leftover permanently unremovable again. The on-screen wording
#     therefore states the condition actually tested, and never claims a last
#     consumer is going out in this run.
#
# Exit codes:
#   0  preview shown / nothing to remove / cancelled / applied successfully.
#   1  blocked (see HUB_BLOCKED_REASON), or an internal removal failure.
#   2  usage error (bad flag, unknown component name).
#   3  the user pressed q to quit the hub from an interactive screen.
#
# HUB_STATUS vocabulary: ok | blocked. HUB_BLOCKED_REASON's closed set is
# published in the base UI spec
# (.crucible/docs/specs/2026/07/30/crucible-management-hub-ui.draft.md, "Agent-
# facing mode"); this header only names which members THIS script emits:
#   confirmation_required     --apply --all without --confirm=UNINSTALL.
#   restore_selection_required  more than one CLAUDE.md backup exists and no
#                             --restore-backup was given. Never guessed:
#                             silently picking "the newest" would overwrite the
#                             operating contract with a file the caller never
#                             named.
#
# Portability: POSIX sh only. jq is required ONLY for --format=json.
set -eu

HUB_PROG="crucible-hub uninstall"
HUB_DIR0=$(dirname "$0")
. "$HUB_DIR0/lib/hub-common.sh"
. "$HUB_DIR0/lib/hub-domains.sh"
. "$HUB_DIR0/lib/hub-render.sh"
. "$HUB_DIR0/lib/hub-nav.sh"
. "$HUB_DIR0/lib/hub-checklist.sh"
. "$HUB_DIR0/lib/hub-discovery.sh"
. "$HUB_DIR0/lib/hub-state.sh"
. "$HUB_DIR0/lib/hub-symlink.sh"
. "$HUB_DIR0/lib/hub-bundle.sh"

hub_workspace_init

usage() {
	cat <<EOF
Usage: $HUB_PROG [--components=a,b | --all] [--apply] [--non-interactive]
                    [--confirm=UNINSTALL] [--restore-backup=TIMESTAMP|none]
                    [--accessible] [--details] [--target DIR] [--source DIR]
                    [--format=text|env|json] [--no-color] [-h|--help]

With no --components and no --all on a TTY, runs the interactive checklist.
A flag-driven selection without --apply previews only and stops; it never reaches
the confirm prompt.

Options:
  --components CSV     Remove exactly these components. Two vocabularies are
                        accepted: the checklist's own keys — one per technology,
                        per PM backend, and per self-contained domain (e.g.
                        python, github, gtd) — and List's per-unit row keys (e.g.
                        java-reviewer; a PM backend has no per-unit row key, only
                        its selection/row key: github or github-backend). A KEY
                        NAMING ONE UNIT REMOVES THE WHOLE THING IT BELONGS TO —
                        a technology's developer, reviewer and standard travel
                        together, and so does a self-contained domain's entire
                        footprint, so --components=java-reviewer takes the whole
                        Java technology out and --components=flow-inbox takes all
                        of GTD out, not that one unit.
                        Mutually exclusive with --all.
  --all                Remove everything installed, plus CLAUDE.md and the
                        contract schemas. The one critical-tier flow, and the only
                        way to remove a domain BASELINE (which otherwise leaves
                        only by cascade, once nothing installed still needs it).
  --confirm=UNINSTALL  Required alongside --apply --all when there is no terminal
                        to confirm at. Absent, the command fails loud rather than
                        assuming consent.
  --restore-backup TS  --all only: restore the CLAUDE.md.backup.* stamped TS, or
                        "none" to restore nothing. Honoured whatever the backup
                        count is; a TS matching no existing backup is a usage
                        error. Absent, one backup restores itself and several
                        prompt (or block, with --non-interactive).
  --apply              Perform the writes. Absent: preview only, on EVERY path,
                        including a TTY. A flag-driven selection without --apply
                        prints its preview and stops; only the pure interactive
                        checklist walk confirms-then-writes.
  --non-interactive    Never prompt; requires --components or --all.
  --accessible         ASCII fallback for every non-ASCII symbol. Opt-in only.
  --details            Result screen: itemize instead of summarizing. Only a BULK
                        (--all) result summarizes by default.
  --target DIR         Deployed config dir to uninstall from (default:
                        \$HOME/.claude).
  --source DIR         Framework root to scan (default: the hub's own tree).
  --format FMT         text (default) | env | json — governs only the FINAL result
                        rendering; the preview is always human-readable text.
  --no-color           Disable ANSI color.
  -h, --help           Show this help.
EOF
}

OPT_COMPONENTS=""
OPT_ALL=0
OPT_APPLY=0
OPT_NONINTERACTIVE=0
OPT_CONFIRM=""
OPT_RESTORE_BACKUP=""
OPT_DETAILS=0
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
	--components)
		[ $# -ge 2 ] || die_usage "--components requires an argument"
		OPT_COMPONENTS=$2
		shift 2
		;;
	--components=*)
		OPT_COMPONENTS=${1#--components=}
		shift
		;;
	--all)
		OPT_ALL=1
		shift
		;;
	--confirm)
		[ $# -ge 2 ] || die_usage "--confirm requires an argument"
		OPT_CONFIRM=$2
		shift 2
		;;
	--confirm=*)
		OPT_CONFIRM=${1#--confirm=}
		shift
		;;
	--restore-backup)
		[ $# -ge 2 ] || die_usage "--restore-backup requires an argument"
		OPT_RESTORE_BACKUP=$2
		shift 2
		;;
	--restore-backup=*)
		OPT_RESTORE_BACKUP=${1#--restore-backup=}
		shift
		;;
	--apply)
		OPT_APPLY=1
		shift
		;;
	--non-interactive)
		OPT_NONINTERACTIVE=1
		shift
		;;
	--details)
		OPT_DETAILS=1
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*) die_usage "unknown argument: $1" ;;
	esac
done

hub_validate_format text env json

# ---------------------------------------------------------------------------
# fd 3 — the HUMAN channel. Same contract as hub-install.sh's: every
# human-readable line (the dry-run preview, no-op notices, the Result screen)
# goes to fd 3, while the machine formats' HUB_*=value lines and JSON document
# go to plain stdout, so a caller can `eval`/`jq` stdout directly. Under
# --format=text both are the same place. Opened here, before the first possible
# no-op exit.
# ---------------------------------------------------------------------------
if [ "$OPT_FORMAT" = text ]; then
	exec 3>&1
else
	exec 3>&2
fi

if [ -n "$OPT_COMPONENTS" ] && [ "$OPT_ALL" -eq 1 ]; then
	die_usage "--components and --all are mutually exclusive"
fi
if [ "$OPT_NONINTERACTIVE" -eq 1 ] && [ -z "$OPT_COMPONENTS" ] && [ "$OPT_ALL" -eq 0 ]; then
	die_usage "--non-interactive requires --components or --all"
fi
if [ -n "$OPT_RESTORE_BACKUP" ] && [ "$OPT_ALL" -eq 0 ]; then
	die_usage "--restore-backup applies only to --all"
fi

[ -n "$OPT_TARGET" ] || OPT_TARGET=$(hub_default_target)
[ -n "$OPT_SOURCE" ] || OPT_SOURCE=$(hub_default_source)
TARGET_DIR=$(hub_abspath "$OPT_TARGET")
FRAMEWORK_ROOT=$(hub_realpath "$OPT_SOURCE") || die "cannot resolve --source: $OPT_SOURCE"

# The write-boundary contract of lib/hub-symlink.sh: every removal this script
# performs is asserted to land inside one of TARGET_DIR's own deployment
# directories, and the assertion reads this variable. Set immediately after
# TARGET_DIR is resolved, before anything can write.
HUB_TARGET_DIR=$TARGET_DIR

hub_discovery_build "$FRAMEWORK_ROOT"
hub_states_build "$TARGET_DIR"
hub_rows_build

ORPHANS="$HUB_WORK/orphans.tsv"
hub_orphaned_units "$TARGET_DIR" >"$ORPHANS"

# ---------------------------------------------------------------------------
# Machine-status exits. Both live in lib/hub-common.sh (hub_ok_exit /
# hub_blocked) — HUB_STATUS/HUB_BLOCKED_REASON is a published closed contract and
# install carried a near-identical copy, differing only in this action string.
# These two wrappers bind that one argument.
# ---------------------------------------------------------------------------
HU_ACTION=uninstall

# hu_ok_exit MESSAGE -> report a legitimate no-op (nothing installed, nothing
# selected, dry run without --apply, cancelled) and exit 0. Every no-op path
# routes through here so a machine caller ALWAYS receives a HUB_STATUS line, in
# every format, on every exit path — a silent exit 0 is indistinguishable, to a
# poller, from a crash before any output.
#
# APPLIED is always false here: every caller of this helper is a path where
# nothing was written. The success path emits HUB_APPLIED=true itself.
hu_ok_exit() {
	hub_ok_exit "$HU_ACTION" false "$1"
}

# hu_blocked REASON MESSAGE -> a gated refusal, exit 1.
hu_blocked() {
	hub_blocked "$HU_ACTION" "$1" "$2"
}

# ---------------------------------------------------------------------------
# Removable rows: everything actually present at the target. An available row is
# not offered — there is nothing to remove — and an orphan IS offered, because a
# dangling link is precisely something a user wants to be able to clear (List
# points them here for exactly that).
# ---------------------------------------------------------------------------
REMOVABLE_ROWS="$HUB_WORK/removable-rows.tsv"
ORPHAN_KINDS="$HUB_WORK/orphan-kinds.tsv"
awk -F '\t' '$4 != "available"' "$HUB_ROWS" >"$REMOVABLE_ROWS"
: >"$ORPHAN_KINDS"
# AN ORPHAN ROW CARRIES AN EMPTY COLUMN 2 (its group — an orphan has none, which is
# what makes it an orphan), and column 2 is NOT the last column. That is the one
# deliberate exception to this hub's "no empty column except the last" rule, and it
# is safe for exactly one reason, stated here at the construction site rather than
# left for a reader to infer:
#
#   REMOVABLE_ROWS IS READ EXCLUSIVELY BY awk, NEVER BY `read`.
#
# awk -F '\t' splits strictly, so an empty field stays a field; `read` with
# IFS=TAB collapses consecutive tabs and would shift every later column (see
# lib/hub-common.sh's "THE TAB TRAP"). The column order cannot simply be
# rearranged, because REMOVABLE_ROWS is HUB_ROWS plus these extra rows and must
# keep HUB_ROWS' own column order. Any future reader of this table must therefore
# be awk, or must first move the group column last.
while IFS="$HUB_TAB" read -r HU_NAME HU_KIND; do
	[ -n "$HU_NAME" ] || continue
	printf '%s\t\t%s\t%s\n' "$HU_NAME" "$HU_NAME" ORPHANED >>"$REMOVABLE_ROWS"
	printf '%s\t%s\n' "$HU_NAME" "$HU_KIND" >>"$ORPHAN_KINDS"
done <"$ORPHANS"

# hu_orphan_kind NAME -> the kind of an orphaned row, or empty when NAME is not
# an orphan. The presence of a kind here is also what marks a row as an orphan
# for the removal loop, which must use hub_unlink_orphan rather than
# hub_unlink_unit (an orphan has no source to compare against).
hu_orphan_kind() {
	hok_name="$1" awk -F '\t' '$1 == ENVIRON["hok_name"] { print $2; exit }' "$ORPHAN_KINDS"
}

# ---------------------------------------------------------------------------
# SELECTABLE ROWS — the interactive checklist's ENTIRE vocabulary: one row per
# technology and one per Project Management backend that has anything to remove.
# See this file's header ("WHAT THIS CAPABILITY OFFERS AS SELECTABLE") for why
# this exists beside HUB_ROWS rather than replacing it.
#
# Built from the group table's own ROLE column (`selectable`) — never from a list
# of selection kinds — so a future third kind is offered here with no edit, the
# same way hub-list.sh's own hl_selectable_rows_build already does it.
#
# Columns: key, group, domain, state, LABEL-LAST. Every column is non-empty for a
# selectable group, so `read` is safe on this table; the label still goes last,
# since it is the only one whose emptiness would be a display bug rather than a
# crash (lib/hub-common.sh's "THE TAB TRAP").
#
# THE LABEL IS THE CONTEXT-FREE FORM (hub_group_label_in_context), not the group
# table's raw column 2, and this screen is one of exactly two places in the hub that
# needs it. Its checklist mixes every domain's rows under one generic title with no
# domain sub-headers at all, so a bare "GitHub" row says nothing about which of the
# several GitHub things this hub touches it removes; the qualified
# "Project Management (GitHub)" does. A technology row is unaffected — the predicate
# behind that function answers `no` for its kind, so "Java" stays "Java" rather than
# growing a "Software Development (…)" wrapper on every row of the longest list
# here. See lib/hub-discovery.sh's own note on why the bare label became canonical.
#
# THE STATE COLUMN IS IN THE DISPLAY VOCABULARY (installed | available | DIVERGED),
# put there by lib/hub-state.sh's hub_group_display_state — the ONE owner of the
# `partial -> DIVERGED` mapping — never by hub_group_state's raw group vocabulary.
# It used to carry the raw `partial`, and the checklist awk below then hand-mapped
# it to the word "diverged", which was a FOURTH spelling of a mapping that has an
# owner (hub_group_display_state's own header named this file as the remaining
# candidate for it, and this is that move). Nothing else on this screen wants the
# raw value: hu_selectable_group_of reads columns 1 and 2, hu_domain_selection_remains
# reads 2 and 3 and asks hub_group_remains_present for the presence question itself,
# and the checklist awk reads 4 and 5 — so no second, raw-state column is needed
# beside it.
#
# The `available` guard below is unaffected by the change: `available` is the one
# word both vocabularies spell identically (hub_group_display_state rewrites only
# `partial`), which is why one call can serve both the guard and the column.
#
# EVERY ACCESSOR RESULT IS ASSIGNED before the printf, never inlined as one of its
# arguments: hub_group_field dies (via hub_discovery_require) on an unbuilt discovery
# and hub_group_label_in_context dies through it and through hub_domain_label, and a
# die inside a command substitution used as an ARGUMENT is swallowed — the
# substitution yields empty, printf still succeeds, and this table gains a row with
# no selection key or no LABEL that the checklist still renders and still lets a user
# tick. A nameless row on a DESTRUCTIVE consent screen is the worst shape this hazard
# takes anywhere in the hub. The same hoisting hu_cascade_items applies to the same
# accessor a few hundred lines below, and lib/hub-state.sh's hub_rows_build states in
# full.
# ---------------------------------------------------------------------------
SELECTABLE_ROWS="$HUB_WORK/selectable-rows.tsv"
: >"$SELECTABLE_ROWS"
for HU_SGROUP in $(hub_groups_of_role selectable); do
	HU_SSTATE=$(hub_group_display_state "$HU_SGROUP")
	# An `available` group is not offered, exactly as an available unit row is
	# not: there is nothing to remove. Same "only list what is actionable" rule
	# the Install side applies from its own direction.
	[ "$HU_SSTATE" != available ] || continue
	HU_SSELKEY=$(hub_group_field "$HU_SGROUP" 6)
	HU_SDOMAIN=$(hub_group_field "$HU_SGROUP" 3)
	HU_SLABEL=$(hub_group_label_in_context "$HU_SGROUP")
	printf '%s\t%s\t%s\t%s\t%s\n' \
		"$HU_SSELKEY" "$HU_SGROUP" "$HU_SDOMAIN" \
		"$HU_SSTATE" "$HU_SLABEL" >>"$SELECTABLE_ROWS"
done

# hu_selectable_group_of KEY -> the selectable group KEY is the selection key of,
# or empty when KEY names nothing that is offered.
hu_selectable_group_of() {
	husgo_key="$1" awk -F '\t' '$1 == ENVIRON["husgo_key"] { print $2; exit }' "$SELECTABLE_ROWS"
}

# hu_removable_row_exists KEY -> exit 0 when KEY is one of HUB_ROWS' own removable
# row keys: a unit name, an atomic group's row key, or an orphan.
hu_removable_row_exists() {
	hurre_key="$1" awk -F '\t' \
		'$1 == ENVIRON["hurre_key"] { found = 1 } END { exit found ? 0 : 1 }' "$REMOVABLE_ROWS"
}

# hu_removal_is_atomic GROUP -> exit 0 when every unit of GROUP comes out
# TOGETHER, whichever of its keys the caller named.
#
# DELIBERATELY NOT the group table's own `atomic` column, and the difference is not
# an inconsistency to be reconciled: the two answer DIFFERENT QUESTIONS about the
# same group, and both answers are right.
#   * `atomic` (column 7) answers ROW PROJECTION — how many rows this group
#     contributes to hub_rows_build/HUB_ROWS. A technology contributes several,
#     because Doctor's diverged section and List's payload have to be able to name
#     "Java agent reviewer" specifically.
#   * this answers REMOVAL COVERAGE — how many units one pick takes out. A
#     technology is ONE thing there: its developer, reviewer and standard are one
#     thing a human installs and one thing a human removes.
# A technology is simultaneously several nameable rows and one removable thing, so
# no single predicate can honestly serve both readers. See lib/hub-domains.sh's
# "WHICH GROUPS ARE ATOMIC" note, which owns the full statement.
#
# Every SELECTABLE group is removal-atomic, read from the role column, so a future
# third selection kind needs no edit here either — and neither did the self-contained
# domain shape (`atomic:<domain>`, role=selectable), which is what makes
# `--components=<any one of its units>` remove all of them. That widening is the
# intended consequence of the role, not an accident of it: such a domain installs as
# one thing and removes as one thing.
hu_removal_is_atomic() {
	[ "$(hub_group_field "$1" 4)" = selectable ]
}

# ---------------------------------------------------------------------------
# Selection.
# ---------------------------------------------------------------------------
SELECTED_ROWS="$HUB_WORK/selected-rows.txt"
: >"$SELECTED_ROWS"

# INTERACTIVE_SELECTION — whether the selection comes from the checklist rather
# than from flags. It decides whether `b` on the confirm screen has a checklist to
# return to, and whether --apply is required to reach that screen at all.
INTERACTIVE_SELECTION=0
CHECKLIST_ROWS="$HUB_WORK/checklist-rows.tsv"

if [ "$OPT_ALL" -eq 1 ]; then
	awk -F '\t' '{ print $1 }' "$REMOVABLE_ROWS" >"$SELECTED_ROWS"
elif [ -n "$OPT_COMPONENTS" ]; then
	# hub_dedup_first_field after the split, exactly as hub-install.sh does after
	# EVERY split: hub_split_csv trims and drops empty tokens but does not
	# deduplicate, and the duplicates survive onto the CONSENT SURFACE —
	# `--components=x,x` inflated the preview header count, the discard guard's
	# count and the published HU_COMPONENTS_CSV payload. The apply itself was
	# always correct (deduped downstream by unit name), so this is an accuracy fix
	# for what the user is asked to approve.
	hub_split_csv "$OPT_COMPONENTS" "$SELECTED_ROWS"
	hub_dedup_first_field "$SELECTED_ROWS"
	while IFS= read -r HU_KEY; do
		[ -n "$HU_KEY" ] || continue
		# BOTH vocabularies are legal, and neither is guessed at: the checklist's
		# own technology/backend selection keys (so a human and an agent name the
		# same thing — the parity requirement) and HUB_ROWS' per-unit keys, which
		# anything already scripted against this flag passes. An unknown token is a
		# usage error, never a silently narrowed selection.
		if [ -z "$(hu_selectable_group_of "$HU_KEY")" ] && ! hu_removable_row_exists "$HU_KEY"; then
			die_usage "unknown or not-installed component: $HU_KEY"
		fi
	done <"$SELECTED_ROWS"
else
	if ! hub_interactive; then
		die_usage "no TTY and no --components/--all given"
	fi
	if [ ! -s "$REMOVABLE_ROWS" ]; then
		hu_ok_exit "$(printf 'Nothing to uninstall — no component is installed at %s. Try "Install" or "List".' "$TARGET_DIR")"
	fi
	INTERACTIVE_SELECTION=1
	# key, label, diverged, ANNOTATION-LAST — the annotation is the only column
	# that can be empty and must therefore come last (lib/hub-common.sh, "THE
	# TAB TRAP").
	#
	# ONE row per technology and per backend, read from SELECTABLE_ROWS. A group
	# that is only partly present — some unit missing, or its path occupied by
	# something else — arrives here already reading DIVERGED (SELECTABLE_ROWS puts it
	# through hub_group_display_state; this awk no longer maps `partial` itself) and
	# is marked [!]. Selecting it still removes the whole technology/backend.
	#
	# THE ANNOTATION SAYS "partially installed", the same STATE PHRASE
	# hub-install.sh's own checklist uses for the identical group state, replacing
	# this screen's private one-word "diverged" — two screens describing one state in
	# two vocabularies is the same drift the state column above just fixed. Install's
	# full annotation is "partially installed — choose to complete"; its action clause
	# is deliberately NOT copied, because on THIS screen selecting the row removes the
	# group rather than completing it, and no annotation states the removal
	# consequence anyway: it is true of every row here, not just this one.
	#
	# A backend row reads "Project Management (GitHub)" here, not the bare "GitHub"
	# every domain-grouped screen shows: this checklist mixes domains under one
	# generic title and has nothing else to say what a bare "GitHub" would be. The
	# qualification is applied when SELECTABLE_ROWS is built, by
	# hub_group_label_in_context — see that build for why it lives there and not in
	# this awk, and lib/hub-discovery.sh for why the canonical label is bare.
	awk -F '\t' -v OFS='\t' '{
		note = ""
		div = 0
		if ($4 == "DIVERGED") { note = "partially installed"; div = 1 }
		print $1, $5, div, note
	}' "$SELECTABLE_ROWS" >"$CHECKLIST_ROWS"
	# ORPHANS STAY OFFERED, and they are the one row here that is not a selectable
	# group at all. That is deliberate: a dangling symlink is not a framework
	# component whose granularity this redesign is about, it is target rubbish with
	# no other way out — List points the user at THIS screen to clear it, and only
	# --all would otherwise reach it.
	while IFS="$HUB_TAB" read -r HU_NAME _; do
		[ -n "$HU_NAME" ] || continue
		printf '%s\t%s\t1\t%s\n' "$HU_NAME" "$HU_NAME" 'orphaned — source no longer exists' >>"$CHECKLIST_ROWS"
	done <"$ORPHANS"
	# SOMETHING IS INSTALLED (checked just above) BUT NOTHING IS INDIVIDUALLY
	# REMOVABLE: only domain baselines are left, and a baseline is never offered —
	# it leaves by cascade or with --all. Saying so beats opening an empty
	# checklist, whose own empty-view line is written for a filter matching
	# nothing and would misdescribe this state.
	if [ ! -s "$CHECKLIST_ROWS" ]; then
		hu_ok_exit "$(printf 'Nothing to uninstall individually at %s — nothing selectable is installed, only domain baselines. Choose "Uninstall all" to remove those too, or "List" to see what is there.' "$TARGET_DIR")"
	fi
fi

# hu_cascade_group GROUP -> the CASCADE direction: nothing that stays installed
# requires GROUP's units any more, so they come out even though the user did not
# name them. Appends to REMOVE_UNITS and CASCADED.
#
# ONE function for BOTH cascades — the cross-domain shared group and a domain's
# own baseline — because they are the same rule over different consumer sets.
# Routing both through here is what makes the preview read as one consistent
# "Also removing" list rather than two blocks saying the same thing in two
# different ways.
#
# Its own function, not an inline branch: this and hu_keep_shared below were one
# 68-line, four-deep loop body that mutated REMOVE_UNITS three different ways, and
# the file's most intricate logic had no named boundaries at all.
hu_cascade_group() {
	hucg_group=$1
	hucg_units="$HUB_WORK/cascade-units.tsv"
	hub_group_units "$hucg_group" >"$hucg_units"
	while IFS="$HUB_TAB" read -r hucg_name hucg_kind hucg_src hucg_display; do
		[ -n "$hucg_name" ] || continue
		# Only what is actually PRESENT can cascade out. Without this test a
		# never-installed unit would be "removed" on every uninstall, because "no
		# consumer remains" is trivially true when no consumer was ever there.
		hub_state_set "$hucg_kind" "$hucg_name" "$hucg_src" "$TARGET_DIR"
		[ "$HUB_STATE" != available ] || continue
		# REMOVE_UNITS column order is name, kind, display, SRC-LAST (see above);
		# hub_group_units hands them back name, kind, src, display.
		printf '%s\t%s\t%s\t%s\n' "$hucg_name" "$hucg_kind" "$hucg_display" "$hucg_src" >>"$REMOVE_UNITS"
		# CASCADED columns: name, GROUP, display, SRC-LAST.
		#
		# The NAME is there because the preview subtracts these rows from its
		# "Remove:" itemization by name (an exact key comparison, never a display
		# string) — REMOVE_ONLY's own awk keys on column 1, so this column is the
		# internal identity of a cascaded unit and stays per-unit no matter what the
		# screen chooses to print.
		#
		# The GROUP is there so the preview can tell WHICH KIND of cascade a row
		# belongs to without re-deriving it: a domain's baseline collapses to one
		# line naming the baseline, while the cross-domain shared group itemizes by
		# name (it is one or two units, and "Git auth procedure" is the useful thing
		# to read). See the "Also removing" block.
		#
		# The SRC is there because a cascaded baseline is now reported by its domain's
		# NAMED FEATURES where it has them, and feature membership is a path-shape test
		# on exactly this column (lib/hub-domains.sh's hub_domain_feature_of). It is
		# LAST per lib/hub-common.sh's "THE TAB TRAP": every group unit has a src, so it
		# cannot actually be empty, but it is the only column here whose absence would
		# be a display bug rather than a crash, and this table is read with `read` and
		# IFS=TAB.
		printf '%s\t%s\t%s\t%s\n' "$hucg_name" "$hucg_group" "$hucg_display" "$hucg_src" >>"$CASCADED"
	done <"$hucg_units"
	hub_dedup_first_field "$REMOVE_UNITS"
}

# hu_keep_shared -> the KEPT direction: the units in HU_SHARED_UNITS were selected
# for removal, but at least one consumer stays installed, so they are held back and
# reported rather than removed. Removes them from REMOVE_UNITS and appends to KEPT.
hu_keep_shared() {
	huks_notes=""
	while IFS= read -r huks_consumer; do
		[ -n "$huks_consumer" ] || continue
		huks_notes=$(hub_join_append "$huks_notes" \
			"$(huks_consumer="$huks_consumer" awk -F '\t' \
				'$1 == ENVIRON["huks_consumer"] { print $2; exit }' "$HU_CONSUMER_NOTES")" ', ')
	done <"$HU_REMAINING"

	while IFS="$HUB_TAB" read -r huks_name _ _ huks_display; do
		[ -n "$huks_name" ] || continue
		printf '%s\t%s\n' "$huks_display" "$huks_notes" >>"$KEPT"
		hub_remove_row_by_key "$REMOVE_UNITS" "$huks_name"
	done <"$HU_SHARED_UNITS"
}

# hu_group_in_plan GROUP -> exit 0 when any unit of GROUP is already in
# REMOVE_UNITS, i.e. the selection names the group itself.
#
# Both cascades ask it, for the same reason: a group already being removed on
# purpose must not ALSO be announced as an "also removing" surprise — which is
# what --all, whose selection names every row there is, would otherwise be
# entirely made of.
#
# The phase test is FNR == NR && FILENAME == ARGV[1], not a bare FNR == NR: an
# EMPTY REMOVE_UNITS is a legitimate state, and with a bare test awk (which never
# reads a record from an empty first file) would mis-file HUB_STATES' own first row
# as a removal entry.
hu_group_in_plan() {
	hugip_found=$(hugip_group="$1" awk -F '\t' '
		FNR == NR && FILENAME == ARGV[1] { removing[$1] = 1; next }
		$1 == ENVIRON["hugip_group"] && ($2 in removing) { print 1; exit }
	' "$REMOVE_UNITS" "$HUB_STATES")
	[ -n "$hugip_found" ]
}

# hu_domain_selection_remains DOMAIN -> exit 0 when at least one of DOMAIN's own
# selectable groups (its technologies, or its backends) is still PRESENT once this
# removal is done. Exit 1 means the domain is left with nothing selectable at all —
# which is precisely when its baseline has nothing left to serve and cascades out.
#
# The per-group answer comes from hub_group_remains_present, the SAME predicate the
# cross-domain consumer test uses, so "still there after this removal" means one
# thing in this file.
#
# "PRESENT", not "installed", and the width is load-bearing rather than loose: it is
# the identical test SELECTABLE_ROWS above applies when it decides a group is still
# offerable (state != available). A DIVERGED technology therefore counts as still
# needing its domain's baseline — its files are sitting at the target, it is listed
# as removable on the very checklist that was just drawn, and Install needs that
# baseline to repair it. Under a stricter `installed`-only test, removing the one
# healthy technology beside it cascaded the baseline out while telling the user
# "nothing installed requires it any more", which was false about the target they
# were looking at. See lib/hub-state.sh's hub_group_remains_present.
#
# Scans SELECTABLE_ROWS, i.e. only the groups that have something at the target:
# an `available` group cannot "remain" by definition, so leaving it out is the
# same answer for less work.
hu_domain_selection_remains() {
	hudsr_groups="$HUB_WORK/domain-selectable.txt"
	hudsr_domain="$1" awk -F '\t' \
		'$3 == ENVIRON["hudsr_domain"] { print $2 }' "$SELECTABLE_ROWS" >"$hudsr_groups"
	while IFS= read -r hudsr_group; do
		[ -n "$hudsr_group" ] || continue
		if hub_group_remains_present "$hudsr_group" "$REMOVE_UNITS"; then
			return 0
		fi
	done <"$hudsr_groups"
	return 1
}

# hu_choose_backup -> the interactive "which CLAUDE.md backup should be restored"
# prompt, reached only with MORE THAN ONE backup present and no --restore-backup.
# Sets RESTORE_TARGET to the chosen path, or empty for "restore none".
#
# IT OBEYS THIS HUB'S UNIVERSAL PROMPT CONTRACT, which it previously did not, and
# every clause below is a live defect it had:
#   * The action hint sits ON the `> ` line and names the nav trio, like every
#     other input point in this hub (hub_confirm_prompt, the checklist,
#     hub_press_key_to_continue). It had no hint at all and no `> ` line.
#   * A BARE ENTER takes the documented default, "Restore none". `read` only
#     defaults on EOF, never on an empty line, so Enter used to fall through with
#     an empty choice, match no numbered row and DIE — aborting a critical-tier
#     uninstall the user then had to restart from scratch, on the single most
#     likely keystroke at any prompt.
#   * UNRECOGNIZED INPUT RE-PROMPTS instead of dying, as it does at every other
#     prompt here (the checklist's "no such row", hub_confirm_gate's decline).
#   * The numbered rows go through hub_number, the one place this hub decides what
#     a numbered choice looks like, so this screen looks like every other prompt
#     the user types a number AT (the Main menu, the Accounts submenu, every
#     checklist row) instead of being the one that rendered its numbers in plain
#     text. Doctor's "Suggested next steps" are deliberately NOT part of that set
#     and stay uncolored: they are advisory prose nobody selects by number, and
#     their text is emitted verbatim as machine payload under --format=env|json.
#
# `b`/`back` means "restore none" rather than a step backwards: this prompt is not
# a step anyone navigated FORWARD to (it is reached by --all alone), so there is no
# earlier screen to return to, and declining the restore is what "back out of this
# question" can honestly mean here. `q`/`quit` exits 3 like everywhere else.
#
# Every line goes to fd 3, the human channel: under --format=env|json fd 3 is
# stderr, so a numbered menu can never interleave with the HUB_*= payload or the
# JSON document a caller parses off stdout. The `read` is unaffected — it takes
# stdin, not fd 1.
hu_choose_backup() {
	hcb_numbered="$HUB_WORK/backups-numbered.tsv"
	while :; do
		{
		printf '  Multiple %s backups were found — choose which to restore:\n\n' "$HUB_BUNDLE_CONFIG_NAME"
		hcb_n=0
		: >"$hcb_numbered"
		while IFS= read -r hcb_backup; do
			[ -n "$hcb_backup" ] || continue
			hcb_n=$((hcb_n + 1))
			printf '    %s %s\n' "$(hub_number "$(printf '%2s.' "$hcb_n")")" "${hcb_backup##*/}"
			printf '%s\t%s\n' "$hcb_n" "$hcb_backup" >>"$hcb_numbered"
		done <"$BACKUPS"
		hcb_n=$((hcb_n + 1))
		# The dimmed halves and the colored key are SEPARATE arguments, never one
		# nested "$(hub_dim "... $(hub_key Enter) ...")": hub_c always closes with a
		# full SGR reset, so an inner hub_key silently ends the outer dim and
		# everything after it renders at full brightness (the same trap
		# hub_confirm_prompt documents at its own prompt).
		printf '    %s Restore none %s%s%s\n\n' "$(hub_number "$(printf '%2s.' "$hcb_n")")" \
			"$(hub_dim '(the default — press ')" "$(hub_key Enter)" "$(hub_dim ')')"
		printf '  %s%s\n> ' "$(hub_dim "1-$hcb_n")" "$(hub_sep_text)$(hub_nav_keys_hint)"
		} >&3

		IFS= read -r hcb_choice || hcb_choice=""
		case $hcb_choice in
		'' | b | back)
			RESTORE_TARGET=""
			return 0
			;;
		q | quit)
			printf 'Cancelled. Nothing changed.\n' >&3
			exit 3
			;;
		'?')
			hub_show_help
			continue
			;;
		esac
		if [ "$hcb_choice" = "$hcb_n" ]; then
			RESTORE_TARGET=""
			return 0
		fi
		RESTORE_TARGET=$(hcb_choice="$hcb_choice" awk -F '\t' \
			'$1 == ENVIRON["hcb_choice"] { print $2; exit }' "$hcb_numbered")
		[ -z "$RESTORE_TARGET" ] || return 0
		printf '  no such choice: %s\n' "$hcb_choice" >&3
	done
}

# hu_row_counts_build UNITS OUT -> writes OUT, "rowkey<TAB>unit count" for every
# SELECTED row that still has at least one of its units present in UNITS (any table
# whose first column is a unit name), in the selection's own order.
#
# TWO CALLERS, ONE JOIN, deliberately: the PREVIEW passes REMOVE_ONLY (what is
# planned) and the RESULT screen passes what was actually removed. Counting both
# through the same ROW_MAP join is what makes the receipt's "(N items)" directly
# comparable with the preview's — and what makes a PARTIAL removal print a SMALLER
# number rather than reprinting the plan as if it had all landed.
#
# THE ONE POST-RESOLUTION ROW SET, and every number the user is asked to approve
# about "how many things did I pick" is derived from it: the preview header
# ("Uninstall N selected"), the itemization below it, and hub_discard_guard's
# "Discard N selected items and quit?".
#
# It is NOT the raw SELECTED_ROWS line count, which the group-atomic resolution can
# make disagree with what is actually itemized underneath it, in two ways that are
# both reachable:
#   * A REDUNDANT SELECTION. `--components=java,java-reviewer` names ONE technology
#     through two keys. ROW_MAP's first-claimant rule attributes every unit to the
#     first of them, so the second has a count of zero, prints no line, and was
#     still counted as a selected row in the header and the discard guard.
#   * A ROW ENTIRELY HELD BACK by the retention rule, whose units are reported under
#     "Kept" instead. Same disagreement, opposite cause.
# Deriving all three numbers here is what makes the header, the list and the guard
# arithmetically the same claim.
hu_row_counts_build() {
	hurcb_units=$1
	hurcb_out=$2
	# Per-row unit counts in one pass. The phase test carries the usual
	# FILENAME == ARGV[1] anchor (see hu_group_in_plan) even though ROW_MAP cannot
	# be empty here, so the shape stays the same everywhere it appears in this file.
	hurcb_counts="$HUB_WORK/row-counts.tsv"
	awk -F '\t' -v OFS='\t' '
		FNR == NR && FILENAME == ARGV[1] { row[$1] = $2; next }
		($1 in row) { n[row[$1]]++ }
		END { for (k in n) print k, n[k] }
	' "$ROW_MAP" "$hurcb_units" >"$hurcb_counts"
	# Re-joined against SELECTED_ROWS rather than emitted straight out of the END
	# block above: awk's for-in iteration order is unspecified, and this block's
	# order IS the order the user's own picks are listed in.
	awk -F '\t' -v OFS='\t' '
		FNR == NR && FILENAME == ARGV[1] { n[$1] = $2; next }
		($1 in n) { print $1, n[$1] }
	' "$hurcb_counts" "$SELECTED_ROWS" >"$hurcb_out"
}

# hu_item_line GLYPH INDENT LABEL COUNT -> one "<GLYPH> <LABEL> (N items)" line.
#
# THE ONE PLACE THIS SCREEN'S "(N items)" ANNOTATION AND ITS SUPPRESSION LIVE. No
# "(1 item)" on a single-unit line: the annotation exists to explain why one ticked
# box accounts for several items in the header count, and on a lone unit it is noise
# that says nothing the line did not already. (A cascade line is NOT one of these —
# it carries a trailing reason and has its own printers below; the collapsed cascade
# count line even keeps its "(1 item)", because there the count IS the subject.)
hu_item_line() {
	if [ "$4" -gt 1 ]; then
		printf '%s%s %s (%s %s)\n' "$2" "$1" "$3" "$4" "$(hub_plural "$4" item items)"
	else
		printf '%s%s %s\n' "$2" "$1" "$3"
	fi
}

# hu_row_label KEY -> the on-screen name of one selected row, as the checklist named
# it (ROW_LABELS is the one place that was decided, whichever vocabulary named it).
hu_row_label() {
	hurlb_key="$1" awk -F '\t' '$1 == ENVIRON["hurlb_key"] { print $2; exit }' "$ROW_LABELS"
}

# hu_row_domain KEY -> the DOMAIN the row's group belongs to, or empty when the row
# has no group at all (an orphan, which is nobody's group by definition).
hu_row_domain() {
	hurd_group=$(hurd_key="$1" awk -F '\t' \
		'$1 == ENVIRON["hurd_key"] { print $2; exit }' "$ROW_GROUPS")
	[ -n "$hurd_group" ] || return 0
	hub_group_field "$hurd_group" 3
}

# hu_row_feature_lines GLYPH INDENT DOMAIN KEY UNITS -> the line(s) a row of a domain
# that declares NAMED FEATURES gets: one per feature whose units are actually going out
# (or actually came out, on the receipt), plus the row's own collapsed line for whatever
# no feature claims.
#
# DOMAIN IS PASSED IN rather than re-derived from KEY: the caller had to resolve it to
# decide this function applies at all, so taking it as an argument makes the
# precondition ("a domain that declares features") part of the signature instead of a
# lookup this function repeats and could disagree about.
#
# WHY A SELECTED ROW NEEDS THIS AND A TECHNOLOGY DOES NOT: a technology's label IS the
# thing the user ticked and its units have no names any screen shows. A featured
# domain's units DO — List, both Install screens and Doctor all name "Inbox capture"
# and "Inbox triage" — so collapsing them here to the domain label would make this
# screen, and only this screen, ask the user to approve (and then confirm back) a
# removal under a name no other screen ever showed them. The checklist above still
# offers ONE row, because one row is what the removal atom is; the itemization says
# what that row contains.
#
# THE SRCS COME FROM THE CALLER'S OWN UNITS TABLE, joined through ROW_MAP, for the
# same reason every count on both screens does (see hu_row_counts_build): the preview
# passes what is planned and the receipt passes what actually came out, so a feature
# whose second unit hit a foreign occupant collapses to "Inbox capture" against a
# preview that promised "(2 items)" rather than reprinting the plan.
#
# LENS REVIEWERS ARE EXCLUDED BEFORE the feature test, the order lib/hub-state.sh's
# hub_domain_feature_rows applies and for its reason: hub_domain_feature_of classifies
# by positive path shape, so an `agents/` test reached first would claim a featured
# domain's `agents/reviewers/lens/*` units as a `capture` feature. Such a unit falls
# to the residual instead.
#
# ORDER AND COUNTING come from lib/hub-state.sh's hub_feature_counts, the shared
# projection every feature-aware screen calls; the rendering is hu_item_line, this
# screen's own.
hu_row_feature_lines() {
	hurfl_glyph=$1
	hurfl_indent=$2
	hurfl_domain=$3
	hurfl_key=$4
	hurfl_units=$5
	hurfl_srcs="$HUB_WORK/row-feature-srcs.txt"
	hurfl_keyed="$HUB_WORK/row-feature-keyed.txt"
	hurfl_counts="$HUB_WORK/row-feature-counts.tsv"
	# The units this row accounts for, by NAME through ROW_MAP, then their src column.
	# The usual FILENAME == ARGV[1] phase anchor: ROW_MAP cannot be empty on a row that
	# reached this function, and the shape stays the same everywhere it appears here.
	hurfl_key="$hurfl_key" awk -F '\t' '
		FNR == NR && FILENAME == ARGV[1] { if ($2 == ENVIRON["hurfl_key"]) row[$1] = 1; next }
		($1 in row) { print $4 }
	' "$ROW_MAP" "$hurfl_units" >"$hurfl_srcs"
	: >"$hurfl_keyed"
	hurfl_residual=0
	while IFS= read -r hurfl_src; do
		[ -n "$hurfl_src" ] || continue
		# A negated `if` around the feature test rather than two nested ones, so a lens
		# and a genuinely unclaimed unit reach the same residual arm by the same route —
		# the same shape hu_cascade_baseline_lines below uses.
		hurfl_fkey=''
		if ! hub_src_in_dir "$hurfl_src" "$HUB_SD_DIR_LENS_REVIEWERS"; then
			hurfl_fkey=$(hub_domain_feature_of "$hurfl_domain" "$hurfl_src")
		fi
		if [ -z "$hurfl_fkey" ]; then
			hurfl_residual=$((hurfl_residual + 1))
			continue
		fi
		printf '%s\n' "$hurfl_fkey" >>"$hurfl_keyed"
	done <"$hurfl_srcs"
	hub_feature_counts "$hurfl_domain" "$hurfl_keyed" "$hurfl_counts"
	while IFS="$HUB_TAB" read -r hurfl_n hurfl_label; do
		[ -n "$hurfl_n" ] || continue
		hu_item_line "$hurfl_glyph" "$hurfl_indent" "$hurfl_label" "$hurfl_n"
	done <"$hurfl_counts"
	# The remainder no feature claims, under the ROW's own name — the same label the
	# collapsed line would have carried if the domain declared no features at all, so an
	# unnamed remainder reads identically either way. Unreachable while every unit of
	# the one featured domain belongs to a feature; it is what keeps the itemization
	# exhaustive rather than merely correct today.
	if [ "$hurfl_residual" -gt 0 ]; then
		hurfl_row_label=$(hu_row_label "$hurfl_key")
		hu_item_line "$hurfl_glyph" "$hurfl_indent" "$hurfl_row_label" "$hurfl_residual"
	fi
}

# hu_row_lines GLYPH INDENT ROWS UNITS -> one line per row of a hu_row_counts_build
# table, labelled the way the checklist labelled it (ROW_LABELS) — or, for a row whose
# domain declares NAMED FEATURES, one line per feature (hu_row_feature_lines above).
# UNITS is the table ROWS was counted from, and is what the feature path reads srcs
# out of.
#
# Shared by the preview's "Remove:" block and the Result screen's receipt so the two
# render one removable thing identically — the receipt only swaps the glyph. Drifting
# copies of this format are exactly how the same technology comes to read
# "Java (3 items)" on one screen and "Java: 3" on the next.
hu_row_lines() {
	hurl_glyph=$1
	hurl_indent=$2
	hurl_rows=$3
	hurl_units=$4
	while IFS="$HUB_TAB" read -r hurl_key hurl_n; do
		[ -n "$hurl_key" ] || continue
		# An `if` on an assigned value, never `[ -n … ] || hurl_features=$(…)`: an
		# assignment on the right of `||` is exempt from `set -e`, the shape this file
		# already avoids at hub_shared_consumers.
		hurl_features=''
		hurl_domain=$(hu_row_domain "$hurl_key")
		if [ -n "$hurl_domain" ]; then
			hurl_features=$(hub_domain_feature_keys "$hurl_domain")
		fi
		if [ -n "$hurl_features" ]; then
			hu_row_feature_lines "$hurl_glyph" "$hurl_indent" \
				"$hurl_domain" "$hurl_key" "$hurl_units"
			continue
		fi
		hurl_label=$(hu_row_label "$hurl_key")
		hu_item_line "$hurl_glyph" "$hurl_indent" "$hurl_label" "$hurl_n"
	done <"$hurl_rows"
}

# HU_CASCADE_REASON — the trailing clause every cascade line carries. Spelled once:
# three call sites emit such a line now (a domain baseline's collapsed count, one per
# named feature, and a cross-domain unit), and a per-site copy is how one sentence
# comes to read three ways on one screen.
#
# It states the condition the cascade actually TESTS — "nothing installed requires
# it" — and not "its last consumer is being removed", which is false on a target whose
# consumers were already gone before this run (see this file's header). It reads
# correctly on both callers' screens: the preview asks consent for it, and after the
# removal it is still the true statement about the target.
HU_CASCADE_REASON='nothing installed requires it any more'

# hu_cascade_baseline_lines GLYPH INDENT ROWS GROUP -> the cascade line(s) a DOMAIN
# BASELINE gets: one per NAMED FEATURE whose units are actually cascading out, plus
# the collapsed count line for whatever no feature claims — or, for a domain that
# declares no features (every domain but GTD), just that count line.
#
# WHY THE NAMES ARE HERE: a generic name costs the most on a destructive screen — it
# asks the user to approve a thing by a name no other screen ever showed them. GTD is
# no longer the example (it is selected rather than cascaded now, and hu_row_lines
# names its features under "Remove:"); this stays the shape any FUTURE featured
# domain's cascaded baseline takes, and the shape hu_cascade_items reaches for
# whenever the cascading group belongs to a domain that declares features at all.
#
# LENS REVIEWERS ARE EXCLUDED BEFORE the feature test, the order lib/hub-state.sh's
# hub_domain_feature_rows applies and for its reason: hub_domain_feature_of
# classifies by positive path shape, so an `agents/` test reached first would claim a
# featured domain's `agents/reviewers/lens/*` units as a `capture` feature. Here a
# lens folds into the anonymous count rather than being itemized by name — the
# opposite of every other screen's treatment of a lens, and deliberate: THIS block
# never itemizes a baseline by unit at all (see hu_cascade_items).
#
# ORDER AND COUNTING come from lib/hub-state.sh's hub_feature_counts, the shared
# projection all three feature-aware screens call; the trailing reason and the
# "(N items)" annotation are this screen's own rendering.
hu_cascade_baseline_lines() {
	hucbl_glyph=$1
	hucbl_indent=$2
	hucbl_rows=$3
	hucbl_group=$4
	hucbl_srcs="$HUB_WORK/cascade-baseline-srcs.txt"
	hucbl_keyed="$HUB_WORK/cascade-feature-keyed.txt"
	hucbl_counts="$HUB_WORK/cascade-feature-counts.tsv"
	# ASSIGNED, never inlined as an argument: hub_group_field dies (via
	# hub_discovery_require) on an unbuilt discovery, and a die inside a command
	# substitution used as an ARGUMENT is swallowed — see hu_cascade_items' own note on
	# what a subject-less line costs on this screen.
	hucbl_domain=$(hub_group_field "$hucbl_group" 3)
	hucbl_keys=$(hub_domain_feature_keys "$hucbl_domain")
	hucbl_group="$hucbl_group" awk -F '\t' \
		'$2 == ENVIRON["hucbl_group"] { print $4 }' "$hucbl_rows" >"$hucbl_srcs"
	if [ -z "$hucbl_keys" ]; then
		# The count is the rows this group actually contributed to ROWS — the same
		# figure the previous inline awk counted, since one src line is written per row.
		hucbl_n=$(hub_count_lines "$hucbl_srcs")
		hu_cascade_count_line "$hucbl_glyph" "$hucbl_indent" "$hucbl_group" "$hucbl_n"
		return 0
	fi
	: >"$hucbl_keyed"
	hucbl_residual=0
	while IFS= read -r hucbl_src; do
		[ -n "$hucbl_src" ] || continue
		# A negated `if` around the feature test rather than two nested ones, so a lens
		# and a genuinely unclaimed unit reach the same residual arm by the same route.
		hucbl_key=''
		if ! hub_src_in_dir "$hucbl_src" "$HUB_SD_DIR_LENS_REVIEWERS"; then
			hucbl_key=$(hub_domain_feature_of "$hucbl_domain" "$hucbl_src")
		fi
		if [ -z "$hucbl_key" ]; then
			hucbl_residual=$((hucbl_residual + 1))
			continue
		fi
		printf '%s\n' "$hucbl_key" >>"$hucbl_keyed"
	done <"$hucbl_srcs"
	hub_feature_counts "$hucbl_domain" "$hucbl_keyed" "$hucbl_counts"
	while IFS="$HUB_TAB" read -r hucbl_n hucbl_label; do
		[ -n "$hucbl_n" ] || continue
		# NO "(1 item)" ON A SINGLE-UNIT FEATURE, exactly as hu_row_lines and
		# hi_result_baseline_lines suppress it: the annotation exists to explain why one
		# name accounts for several items. The collapsed count line below keeps its
		# "(1 item)" for the opposite reason — there the count IS the subject.
		if [ "$hucbl_n" -gt 1 ]; then
			printf '%s%s %s (%s %s) — %s\n' "$hucbl_indent" "$hucbl_glyph" "$hucbl_label" \
				"$hucbl_n" "$(hub_plural "$hucbl_n" item items)" "$HU_CASCADE_REASON"
		else
			printf '%s%s %s — %s\n' "$hucbl_indent" "$hucbl_glyph" "$hucbl_label" \
				"$HU_CASCADE_REASON"
		fi
	done <"$hucbl_counts"
	[ "$hucbl_residual" -eq 0 ] ||
		hu_cascade_count_line "$hucbl_glyph" "$hucbl_indent" "$hucbl_group" "$hucbl_residual"
}

# hu_cascade_count_line GLYPH INDENT GROUP COUNT -> the anonymous collapsed line a
# cascaded baseline gets: "<Domain> baseline (N items) — <reason>". Also the residual
# line of a featured domain, so an unnamed remainder reads the same either way.
hu_cascade_count_line() {
	huccl_glyph=$1
	huccl_indent=$2
	huccl_group=$3
	huccl_count=$4
	# ASSIGNED, never inlined as the printf argument: hub_group_field dies (via
	# hub_discovery_require) on an unbuilt discovery, and a die inside a command
	# substitution used as an ARGUMENT is swallowed — the substitution yields empty,
	# printf still succeeds, and this consent line reads " baseline (30 items) —
	# nothing installed requires it any more", asking the user to approve the removal
	# of a baseline it never named. The same hoisting lib/hub-state.sh's hub_rows_build
	# and hub_domain_buckets both state, and hub-install.sh's hi_shared_heading applies
	# to the same accessor.
	huccl_label=$(hub_group_field "$huccl_group" 2)
	# The noun comes from the group's own PREFIX, never hardcoded: this function
	# is also the residual line for a featured domain (hu_cascade_baseline_lines
	# above), and a featured domain's own group may be `atomic:*` — which has no
	# baseline to name — rather than `baseline:*`. Printing "GTD baseline (N
	# items)" for a group that by definition has no baseline would ask the user
	# to approve removing something that was never there.
	case $huccl_group in
	"$HUB_GROUP_PREFIX_BASELINE":*) huccl_noun=' baseline' ;;
	"$HUB_GROUP_PREFIX_ATOMIC":*) huccl_noun='' ;;
	*) die "hu_cascade_count_line: group '$huccl_group' is neither baseline nor atomic" ;;
	esac
	printf '%s%s %s%s (%s %s) — %s\n' \
		"$huccl_indent" "$huccl_glyph" "$huccl_label" "$huccl_noun" \
		"$huccl_count" "$(hub_plural "$huccl_count" item items)" "$HU_CASCADE_REASON"
}

# hu_cascade_items GLYPH INDENT ROWS -> the cascade itemization for a CASCADED-shaped
# table (name, group, display, src): ONE LINE PER CASCADED GROUP WHEN THAT GROUP IS A
# DOMAIN'S BASELINE, never one line per baseline unit — or one line per NAMED FEATURE
# for a domain that declares them (hu_cascade_baseline_lines above). A baseline is 30+
# units, so itemizing it reprints exactly the wall of individual names both the
# preview and the Result screen exist to avoid — the "Remove:" block collapses a
# technology to one line for that reason and List collapses the same set to
# "Framework baseline (N items)" for that reason.
#
# The CROSS-DOMAIN shared group still itemizes by name: it is one or two units today,
# and "Git auth procedure" is precisely the fact a reader needs here, where "Shared
# baseline (1 item)" would say strictly less.
#
# Every branch keeps the same trailing reason — HU_CASCADE_REASON, spelled once above,
# which is also where the wording is justified.
#
# ROWS, not CASCADED directly, so the RESULT screen can pass the cascaded rows that
# ACTUALLY came out. The count is then whatever that table holds for the group — the
# rows really going out (preview) or really gone (receipt) — never the group's total
# unit count, which would over-promise on a partially-installed baseline (only PRESENT
# units cascade; see hu_cascade_group).
hu_cascade_items() {
	huci_glyph=$1
	huci_indent=$2
	huci_rows=$3
	huci_groups="$HUB_WORK/cascade-groups.txt"
	huci_displays="$HUB_WORK/cascade-group-rows.txt"
	# First-seen order, so the block lists groups in the same canonical order
	# everything else in this hub does.
	awk -F '\t' '!($2 in seen) { seen[$2] = 1; print $2 }' "$huci_rows" >"$huci_groups"
	while IFS= read -r huci_group; do
		[ -n "$huci_group" ] || continue
		# WHETHER THE DOMAIN DECLARES FEATURES IS ASKED FIRST, ahead of the group-key
		# prefix test, because the prefix cannot answer it: a domain that is its own
		# single group is keyed `atomic:<domain>`, not `baseline:<domain>`, so a
		# prefix-only dispatch sent it to the per-name itemization below and printed one
		# line per unit under names no other screen shows. Nothing cascades such a
		# domain today (it is selected, never cascaded — its baseline cascade is
		# skipped, see the domain loop), so this is the arm that keeps the two dispatches
		# in this file agreeing rather than one that fires; the moment a featured domain
		# does cascade, its features are named here exactly as they are under "Remove:"
		# and only its anonymous remainder keeps this block's own collapsed wording.
		huci_domain=$(hub_group_field "$huci_group" 3)
		huci_features=''
		if [ -n "$huci_domain" ]; then
			huci_features=$(hub_domain_feature_keys "$huci_domain")
		fi
		if [ -n "$huci_features" ]; then
			hu_cascade_baseline_lines "$huci_glyph" "$huci_indent" "$huci_rows" "$huci_group"
			continue
		fi
		case $huci_group in
		"$HUB_GROUP_PREFIX_BASELINE":*)
			hu_cascade_baseline_lines "$huci_glyph" "$huci_indent" "$huci_rows" "$huci_group"
			;;
		*)
			huci_group="$huci_group" awk -F '\t' \
				'$2 == ENVIRON["huci_group"] { print $3 }' "$huci_rows" >"$huci_displays"
			while IFS= read -r huci_display; do
				[ -n "$huci_display" ] || continue
				printf '%s%s %s — %s\n' \
					"$huci_indent" "$huci_glyph" "$huci_display" "$HU_CASCADE_REASON"
			done <"$huci_displays"
			;;
		esac
	done <"$huci_groups"
}

# hu_preview_remove_items -> the "Remove:" block's itemization: ONE line per thing
# the user actually SELECTED — a technology, a backend, a dangling orphan — named
# the way the checklist named it, with the number of units it takes out whenever
# that is more than one. Never one line per unit: a technology is one removable
# thing whose three units are an implementation detail, and itemizing them is what
# made this screen a 50-row wall.
#
# THE COUNTS COME FROM PREVIEW_ROWS (above), i.e. from REMOVE_ONLY joined through
# ROW_MAP, for two reasons: the per-row numbers then always add up to the header's
# own count, and a row whose every unit was HELD BACK by the retention rule drops
# out of this block entirely — it is reported under "Kept" instead, and claiming it
# here as well would say the same unit is both going and staying.
#
# --all ITEMIZES BY UNIT INSTEAD, deliberately. Its selection is every removable
# row there is, including per-unit baseline rows that are not selectable
# technologies at all, so a row-level list would name the same units under
# whichever key happened to claim them first. A bulk removal is also the one
# screen where the full per-unit list is what a reader wants: it is the last look
# at exactly what --all covers.
hu_preview_remove_items() {
	if [ "$OPT_ALL" -eq 1 ]; then
		while IFS="$HUB_TAB" read -r _ _ hupri_display _; do
			[ -n "$hupri_display" ] || continue
			printf '    %s %s\n' "$(hub_glyph_remove)" "$hupri_display"
		done <"$REMOVE_ONLY"
		return 0
	fi
	hu_row_lines "$(hub_glyph_remove)" '    ' "$PREVIEW_ROWS" "$REMOVE_ONLY"
}

# hu_result_remove_items -> the Result screen's receipt, at the granularity the user
# actually chose at: one line per TECHNOLOGY or BACKEND that came out ("✓ Java
# (3 items)"), one line per cascaded domain baseline ("✓ Software Development
# baseline (44 items)"), and one line per orphan — an orphan is nobody's group, so it
# has nothing to collapse into and stays its own line, which is correct.
#
# EVERY LINE AND EVERY COUNT IS DERIVED FROM REMOVED, never from the plan. That is
# the receipt property this screen has always had and keeps: a unit whose path was
# occupied by a foreign file never reaches REMOVED, so its technology honestly
# collapses to "✓ Java (2 items)" against a preview that promised 3, and
# hub_report_foreign_blocked names that specific unit immediately below. A collapsed
# line can therefore never claim a unit that did not actually come out.
#
# --all ITEMIZES BY UNIT INSTEAD, for the identical reason hu_preview_remove_items
# does on that path (see there): its selection is every removable row there is, so a
# row-level list would name the same units under whichever key claimed them first,
# and the full per-unit list is what a reader wants from a bulk removal anyway. It is
# also the only path whose REMOVED holds the first-run bundle's own items, which
# belong to no row at all.
hu_result_remove_items() {
	if [ "$OPT_ALL" -eq 1 ]; then
		while IFS="$HUB_TAB" read -r _ hurri_display; do
			[ -n "$hurri_display" ] || continue
			printf '  %s %s\n' "$(hub_glyph_ok)" "$hurri_display"
		done <"$REMOVED"
		return 0
	fi

	# REMOVED minus the cascaded rows, exactly as REMOVE_ONLY is REMOVE_UNITS minus
	# them and for the same reason: the row block and the cascade block below must
	# not both claim the same unit.
	#
	# RE-WIDENED TO REMOVE_ONLY'S OWN FOUR COLUMNS (name, kind, display, SRC-LAST) by
	# picking up kind and src from REMOVE_UNITS, because hu_row_lines' feature path
	# classifies by src path and REMOVED carries only name and display. The DISPLAY
	# still comes from REMOVED — it is the receipt's own record of what came out — and
	# a REMOVED row with no REMOVE_UNITS entry keeps its line with the two extra
	# columns empty rather than being dropped by an inner join, so the reconciliation
	# guard further down can still report it. (Only the first-run bundle's items are
	# ever in that position, and the --all path above returns before this.)
	#
	# The phase test is FILENAME == ARGV[n], never FNR == NR: with three inputs the NR
	# trick cannot name the middle file at all, and an EMPTY CASCADED — the normal case
	# — would make the second file's first record satisfy it anyway. The same shape
	# hub-doctor.sh's hd_diverged_plan_build states for its own three-file join.
	hurri_row_units="$HUB_WORK/removed-row-units.tsv"
	awk -F '\t' -v OFS='\t' '
		FILENAME == ARGV[1] { cascaded[$1] = 1; next }
		FILENAME == ARGV[2] { kind[$1] = $2; src[$1] = $4; next }
		!($1 in cascaded) { print $1, kind[$1], $2, src[$1] }
	' "$CASCADED" "$REMOVE_UNITS" "$REMOVED" >"$hurri_row_units"
	hurri_rows="$HUB_WORK/removed-rows.tsv"
	hu_row_counts_build "$hurri_row_units" "$hurri_rows"
	hu_row_lines "$(hub_glyph_ok)" '  ' "$hurri_rows" "$hurri_row_units"

	# The cascaded rows that ACTUALLY came out, rendered by the same collapser the
	# preview's "Also removing" block uses — a baseline is one line here too.
	hurri_cascaded="$HUB_WORK/removed-cascaded.tsv"
	awk -F '\t' '
		FNR == NR && FILENAME == ARGV[1] { removed[$1] = 1; next }
		($1 in removed)
	' "$REMOVED" "$CASCADED" >"$hurri_cascaded"
	hu_cascade_items "$(hub_glyph_ok)" '  ' "$hurri_cascaded"

	# RECONCILIATION GUARD, and the reason it is not dead code: REMOVED is written by
	# two producers (the unit loop and the bundle loop) while the two blocks above can
	# only account for what ROW_MAP and CASCADED know about. Anything else would
	# otherwise vanish from the receipt while still being counted in the header above
	# it — a list that silently fails to add up to its own total. Today this prints
	# nothing on a selective uninstall; the day it prints something, that IS the fact
	# the reader needs.
	hurri_unattributed="$HUB_WORK/removed-unattributed.tsv"
	awk -F '\t' '
		FNR == NR && FILENAME == ARGV[1] { row[$1] = 1; next }
		!($1 in row)
	' "$ROW_MAP" "$hurri_row_units" >"$hurri_unattributed"
	# AWK-ONLY, never `read`: this table carries REMOVE_ONLY's own column order
	# (name, kind, display, src), and kind (column 2) — not just src — can be
	# empty for exactly the bundle-item rows this guard exists to catch, so a
	# middle column here is nullable too, not only the last one. The same
	# awk-only rule REMOVABLE_ROWS states above for the identical reason
	# (lib/hub-common.sh, "THE TAB TRAP").
	awk -F '\t' -v ok="$(hub_glyph_ok)" '$3 != "" { printf "  %s %s\n", ok, $3 }' \
		"$hurri_unattributed"
}

# ===========================================================================
# THE PLAN LOOP — selection -> units -> retention -> preview -> confirm.
#
# A LOOP, not a straight line, for one reason: `b` on the confirm screen must go
# back ONE step to the checklist that produced the pending selection instead of
# discarding it. hub_confirm_gate returns 2 for back, and funnelling that into the
# same arm as a cancel threw the whole selection away — while the sibling `q` on
# that very screen is guarded by hub_discard_guard precisely to prevent that loss.
#
# Everything inside re-derives from SELECTED_ROWS on every pass and truncates what
# it appends to, so a second pass recomputes cleanly rather than accumulating.
# ===========================================================================
while :; do

if [ "$INTERACTIVE_SELECTION" -eq 1 ]; then
	HU_RC=0
	# "Select what to uninstall", NOT "Select items": "item" is a bound term
	# throughout this file meaning one UNIT ("Remove: 7 items", "(3 items)"), and a
	# screen whose whole point is that one tick is several items must not use that
	# word for a row. The SUBTITLE — hub_checklist's own "the actual question being
	# asked" slot, previously passed empty here — states the granularity rule plainly
	# instead of leaving the user to infer it from the preview one screen later.
	#
	# "EACH ROW", not "technologies and backends": those are no longer the only kinds of
	# row here (a self-contained domain is one too), and a subtitle that enumerates the
	# kinds has to be re-edited every time one is added while saying nothing more. The
	# rule is per-row either way.
	hub_checklist 'Select what to uninstall' \
		"Each row comes out in one piece; a domain's baseline follows automatically once nothing installed still needs it." \
		"$CHECKLIST_ROWS" "$SELECTED_ROWS" || HU_RC=$?
	case $HU_RC in
	# `b` on the only checklist has no earlier step to return to, so it leaves the
	# capability entirely — through hu_ok_exit, never a bare `exit 0`. A machine
	# caller reaching this on a TTY under --format=env|json would otherwise see an
	# empty stdout, which this script's own contract (see hu_ok_exit) forbids:
	# indistinguishable from a crash before any output.
	1) hu_ok_exit 'Nothing changed — went back without selecting anything.' ;;
	2) exit 3 ;;
	esac
fi

if [ ! -s "$SELECTED_ROWS" ]; then
	hu_ok_exit 'Nothing selected — nothing removed.'
fi

# ---------------------------------------------------------------------------
# Rows -> units.
# ---------------------------------------------------------------------------
# REMOVE_UNITS columns: name, kind, display, SRC-LAST. src is empty for an
# orphan (that absence is what makes it an orphan), so it must be the final
# column — see lib/hub-common.sh's "THE TAB TRAP" for why an empty column
# anywhere else would silently shift the fields after it.
#
# ROW_MAP ("unit<TAB>row key") and ROW_LABELS ("row key<TAB>display") exist so the
# preview can itemize what the user SELECTED — one line per technology or backend
# — while still counting in units. ROW_LABELS is the one place a row's on-screen
# name is decided, whichever of the vocabularies below named it.
#
# ROW_GROUPS ("row key<TAB>group") is the third of the same shape, and it exists
# because a row's LABEL cannot answer a question the itemization needs: which domain
# the row belongs to, and therefore whether that domain declares NAMED FEATURES to
# name its units by (hu_row_lines). Derived here rather than re-resolved at render
# time, because this loop is where the group is already in hand — resolving it again
# from a row key would be a second implementation of the two-vocabulary lookup below.
# An ORPHAN gets no entry at all: it belongs to no group, which is what makes it an
# orphan, and hu_row_domain reads that absence as "no domain".
REMOVE_UNITS="$HUB_WORK/remove-units.tsv"
ROW_MAP="$HUB_WORK/row-map.tsv"
ROW_LABELS="$HUB_WORK/row-labels.tsv"
ROW_GROUPS="$HUB_WORK/row-groups.tsv"
: >"$REMOVE_UNITS"
: >"$ROW_MAP"
: >"$ROW_LABELS"
: >"$ROW_GROUPS"
while IFS= read -r HU_KEY; do
	[ -n "$HU_KEY" ] || continue
	HU_ORPHAN_KIND=$(hu_orphan_kind "$HU_KEY")
	if [ -n "$HU_ORPHAN_KIND" ]; then
		printf '%s\t%s\t%s\n' "$HU_KEY" "$HU_ORPHAN_KIND" "$HU_KEY" >>"$REMOVE_UNITS"
		printf '%s\t%s\n' "$HU_KEY" "$HU_KEY" >>"$ROW_MAP"
		printf '%s\t%s\n' "$HU_KEY" "$HU_KEY" >>"$ROW_LABELS"
		continue
	fi
	# TWO vocabularies resolve here, the checklist's own selection key first, then
	# HUB_ROWS' row key (a unit name, or an atomic group's row key). Either way, a
	# key belonging to a REMOVAL-ATOMIC group expands to that whole group, so
	# `--components=java-reviewer` takes the Java technology out rather than leaving
	# two thirds of it behind (see hu_removal_is_atomic, and this file's header on
	# what --components accepts).
	HU_GROUP=$(hu_selectable_group_of "$HU_KEY")
	if [ -z "$HU_GROUP" ]; then
		HU_GROUP=$(HU_KEY="$HU_KEY" awk -F '\t' '$1 == ENVIRON["HU_KEY"] { print $2; exit }' "$REMOVABLE_ROWS")
	fi
	if [ -n "$HU_GROUP" ] && hu_removal_is_atomic "$HU_GROUP"; then
		# THE CONTEXT-FREE FORM (hub_group_label_in_context), the same call the
		# checklist above makes, NOT the group table's raw column 2. ROW_LABELS is read
		# by hu_row_lines, which renders both the preview's "Remove:" block and the
		# Result screen's receipt — and NEITHER of those carries a domain heading, which
		# is exactly the heading-less condition that function exists for. A bare
		# "Jira (3 items)" under "Remove:" says nothing about which of the several Jira
		# things this hub touches is going; "Project Management (Jira) (3 items)" does,
		# and it is what the checklist that produced the tick already called it. All
		# three surfaces of this one screen now name one removable thing identically,
		# which is what hu_row_lines' own header claims of the receipt.
		HU_LABEL=$(hub_group_label_in_context "$HU_GROUP")
		# `$6 != "available"` — a unit with NOTHING at its path is not part of the
		# removal: including it changed no write (hub_unlink_unit reports
		# already-absent) but did inflate every count on the consent surface, so a
		# partially-installed technology promised more items than it could remove.
		# The row map below matches on the identical predicate; the two awks are kept
		# adjacent for exactly that reason.
		HU_GROUP="$HU_GROUP" awk -F '\t' -v OFS='\t' \
			'$1 == ENVIRON["HU_GROUP"] && $6 != "available" { print $2, $3, $5, $4 }' \
			"$HUB_STATES" >>"$REMOVE_UNITS"
		HU_GROUP="$HU_GROUP" HU_KEY="$HU_KEY" awk -F '\t' -v OFS='\t' \
			'$1 == ENVIRON["HU_GROUP"] && $6 != "available" { print $2, ENVIRON["HU_KEY"] }' \
			"$HUB_STATES" >>"$ROW_MAP"
	else
		# A non-atomic group's row IS its unit (a baseline item, a shared
		# procedure), so the row key is the unit name and the label is the row's own
		# display text from HUB_ROWS.
		HU_LABEL=$(HU_KEY="$HU_KEY" awk -F '\t' '$1 == ENVIRON["HU_KEY"] { print $3; exit }' "$REMOVABLE_ROWS")
		HU_KEY="$HU_KEY" awk -F '\t' -v OFS='\t' \
			'$2 == ENVIRON["HU_KEY"] { print $2, $3, $5, $4 }' "$HUB_STATES" >>"$REMOVE_UNITS"
		printf '%s\t%s\n' "$HU_KEY" "$HU_KEY" >>"$ROW_MAP"
	fi
	printf '%s\t%s\n' "$HU_KEY" "$HU_LABEL" >>"$ROW_LABELS"
	printf '%s\t%s\n' "$HU_KEY" "$HU_GROUP" >>"$ROW_GROUPS"
done <"$SELECTED_ROWS"
hub_dedup_first_field "$REMOVE_UNITS"
# FIRST claimant wins (hub_dedup_first_field keeps a key's first row), which is
# what makes a redundant selection — `--components=java,java-reviewer`, or --all's
# every-unit-key expansion — attribute each unit to one row instead of counting it
# once per key that named it.
hub_dedup_first_field "$ROW_MAP"

# ---------------------------------------------------------------------------
# The retention rules, in BOTH directions (see this file's header):
#   CASCADE  — NOT in the removal set, and nothing that stays installed needs it
#              any more -> comes out too, previewed explicitly. Two consumer sets
#              ask this: a DOMAIN's own selectable groups, for that domain's
#              baseline, and the cross-domain registry, for a shared group.
#   KEPT     — in the removal set, but a consumer remains -> held back. Shared
#              groups only: a domain's baseline is never in a removal set to
#              begin with, since nothing can select it.
# ---------------------------------------------------------------------------
KEPT="$HUB_WORK/kept.tsv"
CASCADED="$HUB_WORK/cascaded.tsv"
: >"$KEPT"
: >"$CASCADED"
HU_SHARED_UNITS="$HUB_WORK/shared-units.tsv"
HU_CONSUMER_NOTES="$HUB_WORK/consumer-notes.tsv"
HU_REMAINING="$HUB_WORK/remaining.txt"

# THE PER-DOMAIN BASELINE CASCADE, and it runs BEFORE the cross-domain loop
# below. The order is load-bearing, not stylistic: Software Development's
# baseline is one of the two consumers of the shared git-auth procedure, so with
# the cross-domain loop first, removing every technology cascaded the baseline out
# AFTER that loop had already decided the baseline was still installed — leaving
# git-auth behind, reachable by nothing, which is the exact unreachable leftover
# the CASCADE direction exists to collect. Baseline first, and the shared loop
# sees those units in REMOVE_UNITS and judges its consumers on what will actually
# be left. Nothing flows the other way: a shared group is never a domain's
# selectable group, so the shared loop's own result cannot change this pass's
# answer.
for HU_DOMAIN in $HUB_DOMAIN_KEYS; do
	# THIS GUARD KEYS ON THE SELECTION KIND, and it must keep doing so rather than on
	# the domain's group shape. A domain with NO sub-selection (today, GTD) has an
	# always-empty selectable-consumer set, which hu_domain_selection_remains below
	# cannot distinguish from "everything it had is going out" — so without this line
	# such a domain would cascade on EVERY unrelated uninstall. That is the sweep bug,
	# and it is why the guard is not rewritten as a test for "does this domain have a
	# baseline group": both tests skip GTD today, but only this one states the reason,
	# and the other would silently start cascading a `none` domain the day one is given
	# a baseline group alongside its own content. Such a domain needs no cascade
	# anyway — it is SELECTED, whole, like any other selectable group.
	[ "$(hub_domain_selection_kind "$HU_DOMAIN")" != none ] || continue
	# The accessor, not a constructed key: a domain that reaches this line has a
	# sub-selection and therefore a baseline group, so this is belt-and-braces rather
	# than load-bearing — but a constructed key would hand hu_group_in_plan and
	# hu_cascade_group a group that may not exist, which is exactly the assumption
	# hub_domain_baseline_group exists to stop being made anywhere.
	HU_BASELINE=$(hub_domain_baseline_group "$HU_DOMAIN")
	[ -n "$HU_BASELINE" ] || continue
	# Already in the removal set (--all, or a per-unit --components key naming a
	# baseline item): there is nothing to cascade, the selection said it itself.
	! hu_group_in_plan "$HU_BASELINE" || continue
	hu_domain_selection_remains "$HU_DOMAIN" || hu_cascade_group "$HU_BASELINE"
done

for HU_SHARED in $(hub_groups_of_role shared); do
	hub_group_units "$HU_SHARED" >"$HU_SHARED_UNITS"
	# The consumer annotations are materialized to a file once, rather than
	# re-derived inside the notes loop below via a heredoc nested in a command
	# substitution nested in a loop — which parses, but is exactly the kind of
	# construction that silently misbehaves the next time anyone edits it.
	hub_shared_consumers "$HU_SHARED" >"$HU_CONSUMER_NOTES"
	hub_shared_consumers_remaining "$HU_SHARED" "$REMOVE_UNITS" >"$HU_REMAINING"

	if hu_group_in_plan "$HU_SHARED"; then
		# KEPT — in the plan, but at least one consumer stays installed. With no
		# consumer left, the selection is honored as given and nothing is held back.
		[ -s "$HU_REMAINING" ] || continue
		hu_keep_shared
	else
		# CASCADE — not in the plan, and NO consumer is left installed once the
		# removal is done. A shared unit whose consumers are all gone is unreachable
		# by anything and would otherwise stay installed forever, since no component
		# selection names it. See this file's header for why the trigger is
		# deliberately not narrowed to "this removal takes the last consumer".
		[ -s "$HU_REMAINING" ] && continue
		hu_cascade_group "$HU_SHARED"
	fi
done

REMOVE_COUNT=$(hub_count_lines "$REMOVE_UNITS")
KEPT_COUNT=$(hub_count_lines "$KEPT")
CASCADED_COUNT=$(hub_count_lines "$CASCADED")

# REMOVE_ONLY — REMOVE_UNITS minus the cascaded rows, i.e. exactly what the
# preview's "Remove:" block accounts for: its header count, and (through ROW_MAP)
# the per-row item counts beside each selected technology or backend. A cascaded
# unit IS in REMOVE_UNITS (it is genuinely being removed, and the apply loop must
# walk it), but it is announced by the "Also removing" block below; without this
# subtraction it was counted TWICE, once in each block, which reads as two
# different sets of items going out.
#
# The count comes from `wc -l` of the filtered file rather than the arithmetic
# REMOVE_COUNT - CASCADED_COUNT, so the header number cannot drift from the rows
# actually listed under it. TOTAL stays keyed to REMOVE_COUNT and therefore remains
# inclusive of both blocks — a cascaded unit is a real removal.
#
# The phase test is FNR == NR && FILENAME == ARGV[1], not a bare FNR == NR: an
# EMPTY CASCADED is the normal case, and with a bare test awk (which never reads a
# record from an empty first file) would mis-file REMOVE_UNITS' own first row as a
# cascaded key and drop it. Same trap as hub_units_of_groups documents.
#
# CASCADED's column 1 is still the unit NAME, which is what this join keys on, and
# it stays per-unit even though the "Also removing" block now COLLAPSES a cascaded
# baseline group to one line: the display granularity is a rendering choice, the
# subtraction is an identity comparison, and conflating the two is how a collapsed
# baseline unit would reappear under "Remove:" as well.
REMOVE_ONLY="$HUB_WORK/remove-only.tsv"
awk -F '\t' '
	FNR == NR && FILENAME == ARGV[1] { cascaded[$1] = 1; next }
	!($1 in cascaded)
' "$CASCADED" "$REMOVE_UNITS" >"$REMOVE_ONLY"
REMOVE_ONLY_COUNT=$(hub_count_lines "$REMOVE_ONLY")

# The post-resolution row set both consent-surface counts read (see
# hu_row_counts_build). Built here, not inside the preview's brace group: the
# confirm stage's discard guard needs it too, and that runs after the group closes.
PREVIEW_ROWS="$HUB_WORK/preview-rows.tsv"
: >"$PREVIEW_ROWS"
hu_row_counts_build "$REMOVE_ONLY" "$PREVIEW_ROWS"

# The first-run bundle comes out only on a complete uninstall. A selective
# uninstall never touches CLAUDE.md or the contract schemas: they are not any
# domain's component, so no selection of components can imply removing them.
BUNDLE_REMOVE=$OPT_ALL

# ---------------------------------------------------------------------------
# CLAUDE.md backup selection (--all only).
# ---------------------------------------------------------------------------
RESTORE_TARGET=""
BACKUPS="$HUB_WORK/backups.txt"
: >"$BACKUPS"
if [ "$BUNDLE_REMOVE" -eq 1 ]; then
	hub_bundle_backups "$TARGET_DIR" >"$BACKUPS"
	BACKUP_COUNT=$(hub_count_lines "$BACKUPS")
	# --restore-backup IS CONSULTED FIRST, BEFORE the count branches below, and
	# that ordering is the fix for two silent failures. It used to be read only
	# inside the "more than one backup" arm, so with EXACTLY ONE backup present
	# `--restore-backup=none` was ignored outright and that backup was restored
	# anyway (and, per lib/hub-bundle.sh, consumed) — a caller's explicit
	# instruction not to touch its contract, silently inverted. A bogus timestamp
	# matching no real backup was ignored the same way instead of being rejected.
	# The count now decides only what happens when the caller said NOTHING, and a
	# named timestamp is validated against the backups that actually exist however
	# many that is — including none, where naming one is a usage error and not a
	# no-op.
	if [ -n "$OPT_RESTORE_BACKUP" ]; then
		if [ "$OPT_RESTORE_BACKUP" = none ]; then
			RESTORE_TARGET=""
		else
			# An exact whole-line match against the fully-qualified backup
			# path, not a substring/suffix search: a timestamp is
			# attacker-irrelevant but user-typo-prone, and a partial match
			# would happily restore a DIFFERENT backup than the one named.
			RESTORE_TARGET=$(grep -xF -- "$TARGET_DIR/$HUB_BUNDLE_CONFIG_NAME.backup.$OPT_RESTORE_BACKUP" "$BACKUPS") ||
				die_usage "no backup matches --restore-backup=$OPT_RESTORE_BACKUP"
		fi
	elif [ "$BACKUP_COUNT" -eq 1 ]; then
		RESTORE_TARGET=$(cat "$BACKUPS")
	elif [ "$BACKUP_COUNT" -gt 1 ]; then
		if ! hub_interactive; then
			hu_blocked restore_selection_required \
				"multiple $HUB_BUNDLE_CONFIG_NAME backups found; pass --restore-backup=<timestamp> or --restore-backup=none"
		fi
		hu_choose_backup
	fi
fi

# ---------------------------------------------------------------------------
# Preview. Always human-readable text, in EVERY mode — the dry run is the
# informed-consent surface and an agent-facing caller reads it too. The block is
# wrapped in `{ ... } >&3` (the human channel opened at the top of this script);
# a brace group, not a subshell, so the variables it sets — notably TOTAL, which
# the confirm and result stages both need — survive it.
# ---------------------------------------------------------------------------
{
if [ "$OPT_ALL" -eq 1 ]; then
	hub_print_header "Uninstall ALL from $TARGET_DIR"
else
	# PREVIEW_ROWS, never SELECTED_ROWS: the count has to be the number of rows the
	# block below actually itemizes, and the group-atomic resolution can make the raw
	# selection longer than that (see hu_row_counts_build).
	SELECTED_COUNT=$(hub_count_lines "$PREVIEW_ROWS")
	hub_print_header "Uninstall $SELECTED_COUNT selected from $TARGET_DIR"
fi
printf '\n'

if [ "$REMOVE_ONLY_COUNT" -gt 0 ]; then
	# The header counts ITEMS (units) so it agrees with the total line below and
	# with the Result screen's own arithmetic, while the list itemizes the THINGS
	# THE USER PICKED — see hu_preview_remove_items, which also explains why the
	# two always add up.
	printf '  Remove: %s %s\n' "$REMOVE_ONLY_COUNT" "$(hub_plural "$REMOVE_ONLY_COUNT" item items)"
	hu_preview_remove_items
	printf '\n'
fi

if [ "$CASCADED_COUNT" -gt 0 ]; then
	printf '  Also removing (nothing that stays installed requires these any more):\n'
	# The whole itemization — the baseline collapse, the shared group's per-name
	# lines, the trailing reason — is hu_cascade_items, shared with the Result
	# screen's own receipt of the same cascade. The plan is passed WHOLE here: at
	# preview time every cascaded row is still going out.
	hu_cascade_items "$(hub_glyph_remove)" '    ' "$CASCADED"
	printf '\n'
fi

if [ "$KEPT_COUNT" -gt 0 ]; then
	printf '  Kept (still required by something that stays installed):\n'
	while IFS="$HUB_TAB" read -r HU_DISPLAY HU_NOTES; do
		[ -n "$HU_DISPLAY" ] || continue
		printf '    = %s — still required by: %s\n' "$HU_DISPLAY" "$HU_NOTES"
	done <"$KEPT"
	printf '\n'
fi

TOTAL=$REMOVE_COUNT
if [ "$BUNDLE_REMOVE" -eq 1 ]; then
	BUNDLE_COUNT=$(hub_bundle_count "$FRAMEWORK_ROOT")
	TOTAL=$((TOTAL + BUNDLE_COUNT))
	printf "  Also removing (the framework's own operating contract, removed last):\n"
	printf '    %s %s and %s contract %s\n' "$(hub_glyph_remove)" "$HUB_BUNDLE_CONFIG_NAME" \
		"$((BUNDLE_COUNT - 1))" "$(hub_plural "$((BUNDLE_COUNT - 1))" schema schemas)"
	if [ -n "$RESTORE_TARGET" ]; then
		printf '\n  A backed-up %s was found and will be restored:\n' "$HUB_BUNDLE_CONFIG_NAME"
		printf '    %s %s %s\n' "${RESTORE_TARGET##*/}" "$(hub_glyph_arrow)" "$HUB_BUNDLE_CONFIG_NAME"
	fi
	printf '\n'
fi

printf '  %s %s total. Nothing has changed yet.\n' "$TOTAL" "$(hub_plural "$TOTAL" item items)"

printf '\n'
hub_dry_run_marker
printf '\n'
} >&3

# OUTSIDE the preview group, deliberately — matching hub-install.sh's equivalent
# check. Called INSIDE it, hu_ok_exit's machine payload (the HUB_STATUS=ok lines,
# or the JSON document) went to fd 1, which the group redirects to fd 3, i.e.
# stderr under --format=env|json — leaving stdout completely EMPTY and breaking
# this script's own invariant that a machine caller always receives a HUB_STATUS
# line on stdout. Reachable whenever every selected row resolves to "Kept".
if [ "$TOTAL" -eq 0 ]; then
	hu_ok_exit 'Nothing to remove.'
fi

# ---------------------------------------------------------------------------
# Confirm. Uninstall-all is the one critical-tier flow: it removes the
# framework's own operating contract, and the multiple-backups case means the
# exact prior state is not always deterministically restorable. That reason is
# printed on screen, not merely recorded in a spec.
# ---------------------------------------------------------------------------
if [ "$OPT_ALL" -eq 1 ]; then
	printf '  %s\n' "$(hub_c "$HUB_CRITICAL_COLOR" "WARNING: this removes $HUB_BUNDLE_CONFIG_NAME and the framework's contract")" >&3
	printf '  %s\n\n' "$(hub_c "$HUB_CRITICAL_COLOR" 'schemas — a full restore to your exact prior state is not guaranteed.')" >&3
fi

# --apply gates reaching a confirm prompt on a FLAG-DRIVEN selection, on a TTY as
# much as off one — the same contract hub-install.sh states for its own --apply.
# The interactive checklist walk is unaffected: walking it IS the request.
if [ "$OPT_APPLY" -eq 0 ] && [ "$INTERACTIVE_SELECTION" -eq 0 ]; then
	hu_ok_exit 'Nothing changed. Re-run with --apply to uninstall.'
fi

if ! hub_interactive; then
	if [ "$OPT_ALL" -eq 1 ] && [ "$OPT_CONFIRM" != "$HUB_CRITICAL_PHRASE" ]; then
		hu_blocked confirmation_required "critical action requires --confirm=$HUB_CRITICAL_PHRASE"
	fi
	break
elif [ "$OPT_ALL" -eq 1 ]; then
	# The critical typed-phrase gate has no "back" answer — --all is not a
	# selection anyone navigated to — so it stays a plain confirm/cancel.
	hub_confirm_typed_phrase "$HUB_CRITICAL_PHRASE" || hu_ok_exit 'Nothing changed.'
	break
else
	# The gate's second argument is the PENDING SELECTION size — the rows the user
	# ticked — not the resolved unit count. It is only ever used by
	# hub_discard_guard's "Discard N selected items and quit?", and passing
	# REMOVE_COUNT offered to discard every unit those rows expand to, which is not
	# a number the user ever chose.
	#
	# PREVIEW_ROWS, the same post-resolution set the preview header and its
	# itemization use, so the guard cannot offer to discard more rows than the screen
	# above it just listed (see hu_row_counts_build).
	HU_GATE=0
	hub_confirm_gate dangerous "$(hub_count_lines "$PREVIEW_ROWS")" || HU_GATE=$?
	case $HU_GATE in
	0) break ;;
	2)
		# BACK, not cancel. The pending selection is kept and the checklist is
		# re-entered (hub_checklist pre-seeds from SELECTED_ROWS), so `b` behaves
		# here like `b` everywhere else instead of destroying the selection the
		# sibling `q` on this same screen is explicitly guarded against losing.
		if [ "$INTERACTIVE_SELECTION" -eq 1 ]; then
			continue
		fi
		# A flag-driven selection has no earlier step to return to.
		hu_ok_exit 'Cancelled. Nothing changed.'
		;;
	3)
		printf 'Cancelled. Nothing changed.\n' >&3
		exit 3
		;;
	*)
		hu_ok_exit 'Cancelled. Nothing changed.'
		;;
	esac
fi

done

# ---------------------------------------------------------------------------
# Apply.
# ---------------------------------------------------------------------------
# REMOVED columns: unit name, DISPLAY-LAST. It carries the NAME as well as the
# display text because the Result screen groups its receipt back through ROW_MAP and
# CASCADED, both of which key on the unit name — an exact key comparison, never a
# display string (the same identity-vs-rendering split REMOVE_ONLY's own note makes).
# The count this file publishes as HUB_ACTED_ON_COUNT is still one line per unit, so
# the machine payload is unchanged by the extra column.
#
# The display is LAST because it is the only one of the two that could ever be empty;
# a name never is (see lib/hub-common.sh's "THE TAB TRAP").
#
# FOREIGN_BLOCKED stays a plain display-per-line list: it is emitted verbatim as
# machine payload (hub_emit_itemized_env / hub_itemized_json_array) and is never
# grouped.
REMOVED="$HUB_WORK/removed.tsv"
FOREIGN_BLOCKED="$HUB_WORK/foreign-blocked.txt"
: >"$REMOVED"
: >"$FOREIGN_BLOCKED"

while IFS="$HUB_TAB" read -r HU_NAME HU_KIND HU_DISPLAY HU_SRC; do
	[ -n "$HU_NAME" ] || continue
	if [ -z "$HU_SRC" ]; then
		HU_OUTCOME=$(hub_unlink_orphan "$HU_NAME" "$HU_KIND" "$TARGET_DIR" "$FRAMEWORK_ROOT" 1)
	else
		HU_OUTCOME=$(hub_unlink_unit "$HU_KIND" "$HU_NAME" "$HU_SRC" "$TARGET_DIR" "$FRAMEWORK_ROOT" 1 1)
	fi
	case $HU_OUTCOME in
	foreign-blocked) printf '%s\n' "$HU_DISPLAY" >>"$FOREIGN_BLOCKED" ;;
	already-absent) : ;;
	*) printf '%s\t%s\n' "$HU_NAME" "$HU_DISPLAY" >>"$REMOVED" ;;
	esac
done <"$REMOVE_UNITS"

# The bundle comes out LAST, as the explicit final step: it is the framework's
# own operating contract, and removing it before the components it governs would
# leave a window where the target has agents but no contract telling anything how
# to use them.
if [ "$BUNDLE_REMOVE" -eq 1 ]; then
	BUNDLE_LOG="$HUB_WORK/bundle.tsv"
	hub_bundle_remove "$FRAMEWORK_ROOT" "$TARGET_DIR" 1 "$RESTORE_TARGET" >"$BUNDLE_LOG"
	while IFS="$HUB_TAB" read -r HU_OUTCOME HU_ITEM; do
		[ -n "$HU_ITEM" ] || continue
		case $HU_OUTCOME in
		foreign-blocked) printf '%s\n' "$HU_ITEM" >>"$FOREIGN_BLOCKED" ;;
		already-absent) : ;;
		# A bundle item belongs to no group and to no row — it is not any domain's
		# component — so it is its own identity here, and the Result screen prints it
		# on its own line. Reached on the --all path only, which itemizes by unit
		# anyway.
		*) printf '%s\t%s\n' "$HU_ITEM" "$HU_ITEM" >>"$REMOVED" ;;
		esac
	done <"$BUNDLE_LOG"
fi

REMOVED_COUNT=$(hub_count_lines "$REMOVED")
FOREIGN_BLOCKED_COUNT=$(hub_count_lines "$FOREIGN_BLOCKED")
HU_COMPONENTS_CSV=$(tr '\n' ',' <"$SELECTED_ROWS" | sed 's/,$//')

# THE BACKUP THAT WAS ACTUALLY CONSUMED, as lib/hub-bundle.sh reports it — never
# RESTORE_TARGET, which is only what this run INTENDED to restore. A foreign
# occupant at the CLAUDE.md path blocks the restore (the backup is deliberately
# left in place so it can still be recovered by hand), and reporting the intent
# there told the user their own contract was back when it was not. Empty on every
# path that restored nothing, including a selective uninstall, which never calls
# hub_bundle_remove at all and so never sets the variable.
HU_RESTORED_NAME=${HUB_BUNDLE_RESTORED:-}
HU_RESTORED_NAME=${HU_RESTORED_NAME##*/}

case $OPT_FORMAT in
env)
	hub_env_kv HUB_STATUS ok
	hub_env_kv HUB_ACTION "$HU_ACTION"
	# HUB_APPLIED on the SUCCESS path too, matching the no-op exits' own payload:
	# two HUB_STATUS=ok results with different field sets force a caller to guess
	# which kind of ok it got.
	hub_env_kv HUB_APPLIED true
	hub_env_kv HUB_REQUESTED_ITEMS "$([ "$OPT_ALL" -eq 1 ] && printf all || printf '%s' "$HU_COMPONENTS_CSV")"
	hub_env_kv HUB_ACTED_ON_COUNT "$REMOVED_COUNT"
	hub_env_kv HUB_ATTEMPTED_COUNT "$TOTAL"
	hub_env_kv HUB_BUNDLE_REMOVED "$([ "$BUNDLE_REMOVE" -eq 1 ] && printf true || printf false)"
	hub_env_kv HUB_BUNDLE_RESTORED "$HU_RESTORED_NAME"
	hub_env_kv HUB_KEPT_COUNT "$KEPT_COUNT"
	hub_emit_itemized_env HUB_FOREIGN_BLOCKED "$FOREIGN_BLOCKED"
	;;
json)
	have jq || die "--format=json requires jq, which is not installed"
	HU_FB_JSON=$(hub_itemized_json_array "$FOREIGN_BLOCKED")
	jq -n --arg action "$HU_ACTION" \
		--arg requested "$([ "$OPT_ALL" -eq 1 ] && printf all || printf '%s' "$HU_COMPONENTS_CSV")" \
		--arg bundle_restored "$HU_RESTORED_NAME" \
		--argjson acted_on_count "$REMOVED_COUNT" --argjson attempted_count "$TOTAL" \
		--argjson bundle_removed "$([ "$BUNDLE_REMOVE" -eq 1 ] && printf true || printf false)" \
		--argjson kept_count "$KEPT_COUNT" \
		--argjson foreign_blocked_count "$FOREIGN_BLOCKED_COUNT" \
		--slurpfile foreign_blocked_items "$HU_FB_JSON" \
		'{status:"ok", action:$action, applied:true, requested_items:$requested,
		  acted_on_count:$acted_on_count, attempted_count:$attempted_count,
		  bundle_removed:$bundle_removed, bundle_restored:$bundle_restored,
		  kept_count:$kept_count, foreign_blocked_count:$foreign_blocked_count,
		  foreign_blocked_items:$foreign_blocked_items}'
	;;
text)
	# The Result screen carries the nav hint, as both specs' mockups show, and the
	# pause below actually honours the keys it advertises.
	hub_print_header "$(printf 'Uninstalled %s/%s %s from %s' "$REMOVED_COUNT" "$TOTAL" \
		"$(hub_plural "$TOTAL" item items)" "$TARGET_DIR")"
	if [ -n "$HU_RESTORED_NAME" ]; then
		printf '  %s restored %s from %s\n' "$(hub_glyph_ok)" "$HUB_BUNDLE_CONFIG_NAME" "$HU_RESTORED_NAME"
	fi

	# SELECTIVE results always itemize; only the bulk --all result summarizes and
	# offers the follow-up prompt (see hub_result_details).
	#
	# A RECEIPT OF REAL FILESYSTEM WRITES, still — that reasoning stands and is what
	# keeps this block reading REMOVED rather than the plan: every line and every
	# count below reports what the unlink loop ACTUALLY reported, never what the
	# preview intended. What no longer follows from it is FLAT PER-UNIT lines. Since
	# the redesign made a technology/backend the atomic removal unit, "✓ Java
	# (3 items)" is a receipt for precisely the thing the user ticked, and it is no
	# less true than three separate lines — while 44 baseline lines are not more
	# honest than one, they are just longer.
	#
	# HONESTY UNDER A PARTIAL REMOVAL is what the counts are recomputed for: they are
	# derived from REMOVED alone, so a technology whose third unit hit a foreign
	# occupant collapses to "✓ Java (2 items)", not "(3 items)", and
	# hub_report_foreign_blocked below names that one unit specifically. The collapsed
	# line cannot claim a unit that did not come out; the per-unit fact a reader needs
	# is still on screen, on the line that is actually about it.
	#
	# See hu_result_remove_items for the granularity rules, including why --all still
	# itemizes by unit and why an orphan stays its own line.
	hub_result_details "$OPT_DETAILS" "$OPT_ALL"
	if [ "$HUB_SHOW_DETAILS" -eq 1 ]; then
		hu_result_remove_items
	fi
	hub_report_foreign_blocked "$FOREIGN_BLOCKED" \
		'left untouched — a file that is not framework-owned occupies its path. Move or remove it, then retry. See "List".'
	printf '\n'
	printf '  %s Run "Doctor" to verify, or "List" to see the updated state.\n' "$(hub_glyph_arrow)"
	if [ "$OPT_ALL" -eq 1 ]; then
		printf '  %s To reverse: choose "Install all".\n' "$(hub_glyph_arrow)"
	else
		printf '  %s To reverse: open "Install" and choose the domains, technologies or backends you want back.\n' "$(hub_glyph_arrow)"
	fi
	if hub_interactive; then
		# `q` at the pause means "quit the hub", which is exit 3 — the same code
		# every other interactive screen uses for it.
		HU_PAUSE=0
		hub_press_key_to_continue || HU_PAUSE=$?
		[ "$HU_PAUSE" -ne 3 ] || exit 3
	fi
	;;
esac

exit 0
