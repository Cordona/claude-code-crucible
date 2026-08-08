#!/usr/bin/env sh
# lib/hub-checklist.sh — THE multi-select checklist widget. One implementation,
#                         used by all four selection screens: domain onboarding,
#                         Software Development's technologies, Project
#                         Management's trackers, and uninstall's flat component
#                         list.
#
# Sourced after lib/hub-common.sh, lib/hub-render.sh and lib/hub-nav.sh. Not
# executable on its own.
#
# DISCLOSED DEVIATION FROM THE SPEC'S MOCKUP HINT LINE — read this before
# comparing against the spec. The mockups render their key legend as
# "(space: toggle · a: select all · type to filter · enter: confirm)", which
# describes a raw-keystroke widget. This implementation is LINE-based (see
# lib/hub-nav.sh's header for the full reasoning): the user types a row number
# or name and presses Enter to toggle it. Everything the mockup PROMISES is
# present — toggling, select-all, filtering, confirm-on-Enter, and the exact
# [x]/[ ]/[!] checkbox rendering — but the legend line is written to describe
# the keys that actually work, because a hint line that names a key the program
# does not implement is worse than a different hint line. This is the one place
# the implementation's on-screen text deliberately differs from a mockup.
#
# THE HUMAN CHANNEL IS stderr, NOT stdout. Every line this widget renders — the
# header, the rows, the "N selected" tally, the `> ` prompt and the "no such row"
# rejection — is human prose, and stdout is the MACHINE channel: under
# `--format=env|json` a caller `eval`s or `jq`s it directly, so a single line of
# prose on stdout breaks the parse. stderr is used rather than the capability
# scripts' own fd 3 for the same reason lib/hub-nav.sh uses it: a lib must not
# depend on its sourcing script having opened a private descriptor, and stderr is
# the one human channel that always exists. Under --format=text both land on the
# same terminal, so nothing a human sees changes.
#
# Portability: POSIX sh only.

# HUB_CHECKLIST_FILTER_THRESHOLD -> the filter hint is worth showing only once a
# list is long enough that scanning it by eye is the harder option. A live test
# session found it printed unconditionally even on a 3-row domain-onboarding
# screen, where "/text: filter" describes a feature nobody would ever reach for.
HUB_CHECKLIST_FILTER_THRESHOLD=9

# HUB_CHECKLIST_MULTISELECT_THRESHOLD -> the same "is this hint worth its space"
# judgement HUB_CHECKLIST_FILTER_THRESHOLD above makes, applied to the
# multi-select hint: naming several rows at once is meaningless on a screen with
# only one row to name, so 1 is the threshold rather than a tuned number. Kept as
# a named constant next to its sibling instead of a bare `-gt 1` in the function,
# so the two gates read as one family.
HUB_CHECKLIST_MULTISELECT_THRESHOLD=1

# HUB_CHECKLIST_MAX_RANGE_BOUND -> the largest row number either end of a "1-5"
# range may name. A fat-fingered "1-999999999" must cost ONE rejection line, not
# a loop nobody asked for and a screenful of near-identical complaints.
#
# 100 because the largest screen this widget renders is Uninstall's flat list —
# one row per installed technology, VCS host and tracker (an orphan is no
# longer one of them — Doctor owns orphan reporting and cleanup now) — which
# tops out around 80 today: the bound clears every real list with headroom for
# the framework to grow, while staying small enough that rejecting an absurd
# range is instant.
#
# BOUNDING THE ENDPOINTS rather than the SPAN is the deliberate choice, and it is
# not just simpler — it is strictly stronger. Both endpoints being <= the bound
# caps the span at the bound automatically, so one rule does both jobs; and it
# lets "1000-1001" be rejected as the nonsense it is (no screen here has a row
# 1000) instead of being expanded into two "no such row" lines. A span-only rule
# would have admitted it.
HUB_CHECKLIST_MAX_RANGE_BOUND=100

# HUB_CHECKLIST_MAX_RANGE_DIGITS -> the widest numeral hub_checklist_expand_token
# will let reach ANY arithmetic or numeric comparison. This is an OVERFLOW-SAFETY
# limit, deliberately independent of HUB_CHECKLIST_MAX_RANGE_BOUND above: the two
# guards answer two different questions, and deriving one from the other made the
# safety of the first depend on the VALUE of the second.
#
# 18 because that is the widest decimal numeral both evaluators handle exactly.
# Verified, not assumed: `[ 999999999999999999 -gt 100 ]` is fine on dash and on
# bash 3.2, while one more digit makes dash abort with `Illegal number` (fatal
# under `set -e`) and bash 3.2 answer `integer expression expected`; and bash 3.2's
# `$(( ))` silently WRAPS past 64 bits — `$((9999999999999999999999999 + 1))`
# quietly returns 1590897978359414784, a wrong number accepted as if it were
# right. 18 digits sits below both cliffs.
#
# THE SEPARATION IS THE POINT. This guard's only job is "is this numeral safe to
# evaluate"; the user-facing verdict "is this row number plausible" belongs to
# HUB_CHECKLIST_MAX_RANGE_BOUND's own check, which runs immediately after it and is
# what rejects an evaluable-but-absurd "1-999999999". Taking this width from
# ${#HUB_CHECKLIST_MAX_RANGE_BOUND} instead — as this guard used to — silently tied
# overflow safety to that constant staying small: raising the bound to a 19-digit
# value would have widened this guard along with it and re-admitted the exact
# wraparound it exists to prevent.
#
# The one coupling that remains, stated so it is not rediscovered the hard way:
# HUB_CHECKLIST_MAX_RANGE_BOUND must ITSELF be a numeral of at most this many
# digits, since it is the right-hand side of that numeric comparison.
HUB_CHECKLIST_MAX_RANGE_DIGITS=18

# hub_checklist_hint_text ROW_COUNT -> the legend line, stated once so all four
# screens agree. A function rather than a constant because the `·` separators
# degrade to `,` under accessible mode (hub_sep_text), and HUB_ASCII is set by
# flag parsing AFTER this file is sourced — a constant would have frozen the
# Unicode form before --accessible was ever seen.
#
# ROW_COUNT is the screen's TOTAL row count (not the currently-filtered-visible
# count): whether filtering is worth advertising is a property of the list's
# full size, not of whatever the user has already typed into the filter.
#
# The toggle clause spells out "select or deselect it" rather than the shorter
# "toggle": a live test session asked how to deselect something after picking it
# by mistake — retyping the same number already does it, but the old wording
# never said so.
#
# PRINTED ON THE PROMPT'S OWN LINE, not a separate line above it — "the > line
# contains the action hint" is the rule a live test session settled on for
# every input point in this hub, not just this one.
#
# EVERY key on this line is a hint key (hub_hint_segment: dim cyan key, dimmed
# label), never hub_key — the whole line is a trailing list of alternatives the
# user could type, which is exactly hub_hint_segment's role and not hub_key's
# (see hub_key's own doc comment for the split). That includes `/text`, whose
# label used to be a single plain "/text: filter" string and so rendered
# undimmed-key/dimmed-label while its own list-mates `a`/`n` did the opposite.
# `/text` is ALSO colored via hub_key on the help screen (lib/hub-nav.sh) — that
# is not a contradiction: there it is read-only reference content, here it is a
# live hint at the prompt that accepts it.
#
# THE MULTI-SELECT CLAUSE IS `1,3-5`, ONE literal token rather than the prose
# "1,3 or 1-5", for two reasons. It is genuinely typeable VERBATIM — typing
# "1,3-5" really does toggle rows 1, 3, 4 and 5 — which is exactly what earns it
# hub_hint_segment's colored-key treatment rather than the plain hub_dim its
# neighbouring toggle clause gets (that clause is descriptive prose; this one is
# an example). And it demonstrates BOTH halves of the syntax, the comma list and
# the range, in the space of one segment: a prose "1,3 or 1-5" would have had to
# color the word "or" as part of the key, advertising something the prompt does
# not accept. It sits immediately after the toggle clause because it elaborates
# on that clause rather than standing alone.
hub_checklist_hint_text() {
	hcht_sep=$(hub_sep_text)
	hcht_hint="$(hub_dim 'number or name to select/deselect')"
	if [ "$1" -gt "$HUB_CHECKLIST_MULTISELECT_THRESHOLD" ]; then
		hcht_hint="${hcht_hint}${hcht_sep}$(hub_hint_segment '1,3-5' multiple)"
	fi
	hcht_hint="${hcht_hint}${hcht_sep}$(hub_hint_segment a all)${hcht_sep}$(hub_hint_segment n none)"
	if [ "$1" -gt "$HUB_CHECKLIST_FILTER_THRESHOLD" ]; then
		hcht_hint="${hcht_hint}${hcht_sep}$(hub_hint_segment '/text' filter)"
	fi
	printf '%s%s%s%s%s' "$hcht_hint" "$hcht_sep" "$(hub_nav_keys_hint)" "$hcht_sep" "$(hub_hint_segment Enter confirm)"
}

# hub_checklist_strip_leading_zeros NUMERAL -> NUMERAL with its leading zeros
# removed, so it is safe to hand to $(( )) and to `[ -gt ]`.
#
# THE OCTAL TRAP, and it is a crash rather than a wrong answer: POSIX $(( ))
# reads a leading-zero numeral as OCTAL and ERRORS OUT on a digit that is not
# octal. `sh -c 'n=08; echo $((n))'` dies with `value too great for base (error
# token is "08")`. A user typing "08-10" is naming rows 8 through 10, not writing
# octal, so both endpoints of a range come through here before any arithmetic
# touches them.
#
# $((10#$n)) — bash's own base-10 override — is deliberately NOT used. It is a
# BASHISM: dash, which is /bin/sh on Debian and Ubuntu, rejects it outright with
# `arithmetic expression: expecting EOF: "10#0"`, and this file is POSIX sh (see
# the header). Stripping the zeros is the portable form, and it was verified
# against dash rather than assumed.
#
# The `0[0-9]*` pattern needs at least TWO characters, and that is what stops the
# loop from eating a legitimate lone zero down to the empty string: "00" becomes
# "0", not "". Verified for "0", "00", "000000", "08", "007", "010" and "0080".
hub_checklist_strip_leading_zeros() {
	hcslz_num=$1
	while :; do
		case $hcslz_num in
		0[0-9]*) hcslz_num=${hcslz_num#0} ;;
		*) break ;;
		esac
	done
	printf '%s' "$hcslz_num"
}

# hub_checklist_expand_token TOKEN -> the row tokens TOKEN names, one per line,
# on stdout. A numeric RANGE expands; everything else passes through untouched.
#
# This exists so range support costs the toggle loop NOTHING. "1-5" becomes the
# five lines 1 2 3 4 5, each of which the caller's per-token loop then resolves
# and toggles by exactly the path a bare number the user typed already took —
# there is no second copy of the lookup, the existence check or the
# toggle-add/toggle-remove decision, and there is no new way for a row to be
# selected. A range is purely an input spelling.
#
# WHY A RANGE CANNOT COLLIDE WITH A ROW KEY. Both sides must be pure digits, and
# the keys this hub renders are semantic names — "software-development",
# "github-tracker", "python", "tests-developer" — where a hyphen always has a
# letter on at least one side, so the digit test fails and the key falls through
# to the by-name lookup unchanged.
#
# THIS USED TO HAVE ONE DISCLOSED EXCEPTION: Uninstall's orphan row, whose key
# was a dangling symlink's basename and so was whatever a filesystem happened
# to hold — a symlink literally named "1-2" would have been shadowed. Orphans
# are no longer offered on Uninstall's interactive checklist at all (Doctor
# owns orphan reporting and cleanup now — see hub-doctor.sh), so every row key
# this widget renders, on every one of its four call sites, is drawn from the
# semantic vocabulary above; there is no longer a non-digit-safe key anywhere
# in this widget's own input. Stated for whichever future caller adds a fifth
# one: a row key sourced from outside this hub's own naming (raw filesystem
# names, again, or anything else not guaranteed hyphen-with-a-letter) would
# reopen the same hazard and would need the same disclosure this paragraph
# used to carry.
#
# A REVERSED range ("5-1") is read as 1-5 rather than rejected. The user has
# unambiguously named two endpoints, the order they typed them in carries no
# other meaning here, and of the three candidate behaviours — swap, error,
# silently do nothing — only silence teaches them nothing, and an error would be
# pedantry about a typo whose intent is obvious.
hub_checklist_next_field() {
	case $hcl_rest in
	*"$HUB_TAB"*)
		hcl_field=${hcl_rest%%"$HUB_TAB"*}
		hcl_rest=${hcl_rest#*"$HUB_TAB"}
		;;
	*)
		# NO tab left in hcl_rest: parameter expansion's own "no match, string
		# unchanged" rule is the trap here. `${hcl_rest#*TAB}` on a tab-less
		# hcl_rest returns hcl_rest ITSELF, not "" — so naively chaining `%%`/`#`
		# extractions across a row with fewer tabs than expected columns would
		# freeze hcl_rest at whatever survived the last real cut, and every
		# field read after that point would silently repeat it instead of
		# degrading to empty. This branch is what makes a short/malformed row
		# read as "this field, then nothing" rather than "this field, then a
		# duplicate of it, forever".
		hcl_field=$hcl_rest
		hcl_rest=""
		;;
	esac
}

hub_checklist_expand_token() {
	hcet_token=$1
	hcet_start=${hcet_token%%-*}
	hcet_end=${hcet_token##*-}

	# THE SHAPE TEST for `^[0-9]+-[0-9]+$`, in a language with no regex and no `+`
	# in its patterns. Reconstructing the token from its two halves is what makes
	# it airtight: it matches only when there was exactly ONE hyphen (a second
	# leaves "1-3" != "1-2-3") with something on both sides, and the two digit
	# tests below then reject anything that is not a pure numeral. Between them,
	# "software-development" (halves are words), "1-2-3", "-5", "5-" and a bare
	# "-" all fall through as literal tokens for the by-name lookup to reject with
	# its own "no such row" line, which is the right message for each of them.
	if [ "$hcet_token" != "${hcet_start}-${hcet_end}" ]; then
		printf '%s\n' "$hcet_token"
		return 0
	fi
	case $hcet_start in
	'' | *[!0-9]*)
		printf '%s\n' "$hcet_token"
		return 0
		;;
	esac
	case $hcet_end in
	'' | *[!0-9]*)
		printf '%s\n' "$hcet_token"
		return 0
		;;
	esac

	# Leading zeros come off BEFORE anything numeric reads these — see
	# hub_checklist_strip_leading_zeros for the crash this prevents. It also makes
	# the length guard below exact, since a stripped numeral's digit count is its
	# true magnitude.
	hcet_start=$(hub_checklist_strip_leading_zeros "$hcet_start")
	hcet_end=$(hub_checklist_strip_leading_zeros "$hcet_end")

	# THE LENGTH GUARD RUNS FIRST, and it is not redundant with the numeric bound
	# check below it — it is what makes that check safe to perform at all. An
	# over-long numeral breaks BOTH of the tools used to evaluate it, and one of
	# them fails silently: `[ 1 -gt 999999999999999999999999 ]` aborts with
	# "integer expression expected" on bash and "Illegal number" on dash (fatal
	# under `set -e`), while `$((999999999999999999999999 - 1))` on bash 3.2
	# quietly WRAPS and answers 2003764205206896639 — a wrong number, accepted as
	# if it were right. Comparing DIGIT COUNTS is pure string work and cannot
	# overflow, which is why it has to come first.
	#
	# It is measured against HUB_CHECKLIST_MAX_RANGE_DIGITS, NOT against
	# ${#HUB_CHECKLIST_MAX_RANGE_BOUND} — see that constant's own comment for why
	# the two are deliberately decoupled. Both endpoints surviving this test are
	# provably evaluable, which is what makes the numeric bound check on the next
	# lines (and the arithmetic further down) safe; that numeric check, not this
	# one, is what decides whether an evaluable number is a plausible ROW number.
	if [ "${#hcet_start}" -gt "$HUB_CHECKLIST_MAX_RANGE_DIGITS" ] ||
		[ "${#hcet_end}" -gt "$HUB_CHECKLIST_MAX_RANGE_DIGITS" ] ||
		[ "$hcet_start" -gt "$HUB_CHECKLIST_MAX_RANGE_BOUND" ] ||
		[ "$hcet_end" -gt "$HUB_CHECKLIST_MAX_RANGE_BOUND" ]; then
		# ONE line for the whole range, not one per number: the guard fires before
		# the expansion loop, so an absurd range never becomes output at all.
		printf '  no such row range: %s (each end must be %s or less)\n' \
			"$hcet_token" "$HUB_CHECKLIST_MAX_RANGE_BOUND" >&2
		return 0
	fi

	# The swap is safe only below the length guard, since it compares numerically.
	if [ "$hcet_start" -gt "$hcet_end" ]; then
		hcet_swap=$hcet_start
		hcet_start=$hcet_end
		hcet_end=$hcet_swap
	fi

	while [ "$hcet_start" -le "$hcet_end" ]; do
		printf '%s\n' "$hcet_start"
		# An ASSIGNMENT, never a bare `(( hcet_start++ ))`: an arithmetic COMMAND
		# whose result is 0 returns exit status 1 and would trip `set -eu`. The
		# assignment form always succeeds. (`(( ))` is also not POSIX.)
		hcet_start=$((hcet_start + 1))
	done
}

# hub_checklist TITLE SUBTITLE ROWSFILE OUTFILE [GROUPED] -> render an
# interactive checklist and write the selected row keys, one per line, to
# OUTFILE.
#
# SUBTITLE is an optional second line under the title (the onboarding screen's
# "Which domain(s) do you want to install?"); pass an empty string for none. It is
# a separate argument rather than embedded newlines in TITLE because the two lines
# are RENDERED DIFFERENTLY — see the render loop below: the title goes through
# hub_print_header and the subtitle is the actual question being asked, printed at
# full brightness on its own line. One string could not carry two treatments.
# (This used to claim the split existed because the header measured TITLE's width
# to right-align a nav hint. It no longer measures anything — that hint moved onto
# each screen's own prompt line.)
#
# GROUPED is OPTIONAL, defaults to 0 (ungrouped — the ORIGINAL, unchanged shape,
# and every existing call site before Uninstall's flat list omits it and is
# untouched by anything below). Pass 1 to render:
#   * a plain, un-numbered, un-selectable DOMAIN HEADING at the 2-space indent
#     (matching hub-list.sh's own domain sub-headers), preceded by a blank line
#     unless it is the very first heading on screen, before the first row of
#     every run of consecutive rows that share a GROUP value;
#   * optionally, a second, narrower SUBGROUP heading at the 4-space indent —
#     one level deeper than its domain heading — preceded by a blank line
#     unless it is the first subgroup of its domain, before a run of rows that
#     share a SUBGROUP within that domain (Software Development: Technologies,
#     then VCS).
# Uninstall's own reason for wanting either level at all: its checklist mixes
# rows from every domain on one screen, and with two selectable kinds now
# sharing a key vocabulary (github/gitlab, both a VCS choice and a tracker
# choice) an ungrouped flat list reads as one undifferentiated block.
# Numbering STAYS CONTINUOUS across BOTH heading levels (neither consumes a
# number and neither is ever a toggle target) — the same "heading is
# presentation only" rule hub-list.sh's own domain sub-headers follow.
#
# EVERY ROW NESTS ONE LEVEL DEEPER THAN THE HEADING DIRECTLY OVER IT, never
# level with it: a row with no subgroup sits at 4-space (one level under its
# domain heading's 2-space); a row WITH a subgroup sits at 6-space (one level
# under that subgroup's own 4-space), not sharing the subgroup's depth. A row
# is told apart from a heading by depth first, and only secondarily by having
# a checkbox/number a heading never has.
#
# ROWSFILE columns, GROUPED=0 (default):
#   key<TAB>label<TAB>diverged<TAB>annotation
# ROWSFILE columns, GROUPED=1:
#   key<TAB>label<TAB>diverged<TAB>group<TAB>subgroup<TAB>annotation
#   key         the token written to OUTFILE and accepted as typed input; also
#               the flag token the non-interactive path uses, so the human and
#               the agent name the same thing (the parity requirement).
#   label       the human-facing display name. On a GROUPED=1 screen this
#               should be the BARE label (no domain qualification): the
#               heading now supplies the context a heading-less screen's own
#               qualified form existed to substitute for — see
#               lib/hub-domains.sh's hub_selection_kind_needs_domain.
#   diverged    1 when this row is installed-but-diverged, so a SELECTED row
#               renders [!] (re-syncs on install) rather than [x].
#   group       GROUPED=1 ONLY. The domain heading text. NEVER empty when
#               GROUPED=1 is passed — every real row has a real group by
#               construction on the one screen that uses this (a flat
#               component list only ever mixes DOMAINS, and every domain has
#               a label) — an always-empty column would defeat its own
#               purpose, and an ever-changing one is what drives the heading
#               to print.
#   subgroup    GROUPED=1 ONLY. The narrower heading text, or EMPTY for a
#               domain with only one selection kind (Project Management,
#               GTD) — genuinely empty is fine here, unlike group: this
#               column is read by PARAMETER EXPANSION (see the render loop),
#               never by `read`'s IFS-splitting, so it carries none of the
#               concentration THE TAB TRAP warns about elsewhere in this hub.
#   annotation  optional trailing text shown after the label (a blurb, a state).
#
# WHY AN EMPTY MIDDLE COLUMN IS SAFE HERE, WHEN lib/hub-common.sh's "THE TAB
# TRAP" SAYS IT SHOULDN'T BE: that trap is specifically about `read` with
# IFS=TAB, which treats a run of tabs as ONE delimiter and silently shifts
# every field after an empty one. This function's GROUPED=1 parsing never uses
# `read` for the per-column split — it reads the WHOLE raw line with `read`
# (a single field, nothing to collapse) and then splits it with parameter
# expansion (`${var%%pat*}` / `${var#*pat}`), which never merges delimiters
# and never treats an empty field as anything but itself. That is what makes
# `subgroup` safe to leave empty while `annotation`, further right, is ALSO
# sometimes empty on the very same row — a shape the TAB TRAP's own `read`
# based tables cannot express safely, and this table does not use `read` to
# read it.
#
# Exit status:
#   0  confirmed — OUTFILE holds the selection (possibly empty; the CALLER owns
#      the "empty selection" policy, because it differs per screen: onboarding
#      treats it as "nothing to do", a domain sub-selection blocks inline)
#   1  the user went back one level (b)
#   2  the user quit the hub (q), having passed the discard guard if a
#      non-empty selection was pending
hub_checklist() {
	hcl_title=$1
	hcl_subtitle=$2
	hcl_rows=$3
	hcl_out=$4
	hcl_grouped=${5:-0}

	hcl_scratch=$(hub_mktemp_dir)
	hcl_selected="$hcl_scratch/selected.txt"
	: >"$hcl_selected"
	hcl_filter=""

	# PRE-SEED from OUTFILE when it already holds a selection. This is what makes
	# `b` genuinely non-destructive: going back one level and returning must show
	# the choices the user already made, not a blank screen that silently threw
	# them away. Keys no longer present in ROWSFILE are dropped rather than
	# carried as ghosts — the row set can legitimately differ between visits (a
	# technology that just became installed, say).
	if [ -s "$hcl_out" ]; then
		while IFS= read -r hcl_seed; do
			[ -n "$hcl_seed" ] || continue
			if [ -n "$(hcl_seed="$hcl_seed" awk -F '\t' '$1 == ENVIRON["hcl_seed"] { print 1; exit }' "$hcl_rows")" ]; then
				printf '%s\n' "$hcl_seed" >>"$hcl_selected"
			fi
		done <"$hcl_out"
	fi

	# The label column's width comes from the ACTUAL rows every time the screen
	# renders, never a hardcoded literal: a hardcoded width misaligns the moment
	# a label is longer than it, and an annotation then runs into its own label.
	hcl_width=$(hub_name_column_width 2 "$hcl_rows")
	hcl_total_rows=$(hub_count_lines "$hcl_rows")

	while :; do
		# One brace group, not a subshell: hcl_n / hcl_visible / hcl_numbered are
		# set inside it and every later stage of this loop reads them. The nested
		# `>>"$hcl_numbered"` redirect below still wins over the group's own >&2,
		# so the numbering file is written normally.
		{
		printf '\n'
		hub_print_header "$hcl_title"
		# SUBTITLE is the actual question being asked ("Which domain(s) do you
		# want to install?"), not a secondary hint — full brightness, matching
		# the title above it, not dimmed the way a hint line is.
		if [ -n "$hcl_subtitle" ]; then
			printf '%s\n' "$hcl_subtitle"
		fi
		if [ -n "$hcl_filter" ]; then
			hub_print_hint "filter: \"$hcl_filter\" (type / alone to clear)"
		fi
		printf '\n'

		# The numbering shown to the user is rebuilt on every render and covers
		# only the rows currently VISIBLE under the filter, so "3" always means
		# the third row the user can actually see. The mapping is written to a
		# file rather than kept in a variable because the render loop below
		# reads from a redirected file and its own numbering must survive it.
		hcl_numbered="$hcl_scratch/numbered.tsv"
		: >"$hcl_numbered"
		hcl_n=0
		hcl_visible=0
		# hcl_prev_group starts at a value no real GROUP can ever equal (a group is
		# always non-empty when hcl_grouped=1 — see this function's own header), so
		# the FIRST visible row of a grouped render always prints its heading rather
		# than needing a separate "is this the first row" flag.
		hcl_prev_group=""
		hcl_prev_subgroup=""
		while IFS= read -r hcl_rawline; do
			[ -n "$hcl_rawline" ] || continue
			# MANUAL FIELD SPLITTING, never `read ... <field vars>`: `read`'s IFS-TAB
			# splitting collapses CONSECUTIVE tabs (THE TAB TRAP — see
			# lib/hub-common.sh), and grouped rows legitimately have an EMPTY
			# annotation followed by a non-empty trailing field in ungrouped rows'
			# old position — exactly the interior-empty-field shape that trap warns
			# about. hub_checklist_next_field (above) never collapses anything AND
			# degrades a short/malformed row's missing trailing fields to empty
			# rather than duplicating the last one it did find — see that
			# function's own comment for the parameter-expansion trap this avoids.
			hcl_rest=$hcl_rawline
			hub_checklist_next_field
			hcl_key=$hcl_field
			hub_checklist_next_field
			hcl_label=$hcl_field
			hub_checklist_next_field
			hcl_div=$hcl_field
			if [ "$hcl_grouped" -eq 1 ]; then
				hub_checklist_next_field
				hcl_group=$hcl_field
				hub_checklist_next_field
				hcl_subgroup=$hcl_field
				hub_checklist_next_field
				hcl_note=$hcl_field
			else
				hcl_group=""
				hcl_subgroup=""
				hub_checklist_next_field
				hcl_note=$hcl_field
			fi
			[ -n "$hcl_key" ] || continue
			if [ -n "$hcl_filter" ]; then
				case $hcl_label in
				*"$hcl_filter"*) : ;;
				*)
					case $hcl_key in
					*"$hcl_filter"*) : ;;
					*) continue ;;
					esac
					;;
				esac
			fi
			# THE HEADING, printed once per run of consecutive VISIBLE rows sharing
			# a group — never for an ungrouped call (hcl_group is always "" there,
			# so it never changes and this branch never fires), and never counted
			# as a row: it consumes no number and is never a toggle target.
			if [ "$hcl_grouped" -eq 1 ] && [ "$hcl_group" != "$hcl_prev_group" ]; then
				[ -z "$hcl_prev_group" ] || printf '\n'
				printf '  %s\n' "$hcl_group"
				hcl_prev_group=$hcl_group
				hcl_prev_subgroup=""
			fi
			if [ "$hcl_grouped" -eq 1 ] && [ -n "$hcl_subgroup" ] && [ "$hcl_subgroup" != "$hcl_prev_subgroup" ]; then
				[ -z "$hcl_prev_subgroup" ] || printf '\n'
				printf '    %s\n' "$hcl_subgroup"
				hcl_prev_subgroup=$hcl_subgroup
			fi
			hcl_n=$((hcl_n + 1))
			hcl_visible=$((hcl_visible + 1))
			printf '%s\t%s\n' "$hcl_n" "$hcl_key" >>"$hcl_numbered"

			if grep -qxF -- "$hcl_key" "$hcl_selected"; then
				if [ "$hcl_div" = 1 ]; then
					hcl_box="[$(hub_glyph_warn)]"
				else
					# Blue, matching hub_glyph_new's "+"/"will be added" meaning
					# everywhere else in this hub, rather than green ("✓"/success) —
					# a checked box here is a PENDING selection, not yet installed.
					hcl_box="[$(hub_c "$HUB_NEW_COLOR" x)]"
				fi
			else
				hcl_box='[ ]'
			fi
			# The label is padded to the column width ONLY when there is an
			# annotation to align after it. Padding a row with no annotation
			# would emit trailing whitespace to the terminal for no visual
			# benefit at all.
			hcl_shown=$(hub_truncate_name "$hcl_label" "$hcl_width")
			# The row number is cyan and "N." — the same numbered-choice treatment
			# the Main menu and Accounts submenu use, applied here too so a live
			# test session's own consistency ask ("cyan 1. in some places, plain
			# 1) in others") stops being true. One fix, here, covers all four
			# checklist screens this widget renders.
			hcl_numstr=$(hub_number "$(printf '%2s.' "$hcl_n")")
			# ONE INDENT LEVEL DEEPER THAN WHATEVER HEADING THIS ROW SITS UNDER: a
			# row with no subgroup nests one level under its domain heading
			# (4-space — the domain's own 2-space plus one level); a row WITH a
			# subgroup nests one level under THAT instead (6-space) rather than
			# sharing its depth — a row is never visually equal to the heading
			# that introduces it.
			hcl_row_indent='  '
			if [ "$hcl_grouped" -eq 1 ]; then
				hcl_row_indent='    '
				[ -z "$hcl_subgroup" ] || hcl_row_indent='      '
			fi
			if [ -n "$hcl_note" ]; then
				printf '%s%s %s %s %s\n' "$hcl_row_indent" "$hcl_box" "$hcl_numstr" \
					"$(hub_pad_right "$hcl_shown" "$hcl_width")" "$hcl_note"
			else
				printf '%s%s %s %s\n' "$hcl_row_indent" "$hcl_box" "$hcl_numstr" "$hcl_shown"
			fi
		done <"$hcl_rows"

		if [ "$hcl_visible" -eq 0 ]; then
			printf '  (nothing matches the current filter)\n'
		fi

		hcl_count=$(hub_count_lines "$hcl_selected")
		printf '\n  %s selected\n\n' "$hcl_count"
		printf '%s\n> ' "$(hub_checklist_hint_text "$hcl_total_rows")"
		} >&2

		IFS= read -r hcl_reply || hcl_reply=q

		case $hcl_reply in
		'')
			cat "$hcl_selected" >"$hcl_out"
			return 0
			;;
		a | all)
			awk -F '\t' '{ print $2 }' "$hcl_numbered" >>"$hcl_selected"
			hub_dedup_first_field "$hcl_selected"
			continue
			;;
		n | none)
			: >"$hcl_selected"
			continue
			;;
		b | back)
			return 1
			;;
		q | quit)
			hcl_count=$(hub_count_lines "$hcl_selected")
			if [ "$hcl_count" -gt 0 ]; then
				hub_discard_guard "$hcl_count" || continue
			fi
			return 2
			;;
		'?')
			hub_show_help
			continue
			;;
		/)
			hcl_filter=""
			continue
			;;
		/*)
			hcl_filter=${hcl_reply#/}
			continue
			;;
		esac

		# Anything else is a toggle list: comma- or space-separated row numbers,
		# numeric ranges and/or row keys, so "1,3", "1-5", "python,react",
		# "1 react" and "1-3,7,9-10" all work.
		hcl_split="$hcl_scratch/split.txt"
		hcl_expanded="$hcl_scratch/expanded.txt"
		hcl_tokens="$hcl_scratch/tokens.txt"
		# Two tr stages rather than one `tr ', ' '\n\n'`: the single-stage form
		# is correct but its duplicated replacement character reads like the
		# classic "tr replaces sets, not words" mistake (SC2020), and splitting
		# it removes the ambiguity for the next reader at the cost of one fork.
		printf '%s\n' "$hcl_reply" | tr ',' '\n' | tr ' ' '\n' | grep -v '^$' >"$hcl_split" || :
		# RANGES ARE EXPANDED IN THEIR OWN PASS, ahead of the toggle loop, so that
		# loop stays the single place a token is resolved and toggled — "1-5"
		# arrives there as five ordinary numbers and is indistinguishable from
		# "1 2 3 4 5" typed by hand. Doing it inline would have meant a second copy
		# of the lookup and toggle logic for the expanded numbers to run through.
		: >"$hcl_expanded"
		while IFS= read -r hcl_raw; do
			[ -n "$hcl_raw" ] || continue
			hub_checklist_expand_token "$hcl_raw" >>"$hcl_expanded"
		done <"$hcl_split"
		# THEN DE-DUPLICATED, and this is a correctness fix, not tidiness. The
		# toggle loop below TOGGLES, so a row named twice in one reply toggles twice
		# and lands back where it started — silently, with no error, because each
		# individual toggle was legitimate. Overlapping ranges make that trivial to
		# hit now that ranges exist: against a 1-5 selection, "4-8" expanded to
		# 4 5 6 7 8 with 4 and 5 already selected used to DESELECT 4 and 5 and net
		# 1,2,3,6,7,8, when the user plainly asked to select 4 through 8; "1-5,3-7"
		# expanded to a stream naming 3, 4 and 5 twice each and netted only 1,2,6,7.
		# Collapsing the stream to one entry per token makes the reply's meaning
		# "these rows, toggled once each", which is what both examples read as.
		#
		# A hand-typed "3,3" now toggles row 3 once rather than twice. That is a
		# deliberate consequence, not a regression: the second "3" never carried
		# information, and toggle-then-untoggle was never what anyone typing it
		# meant.
		#
		# NOT deduplicated: the same row named once by NUMBER and once by KEY in one
		# reply ("1,python" where row 1 IS python) still toggles twice and cancels,
		# because dedup happens on the token text and those are two different
		# strings. Left as-is, disclosed rather than guarded: it needs the user to
		# name one row two different ways in one breath, and closing it means
		# resolving every token to its key before toggling any of them — a second
		# resolution pass, one extra `grep` fork per token, for a case that the
		# range spellings above do not make any easier to reach.
		awk '!seen[$0]++' "$hcl_expanded" >"$hcl_tokens"
		while IFS= read -r hcl_token; do
			[ -n "$hcl_token" ] || continue
			case $hcl_token in
			*[!0-9]*) hcl_target=$hcl_token ;;
			*)
				hcl_target=$(hcl_token="$hcl_token" awk -F '\t' \
					'$1 == ENVIRON["hcl_token"] { print $2; exit }' "$hcl_numbered")
				;;
			esac
			# Existence is checked with awk against column 1, never with a
			# tab-bearing grep pattern: `$(printf '%s\t' ...)` would have its
			# trailing tab stripped by command substitution, silently turning an
			# exact-key test into a prefix test.
			hcl_known=$(hcl_target="$hcl_target" awk -F '\t' \
				'$1 == ENVIRON["hcl_target"] { print 1; exit }' "$hcl_rows")
			if [ -z "$hcl_target" ] || [ -z "$hcl_known" ]; then
				printf '  no such row: %s\n' "$hcl_token" >&2
				continue
			fi
			if grep -qxF -- "$hcl_target" "$hcl_selected"; then
				hub_remove_line "$hcl_selected" "$hcl_target"
			else
				printf '%s\n' "$hcl_target" >>"$hcl_selected"
			fi
		done <"$hcl_tokens"
	done
}
