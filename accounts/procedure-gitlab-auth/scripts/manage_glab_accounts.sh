#!/usr/bin/env sh
#
# manage_glab_accounts.sh — USER-interactive GitLab CLI account manager.
#
# Purpose:
#   The one step of the GitLab account auth gate a HUMAN drives. It shows the
#   current `glab` auth state, then lets the user authenticate — either against
#   a SPECIFIC instance (`glab auth login --hostname <h>`, for a self-managed
#   host or to replace the credential of a host already configured) or via
#   glab's own interactive host detection (`glab auth login`) — or keep what is
#   already configured.
#
#   WHY THERE IS NO "SWITCH" MENU ROW (the one real divergence from the sibling
#   manage_gh_accounts.sh): `glab auth` has NO `switch` subcommand. Verified
#   against glab 1.112.0 — `glab auth` offers exactly configure-docker,
#   docker-helper, dpop-gen, login, logout, status. glab stores ONE credential
#   per GitLab instance, so "switch to another already-logged-in account" is not
#   a state glab can be put into the way `gh auth switch --user` can; the
#   equivalent act is authenticating that instance (row 1). Faking a switch —
#   e.g. by rewriting the `host` config key — would move a DIFFERENT setting
#   (glab's default instance) while the account gate resolves accounts per host
#   anyway, so it would report a change it did not make. The gate's way to pick
#   one of several configured accounts is `glab-auth-status.sh --hostname HOST`,
#   not a mutation here.
#
#   The agent NEVER parses this script's output — it re-runs glab-auth-status.sh
#   afterwards to learn the result. This script only drives the human.
#
# Usage:
#   manage_glab_accounts.sh [-h|--help]
#   (No operands — interactive.)
#
# Exit codes:
#   0  a login completed, OR the user chose to keep the current account
#   1  error, or the user cancelled
#
# Portability: POSIX sh only (no bashisms — no [[ ]], arrays, `local`, (( )),
#   shopt, BASH_SOURCE, `read -p`). Runs identically on macOS (BSD userland /
#   Bash 3.2) and Linux (GNU). shellcheck-clean. SELF-CONTAINED: it sources
#   NOTHING (not the hub's render library, not the sibling GitHub scripts).
#
set -eu

LC_ALL=C
export LC_ALL

# Pin glab's optional chatter out of the way so the screens this script draws
# stay predictable. GLAB_NO_PROMPT is deliberately NOT set here (unlike the
# non-interactive glab-auth-status.sh): `glab auth login` MUST be able to prompt
# — driving that prompt is this script's entire purpose.
GLAB_CHECK_UPDATE=false
GLAB_SHOW_WHATS_NEW=false
export GLAB_CHECK_UPDATE GLAB_SHOW_WHATS_NEW

PROG=${0##*/}
MAX_RETRIES=3

# ===========================================================================
# Inline reimplementation of the small logging / prompting / tool-check helpers
# this screen needs. Kept minimal + POSIX.
# ===========================================================================

# ---------------------------------------------------------------------------
# Rendering legend — glyphs, colors and prompt furniture.
#
# The VALUES and glyph choices below deliberately mirror the Crucible
# Management Hub's lib/hub-render.sh one for one (HUB_OK_COLOR, HUB_FAIL_COLOR,
# HUB_WARN_COLOR, HUB_NUMBER_COLOR, HUB_DIM_COLOR, HUB_HINT_KEY_COLOR and the
# ✓/✗/! glyphs), so this screen looks like the menu that launched it. They are
# RE-DECLARED here and NOT sourced from that file — nor from the sibling
# manage_gh_accounts.sh, which carries the identical block — for the reason this
# script's own header states: it ships inside the procedure-gitlab-auth skill
# and is run directly by agents as their account-confirmation gate, so it must
# keep working with no hub present. The cost of that independence is this
# duplication; the rule for it is that the values here only ever move to MATCH
# the hub's.
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

# Colors: honour NO_COLOR, checked by PRESENCE alone — deliberately STRICTER
# than no-color.org itself (which disables color only when NO_COLOR is present
# AND non-empty), so this agrees with the hub's own hub_color_enabled rather
# than with the spec's letter: an empty NO_COLOR="" still disables color here,
# same as there. Also honour the hub's own HUB_NO_COLOR when this script runs
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

# Logging: INFO/SUCCESS -> stdout, WARNING/ERROR -> stderr. The severity is
# carried by a COLORED GLYPH rather than a bracketed [LEVEL] tag, which is what
# aligns this script with the hub. log_info deliberately gets neither glyph nor
# color: an informational line is the screen's ordinary content, so a marker on
# it would only compete with the three that mean something.
log_info()    { printf '%s\n' "$*"; }
log_success() { printf '%s%s%s %s\n' "$C_OK"   "$GLYPH_OK"   "$C_RESET" "$*"; }
log_warning() { printf '%s%s%s %s\n' "$C_WARN" "$GLYPH_WARN" "$C_RESET" "$*" >&2; }
log_error()   { printf '%s%s%s %s\n' "$C_FAIL" "$GLYPH_FAIL" "$C_RESET" "$*" >&2; }

# check_command_exists <cmd> — 0 if on PATH, 1 otherwise.
check_command_exists() { command -v "$1" >/dev/null 2>&1; }

# glab_version — best-effort version string for the banner, "unknown" on
# failure. `glab --version` prints e.g. "glab 1.112.0 (816e3a52)".
glab_version() {
	gv=$(glab --version 2>/dev/null | head -n 1 | awk '{print $2}' || true)
	printf '%s' "${gv:-unknown}"
}

# is_valid_hostname VALUE — allow-list for a hostname the USER types, before it
# becomes a `glab auth login --hostname` argument: letters, digits, '.', '-',
# '_' and an optional ':port'. Rejects whitespace, shell metacharacters, a
# leading '-' (which glab's flag parser would read as another flag) and any
# empty label. It is a fail-fast usability guard, not the injection defense —
# the value travels as ONE argv token and is never re-interpreted by a shell.
is_valid_hostname() {
	case "$1" in
		'') return 1 ;;
		*[!A-Za-z0-9._:-]*) return 1 ;;
		-*) return 1 ;;
		.*|*.|*..*) return 1 ;;
		*) return 0 ;;
	esac
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

Interactive GitLab CLI account manager. Shows the current auth state, then lets
you authenticate a SPECIFIC instance (--hostname) or use glab's own interactive
host detection. Supports gitlab.com and self-managed GitLab instances.

There is no "switch account" action: glab has no 'auth switch' subcommand and
keeps one credential per instance — authenticating the instance IS the switch.

Exit codes:
  0  a login completed, or you kept the current account
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
WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/glab-accounts.XXXXXX") || {
	log_error "could not create a temporary working directory"
	exit 1
}
# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT INT TERM

ACCT_TABLE="$WORKDIR/accounts"    # "host<TAB>login" per line

# ===========================================================================
# parse_auth — run `glab auth status`, populate:
#   AUTHED (true|false), MULTI (true|false), ACTIVE_LOGIN, ACTIVE_HOST,
#   and $ACCT_TABLE.
#
# The account is PER HOST: glab keeps one credential per instance. When MORE
# THAN ONE account is configured we set MULTI=true and leave ACTIVE_LOGIN/HOST
# empty — there is no glab state saying which of them is "the" active one, so
# claiming one would be a guess. The gate resolves that case with
# `glab-auth-status.sh --hostname HOST`, not here.
#
# Same keyword-anchored parse as glab-auth-status.sh (duplicated on purpose so
# this file stays standalone — no sourcing). `--all` is what enumerates every
# configured instance; a bare `glab auth status` reports only the current
# context's instance, so it is used solely as the fallback for a glab old enough
# to lack `--all`.
# ===========================================================================
AUTHED=false
MULTI=false
ACTIVE_LOGIN=""
ACTIVE_HOST=""

parse_auth_records() {
	printf '%s\n' "$1" | awk '
		/Logged in to /{
			host=""; login=""
			for (i = 1; i <= NF; i++) {
				if      ($i == "to") host  = $(i + 1)
				else if ($i == "as") login = $(i + 1)
			}
			if (host == "" || login == "") next
			key = host "\t" login
			if (key in seen) next
			seen[key] = 1
			printf "%s\t%s\n", host, login
		}
	'
}

parse_auth() {
	AUTHED=false
	MULTI=false
	ACTIVE_LOGIN=""
	ACTIVE_HOST=""
	: > "$ACCT_TABLE"

	pa_out=$(glab auth status --all 2>&1 || true)
	parse_auth_records "$pa_out" > "$ACCT_TABLE"
	if [ ! -s "$ACCT_TABLE" ]; then
		pa_out=$(glab auth status 2>&1 || true)
		parse_auth_records "$pa_out" > "$ACCT_TABLE"
	fi
	[ -s "$ACCT_TABLE" ] || return 0
	AUTHED=true

	pa_count=$(awk 'END { print NR }' "$ACCT_TABLE")
	if [ "$pa_count" -gt 1 ]; then
		MULTI=true
		return 0
	fi
	IFS="$TAB" read -r ACTIVE_HOST ACTIVE_LOGIN < "$ACCT_TABLE" || true
}

# report_now_active — post-action summary that stays honest under MULTI.
report_now_active() {
	if [ "$MULTI" = true ]; then
		log_success "Done. Several accounts are configured (glab keeps one credential per instance)."
		log_info    "The account gate must pick one: glab-auth-status.sh --hostname HOST."
	else
		log_success "Now active: $ACTIVE_LOGIN ($ACTIVE_HOST)."
	fi
}

# ===========================================================================
# UI helpers
# ===========================================================================
#
# The title is PLAIN, UNCOLORED text at column 0 and carries no rule lines above
# or below it — the hub's hub_print_header shape exactly. In this hub only
# glyphs, typeable keys and numbers are colored, and a screen title is content,
# not a marker.
print_welcome() {
	printf '\n'
	printf 'GitLab CLI Account Manager\n'
	printf '\n'
	printf '  Show current GitLab auth and log in to a GitLab instance. Supports\n'
	printf '  gitlab.com and self-managed instances.\n'
	printf '\n'
}

show_status() {
	printf '\n'
	log_info "Current GitLab authentication:"
	printf '\n'
	if [ "$AUTHED" = true ]; then
		if [ "$MULTI" = true ]; then
			printf '  Active account: <several accounts configured — one credential per instance>\n'
		else
			printf '  Active account: %s\n' "$ACTIVE_LOGIN"
			printf '  Host:           %s\n' "$ACTIVE_HOST"
		fi
		printf '  Logged-in accounts:\n'
		# Star a row when it is the resolved active pair. Match login AND host
		# so a same-login row on another host is not mis-starred.
		while IFS="$TAB" read -r r_host r_login; do
			[ -n "$r_login" ] || continue
			if [ "$r_login" = "$ACTIVE_LOGIN" ] && [ "$r_host" = "$ACTIVE_HOST" ]; then
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

# run_glab_login [HOST] — hand the terminal to `glab auth login`, against HOST
# when one is given (`--hostname HOST`) and against glab's own interactive host
# detection when it is omitted or empty. It is inherently interactive (token entry
# / browser / device code, TTY); we do NOT drive it. The argv is built as
# POSITIONAL PARAMETERS (POSIX sh's array equivalent), never a concatenated
# string, so a user-typed hostname travels as one argv value straight into execve.
#
# The host is a real POSITIONAL ARGUMENT, not an implicit global every caller has
# to remember to set first: the header used to document `[--hostname HOST]` while
# the function took no arguments at all, so following that documented signature
# would have had the argument SILENTLY DISCARDED and the login run against
# whatever host glab auto-detected.
#
# Unlike the GitHub sibling, this does NOT cd to $HOME first: glab detects
# candidate instances from the CURRENT repository's git remotes, which is
# genuinely useful here — so the cwd is left alone and only replaced when it is
# unusable (a deleted/unreadable directory would make glab fail on startup).
run_glab_login() {
	rgl_hostname=${1:-}

	if ! pwd >/dev/null 2>&1; then
		cd "${HOME:-/}" || {
			log_error "current directory is unusable and HOME is not reachable"
			return 1
		}
	fi

	set -- glab auth login
	[ -z "$rgl_hostname" ] || set -- "$@" --hostname "$rgl_hostname"

	rgl_rc=0
	"$@" || rgl_rc=$?

	if [ "$rgl_rc" -eq 0 ]; then
		log_success "Login completed."
		return 0
	fi
	log_error "Login was cancelled or failed."
	return 1
}

# do_login — log in via glab's own interactive host detection (no --hostname).
do_login() {
	printf '\n'
	log_info "Starting 'glab auth login' — follow glab's interactive prompts."
	log_info "glab will ask which instance to use (it suggests hosts from your git remotes)."
	printf '\n'
	run_glab_login
}

# ---------------------------------------------------------------------------
# do_login_host's three steps, extracted (it was ~80 lines and five
# responsibilities). Each RETURNS 0/1 and hands its result back through ONE
# documented global — the same shape main_menu already uses with MENU_ACTION, and
# NOT via `$(...)` command substitution: these functions PROMPT on stdout, and a
# command substitution would capture the prompt instead of showing it to the human
# this whole script exists to drive.
#
# The exit status, not a sentinel value, is what says "no choice was made". The
# retry loop used to sit inline in do_login_host and signalled that by leaving a
# sentinel EMPTY variable behind for the code below it to notice — a convention
# nothing enforced, so any edit that forgot to re-blank it on the retry path would
# have made an invalid answer look like a valid one.
# ---------------------------------------------------------------------------
HOST_COUNT=0      # set by list_configured_hosts
NUMERIC_CHOICE="" # set by read_numeric_choice
NEW_HOSTNAME=""   # set by prompt_new_hostname

# list_configured_hosts FILE — write the DISTINCT configured hosts (in glab's
# output order) to FILE, print the numbered menu for them plus the trailing
# "Enter a different hostname" row, and set HOST_COUNT to the number of HOSTS. The
# count of selectable rows is HOST_COUNT + 1 (the "different hostname" row is
# always last), which is the only arithmetic the caller needs.
list_configured_hosts() {
	lch_list=$1
	: > "$lch_list"
	awk -F"$TAB" '!seen[$1]++ { print $1 }' "$ACCT_TABLE" > "$lch_list"

	printf '\n'
	log_info "Select the GitLab instance to authenticate:"
	printf '\n'
	HOST_COUNT=0
	while IFS= read -r c_host; do
		[ -n "$c_host" ] || continue
		HOST_COUNT=$((HOST_COUNT + 1))
		printf '  %s %s\n' "$(number "$HOST_COUNT.")" "$c_host"
	done < "$lch_list"
	printf '  %s Enter a different hostname\n' "$(number "$((HOST_COUNT + 1)).")"
	printf '\n'
}

# read_numeric_choice TOTAL — prompt until the user types an integer in 1..TOTAL,
# set NUMERIC_CHOICE to it and return 0. Returns 1 when the user cancels, EOF
# arrives, or MAX_RETRIES invalid answers are given — the three outcomes that all
# mean "no choice was made".
#
# Deliberately NOT used by main_menu, which offers a different alias set (1/2/3
# plus host/login/keep, and no `c`) and keeps its own loop.
read_numeric_choice() {
	rnc_total=$1
	rnc_retries=0
	NUMERIC_CHOICE=""
	while [ "$rnc_retries" -lt "$MAX_RETRIES" ]; do
		prompt_select "$rnc_total"
		if ! IFS= read -r rnc_answer; then
			log_error "No input; cancelling."
			return 1
		fi
		case "$rnc_answer" in
			c|C|cancel) log_info "Cancelled."; return 1 ;;
		esac
		# Validate: a positive integer within range.
		case "$rnc_answer" in
			''|*[!0-9]*) : ;;
			*)
				if [ "$rnc_answer" -ge 1 ] && [ "$rnc_answer" -le "$rnc_total" ]; then
					NUMERIC_CHOICE=$rnc_answer
					return 0
				fi ;;
		esac
		log_error "Invalid selection. Enter a number 1-$rnc_total, or 'c'."
		rnc_retries=$((rnc_retries + 1))
	done
	log_error "Maximum retries reached; cancelling."
	return 1
}

# prompt_new_hostname — ask for a hostname the user types, set NEW_HOSTNAME to it
# and return 0. Returns 1 on cancel or EOF.
#
# The `c: cancel` alternative is offered here for the same reason prompt_select
# offers it on the host list — and, critically, it is HANDLED before any validator
# runs. Without that case, a user who types the `c` the previous prompt just
# advertised would have it accepted as a literal hostname (it passes
# is_valid_hostname), and `glab auth login --hostname c` would persist a bogus
# host.
prompt_new_hostname() {
	NEW_HOSTNAME=""
	printf '  %s%s%s\n> ' "$(dim 'Hostname (e.g. gitlab.example.com)')" "$SEP" "$(hint_segment c cancel)"
	if ! IFS= read -r pnh_answer; then
		log_error "No input; cancelling."
		return 1
	fi
	case "$pnh_answer" in
		c|C|cancel) log_info "Cancelled."; return 1 ;;
	esac
	NEW_HOSTNAME=$pnh_answer
}

# do_login_host — pick the instance FIRST (one of the already-configured hosts,
# or a hostname the user types), then log in against it with --hostname. This is
# the row that stands where manage_gh_accounts.sh offers `gh auth switch`: for
# glab, re-authenticating an instance is the only way to change which credential
# acts on it. Returns 0 on a completed login, 1 on error/cancel.
#
# Reads top-down as list -> choose -> resolve -> login; the first three steps are
# the named helpers above, so this function holds the SEQUENCE and nothing else.
do_login_host() {
	dh_list="$WORKDIR/hosts"

	list_configured_hosts "$dh_list"
	read_numeric_choice "$((HOST_COUNT + 1))" || return 1

	if [ "$NUMERIC_CHOICE" -le "$HOST_COUNT" ]; then
		dh_host=$(awk -v n="$NUMERIC_CHOICE" 'NR==n { print $0 }' "$dh_list")
	else
		prompt_new_hostname || return 1
		dh_host=$NEW_HOSTNAME
	fi

	if ! is_valid_hostname "$dh_host"; then
		log_error "Not a usable hostname: $dh_host"
		return 1
	fi

	printf '\n'
	log_info "Starting 'glab auth login --hostname $dh_host' — follow glab's prompts."
	printf '\n'
	run_glab_login "$dh_host"
}

# main_menu — the authenticated-state menu. Sets MENU_ACTION.
#
# EVERY ACCEPTED TOKEN IS ADVERTISED: the number, and the one mnemonic word per
# row. The keep row used to also answer to `exit`, `q` and `Q`, none of which the
# "Select 1-3" prompt line ever mentioned — three extra spellings of the row a
# user can already reach by typing its number or its name, unfindable except by
# reading this source. They are gone rather than promoted onto the prompt line:
# `q` here would read as "quit", and this script's documented 0/1 exit-code
# contract (see its header, usage() and the skill's SKILL.md) makes "keep the
# current account" a 0-exit success, not a quit.
MENU_ACTION=""
main_menu() {
	MENU_ACTION=""
	printf '\n'
	log_info "What would you like to do?"
	printf '\n'
	printf '  %s Authenticate a specific instance (pick a host, or enter a new one)\n' "$(number '1.')"
	printf '  %s Log in with glab'"'"'s own interactive host detection\n'                "$(number '2.')"
	printf '  %s Keep the current account\n'                                            "$(number '3.')"
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
			1|host)   MENU_ACTION=host;  return 0 ;;
			2|login)  MENU_ACTION=login; return 0 ;;
			3|keep) MENU_ACTION=keep; return 0 ;;
			*) log_error "Invalid choice. Enter 1, 2, or 3."
			   mm_retries=$((mm_retries + 1)) ;;
		esac
	done
	log_error "Maximum retries reached."
	MENU_ACTION=""
	return 1
}

# report_keep — the honest "nothing changed" summary for the keep branch.
report_keep() {
	if [ "$MULTI" = true ]; then
		log_info "Keeping the current configuration; several accounts remain configured."
		log_info "The account gate must pick one: glab-auth-status.sh --hostname HOST."
	else
		log_info "Keeping the current account: $ACTIVE_LOGIN ($ACTIVE_HOST)."
	fi
}

# ===========================================================================
# Main
# ===========================================================================
main() {
	# 1. Preflight: glab (and awk, which does the parsing) must be installed.
	if ! check_command_exists glab; then
		log_error "GitLab CLI (glab) is not installed."
		log_info  "Install it from https://gitlab.com/gitlab-org/cli then re-run."
		return 1
	fi
	if ! check_command_exists awk; then
		log_error "awk is not installed (required to parse glab auth status)."
		return 1
	fi

	print_welcome
	log_success "glab found (version $(glab_version))."

	# 2. Resolve + show current auth.
	parse_auth
	show_status

	# 3. Not authenticated -> offer to log in.
	if [ "$AUTHED" != true ]; then
		if confirm_yn "No account is authenticated. Log in now?" "y"; then
			do_login || return 1
			parse_auth
			show_status
			[ "$AUTHED" = true ] || { log_error "Still not authenticated."; return 1; }
			return 0
		fi
		log_info "No changes made."
		return 0
	fi

	# 4. Authenticated -> menu.
	if ! main_menu; then
		return 1
	fi

	case "$MENU_ACTION" in
		host)
			do_login_host || return 1
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
			report_keep
			return 0
			;;
		*)
			return 1
			;;
	esac
}

main
exit $?
