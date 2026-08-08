#!/usr/bin/env sh
#
# jira-auth-status.sh — deterministically report the Jira credential state
#                        BEFORE any Jira write. The twin of
#                        procedure-github-auth's gh-auth-status.sh: fully
#                        non-interactive, machine-parseable, and READ-ONLY
#                        (it never writes anything and never prompts). This
#                        is what the orchestrator reads to PRESENT the
#                        resolved site + account for the human to confirm —
#                        it never presents or handles the token itself.
#
# Purpose:
#   Resolves, from the on-disk credential store this skill's jira-login.sh
#   writes: whether ANY credential is configured; the full list of
#   configured sites; the current default site (if any); and — for a given
#   --site or, absent that, the default — whether a credential exists for
#   it and which ACCOUNT EMAIL it belongs to. The token itself is NEVER
#   read, printed, or otherwise surfaced by this script.
#
# Usage:
#   jira-auth-status.sh [--site SITE] [-h|--help]
#     --site SITE   Report on this site specifically, instead of the
#                   configured default. Does not need to be pre-normalized
#                   ("https://" prefix / trailing path are stripped).
#
# Output:
#   stdout — a human-readable status block AND a machine-parseable
#            JIRA_AUTH_*=VALUE block a caller/agent can relay. Diagnostics
#            go to stderr. The token NEVER appears in any output.
#
#   Machine keys (always emitted, even on failure):
#     JIRA_AUTH_CONFIGURED=true|false   any credential stored at all
#     JIRA_AUTH_SITES=<site[,site...]>  every configured site (sorted)
#     JIRA_AUTH_DEFAULT_SITE=<site>     the configured default (empty if none)
#     JIRA_AUTH_SITE=<site>             the site actually being reported on
#                                        (the resolved --site, or the
#                                        default; empty if neither resolved)
#     JIRA_AUTH_SITE_CONFIGURED=true|false  a credential exists for
#                                        JIRA_AUTH_SITE
#     JIRA_AUTH_ACCOUNT=<email>         the account email for JIRA_AUTH_SITE
#                                        (empty unless SITE_CONFIGURED=true)
#
# Exit codes:
#   0  a credential is configured for the resolved site — ready to present
#      for confirmation
#   1  no credential store / no credential for the resolved site / --site
#      omitted and no default is set — DO NOT act
#   2  usage error
#
# Portability: POSIX sh only (no bashisms). Runs identically on macOS (BSD
#   userland / Bash 3.2) and Linux (GNU coreutils). This script touches no
#   optional/interactive binary — every external command it uses (sed, cat,
#   sort, tr) is a baseline POSIX coreutil, assumed present; there is
#   nothing here for `command -v` to usefully guard. Self-contained: sources
#   nothing. Deterministic: same on-disk store -> same output (LC_ALL=C pins
#   sort ordering).
#
set -eu

LC_ALL=C
export LC_ALL

PROG=${0##*/}

# ---------------------------------------------------------------------------
# Diagnostics (all to stderr — stdout stays machine-clean)
# ---------------------------------------------------------------------------
warn()  { printf '%s: warning: %s\n' "$PROG" "$*" >&2; }
error() { printf '%s: error: %s\n'   "$PROG" "$*" >&2; }

usage() {
	cat <<EOF
Usage: $PROG [--site SITE] [-h|--help]

Report the Jira credential state (agent-friendly, non-interactive,
read-only). NEVER prints a token.

Options:
  --site SITE   Report on this site instead of the configured default.
  -h, --help    Show this help.

Prints a human-readable block plus machine-parseable JIRA_AUTH_*=VALUE lines:
  JIRA_AUTH_CONFIGURED, JIRA_AUTH_SITES, JIRA_AUTH_DEFAULT_SITE,
  JIRA_AUTH_SITE, JIRA_AUTH_SITE_CONFIGURED, JIRA_AUTH_ACCOUNT

Exit codes:
  0  a credential is configured for the resolved site
  1  no credential store / no credential for the resolved site / no default
     and no --site given
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

while [ $# -gt 0 ]; do
	case "$1" in
		--site) need_arg "$1" "${2:-}"; OPT_SITE=$2; shift ;;
		-h|--help) usage; exit 0 ;;
		--) shift; break ;;
		-*) usage >&2; error "unknown option: $1"; exit 2 ;;
		*)  usage >&2; error "unexpected argument: $1"; exit 2 ;;
	esac
	shift
done
[ $# -eq 0 ] || { usage >&2; error "unexpected argument: $1"; exit 2; }

# ---------------------------------------------------------------------------
# Credential-store layout (shared shape with jira-login.sh / jira-curl-config.sh
# / jira-accounts.sh — re-implemented inline in each, not sourced).
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
# re-checked at this SINK (a --site an agent supplies), not just at
# jira-login.sh's write time.
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

# account_email_from_cred FILE -> the "email" half of the stored
# `user = "email:token"` line, WITHOUT ever emitting the token. Parses with
# sed only (no eval/sourcing of file content — it is a credential, not code).
#
# Split on the FIRST colon (`[^:]*`), never a greedy `.*`.
# curl's own `-u`/`user = "..."` parsing splits "user:password" on the FIRST
# colon — a TOKEN containing a ":" is legal and common (e.g. many API tokens
# embed one), so a greedy `.*` before the LAST colon would silently splice
# leading token bytes into the reported email. Email addresses do not
# contain a bare ":", so first-colon splitting is also the correct email
# boundary, not just the safe one.
account_email_from_cred() {
	sed -n 's/^user = "\([^:]*\):.*"$/\1/p' "$1" | sed -n '1p' | sed 's/\\"/"/g; s/\\\\/\\/g'
}

# ---------------------------------------------------------------------------
# Result state (globals; POSIX sh has no arrays/local).
# ---------------------------------------------------------------------------
JIRA_AUTH_CONFIGURED=false
JIRA_AUTH_SITES=""
JIRA_AUTH_DEFAULT_SITE=""
JIRA_AUTH_SITE=""
JIRA_AUTH_SITE_CONFIGURED=false
JIRA_AUTH_ACCOUNT=""

emit() {
	printf 'Jira Credential Status\n'
	printf '  Configured:      %s\n' "$JIRA_AUTH_CONFIGURED"
	printf '  Sites:           %s\n' "${JIRA_AUTH_SITES:-<none>}"
	printf '  Default site:    %s\n' "${JIRA_AUTH_DEFAULT_SITE:-<none>}"
	printf '  Reporting on:    %s\n' "${JIRA_AUTH_SITE:-<unresolved>}"
	if [ "$JIRA_AUTH_SITE_CONFIGURED" = true ]; then
		printf '  Account:         %s\n' "$JIRA_AUTH_ACCOUNT"
	fi
	printf '\n'
	printf 'JIRA_AUTH_CONFIGURED=%s\n'      "$JIRA_AUTH_CONFIGURED"
	printf 'JIRA_AUTH_SITES=%s\n'           "$JIRA_AUTH_SITES"
	printf 'JIRA_AUTH_DEFAULT_SITE=%s\n'    "$JIRA_AUTH_DEFAULT_SITE"
	printf 'JIRA_AUTH_SITE=%s\n'            "$JIRA_AUTH_SITE"
	printf 'JIRA_AUTH_SITE_CONFIGURED=%s\n' "$JIRA_AUTH_SITE_CONFIGURED"
	printf 'JIRA_AUTH_ACCOUNT=%s\n'         "$JIRA_AUTH_ACCOUNT"
}

# ---------------------------------------------------------------------------
# 1. Inventory every configured site (sorted, LC_ALL=C -> stable order).
# ---------------------------------------------------------------------------
if [ -d "$JIRA_CRED_DIR" ]; then
	for f in "$JIRA_CRED_DIR"/*.cfg; do
		[ -e "$f" ] || continue
		base=${f##*/}
		site=${base%.cfg}
		if [ -z "$JIRA_AUTH_SITES" ]; then JIRA_AUTH_SITES=$site
		else JIRA_AUTH_SITES="$JIRA_AUTH_SITES,$site"; fi
	done
	if [ -n "$JIRA_AUTH_SITES" ]; then
		JIRA_AUTH_SITES=$(printf '%s\n' "$JIRA_AUTH_SITES" | tr ',' '\n' | sort | tr '\n' ',')
		JIRA_AUTH_SITES=${JIRA_AUTH_SITES%,}
	fi
fi
[ -n "$JIRA_AUTH_SITES" ] && JIRA_AUTH_CONFIGURED=true

# ---------------------------------------------------------------------------
# 2. Default site — reported ONLY if the marker exists AND still names a
#    site that actually HAS a stored credential. A dangling marker
#    (its site removed via jira-accounts.sh remove through a --site not
#    routed back through the same write path, or the file deleted by hand)
#    must never be surfaced as if it were still active.
# ---------------------------------------------------------------------------
if [ -f "$DEFAULT_MARKER" ]; then
	default_candidate=$(sed -n '1p' "$DEFAULT_MARKER")
	if [ -n "$default_candidate" ] && [ -f "$(cred_file_for_site "$default_candidate")" ]; then
		JIRA_AUTH_DEFAULT_SITE=$default_candidate
	fi
fi

# ---------------------------------------------------------------------------
# 3. Resolve the site to report on: --site (normalized + allow-list gated)
#    or the (already-verified) default.
# ---------------------------------------------------------------------------
if [ -n "$OPT_SITE" ]; then
	JIRA_AUTH_SITE=$(normalize_site "$OPT_SITE")
	if [ -n "$JIRA_AUTH_SITE" ] && ! assert_host_allowed "$JIRA_AUTH_SITE"; then
		error "site '$JIRA_AUTH_SITE' is not in the allowed shape ($JIRA_HOST_ALLOWLIST_PATTERN)"
		emit
		exit 1
	fi
else
	JIRA_AUTH_SITE=$JIRA_AUTH_DEFAULT_SITE
fi

if [ -z "$JIRA_AUTH_SITE" ]; then
	error "no site given and no default site is configured"
	warn  "run jira-login.sh to store a credential, or pass --site"
	emit
	exit 1
fi

# ---------------------------------------------------------------------------
# 4. Resolve the credential for that site.
# ---------------------------------------------------------------------------
cred_file=$(cred_file_for_site "$JIRA_AUTH_SITE")
if [ -f "$cred_file" ] && [ -r "$cred_file" ]; then
	JIRA_AUTH_SITE_CONFIGURED=true
	JIRA_AUTH_ACCOUNT=$(account_email_from_cred "$cred_file")
fi

if [ "$JIRA_AUTH_SITE_CONFIGURED" != true ]; then
	error "no credential configured for site '$JIRA_AUTH_SITE'"
	warn  "run jira-login.sh --site $JIRA_AUTH_SITE to store one"
	emit
	exit 1
fi

emit
exit 0
