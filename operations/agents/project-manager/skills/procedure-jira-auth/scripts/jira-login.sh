#!/usr/bin/env sh
#
# jira-login.sh — USER-interactive Jira Cloud credential setup. The twin of
#                 procedure-git-auth's manage_gh_accounts.sh, but for Jira:
#                 there is no local CLI session to switch (Jira has no `gh`
#                 equivalent), so this script's whole job is to PROMPT for a
#                 site + email + API token and write them to a secure,
#                 per-site credential file this skill's siblings resolve
#                 (jira-auth-status.sh, jira-curl-config.sh) and the
#                 procedure-jira engine ultimately consumes via
#                 $JIRA_CURL_CONFIG.
#
# Purpose:
#   Prompts for:
#     1. Site   — e.g. "your-co.atlassian.net" (an "https://" prefix and/or
#                 trailing path are stripped; validated against the same
#                 host-shape allow-list procedure-jira's engine enforces at
#                 call time, so a credential can never be stored for a host
#                 the engine would refuse anyway).
#     2. Email  — the Atlassian account email the API token belongs to.
#     3. Token  — the Jira API token, read WITHOUT terminal echo.
#   and stores them as a curl -K config file (`user = "email:token"`),
#   `600`, under a private `700` directory — one file per site, so a user can
#   hold credentials for several Jira Cloud sites (e.g. your-team.atlassian.net
#   and another <client>.atlassian.net) at once. The FIRST site ever stored becomes the default
#   (see jira-accounts.sh to change it later).
#
#   This script NEVER calls Jira — it only writes the credential file. The
#   procedure-jira engine is the sole caller of the Jira API (the
#   credential-handoff interface is fixed before its consumer exists).
#
# Usage:
#   jira-login.sh [--site SITE] [-h|--help]
#     --site SITE   Skip the site prompt; validate + use this site directly.
#
# Storage:
#   ${JIRA_CRED_DIR:-$HOME/.claude/crucible/jira/credentials}/<site>.cfg
#   Directory created `700` (umask 077); each credential file written `600`
#   via an atomic write-then-rename in the SAME directory (no partial file is
#   ever visible at the final path). NEVER ~/.claude/settings.json.
#
#   Future enhancement (not implemented here): on macOS, prefer the Keychain
#   (`security add-generic-password`) over the `600` file. The file is kept
#   as the portable default across macOS/Linux; see the Security note below.
#
# Security:
#   - The token is read with terminal echo OFF (`stty -echo`, restored via a
#     trap even on Ctrl-C) and NEVER appears on argv, in a prompt echo, in
#     stdout/stderr, or in any log.
#   - The credential file is written via `mktemp` in the credential
#     directory (never a predictable name) under `umask 077`, then renamed
#     into place — no TOCTOU window where a partial/insecurely-permissioned
#     file is visible at the final path.
#   - Token-at-rest tier: `600` file (umask 077). This is the ARCH/plan's
#     designated portable default — OS keychain integration is a documented
#     future enhancement, not a silent downgrade (see Storage above).
#
# Exit codes:
#   0  credential stored (or the user reused the existing one unchanged)
#   1  error (write failure, stty unavailable and no fallback, cancelled)
#   2  usage error
#
# Portability: POSIX sh only (no bashisms — no [[ ]], arrays, `local`,
#   `read -p`, `read -s`). Runs identically on macOS (BSD userland / Bash
#   3.2) and Linux (GNU). The one OPTIONAL/interactive binary this script
#   touches — `stty` — is guarded with `command -v` and degrades gracefully
#   (falls back to a plain, echoing `read`) when absent or stdin isn't a
#   TTY. Every other external command used (sed, mktemp, mkdir, chmod, mv)
#   is a baseline POSIX coreutil, assumed present. Self-contained: sources
#   nothing.
#
set -eu

LC_ALL=C
export LC_ALL

PROG=${0##*/}
MAX_RETRIES=3

# ---------------------------------------------------------------------------
# Colors + logging (NO_COLOR-aware; disabled when stdout is not a TTY so
# piped/captured output stays clean). Same shape as manage_gh_accounts.sh.
# ---------------------------------------------------------------------------
if [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
	C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
else
	C_RESET=$(printf '\033[0m')
	C_RED=$(printf '\033[31m')
	C_GREEN=$(printf '\033[32m')
	C_YELLOW=$(printf '\033[93m')
	C_BLUE=$(printf '\033[34m')
fi

log_info()    { printf '%s[INFO]%s %s\n'  "$C_BLUE"   "$C_RESET" "$*"; }
log_success() { printf '%s[OK]%s %s\n'    "$C_GREEN"  "$C_RESET" "$*"; }
log_warning() { printf '%s[WARN]%s %s\n'  "$C_YELLOW" "$C_RESET" "$*" >&2; }
log_error()   { printf '%s[ERROR]%s %s\n' "$C_RED"    "$C_RESET" "$*" >&2; }

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
	cat <<EOF
Usage: $PROG [--site SITE] [-h|--help]

Interactive Jira Cloud credential setup. Prompts for a site, email, and API
token (token input is never echoed), then stores them as a private, per-site
credential file for procedure-jira-auth's siblings and the procedure-jira
engine to resolve.

Options:
  --site SITE   Skip the site prompt; validate and use this site directly.
  -h, --help    Show this help.

Storage: \${JIRA_CRED_DIR:-\$HOME/.claude/crucible/jira/credentials}/<site>.cfg
(600, directory 700). The token is never written to argv, stdout, stderr, or
any log, and never to ~/.claude/settings.json.

Exit codes:
  0  credential stored
  1  error / cancelled
  2  usage error
EOF
}

need_arg() {
	[ -n "${2:-}" ] || { usage >&2; log_error "option $1 requires an argument"; exit 2; }
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
OPT_SITE=""

while [ $# -gt 0 ]; do
	case "$1" in
		--site) need_arg "$1" "${2:-}"; OPT_SITE=$2; shift ;;
		-h|--help) usage; exit 0 ;;
		--) shift; break ;;
		-*) usage >&2; log_error "unknown option: $1"; exit 2 ;;
		*)  usage >&2; log_error "unexpected argument: $1"; exit 2 ;;
	esac
	shift
done
[ $# -eq 0 ] || { usage >&2; log_error "unexpected argument: $1"; exit 2; }

# ---------------------------------------------------------------------------
# Constants + credential-store layout (shared shape with jira-auth-status.sh,
# jira-curl-config.sh, jira-accounts.sh — each re-implements it inline, not
# sourced, per this repo's self-contained-script convention).
# ---------------------------------------------------------------------------
JIRA_HOST_ALLOWLIST_PATTERN=${JIRA_HOST_ALLOWLIST_PATTERN:-'*.atlassian.net'}
JIRA_CRED_DIR=${JIRA_CRED_DIR:-"$HOME/.claude/crucible/jira/credentials"}
DEFAULT_MARKER="$JIRA_CRED_DIR/default"

# normalize_site VALUE -> bare host (strips an optional http(s):// prefix and
# any path/query from the first "/" onward). Mirrors procedure-jira/jira.sh's
# normalize_site() exactly, so the two skills agree on what a "site" is.
normalize_site() {
	raw=$1
	host=$(printf '%s' "$raw" | sed -E 's#^[Hh][Tt][Tt][Pp][Ss]?://##')
	host=${host%%/*}
	printf '%s' "$host"
}

# assert_host_allowed HOST -> 0 if HOST is host-safe AND matches the
# configured allow-list glob, 1 otherwise. Character check FIRST — never let
# a "/" or other unsafe byte reach the glob or a later filename.
assert_host_allowed() {
	h=$1
	case "$h" in
		*[!A-Za-z0-9.-]*) return 1 ;;
	esac
	# shellcheck disable=SC2254  # deliberate glob match against the configured allow-list pattern, not a literal
	case "$h" in
		$JIRA_HOST_ALLOWLIST_PATTERN) return 0 ;;
		*) return 1 ;;
	esac
}

# cred_file_for_site SITE -> the credential file path for a (host-safe,
# already-validated) site.
cred_file_for_site() {
	printf '%s/%s.cfg' "$JIRA_CRED_DIR" "$1"
}

# ---------------------------------------------------------------------------
# Prompts
# ---------------------------------------------------------------------------

# confirm_yn PROMPT DEFAULT(y|n) -> 0=yes, 1=no. EOF fails SAFE (declines),
# never assumes the default, so an unattended run never silently proceeds.
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

# prompt_site -> sets SITE_HOST to a validated, normalized host. Retries on
# an empty or disallowed value; does not touch the credential store.
SITE_HOST=""
prompt_site() {
	ps_retries=0
	while [ "$ps_retries" -lt "$MAX_RETRIES" ]; do
		if [ -n "$OPT_SITE" ]; then
			ps_raw=$OPT_SITE
		else
			printf 'Jira site (e.g. your-co.atlassian.net): '
			if ! IFS= read -r ps_raw; then
				log_error "No input; cancelling."
				return 1
			fi
		fi
		ps_host=$(normalize_site "$ps_raw")
		if [ -z "$ps_host" ]; then
			log_error "Site must not be empty."
		elif ! assert_host_allowed "$ps_host"; then
			log_error "Site '$ps_host' is not in the allowed shape ($JIRA_HOST_ALLOWLIST_PATTERN)."
		else
			SITE_HOST=$ps_host
			return 0
		fi
		[ -n "$OPT_SITE" ] && { log_error "--site was invalid; cancelling."; return 1; }
		ps_retries=$((ps_retries + 1))
	done
	log_error "Maximum retries reached; cancelling."
	return 1
}

# prompt_email -> sets ACCOUNT_EMAIL to a non-empty, single-line, "@"-shaped
# value (a light sanity check — Jira itself is the source of truth for
# whether the address is real).
ACCOUNT_EMAIL=""
prompt_email() {
	pe_retries=0
	while [ "$pe_retries" -lt "$MAX_RETRIES" ]; do
		printf 'Account email: '
		if ! IFS= read -r pe_raw; then
			log_error "No input; cancelling."
			return 1
		fi
		case "$pe_raw" in
			*@*[!@]*) ACCOUNT_EMAIL=$pe_raw; return 0 ;;
			*) log_error "Enter a valid-looking email (must contain '@')." ;;
		esac
		pe_retries=$((pe_retries + 1))
	done
	log_error "Maximum retries reached; cancelling."
	return 1
}

# stty_echo_off / stty_echo_on — best-effort terminal-echo control. If `stty`
# is unavailable or stdin is not a TTY, we warn and fall back to a plain
# `read` rather than failing outright (an agent-driven/non-TTY caller still
# needs a path through, even though the token would then be visible on that
# non-interactive stream — which is the caller's own terminal/pipe, not this
# script leaking it via argv/logs/stdout).
STTY_SAVED=0
stty_echo_off() {
	if command -v stty >/dev/null 2>&1 && [ -t 0 ]; then
		stty -echo 2>/dev/null && STTY_SAVED=1
	fi
}
stty_echo_on() {
	if [ "$STTY_SAVED" -eq 1 ]; then
		stty echo 2>/dev/null || true
		STTY_SAVED=0
	fi
}

# PENDING_TMP_FILE — the path of a `mktemp`-created file between its
# creation and the `mv` that gives it its final name. store_credential() and
# set_default_if_unset() set this right after mktemp and clear it right
# after a successful mv — so an interrupt (Ctrl-C) landing in that narrow
# window still gets the orphaned tempfile removed by the trap below, instead
# of leaving a stray credential-shaped file behind in $JIRA_CRED_DIR.
PENDING_TMP_FILE=""

# cleanup_on_exit — the ONE trap for this script (a second `trap ... EXIT`
# would silently replace the first, so both exit-time duties — restoring
# terminal echo AND removing any orphaned tempfile — live in a single
# function). Runs on ANY exit path: normal return, error, or Ctrl-C.
# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup_on_exit() {
	stty_echo_on
	if [ -n "$PENDING_TMP_FILE" ] && [ -f "$PENDING_TMP_FILE" ]; then
		rm -f "$PENDING_TMP_FILE"
	fi
}
trap cleanup_on_exit EXIT INT TERM

# prompt_token -> sets API_TOKEN. Echo is disabled for the read; the raw
# value is NEVER printed, logged, or echoed back — not even masked.
API_TOKEN=""
prompt_token() {
	pt_retries=0
	while [ "$pt_retries" -lt "$MAX_RETRIES" ]; do
		printf 'API token (input hidden): '
		stty_echo_off
		if ! IFS= read -r pt_raw; then
			stty_echo_on
			printf '\n'
			log_error "No input; cancelling."
			return 1
		fi
		stty_echo_on
		printf '\n'
		if [ -n "$pt_raw" ]; then
			API_TOKEN=$pt_raw
			return 0
		fi
		log_error "Token must not be empty."
		pt_retries=$((pt_retries + 1))
	done
	log_error "Maximum retries reached; cancelling."
	return 1
}

# ---------------------------------------------------------------------------
# curl_config_escape VALUE -> VALUE with backslash escaped FIRST, then the
# double quote — curl's -K config quoted-string escaping. Same rule (and
# order) as procedure-jira/jira.sh's curl_config_escape().
# ---------------------------------------------------------------------------
curl_config_escape() {
	printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# ---------------------------------------------------------------------------
# store_credential — atomically write the curl-config credential file for
# $SITE_HOST from $ACCOUNT_EMAIL/$API_TOKEN. `umask 077` covers BOTH the
# directory creation and the tempfile (belt-and-braces with the explicit
# chmod calls below, which hold even if the umask is somehow not honored by
# a nonstandard mkdir/mktemp). Write-then-rename in the SAME directory means
# the final path never has a readable-then-fixed-later window.
# ---------------------------------------------------------------------------
store_credential() {
	NL='
'
	case "$ACCOUNT_EMAIL" in *"$NL"*) log_error "email must not contain a newline"; return 1 ;; esac
	case "$API_TOKEN" in *"$NL"*) log_error "token must not contain a newline"; return 1 ;; esac

	old_umask=$(umask)
	umask 077
	mkdir -p "$JIRA_CRED_DIR"
	chmod 700 "$JIRA_CRED_DIR"

	sc_tmp=$(mktemp "$JIRA_CRED_DIR/.jira-login.XXXXXX") || { umask "$old_umask"; log_error "could not create a temp file in $JIRA_CRED_DIR"; return 1; }
	umask "$old_umask"
	chmod 600 "$sc_tmp"
	PENDING_TMP_FILE=$sc_tmp

	sc_esc_email=$(curl_config_escape "$ACCOUNT_EMAIL")
	sc_esc_token=$(curl_config_escape "$API_TOKEN")
	printf 'user = "%s:%s"\n' "$sc_esc_email" "$sc_esc_token" >"$sc_tmp"

	sc_dest=$(cred_file_for_site "$SITE_HOST")
	mv -f "$sc_tmp" "$sc_dest"
	PENDING_TMP_FILE=""
	chmod 600 "$sc_dest"
}

# set_default_if_unset — the FIRST site ever stored becomes the default (a
# bootstrap convenience); later logins never silently steal the default —
# that is jira-accounts.sh's job.
set_default_if_unset() {
	if [ ! -f "$DEFAULT_MARKER" ]; then
		old_umask=$(umask)
		umask 077
		sd_tmp=$(mktemp "$JIRA_CRED_DIR/.jira-default.XXXXXX") || { umask "$old_umask"; log_error "could not create a temp file in $JIRA_CRED_DIR"; return 1; }
		umask "$old_umask"
		chmod 600 "$sd_tmp"
		PENDING_TMP_FILE=$sd_tmp
		printf '%s\n' "$SITE_HOST" >"$sd_tmp"
		mv -f "$sd_tmp" "$DEFAULT_MARKER"
		PENDING_TMP_FILE=""
		chmod 600 "$DEFAULT_MARKER"
		log_info "'$SITE_HOST' set as the default site (change it with jira-accounts.sh set-default)."
	fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
	printf '\n'
	printf '===============================================================================\n'
	printf '  %sJira Credential Setup%s\n' "$C_BLUE" "$C_RESET"
	printf '===============================================================================\n'
	printf '\n'
	printf '  Stores an API token for one Jira Cloud site. Run again for another site.\n'
	printf '\n'

	prompt_site || return 1

	existing=$(cred_file_for_site "$SITE_HOST")
	if [ -f "$existing" ]; then
		log_warning "A credential is already stored for '$SITE_HOST'."
		if ! confirm_yn "Overwrite it?" "n"; then
			log_info "No changes made."
			return 0
		fi
	fi

	prompt_email || return 1
	prompt_token || return 1

	store_credential || return 1
	set_default_if_unset

	log_success "Credential stored for '$SITE_HOST' ($ACCOUNT_EMAIL) at $(cred_file_for_site "$SITE_HOST")."
	return 0
}

main
exit $?
