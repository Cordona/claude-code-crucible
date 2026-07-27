#!/usr/bin/env sh
#
# jira-curl-config.sh — resolve a confirmed site's stored credential into
#                        the curl-config file path procedure-jira's engine
#                        consumes via $JIRA_CURL_CONFIG (the
#                        credential-handoff contract this skill's whole
#                        reason for existing is to satisfy). Non-interactive,
#                        agent-friendly. FAILS CLOSED if the site has no
#                        stored credential — never falls back to any other
#                        site.
#
# Purpose:
#   Given the site the orchestrator has ALREADY had the human confirm
#   (--site — pass the same confirmed-site value procedure-jira's
#   `--confirmed-site` will receive; this script does not itself perform the
#   confirmation, it only resolves credentials for a site the caller has
#   already resolved/confirmed), prints EITHER:
#     - the path of the stored `600` credential file directly (default), or
#     - the path of a freshly `mktemp`-ed `600` COPY of it (--copy).
#   The token itself is NEVER printed — only ever a file path. Feed the
#   printed path to the engine as: JIRA_CURL_CONFIG=<path> jira.sh ...
#
# Usage:
#   jira-curl-config.sh --site SITE [--copy] [-h|--help]
#     --site SITE   The (already-confirmed) Jira Cloud site, e.g.
#                   "your-co.atlassian.net". An "https://" prefix and/or
#                   trailing path are stripped before lookup.
#     --copy        Print the path of a fresh 600 mktemp COPY instead of the
#                   stored file's own path. Use this when the caller needs a
#                   config file it can freely delete afterwards (the stored
#                   original is never deleted by this script or by the
#                   engine — see the Cleanup note below) or wants isolation
#                   from a concurrent jira-login.sh overwrite. The caller
#                   OWNS cleanup of a --copy'd file (this script's own
#                   process has already exited by the time it's used).
#
# Cleanup:
#   Without --copy, the printed path IS the persistent credential store
#   entry — do not delete it. procedure-jira's jira.sh already knows this:
#   when $JIRA_CURL_CONFIG is externally supplied it treats the file as
#   "not its own" and never removes it (CURL_CONFIG_IS_OWN=0 in that
#   script). With --copy, the printed path is a throwaway temp file the
#   CALLER is responsible for removing.
#
#   Token-bearing tempfile in $TMPDIR: a --copy'd file is `600`
#   and only readable by the invoking user, but it lives in $TMPDIR (not
#   the private, `700` credential directory) until the caller removes it —
#   if the caller crashes or is killed before cleanup, the copy is orphaned
#   there. A caller that uses --copy MUST `rm -f` the printed path as soon
#   as it is done with it (ideally under its OWN exit trap), the same
#   discipline this script and jira-login.sh apply to their own tempfiles.
#   Prefer the DEFAULT (no --copy) whenever an isolated/disposable file
#   isn't actually required — it hands back the persistent store entry,
#   which needs no caller-side cleanup at all.
#
# Exit codes:
#   0  success — a credential-config path was printed to stdout
#   1  no credential stored for SITE (fail closed), or a filesystem error
#      resolving/copying it
#   2  usage error (missing/empty --site)
#
# Portability: POSIX sh only (no bashisms). Runs identically on macOS (BSD
#   userland / Bash 3.2) and Linux (GNU coreutils). This script touches no
#   optional/interactive binary — every external command it uses (sed,
#   mktemp, chmod, cp, rm) is a baseline POSIX coreutil, assumed present;
#   there is nothing here for `command -v` to usefully guard. Self-contained:
#   sources nothing.
#
set -eu

LC_ALL=C
export LC_ALL

PROG=${0##*/}

warn()  { printf '%s: warning: %s\n' "$PROG" "$*" >&2; }
error() { printf '%s: error: %s\n'   "$PROG" "$*" >&2; }

# COPY_FILE/COPY_DONE — the --copy path's tempfile is DELIBERATELY
# meant to outlive this process (the caller owns and uses it after we exit
# 0), so the trap below must NOT always remove it — only when this script
# is interrupted/fails BEFORE handing the path off successfully (mktemp
# succeeded but chmod/cp/the final printf never completed). COPY_DONE=1 is
# set only once the path has actually been printed to the caller.
COPY_FILE=""
COPY_DONE=0
# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup_on_exit() {
	if [ "$COPY_DONE" -eq 0 ] && [ -n "$COPY_FILE" ] && [ -f "$COPY_FILE" ]; then
		rm -f "$COPY_FILE"
	fi
}
trap cleanup_on_exit EXIT INT TERM

usage() {
	cat <<EOF
Usage: $PROG --site SITE [--copy] [-h|--help]

Resolve a site's stored Jira credential into a curl -K config file path
(for \$JIRA_CURL_CONFIG). NEVER prints the token — only a file path. Fails
closed (exit 1) if no credential is stored for SITE.

Options:
  --site SITE   The (already-confirmed) Jira Cloud site.
  --copy        Print a fresh 600 mktemp COPY's path instead of the stored
                file's own path. The caller owns cleanup of a --copy'd file.
  -h, --help    Show this help.

Exit codes:
  0  success — a config file path was printed to stdout
  1  no credential stored for SITE / filesystem error
  2  usage error
EOF
}

need_arg() {
	[ -n "${2:-}" ] || { usage >&2; error "option $1 requires an argument"; exit 2; }
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
OPT_SITE=""
OPT_COPY=0

while [ $# -gt 0 ]; do
	case "$1" in
		--site) need_arg "$1" "${2:-}"; OPT_SITE=$2; shift ;;
		--copy) OPT_COPY=1 ;;
		-h|--help) usage; exit 0 ;;
		--) shift; break ;;
		-*) usage >&2; error "unknown option: $1"; exit 2 ;;
		*)  usage >&2; error "unexpected argument: $1"; exit 2 ;;
	esac
	shift
done
[ $# -eq 0 ] || { usage >&2; error "unexpected argument: $1"; exit 2; }
[ -n "$OPT_SITE" ] || { usage >&2; error "--site is required"; exit 2; }

# ---------------------------------------------------------------------------
# Credential-store layout (shared shape with jira-login.sh / jira-auth-status.sh
# / jira-accounts.sh — re-implemented inline, not sourced).
# ---------------------------------------------------------------------------
JIRA_HOST_ALLOWLIST_PATTERN=${JIRA_HOST_ALLOWLIST_PATTERN:-'*.atlassian.net'}
JIRA_CRED_DIR=${JIRA_CRED_DIR:-"$HOME/.claude/crucible/jira/credentials"}

normalize_site() {
	raw=$1
	host=$(printf '%s' "$raw" | sed -E 's#^[Hh][Tt][Tt][Pp][Ss]?://##')
	host=${host%%/*}
	printf '%s' "$host"
}

# assert_host_allowed HOST -> 0 if HOST is host-safe AND matches the
# configured allow-list glob, 1 otherwise. Defense-in-depth:
# this SINK re-checks the shape (not just jira-login.sh at write time) —
# a credential dir populated by any other means, or a $JIRA_CRED_DIR pointed
# at foreign content, must not let a malformed/traversal-shaped site reach
# cred_file_for_site().
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

SITE_HOST=$(normalize_site "$OPT_SITE")
[ -n "$SITE_HOST" ] || { error "--site is empty after normalization"; exit 2; }
if ! assert_host_allowed "$SITE_HOST"; then
	error "site '$SITE_HOST' is not in the allowed shape ($JIRA_HOST_ALLOWLIST_PATTERN)"
	exit 1
fi

CRED_FILE=$(cred_file_for_site "$SITE_HOST")

# ---------------------------------------------------------------------------
# Fail closed: no credential for this site -> exit 1, clear message, NOTHING
# printed to stdout (a caller that doesn't check the exit code must not be
# handed a bogus/empty path to feed straight into $JIRA_CURL_CONFIG).
# ---------------------------------------------------------------------------
if [ ! -f "$CRED_FILE" ] || [ ! -r "$CRED_FILE" ]; then
	error "no credential stored for site '$SITE_HOST'"
	warn  "run jira-login.sh --site $SITE_HOST to store one"
	exit 1
fi

if [ "$OPT_COPY" -eq 0 ]; then
	printf '%s\n' "$CRED_FILE"
	exit 0
fi

# ---------------------------------------------------------------------------
# --copy: a fresh 600 mktemp copy. umask 077 covers mktemp's own creation
# mode; the explicit chmod 600 afterward holds even if that is somehow not
# honored, matching jira.sh's own belt-and-braces credential-file pattern.
# ---------------------------------------------------------------------------
old_umask=$(umask)
umask 077
COPY_FILE=$(mktemp "${TMPDIR:-/tmp}/jira.curlconfig.XXXXXX") || {
	umask "$old_umask"
	error "could not create a temp file for the credential copy"
	exit 1
}
umask "$old_umask"
chmod 600 "$COPY_FILE"

if ! cp "$CRED_FILE" "$COPY_FILE"; then
	error "could not copy the credential for site '$SITE_HOST'"
	exit 1
fi
chmod 600 "$COPY_FILE"

COPY_DONE=1
printf '%s\n' "$COPY_FILE"
exit 0
