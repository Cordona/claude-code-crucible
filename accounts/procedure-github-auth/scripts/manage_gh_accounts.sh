#!/usr/bin/env sh
#
# manage_gh_accounts.sh — USER-interactive GitHub CLI account manager.
#
# Purpose:
#   The one step of the account auth gate a HUMAN drives. It shows the current
#   `gh` auth state, then lets the user either SWITCH to another already-logged-
#   in account (preferred: `gh auth switch --user <u> --hostname <h>`, which is
#   fast and non-interactive where the account is already authenticated) or LOG
#   IN a brand-new account (`gh auth login`, inherently interactive). Supports
#   github.com and GitHub Enterprise hosts.
#
#   The agent NEVER parses this script's output — it re-runs gh-auth-status.sh
#   afterwards to learn the result. This script only drives the human.
#
# Usage:
#   manage_gh_accounts.sh [-h|--help]
#   (No operands — interactive.)
#
# Exit codes:
#   0  a switch/login completed, OR the user chose to keep the current account
#   1  error, or the user cancelled
#
# Portability: POSIX sh only (no bashisms — no [[ ]], arrays, `local`, (( )),
#   shopt, BASH_SOURCE, `read -p`). Runs identically on macOS (BSD userland /
#   Bash 3.2) and Linux (GNU). shellcheck-clean. SELF-CONTAINED: it re-implements
#   inline the small subset of the control-center common/lib it needs
#   (log_*, confirm_yn, check-command, tool version) — it sources NOTHING and
#   does not depend on that repo.
#
set -eu

LC_ALL=C
export LC_ALL

PROG=${0##*/}
MAX_RETRIES=3

# ===========================================================================
# Inline reimplementation of the bits we used to source from common/lib/*
# (logging.sh: log_*/COLOR_*; prompts.sh: confirm_yn/MAX_RETRIES;
#  tools.sh: check_command_exists/get_tool_version). Kept minimal + POSIX.
# ===========================================================================

# ---------------------------------------------------------------------------
# Rendering legend — glyphs, colors and prompt furniture.
#
# The VALUES and glyph choices below deliberately mirror the Crucible
# Management Hub's lib/hub-render.sh one for one (HUB_OK_COLOR, HUB_FAIL_COLOR,
# HUB_WARN_COLOR, HUB_NUMBER_COLOR, HUB_DIM_COLOR, HUB_HINT_KEY_COLOR and the
# ✓/✗/! glyphs), so this screen looks like the menu that launched it. They are
# RE-DECLARED here and NOT sourced from that file, for the reason this script's
# own header states: it ships inside the procedure-github-auth skill and is run
# directly by agents as their account-confirmation gate, so it must keep working
# with no hub present. The cost of that independence is this duplication; the
# rule for it is that the values here only ever move to MATCH the hub's.
#
# One named constant per MEANING, following the hub's own discipline: several
# meanings collide on an SGR number today (failure and "will be removed" are
# both 31; number, arrow and hint-key are all 36), so recoloring one must not
# silently move the others.
#
# Out of scope, and stated so no one reads its absence as an oversight: the
# hub's HUB_ASCII/--accessible glyph fallback. This script has no such flag to
# switch on, and inventing one would add an option the hub never passes it.
# ---------------------------------------------------------------------------

# Glyph characters. NOT emptied by the no-color branch below: color and content
# are independent axes in the hub too (--no-color strips ANSI attributes and
# keeps every glyph), and a ✓ still reads as success in a pipe.
GLYPH_OK='✓'
GLYPH_WARN='!'
GLYPH_FAIL='✗'

# SGR_DIM — the faint attribute (hub HUB_DIM_COLOR=2). The one color value that
# needs a name of its own rather than living inline in a printf format below,
# because TWO renderings derive from it: C_DIM, and C_HINT_KEY's dim+cyan pair.
# That derivation is valid ONLY while this holds an intensity ATTRIBUTE (2) and
# not a hue — "2;36" applies both, whereas a grey hue like "38;5;245;36" would
# let the trailing 36 override the grey outright and lose the dimming.
SGR_DIM=2

# SEP — the inline hint-list separator, carrying its OWN surrounding spacing
# (hub hub_sep_text), because the spacing differs between the Unicode and ASCII
# forms there and so belongs to the separator rather than to each call site.
SEP=' · '

# Colors: honour NO_COLOR (https://no-color.org/, checked by PRESENCE — an
# empty NO_COLOR="" still disables color, matching the hub's own
# hub_color_enabled), honour the hub's own HUB_NO_COLOR when this script runs
# AS the hub's delegate (crucible-hub passes it through on exec; unset when run
# standalone, so a direct invocation is unaffected), and disable when stdout is
# not a TTY, so piped/captured output is clean.
color_disabled() {
	[ -z "${NO_COLOR+x}" ] || return 0
	case ${HUB_NO_COLOR:-0} in
	0 | '') : ;;
	*) return 0 ;;
	esac
	[ -t 1 ] || return 0
	return 1
}
if color_disabled; then
	C_RESET=""; C_OK=""; C_WARN=""; C_FAIL=""; C_NUMBER=""; C_DIM=""; C_HINT_KEY=""
else
	C_RESET=$(printf '\033[0m')
	C_OK=$(printf '\033[32m')                      # green  — success (hub HUB_OK_COLOR)
	C_WARN=$(printf '\033[38;5;208m')              # orange — warning (hub HUB_WARN_COLOR)
	C_FAIL=$(printf '\033[31m')                    # red    — failure (hub HUB_FAIL_COLOR)
	C_NUMBER=$(printf '\033[36m')                  # cyan   — a number you may type (hub HUB_NUMBER_COLOR)
	C_DIM=$(printf '\033[%sm' "$SGR_DIM")          # faint  — secondary/instructional text
	C_HINT_KEY=$(printf '\033[%s;36m' "$SGR_DIM")  # dim cyan — a key offered in a trailing hint list
fi

# dim TEXT / number TEXT -> TEXT in the one treatment named above. Every call
# site colors through these, never by hand-writing an escape, so "change the
# color" stays a one-line change in the legend.
dim()    { printf '%s%s%s' "$C_DIM"    "$1" "$C_RESET"; }
number() { printf '%s%s%s' "$C_NUMBER" "$1" "$C_RESET"; }

# hint_segment KEY LABEL -> "KEY: LABEL", KEY in dim cyan and LABEL dimmed —
# the hub's hub_hint_segment shape, for one of the alternatives a user may type
# INSTEAD of answering the prompt's own question (`c: cancel`). Two separately
# colored spans CONCATENATED, never nested: each span ends in a full SGR reset,
# so wrapping one inside the other would kill the outer color for everything
# printed after it.
hint_segment() {
	printf '%s%s%s%s' "$C_HINT_KEY" "$1" "$C_RESET" "$(dim ": $2")"
}

# prompt_select TOTAL -> the prompt line shared by every list this script asks
# the user to pick from: a dimmed instruction, the `c: cancel` alternative, and
# the hub's `> ` input marker on its own line. The order is the hub's own: this
# prompt's instruction first, then the keys you could type INSTEAD of answering
# it — screen-specific alternatives never precede the question they belong to.
#
# main_menu composes its OWN line by hand instead of calling this, because it
# offers no `c` — its "3. Keep the current account" row already IS the decline,
# and advertising a key the menu's case statement does not handle would be a
# lie. Exactly the split the hub draws when its Main menu hand-rolls a hint
# rather than calling hub_nav_keys_hint for a `b` it has nowhere to go back to.
prompt_select() {
	printf '  %s%s%s\n> ' "$(dim "Select 1-$1")" "$SEP" "$(hint_segment c cancel)"
}

# Logging: INFO/SUCCESS -> stdout, WARNING/ERROR -> stderr. Matches the
# semantics of the original common/lib/logging.sh convenience functions.
#
# The severity is carried by a COLORED GLYPH rather than a bracketed [LEVEL]
# tag, which is what aligns this script with the hub. log_info deliberately
# gets neither glyph nor color: an informational line is the screen's ordinary
# content, so a marker on it would only compete with the three that mean
# something.
log_info()    { printf '%s\n' "$*"; }
log_success() { printf '%s%s%s %s\n' "$C_OK"   "$GLYPH_OK"   "$C_RESET" "$*"; }
log_warning() { printf '%s%s%s %s\n' "$C_WARN" "$GLYPH_WARN" "$C_RESET" "$*" >&2; }
log_error()   { printf '%s%s%s %s\n' "$C_FAIL" "$GLYPH_FAIL" "$C_RESET" "$*" >&2; }

# check_command_exists <cmd> — 0 if on PATH, 1 otherwise.
check_command_exists() { command -v "$1" >/dev/null 2>&1; }

# gh_version — best-effort version string for the banner, "unknown" on failure.
gh_version() {
	gv=$(gh --version 2>/dev/null | head -n 1 | awk '{print $3}' || true)
	printf '%s' "${gv:-unknown}"
}

# confirm_yn <prompt> <default y|n> — POSIX read (no `read -p` bashism), retry
# bounded by MAX_RETRIES, Enter selects the default. Returns 0=yes, 1=no.
confirm_yn() {
	cy_prompt=$1
	cy_default=${2:-n}
	cy_retries=0
	case "$cy_default" in
		y|Y) cy_hint="[Y/n]" ;;
		*)   cy_hint="[y/N]" ;;
	esac
	while [ "$cy_retries" -lt "$MAX_RETRIES" ]; do
		printf '%s %s: ' "$cy_prompt" "$cy_hint"
		if ! IFS= read -r cy_ans; then
			# EOF (unattended run): fail-safe DECLINE. We do NOT assume the
			# default — an EOF'd "Log in now? [Y/n]" must not silently start an
			# interactive login no one is there to complete.
			log_warning "No input (EOF); declining."
			return 1
		fi
		[ -n "$cy_ans" ] || cy_ans=$cy_default
		case "$cy_ans" in
			y|Y|yes|YES|Yes) return 0 ;;
			n|N|no|NO|No)    return 1 ;;
			*) log_error "Please answer 'y' or 'n'."
			   cy_retries=$((cy_retries + 1)) ;;
		esac
	done
	log_error "Maximum retries reached; using default '$cy_default'."
	case "$cy_default" in y|Y) return 0 ;; *) return 1 ;; esac
}

# ===========================================================================
# Usage
# ===========================================================================
usage() {
	cat <<EOF
Usage: $PROG [-h|--help]

Interactive GitHub CLI account manager. Shows the current auth state, then lets
you SWITCH to another already-logged-in account or LOG IN a new one. Supports
github.com and GitHub Enterprise.

Exit codes:
  0  a switch/login completed, or you kept the current account
  1  error, or cancelled
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		-h|--help) usage; exit 0 ;;
		--) shift; break ;;
		-*) usage >&2; log_error "unknown option: $1"; exit 1 ;;
		*)  usage >&2; log_error "unexpected argument: $1"; exit 1 ;;
	esac
	shift
done
[ $# -eq 0 ] || { usage >&2; log_error "unexpected argument: $1"; exit 1; }

TAB=$(printf '\t')

# ===========================================================================
# Isolated scratch dir for the parsed account table (POSIX: no arrays).
# ===========================================================================
WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/gh-accounts.XXXXXX") || {
	log_error "could not create a temporary working directory"
	exit 1
}
# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT INT TERM

ACCT_TABLE="$WORKDIR/accounts"    # "host<TAB>login<TAB>active(0|1)" per line
ACTIVE_LIST="$WORKDIR/actives"    # "login<TAB>host" per ACTIVE account

# ===========================================================================
# parse_auth — run `gh auth status`, populate:
#   AUTHED (true|false), AMBIGUOUS (true|false), ACTIVE_LOGIN, ACTIVE_HOST,
#   $ACCT_TABLE, and $ACTIVE_LIST.
#
# The active account is PER HOST: `gh auth status` marks one account active for
# EACH host. If MORE THAN ONE host has an active account we set AMBIGUOUS=true
# and leave ACTIVE_LOGIN/HOST empty — main() then has the user pick one rather
# than silently choosing an output-order-dependent (possibly wrong) account.
#
# Same keyword-anchored parse as gh-auth-status.sh (duplicated on purpose so
# this file stays standalone — no sourcing).
# ===========================================================================
AUTHED=false
AMBIGUOUS=false
ACTIVE_LOGIN=""
ACTIVE_HOST=""

parse_auth() {
	AUTHED=false
	AMBIGUOUS=false
	ACTIVE_LOGIN=""
	ACTIVE_HOST=""
	: > "$ACCT_TABLE"
	: > "$ACTIVE_LIST"

	if pa_out=$(gh auth status 2>&1); then
		pa_rc=0
	else
		pa_rc=$?
	fi
	[ "$pa_rc" -eq 0 ] || return 0
	AUTHED=true

	printf '%s\n' "$pa_out" | awk '
		/Logged in to /{
			host=""; login=""
			for (i = 1; i <= NF; i++) {
				if      ($i == "to")      host  = $(i + 1)
				else if ($i == "account") login = $(i + 1)
				else if ($i == "as")      login = $(i + 1)
			}
			n++; H[n] = host; L[n] = login; A[n] = 0
		}
		/Active account: true/{ if (n > 0) A[n] = 1 }
		END {
			cnt = 0; na = 0
			for (i = 1; i <= n; i++) {
				if (L[i] == "") continue
				cnt++
				printf "REC\t%s\t%s\t%s\n", H[i], L[i], A[i]
				if (A[i] == 1) { printf "ACT\t%s\t%s\n", H[i], L[i]; ah[H[i]] = 1; na++ }
			}
			nd = 0
			for (h in ah) nd++
			printf "META\tCOUNT\t%d\n",        cnt
			printf "META\tFILT_ACTIVE\t%d\n",  na
			printf "META\tACTIVE_HOSTS\t%d\n", nd
		}
	' > "$WORKDIR/parsed"

	awk -F"$TAB" -v OFS="$TAB" '$1=="REC"{print $2,$3,$4}' "$WORKDIR/parsed" > "$ACCT_TABLE"
	# ACTIVE_LIST rows are "login<TAB>host" (note the field swap for menu use).
	awk -F"$TAB" -v OFS="$TAB" '$1=="ACT"{print $3,$2}' "$WORKDIR/parsed" > "$ACTIVE_LIST"
	pa_count=$(awk -F"$TAB" '$1=="META"&&$2=="COUNT"{print $3}' "$WORKDIR/parsed")
	pa_filtactive=$(awk -F"$TAB" '$1=="META"&&$2=="FILT_ACTIVE"{print $3}' "$WORKDIR/parsed")
	pa_acthosts=$(awk -F"$TAB" '$1=="META"&&$2=="ACTIVE_HOSTS"{print $3}' "$WORKDIR/parsed")
	: "${pa_count:=0}"
	: "${pa_filtactive:=0}"
	: "${pa_acthosts:=0}"

	# Ambiguous: more than one host has an active account -> defer to the user.
	if [ "$pa_acthosts" -gt 1 ]; then
		AMBIGUOUS=true
		return 0
	fi

	# Resolve THE active account: marker -> single account -> gh api fall-back.
	if [ "$pa_filtactive" -ge 1 ]; then
		IFS="$TAB" read -r ACTIVE_LOGIN ACTIVE_HOST < "$ACTIVE_LIST" || true
	fi
	if [ -z "$ACTIVE_LOGIN" ] && [ "$pa_count" -eq 1 ]; then
		IFS="$TAB" read -r ACTIVE_HOST ACTIVE_LOGIN _ < "$ACCT_TABLE" || true
	fi
	if [ -z "$ACTIVE_LOGIN" ]; then
		pa_api=$(gh api user --jq '.login' 2>/dev/null || true)
		if [ -n "$pa_api" ]; then
			ACTIVE_LOGIN=$pa_api
			# `gh api user` (no --hostname) queries github.com: prefer a
			# github.com match when recovering the host, else first match.
			pa_host=""; pa_host_gh=""
			while IFS="$TAB" read -r r_host r_login r_act; do
				[ "$r_login" = "$pa_api" ] || continue
				[ -n "$pa_host" ] || pa_host=$r_host
				[ "$r_host" = "github.com" ] && pa_host_gh="github.com"
			done < "$ACCT_TABLE"
			[ -n "$pa_host_gh" ] && pa_host=$pa_host_gh
			ACTIVE_HOST=$pa_host
		fi
	fi
	[ -n "$ACTIVE_HOST" ] || ACTIVE_HOST="github.com"
}

# ===========================================================================
# resolve_ambiguous — when several hosts each have an active account, present
# them and let the HUMAN pick which one is current. Sets ACTIVE_LOGIN/HOST and
# clears AMBIGUOUS. Returns 1 if the user cancels or gives no input.
# ===========================================================================
resolve_ambiguous() {
	printf '\n'
	log_warning "Multiple hosts have an active account (gh keeps one active per host)."
	log_info "Select which account is current for this operation:"
	printf '\n'
	ra_i=0
	while IFS="$TAB" read -r a_login a_host; do
		[ -n "$a_login" ] || continue
		ra_i=$((ra_i + 1))
		printf '  %s %s (%s)\n' "$(number "$ra_i.")" "$a_login" "$a_host"
	done < "$ACTIVE_LIST"
	printf '\n'

	ra_total=$ra_i
	ra_retries=0
	while [ "$ra_retries" -lt "$MAX_RETRIES" ]; do
		prompt_select "$ra_total"
		if ! IFS= read -r ra_choice; then
			log_error "No input; cancelling."
			return 1
		fi
		case "$ra_choice" in
			c|C|cancel) log_info "Cancelled."; return 1 ;;
		esac
		case "$ra_choice" in
			''|*[!0-9]*) ra_ok=0 ;;
			*) [ "$ra_choice" -ge 1 ] && [ "$ra_choice" -le "$ra_total" ] && ra_ok=1 || ra_ok=0 ;;
		esac
		if [ "$ra_ok" -eq 1 ]; then
			ACTIVE_LOGIN=$(awk -F"$TAB" -v n="$ra_choice" 'NR==n{print $1}' "$ACTIVE_LIST")
			ACTIVE_HOST=$(awk  -F"$TAB" -v n="$ra_choice" 'NR==n{print $2}' "$ACTIVE_LIST")
			AMBIGUOUS=false
			return 0
		fi
		log_error "Invalid selection. Enter a number 1-$ra_total, or 'c'."
		ra_retries=$((ra_retries + 1))
	done
	log_error "Maximum retries reached; cancelling."
	return 1
}

# report_now_active — post-action summary that stays honest under ambiguity.
report_now_active() {
	if [ "$AMBIGUOUS" = true ]; then
		log_success "Done. Multiple hosts remain active (one active account per host)."
	else
		log_success "Now active: $ACTIVE_LOGIN ($ACTIVE_HOST)."
	fi
}

# ===========================================================================
# UI helpers
# ===========================================================================
#
# The title is PLAIN, UNCOLORED text at column 0 and carries no rule lines above
# or below it — the hub's hub_print_header shape exactly. Both changes are the
# same point: in this hub only glyphs, typeable keys and numbers are colored,
# and a screen title is content, not a marker. The "====" rules went with the
# color for the same reason — nothing else in the hub separates a screen from
# its content with a drawn rule, and the blank line below already does that job.
print_welcome() {
	printf '\n'
	printf 'GitHub CLI Account Manager\n'
	printf '\n'
	printf '  Show current GitHub auth, switch between logged-in accounts, or log in\n'
	printf '  a new one. Supports github.com and GitHub Enterprise.\n'
	printf '\n'
}

show_status() {
	printf '\n'
	log_info "Current GitHub authentication:"
	printf '\n'
	if [ "$AUTHED" = true ]; then
		if [ "$AMBIGUOUS" = true ]; then
			printf '  Active account: <ambiguous — several hosts active; pick below>\n'
		else
			printf '  Active account: %s\n' "$ACTIVE_LOGIN"
			printf '  Host:           %s\n' "$ACTIVE_HOST"
		fi
		printf '  Logged-in accounts:\n'
		# Star a row when gh marks it active OR it is the resolved active pair.
		# Match login AND host so a same-login row on another host is not
		# mis-starred.
		while IFS="$TAB" read -r r_host r_login r_act; do
			[ -n "$r_login" ] || continue
			if [ "$r_act" = "1" ] || { [ "$r_login" = "$ACTIVE_LOGIN" ] && [ "$r_host" = "$ACTIVE_HOST" ]; }; then
				printf '    * %s (%s) [active]\n' "$r_login" "$r_host"
			else
				printf '      %s (%s)\n' "$r_login" "$r_host"
			fi
		done < "$ACCT_TABLE"
	else
		printf '  (not authenticated to any host)\n'
	fi
	printf '\n'
}

# ===========================================================================
# Actions
# ===========================================================================

# do_switch — pick an already-logged-in account and switch to it via
# `gh auth switch --user <u> --hostname <h>` (fast, non-interactive).
# Returns 0 on a completed switch, 1 on error/cancel.
do_switch() {
	# Build the candidate list: every account EXCEPT the current active one.
	# Exclude by login AND host — a same-login account on a DIFFERENT host is a
	# legitimate switch target and must stay in the list.
	ds_list="$WORKDIR/candidates"
	: > "$ds_list"
	while IFS="$TAB" read -r c_host c_login _; do
		[ -n "$c_login" ] || continue
		[ "$c_login" = "$ACTIVE_LOGIN" ] && [ "$c_host" = "$ACTIVE_HOST" ] && continue
		printf '%s%s%s\n' "$c_login" "$TAB" "$c_host" >> "$ds_list"
	done < "$ACCT_TABLE"

	if [ ! -s "$ds_list" ]; then
		log_warning "No other logged-in accounts to switch to."
		log_info    "Use 'log in a new account' to add one."
		return 1
	fi

	printf '\n'
	log_info "Select an account to switch to:"
	printf '\n'
	ds_i=0
	while IFS="$TAB" read -r c_login c_host; do
		ds_i=$((ds_i + 1))
		printf '  %s %s (%s)\n' "$(number "$ds_i.")" "$c_login" "$c_host"
	done < "$ds_list"
	printf '\n'

	ds_total=$ds_i
	ds_retries=0
	ds_choice=""
	while [ "$ds_retries" -lt "$MAX_RETRIES" ]; do
		prompt_select "$ds_total"
		if ! IFS= read -r ds_choice; then
			log_error "No input; cancelling."
			return 1
		fi
		case "$ds_choice" in
			c|C|cancel) log_info "Cancelled."; return 1 ;;
		esac
		# Validate: a positive integer within range.
		case "$ds_choice" in
			''|*[!0-9]*) ds_ok=0 ;;
			*) [ "$ds_choice" -ge 1 ] && [ "$ds_choice" -le "$ds_total" ] && ds_ok=1 || ds_ok=0 ;;
		esac
		if [ "$ds_ok" -eq 1 ]; then
			break
		fi
		log_error "Invalid selection. Enter a number 1-$ds_total, or 'c'."
		ds_retries=$((ds_retries + 1))
		ds_choice=""
	done
	if [ -z "$ds_choice" ]; then
		log_error "Maximum retries reached; cancelling."
		return 1
	fi

	# Read the chosen line.
	ds_sel_login=$(awk -F"$TAB" -v n="$ds_choice" 'NR==n{print $1}' "$ds_list")
	ds_sel_host=$(awk  -F"$TAB" -v n="$ds_choice" 'NR==n{print $2}' "$ds_list")

	printf '\n'
	log_info "Switching to $ds_sel_login on $ds_sel_host ..."
	if gh auth switch --user "$ds_sel_login" --hostname "$ds_sel_host"; then
		log_success "Switched to $ds_sel_login ($ds_sel_host)."
		return 0
	fi
	log_error "gh auth switch failed for $ds_sel_login ($ds_sel_host)."
	return 1
}

# do_login — log in a brand-new account. `gh auth login` is inherently
# interactive (browser/device-code, TTY); we hand the terminal to gh and do
# NOT drive it. Returns 0 on success, 1 on failure/cancel.
do_login() {
	printf '\n'
	log_info "Starting 'gh auth login' — follow gh's interactive prompts."
	log_info "gh will ask whether to use github.com or a GitHub Enterprise host."
	printf '\n'

	# cd to HOME so gh never trips over an unreadable CWD; restore afterwards.
	dl_orig=$(pwd 2>/dev/null || printf '%s' "${HOME:-/}")
	cd "${HOME:-/}" 2>/dev/null || true

	dl_rc=0
	gh auth login || dl_rc=$?

	if [ -d "$dl_orig" ]; then
		cd "$dl_orig" 2>/dev/null || true
	fi

	if [ "$dl_rc" -eq 0 ]; then
		log_success "Login completed."
		return 0
	fi
	log_error "Login was cancelled or failed."
	return 1
}

# main_menu — the authenticated-state menu. Sets MENU_ACTION.
MENU_ACTION=""
main_menu() {
	MENU_ACTION=""
	printf '\n'
	log_info "What would you like to do?"
	printf '\n'
	printf '  %s Switch to another logged-in account\n' "$(number '1.')"
	printf '  %s Log in a new account\n'                "$(number '2.')"
	printf '  %s Keep the current account\n'            "$(number '3.')"
	printf '\n'

	mm_retries=0
	while [ "$mm_retries" -lt "$MAX_RETRIES" ]; do
		printf '  %s\n> ' "$(dim 'Select 1-3')"
		if ! IFS= read -r mm_choice; then
			log_error "No input; keeping the current account."
			MENU_ACTION=keep
			return 0
		fi
		case "$mm_choice" in
			1|switch) MENU_ACTION=switch; return 0 ;;
			2|login)  MENU_ACTION=login;  return 0 ;;
			3|keep|exit|q|Q) MENU_ACTION=keep; return 0 ;;
			*) log_error "Invalid choice. Enter 1, 2, or 3."
			   mm_retries=$((mm_retries + 1)) ;;
		esac
	done
	log_error "Maximum retries reached."
	MENU_ACTION=""
	return 1
}

# ===========================================================================
# Main
# ===========================================================================
main() {
	# 1. Preflight: gh must be installed.
	if ! check_command_exists gh; then
		log_error "GitHub CLI (gh) is not installed."
		log_info  "Install it from https://cli.github.com/ then re-run."
		return 1
	fi

	print_welcome
	log_success "gh found (version $(gh_version))."

	# 2. Resolve + show current auth.
	parse_auth
	show_status

	# 3. Not authenticated -> offer to log in.
	if [ "$AUTHED" != true ]; then
		if confirm_yn "No account is authenticated. Log in now?" "y"; then
			do_login || return 1
			parse_auth
			# A fresh login could itself land in an ambiguous multi-host state.
			if [ "$AMBIGUOUS" = true ] && ! resolve_ambiguous; then
				log_info "No changes made."
				return 0
			fi
			show_status
			[ "$AUTHED" = true ] || { log_error "Still not authenticated."; return 1; }
			return 0
		fi
		log_info "No changes made."
		return 0
	fi

	# 4. Authenticated but AMBIGUOUS -> the user picks the current account first
	#    (we never silently choose one). Declining leaves everything untouched.
	if [ "$AMBIGUOUS" = true ]; then
		if ! resolve_ambiguous; then
			log_info "No changes made."
			return 0
		fi
		show_status
	fi

	# 5. Authenticated -> menu.
	if ! main_menu; then
		return 1
	fi

	case "$MENU_ACTION" in
		switch)
			do_switch || return 1
			parse_auth
			show_status
			report_now_active
			return 0
			;;
		login)
			do_login || return 1
			parse_auth
			show_status
			report_now_active
			return 0
			;;
		keep)
			log_info "Keeping the current account: $ACTIVE_LOGIN ($ACTIVE_HOST)."
			return 0
			;;
		*)
			return 1
			;;
	esac
}

main
exit $?
