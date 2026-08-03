#!/usr/bin/env sh
# lib/hub-nav.sh — the interactive navigation and confirmation primitives every
#                   mutating screen shares: the safe/dangerous [Y/n]-style
#                   prompt, the critical typed-phrase gate, the pending-
#                   selection discard guard, the Result-screen pause, and the
#                   global help screen.
#
# Sourced after lib/hub-common.sh and lib/hub-render.sh. Not executable on its
# own.
#
# DISCLOSED DESIGN DECISION — every prompt here is LINE-based (`read -r` up to
# Enter), not a raw single-keystroke terminal widget. Consequences, stated
# plainly rather than left implicit:
#   * The spec's "b/q/? are literal characters, not navigation, inside the one
#     free-text confirmation field" carve-out needs no special casing, because
#     nothing here intercepts a bare keystroke as navigation anywhere — every
#     read is a whole line the caller interprets, so the ambiguity that
#     carve-out resolves never arises.
#   * The help screen's "ANY key closes help" becomes "Enter closes help".
#   * The checklist's space-to-toggle becomes type-the-row-then-Enter (see
#     lib/hub-checklist.sh's own header).
# The alternative — `stty -icanon` raw mode with cursor addressing and escape-
# sequence parsing — would put the user's terminal into a state this script is
# then responsible for restoring on every exit path including a signal, which
# is a materially larger correctness and portability risk than the interaction
# polish it buys.
#
# Portability: POSIX sh only.

# hub_help_text -> the static, category-grouped reference (spec: the global `?`
# help): what each nav key does, how a checklist is driven, what each domain
# installs, and what each action does.
#
# RENDERED FULL BRIGHTNESS, not dimmed. This screen's headings and prose ARE its
# content — the same reading that undimmed the checklist subtitle, applied here:
# a whole screen the user deliberately opened is never one long secondary hint.
# The ONLY dimmed line is the closing "Press Enter to return." footer, which
# genuinely is a hint about how to leave rather than something to read.
#
# Every literal key the user may type (`?`, b/back, q/quit, Enter, a, n, /text)
# is colored via hub_key — deliberately, NOT hub_hint_segment, which every
# live prompt's own hint line uses instead: this screen is read-only reference
# content the user came to read, not a secondary hint alongside another input,
# so its keystrokes get the same bold treatment as a prompt's own primary
# answer affordance, not the dimmed hint-list treatment. The Actions rows are
# NOT keys: `status`,
# `install all` and friends are subcommand names invoked elsewhere, not
# keystrokes accepted at this screen, so coloring them as keys would advertise
# input this screen does not take.
#
# Colored segments are always concatenated as SEPARATE printf arguments, never
# nested inside another color call's text — hub_c ends with a full SGR reset, so
# an inner hub_key inside hub_dim's argument would kill the dim for the rest of
# the line (the same trap hub_confirm_prompt documents).
#
# "CAPABILITIES", NOT "COMPONENTS", in GTD's block below. "Component" is a bound
# term everywhere else in this hub meaning one discovered UNIT — hub-list.sh's
# "Components — discovered" heading, hub-doctor.sh's "Diverged components",
# --components on the uninstall flags — and GTD has THREE of those, not two. What it
# has two of is FEATURES (lib/hub-domains.sh's §4b, which uses "capability" for
# exactly this distinction), so naming them "components" told a reader a unit count
# that contradicts every other screen.
hub_help_text() {
	hht_sep=$(hub_sep_text)

	printf '%s\n\n' 'Crucible Management Hub — Help'

	printf '%s\n' '  Navigation'
	printf '    %s%s\n' "$(hub_key '?')" '              show this help'
	printf '    %s, %s%s\n' "$(hub_key b)" "$(hub_key back)" \
		'        go back one step (repeat to reach the main menu)'
	printf '    %s, %s%s\n' "$(hub_key q)" "$(hub_key quit)" \
		'        quit the hub, from anywhere (except: while viewing this'
	printf '                   help screen, %s just closes help)\n' "$(hub_key Enter)"
	printf '\n'

	printf '%s\n' '  Selecting options (checklists)'
	printf '    Type a number or name, then %s, to select or deselect it.\n' \
		"$(hub_key Enter)"
	printf '%s\n' '    Combine several: "1,3,5" or a range "1-5" (same as "1,2,3,4,5").'
	printf '    %s: select all%s%s: select none%s%s: filter a long list\n' \
		"$(hub_key a)" "$hht_sep" "$(hub_key n)" "$hht_sep" "$(hub_key '/text')"
	printf '\n'

	printf '%s\n' \
		'  Software Development' \
		'    A developer + reviewer agent pair per technology (Python, Java, React,' \
		'    ...), plus review lenses and framework plumbing shared across all of' \
		'    them.' \
		'' \
		'  Adding a new technology (tech pair)' \
		'    Software Development ships with a fixed set, but the framework can' \
		'    generate a new developer+reviewer pair on demand — in a Claude Code' \
		'    session (not from this hub), just ask: "I need a tech pair for Go."' \
		'    Review and deploy it, then re-run this hub to install it like any' \
		'    other technology.' \
		'' \
		'  Project Management' \
		'    GitHub and/or Jira backends: lets an agent file, comment on, and' \
		'    update tickets on whichever backend(s) you install.' \
		'' \
		'  Getting Things Done (GTD)' \
		'    Two capabilities:' \
		'      - Inbox capture: park a stray thought without derailing your' \
		'        current task (say "dump: <thought>" or "park: <thought>" in any' \
		'        Claude Code session).' \
		"      - Inbox triage: review what's captured and process it." \
		'' \
		'  Actions' \
		'    status         which domains are installed' \
		'    list           installed vs available components' \
		'    doctor         required tools + account health' \
		'    accounts       manage GitHub / Jira authentication' \
		'    install all    install every domain, technology and backend' \
		'    install        choose domains, then technologies / backends' \
		'    uninstall all  uninstall everything (critical, typed confirmation)' \
		'    uninstall      choose specific components to uninstall' \
		''

	printf '  %s%s%s\n' "$(hub_dim 'Press ')" "$(hub_key Enter)" "$(hub_dim ' to return.')"
}

# hub_show_help -> print the help overlay and block until Enter. A temporary
# read-only overlay, never a navigable screen: it always returns to whatever
# screen called it and can never quit the hub.
#
# THE OVERLAY GOES TO stderr, like every other human-only surface in this file
# (hub_press_key_to_continue, hub_discard_guard, hub_confirm_gate's prompt) and
# in lib/hub-checklist.sh. stdout is the MACHINE channel: `?` is accepted on the
# checklist and the confirm screen, both of which a caller can reach on a TTY
# under --format=env|json, so an unrouted help screen would dump ~20 lines of
# dimmed prose into the payload a caller `eval`s or `jq`s. stderr rather than the
# capability scripts' fd 3 for the reason stated in this file's header: a lib must
# not depend on its sourcing script having opened a private descriptor, and under
# --format=text both land on the same terminal anyway.
#
# Routed HERE rather than at the two call sites so a third caller cannot
# reintroduce the leak by forgetting the redirect.
hub_show_help() {
	hub_help_text >&2
	IFS= read -r _ || :
}

# hub_confirm_gate TIER PENDING_COUNT -> the confirmation prompt on a dry-run
# screen, with navigation. Returns:
#   0  proceed
#   1  decline (an explicit no, or unrecognized input)
#   2  go back one level
#   3  quit the hub
#
# Input handling:
#   * an EMPTY line applies TIER's default — safe: Yes, dangerous: No.
#   * an explicit y/yes (any case) proceeds, on either tier.
#   * c/cancel declines — the SAME return 1, and the same "Cancelled. Nothing
#     changed." at both call sites, that an unrecognized or negative input has
#     always produced. It is a NAME for the existing decline path, not a new
#     return code and not new behavior: the capability existed but nothing on
#     screen said so, leaving "abandon this operation" the one action the user
#     had to infer while its two neighbours (b/back, q/quit) were both
#     advertised — and easy to confuse with either, since `b` re-opens the
#     checklist and `q` leaves the hub entirely. Handled HERE, above the tier
#     dispatch, rather than folded into either tier's `*)` arm: the two `*)`
#     arms are tier-specific by construction (safe's default-Yes lives in one
#     of them), so a key that must behave identically on both tiers cannot live
#     in either.
#   * b/back goes back one level; ? shows help and re-prompts.
#   * q/quit quits, asking first when PENDING_COUNT is non-zero — the confirm
#     screen holds the identical not-yet-committed selection the checklist just
#     built, so a habitual q here is the identical footgun at the identical
#     cost, and guarding the checklist but not its very next sibling would close
#     the gap in the wrong place.
#   * anything else declines. A safe tier's default-Yes applies ONLY to the
#     empty line; garbage input is never read as consent to proceed, which is
#     the safer and conventional reading of a [Y/n] prompt. This implicit path
#     is retained exactly as-is alongside the explicit `c` above — naming the
#     action must not make the unnamed spelling stop working.
#
# There is no retry loop for a decline: a non-interactive caller never reaches
# this function at all (every capability script gates it on its own TTY check).
hub_confirm_gate() {
	hcg_tier=$1
	hcg_pending=$2
	while :; do
		hub_confirm_prompt "$hcg_tier" >&2
		IFS= read -r hcg_reply || hcg_reply=q
		case $hcg_reply in
		'?')
			hub_show_help
			continue
			;;
		c | cancel) return 1 ;;
		b | back) return 2 ;;
		q | quit)
			if [ "$hcg_pending" -gt 0 ]; then
				hub_discard_guard "$hcg_pending" || continue
			fi
			return 3
			;;
		esac
		case $hcg_tier in
		safe)
			case $hcg_reply in
			'' | [Yy] | [Yy][Ee][Ss]) return 0 ;;
			*) return 1 ;;
			esac
			;;
		dangerous)
			case $hcg_reply in
			[Yy] | [Yy][Ee][Ss]) return 0 ;;
			*) return 1 ;;
			esac
			;;
		*) die "hub_confirm_gate: unknown tier '$hcg_tier'" ;;
		esac
	done
}

# hub_discard_guard COUNT -> the guard for pressing q while a non-empty,
# not-yet-committed selection is pending (spec: "Discard N selected items and
# quit?"). Returns 0 to discard and quit, 1 to stay. Covers BOTH the checklist
# screen and the confirm/dry-run screen that follows it, since both hold the
# identical pending selection and a habitual q is the identical footgun at
# either point. A COUNT of 0 is a caller bug — the empty-selection case exits
# immediately with no prompt — so it dies rather than misbehaving quietly.
hub_discard_guard() {
	hdg_count=$1
	[ "$hdg_count" -gt 0 ] || die "hub_discard_guard: called with nothing pending"
	printf '%s [%s]: ' "$(hub_c "$HUB_DANGER_COLOR" "Discard $hdg_count selected $(hub_plural "$hdg_count" item items) and quit?")" \
		"$(hub_key y)/$(hub_key N)" >&2
	IFS= read -r hdg_reply || hdg_reply=""
	case $hdg_reply in
	[Yy] | [Yy][Ee][Ss]) return 0 ;;
	*) return 1 ;;
	esac
}

# hub_interactive -> exit 0 when this run may prompt: --non-interactive was not
# passed AND both stdin and stdout are a terminal. The test every mutating screen
# gates its prompts on, written down once — install and uninstall each spelled it
# out three times, and a fourth site that got it half-right would prompt a machine
# caller and hang it.
#
# OPT_NONINTERACTIVE is read from the calling script (defaulted, so a script that
# has no such flag can still call this safely), exactly as hub_validate_format
# reads OPT_FORMAT.
hub_interactive() {
	[ "${OPT_NONINTERACTIVE:-0}" -eq 0 ] || return 1
	hub_is_tty
}

# hub_result_details DETAILS_FLAG BULK -> sets HUB_SHOW_DETAILS to 1 or 0,
# prompting only where a prompt is warranted.
#
# THE RULE, from the base spec's Result screens: a SELECTIVE result is always
# fully itemized — the user named specific things and is owed a line per thing —
# while only the BULK (--all) result defaults to the summary line and offers
# "Show details?" as a follow-up. Both scripts had this inverted: they defaulted
# every result to the summary, so a selective install of one domain printed a bare
# count, and off a TTY printed nothing at all.
#
# The prompt goes to stdout rather than stderr, unlike every other prompt in this
# file: it is reachable only from the text-format Result screen, where stdout IS
# the human channel, and the detail lines it gates print there too — a prompt on a
# different stream than its own answer's output reads as two unrelated screens.
hub_result_details() {
	if [ "$1" -eq 1 ] || [ "$2" -eq 0 ]; then
		HUB_SHOW_DETAILS=1
		return 0
	fi
	HUB_SHOW_DETAILS=0
	hub_interactive || return 0
	printf 'Show details? [%s/%s]: ' "$(hub_key y)" "$(hub_key N)"
	IFS= read -r hrd_reply || hrd_reply=""
	case $hrd_reply in
	[Yy] | [Yy][Ee][Ss]) HUB_SHOW_DETAILS=1 ;;
	esac
}

# hub_press_key_to_continue -> block on one line before returning: EVERY screen's
# pause now, not just a Result screen's. A live test session found the old
# read-only-screen behavior (render, then auto-redraw the Main menu underneath
# with only a dim divider between them) buried the screen's own content the
# instant it appeared, which defeated the point of asking to see it. Every
# screen now waits for an explicit action instead, matching the Result screens'
# pause, which already worked this way.
#
# THE PROMPT IS THE ONLY PLACE THIS SCREEN'S NAV KEYS ARE ADVERTISED — there is
# no separate list at the top any more (see hub_print_header). Leads with
# `Enter`, not `b`, because Enter IS the accepted way to continue (this
# function's own case below returns 0 on Enter, `b`/`back`, or literally
# anything else it does not otherwise recognize) — a live test session found
# the old "Press 'b'..." wording implied `b` was required when it never was.
#
# Returns:
#   0  return to the caller (Enter, b/back, or anything unrecognized)
#   3  the user asked to quit the hub
# `?` shows help and re-prompts, as everywhere else.
#
# The CALLER gates this on hub_interactive; agent-facing mode has no keypress to
# wait for and must return immediately.
hub_press_key_to_continue() {
	hpktc_sep=$(hub_sep_text)
	while :; do
		printf '\n%s%s%s%s%s\n> ' \
			"$(hub_hint_segment Enter 'back to the menu')" "$hpktc_sep" \
			"$(hub_hint_segment q quit)" "$hpktc_sep" \
			"$(hub_hint_segment '?' help)" >&2
		IFS= read -r hpktc_reply || hpktc_reply=""
		case $hpktc_reply in
		'?')
			hub_show_help
			continue
			;;
		q | quit) return 3 ;;
		*) return 0 ;;
		esac
	done
}

# HUB_CRITICAL_PHRASE — the phrase the one critical-tier flow requires typed.
HUB_CRITICAL_PHRASE='UNINSTALL'

# HUB_CRITICAL_MAX_ATTEMPTS — 3, citing sudo's own default passwd_tries=3: a
# small retry count is the established shape for a destructive-confirmation
# gate, generous enough for a genuine typo and short enough that hammering it
# is not a strategy.
HUB_CRITICAL_MAX_ATTEMPTS=3

# hub_confirm_typed_phrase PHRASE -> the critical gate. Prompts up to
# HUB_CRITICAL_MAX_ATTEMPTS times for an exact match; an empty line cancels
# immediately on ANY attempt (the spec's "press Enter on an empty line to
# cancel" is never scoped to the first attempt only). Returns 0 on an exact
# match, 1 on cancellation — the caller treats either cancellation path as
# "nothing changed".
hub_confirm_typed_phrase() {
	hctp_phrase=$1
	hctp_attempt=1
	while [ "$hctp_attempt" -le "$HUB_CRITICAL_MAX_ATTEMPTS" ]; do
		printf 'Type %s to confirm, or press %s on an empty line to cancel:\n> ' \
			"$(hub_key "$hctp_phrase")" "$(hub_key Enter)" >&2
		IFS= read -r hctp_reply || hctp_reply=""
		if [ -z "$hctp_reply" ]; then
			printf 'Cancelled. Nothing changed.\n' >&2
			return 1
		fi
		if [ "$hctp_reply" = "$hctp_phrase" ]; then
			return 0
		fi
		hctp_remaining=$((HUB_CRITICAL_MAX_ATTEMPTS - hctp_attempt))
		if [ "$hctp_remaining" -gt 0 ]; then
			printf 'Not recognized. %s %s remaining.\n' \
				"$hctp_remaining" "$(hub_plural "$hctp_remaining" attempt attempts)" >&2
		else
			printf 'Too many incorrect attempts — cancelled. Nothing changed.\n' >&2
		fi
		hctp_attempt=$((hctp_attempt + 1))
	done
	return 1
}
