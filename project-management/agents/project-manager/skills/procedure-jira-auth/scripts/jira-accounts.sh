#!/usr/bin/env sh
#
# jira-accounts.sh — list configured Jira sites and manage which one is the
#                     default, so a user holding credentials for several
#                     Jira Cloud sites (e.g. your-team.atlassian.net and
#                     another <client>.atlassian.net) can
#                     switch which one jira-auth-status.sh/jira-curl-config.sh
#                     resolve to when no --site is given. Non-interactive,
#                     agent-friendly (no prompts) — the interactive half of
#                     credential setup is jira-login.sh.
#
# Usage:
#   jira-accounts.sh list                       [--json]
#   jira-accounts.sh default
#   jira-accounts.sh set-default --site SITE
#   jira-accounts.sh remove       --site SITE --force
#   jira-accounts.sh -h|--help
#
# Subcommands:
#   list          Print every configured site (sorted) and mark the default.
#   default       Print the current default site (fails if none is set).
#   set-default   Make SITE the default. Fails closed if SITE has no stored
#                 credential (never points the default at a site that isn't
#                 actually configured).
#   remove        Delete the stored credential for SITE. Destructive —
#                 requires --force. Clears the default marker if SITE was
#                 the default (never leaves a dangling default).
#
# Output: a human-readable line/block plus machine-parseable
#   JIRA_ACCOUNTS_*=VALUE lines. The token is NEVER read or printed by this
#   script — it only ever touches credential FILE NAMES and the default
#   marker, never file contents.
#
# Exit codes:
#   0  success
#   1  no sites configured / SITE not configured / no default set / a
#      filesystem error
#   2  usage error (unknown subcommand, missing --site, remove without
#      --force)
#
# Portability: POSIX sh only (no bashisms). Runs identically on macOS (BSD
#   userland / Bash 3.2) and Linux (GNU coreutils). This script touches no
#   optional/interactive binary — every external command it uses (sed, cat,
#   sort, tr, mkdir, mktemp, chmod, mv, rm) is a baseline POSIX coreutil,
#   assumed present; there is nothing here for `command -v` to usefully
#   guard. Self-contained: sources nothing.
#
set -eu

LC_ALL=C
export LC_ALL

PROG=${0##*/}

warn()  { printf '%s: warning: %s\n' "$PROG" "$*" >&2; }
error() { printf '%s: error: %s\n'   "$PROG" "$*" >&2; }

# PENDING_TMP_FILE — the path of a `mktemp`-created file between its
# creation and the `mv` that gives it its final name (write_default()). An
# interrupt (Ctrl-C) landing in that window must not orphan the tempfile.
PENDING_TMP_FILE=""
# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup_on_exit() {
	if [ -n "$PENDING_TMP_FILE" ] && [ -f "$PENDING_TMP_FILE" ]; then
		rm -f "$PENDING_TMP_FILE"
	fi
}
trap cleanup_on_exit EXIT INT TERM

usage() {
	cat <<EOF
Usage:
  $PROG list                     [--json]
  $PROG default
  $PROG set-default --site SITE
  $PROG remove       --site SITE --force
  $PROG -h|--help

Manage which configured Jira site is the default. Credentials are stored by
jira-login.sh; this script never reads or prints a token.

Exit codes:
  0  success
  1  no sites configured / SITE not configured / no default set
  2  usage error
EOF
}

need_arg() {
	[ -n "${2:-}" ] || { usage >&2; error "option $1 requires an argument"; exit 2; }
}

# ---------------------------------------------------------------------------
# Credential-store layout (shared shape with the sibling scripts — each
# re-implements it inline, not sourced).
# ---------------------------------------------------------------------------
JIRA_HOST_ALLOWLIST_PATTERN=${JIRA_HOST_ALLOWLIST_PATTERN:-'*.atlassian.net'}
JIRA_CRED_DIR=${JIRA_CRED_DIR:-"$HOME/.claude/crucible/jira/credentials"}
DEFAULT_MARKER="$JIRA_CRED_DIR/default"

normalize_site() {
	raw=$1
	host=$(printf '%s' "$raw" | sed -E 's#^[Hh][Tt][Tt][Pp][Ss]?://##')
	host=${host%%/*}
	printf '%s' "$host"
}

# assert_host_allowed HOST -> 0 if HOST is host-safe AND matches the
# configured allow-list glob, 1 otherwise. Defense-in-depth:
# re-checked at this SINK (set-default/remove take a caller-supplied
# --site), not just at jira-login.sh's write time.
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

cred_file_for_site() {
	printf '%s/%s.cfg' "$JIRA_CRED_DIR" "$1"
}

# list_sites -> newline-separated, sorted list of every configured site on
# stdout (empty output if none). Never touches file CONTENTS.
list_sites() {
	if [ -d "$JIRA_CRED_DIR" ]; then
		for f in "$JIRA_CRED_DIR"/*.cfg; do
			[ -e "$f" ] || continue
			base=${f##*/}
			printf '%s\n' "${base%.cfg}"
		done | sort
	fi
}

# current_default -> prints the default site on stdout (nothing if unset).
# ALWAYS returns 0 — "no default configured" is a normal, expected state,
# never an error. Without the explicit `return 0`, the function's exit
# status would be that of `[ -f "$DEFAULT_MARKER" ]` (1 when absent), and
# every caller assigns its output via `def=$(current_default)` — a failing
# command substitution IS "set -e"-fatal for a plain assignment (unlike the
# well-known `local x=$(cmd)` status-swallowing trap, this is the opposite:
# nothing swallows it here), which would silently kill the whole script
# before it ever prints its own diagnostic.
current_default() {
	if [ -f "$DEFAULT_MARKER" ]; then
		sed -n '1p' "$DEFAULT_MARKER"
	fi
	return 0
}

# write_default SITE — atomic write-then-rename, 600, same directory (no
# TOCTOU window at the final path). Mirrors jira-login.sh's own pattern.
write_default() {
	old_umask=$(umask)
	umask 077
	mkdir -p "$JIRA_CRED_DIR"
	chmod 700 "$JIRA_CRED_DIR"
	wd_tmp=$(mktemp "$JIRA_CRED_DIR/.jira-default.XXXXXX") || { umask "$old_umask"; error "could not create a temp file"; return 1; }
	umask "$old_umask"
	chmod 600 "$wd_tmp"
	PENDING_TMP_FILE=$wd_tmp
	printf '%s\n' "$1" >"$wd_tmp"
	mv -f "$wd_tmp" "$DEFAULT_MARKER"
	PENDING_TMP_FILE=""
	chmod 600 "$DEFAULT_MARKER"
}

# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------

cmd_list() {
	opt_json=0
	while [ $# -gt 0 ]; do
		case "$1" in
			--json) opt_json=1 ;;
			-h|--help) usage; exit 0 ;;
			*) usage >&2; error "unknown option to 'list': $1"; exit 2 ;;
		esac
		shift
	done

	sites=$(list_sites)
	def=$(current_default)
	csv=$(printf '%s\n' "$sites" | tr '\n' ',' )
	csv=${csv%,}

	if [ "$opt_json" -eq 1 ]; then
		# Built via a heredoc (not `cmd | while read`) so $json survives past
		# the loop — a pipeline's while-body runs in a SUBSHELL and any
		# variable it sets would otherwise be lost once the pipe closes.
		json_body=""
		if [ -n "$sites" ]; then
			first=1
			while IFS= read -r s; do
				[ -n "$s" ] || continue
				if [ "$s" = "$def" ]; then is_def=true; else is_def=false; fi
				entry="{\"site\":\"$s\",\"default\":$is_def}"
				if [ "$first" -eq 1 ]; then json_body=$entry; first=0
				else json_body="$json_body,$entry"; fi
			done <<EOF
$sites
EOF
		fi
		printf '[%s]\n' "$json_body"
		[ -n "$sites" ] || exit 1
		exit 0
	fi

	printf 'Configured Jira sites:\n'
	if [ -z "$sites" ]; then
		printf '  (none — run jira-login.sh)\n'
	else
		printf '%s\n' "$sites" | while IFS= read -r s; do
			[ -n "$s" ] || continue
			if [ "$s" = "$def" ]; then
				printf '  * %s [default]\n' "$s"
			else
				printf '    %s\n' "$s"
			fi
		done
	fi
	printf '\n'
	printf 'JIRA_ACCOUNTS_SITES=%s\n'   "$csv"
	printf 'JIRA_ACCOUNTS_DEFAULT=%s\n' "$def"

	[ -n "$sites" ] || exit 1
	exit 0
}

cmd_default() {
	# Both branches exit, so a bare `if` (no while/shift) is enough — 'default'
	# takes no arguments beyond an optional -h/--help.
	if [ $# -gt 0 ]; then
		case "$1" in
			-h|--help) usage; exit 0 ;;
			*) usage >&2; error "unknown option to 'default': $1"; exit 2 ;;
		esac
	fi

	def=$(current_default)
	if [ -z "$def" ]; then
		error "no default site is configured"
		warn  "set one with: $PROG set-default --site SITE"
		printf 'JIRA_ACCOUNTS_DEFAULT=\n'
		exit 1
	fi
	printf 'Default Jira site: %s\n' "$def"
	printf 'JIRA_ACCOUNTS_DEFAULT=%s\n' "$def"
	exit 0
}

cmd_set_default() {
	opt_site=""
	while [ $# -gt 0 ]; do
		case "$1" in
			--site) need_arg "$1" "${2:-}"; opt_site=$2; shift ;;
			-h|--help) usage; exit 0 ;;
			*) usage >&2; error "unknown option to 'set-default': $1"; exit 2 ;;
		esac
		shift
	done
	[ -n "$opt_site" ] || { usage >&2; error "--site is required"; exit 2; }

	site_host=$(normalize_site "$opt_site")
	[ -n "$site_host" ] || { error "--site is empty after normalization"; exit 2; }
	if ! assert_host_allowed "$site_host"; then
		error "site '$site_host' is not in the allowed shape ($JIRA_HOST_ALLOWLIST_PATTERN)"
		exit 1
	fi

	cred_file=$(cred_file_for_site "$site_host")
	if [ ! -f "$cred_file" ]; then
		error "no credential stored for site '$site_host' — cannot make it the default"
		warn  "run jira-login.sh --site $site_host first"
		exit 1
	fi

	write_default "$site_host"
	printf 'Default Jira site set to: %s\n' "$site_host"
	printf 'JIRA_ACCOUNTS_DEFAULT=%s\n' "$site_host"
	exit 0
}

cmd_remove() {
	opt_site=""
	opt_force=0
	while [ $# -gt 0 ]; do
		case "$1" in
			--site) need_arg "$1" "${2:-}"; opt_site=$2; shift ;;
			--force) opt_force=1 ;;
			-h|--help) usage; exit 0 ;;
			*) usage >&2; error "unknown option to 'remove': $1"; exit 2 ;;
		esac
		shift
	done
	[ -n "$opt_site" ] || { usage >&2; error "--site is required"; exit 2; }
	if [ "$opt_force" -ne 1 ]; then
		usage >&2
		error "remove is destructive — pass --force to confirm removing the stored credential"
		exit 2
	fi

	site_host=$(normalize_site "$opt_site")
	[ -n "$site_host" ] || { error "--site is empty after normalization"; exit 2; }
	if ! assert_host_allowed "$site_host"; then
		error "site '$site_host' is not in the allowed shape ($JIRA_HOST_ALLOWLIST_PATTERN)"
		exit 1
	fi

	cred_file=$(cred_file_for_site "$site_host")
	if [ ! -f "$cred_file" ]; then
		error "no credential stored for site '$site_host'"
		exit 1
	fi

	rm -f "$cred_file"

	if [ "$(current_default)" = "$site_host" ]; then
		rm -f "$DEFAULT_MARKER"
		warn "'$site_host' was the default site; the default is now unset"
	fi

	printf 'Removed credential for: %s\n' "$site_host"
	exit 0
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
[ $# -ge 1 ] || { usage >&2; error "a subcommand is required"; exit 2; }

sub=$1
shift
case "$sub" in
	list)        cmd_list "$@" ;;
	default)     cmd_default "$@" ;;
	set-default) cmd_set_default "$@" ;;
	remove)      cmd_remove "$@" ;;
	-h|--help)   usage; exit 0 ;;
	*) usage >&2; error "unknown subcommand: $sub"; exit 2 ;;
esac
