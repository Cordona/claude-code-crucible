#!/usr/bin/env sh
# hub-install.sh — Capability: install, at DOMAIN granularity. One script,
#                   because "install all" is the select-everything case of the
#                   same computation, not a second feature: both walk the same
#                   selection -> groups -> units -> preview -> confirm -> apply
#                   pipeline.
#
# Usage:
#   hub-install.sh [--domains=a,b] [--technologies=a,b] [--sd-vcs=a,b]
#                  [--pm-trackers=a,b] [--all] [--apply] [--non-interactive]
#                  [--accessible] [--details] [--target DIR] [--source DIR]
#                  [--format=text|env|json] [--no-color] [-h|--help]
#
#   --domains CSV       Install exactly these domains. Each domain always brings
#                        its own baseline; a domain with a sub-selection also
#                        needs its matching flag below.
#   --technologies CSV  Software Development only: which technologies (a
#                        developer agent, its reviewer and its standard, whichever
#                        of the three exist).
#   --sd-vcs CSV        Software Development only, OPTIONAL: which VCS host(s)
#                        git-operator's PR/MR skill talks to — github, gitlab, or
#                        both. Every other specialist and git-operator's own
#                        local commit/branch/tag skills install regardless;
#                        omitting this flag (or giving it nothing) is a valid
#                        "no PR/MR automation" answer, never a blocked run.
#   --pm-trackers CSV   Project Management only: github, gitlab, jira, or any combination.
#   --all               Every domain, every technology, every VCS host, every tracker.
#   --apply             Perform the writes. Absent: preview only (the dry run) —
#                        on EVERY path, including a TTY. A flag-driven selection
#                        without --apply prints its preview and stops there; it
#                        never reaches the confirm prompt, so a bare Enter cannot
#                        turn a dry run into an install. Only the pure interactive
#                        walk (no selection flags at all) confirms-then-writes,
#                        which is what the user asked for by walking it.
#   --non-interactive   Never prompt; requires --domains or --all.
#   --accessible        Render the ASCII fallback for every non-ASCII SYMBOL:
#                        glyphs, hint/list separators and the truncation ellipsis.
#                        Em-dashes inside free prose message text are deliberately
#                        left as-is (they are punctuation, not symbols — see
#                        lib/hub-render.sh's HUB_ASCII note).
#                        Opt-in only, never auto-detected. Independent of
#                        --no-color: pass both when a terminal needs both.
#   --details           Result screen: itemize instead of summarizing. Only a BULK
#                        (--all) result summarizes by default; a SELECTIVE result
#                        always itemizes, so this flag changes nothing there.
#   --target DIR        Deployed config dir (default: $HOME/.claude).
#   --source DIR        Framework root to scan (default: the hub's own tree).
#   --format FMT        text (default) | env | json — governs only the FINAL
#                        result rendering; the preview is always human-readable
#                        text, matching the spec's own agent-facing dry-run.
#   --no-color          Disable ANSI color.
#   -h, --help          Show this help.
#
# Exit codes:
#   0  preview shown / nothing to install / cancelled / applied successfully.
#   1  blocked (a domain needs a sub-selection that was not given), or an
#      internal write failure.
#   2  usage error (bad flag, unknown domain/technology/tracker name).
#   3  the user pressed q to quit the hub from an interactive screen. A distinct
#      code because "cancel this action" and "quit the program" are different
#      answers, and the entrypoint must be able to tell them apart: exiting 0
#      for both would drop the user back on the Main menu they just asked to
#      leave.
#
# HUB_STATUS vocabulary: ok | blocked. HUB_BLOCKED_REASON is a CLOSED set, and
# the set is published in the base UI spec
# (.crucible/docs/specs/2026/07/30/crucible-management-hub-ui.draft.md, "Agent-
# facing mode"), NOT here — this header only names which member this script emits.
# The value below was added to that published set explicitly, following the
# precedent of `dependency_unresolved`, rather than being invented at the point of
# use:
#   selection_required — a selected domain has a mandatory sub-selection
#                        (Software Development's technologies, Project
#                        Management's trackers) and none was given. Never
#                        guessed: installing "some default technology" because
#                        the caller did not say is exactly the silent
#                        assumption the never-guess discipline forbids.
#
# Portability: POSIX sh only. jq is required ONLY for --format=json.
set -eu

HUB_PROG="crucible-hub install"
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
Usage: $HUB_PROG [--domains=a,b] [--technologies=a,b] [--sd-vcs=a,b]
                  [--pm-trackers=a,b] [--all] [--apply] [--non-interactive]
                  [--accessible] [--details] [--target DIR] [--source DIR]
                  [--format=text|env|json] [--no-color] [-h|--help]

With no --domains and no --all on a TTY, runs the interactive domain onboarding.
A flag-driven selection without --apply previews only and stops; it never reaches
the confirm prompt.

Options:
  --domains CSV       Install exactly these domains. Each domain always brings its
                       own baseline; a domain with a MANDATORY sub-selection also
                       needs its matching flag below, or the run is blocked rather
                       than given a guessed default.
  --technologies CSV  Software Development only: which technologies. One token per
                       technology installs its developer agent, its reviewer and its
                       standard together — whichever of the three exist.
  --sd-vcs CSV        Software Development only, OPTIONAL: github, gitlab, or both —
                       which host(s) git-operator's PR/MR skill talks to. Omitting
                       it (or giving it nothing) is a valid answer, never a block.
  --pm-trackers CSV   Project Management only: github, gitlab, jira, or any combination.
  --all               Every domain, every technology, every VCS host, every tracker.
  --apply             Perform the writes. Absent: preview only, on EVERY path,
                       including a TTY. A flag-driven selection without --apply
                       prints its preview and stops, so a bare Enter cannot turn a
                       dry run into an install; only the pure interactive walk
                       confirms-then-writes.
  --non-interactive   Never prompt; requires --domains or --all.
  --accessible        ASCII fallback for every non-ASCII symbol. Opt-in only, and
                       independent of --no-color: pass both when a terminal needs
                       both.
  --details           Result screen: itemize instead of summarizing. Only a BULK
                       (--all) result summarizes by default.
  --target DIR        Deployed config dir to install into (default: \$HOME/.claude).
  --source DIR        Framework root to scan (default: the hub's own tree).
  --format FMT        text (default) | env | json — governs only the FINAL result
                       rendering; the preview is always human-readable text.
  --no-color          Disable ANSI color.
  -h, --help          Show this help.
EOF
}

OPT_DOMAINS=""
OPT_TECHNOLOGIES=""
OPT_PM_TRACKERS=""
OPT_SD_VCS=""
OPT_ALL=0
OPT_APPLY=0
OPT_NONINTERACTIVE=0
OPT_DETAILS=0
OPT_TARGET=""
OPT_SOURCE=""
OPT_FORMAT=text
HUB_NO_COLOR=${HUB_NO_COLOR:-0}
FLAG_DRIVEN=0

while [ $# -gt 0 ]; do
	if hub_try_common_opt "$1" "${2:-}" "$#"; then
		shift "$HUB_COMMON_OPT_SHIFT"
		continue
	fi
	case $1 in
	--domains)
		[ $# -ge 2 ] || die_usage "--domains requires an argument"
		OPT_DOMAINS=$2
		FLAG_DRIVEN=1
		shift 2
		;;
	--domains=*)
		OPT_DOMAINS=${1#--domains=}
		FLAG_DRIVEN=1
		shift
		;;
	--technologies)
		[ $# -ge 2 ] || die_usage "--technologies requires an argument"
		OPT_TECHNOLOGIES=$2
		shift 2
		;;
	--technologies=*)
		OPT_TECHNOLOGIES=${1#--technologies=}
		shift
		;;
	--pm-trackers)
		[ $# -ge 2 ] || die_usage "--pm-trackers requires an argument"
		OPT_PM_TRACKERS=$2
		shift 2
		;;
	--pm-trackers=*)
		OPT_PM_TRACKERS=${1#--pm-trackers=}
		shift
		;;
	--sd-vcs)
		[ $# -ge 2 ] || die_usage "--sd-vcs requires an argument"
		OPT_SD_VCS=$2
		shift 2
		;;
	--sd-vcs=*)
		OPT_SD_VCS=${1#--sd-vcs=}
		shift
		;;
	--all)
		OPT_ALL=1
		FLAG_DRIVEN=1
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
# fd 3 — the HUMAN channel. Every human-readable line this script prints (the
# dry-run preview, no-op notices, the interactive Result screen) goes to fd 3;
# the machine formats' HUB_*=value lines and JSON document go to plain stdout.
#
# Under --format=text the two are the same place and nothing changes. Under
# --format=env/json, fd 3 is stderr, so stdout carries NOTHING but the machine
# payload and a caller can `eval` or `jq` it directly instead of first filtering
# human prose out of it — while still seeing the preview on its terminal or in
# its logs, which the informed-consent contract requires. Opened here, before
# the first possible no-op exit, so no output path can ever reach an unopened
# fd 3.
# ---------------------------------------------------------------------------
if [ "$OPT_FORMAT" = text ]; then
	exec 3>&1
else
	exec 3>&2
fi

if [ -n "$OPT_DOMAINS" ] && [ "$OPT_ALL" -eq 1 ]; then
	die_usage "--domains and --all are mutually exclusive"
fi
if [ "$OPT_NONINTERACTIVE" -eq 1 ] && [ "$FLAG_DRIVEN" -eq 0 ]; then
	die_usage "--non-interactive requires --domains or --all"
fi

[ -n "$OPT_TARGET" ] || OPT_TARGET=$(hub_default_target)
[ -n "$OPT_SOURCE" ] || OPT_SOURCE=$(hub_default_source)
TARGET_DIR=$(hub_abspath "$OPT_TARGET")
FRAMEWORK_ROOT=$(hub_realpath "$OPT_SOURCE") || die "cannot resolve --source: $OPT_SOURCE"

# The write-boundary contract of lib/hub-symlink.sh: every write this script
# performs is asserted to land inside one of TARGET_DIR's own deployment
# directories, and the assertion reads this variable. Set immediately after
# TARGET_DIR is resolved, before anything can write.
HUB_TARGET_DIR=$TARGET_DIR

hub_discovery_build "$FRAMEWORK_ROOT"
hub_states_build "$TARGET_DIR"

# ---------------------------------------------------------------------------
# Machine-status exits. Both live in lib/hub-common.sh (hub_ok_exit /
# hub_blocked): HUB_STATUS/HUB_BLOCKED_REASON is a published closed contract, and
# install and uninstall previously carried a near-identical copy each, differing
# only in this action string. These two wrappers bind that one argument so the
# call sites below stay readable.
# ---------------------------------------------------------------------------
HI_ACTION=install

# hi_ok_exit APPLIED MESSAGE -> a legitimate no-op or completed action, exit 0.
hi_ok_exit() {
	hub_ok_exit "$HI_ACTION" "$1" "$2"
}

# hi_blocked REASON MESSAGE -> a gated refusal, exit 1.
hi_blocked() {
	hub_blocked "$HI_ACTION" "$1" "$2"
}

# ---------------------------------------------------------------------------
# Selection. Three entry points, ONE output: SEL_DOMAINS plus one selection file
# per SUB-SELECTION KIND. Everything downstream reads only those files, so the
# flag-driven and interactive paths cannot diverge in what they are able to
# express — the human/agent parity requirement, enforced structurally rather than
# by keeping two code paths in sync.
#
# The per-kind files are NAMED AFTER THE KIND rather than after the domain that
# needs them, and are addressed through hi_sel_file/hi_rows_file. That is what
# lets the whole walk below be driven by hub_domain_selection_kind: a fourth
# domain reusing an existing kind gets its screen, its rows and its selection file
# for free.
# ---------------------------------------------------------------------------
SEL_DOMAINS="$HUB_WORK/sel-domains.txt"
: >"$SEL_DOMAINS"

# hi_sel_file KIND -> the selection file for one sub-selection kind.
hi_sel_file() {
	printf '%s/sel-%s.txt' "$HUB_WORK" "$1"
}

# hi_rows_file KIND -> the checklist-rows file for one sub-selection kind.
hi_rows_file() {
	printf '%s/rows-%s.tsv' "$HUB_WORK" "$1"
}

# hi_selection_kinds -> every sub-selection kind any domain in this source needs,
# in canonical domain order (and, within a multi-kind domain, that domain's own
# kind order — e.g. Software Development's `vcs` before `technology`), each
# listed once.
#
# THE INNER LOOP is what changed the moment a domain could carry more than one
# kind: hub_domain_selection_kind now returns a space-separated list, so this
# walks every word of it instead of treating the whole result as one kind.
hi_selection_kinds() {
	hisk_seen=""
	for hisk_domain in $HUB_DOMAIN_KEYS; do
		# ASSIGNED, never inlined as the for-list word: hub_domain_selection_kind
		# DIES on an unregistered domain, and a die inside a command substitution
		# used as a for-list is swallowed under `set -e` (the substitution simply
		# yields whatever it printed before dying — here, nothing — and the loop
		# runs zero times instead of the script failing). Unreachable today only
		# because every domain reaching this point already came from
		# $HUB_DOMAIN_KEYS itself; nothing structurally ties the two together.
		hisk_kinds=$(hub_domain_selection_kind "$hisk_domain")
		for hisk_kind in $hisk_kinds; do
			[ "$hisk_kind" != none ] || continue
			case " $hisk_seen " in
			*" $hisk_kind "*) continue ;;
			esac
			hisk_seen="$hisk_seen $hisk_kind"
			printf '%s\n' "$hisk_kind"
		done
	done
}

# The two names the RESULT PAYLOAD still refers to directly, because
# HUB_TECHNOLOGIES / HUB_PM_TRACKERS are per-kind fields of a published, closed
# machine contract and cannot be emitted by a generic loop without inventing key
# names. Read-only aliases for the per-kind files above, never a second source of
# truth: the selection, validation and preview paths all address these files
# through hi_sel_file so a kind added to the registry needs no edit there.
SEL_TECHNOLOGIES=$(hi_sel_file technology)
SEL_TRACKERS=$(hi_sel_file pm-tracker)
for HI_KIND in $(hi_selection_kinds); do
	: >"$(hi_sel_file "$HI_KIND")"
done

# hi_flag_value KIND -> the raw CSV the caller passed for one sub-selection kind.
# The ONE remaining per-kind arm in this file's flag layer, and an irreducible
# one: a new kind needs its own OPT_ variable and its own case arms in the
# argument parser above regardless, so this arm is where those meet the registry.
# Dies on an unknown kind rather than yielding an empty selection, which would
# read as "the caller selected nothing" — a false answer, not a lesser one.
hi_flag_value() {
	case $1 in
	technology) printf '%s' "$OPT_TECHNOLOGIES" ;;
	pm-tracker) printf '%s' "$OPT_PM_TRACKERS" ;;
	vcs) printf '%s' "$OPT_SD_VCS" ;;
	*) die "hi_flag_value: no flag variable for selection kind '$1'" ;;
	esac
}

# hi_validate_tokens FILE VALID_FILE WHAT -> die_usage on the first token in FILE
# that is not present in VALID_FILE, naming it. Never silently narrows a
# selection to the subset that happened to resolve.
hi_validate_tokens() {
	while IFS= read -r hivt_token; do
		[ -n "$hivt_token" ] || continue
		grep -qxF -- "$hivt_token" "$2" || die_usage "unknown $3: $hivt_token"
	done <"$1"
}

VALID_DOMAINS="$HUB_WORK/valid-domains.txt"
: >"$VALID_DOMAINS"
for HI_DOMAIN in $HUB_DOMAIN_KEYS; do
	if hub_domain_exists "$FRAMEWORK_ROOT" "$HI_DOMAIN"; then
		printf '%s\n' "$HI_DOMAIN" >>"$VALID_DOMAINS"
	fi
done
# hi_valid_file KIND -> the file of legal selection keys for one sub-selection
# kind. One per kind, filled from the group table's own selkey column.
hi_valid_file() {
	printf '%s/valid-%s.txt' "$HUB_WORK" "$1"
}
for HI_KIND in $(hi_selection_kinds); do
	hub_selection_keys "$HI_KIND" >"$(hi_valid_file "$HI_KIND")"
done

# hi_selection_rows SELKIND OUTFILE -> the checklist rows for one selectable
# kind: key, label, its hint, and whether it is currently diverged.
hi_selection_rows() {
	: >"$2"
	for hisr_group in $(hub_selectable_groups "$1"); do
		hisr_state=$(hub_group_state "$hisr_group")
		# A GROUP THAT IS ALREADY FULLY INSTALLED IS NOT OFFERED AT ALL — the
		# same rule hi_domain_pending applies at the domain level, applied here
		# at the technology/tracker level. A live test session found this screen
		# still listing React/Shell script/Tests developer as live, selectable
		# checkboxes annotated "already installed" once they genuinely were —
		# selecting them changed nothing. "Partial" (some of a group's units
		# diverged) stays offered, pre-marked [!], since there IS something left
		# to fix; only a group with nothing outstanding drops off the screen.
		[ "$hisr_state" != installed ] || continue
		hisr_key=$(hub_group_field "$hisr_group" 6)
		hisr_label=$(hub_group_field "$hisr_group" 2)
		hisr_note=""
		hisr_div=0
		case $1 in
		# The per-kind arms left on this screen: a tracker or VCS row carries a
		# "what it does" blurb. Both used to ALSO trim a suffix off the group
		# label, because the label carried one and each screen is already titled
		# "select tracker(s)"/"select VCS" — that trim is gone, not disabled: the
		# group label itself is bare now (see lib/hub-discovery.sh's own note on
		# why the default was inverted), so a row reads "GitHub" here with
		# nothing to strip, and the two screens that DO need the fuller form
		# compose it themselves through hub_group_label_in_context.
		pm-tracker) hisr_note=$(hub_pm_tracker_hint "$hisr_key") ;;
		vcs) hisr_note=$(hub_sd_vcs_hint "$hisr_key") ;;
		esac
		if [ "$hisr_state" = partial ]; then
			hisr_note="${hisr_note:+$hisr_note   }partially installed — choose to complete"
			hisr_div=1
		fi
		# Column order is key, label, diverged, ANNOTATION-LAST — the annotation
		# is the only column that can be empty, and it must be last (see
		# lib/hub-common.sh's "THE TAB TRAP").
		printf '%s\t%s\t%s\t%s\n' "$hisr_key" "$hisr_label" "$hisr_div" "$hisr_note" >>"$2"
	done
}

# hi_domain_pending DOMAIN -> exit 0 when DOMAIN has anything left to add or
# re-sync — its baseline, or (for a domain with a sub-selection kind) any of its
# own selectable groups — exit 1 when there is genuinely nothing left to do.
#
# A live test session found the onboarding checklist offering an already-fully-
# installed domain as a live checkbox, annotated "(already installed)" but still
# selectable — selecting it walked its sub-selection screens for no reason, since
# nothing there could change. "Install" should offer only what is actually
# installable: not-yet-installed domains, and partially-installed ones with a
# real gap or a diverged item to fix.
#
# Deliberately NOT keyed off hub_domain_state alone: that reports only the state of
# what the domain installs UNCONDITIONALLY (see its own header — that content goes in
# on first selection, so hub_domain_state says "installed" the moment even ONE of
# nine technologies is added). Checking the selectable groups too is what keeps
# Software Development in this list while 8 of 9 technologies remain available.
#
# THE UNCONDITIONAL CONTENT IS ASKED FOR, never constructed as `baseline:<domain>`:
# for a domain that has no baseline group that key names no row, hub_group_state
# answers `available` for a nonexistent group, and this function then reported
# "pending" forever — a fully-installed domain left standing as a live checkbox that
# changes nothing when selected, which is verbatim the bug the paragraph above says
# this function exists to prevent. hub_domain_content_groups answers for both shapes,
# and its `else` branch is exactly the "judge it by its own selectable groups" rule
# such a domain needs.
hi_domain_pending() {
	hidp_domain=$1
	for hidp_content in $(hub_domain_content_groups "$hidp_domain"); do
		[ "$(hub_group_state "$hidp_content")" = installed ] || return 0
	done
	# EVERY KIND THE DOMAIN HAS, not just its first: Software Development must
	# stay pending while EITHER its technology OR its VCS fan-out still has
	# something available, and a domain whose kind list is the single word
	# `none` (GTD) correctly finds nothing here and falls through to `return 1`.
	# ASSIGNED, never inlined — see hi_selection_kinds' own note on why a die
	# inside a for-list command substitution is swallowed under `set -e`.
	hidp_kinds=$(hub_domain_selection_kind "$hidp_domain")
	for hidp_kind in $hidp_kinds; do
		[ "$hidp_kind" != none ] || continue
		for hidp_group in $(hub_selectable_groups "$hidp_kind"); do
			[ "$(hub_group_state "$hidp_group")" = installed ] || return 0
		done
	done
	return 1
}

# hi_drop_unsatisfiable_domain DOMAIN WHAT SELFILE -> report that DOMAIN has no
# candidates of its sub-selection kind at all in this --source, and take it back
# out of the selection.
#
# Without this the screen is an INESCAPABLE LOOP: an empty checklist can only be
# confirmed empty, the empty-selection rule then re-prompts, and the same empty
# screen returns forever with no exit but ^C. `b` does not help either — it walks
# back to a domain list the user must re-confirm, straight into the same dead end.
# A domain whose entire sub-selection is missing is not installable, so saying so
# and dropping it is the only honest outcome.
#
# NEVER called when the row list is merely empty because every candidate is
# already installed (see hi_select_interactive's own genuinely-empty check
# right before this is reached) — that is a different, non-fatal condition:
# the domain likely still belongs in the selection for its BASELINE'S own sake
# (hi_domain_pending admits it for exactly that reason), and dropping it here
# would make a diverged baseline item unreachable through Install.
hi_drop_unsatisfiable_domain() {
	printf '\n%s No %s was found in %s, so %s cannot be installed — removing it from your selection.\n' \
		"$(hub_glyph_warn)" "$2" "$FRAMEWORK_ROOT" "$(hub_domain_label "$1")" >&3
	hub_remove_line "$SEL_DOMAINS" "$1"
	: >"$3"
}

# ---------------------------------------------------------------------------
# The interactive walk's STEP SEQUENCE, derived from the registry.
#
# A step is either the literal `domains` (the onboarding checklist, always first)
# or a KIND KEY, meaning "the sub-selection screen for that kind". Steps are KIND
# keys rather than DOMAIN keys precisely because a domain can now carry more than
# one kind (Software Development: `vcs` then `technology`) — keying by kind gives
# a multi-kind domain one step per kind for free from this same generic sequence
# machinery (hi_step_next/hi_step_prev below need no change at all), where keying
# by domain would have needed a second, nested sequence inside a single domain
# step. hub_selection_kind_domain is the reverse lookup a step uses to recover
# its own domain (for the screen title, the empty-selection message, and the
# unsatisfiable-source notice) — safe because a kind still maps to exactly ONE
# domain, only a domain can now map to more than one kind.
#
# The sequence is recomputed from SEL_DOMAINS whenever the domain selection
# changes, so it always holds exactly the screens this selection needs, in
# canonical domain order (and, within a domain, that domain's own kind order).
#
# This replaced a hardcoded domains -> technologies -> trackers machine whose every
# transition tested for the literal strings "software-development" and
# "project-management". That was the largest single item in a new domain's blast
# radius, and it was invisible: adding a domain with a sub-selection would have
# silently skipped its screen rather than failing.
# ---------------------------------------------------------------------------
HI_STEPS="$HUB_WORK/selection-steps.txt"

# hi_kind_required KIND -> exit 0 when at least one SELECTED domain needs a
# sub-selection of KIND. A reverse lookup (hub_selection_kind_domain) rather than
# a scan of every domain's own kind LIST: a kind still maps to exactly one
# domain, so asking "is THAT domain selected" is the whole question.
hi_kind_required() {
	hikr_domain=$(hub_selection_kind_domain "$1")
	grep -qxF -- "$hikr_domain" "$SEL_DOMAINS"
}

# hi_steps_build -> rewrite HI_STEPS: one line per KIND any SELECTED domain
# needs, in canonical domain order (and, within a domain, that domain's own kind
# order).
hi_steps_build() {
	: >"$HI_STEPS"
	for hisb_domain in $HUB_DOMAIN_KEYS; do
		grep -qxF -- "$hisb_domain" "$SEL_DOMAINS" || continue
		# ASSIGNED, never inlined — see hi_selection_kinds' own note.
		hisb_kinds=$(hub_domain_selection_kind "$hisb_domain")
		for hisb_kind in $hisb_kinds; do
			[ "$hisb_kind" != none ] || continue
			printf '%s\n' "$hisb_kind" >>"$HI_STEPS"
		done
	done
}

# hi_step_next STEP -> the step after STEP, or empty when STEP is the last one
# (the walk is complete).
hi_step_next() {
	if [ "$1" = domains ]; then
		head -n 1 "$HI_STEPS"
		return 0
	fi
	hisn_cur="$1" awk '$0 == ENVIRON["hisn_cur"] { found = 1; next } found { print; exit }' "$HI_STEPS"
}

# hi_step_prev STEP -> the step before STEP; `domains` when STEP is the first
# sub-selection screen, and empty for `domains` itself (nothing precedes it).
hi_step_prev() {
	[ "$1" != domains ] || return 0
	hisp_prev=$(hisp_cur="$1" awk '$0 == ENVIRON["hisp_cur"] { print prev; exit } { prev = $0 }' "$HI_STEPS")
	[ -n "$hisp_prev" ] || hisp_prev=domains
	printf '%s' "$hisp_prev"
}

# hi_last_selection_step -> the interactive step to re-enter when the user presses
# `b` on the CONFIRM screen: the last checklist that actually ran for this
# selection. Derived from the selection rather than remembered, so it stays right
# no matter which steps the walk skipped.
hi_last_selection_step() {
	hilss_last=$(tail -n 1 "$HI_STEPS")
	[ -n "$hilss_last" ] || hilss_last=domains
	printf '%s' "$hilss_last"
}

# hi_select_interactive -> walk the onboarding checklist and then each selected
# domain's own sub-selection screen, starting from whatever HI_STEP currently
# holds, leaving SEL_DOMAINS plus the per-kind selection files as the selection. A
# FUNCTION rather than inline code precisely so it can be RE-ENTERED: `b` on the
# confirm screen sets HI_STEP back to the relevant checklist and calls this again,
# and hub_checklist pre-seeds each screen from its own OUTFILE, so the user's
# earlier choices are still ticked.
#
# An explicit state machine rather than nested calls, so `b` genuinely goes back
# exactly one level from any screen and the user's earlier selections survive the
# trip.
hi_select_interactive() {
	while :; do
		# Every hub_checklist call is guarded with `|| HI_RC=$?`: it returns 1 for
		# "back" and 2 for "quit", and a bare non-zero function call would trip
		# set -e and kill the script instead of navigating.
		HI_RC=0
		if [ "$HI_STEP" = domains ]; then
			hub_checklist 'Welcome to the Crucible Management Hub' \
				'Which domain(s) do you want to install?' "$DOMAIN_ROWS" "$SEL_DOMAINS" || HI_RC=$?
			case $HI_RC in
			# `b` on the FIRST checklist has no earlier step to return to, so it
			# leaves the capability entirely — through hi_ok_exit, never a bare
			# `exit 0`. A machine caller reaching this on a TTY under
			# --format=env|json would otherwise see an empty stdout, which this
			# script's own contract (see hub_ok_exit) forbids: indistinguishable
			# from a crash before any output.
			1) hi_ok_exit false 'Nothing changed — went back without choosing a domain.' ;;
			2) exit 3 ;;
			esac
			if [ ! -s "$SEL_DOMAINS" ]; then
				printf '\n' >&3
				hi_ok_exit false 'Nothing selected — nothing to install. Choose at least one domain, or run "List" to see what is already there.'
			fi
			# A de-selected domain must not leave its earlier sub-selection in the
			# plan, so the file of any kind no longer required is cleared here. A
			# kind that IS still required keeps its file untouched, which is what
			# makes `b` back to this screen and forward again non-destructive:
			# hub_checklist pre-seeds each screen from its own selection file.
			for HI_KIND in $(hi_selection_kinds); do
				hi_kind_required "$HI_KIND" || : >"$(hi_sel_file "$HI_KIND")"
			done
			hi_steps_build
			HI_STEP=$(hi_step_next domains)
			[ -n "$HI_STEP" ] || return 0
			continue
		fi

		# A sub-selection step. Everything about it — the screen title, the
		# rows, the selection file, the empty-selection message, the noun in the
		# unsatisfiable-source message — comes from the registry. The STEP is a
		# KIND now (see this section's header above), so the domain is the
		# reverse lookup, not the other way around.
		HI_KIND=$HI_STEP
		HI_DOMAIN=$(hub_selection_kind_domain "$HI_KIND")
		HI_SEL=$(hi_sel_file "$HI_KIND")
		HI_ROWS=$(hi_rows_file "$HI_KIND")
		HI_NEXT=$(hi_step_next "$HI_STEP")
		HI_PREV=$(hi_step_prev "$HI_STEP")

		if [ ! -s "$HI_ROWS" ]; then
			# EMPTY has two different causes, and only one of them means the
			# domain is unsatisfiable. If this --source genuinely has no
			# candidate of this kind at all, hi_drop_unsatisfiable_domain's
			# message is correct and the domain has to come out — UNLESS this
			# kind is OPTIONAL (hub_selection_kind_optional), in which case
			# zero candidates is exactly as fine as zero chosen: nothing to
			# drop, nothing to block, just skip the step. If candidates DO
			# exist and are simply all already installed — reachable now that
			# hi_selection_rows excludes them entirely — the domain almost
			# certainly stayed in SEL_DOMAINS for its BASELINE'S own sake
			# (hi_domain_pending admitted it for exactly that reason);
			# dropping it here would make a diverged baseline item
			# unreachable through Install. Skip this step with an empty
			# sub-selection instead — there is nothing to pick, but that is
			# not the same as nothing to do.
			if [ -n "$(hub_selectable_groups "$HI_KIND")" ] || hub_selection_kind_optional "$HI_KIND"; then
				: >"$HI_SEL"
				# THE SKIPPED STEP COMES OUT OF THE SEQUENCE, and that is not
				# bookkeeping — it is what keeps `b` working. hi_last_selection_step
				# (the confirm screen's `b`) and hi_step_prev both read HI_STEPS, so a
				# step that rendered no checklist but stayed listed was a step `b`
				# could land on: re-entering it hit this same branch, advanced
				# straight back to the confirm screen, and `b` became a silent no-op
				# with the real checklist unreachable. Removed by LINE (against its
				# own KIND now, since steps are kind-keyed) rather than by
				# hi_steps_build (the sibling drop branch's mechanism just below):
				# that rebuild derives the sequence from SEL_DOMAINS, and this domain
				# deliberately STAYS selected for its baseline's own sake (or, for an
				# optional kind, simply stays selected), so a rebuild would put the
				# step straight back. Re-entering the domains checklist rebuilds it
				# anyway, and this branch removes it again — self-healing either way.
				hub_remove_line "$HI_STEPS" "$HI_KIND"
				[ -n "$HI_NEXT" ] || return 0
				HI_STEP=$HI_NEXT
				continue
			fi
			hi_drop_unsatisfiable_domain "$HI_DOMAIN" "$(hub_selection_kind_noun "$HI_KIND")" "$HI_SEL"
			# The domain just left the selection, so the sequence is rebuilt — but
			# HI_NEXT was captured BEFORE the rebuild, while this step was still in
			# the list, which is exactly why it is read first.
			hi_steps_build
			[ -n "$HI_NEXT" ] || return 0
			HI_STEP=$HI_NEXT
			continue
		fi

		hub_checklist "$(hub_domain_label "$HI_DOMAIN") — $(hub_selection_kind_prompt "$HI_KIND")" '' \
			"$HI_ROWS" "$HI_SEL" || HI_RC=$?
		case $HI_RC in
		1)
			HI_STEP=$HI_PREV
			continue
			;;
		2) exit 3 ;;
		esac
		if [ ! -s "$HI_SEL" ] && ! hub_selection_kind_optional "$HI_KIND"; then
			# ASSIGNED, never inlined as the printf argument.
			# hub_domain_empty_selection_message is a closed lookup that DIES for a
			# domain with no sub-selection, and a die inside a command substitution used
			# as an ARGUMENT is swallowed — the substitution yields empty, printf still
			# succeeds, and the user is re-prompted by an empty-selection rule that
			# printed nothing to explain itself, forever, with no way out but ^C. The
			# `!= none` guard on HI_KIND above happens to make the die unreachable
			# today, but that guard is in another branch of another function and nothing
			# structurally ties the two together. The same hoisting lib/hub-state.sh's
			# hub_rows_build states and hi_shared_heading applies.
			#
			# THE OPTIONAL-KIND EXEMPTION is new: an empty `vcs` selection is a
			# genuinely valid answer ("no PR/MR automation"), not an empty domain,
			# so it never reaches this block at all — it falls straight through to
			# advancing the step, exactly like a satisfied selection does.
			HI_EMPTY_MSG=$(hub_domain_empty_selection_message "$HI_DOMAIN")
			printf '\n%s %s\n' "$(hub_glyph_warn)" "$HI_EMPTY_MSG" >&3
			continue
		fi

		[ -n "$HI_NEXT" ] || return 0
		HI_STEP=$HI_NEXT
	done
}

# INTERACTIVE_SELECTION — whether the selection came from the checklists rather
# than from flags. It decides two things later: whether `b` on the confirm screen
# has a checklist to return to, and whether --apply is required to reach the
# confirm screen at all.
INTERACTIVE_SELECTION=0

if [ "$OPT_ALL" -eq 1 ]; then
	# Every kind the registry knows about, not the two that happened to exist when
	# this was written: a third domain reusing `technology` or `pm-tracker` was
	# silently unselectable via --all while the interactive walk offered it.
	cat "$VALID_DOMAINS" >"$SEL_DOMAINS"
	for HI_KIND in $(hi_selection_kinds); do
		cat "$(hi_valid_file "$HI_KIND")" >"$(hi_sel_file "$HI_KIND")"
	done
elif [ "$FLAG_DRIVEN" -eq 1 ]; then
	# hub_dedup_first_field after EVERY split: hub_split_csv trims and drops empty
	# tokens but does not deduplicate, and the duplicates survive all the way onto
	# the CONSENT SURFACE — `--domains=gtd,gtd` announced "Install 2 domains",
	# rendered the GTD baseline block twice and doubled the discard guard's pending
	# count. The apply itself was always correct (hub_units_of_groups dedups by
	# unit name), so this is an accuracy fix for what the user is asked to approve,
	# which is reason enough on its own.
	hub_split_csv "$OPT_DOMAINS" "$SEL_DOMAINS"
	hub_dedup_first_field "$SEL_DOMAINS"
	hi_validate_tokens "$SEL_DOMAINS" "$VALID_DOMAINS" domain
	for HI_KIND in $(hi_selection_kinds); do
		HI_SEL=$(hi_sel_file "$HI_KIND")
		hub_split_csv "$(hi_flag_value "$HI_KIND")" "$HI_SEL"
		hub_dedup_first_field "$HI_SEL"
		# The "unknown X" noun is the registry's own, plus the flag it came from:
		# the hand-written literals this replaced named the DOMAIN ("unknown
		# project-management tracker"), and the flag is the more actionable half —
		# it is the thing the caller actually typed.
		hi_validate_tokens "$HI_SEL" "$(hi_valid_file "$HI_KIND")" \
			"$(hub_selection_kind_noun "$HI_KIND") ($(hub_selection_kind_flag "$HI_KIND"))"
	done

	# A sub-selection flag for a domain that was not selected is a usage error,
	# not a silent no-op: the caller clearly meant something the command cannot
	# do, and quietly ignoring half the request is how an agent ends up believing
	# it installed Python when it did not. Both this check and the mandatory-
	# sub-selection check below iterate the registry, so neither names a domain.
	for HI_DOMAIN in $HUB_DOMAIN_KEYS; do
		# ASSIGNED, never inlined — see hi_selection_kinds' own note.
		HI_KINDS=$(hub_domain_selection_kind "$HI_DOMAIN")
		for HI_KIND in $HI_KINDS; do
			[ "$HI_KIND" != none ] || continue
			[ -s "$(hi_sel_file "$HI_KIND")" ] || continue
			grep -qxF -- "$HI_DOMAIN" "$SEL_DOMAINS" ||
				die_usage "$(hub_selection_kind_flag "$HI_KIND") requires $HI_DOMAIN in --domains"
		done
	done
else
	if ! hub_interactive; then
		die_usage "no TTY and no --domains/--all given"
	fi
	INTERACTIVE_SELECTION=1

	# Only a domain with something PENDING (see hi_domain_pending's own header)
	# is offered at all — a domain that is fully installed and fully in sync has
	# nothing this screen could do for it.
	DOMAIN_ROWS="$HUB_WORK/domain-rows.tsv"
	: >"$DOMAIN_ROWS"
	while IFS= read -r HI_DOMAIN; do
		[ -n "$HI_DOMAIN" ] || continue
		hi_domain_pending "$HI_DOMAIN" || continue
		HI_NOTE=$(hub_domain_blurb "$HI_DOMAIN")
		# The ratio/tracker detail (hub_domain_detail, e.g. "(2/9 technologies)")
		# is the accurate way to say "here's what's already there" for a
		# partially-selected domain — unlike the binary installed/partial tag
		# this replaced, it cannot claim a domain with 8 of 9 technologies still
		# available is simply "already installed".
		HI_DETAIL=$(hub_domain_detail "$HI_DOMAIN")
		[ -z "$HI_DETAIL" ] || HI_NOTE="$HI_NOTE   $HI_DETAIL installed"
		printf '%s\t%s\t0\t%s\n' "$HI_DOMAIN" "$(hub_domain_label "$HI_DOMAIN")" "$HI_NOTE" >>"$DOMAIN_ROWS"
	done <"$VALID_DOMAINS"

	# One rows file per sub-selection kind, built for every kind this source
	# offers — not two hand-named files for two hand-named domains.
	for HI_KIND in $(hi_selection_kinds); do
		hi_selection_rows "$HI_KIND" "$(hi_rows_file "$HI_KIND")"
	done

	# Every domain can be fully installed and fully in sync at once — nothing
	# left for "Install" to do at all. Say so cleanly rather than opening an
	# empty checklist (hub_checklist has no "there is nothing to select, period"
	# message of its own; its empty-view line is written for an active filter
	# matching nothing, which would misdescribe this case).
	if [ ! -s "$DOMAIN_ROWS" ]; then
		hi_ok_exit false 'Everything is already installed and up to date. Nothing to do.'
	fi

	HI_STEP=domains
fi

# THE MANDATORY SUB-SELECTION CHECK, for BOTH non-interactive entry points — it
# used to live inside the --domains branch only, so the three entry points
# disagreed about the same situation: the flag-driven path blocked, the
# interactive path dropped the domain (hi_drop_unsatisfiable_domain), and --all
# silently installed the domain's baseline with an empty, never-validated
# sub-selection. On a --source where a domain's selection kind has no candidates
# at all, --all now blocks with the same reason and the same message the flag path
# gives. The interactive path keeps its own, gentler handling: it has a screen to
# say it on and a user to say it to, which a blocked machine caller does not.
#
# Iterates SEL_DOMAINS and asks the registry, so it names no domain.
if [ "$INTERACTIVE_SELECTION" -eq 0 ]; then
	while IFS= read -r HI_DOMAIN; do
		[ -n "$HI_DOMAIN" ] || continue
		# ASSIGNED, never inlined — see hi_selection_kinds' own note.
		HI_KINDS=$(hub_domain_selection_kind "$HI_DOMAIN")
		for HI_KIND in $HI_KINDS; do
			[ "$HI_KIND" != none ] || continue
			# An OPTIONAL kind (vcs) is never mandatory here either — an empty
			# selection of it is a valid answer on every entry point, not just
			# the interactive one.
			if hub_selection_kind_optional "$HI_KIND"; then
				continue
			fi
			if [ ! -s "$(hi_sel_file "$HI_KIND")" ]; then
				# ASSIGNED, never inlined as hi_blocked's argument — same hazard as the
				# interactive path's own copy of this message above, with a worse outcome
				# here: a swallowed die would hand a MACHINE caller
				# `HUB_BLOCKED_REASON=selection_required` with an empty HUB_MESSAGE, i.e. a
				# refusal it cannot act on or report.
				HI_EMPTY_MSG=$(hub_domain_empty_selection_message "$HI_DOMAIN")
				hi_blocked selection_required "$HI_EMPTY_MSG"
			fi
		done
	done <"$SEL_DOMAINS"
fi

# ===========================================================================
# THE PLAN STAGE'S HELPERS — defined ONCE, here, above the loop that uses them.
#
# They used to be defined INSIDE the plan loop, so every `b` round trip
# re-created four identical functions for no reason, and a reader following the
# loop's flow met three function definitions before reaching the code that
# produced the screen.
# ===========================================================================

# hi_reqby_file GROUP -> the per-group scratch file holding that shared group's
# "required by:" annotations. Per-group rather than one shared file: only one
# cross-domain group exists today, but a single accumulating file would silently
# attribute the first group's consumers to the second the day a second appears.
#
# `sed 's|[:/]|_|g'`, not `tr ':/' '__'`: tr's second operand is a SET mapped
# positionally onto the first, so a duplicated replacement character is exactly
# the shape SC2020 flags (it happens to produce the intended result here only
# because both replacements are the same character). lib/hub-checklist.sh's own
# token split already avoids this shape for the same reason and says so; a sed
# character class states "replace either of these with _" unambiguously.
hi_reqby_file() {
	printf '%s/reqby-%s.txt' "$HUB_WORK" "$(printf '%s' "$1" | sed 's|[:/]|_|g')"
}

# hi_unit_glyph STATE -> the preview glyph: + will be added, ! diverged (will
# re-sync — the SAME glyph List/Doctor/Status use for divergence; a live test
# session pointed out this file used to invent its own second symbol, `~`, for
# the identical condition), = already identical.
hi_unit_glyph() {
	case $1 in
	available) hub_glyph_new ;;
	DIVERGED) hub_glyph_warn ;;
	*) printf '=' ;;
	esac
}

# hi_print_units GROUP KIND_FILTER -> one glyph-prefixed display-name line per
# unit of GROUP whose kind matches KIND_FILTER ("agent", "skill" or "any").
# Used only by hi_preview_shared below: the cross-domain block is always small
# (today, exactly one shared unit) and its own "required by" framing already
# earns full itemization regardless of state — the "collapse what isn't
# changing" rule that governs a DOMAIN's own preview block does not apply here.
hi_print_units() {
	hipu_group=$1
	hipu_kind=$2
	hipu_group="$hipu_group" hipu_kind="$hipu_kind" awk -F '\t' -v OFS='\t' '
		$1 == ENVIRON["hipu_group"] &&
		(ENVIRON["hipu_kind"] == "any" || $3 == ENVIRON["hipu_kind"]) { print $2, $3, $4, $5 }
	' "$PLAN_UNITS" >"$HUB_WORK/print-units.tsv"
	while IFS="$HUB_TAB" read -r hipu_name hipu_k hipu_src hipu_display; do
		[ -n "$hipu_name" ] || continue
		hub_state_set "$hipu_k" "$hipu_name" "$hipu_src" "$TARGET_DIR"
		printf '    %s %s\n' "$(hi_unit_glyph "$HUB_STATE")" "$hipu_display"
	done <"$HUB_WORK/print-units.tsv"
}

# hi_selectable_group KIND SELKEY -> the group key one selection key names, built
# through the grammar's own constructor rather than by pasting a prefix onto it.
hi_selectable_group() {
	hub_group_key "$(hub_selection_kind_prefix "$1")" "$2"
}

# ---------------------------------------------------------------------------
# Selection -> groups. The cross-domain group joins the plan when ANY of its
# consumers does, and is deduplicated by construction: it is one group, added at
# most once, so its unit is installed once no matter how many consumers pulled
# it in.
# ---------------------------------------------------------------------------

# hi_plan_groups_build -> rewrite PLAN_GROUPS from the current selection: every
# selected domain's own unconditional content, every selected sub-selection key's own
# group, and any shared group at least one of those pulled in.
#
# RULE ONE IS hub_domain_content_groups, ONE RULE RATHER THAN TWO. It used to append
# a constructed `baseline:<domain>` per selected domain, which is the right answer for
# a domain that HAS a baseline group and names nothing at all for a domain whose
# selectable content is its whole footprint — picking such a domain then resolved to
# an empty plan and installed nothing, silently. Asking the accessor covers both
# shapes with one line, and it is the same accessor lib/hub-state.sh's feature
# projection asks, so "what does picking this domain bring in" has one answer.
#
# The accessor writes to stdout and is APPENDED here, never read back through a
# nested `while read` on SEL_DOMAINS: this loop holds an open descriptor on that file,
# and a nested reader of it would consume the outer loop's own stream.
hi_plan_groups_build() {
	: >"$PLAN_GROUPS"
	while IFS= read -r hipgb_domain; do
		[ -n "$hipgb_domain" ] || continue
		hub_domain_content_groups "$hipgb_domain" >>"$PLAN_GROUPS"
	done <"$SEL_DOMAINS"

	for hipgb_kind in $(hi_selection_kinds); do
		while IFS= read -r hipgb_key; do
			[ -n "$hipgb_key" ] || continue
			printf '%s\n' "$(hi_selectable_group "$hipgb_kind" "$hipgb_key")" >>"$PLAN_GROUPS"
		done <"$(hi_sel_file "$hipgb_kind")"
	done

	for hipgb_shared in $(hub_groups_of_role shared); do
		hipgb_reqby=$(hi_reqby_file "$hipgb_shared")
		: >"$hipgb_reqby"
		# The consumer list is materialized to a file first, then read with a
		# redirect. A `while read ... <<EOF $(cmd) EOF` heredoc-wrapped command
		# substitution parses, but it is the construction hub-uninstall.sh's own
		# comment calls out as the kind that silently misbehaves the next time
		# anyone edits it — so all three sites that consume hub_shared_consumers now
		# do it the same, plainer way.
		hub_shared_consumers "$hipgb_shared" >"$HUB_WORK/shared-consumers.tsv"
		while IFS="$HUB_TAB" read -r hipgb_consumer hipgb_note; do
			[ -n "$hipgb_consumer" ] || continue
			grep -qxF -- "$hipgb_consumer" "$PLAN_GROUPS" || continue
			printf '%s\n' "$hipgb_note" >>"$hipgb_reqby"
		done <"$HUB_WORK/shared-consumers.tsv"
		if [ -s "$hipgb_reqby" ]; then
			printf '%s\n' "$hipgb_shared" >>"$PLAN_GROUPS"
		fi
	done
}

# ---------------------------------------------------------------------------
# Preview blocks. Each is ONE named job, called in sequence by hi_preview below,
# because the whole preview used to be a single 128-line brace group doing six
# unrelated rendering jobs with no named boundaries between them.
#
# Every block writes to stdout and is called from inside hi_preview's
# `{ ... } >&3` group, so none of them names the human channel itself.
#
# THE CORE RULE BEHIND EVERY hi_preview_domain* FUNCTION BELOW: itemize by name
# ONLY what will actually change (new or diverged); fold everything that will
# NOT change into a count. A live test session found the previous shape —
# itemizing every SELECTED item unconditionally, with a hardcoded "+" regardless
# of its real state — actively lied on an already-fully-installed target: every
# technology showed "+" ("will be added") next to a standards/baseline block
# correctly showing "=" ("already installed") for the very same technologies,
# and running "Install all" a second time dumped 80 lines to say, in the end,
# nothing was going to happen. The dry run's job is to say what is ABOUT TO
# HAPPEN, not to enumerate the entire universe of files that happen to already
# be there unchanged.
# ---------------------------------------------------------------------------

# hi_selection_kind_noun_plural KIND -> the irregular plural for a selection
# kind whose plural genuinely is irregular, with a regular "+s" fallback for
# one that is not. A local, tiny mapping rather than a new entry in
# hub-domains.sh's own KIND registry (hub_selection_kind_noun and its
# siblings): this is the ONE place in the hub that needs a plural form of the
# noun, so growing the shared registry for it is not yet earned. `vcs` is an
# arm here for the same reason `technology`/`pm-tracker` are: the "+s"
# fallback on an acronym like "VCS" produces "VCSs", exactly the irregular
# case this function exists to override.
hi_selection_kind_noun_plural() {
	case $1 in
	technology) printf 'technologies' ;;
	pm-tracker) printf 'trackers' ;;
	vcs) printf 'VCS hosts' ;;
	*)
		# Assigned, not inlined as the printf argument: hub_selection_kind_noun is a
		# closed lookup that DIES on an unknown kind, and a die inside a command
		# substitution used as an ARGUMENT is swallowed — the substitution yields
		# empty, printf still succeeds, and this returns a bare "s" that a caller then
		# renders as "3 s already installed". The same hoisting convention
		# lib/hub-state.sh's hub_rows_build states; this arm exists precisely for an
		# unregistered future kind, which is exactly when the die matters.
		hisknp_noun=$(hub_selection_kind_noun "$1")
		printf '%ss' "$hisknp_noun"
		;;
	esac
}

# hi_bucket_reset -> zero the accumulators one hi_preview_domain call fills.
# HI_NEW_ITEMS / HI_DIVERGED_ITEMS collect display names, one per line, in the
# order they are added (selectable, then lenses — whatever order hi_preview_domain
# feeds the bucket rows in); the display name itself says what kind of thing it is,
# so the itemized list never needs to.
#
# HI_NEW_UNITS / HI_DIVERGED_UNITS are those same two files' UNIT WEIGHT — see
# hi_bucket_add_row, and the "LINES ARE NOT UNITS" note below.
#
# WHAT IS INDIVIDUALLY NAMEABLE ON THIS HUB'S SCREENS: a technology, a tracker, a
# lens reviewer. Nothing else — not a baseline unit, and not a standard of either
# kind. hub-list.sh's hl_lens_rows_build owns the authoritative statement of that
# rule and the two different mechanisms that produce it; this comment deliberately
# does not restate them, because it previously CONTRADICTED them (it named
# "technologies/trackers/standards/lenses" as the nameable set, while List has never
# given a standard a row of its own in any state).
#
# So neither a baseline unit nor a standard ever lands in those two files:
#   * BASELINE units are plain counts (HI_BASE_NEW / HI_BASE_DIVERGED /
#     HI_BASE_UNCHANGED), rendered as the one "new baseline (N items)" line List
#     renders as "Framework baseline (N items)".
#   * a STANDARD folds into its owning technology's own line, which is where its
#     units already count (see hi_bucket_add_row's `standard` arm). This screen used
#     to print it as a second, separately-named line — "+ Python" immediately
#     followed by "+ Python standard" — which named the one thing three other
#     surfaces in this hub agree is not nameable: List collapses it into the
#     technology row, hub-doctor.sh's rule 2 folds it into the technology it belongs
#     to, and this file's OWN Result screen folds it into the group label
#     (hi_result_domain_block's `selectable` arm). The preview was the only
#     disagreement, and it was disagreeing with the receipt the same run prints.
#
# The four UNCHANGED counters stay separate BY KIND, and that is NOT in tension with
# the rule above: the trailing "already installed" note counts kinds rather than
# naming instances ("7 other technologies, 8 standards, ..."), and a count is
# precisely what a non-nameable thing gets.
#
# HI_SEL_UNCHANGED is the one of the four that hi_bucket_add_row never fills from
# a SELECTED key: an already-installed technology/tracker is counted by
# hi_preview_domain's own selection-independent pass over every selectable row of
# the domain, because the checklist no longer offers an already-installed group
# at all (hi_selection_rows excludes it) and a selection therefore cannot name
# one. The other three are per-row and are filled as the rows are classified.
#
# HI_FEATURE_UNCHANGED_ITEMS is the one unchanged accumulator that collects NAMES
# rather than a count, and that is not in tension with the rule above: a FEATURE
# is individually nameable (that is the whole reason it has a line of its own —
# see lib/hub-domains.sh §4b), so its unchanged remainder is named too. Every
# other unchanged remainder is a count because the things it counts are not
# nameable. A domain has either features or a selection kind, never both, so the
# note never mixes a name with a count in one parenthetical.
hi_bucket_reset() {
	HI_NEW_ITEMS="$HUB_WORK/bucket-new.txt"
	HI_DIVERGED_ITEMS="$HUB_WORK/bucket-diverged.txt"
	HI_FEATURE_UNCHANGED_ITEMS="$HUB_WORK/bucket-feature-unchanged.txt"
	: >"$HI_NEW_ITEMS"
	: >"$HI_DIVERGED_ITEMS"
	: >"$HI_FEATURE_UNCHANGED_ITEMS"
	HI_NEW_UNITS=0
	HI_DIVERGED_UNITS=0
	HI_SEL_UNCHANGED=0
	HI_STD_UNCHANGED=0
	HI_LENS_UNCHANGED=0
	HI_BASE_UNCHANGED=0
	HI_BASE_NEW=0
	HI_BASE_DIVERGED=0
	HI_FEATURE_ITEMIZED=0
}

# ---------------------------------------------------------------------------
# THE CLASSIFICATION SOURCE. Everything hi_preview_domain reports about a domain
# comes from ONE call to lib/hub-state.sh's hub_domain_buckets — the shared
# per-domain projection — and nothing below re-derives any part of it.
#
# WHAT THAT REPLACED: this file used to hand-roll the two classifications that
# table already owns. It mapped a selectable group's `partial` to DIVERGED itself
# (the third hand-written copy of the mapping hub_group_display_state exists to
# hold), and it split Software Development's baseline into lens reviewers and
# everything else with its own src-path test behind a
# `[ "$domain" = software-development ]` literal. Both are now columns.
#
# THE SCOPE QUESTION THIS SETTLES, because it is the one thing that made a second
# derivation look necessary: the bucket table is DISCOVERY-scoped (every unit the
# domain has, at its current live state), while the preview needs two scopes at
# once — what the SELECTION named, itemized by name, and every selectable group
# of the domain REGARDLESS of selection, counted into the "already installed,
# unchanged" note. One table serves both, because scope is not part of the
# classification: the table answers "what state is this unit/group in" for every
# unit that exists, and the SELECTION is applied by the caller as a filter on the
# groupkey column (see hi_preview_domain's own loop). Discovery scope is in fact
# what the second half REQUIRES — it is exactly why the plan-scoped walk this
# replaced (over PLAN_UNITS, which holds only the groups THIS install's plan
# pulled in) needed a second, discovery-scoped walker beside it to count the
# groups the selection never named.
#
# The one thing the table cannot collapse further is also the one thing wanted:
# a technology is ONE `selectable` row at its group's aggregate state, never its
# two agents individually — the exact collapse the selectable line has always
# reported, and the reason Doctor deliberately stays off this projection (see
# lib/hub-state.sh's bucket header).
#
# The per-domain table and the two scratch files its readers hand to `read` are
# FIXED paths under HUB_WORK, rewritten in place per domain and per lookup: the
# preview walks one domain fully before starting the next and never re-enters
# itself, and a fresh hub_mktemp_dir per domain would leave one directory per
# domain behind for the lifetime of the workspace — the reason hub_domain_buckets
# gives for its own single HUB_BUCKETS_DIR.
# ---------------------------------------------------------------------------
HI_BUCKETS="$HUB_WORK/preview-buckets.tsv"
HI_BUCKET_ROW="$HUB_WORK/preview-bucket-row.tsv"
HI_BUCKET_ROWS="$HUB_WORK/preview-bucket-rows.tsv"

# hi_bucket_add_row BUCKET STATE DISPLAY [UNITS] -> classify ONE hub_domain_buckets
# row into the accumulators. UNITS is how many TARGET UNITS the row stands for and
# defaults to 1; only a `selectable` row is ever worth more than one, and only its
# caller knows the figure (see "LINES ARE NOT UNITS" below).
#
#   baseline    every outcome is a plain count
#               (HI_BASE_NEW/HI_BASE_DIVERGED/HI_BASE_UNCHANGED).
#   standard    NEVER itemized and never counted as changing — it folds into its
#               owning technology's own line and unit weight. An already-installed
#               one still increments HI_STD_UNCHANGED, which is a per-kind count
#               rather than a name (see hi_bucket_reset).
#   otherwise   DISPLAY is appended to HI_NEW_ITEMS/HI_DIVERGED_ITEMS and UNITS is
#               added to HI_NEW_UNITS/HI_DIVERGED_UNITS when the row is changing;
#               otherwise its own unchanged counter is incremented.
#
# ===========================================================================
# LINES ARE NOT UNITS — the arithmetic bug the UNITS parameter exists to fix.
# ===========================================================================
# The per-domain block header used to be `lines(HI_NEW_ITEMS) + HI_BASE_NEW` and
# call the result "N new items". Those two addends counted DIFFERENT THINGS:
# HI_BASE_NEW is a UNIT count (hub_domain_buckets emits one baseline row per unit),
# while a `selectable` line is a whole COLLAPSED TECHNOLOGY — one line standing for
# a developer agent, a reviewer agent and a standard skill. Adding them produced a
# number that was neither, and it could not be reconciled with hi_preview_totals'
# own "N items total" a few lines further down the SAME consent screen, which counts
# real units off PLAN_UNITS. Two different totals for one install, both on the
# screen the user is being asked to approve.
#
# A `selectable` row is therefore weighted by its GROUP's own unit count — the group
# table's column 8, the same column lib/hub-discovery.sh fills from the same
# discovery pass PLAN_UNITS is resolved from — so the block header and the totals
# line count the same things. Folding the `standard` bucket (above) is what keeps
# that exact rather than double-counting: a technology's standard is one of the units
# already inside its group's count, so itemizing it separately AND weighting the
# group would count it twice.
#
# THE ONE REMAINING APPROXIMATION, disclosed rather than hidden: a PARTLY-present
# group arrives as a single row at its aggregate DIVERGED state, so all of its units
# are attributed to "diverged" even when some of them are actually available or
# already installed. That is inherent to a collapsed row — the row deliberately
# cannot say more than "this technology needs re-selecting" — and the totals line
# right below it remains the exact per-unit split. It is a strictly smaller error
# than the line/unit mixture it replaces, which was wrong for EVERY multi-unit group
# rather than only for partly-present ones.
#
# BUCKET IS A CLOSED SET — hub_domain_buckets' own, not a second vocabulary this
# file translates into — and an unrecognized one DIES rather than quietly dropping
# the row from every counter it should have landed in. That is this codebase's
# convention for a closed lookup (hub_domain_label, hub_tool_reason,
# hub_glyph_for_state, hub_confirm_prompt all do the same), and it earned its
# place here: the tag vocabulary this replaced let a typo fall through every arm
# silently, so the row was neither itemized nor counted and the preview's own
# arithmetic lost an item with no trace anywhere.
#
# THE VALIDATION RUNS FIRST, BEFORE ANY BRANCH ON STATE, because the bucket's
# validity does not depend on the row's state: guarding it inside the unchanged
# arm only meant a typo was accepted in silence whenever the row happened to be
# available or DIVERGED, so the fail-loud guarantee fired on the state of the tree
# rather than on the bug.
hi_bucket_add_row() {
	hibar_bucket=$1
	hibar_state=$2
	hibar_display=$3
	hibar_units=${4:-1}
	# `feature` is NOT one of hub_domain_buckets' four buckets, and is the one
	# member of this closed set that does not come from that table: a feature is a
	# SUBSET of one group's units, which the bucket table structurally cannot
	# express, so it arrives from lib/hub-state.sh's hub_domain_feature_rows
	# instead (see hi_preview_domain's own baseline block). It is validated here
	# alongside the four for the same fail-loud reason.
	case $hibar_bucket in
	selectable | standard | lens | baseline | feature) : ;;
	*) die "hi_bucket_add_row: unknown BUCKET '$hibar_bucket'" ;;
	esac
	# EVERY ARM HONORS THE WEIGHT, these two included. They used to increment by a
	# literal 1 and silently DROP the 4th argument, which made the parameter a
	# trap: a caller that weighted a baseline row got a count of 1 back with no
	# error anywhere, and hi_preview_domain_baseline compensated by unrolling a
	# collapsed count into N single calls through two `while` loops — 12 lines
	# working around a dropped argument. HI_BASE_* and HI_STD_UNCHANGED are unit
	# counts either way (a weight of 1 per call is exactly what the per-unit
	# `baseline`/`standard` bucket rows still pass), so nothing about their meaning
	# changes; what changes is that the weight now means the same thing in all five
	# arms of one function.
	if [ "$hibar_bucket" = baseline ]; then
		case $hibar_state in
		available) HI_BASE_NEW=$((HI_BASE_NEW + hibar_units)) ;;
		DIVERGED) HI_BASE_DIVERGED=$((HI_BASE_DIVERGED + hibar_units)) ;;
		*) HI_BASE_UNCHANGED=$((HI_BASE_UNCHANGED + hibar_units)) ;;
		esac
		return 0
	fi
	if [ "$hibar_bucket" = standard ]; then
		# A CHANGING standard produces no line and no count at all: its units are
		# already inside its technology's group weight, so the technology's own line
		# reports it. Only the unchanged case has anything left to say, and it says it
		# as a count.
		case $hibar_state in
		available | DIVERGED) : ;;
		*) HI_STD_UNCHANGED=$((HI_STD_UNCHANGED + hibar_units)) ;;
		esac
		return 0
	fi
	# WHETHER A FEATURE LINE WAS ACTUALLY ITEMIZED, which is what the atomicity hint
	# is guarded on (hi_print_feature_hint): a hint saying "these install together"
	# under a block whose only changing line is an anonymous baseline count names
	# nothing it could be about. Set before the state branch below rather than
	# inside it, because both changing states qualify and neither knows the bucket.
	if [ "$hibar_bucket" = feature ]; then
		case $hibar_state in
		available | DIVERGED) HI_FEATURE_ITEMIZED=1 ;;
		esac
	fi
	case $hibar_state in
	available)
		printf '%s\n' "$hibar_display" >>"$HI_NEW_ITEMS"
		HI_NEW_UNITS=$((HI_NEW_UNITS + hibar_units))
		;;
	DIVERGED)
		printf '%s\n' "$hibar_display" >>"$HI_DIVERGED_ITEMS"
		HI_DIVERGED_UNITS=$((HI_DIVERGED_UNITS + hibar_units))
		;;
	*)
		case $hibar_bucket in
		lens) HI_LENS_UNCHANGED=$((HI_LENS_UNCHANGED + 1)) ;;
		# NAMED, not counted — see hi_bucket_reset on why a feature is the one
		# unchanged remainder that is nameable.
		feature) printf '%s\n' "$hibar_display" >>"$HI_FEATURE_UNCHANGED_ITEMS" ;;
		# An already-installed SELECTABLE is deliberately counted nowhere here:
		# this arm is reached only for a key the caller actually SELECTED, and
		# HI_SEL_UNCHANGED has to come from a selection-independent pass instead —
		# see hi_preview_domain, right after its selection loop — so that it works
		# the same whether the selection came from the checklist (which never
		# offers an already-installed group) or from a --technologies /
		# --pm-trackers flag (which can name one).
		selectable) : ;;
		esac
		;;
	esac
}

# hi_bucket_lookup BUCKET GROUP -> sets HI_BK_STATE / HI_BK_DISPLAY from GROUP's
# single BUCKET row in HI_BUCKETS. Returns 1 when this domain's table has no such
# row, which is a legitimate answer rather than an error: a sub-selection file is
# named after its KIND, not after a domain, so a source where two domains share
# one selection kind (a state lib/hub-domains.sh's blast-radius note explicitly
# permits) hands this domain's block a key belonging to the other domain's
# groups. Skipping it is what keeps each domain's block to its own items.
hi_bucket_lookup() {
	hibl_bucket="$1" hibl_group="$2" awk -F '\t' -v OFS='\t' '
		$1 == ENVIRON["hibl_bucket"] && $2 == ENVIRON["hibl_group"] { print $3, $4; exit }
	' "$HI_BUCKETS" >"$HI_BUCKET_ROW"
	[ -s "$HI_BUCKET_ROW" ] || return 1
	IFS="$HUB_TAB" read -r HI_BK_STATE HI_BK_DISPLAY <"$HI_BUCKET_ROW"
}

# hi_bucket_add_rows BUCKET GROUP -> hi_bucket_add_row for every BUCKET row of
# GROUP, in the table's own order.
#
# Materialized to a file and read with a redirect, never `awk … | while read`:
# POSIX sh has no `lastpipe`, so the loop body would run in a subshell and every
# accumulator it incremented would be lost the moment the pipeline ended.
hi_bucket_add_rows() {
	hibars_bucket=$1
	hibars_bucket="$hibars_bucket" hibars_group="$2" awk -F '\t' -v OFS='\t' '
		$1 == ENVIRON["hibars_bucket"] && $2 == ENVIRON["hibars_group"] { print $3, $4 }
	' "$HI_BUCKETS" >"$HI_BUCKET_ROWS"
	while IFS="$HUB_TAB" read -r hibars_state hibars_display; do
		[ -n "$hibars_state" ] || continue
		hi_bucket_add_row "$hibars_bucket" "$hibars_state" "$hibars_display"
	done <"$HI_BUCKET_ROWS"
}

# hi_preview_domain_unchanged_note DOMAIN INSTALLED_GROUPS_FILE -> "(N other
# <selectable-noun>, M standards, K review lenses, the L-item baseline already
# installed, unchanged)" — naming only the kinds that actually have an
# unchanged remainder, so a domain with everything itemized above prints no
# note at all.
#
# LOOPS OVER EVERY KIND THE DOMAIN HAS, one fragment per kind with a non-zero
# count, rather than reading a single scalar kind — Software Development now
# carries two (vcs, technology), and reading whichever one a caller's own loop
# happened to iterate last (this function's previous shape) named the wrong
# noun and, worse, is not even a stable answer: it depends on the registry's
# own kind ORDER, which is documented as screen-walk order, not a contract.
# INSTALLED_GROUPS_FILE is the domain-wide "selectable rows already installed"
# list hi_preview_domain built once (HI_SEL_UNCHANGED's own source) — read
# here, never rebuilt, so the count named in the note and the count folded
# into HI_SEL_UNCHANGED can never disagree.
hi_preview_domain_unchanged_note() {
	hipdun_domain=$1
	hipdun_installed=$2
	hipdun_note=""
	# ASSIGNED, never inlined — see hi_selection_kinds' own note.
	hipdun_kinds=$(hub_domain_selection_kind "$hipdun_domain")
	for hipdun_kind in $hipdun_kinds; do
		[ "$hipdun_kind" != none ] || continue
		# INTERSECTED against hub_selectable_groups' own DISCOVERED set for
		# this kind, rather than re-deriving "which kind does this group
		# belong to" from the group key's own prefix a second time: the
		# registry already answers that question, through the one function
		# every other per-kind walk in this file already calls.
		hipdun_kind_n=0
		for hipdun_kind_group in $(hub_selectable_groups "$hipdun_kind"); do
			grep -qxF -- "$hipdun_kind_group" "$hipdun_installed" || continue
			hipdun_kind_n=$((hipdun_kind_n + 1))
		done
		[ "$hipdun_kind_n" -gt 0 ] || continue
		hipdun_noun=$(hub_plural "$hipdun_kind_n" "$(hub_selection_kind_noun "$hipdun_kind")" \
			"$(hi_selection_kind_noun_plural "$hipdun_kind")")
		hipdun_note=$(hub_join_append "$hipdun_note" "$hipdun_kind_n other $hipdun_noun" ', ')
	done
	if [ "$HI_STD_UNCHANGED" -gt 0 ]; then
		hipdun_note=$(hub_join_append "$hipdun_note" \
			"$HI_STD_UNCHANGED $(hub_plural "$HI_STD_UNCHANGED" standard standards)" ', ')
	fi
	if [ "$HI_LENS_UNCHANGED" -gt 0 ]; then
		hipdun_note=$(hub_join_append "$hipdun_note" \
			"$HI_LENS_UNCHANGED $(hub_plural "$HI_LENS_UNCHANGED" 'review lens' 'review lenses')" ', ')
	fi
	# The unchanged FEATURES, by name — the one clause here that names rather than
	# counts (see hi_bucket_reset). Joined with the same separator as every other
	# clause, so "Inbox capture" and a hypothetical second unchanged feature read as
	# one list rather than two sentences.
	while IFS= read -r hipdun_feature; do
		[ -n "$hipdun_feature" ] || continue
		hipdun_note=$(hub_join_append "$hipdun_note" "$hipdun_feature" ', ')
	done <"$HI_FEATURE_UNCHANGED_ITEMS"
	if [ "$HI_BASE_UNCHANGED" -gt 0 ]; then
		hipdun_note=$(hub_join_append "$hipdun_note" "the $HI_BASE_UNCHANGED-item baseline" ', ')
	fi
	[ -n "$hipdun_note" ] || return 0
	printf '  (%s already installed, unchanged)\n' "$hipdun_note"
}

# hi_preview_domain_baseline DOMAIN BASELINE_GROUP -> classify DOMAIN's baseline,
# either as its NAMED FEATURES plus whatever remainder they do not claim, or — for
# a domain that declares no features, which is every domain but GTD — as the plain
# per-unit `baseline` bucket rows this file has always counted.
#
# BASELINE_GROUP MAY BE EMPTY, for a domain that has none (see
# hub_domain_baseline_group), and is then unused: such a domain reaches the feature
# path. THE INVARIANT THAT MAKES THAT SAFE, stated because nothing enforces it: a
# domain with no baseline group MUST declare features, or its content gets no line on
# this screen at all — its `selectable` bucket row is not counted here (the loop above
# reads only the keys a sub-selection screen selected, and such a domain has no such
# screen) and it has no `baseline` rows to fall back on. GTD satisfies it. A future
# `atomic:`-prefixed domain that does not would need its own arm here.
#
# WHY THE FEATURE PATH REPLACES THE BUCKET PATH RATHER THAN JOINING IT: the
# `baseline` bucket holds one row per baseline UNIT, so counting it as well would
# count GTD's three units into HI_BASE_NEW at the same time as the two feature
# lines account for them — the preview header would then read "6 new items" for a
# 3-unit install, and hi_preview_totals a few lines below it (which counts real
# units off PLAN_UNITS) would say 3. Two totals for one install, on the screen the
# user approves. The residual row is the same arithmetic over the units NO feature
# claims, so the two paths partition the baseline exactly once either way.
#
# A FEATURE ROW IS WEIGHTED BY ITS UNIT COUNT, exactly as a selectable row is
# weighted by its group's — see hi_bucket_add_row's "LINES ARE NOT UNITS". "Inbox
# capture" is one line standing for an agent and its nested skill, so an
# unweighted row would reintroduce the mixed-denominator bug that note exists to
# document.
#
# The residual is folded into HI_BASE_NEW/_DIVERGED/_UNCHANGED through
# hi_bucket_add_row's own `baseline` arm, in TWO WEIGHTED CALLS — one for the
# `pending` units and one for the already-installed remainder — rather than once per
# unit through two unrolling loops. That arm honors the weight like every other arm
# now (see hi_bucket_add_row), so the counters keep their one meaning (units) with no
# unrolling needed to get there. A zero weight is a no-op, which is what makes the
# unguarded pair safe when a residual is entirely pending or entirely installed.
hi_preview_domain_baseline() {
	hipdb_domain=$1
	hipdb_group=$2
	hipdb_features="$HUB_WORK/preview-features.tsv"
	hub_domain_feature_rows "$hipdb_domain" "$hipdb_features"
	if [ ! -s "$hipdb_features" ]; then
		hi_bucket_add_rows baseline "$hipdb_group"
		return 0
	fi
	while IFS="$HUB_TAB" read -r hipdb_state hipdb_count hipdb_pending hipdb_label; do
		[ -n "$hipdb_state" ] || continue
		[ "$hipdb_count" -gt 0 ] || continue
		if [ -z "$hipdb_label" ]; then
			# THE RESIDUAL, reported as the anonymous baseline count line, weighted by
			# units so HI_BASE_* stays a unit count. The changed/unchanged split is exact
			# (pending is the units a re-install would write); only the new-vs-diverged
			# split inside `pending` inherits the collapsed row's approximation, which is
			# the same one hi_bucket_add_row documents for a selectable row and is
			# unreachable today (nothing is residual).
			hipdb_installed=$((hipdb_count - hipdb_pending))
			hi_bucket_add_row baseline "$hipdb_state" '' "$hipdb_pending"
			hi_bucket_add_row baseline installed '' "$hipdb_installed"
			continue
		fi
		# WEIGHTED BY `pending`, NOT by the feature's total unit count: the block
		# header this feeds counts what is about to be WRITTEN, and hi_preview_totals
		# a few lines below it counts the same thing off PLAN_UNITS. A feature whose
		# agent is already installed and whose skill diverged stands for ONE write, so
		# weighting it by its two units made the header claim 2 while the totals line
		# on the same consent screen said 1.
		hi_bucket_add_row feature "$hipdb_state" "$hipdb_label" "$hipdb_pending"
	done <"$hipdb_features"
}

# hi_print_feature_hint DOMAIN -> the dimmed atomicity advisory under DOMAIN's
# feature lines, at the item-text indent, or nothing for a domain with no features.
#
# Printed on the PREVIEW only, immediately under the itemized lines and BEFORE the
# unchanged note: the note sits at the block indent (2) while items sit at 4, so a
# hint at the item-text indent (6) after it would read as an annotation on the
# wrong line. The RESULT screen deliberately prints no hint — there is nothing left
# to choose once the writes have landed — and neither does Doctor.
#
# Guarded on HI_FEATURE_ITEMIZED (see hi_bucket_add_row) so it never lands under a
# block that named no feature, and on the hint TEXT, so a future domain that
# declares features but no advisory prints no blank dimmed line.
hi_print_feature_hint() {
	[ "$HI_FEATURE_ITEMIZED" -eq 1 ] || return 0
	hipfh_hint=$(hub_domain_feature_hint "$1")
	[ -n "$hipfh_hint" ] || return 0
	printf '      %s\n' "$(hub_dim "$hipfh_hint")"
}

# hi_preview_domain DOMAIN -> DOMAIN's own preview block, called once per domain
# from hi_preview's own domain loop (see its header for why every domain's
# blocks print together rather than interleaved by block kind).
#
# Buckets, in this order: DOMAIN's own selectable items (technologies/trackers, by
# group state — each ONE line, with its own standard folded into it), then its lens
# reviewers split out from the rest of its baseline. A domain with none of this
# changing collapses to one line; otherwise every new/diverged item is itemized by
# name (see this section's own header for why), followed by one trailing note for
# whatever is left unchanged.
#
# The `standard` bucket is still WALKED but never rendered as its own line: it feeds
# HI_STD_UNCHANGED only, and a changing standard is reported by the technology line
# that owns it. See hi_bucket_reset on why a standard is not an individually
# nameable thing on any screen in this hub, and hi_bucket_add_row on why folding it
# is also what keeps the block header's unit arithmetic from double-counting it.
hi_preview_domain() {
	hipd_domain=$1
	hi_bucket_reset
	# ONE call, and the only classification this block performs — see the section
	# header above for why a discovery-scoped table serves both of the scopes the
	# blocks below need.
	hub_domain_buckets "$hipd_domain" "$HI_BUCKETS"

	# EVERY KIND THE DOMAIN HAS, not just its first: Software Development's
	# preview block now accumulates rows from BOTH its `vcs` and its
	# `technology` selection files into the same bucket set, in kind order —
	# one domain block, still, regardless of how many kinds fed it. A domain
	# with a single kind (or `none`) behaves byte-identically to before this
	# loop existed.
	hipd_has_kind=0
	# ASSIGNED, never inlined — see hi_selection_kinds' own note.
	hipd_kinds=$(hub_domain_selection_kind "$hipd_domain")
	for hipd_kind in $hipd_kinds; do
		[ "$hipd_kind" != none ] || continue
		hipd_has_kind=1
		hipd_sel=$(hi_sel_file "$hipd_kind")
		# THE SELECTED keys, each read from its own `selectable` row — one lookup
		# per key, whose state serves both decisions this loop makes (how to
		# classify the selectable itself, and whether its standards belong to this
		# loop at all), so the two can never disagree about one key.
		while IFS= read -r hipd_key; do
			[ -n "$hipd_key" ] || continue
			hipd_group=$(hi_selectable_group "$hipd_kind" "$hipd_key")
			hi_bucket_lookup selectable "$hipd_group" || continue
			# THE GROUP'S UNIT COUNT (the group table's column 8), passed as the row's
			# weight so the block header below counts UNITS rather than collapsed lines
			# — see hi_bucket_add_row's "LINES ARE NOT UNITS". Column 8 is filled by the
			# same discovery pass PLAN_UNITS is resolved from, which is what makes the
			# header and hi_preview_totals agree. An empty answer is structurally
			# impossible here (hi_bucket_lookup just found this group's row in a table
			# projected from the same group table), and hi_bucket_add_row's own
			# `${4:-1}` default keeps the arithmetic valid rather than erroring if it
			# ever were.
			hipd_units=$(hub_group_field "$hipd_group" 8)
			hi_bucket_add_row selectable "$HI_BK_STATE" "$HI_BK_DISPLAY" "$hipd_units"
			# AN ALREADY-INSTALLED KEY'S STANDARDS ARE NOT ADDED HERE — the
			# installed pass below owns them, and owning them in exactly one place
			# is what keeps HI_STD_UNCHANGED honest. This loop used to add EVERY
			# selected key's standard regardless of state while the pass below
			# added every installed group's, so any key that was both selected
			# and already installed had its standard counted TWICE: --all, and
			# any --technologies= naming something already there, over-reported
			# the "(N standards already installed, unchanged)" note.
			#
			# No `kind = technology` test guards this any more: a `standard` row
			# exists only for a unit under the shared per-technology standards
			# subtree (lib/hub-state.sh applies that src-path test itself), so a
			# selection kind that has no standards simply has no rows here.
			[ "$HI_BK_STATE" = installed ] || hi_bucket_add_rows standard "$hipd_group"
		done <"$hipd_sel"
	done
	# ALWAYS CREATED, even for a domain with no kind at all (GTD): the unchanged
	# note below reads this file unconditionally as its second argument, and an
	# absent file there would be a "file not found" error rather than the
	# correct "nothing installed to report" empty-file answer.
	hipd_installed="$HUB_WORK/preview-installed-groups.txt"
	: >"$hipd_installed"
	if [ "$hipd_has_kind" -eq 1 ]; then
		# The already-installed count, and those groups' already-installed
		# standards — deliberately over EVERY selectable row of this domain, not
		# just what is in any one kind's own selection file: the interactive
		# checklist no longer offers an already-installed group at all
		# (hi_selection_rows excludes it), so no selection file can ever carry
		# one, and this is the only remaining way to know how many exist. It is
		# also the SOLE source of the unchanged-standards count (see the loop
		# above), run ONCE for the whole domain rather than once per kind —
		# HI_BUCKETS already holds every kind's selectable rows together, so a
		# second pass per kind would double-count a domain with more than one.
		#
		# Scoped to the DOMAIN's own rows rather than to every group of a KIND,
		# which is what this read before: the two are the same set for a
		# single-kind domain, but a source where two domains share one selection
		# kind would otherwise credit this domain's block with the other
		# domain's installed technologies. That is the same reason
		# hub_domain_selectable_groups filters on the domain column (see its
		# header).
		awk -F '\t' '$1 == "selectable" && $3 == "installed" { print $2 }' \
			"$HI_BUCKETS" >"$hipd_installed"
		while IFS= read -r hipd_all_group; do
			[ -n "$hipd_all_group" ] || continue
			HI_SEL_UNCHANGED=$((HI_SEL_UNCHANGED + 1))
			hi_bucket_add_rows standard "$hipd_all_group"
		done <"$hipd_installed"
	fi

	# The baseline, already split into its lens reviewers and everything else by
	# the table's own src-path test — no `domain = software-development` literal
	# here any more. A domain with no lens subtree contributes no `lens` rows and
	# the first call is simply a no-op for it; a second domain that ever grows
	# lens reviewers is itemized on the same footing, with no edit here.
	#
	# ASKED FOR, never constructed: a domain with no baseline group has no `lens` or
	# `baseline` bucket rows to add (hub_domain_buckets emits none), and its own
	# content is reported by the feature path inside hi_preview_domain_baseline.
	# Passing it an EMPTY group is correct rather than a gap — that function branches
	# on whether the domain declares features, not on the group it is handed, and the
	# group is used only by its no-features path.
	hipd_baseline_group=$(hub_domain_baseline_group "$hipd_domain")
	hi_bucket_add_rows lens "$hipd_baseline_group"
	hi_preview_domain_baseline "$hipd_domain" "$hipd_baseline_group"

	# BOTH ADDENDS ARE UNIT COUNTS. HI_NEW_UNITS / HI_DIVERGED_UNITS are the itemized
	# lines' own unit weight (a collapsed technology contributes its whole group), not
	# the number of lines — see hi_bucket_add_row's "LINES ARE NOT UNITS" for the
	# mixed-denominator bug this replaced and for the one approximation that remains.
	hipd_new=$((HI_NEW_UNITS + HI_BASE_NEW))
	hipd_diverged=$((HI_DIVERGED_UNITS + HI_BASE_DIVERGED))

	# Assigned once, never inlined four times as a printf argument: hub_domain_label
	# is a closed lookup that DIES on a key outside its set, and a die inside a
	# command substitution used as an ARGUMENT is swallowed — the substitution yields
	# empty, printf still succeeds, and the block loses its subject while still
	# claiming "N new items". The same hoisting lib/hub-state.sh's hub_rows_build,
	# hi_shared_heading and hi_result_domain_block all state.
	hipd_label=$(hub_domain_label "$hipd_domain")

	if [ "$hipd_new" -eq 0 ] && [ "$hipd_diverged" -eq 0 ]; then
		printf '  %s — already installed and up to date, unchanged.\n\n' "$hipd_label"
		return 0
	fi

	if [ "$hipd_new" -gt 0 ] && [ "$hipd_diverged" -gt 0 ]; then
		printf '  %s — %s new %s, %s diverged %s, will re-sync:\n' "$hipd_label" \
			"$hipd_new" "$(hub_plural "$hipd_new" item items)" \
			"$hipd_diverged" "$(hub_plural "$hipd_diverged" item items)"
	elif [ "$hipd_new" -gt 0 ]; then
		printf '  %s — %s new %s:\n' "$hipd_label" \
			"$hipd_new" "$(hub_plural "$hipd_new" item items)"
	else
		printf '  %s — %s diverged %s, will re-sync:\n' "$hipd_label" \
			"$hipd_diverged" "$(hub_plural "$hipd_diverged" item items)"
	fi

	while IFS= read -r hipd_line; do
		[ -n "$hipd_line" ] || continue
		printf '    %s %s\n' "$(hub_glyph_new)" "$hipd_line"
	done <"$HI_NEW_ITEMS"
	# The baseline's own new/diverged counts print as ONE line each — never a
	# name per item, matching List's own convention (see hi_bucket_reset's
	# header) — right after the individually-nameable new items above.
	[ "$HI_BASE_NEW" -eq 0 ] || printf '    %s new baseline (%s %s)\n' \
		"$(hub_glyph_new)" "$HI_BASE_NEW" "$(hub_plural "$HI_BASE_NEW" item items)"
	while IFS= read -r hipd_line; do
		[ -n "$hipd_line" ] || continue
		printf '    %s %s\n' "$(hub_glyph_warn)" "$hipd_line"
	done <"$HI_DIVERGED_ITEMS"
	[ "$HI_BASE_DIVERGED" -eq 0 ] || printf '    %s diverged baseline (%s %s), will re-sync\n' \
		"$(hub_glyph_warn)" "$HI_BASE_DIVERGED" "$(hub_plural "$HI_BASE_DIVERGED" item items)"

	hi_print_feature_hint "$hipd_domain"
	hi_preview_domain_unchanged_note "$hipd_domain" "$hipd_installed"
	printf '\n'
}

# hi_shared_heading GROUP -> the heading a cross-domain block carries, on BOTH
# screens that draw one (the preview below and the Result screen further down).
#
# The label comes from the group table rather than being written out, so two
# shared groups would be told apart instead of both printing one hardcoded name;
# the parenthetical is the consent-relevant fact about every such group — it is
# installed ONCE no matter how many domains pulled it in — and lives here rather
# than in two printf strings that would drift.
# The label is assigned before the printf, never inlined as its argument:
# hub_group_field dies (via hub_discovery_require) on an unbuilt discovery, and a
# die inside a command substitution used as an ARGUMENT is swallowed — the
# substitution yields empty, printf still succeeds, and the heading silently loses
# its subject. The same hazard lib/hub-state.sh's hub_rows_build states.
hi_shared_heading() {
	hish_label=$(hub_group_field "$1" 2)
	printf '%s (shared by more than one domain; installed once)' "$hish_label"
}

# hi_preview_shared -> ONE cross-domain block, then every shared group the plan
# pulled in underneath it, each with its own units plus its own wrapped
# "required by:" attribution.
#
# ONE HEADING FOR THE WHOLE BLOCK, not one per group — this changed the moment a
# second shared group existed (GitLab-auth alongside GitHub-auth): hi_shared_heading
# reads its label from the group table, and every shared group's label is the
# identical "Cross-domain" (lib/hub-discovery.sh's domain_label() awk function has
# exactly one fallback for "belongs to no registered domain"), so printing it once
# per group printed "Cross-domain (shared by more than one domain; installed
# once):" twice in a row with one group's units and required-by note under each —
# the same per-group-heading bug hub-list.sh's hl_print_nondomain_groups had and
# was fixed the same way: one heading, then every qualifying group's own content
# underneath it, in role order.
hi_preview_shared() {
	hipsh_heading_written=0
	for hipsh_shared in $(hub_groups_of_role shared); do
		grep -qxF -- "$hipsh_shared" "$PLAN_GROUPS" || continue
		if [ "$hipsh_heading_written" -eq 0 ]; then
			hipsh_heading=$(hi_shared_heading "$hipsh_shared")
			printf '  %s:\n' "$hipsh_heading"
			hipsh_heading_written=1
		fi
		hi_print_units "$hipsh_shared" any
		hipsh_first=1
		while IFS= read -r hipsh_note; do
			[ -n "$hipsh_note" ] || continue
			if [ "$hipsh_first" -eq 1 ]; then
				printf '      required by: %s' "$hipsh_note"
				hipsh_first=0
			else
				printf ',\n                   %s' "$hipsh_note"
			fi
		done <"$(hi_reqby_file "$hipsh_shared")"
		printf '\n'
	done
	[ "$hipsh_heading_written" -eq 0 ] || printf '\n'
}

# hi_preview_totals -> the total, phrased around what will actually be WRITTEN
# (ATTEMPT_COUNT = new + diverged), not the full size of what was selected (the
# whole PLAN_UNITS row count) — the same "say what will happen, not what was selected" rule
# every hi_preview_domain block follows above. Reached only when ATTEMPT_COUNT is
# known to be positive OR the bundle needs installing (hi_preview's own caller
# already routed the "nothing at all" case straight to the no-op exit before
# this function is ever called), so the plain, no-breakdown line below is for
# the one remaining edge case: a bundle-only run where every component is
# already installed and unchanged.
hi_preview_totals() {
	if [ "$NEW_COUNT" -gt 0 ] && [ "$REPLACE_COUNT" -gt 0 ]; then
		printf '  %s %s total: %s new, %s re-syncing. Nothing has changed yet.\n' \
			"$ATTEMPT_COUNT" "$(hub_plural "$ATTEMPT_COUNT" item items)" "$NEW_COUNT" "$REPLACE_COUNT"
	elif [ "$NEW_COUNT" -gt 0 ]; then
		printf '  %s %s total, all new. Nothing has changed yet.\n' \
			"$ATTEMPT_COUNT" "$(hub_plural "$ATTEMPT_COUNT" item items)"
	elif [ "$REPLACE_COUNT" -gt 0 ]; then
		printf '  %s %s total, all re-syncing. Nothing has changed yet.\n' \
			"$ATTEMPT_COUNT" "$(hub_plural "$ATTEMPT_COUNT" item items)"
	else
		printf '  %s %s total. Nothing has changed yet.\n' "$ATTEMPT_COUNT" "$(hub_plural "$ATTEMPT_COUNT" item items)"
	fi
	if [ "$SKIP_COUNT" -gt 0 ]; then
		printf '  (%s already installed and up to date, not counted above.)\n' "$SKIP_COUNT"
	fi
}

# hi_preview_bundle -> the first-run bundle block, including the consent-relevant
# fact that an existing foreign CLAUDE.md will be preserved.
hi_preview_bundle() {
	[ "$BUNDLE_NEEDED" -eq 1 ] || return 0
	printf '\n  Also installing (first run only, not counted above):\n'
	printf "    %s and the framework's contract schemas.\n" "$HUB_BUNDLE_CONFIG_NAME"
	[ -n "$BUNDLE_PREVIEW_BACKUP" ] || return 0
	# THE STABLE PREFIX, not the probe's concrete filename. The probe computed a
	# name from its own `date -u` stamp, and the apply run computes a fresh one
	# (and may append -2 if that second name is taken) — so any exact name shown
	# here is a promise the apply path cannot keep the moment more than a second
	# passes at the confirm prompt. The consent-relevant fact is that the existing
	# contract IS preserved and where it lands; the exact stamp is reported by the
	# Result screen below, which prints the name that was actually written.
	printf '\n  Your existing %s will be backed up first:\n' "$HUB_BUNDLE_CONFIG_NAME"
	printf '    %s %s %s.backup.<timestamp>\n' "$TARGET_DIR/$HUB_BUNDLE_CONFIG_NAME" \
		"$(hub_glyph_arrow)" "$TARGET_DIR/$HUB_BUNDLE_CONFIG_NAME"
}

# hi_preview -> the whole dry-run screen. Always human-readable text, in EVERY
# mode: the dry run is the informed-consent surface and an agent-facing caller
# gets to read it too.
#
# EVERY BLOCK OF ONE DOMAIN PRINTS TOGETHER, before moving to the next domain —
# a live test session found the previous shape (one pass per BLOCK KIND across
# every domain: all domains' selectable blocks, then all domains' standards
# blocks, then all domains' baseline blocks) interleaved unrelated domains'
# output, e.g. Software Development's selectable block, then Project
# Management's, then back to Software Development's standards block. The
# selection screens themselves walk one domain fully before the next; the
# preview now confirms in that same order, domain by domain. The cross-domain
# shared block, the totals and the bundle stay domain-agnostic by nature and are
# still printed once, after every domain's own blocks.
#
# The blocks are wrapped in ONE `{ ... } >&3` — the human channel opened at the
# top of this script. A brace group, not a subshell, so anything it sets survives
# it (nothing does any more, now that each block owns its own variables).
hi_preview() {
	{
		if [ "$OPT_ALL" -eq 1 ]; then
			# BULK EMPHASIS, matching hub-uninstall.sh's own "Uninstall ALL" line
			# and the base spec's bulk-header convention: an --all run is not "N
			# domains", it is everything, and the header says so.
			hub_print_header "Install ALL to $TARGET_DIR"
		else
			hip_domains=$(hub_count_lines "$SEL_DOMAINS")
			hub_print_header "Install $hip_domains $(hub_plural "$hip_domains" domain domains) to $TARGET_DIR"
		fi
		printf '\n'

		for hip_dom in $HUB_DOMAIN_KEYS; do
			grep -qxF -- "$hip_dom" "$SEL_DOMAINS" || continue
			hi_preview_domain "$hip_dom"
		done
		hi_preview_shared
		hi_preview_totals
		hi_preview_bundle

		printf '\n'
		hub_dry_run_marker
		printf '\n'
	} >&3
}

# hi_pending_count -> how many items the user has SELECTED but not yet committed,
# which is what the discard guard asks about ("Discard N selected items and
# quit?"). Deliberately NOT the resolved unit count: selecting one domain resolves
# to dozens of units, and "Discard 47 selected items" describes a selection the
# user never made.
hi_pending_count() {
	hipc_total=$(hub_count_lines "$SEL_DOMAINS")
	for hipc_kind in $(hi_selection_kinds); do
		hipc_total=$((hipc_total + $(hub_count_lines "$(hi_sel_file "$hipc_kind")")))
	done
	printf '%s' "$hipc_total"
}

# ===========================================================================
# Result blocks — the Result screen's DETAIL view, at the same granularity the
# preview reports in: one block per domain, one line per technology/tracker, the
# baseline collapsed to a single count line.
#
# IT USED TO BE ONE FLAT LINE PER ACTED-ON UNIT — "Python agent developer",
# "Python agent reviewer", "Python standard", "Java agent developer", … — which is
# the one granularity no screen a human reads uses anywhere else: the preview
# collapses a technology to "+ Python" (see its own section header on itemizing
# only what changes), List collapses it to "✓ Python", and only Doctor itemizes
# units, because naming the individual agent that diverged IS its job. This screen
# has the opposite job — confirming back what the human just approved — and a
# selective install printed the flat list BY DEFAULT (hub_result_details itemizes
# every non---all result), which made it the most commonly seen form. Someone who
# approved "Python, Java, Rust" wants those three names confirmed, not the nine
# files they resolved to.
#
# WHY THE GROUPING COMES FROM PLAN_UNITS' OWN GROUP COLUMN and not from a second
# hub_domain_buckets call: that table is a projection of HUB_STATES, which was
# computed BEFORE the apply, so re-deriving it afterwards would report `installed`
# for every unit — including every unit that was already installed and never
# touched — and it has no way to express "this run wrote this". Only the apply loop
# knows that, so it records each acted-on unit's GROUP and SRC beside its display
# name and the blocks below aggregate those. RESULT is therefore a TSV,
# "group<TAB>src<TAB>display", with the display name LAST because it is the only
# one of the three whose emptiness is even possible (lib/hub-common.sh's "THE TAB
# TRAP"); RESULT_COUNT is a line count either way, so nothing downstream of it
# changed.
#
# --format=env and --format=json are deliberately NOT reshaped with this. They stay
# flat and per-unit: the grouping exists to solve a human scanning problem a
# machine caller does not have, and their payload is a published contract.
# ===========================================================================

# HI_RESULT_GROUPS / HI_RESULT_LINES — the group keys the blocks walk, and the
# per-block line buffer they fill before deciding whether the block has anything
# to print at all. Fixed paths under HUB_WORK, for the reason HI_BUCKETS states
# above; two DIFFERENT paths because a block iterates the first while writing the
# second.
HI_RESULT_GROUPS="$HUB_WORK/result-group-keys.txt"
HI_RESULT_LINES="$HUB_WORK/result-block-lines.txt"

# hi_result_blocks -> the whole detail view: one block per domain in canonical
# domain order, then one per group that belongs to no domain.
#
# The two halves cover EVERY group by construction — a group's domain column
# either holds one of the registry's keys or it does not — so no acted-on unit can
# fall outside the rendered blocks and leave the header's own "N/M items" claiming
# more than the screen shows.
hi_result_blocks() {
	hub_group_keys >"$HI_RESULT_GROUPS"
	for hirb_domain in $HUB_DOMAIN_KEYS; do
		hi_result_domain_block "$hirb_domain"
	done
	hi_result_nondomain_blocks
}

# hi_result_domain_block DOMAIN -> DOMAIN's heading and its own collapsed lines,
# or nothing at all when this run touched none of DOMAIN's groups.
#
# THE GROUP'S ROLE DECIDES THE COLLAPSE, read from the group table's own column
# rather than inferred from the group key's shape: a `selectable` group is ONE line
# at its label (the technology or tracker the human actually picked), annotated with
# how many of its units this run actually wrote so the line reconciles with the
# header's own unit count, and a `baseline` group is one count line. Any other role
# is itemized by unit — an arm nothing reaches today (the grammar has three roles
# and the third, `shared`, belongs to no domain), which itemizes rather than dying
# because silently dropping a unit AFTER the writes have landed is the one outcome
# this screen must never produce.
#
# EXCEPT WHERE THE DOMAIN DECLARES FEATURES, which is tested FIRST, ahead of the role
# dispatch — and that order is the whole point rather than a preference. A domain that
# is its own single selectable group (GTD) carries `role=selectable`, so the role
# dispatch alone gave it the generic one-line collapse at its own domain label, on the
# one screen that reports what a run actually wrote. Every other feature-aware surface
# — List, the preview above, Doctor, Uninstall — names "Inbox capture" and "Inbox
# triage", so this screen alone would have confirmed back a name none of them showed.
# The feature renderer is the same one the `baseline` arm uses; what changes is only
# which groups reach it.
hi_result_domain_block() {
	hirdb_domain=$1
	: >"$HI_RESULT_LINES"
	while IFS= read -r hirdb_group; do
		[ -n "$hirdb_group" ] || continue
		# EVERY substitution assigned before it is used, never inlined as an
		# argument or a `case` word: hub_group_field dies (via
		# hub_discovery_require) on an unbuilt discovery, and a die inside a command
		# substitution used as an argument is swallowed — the substitution yields
		# empty and the caller carries on with a malformed line. The same hazard
		# lib/hub-state.sh's hub_rows_build and hub_domain_buckets both state.
		hirdb_group_domain=$(hub_group_field "$hirdb_group" 3)
		[ "$hirdb_group_domain" = "$hirdb_domain" ] || continue
		hirdb_count=$(hi_result_group_count "$hirdb_group")
		[ "$hirdb_count" -gt 0 ] || continue
		# The feature test comes BEFORE the role dispatch — see this function's header
		# on why that order, and not the role column alone, is what keeps a featured
		# domain named the same way here as on every other screen.
		hirdb_features=$(hub_domain_feature_keys "$hirdb_domain")
		if [ -n "$hirdb_features" ]; then
			hi_result_baseline_lines "$hirdb_domain" "$hirdb_group" "$hirdb_count" >>"$HI_RESULT_LINES"
			continue
		fi
		hirdb_role=$(hub_group_field "$hirdb_group" 4)
		case $hirdb_role in
		selectable)
			hirdb_label=$(hub_group_field "$hirdb_group" 2)
			# ANNOTATED WITH THE UNITS IT ACCOUNTS FOR, for the reason
			# hub-uninstall.sh's hu_row_lines states for the identical shape: this
			# screen's own header counts UNITS ("Installed 9/9 items"), while one
			# collapsed selectable line stands for a whole technology, so an
			# unannotated list of three names under a "9 items" header cannot be
			# reconciled by the reader. hirdb_count is already the units this run wrote
			# for the group (the caller needed it to decide the group belongs in the
			# block at all), so nothing is recomputed.
			#
			# NO "(1 item)" ON A SINGLE-UNIT ROW, exactly as hu_row_lines suppresses it:
			# the annotation exists to explain why one name accounts for several items,
			# and on a lone unit it says nothing the line did not already. (The baseline
			# line keeps its "(1 item)" — see hi_result_baseline_line — because there the
			# count IS the subject: the line names no unit at all.)
			if [ "$hirdb_count" -gt 1 ]; then
				printf '%s (%s %s)\n' "$hirdb_label" "$hirdb_count" \
					"$(hub_plural "$hirdb_count" item items)" >>"$HI_RESULT_LINES"
			else
				printf '%s\n' "$hirdb_label" >>"$HI_RESULT_LINES"
			fi
			;;
		baseline) hi_result_baseline_lines "$hirdb_domain" "$hirdb_group" "$hirdb_count" >>"$HI_RESULT_LINES" ;;
		*) hi_result_group_units "$hirdb_group" >>"$HI_RESULT_LINES" ;;
		esac
	done <"$HI_RESULT_GROUPS"
	[ -s "$HI_RESULT_LINES" ] || return 0
	# Assigned, not inlined, for the reason stated in the loop above:
	# hub_domain_label dies on a key outside its closed set.
	hirdb_heading=$(hub_domain_label "$hirdb_domain")
	printf '  %s\n' "$hirdb_heading"
	hi_result_print_lines "$HI_RESULT_LINES"
}

# hi_result_group_count GROUP -> how many of GROUP's units this run acted on.
#
# Counted inside awk (END { print n + 0 }) rather than piped through
# `wc -l | tr -d ' '`, for the reason lib/hub-state.sh's hub_state_counts gives:
# same answer, two fewer processes per count, and no BSD/GNU padding to strip.
hi_result_group_count() {
	hirgc_group="$1" awk -F '\t' \
		'$1 == ENVIRON["hirgc_group"] { n++ } END { print n + 0 }' "$RESULT"
}

# hi_result_baseline_line SRCS COUNT -> the single line a baseline group gets:
# "Framework baseline (N items)", plus ", incl. M review lenses" when any of the N
# are lens reviewers.
#
# ONE LINE FOR THE WHOLE BASELINE, itemizing nothing, because a baseline item's
# individual identity is surfaced nowhere in this hub's UI — see hi_bucket_reset's
# header for the full statement of that convention, which List follows too.
#
# COUNT IS PASSED IN rather than recomputed: the caller already had to know it to
# decide this group belongs in the block at all, and counting it twice from two
# places is how the line and its own precondition drift apart.
#
# SO IS THE src LIST, and for the same reason turned the other way round: this used
# to take the GROUP and re-derive every src the run wrote for it, which is the wrong
# denominator on the one call that does not stand for the whole group. A featured
# domain's RESIDUAL line reports only the units no feature claimed, so a lens clause
# counted over the group's full src list would credit a "Framework baseline (1 item)"
# line with every lens the whole baseline installed. Both callers now hand over
# exactly the srcs the line stands for, beside the count of those same srcs.
#
# The lens clause goes through hub_src_in_dir, the canonical spelling of the
# src-path test (see its header in lib/hub-domains.sh, which asks a new caller to
# either consume hub_domain_buckets' `bucket` column or call it — this screen
# cannot use that column, since the bucket table cannot say what this RUN wrote).
# No domain literal and no name list: a domain with no lens subtree counts zero and
# drops the clause.
#
# hi_result_baseline_lines DOMAIN GROUP COUNT -> the line(s) DOMAIN's baseline gets
# on the receipt: one per NAMED FEATURE this run actually wrote to, plus the
# collapsed count line for whatever no feature claims — or, for a domain that
# declares no features, just that count line, which is every domain but GTD.
#
# CLASSIFIED FROM RESULT'S OWN src COLUMN, one unit at a time, and NOT from
# lib/hub-state.sh's hub_domain_feature_rows: that function reports the state of
# every unit a feature HAS, while this screen reports what this RUN WROTE. The two
# differ on exactly the case the receipt exists for — a feature whose second unit
# was blocked by a foreign occupant must collapse to "Inbox capture (1 item)"
# against a preview that promised 2, and a projection of the pre-apply state cannot
# say that. Same reason the Result section header gives for grouping off
# PLAN_UNITS instead of re-deriving hub_domain_buckets.
#
# ORDER COMES FROM THE REGISTRY, never from awk for-in, so the receipt lists
# features in the same order the preview and List do — through lib/hub-state.sh's
# hub_feature_counts, the shared projection all three feature-aware screens call
# rather than each keeping its own copy of the registry walk, the awk counter and the
# label hoist. What stays here is this screen's own rendering: the "(N items)"
# annotation and its suppression at one.
#
# LENS REVIEWERS ARE EXCLUDED BEFORE THE FEATURE TEST, the order
# lib/hub-state.sh's hub_domain_feature_rows applies and for its reason:
# hub_domain_feature_of classifies by positive path shape, so an `agents/` test
# reached first would claim a featured domain's `agents/reviewers/lens/*` units as a
# `capture` feature. A lens unit falls to the residual instead, where it is counted
# by the collapsed line that already reports lenses separately
# (hi_result_baseline_line's own ", incl. N review lenses" clause). Unreachable today
# — GTD ships no lens subtree — and cheap to keep right while both classifiers agree.
#
# THE "(N items)" ANNOTATION follows this screen's existing rule for a collapsed
# line, not a new one: a feature line stands for as many units as the run wrote for
# it, while the header above counts UNITS ("Installed 3/3 items"), so an
# unannotated pair of names cannot be reconciled by the reader — exactly the
# argument the `selectable` arm above makes. And it is suppressed at ONE unit for
# the same reason it is there: the annotation exists to explain why one name
# accounts for several items.
hi_result_baseline_lines() {
	hirbls_domain=$1
	hirbls_group=$2
	hirbls_count=$3
	hirbls_srcs="$HUB_WORK/result-feature-srcs.txt"
	hirbls_residual_srcs="$HUB_WORK/result-residual-srcs.txt"
	hirbls_keyed="$HUB_WORK/result-feature-keyed.txt"
	hirbls_counts="$HUB_WORK/result-feature-counts.tsv"
	# THE GROUP'S OWN srcs, resolved BEFORE the no-features shortcut, because both
	# paths need them now: the collapsed line counts its lens reviewers off exactly the
	# srcs it is reporting on (see hi_result_baseline_line, which takes the list rather
	# than re-deriving one).
	hirbls_group="$hirbls_group" awk -F '\t' \
		'$1 == ENVIRON["hirbls_group"] { print $2 }' "$RESULT" >"$hirbls_srcs"
	hirbls_keys=$(hub_domain_feature_keys "$hirbls_domain")
	if [ -z "$hirbls_keys" ]; then
		hi_result_baseline_line "$hirbls_srcs" "$hirbls_count"
		return 0
	fi
	: >"$hirbls_keyed"
	: >"$hirbls_residual_srcs"
	hirbls_residual=0
	while IFS= read -r hirbls_src; do
		[ -n "$hirbls_src" ] || continue
		# THE LENS TEST FIRST, then the feature test — see this function's header on
		# why that order is the classifier's, not a style choice. A negated `if` around
		# the second test rather than two nested ones, so a lens and an unclaimed unit
		# reach the same residual arm below by the same route.
		hirbls_key=''
		if ! hub_src_in_dir "$hirbls_src" "$HUB_SD_DIR_LENS_REVIEWERS"; then
			hirbls_key=$(hub_domain_feature_of "$hirbls_domain" "$hirbls_src")
		fi
		if [ -z "$hirbls_key" ]; then
			hirbls_residual=$((hirbls_residual + 1))
			printf '%s\n' "$hirbls_src" >>"$hirbls_residual_srcs"
			continue
		fi
		printf '%s\n' "$hirbls_key" >>"$hirbls_keyed"
	done <"$hirbls_srcs"
	hub_feature_counts "$hirbls_domain" "$hirbls_keyed" "$hirbls_counts"
	while IFS="$HUB_TAB" read -r hirbls_n hirbls_label; do
		[ -n "$hirbls_n" ] || continue
		if [ "$hirbls_n" -gt 1 ]; then
			printf '%s (%s %s)\n' "$hirbls_label" "$hirbls_n" \
				"$(hub_plural "$hirbls_n" item items)"
		else
			printf '%s\n' "$hirbls_label"
		fi
	done <"$hirbls_counts"
	# The residual, if this run wrote anything no feature claims. Reuses the plain
	# baseline line so an anonymous remainder is worded identically on every screen —
	# and hands it the RESIDUAL srcs, so its own lens clause describes exactly the
	# units the line stands for rather than the whole group's.
	[ "$hirbls_residual" -eq 0 ] ||
		hi_result_baseline_line "$hirbls_residual_srcs" "$hirbls_residual"
}

# The label is lib/hub-domains.sh's HUB_BASELINE_LABEL — the generic "Framework
# baseline", for every domain and for the residual of a featured one, and a registry
# constant rather than a literal here because hub-list.sh and hub-doctor.sh print the
# same line (see that constant's own header). The GTD-specific "Inbox capture" label
# hub-list.sh used to give this same line is gone from that screen too — GTD's
# footprint is reported by its named FEATURE lines now (see hi_result_baseline_lines
# above), so there is no longer a second, disagreeing name for one domain's baseline
# anywhere in the hub.
hi_result_baseline_line() {
	hirbl_srcs=$1
	hirbl_count=$2
	hirbl_lenses=0
	while IFS= read -r hirbl_src; do
		[ -n "$hirbl_src" ] || continue
		# An `if`, never `hub_src_in_dir … && hirbl_lenses=…`: a predicate returning
		# 1 as the last command of a loop body trips `set -e`, and the non-lens arm
		# is the common case. The same shape lib/hub-state.sh's own baseline walk
		# states.
		if hub_src_in_dir "$hirbl_src" "$HUB_SD_DIR_LENS_REVIEWERS"; then
			hirbl_lenses=$((hirbl_lenses + 1))
		fi
	done <"$hirbl_srcs"
	hirbl_note=""
	if [ "$hirbl_lenses" -gt 0 ]; then
		hirbl_note=$(printf ', incl. %s %s' "$hirbl_lenses" \
			"$(hub_plural "$hirbl_lenses" 'review lens' 'review lenses')")
	fi
	printf '%s (%s %s%s)\n' "$HUB_BASELINE_LABEL" "$hirbl_count" \
		"$(hub_plural "$hirbl_count" item items)" "$hirbl_note"
}

# hi_result_group_units GROUP -> one display name per line for every unit of GROUP
# this run acted on. The shape for a block that does NOT collapse: the cross-domain
# group, which is always small (one unit today) and which the preview's own
# cross-domain block already itemizes for the same reason (see hi_print_units).
hi_result_group_units() {
	hirgu_group="$1" awk -F '\t' \
		'$1 == ENVIRON["hirgu_group"] { print $3 }' "$RESULT"
}

# hi_result_print_lines FILE -> one glyph-prefixed line per line of FILE, at the
# indent every per-domain item on every screen uses (hub-list.sh's status groups
# included).
hi_result_print_lines() {
	while IFS= read -r hirpl_line; do
		[ -n "$hirpl_line" ] || continue
		printf '    %s %s\n' "$(hub_glyph_ok)" "$hirpl_line"
	done <"$1"
}

# hi_result_nondomain_blocks -> ONE block for every acted-on group belonging to
# no domain: today, the two cross-domain shared groups (one per VCS host), under
# ONE heading (hi_shared_heading) — not one heading per group. Same fix, same
# reason, as hi_preview_shared above: every shared group's own label is the
# identical "Cross-domain", so a second shared group meant a second identical
# heading with one group's units under each half; now every qualifying group's
# units list underneath the single heading instead.
#
# Selected by the DOMAIN column rather than by `hub_groups_of_role shared`,
# deliberately: paired with hi_result_blocks' per-domain half, "its domain is not
# one of the registry's keys" is what makes the two halves provably exhaustive,
# where a role-name filter would silently drop a group carrying some third role.
# The heading falls back to the plain group label for such a group, since the
# "installed once" promise is only true of a genuinely shared one — taken from
# the FIRST qualifying group only, safe because every non-domain group today
# shares that identical label and role.
hi_result_nondomain_blocks() {
	hirnb_heading_written=0
	while IFS= read -r hirnb_group; do
		[ -n "$hirnb_group" ] || continue
		hirnb_domain=$(hub_group_field "$hirnb_group" 3)
		if hub_domain_is_registered "$hirnb_domain"; then
			continue
		fi
		hirnb_count=$(hi_result_group_count "$hirnb_group")
		[ "$hirnb_count" -gt 0 ] || continue
		if [ "$hirnb_heading_written" -eq 0 ]; then
			hirnb_role=$(hub_group_field "$hirnb_group" 4)
			hirnb_heading=$(hub_group_field "$hirnb_group" 2)
			[ "$hirnb_role" != shared ] || hirnb_heading=$(hi_shared_heading "$hirnb_group")
			printf '  %s\n' "$hirnb_heading"
			hirnb_heading_written=1
		fi
		hi_result_group_units "$hirnb_group" >"$HI_RESULT_LINES"
		hi_result_print_lines "$HI_RESULT_LINES"
	done <"$HI_RESULT_GROUPS"
}

# ===========================================================================
# THE PLAN LOOP — selection -> groups -> units -> preview -> confirm.
#
# It is a LOOP, not a straight line, for exactly one reason: `b` on the confirm
# screen must go back ONE step to the checklist that produced the pending
# selection, not throw that selection away. hub_confirm_gate returns 2 for back;
# funnelling that into the same arm as a cancel silently discarded everything the
# user had just picked — while the adjacent `q` on that very screen is guarded by
# hub_discard_guard precisely to prevent that loss.
#
# Everything inside re-derives from the selection files on every pass and
# truncates what it appends to, so a second pass is a clean recomputation, never
# an accumulation on top of the first.
#
# THE BODY IS DELIBERATELY AT COLUMN 0, not indented one level under `while`.
# It is the script's main line of work — selection, plan, preview, confirm, then
# fall through to apply — and indenting ~90 lines of top-level flow to signal a
# loop that exists only for the `b` round trip buys nothing and costs a column of
# every line. The loop's two exits are the `break` in the confirm block and the
# `continue` in its BACK arm; there are no others.
# ===========================================================================
PLAN_GROUPS="$HUB_WORK/plan-groups.txt"
PLAN_UNITS="$HUB_WORK/plan-units.tsv"
NEW_LIST="$HUB_WORK/new.txt"
REPLACE_LIST="$HUB_WORK/replace.txt"
SKIP_LIST="$HUB_WORK/skip.txt"

while :; do

[ "$INTERACTIVE_SELECTION" -eq 0 ] || hi_select_interactive

if [ ! -s "$SEL_DOMAINS" ]; then
	hi_ok_exit false 'Nothing to install — no domain selected.'
fi

hi_plan_groups_build
hub_units_of_groups "$PLAN_GROUPS" >"$PLAN_UNITS"

: >"$NEW_LIST"
: >"$REPLACE_LIST"
: >"$SKIP_LIST"
while IFS="$HUB_TAB" read -r _ HI_NAME HI_KIND HI_SRC _; do
	[ -n "$HI_NAME" ] || continue
	hub_state_set "$HI_KIND" "$HI_NAME" "$HI_SRC" "$TARGET_DIR"
	case $HUB_STATE in
	available) printf '%s\n' "$HI_NAME" >>"$NEW_LIST" ;;
	DIVERGED) printf '%s\n' "$HI_NAME" >>"$REPLACE_LIST" ;;
	installed) printf '%s\n' "$HI_NAME" >>"$SKIP_LIST" ;;
	esac
done <"$PLAN_UNITS"
NEW_COUNT=$(hub_count_lines "$NEW_LIST")
REPLACE_COUNT=$(hub_count_lines "$REPLACE_LIST")
SKIP_COUNT=$(hub_count_lines "$SKIP_LIST")
ATTEMPT_COUNT=$((NEW_COUNT + REPLACE_COUNT))

# THE SOURCE MUST ACTUALLY HAVE A BUNDLE TO INSTALL, and that is part of
# BUNDLE_NEEDED rather than a condition checked later, so the preview, the totals
# and the apply step cannot disagree about it. hub_bundle_install DIES without a
# root CLAUDE.md, and a --source that ships none (a partial checkout, a custom
# tree; see lib/hub-domains.sh's hub_domain_exists) is a legitimate state — so
# without this second clause the preview promised CLAUDE.md and the contract
# schemas, took the user's consent, and only THEN died inside hub_bundle_install,
# after consent, with no HUB_STATUS payload and nothing written. The preview
# probe below was already gated this way; this makes the state itself carry the
# fact, which is what keeps the APPLY=1 call symmetric with it.
BUNDLE_STATE=$(hub_bundle_state "$FRAMEWORK_ROOT" "$TARGET_DIR")
BUNDLE_NEEDED=0
if [ "$BUNDLE_STATE" != installed ] && hub_bundle_config_src "$FRAMEWORK_ROOT" >/dev/null; then
	BUNDLE_NEEDED=1
fi

# WHETHER applying would BACK UP an existing foreign CLAUDE.md, answered by asking
# hub_bundle_install itself in preview mode (APPLY=0) rather than by a second copy
# of its foreign-occupant test here. Replacing the user's operating contract is the
# single most consequential thing an install does, so the informed-consent surface
# has to say it BEFORE the confirm prompt — not only on the Result screen
# afterwards, where the decision has already been made.
#
# The probe needs no gate of its own any more: BUNDLE_NEEDED above already carries
# "the source actually has a CLAUDE.md to install", so a --source that ships none
# (a partial checkout, a custom tree; see lib/hub-domains.sh's hub_domain_exists)
# leaves BUNDLE_NEEDED at 0 and neither this probe nor the APPLY=1 call downstream
# is reached. It used to be gated HERE and only here, which killed the DRY RUN with
# exit 1 and no HUB_STATUS payload before the gate existed — and, once gated,
# quietly left the apply path to die on the same missing file AFTER taking consent.
# CHECKED HERE, BEFORE the preview is ever built or printed — not after, as it
# used to be. A live test session found the previous order backwards: it always
# built and printed the FULL preview (every domain's every selected item) first,
# and only THEN checked whether anything had actually changed — so re-running
# "Install all" on an already-fully-installed target dumped 80 lines that each,
# individually, said something would happen, immediately followed by a message
# saying nothing would. When there is truly nothing to do, there is nothing to
# preview either; go straight to the no-op exit.
if [ "$ATTEMPT_COUNT" -eq 0 ] && [ "$BUNDLE_NEEDED" -eq 0 ]; then
	hi_ok_exit false 'Already up to date. Nothing to do.'
fi

BUNDLE_PREVIEW_BACKUP=""
if [ "$BUNDLE_NEEDED" -eq 1 ]; then
	hub_bundle_install "$FRAMEWORK_ROOT" "$TARGET_DIR" 0 >/dev/null
	BUNDLE_PREVIEW_BACKUP=${HUB_BUNDLE_BACKUP:-}
	# Cleared so a path that never applies cannot report a backup that never
	# happened: HUB_BUNDLE_BACKUP is what the Result screen and HUB_BUNDLE_BACKUP=
	# both read, and only the real APPLY=1 run is entitled to set it.
	HUB_BUNDLE_BACKUP=""
fi

hi_preview

# ---------------------------------------------------------------------------
# Confirm.
#
# --apply IS what gates reaching this prompt on a flag-driven selection, on a TTY
# as much as off one. Without that, `install --domains=x` on a terminal reached
# the SAFE tier (default-Yes), so a bare Enter installed — flatly contradicting
# --apply's own documented "Absent: preview only". The pure interactive walk is
# unaffected: walking the checklists IS the request, and it confirms as before.
# ---------------------------------------------------------------------------
if [ "$OPT_APPLY" -eq 0 ] && [ "$INTERACTIVE_SELECTION" -eq 0 ]; then
	hi_ok_exit false 'Nothing changed. Re-run with --apply to install.'
fi

if ! hub_interactive; then
	break
fi

# The gate's second argument is the PENDING SELECTION size, not the resolved unit
# count: it is only ever used by hub_discard_guard's "Discard N selected items and
# quit?", and that sentence must describe what the user picked. Passing the
# resolved PLAN_UNITS count offered to discard 47 items after a one-domain selection.
HI_GATE=0
hub_confirm_gate safe "$(hi_pending_count)" || HI_GATE=$?
case $HI_GATE in
0) break ;;
2)
	# BACK, not cancel. The pending selection is kept and the checklist that
	# produced it is re-entered (pre-seeded from its own SEL_ file), so `b` here
	# behaves like `b` everywhere else instead of destroying the selection that
	# the sibling `q` on this same screen is explicitly guarded against losing.
	if [ "$INTERACTIVE_SELECTION" -eq 1 ]; then
		HI_STEP=$(hi_last_selection_step)
		continue
	fi
	# A flag-driven selection has no earlier step to return to — there was never a
	# checklist — so `b` can only mean "don't do it".
	hi_ok_exit false 'Cancelled. Nothing changed.'
	;;
3)
	printf 'Cancelled. Nothing changed.\n' >&3
	exit 3
	;;
*)
	hi_ok_exit false 'Cancelled. Nothing changed.'
	;;
esac

done

# ---------------------------------------------------------------------------
# Apply.
#
# ALLOW_DIVERGED=1 for every unit: a preview that promised "N to re-sync" and
# then re-synced none of them would silently contradict its own arithmetic.
# What actually protects a genuinely foreign occupant is hub_symlink_at's own
# unconditional classification, not this flag — ALLOW_DIVERGED only ever governs
# the framework's OWN mismatched symlink.
# ---------------------------------------------------------------------------
RESULT="$HUB_WORK/result.txt"
FOREIGN_BLOCKED="$HUB_WORK/foreign-blocked.txt"
: >"$RESULT"
: >"$FOREIGN_BLOCKED"

if [ "$BUNDLE_NEEDED" -eq 1 ]; then
	BUNDLE_LOG="$HUB_WORK/bundle.tsv"
	hub_bundle_install "$FRAMEWORK_ROOT" "$TARGET_DIR" 1 >"$BUNDLE_LOG"
	while IFS="$HUB_TAB" read -r HI_OUTCOME HI_ITEM; do
		[ -n "$HI_ITEM" ] || continue
		if [ "$HI_OUTCOME" = foreign-blocked ]; then
			printf '%s\n' "$HI_ITEM" >>"$FOREIGN_BLOCKED"
		fi
	done <"$BUNDLE_LOG"
fi

# Reading this table with IFS=TAB is safe against a crafted name for a reason
# stated once, at the gate: a unit NAME cannot contain a TAB, because
# HUB_NAME_CHARSET_RE does not admit one and every name is checked against it as
# it enters the pipeline (lib/hub-discovery.sh). There is no separate TAB
# carve-out anywhere — TAB rejection falls out of the charset, which is why the
# charset is the thing to keep intact. Without it, a name carrying a TAB would
# shift kind/src/display one column each and let the source forge the very fields
# that decide what gets written where. See lib/hub-common.sh's "THE TAB TRAP".
#
# THE GROUP COLUMN IS KEPT, not discarded into `_` as it was: it is what lets the
# Result screen report at the granularity a human reads (see the "Result blocks"
# section for why that grouping cannot come from a post-apply hub_domain_buckets
# call), and this loop is the only place that knows which units this run actually
# wrote. The SRC comes along for the baseline line's lens count, on the same
# reasoning.
while IFS="$HUB_TAB" read -r HI_GROUP HI_NAME HI_KIND HI_SRC HI_DISPLAY; do
	[ -n "$HI_NAME" ] || continue
	HI_OUTCOME=$(hub_symlink_unit "$HI_KIND" "$HI_NAME" "$HI_SRC" "$TARGET_DIR" "$FRAMEWORK_ROOT" 1 1)
	case $HI_OUTCOME in
	foreign-blocked) printf '%s\n' "$HI_NAME" >>"$FOREIGN_BLOCKED" ;;
	# "skip" (already installed, unchanged) is neither acted on nor blocked, so
	# it is excluded from RESULT — that keeps HUB_ACTED_ON_COUNT from ever
	# exceeding the ATTEMPT_COUNT denominator the preview already printed.
	skip) : ;;
	*) printf '%s\t%s\t%s\n' "$HI_GROUP" "$HI_SRC" "$HI_DISPLAY" >>"$RESULT" ;;
	esac
done <"$PLAN_UNITS"

RESULT_COUNT=$(hub_count_lines "$RESULT")
FOREIGN_BLOCKED_COUNT=$(hub_count_lines "$FOREIGN_BLOCKED")

# ---------------------------------------------------------------------------
# Result.
# ---------------------------------------------------------------------------
HI_DOMAINS_CSV=$(tr '\n' ',' <"$SEL_DOMAINS" | sed 's/,$//')
HI_TECH_CSV=$(tr '\n' ',' <"$SEL_TECHNOLOGIES" | sed 's/,$//')
HI_SD_VCS_CSV=$(tr '\n' ',' <"$(hi_sel_file vcs)" | sed 's/,$//')
HI_TRACKERS_CSV=$(tr '\n' ',' <"$SEL_TRACKERS" | sed 's/,$//')

case $OPT_FORMAT in
env)
	hub_env_kv HUB_STATUS ok
	hub_env_kv HUB_ACTION "$HI_ACTION"
	# HUB_APPLIED on the SUCCESS path too, not only on the no-op exits: two
	# HUB_STATUS=ok payloads with different shapes force a caller to guess, and a
	# caller checking HUB_APPLIED after a real install used to get nothing at all.
	hub_env_kv HUB_APPLIED true
	hub_env_kv HUB_DOMAINS "$HI_DOMAINS_CSV"
	hub_env_kv HUB_TECHNOLOGIES "$HI_TECH_CSV"
	hub_env_kv HUB_SD_VCS "$HI_SD_VCS_CSV"
	hub_env_kv HUB_PM_TRACKERS "$HI_TRACKERS_CSV"
	hub_env_kv HUB_ACTED_ON_COUNT "$RESULT_COUNT"
	hub_env_kv HUB_ATTEMPTED_COUNT "$ATTEMPT_COUNT"
	hub_env_kv HUB_BUNDLE_INSTALLED "$([ "$BUNDLE_NEEDED" -eq 1 ] && printf true || printf false)"
	hub_env_kv HUB_BUNDLE_BACKUP "${HUB_BUNDLE_BACKUP:-}"
	hub_emit_itemized_env HUB_FOREIGN_BLOCKED "$FOREIGN_BLOCKED"
	;;
json)
	have jq || die "--format=json requires jq, which is not installed"
	HI_FB_JSON=$(hub_itemized_json_array "$FOREIGN_BLOCKED")
	jq -n --arg action "$HI_ACTION" \
		--arg domains "$HI_DOMAINS_CSV" --arg technologies "$HI_TECH_CSV" \
		--arg sd_vcs "$HI_SD_VCS_CSV" \
		--arg pm_trackers "$HI_TRACKERS_CSV" \
		--arg bundle_backup "${HUB_BUNDLE_BACKUP:-}" \
		--argjson acted_on_count "$RESULT_COUNT" --argjson attempted_count "$ATTEMPT_COUNT" \
		--argjson bundle_installed "$([ "$BUNDLE_NEEDED" -eq 1 ] && printf true || printf false)" \
		--argjson foreign_blocked_count "$FOREIGN_BLOCKED_COUNT" \
		--slurpfile foreign_blocked_items "$HI_FB_JSON" \
		'{status:"ok", action:$action, applied:true,
		  domains:($domains | if . == "" then [] else split(",") end),
		  technologies:($technologies | if . == "" then [] else split(",") end),
		  sd_vcs:($sd_vcs | if . == "" then [] else split(",") end),
		  pm_trackers:($pm_trackers | if . == "" then [] else split(",") end),
		  acted_on_count:$acted_on_count, attempted_count:$attempted_count,
		  bundle_installed:$bundle_installed, bundle_backup:$bundle_backup,
		  foreign_blocked_count:$foreign_blocked_count,
		  foreign_blocked_items:$foreign_blocked_items}'
	;;
text)
	# The Result screen carries the nav hint, as both specs' mockups show, and the
	# pause below actually honours the keys it advertises.
	hub_print_header "$(printf 'Installed %s/%s %s to %s' "$RESULT_COUNT" "$ATTEMPT_COUNT" \
		"$(hub_plural "$ATTEMPT_COUNT" item items)" "$TARGET_DIR")"
	if [ "$BUNDLE_NEEDED" -eq 1 ]; then
		printf '  %s %s and the contract schemas (first run only)\n' "$(hub_glyph_ok)" "$HUB_BUNDLE_CONFIG_NAME"
		if [ -n "${HUB_BUNDLE_BACKUP:-}" ]; then
			printf '  %s your existing %s was preserved as %s\n' \
				"$(hub_glyph_arrow)" "$HUB_BUNDLE_CONFIG_NAME" "${HUB_BUNDLE_BACKUP##*/}"
		fi
	fi

	# SELECTIVE results always itemize; only the bulk --all result summarizes and
	# offers the follow-up prompt (see hub_result_details). Either way, the detail
	# view itself is the domain-grouped one — see the "Result blocks" section.
	hub_result_details "$OPT_DETAILS" "$OPT_ALL"
	if [ "$HUB_SHOW_DETAILS" -eq 1 ]; then
		hi_result_blocks
	fi
	hub_report_foreign_blocked "$FOREIGN_BLOCKED" \
		'skipped — a file that is not framework-owned occupies its target path. Move or remove it, then retry. See "List".'
	printf '\n'
	printf '  %s Run "Doctor" to verify, or "List" to see the updated state.\n' "$(hub_glyph_arrow)"
	if [ "$OPT_ALL" -eq 1 ]; then
		printf '  %s To reverse: choose "Uninstall all".\n' "$(hub_glyph_arrow)"
	else
		printf '  %s To reverse: open "Uninstall" and choose the components you no longer want (or "Uninstall all").\n' "$(hub_glyph_arrow)"
	fi
	if hub_interactive; then
		# `q` at the pause means "quit the hub", which is exit 3 — the same code
		# every other interactive screen uses for it, so the entrypoint's loop can
		# tell it from "this action finished".
		HI_PAUSE=0
		hub_press_key_to_continue || HI_PAUSE=$?
		[ "$HI_PAUSE" -ne 3 ] || exit 3
	fi
	;;
esac

exit 0
