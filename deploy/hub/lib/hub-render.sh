#!/usr/bin/env sh
# lib/hub-render.sh — the glyph/color legend and the shared screen furniture
#                      every mockup uses: the nav-hint header, the [DRY RUN]
#                      marker, and the confirmation-tier prompt strings.
#
# Sourced after lib/hub-common.sh (uses hub_color_enabled). Not executable on
# its own. This file IS the UI spec's "Glyph & color legend" and "Navigation &
# help" subsections, realized — carried forward unchanged in substance from the
# previous hub, because the legend itself did not change with the domain model.
#
# Portability: POSIX sh only.

# hub_c CODE TEXT -> TEXT wrapped in ANSI color CODE when hub_color_enabled,
# else TEXT unchanged. CODE is a bare SGR parameter (e.g. "32" for green).
hub_c() {
	if hub_color_enabled; then
		printf '\033[%sm%s\033[0m' "$1" "$2"
	else
		printf '%s' "$2"
	fi
}

# HUB_ASCII — accessible mode: 1 means render the ASCII fallback for every
# non-ASCII character this hub prints AS A SYMBOL — every glyph (✓ ✗ →), every
# separator (·) and the truncation ellipsis (…). Set by --accessible (see
# lib/hub-common.sh's hub_try_common_opt) and OPT-IN ONLY — deliberately never
# auto-detected from the locale, per the spec's own constraint.
#
# EXPLICITLY OUT OF SCOPE, and stated here so the flag's own help text can say
# so accurately: the em-dash (—) inside free PROSE message text. An em-dash
# there is punctuation, not a symbol carrying meaning the way a glyph does; it
# reads correctly in any UTF-8 terminal, and rewriting every sentence in the hub
# to avoid it would change the message text itself rather than its rendering.
#
# Colour and accessible mode are independent axes: --no-color strips ANSI
# attributes but keeps the glyphs, --accessible swaps the glyphs but keeps
# colour. A terminal that needs both passes both.
HUB_ASCII=${HUB_ASCII:-0}

# hub_glyph GLYPH ASCII COLOR -> the coloured Unicode glyph, or its ASCII
# fallback under accessible mode. One helper, so a glyph can never be added with
# a fallback that no call site actually reaches — the previous shape kept the
# fallbacks in separate hub_glyph_*_ascii functions that nothing ever called.
hub_glyph() {
	if [ "$HUB_ASCII" = 1 ]; then
		hub_c "$3" "$2"
	else
		hub_c "$3" "$1"
	fi
}

# hub_arrow_text / hub_sep_text -> the arrow and the list separator as PLAIN,
# UNCOLOURED text, honouring accessible mode.
#
# THE ONE REMAINING REASON a text-only arrow exists: hub-doctor.sh's next-step
# lines are emitted VERBATIM as machine payload under --format=env/json
# (HUB_STEP_N_NAME / steps[]), and an embedded ANSI escape would corrupt the value
# a caller parses. (The other reason this comment used to give — that
# hub_print_header MEASURES a string's printed width, which an ANSI-wrapped copy
# would not give — no longer exists: the header measures nothing since the
# right-aligned nav hint moved onto each screen's own prompt line, and the
# hub_nav_hint_text it pointed at was deleted with it.)
#
# Anything rendering to a human-only surface should prefer hub_glyph_arrow.
hub_arrow_text() {
	if [ "$HUB_ASCII" = 1 ]; then
		printf '%s' '->'
	else
		printf '%s' '→'
	fi
}

# hub_sep_text -> the inline list separator INCLUDING its own surrounding
# spacing: " · " normally, ", " under accessible mode. The spacing belongs to the
# separator rather than to each call site precisely because it DIFFERS between
# the two forms — a bare "·"/"," swapped inside a fixed " %s " template renders
# as "back , quit" in accessible mode. Every hint line and every "a · b" pair in
# the hub composes with this one value.
hub_sep_text() {
	if [ "$HUB_ASCII" = 1 ]; then
		printf '%s' ', '
	else
		printf '%s' ' · '
	fi
}

# Only ✓, ✗, ○ and → are genuinely non-ASCII; !, +, and - already are ASCII and
# pass through both modes unchanged. hub_glyph_arrow is built ON hub_arrow_text
# rather than repeating the fallback, so the two can never disagree about what
# the arrow degrades to.
#
# Every glyph below takes its color from a named HUB_*_COLOR constant declared
# immediately above it, never from a bare SGR literal passed inline — the exact
# rule HUB_KEY_COLOR/hub_key state for keys further down, applied to every
# colored element in this hub rather than to keys alone.

# HUB_OK_COLOR — the one place that decides what "success / installed" looks
# like: hub_glyph_ok's own ✓, and through hub_glyph_for_state every `installed`
# row List prints.
HUB_OK_COLOR=32
hub_glyph_ok() { hub_glyph '✓' '[ok]' "$HUB_OK_COLOR"; } # green — success / installed

# HUB_FAIL_COLOR — "a genuine failure occurred": hub_glyph_fail's ✗, the ORPHANED
# listing state, and hub_report_foreign_blocked's refusal lines. Deliberately its
# OWN constant rather than sharing HUB_CRITICAL_COLOR (or HUB_REMOVE_COLOR), for
# the reason HUB_CRITICAL_COLOR's own comment gives from the other side: the
# three happen to share a numeric SGR code today, but a failure, a critical-tier
# warning and a pending removal are different concepts, and collapsing them onto
# one constant would make "make critical redder than failure" require splitting
# them back apart anyway.
HUB_FAIL_COLOR=31
hub_glyph_fail() { hub_glyph '✗' '[fail]' "$HUB_FAIL_COLOR"; } # red — genuine failure

# HUB_ARROW_COLOR — the informational arrow (hub_glyph_arrow). Its own constant
# beside HUB_SAFE_COLOR and HUB_NUMBER_COLOR, which are also 36: "here is where
# this leads", "this tier is safe to confirm" and "this is a number you may type"
# are three unrelated meanings, so each stays independently recolorable.
HUB_ARROW_COLOR=36
hub_glyph_arrow() { hub_c "$HUB_ARROW_COLOR" "$(hub_arrow_text)"; } # cyan — informational

# HUB_WARN_COLOR — "warning / diverged / will-be-re-synced": hub_glyph_warn's !,
# and the DIVERGED listing state through hub_glyph_for_state. The one 256-color
# value in the legend, which is the strongest case in the file for a name — a
# bare '38;5;208' at the call site reads as noise rather than as orange. Quoted
# because unquoted, the semicolons would end the assignment early:
# HUB_WARN_COLOR would silently become 38, and 5/208 would run as commands.
HUB_WARN_COLOR='38;5;208'
hub_glyph_warn() { hub_c "$HUB_WARN_COLOR" '!'; } # orange — warning / diverged / will-be-re-synced

# HUB_ABSENT_COLOR — "not installed" (an absence, not a failure): hub_glyph_absent's
# ○. Its own constant rather than sharing HUB_DANGER_COLOR below, which is also
# 33 — same reasoning as HUB_FAIL_COLOR vs HUB_CRITICAL_COLOR: "nothing is here
# yet" and "this needs a deliberate yes" are unrelated meanings that merely
# collide on one number today, and a change to either must not move the other.
HUB_ABSENT_COLOR=33
hub_glyph_absent() { hub_glyph '○' '(-)' "$HUB_ABSENT_COLOR"; } # yellow — not installed

# HUB_NEW_COLOR — the one place that decides what "new / will-be-added" looks
# like, shared by hub_glyph_new's own `+` AND lib/hub-checklist.sh's `[x]`
# selected-box glyph (a pending selection is exactly this same meaning, not
# success — see that call site's own comment). Before this constant existed,
# the checklist hand-wrote its OWN copy of "34" — the exact kind of silent
# drift a live test session's "change the color in one place only" rule exists
# to prevent.
HUB_NEW_COLOR=34
hub_glyph_new() { hub_c "$HUB_NEW_COLOR" '+'; } # blue — new / will-be-added

# HUB_REMOVE_COLOR — "will be removed" (hub_glyph_remove's -), the exact
# counterpart to HUB_NEW_COLOR's +, and so its own constant for the same reason
# HUB_NEW_COLOR is one. The third name on 31, kept separate from HUB_FAIL_COLOR
# and HUB_CRITICAL_COLOR because a pending removal is neither a failure nor a
# critical-tier warning: recoloring any one of the three must not silently
# recolor the other two.
HUB_REMOVE_COLOR=31
hub_glyph_remove() { hub_c "$HUB_REMOVE_COLOR" '-'; } # red — will-be-removed

# HUB_SAFE_COLOR — the "safe" confirmation tier's color (hub_confirm_prompt). Its
# own constant beside the two tiers below rather than a bare `hub_c 36` inline,
# which is what it used to be: the sibling `dangerous)` arm one line down already
# read HUB_DANGER_COLOR, so the two halves of one three-tier ladder were colored by
# two different mechanisms and only one of them could be changed in one place.
HUB_SAFE_COLOR=36

# HUB_DANGER_COLOR — the "dangerous" confirmation tier's color (hub_confirm_prompt)
# AND hub_discard_guard's [y/N] prompt (lib/hub-nav.sh) — both are the same
# "this needs a deliberate yes" concept, so both read this one constant.
HUB_DANGER_COLOR=33

# HUB_CRITICAL_COLOR — the one critical-tier flow's (uninstall-all) own warning
# text, in hub-uninstall.sh. Deliberately its OWN constant rather than reusing
# hub_glyph_fail's HUB_FAIL_COLOR: the two happen to share a numeric SGR code
# today, but "a genuine failure occurred" and "this critical action needs a harder
# warning than the dangerous tier" are different concepts, and forcing them onto
# one constant would make a future "make critical redder than failure" ask require
# splitting them back apart anyway.
# shellcheck disable=SC2034  # consumed cross-file by hub-uninstall.sh
HUB_CRITICAL_COLOR=31

# HUB_DIM_COLOR — SGR 2 (faint), the treatment for every secondary line this hub
# prints, funnelled through hub_dim and hub_print_hint. The only entry in the
# legend that is an attribute rather than a hue, and it gets a name for the same
# one-place-to-change-it reason as the rest: "make secondary text lighter" (say,
# a switch to an explicit grey) stays a one-line change here.
HUB_DIM_COLOR=2

# hub_dim TEXT -> TEXT dimmed (nav hints, help screen, shortcuts).
hub_dim() { hub_c "$HUB_DIM_COLOR" "$1"; }

# HUB_KEY_COLOR — the ONE place that decides what a literal key/token the user
# may type looks like (bold cyan). Every call site colors a key via hub_key
# below, never by hand-writing its own `hub_c` code — a live test session asked
# explicitly for this: "if I decide to change the color, I change it in one
# place only," extended to EVERY colored element in this hub, not just keys.
# This constant is that one place for shortcut keys specifically.
HUB_KEY_COLOR='1;36'

# hub_key TEXT -> TEXT rendered as a literal, typeable action stated INLINE as
# part of a prompt's own question or content: its primary answer or accept
# action. A single letter (`y`, `N`), a whole phrase the user must type verbatim
# (the critical-uninstall confirmation phrase), `Enter` where Enter IS the
# prompt's own accept action, or a key named in read-only screen content (the
# help screen's own reference rows).
#
# NOT for a key listed in a TRAILING HINT LIST appended after a prompt's own
# content — one of the alternatives the user could type instead (`b: back`,
# `a: all`, `/text: filter`). That role belongs to hub_hint_segment below,
# which colors it dimmer so the prompt's own question stays the brightest thing
# on the line. The split follows a structure hub_confirm_prompt already
# documents: its own tier-colored question and the appended nav trio are
# colored by two separate mechanisms, never nested.
#
# Within its narrowed role this is still THE one way to color such a key: never
# hand-call hub_c with a bare code, for the same one-place-to-change-it reason
# HUB_KEY_COLOR exists.
hub_key() { hub_c "$HUB_KEY_COLOR" "$1"; }

# HUB_NUMBER_COLOR / hub_number -> the SAME one-place-to-change-it rule as
# HUB_KEY_COLOR/hub_key, for the OTHER thing this hub colors at every numbered
# choice (the Main menu, the Accounts submenu, every checklist row): a plain
# (not bold) cyan number, a deliberately distinct treatment from a lettered
# shortcut so the two remain visually distinguishable from each other, not just
# from plain text.
HUB_NUMBER_COLOR=36
hub_number() { hub_c "$HUB_NUMBER_COLOR" "$1"; }

# HUB_HINT_KEY_COLOR — dim + cyan, for a key listed as part of a trailing
# hint list (see hub_hint_segment) — as opposed to HUB_KEY_COLOR, which is for
# a key that IS a prompt's own primary answer or accept action. DERIVED from
# HUB_DIM_COLOR rather than a duplicated literal "2", valid ONLY while
# HUB_DIM_COLOR holds an SGR *intensity attribute* (2), not a hue: prefixing a
# later foreground color, as done here, works because "2;36" applies both;
# prefixing a HUE (HUB_DIM_COLOR's own comment anticipates an explicit-grey
# switch, e.g. "38;5;245") would instead produce "38;5;245;36", where the
# trailing 36 overrides the grey foreground outright and the dim is lost. If
# HUB_DIM_COLOR ever becomes a hue, this constant must be re-derived as a
# grey-plus-no-additional-hue value, not this prefix concatenation. Quoted for
# the same reason HUB_WARN_COLOR is: an unquoted value with a `;` in it would
# terminate the assignment early.
#
# SGR 2 (faint) is not universally honored; a terminal that ignores it renders
# this as plain "36" — the same value as HUB_ARROW_COLOR/HUB_SAFE_COLOR/
# HUB_NUMBER_COLOR. If that collision or the low-contrast pairing against a
# HUB_DIM_COLOR-only label reads poorly on a real terminal, the one-line fix
# is dropping the "$HUB_DIM_COLOR;" prefix, leaving plain cyan.
HUB_HINT_KEY_COLOR="${HUB_DIM_COLOR};36"

# hub_hint_segment KEY LABEL -> "KEY: LABEL", KEY in HUB_HINT_KEY_COLOR,
# LABEL dimmed — the one shared shape for a key listed among a prompt's
# alternatives, replacing each site's own "$(hub_key X)$(hub_dim ': label')"
# (or, at several sites, an undimmed label achieving the same list — this
# function is also what makes every site agree on dimming the label, not only
# the key). Two separate hub_c calls concatenated, never nested — the same
# reset-swallows-the-outer-color trap hub_confirm_prompt documents.
#
# No standalone hub_hint_key: today nothing needs a hint-colored key without
# a label, and this file's own hub_glyph doc comment already rejects shipping
# a wrapper with no real caller. Add one, when a real bare-key site exists.
#
# hub_sep_text's " · " stays uncolored between segments — accepted, not an
# oversight: with every segment now dimmed, the separator is the brightest
# character on the line, but it cannot be colored globally (hub-doctor.sh
# emits it into machine payload under --format=env|json, per hub_arrow_text's
# own comment above) and a hint-line-local variant would be exactly the kind
# of one-more-special-case creep the full-renderer proposals in this hub were
# rejected for.
hub_hint_segment() {
	printf '%s%s' "$(hub_c "$HUB_HINT_KEY_COLOR" "$1")" "$(hub_dim ": $2")"
}

# hub_nav_keys_hint -> "b: back · q: quit · ?: help", each segment built by
# hub_hint_segment. The single definition of this trio's wording AND color.
# Called by hub_confirm_prompt, hub_checklist_hint_text (which appends its own
# "Enter: confirm" AFTER the trio, not before) and the Accounts submenu
# prompt. hub_press_key_to_continue does NOT call this: it advertises no `b`
# and leads with Enter instead, so it composes its own trio-shaped hint by
# hand. The Main menu, the one screen where `b` has nothing to go back to,
# also composes its own hint by hand rather than calling this.
hub_nav_keys_hint() {
	hnkh_sep=$(hub_sep_text)
	printf '%s%s%s%s%s' \
		"$(hub_hint_segment b back)" "$hnkh_sep" \
		"$(hub_hint_segment q quit)" "$hnkh_sep" \
		"$(hub_hint_segment '?' help)"
}

# hub_glyph_for_state STATE -> the listing glyph for one of the three statuses
# List groups rows by (✓ green installed, ○ yellow available, ! orange
# diverged), plus ORPHANED which reuses the failure glyph because a dangling
# link IS a genuine fault, not a pending action. AVAILABLE IS hub_glyph_absent,
# NOT hub_glyph_new: List is a report of current state, not a plan — `+`/`-`
# are reserved for the plan stage (Install/Uninstall's own preview screens,
# hi_unit_glyph/hub_glyph_remove), where they mean "will be added/removed" once
# the user confirms. An available-but-not-installed item here is the same
# absence hub-status.sh already reports with this same glyph, not a pending
# action.
hub_glyph_for_state() {
	case $1 in
	installed) hub_glyph_ok ;;
	available) hub_glyph_absent ;;
	DIVERGED) hub_glyph_warn ;;
	ORPHANED) hub_glyph_fail ;;
	*) die "hub_glyph_for_state: unknown state '$1'" ;;
	esac
}

# hub_print_header TITLE -> TITLE on its own line, undimmed — it is the
# screen's actual content.
#
# NO LONGER prints a standalone b/q/?  nav-hint list underneath. A live test
# session's own rule of thumb: "the > line contains the action hint" — b/q/?
# are valid at whatever prompt a screen ends on (hub_press_key_to_continue,
# hub_confirm_prompt, the checklist's own prompt, ...), so hub_nav_keys_hint is
# appended THERE, at the point of actual input, rather than floating in a
# separate list at the top that the user has to remember while scrolling down
# to where they actually type. Every screen this hub renders ends at one of
# those prompts, so nothing becomes undiscoverable by this move.
hub_print_header() {
	printf '%s\n' "$1"
}

# hub_report_foreign_blocked FILE MESSAGE -> one failure-glyph line per non-empty
# line of FILE, each reading "<item> <MESSAGE>". The universal write guard's
# report, rendered identically wherever it is reported: install and uninstall each
# had their own copy of this loop, differing only in the sentence, which is exactly
# how two reports of the same refusal drift into describing it differently.
hub_report_foreign_blocked() {
	while IFS= read -r hrfb_item; do
		[ -n "$hrfb_item" ] || continue
		printf '  %s %s %s\n' "$(hub_glyph_fail)" "$hrfb_item" "$2"
	done <"$1"
}

# hub_print_hint TEXT -> a dimmed secondary line (a checklist's key legend, a
# next-action hint under a menu).
hub_print_hint() {
	hub_dim "$1"
	printf '\n'
}

# hub_dry_run_marker -> the fixed interactive dry-run line (spec: "the
# `[DRY RUN]` marker line reads simply `[DRY RUN] Nothing has changed yet.`" —
# the flag-bearing "re-run with --apply" clause belongs to agent-facing mode
# only, and is printed there, never here).
hub_dry_run_marker() {
	printf '[DRY RUN] Nothing has changed yet.\n'
}

# hub_confirm_prompt TIER -> the fixed prompt text for a confirmation tier, per
# the spec's confirmation-tier table. TIER is safe | dangerous. (critical's
# typed-phrase prompt lives in lib/hub-nav.sh — it is not a same-shape [Y/n]
# prompt.) "Proceed? [Y/n]" is colored per tier (cyan for safe, yellow for
# dangerous, matching the ladder's own color column); every hint key appended
# after it (`c` and the b/q/? trio are ALL valid at this exact prompt —
# hub_confirm_gate's own case statement handles each) is colored via
# hub_hint_segment / hub_nav_keys_hint instead, NEVER by nesting one inside this
# function's own `hub_c` call — hub_c always ends with a full SGR reset, so an
# inner hub_c/hub_key call would silently kill the outer tier color for
# everything printed after it.
#
# `c: cancel` sits BETWEEN the tier question and the nav trio, and via
# hub_hint_segment like every other trailing-hint key (never a hand-rolled
# "$(hub_key c)$(hub_dim ': cancel')" — that composition is exactly what
# hub_hint_segment exists to own). Two reasons for that position, both about
# what the key IS rather than about line aesthetics. `c` is an answer to THIS
# prompt's own question — a name for the decline that [Y/n]'s `n` half already
# implies (see hub_confirm_gate) — whereas b/q/? are the hub's GLOBAL
# navigation, valid at every prompt that renders them; grouping the
# prompt-specific answer with the question and leaving the trio an unbroken tail
# keeps b/q/? in the same relative position on every screen. And it is the
# ordering lib/hub-checklist.sh's hub_checklist_hint_text already established
# from the other side: screen-specific alternatives first (`1,3-5`, `a`, `n`,
# `/text`), THEN hub_nav_keys_hint. Splitting the trio to slot `c` inside it
# would also mean either breaking hub_nav_keys_hint apart or duplicating its
# wording, which is the drift that function exists to prevent.
#
# The segments are joined by hub_sep_text, like every other multi-segment hint
# line here (hub_nav_keys_hint itself, hu_choose_backup's `1-N` line) — and with
# no spaces of its own in the format string, since hub_sep_text carries its own
# spacing. A hardcoded '·' here, which is what this used to be, was the one
# separator in the hub that did NOT degrade under --accessible, against
# HUB_ASCII's own stated contract that every separator does. Assigned ONCE to
# hcp_sep rather than substituted per slot, matching hub_nav_keys_hint and
# hub_checklist_hint_text.
hub_confirm_prompt() {
	hcp_tier=$1
	case $hcp_tier in
	safe) hcp_color=$HUB_SAFE_COLOR hcp_yn='Y/n' ;;
	dangerous) hcp_color=$HUB_DANGER_COLOR hcp_yn='y/N' ;;
	*) die "hub_confirm_prompt: unknown tier '$1'" ;;
	esac
	hcp_sep=$(hub_sep_text)
	printf '%s%s%s%s%s: ' "$(hub_c "$hcp_color" "Proceed? [$hcp_yn]")" \
		"$hcp_sep" "$(hub_hint_segment c cancel)" \
		"$hcp_sep" "$(hub_nav_keys_hint)"
}

