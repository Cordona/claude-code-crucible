#!/usr/bin/env sh
#
# gh-auth-status.sh — deterministically report the GitHub CLI account auth
#                     state BEFORE any GitHub operation (open/update a PR, cut
#                     a release).
#
# Purpose:
#   Resolves, from `gh auth status` (with a `gh api user` fall-back), whether
#   `gh` is installed AND authenticated; the ACTIVE account (login); the HOST
#   (github.com or an Enterprise host); and — when several accounts are logged
#   in — the full list. AGENT-FRIENDLY: fully non-interactive, machine-parseable,
#   and READ-ONLY (it never writes anything and never prompts).
#
#   IMPORTANT — the active account is PER HOST. `gh auth status` marks one
#   account "Active account: true" for EACH host you are logged into. So a user
#   logged into github.com AND an Enterprise host has TWO active accounts, and
#   "the active account" is only well-defined once a host is chosen. When more
#   than one host has an active account and no --host is given, this is reported
#   as AMBIGUOUS rather than silently guessing one (an output-order-dependent
#   guess could present a plausible-but-wrong account+host to confirm).
#
# Usage:
#   gh-auth-status.sh [--host HOST] [-h|--help]
#     --host HOST   Scope resolution to a single host (e.g. github.com or an
#                   Enterprise host). Deterministically resolves the active
#                   account FOR THAT HOST — the way to get a single answer when
#                   several hosts are logged in.
#
# Output:
#   stdout — a human-readable status block AND a machine-parseable GH_*=VALUE
#            block a caller/agent can relay. Diagnostics go to stderr.
#
#   Machine keys (always emitted, even on failure):
#     GH_INSTALLED=true|false
#     GH_AUTHENTICATED=true|false
#     GH_ACTIVE_ACCOUNT=<login>            (empty if none / if ambiguous)
#     GH_HOST=<host>                       (empty if none / if ambiguous)
#     GH_ACCOUNTS=<login[,login...]>       (comma-separated inventory, may be empty)
#     GH_ACTIVE_AMBIGUOUS=true|false       (true => >1 host has an active account)
#     GH_ACTIVE_ACCOUNTS=<login@host[,...]> (the resolved active account, or the
#                                            full active set when ambiguous)
#
# Exit codes:
#   0  authenticated AND a SINGLE active account was resolved — ready to act
#   1  gh absent, OR not authenticated, OR no active account, OR AMBIGUOUS
#      (multiple hosts active and no --host) — DO NOT act
#   2  usage error
#
# Portability: POSIX sh only (no bashisms). Runs identically on macOS (BSD
#   userland / Bash 3.2, BSD sed/grep) and Linux (GNU coreutils). Every external
#   binary is guarded with `command -v`. Self-contained: sources nothing.
#   Deterministic: same `gh` state -> same output (LC_ALL=C pins ordering).
#
set -eu

# Pin collation/formatting so parsing + ordering are byte-stable everywhere.
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
Usage: $PROG [--host HOST] [-h|--help]

Report the GitHub CLI account authentication state (agent-friendly,
non-interactive, read-only).

Options:
  --host HOST   Scope resolution to a single host (github.com or Enterprise).
                Use this to get a single active account when several hosts are
                logged in (the active account is per host).
  -h, --help    Show this help.

Prints a human-readable block plus machine-parseable GH_*=VALUE lines:
  GH_INSTALLED, GH_AUTHENTICATED, GH_ACTIVE_ACCOUNT, GH_HOST, GH_ACCOUNTS,
  GH_ACTIVE_AMBIGUOUS, GH_ACTIVE_ACCOUNTS

Exit codes:
  0  authenticated with a single active account — ready to act
  1  gh absent / not authenticated / no active account / ambiguous — do not act
  2  usage error
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
OPT_HOST=""

need_arg() {
	[ -n "${2:-}" ] || { usage >&2; error "option $1 requires an argument"; exit 2; }
}

while [ $# -gt 0 ]; do
	case "$1" in
		--host) need_arg "$1" "${2:-}"; OPT_HOST=$2; shift ;;
		-h|--help) usage; exit 0 ;;
		--) shift; break ;;
		-*) usage >&2; error "unknown option: $1"; exit 2 ;;
		*)  usage >&2; error "unexpected argument: $1"; exit 2 ;;
	esac
	shift
done
[ $# -eq 0 ] || { usage >&2; error "unexpected argument: $1"; exit 2; }

TAB=$(printf '\t')

# Result state (globals; POSIX sh has no arrays/local).
GH_INSTALLED=false
GH_AUTHENTICATED=false
GH_ACTIVE_ACCOUNT=""
GH_HOST=""
GH_ACCOUNTS=""
GH_ACTIVE_AMBIGUOUS=false
GH_ACTIVE_ACCOUNTS=""
REC_DATA=""        # newline list of "host<TAB>login<TAB>active(0|1)" (host-filtered)

# ---------------------------------------------------------------------------
# emit — print the human block (stdout) then the machine block (stdout).
# Always called exactly once before exit so output is uniform for every path.
# ---------------------------------------------------------------------------
emit() {
	printf 'GitHub CLI Authentication\n'
	printf '  Installed:       %s\n' "$GH_INSTALLED"
	printf '  Authenticated:   %s\n' "$GH_AUTHENTICATED"
	if [ "$GH_AUTHENTICATED" = true ]; then
		if [ "$GH_ACTIVE_AMBIGUOUS" = true ]; then
			printf '  Active account:  <ambiguous — several hosts active>\n'
			printf '  Active set:      %s\n' "$GH_ACTIVE_ACCOUNTS"
			printf '  Hint:            re-run with --host HOST to pick one\n'
		else
			printf '  Active account:  %s\n' "${GH_ACTIVE_ACCOUNT:-<none>}"
			printf '  Host:            %s\n' "${GH_HOST:-<none>}"
		fi
		if [ -n "$REC_DATA" ]; then
			printf '  Accounts:\n'
			# Deliberate word-split of the TAB-separated record fields. A row is
			# starred when gh marks it active OR it is the resolved active pair.
			printf '%s\n' "$REC_DATA" | while IFS="$TAB" read -r e_host e_login e_act; do
				[ -n "$e_login" ] || continue
				if [ "$e_act" = "1" ] || { [ "$e_login" = "$GH_ACTIVE_ACCOUNT" ] && [ "$e_host" = "$GH_HOST" ]; }; then
					printf '    * %s (%s) [active]\n' "$e_login" "$e_host"
				else
					printf '      %s (%s)\n' "$e_login" "$e_host"
				fi
			done
		fi
	fi

	printf '\n'
	printf 'GH_INSTALLED=%s\n'         "$GH_INSTALLED"
	printf 'GH_AUTHENTICATED=%s\n'     "$GH_AUTHENTICATED"
	printf 'GH_ACTIVE_ACCOUNT=%s\n'    "$GH_ACTIVE_ACCOUNT"
	printf 'GH_HOST=%s\n'              "$GH_HOST"
	printf 'GH_ACCOUNTS=%s\n'          "$GH_ACCOUNTS"
	printf 'GH_ACTIVE_AMBIGUOUS=%s\n'  "$GH_ACTIVE_AMBIGUOUS"
	printf 'GH_ACTIVE_ACCOUNTS=%s\n'   "$GH_ACTIVE_ACCOUNTS"
}

# ---------------------------------------------------------------------------
# 0. gh must be installed.
# ---------------------------------------------------------------------------
if ! command -v gh >/dev/null 2>&1; then
	error "GitHub CLI (gh) is not installed"
	warn  "install it from https://cli.github.com/ then re-run"
	emit
	exit 1
fi
GH_INSTALLED=true

# ---------------------------------------------------------------------------
# 1. Authenticated? `gh auth status` exits non-zero when logged into no host.
#    Capture combined output (gh's version history has flip-flopped between
#    stdout/stderr); we key the verdict off the exit code, not the stream.
# ---------------------------------------------------------------------------
if STATUS_OUT=$(gh auth status 2>&1); then
	GH_STATUS_RC=0
else
	GH_STATUS_RC=$?
fi

if [ "$GH_STATUS_RC" -ne 0 ]; then
	error "gh is installed but not authenticated to any host"
	warn  "authenticate (or switch) with the interactive manage_gh_accounts.sh"
	emit
	exit 1
fi
GH_AUTHENTICATED=true

# ---------------------------------------------------------------------------
# 2. Parse `gh auth status`. Robustness: we key off the stable substring
#    "Logged in to" and the KEYWORDS ("to"/"account"/"as"), NOT fragile column
#    positions, so both the modern format:
#        ✓ Logged in to github.com account octocat (keyring)
#        - Active account: true
#    and the legacy format:
#        ✓ Logged in to github.com as octocat (oauth_token)
#    parse correctly. Failure lines ("X Failed to log in to ...") never match
#    because they read "log in", not "Logged in".
#
#    awk emits (respecting the optional --host filter):
#      REC<TAB>host<TAB>login<TAB>active   — one per account
#      ACT<TAB>host<TAB>login              — one per ACTIVE account
#      META<TAB>COUNT<TAB>n                — accounts after filtering
#      META<TAB>FILT_ACTIVE<TAB>n          — active accounts after filtering
#      META<TAB>ACTIVE_HOSTS<TAB>n         — DISTINCT hosts that have an active
#                                            account (the ambiguity signal)
# ---------------------------------------------------------------------------
PARSED=$(printf '%s\n' "$STATUS_OUT" | awk -v want="$OPT_HOST" '
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
			if (want != "" && H[i] != want) continue
			if (L[i] == "") continue
			cnt++
			printf "REC\t%s\t%s\t%s\n", H[i], L[i], A[i]
			if (A[i] == 1) {
				printf "ACT\t%s\t%s\n", H[i], L[i]
				ah[H[i]] = 1; na++
			}
		}
		nd = 0
		for (h in ah) nd++
		printf "META\tCOUNT\t%d\n",        cnt
		printf "META\tFILT_ACTIVE\t%d\n",  na
		printf "META\tACTIVE_HOSTS\t%d\n", nd
	}
')

REC_DATA=$(printf '%s\n' "$PARSED" | awk -F"$TAB" -v OFS="$TAB" '$1=="REC"{print $2,$3,$4}')
ACT_DATA=$(printf '%s\n' "$PARSED" | awk -F"$TAB" -v OFS="$TAB" '$1=="ACT"{print $2,$3}')
ACCT_COUNT=$(printf '%s\n'     "$PARSED" | awk -F"$TAB" '$1=="META"&&$2=="COUNT"{print $3}')
FILT_ACTIVE=$(printf '%s\n'    "$PARSED" | awk -F"$TAB" '$1=="META"&&$2=="FILT_ACTIVE"{print $3}')
ACTIVE_HOSTS_N=$(printf '%s\n' "$PARSED" | awk -F"$TAB" '$1=="META"&&$2=="ACTIVE_HOSTS"{print $3}')
: "${ACCT_COUNT:=0}"
: "${FILT_ACTIVE:=0}"
: "${ACTIVE_HOSTS_N:=0}"

# Inventory of logins (host-filtered), comma-separated, in gh's output order.
GH_ACCOUNTS=""
if [ -n "$REC_DATA" ]; then
	while IFS="$TAB" read -r r_host r_login _; do
		[ -n "$r_login" ] || continue
		if [ -z "$GH_ACCOUNTS" ]; then GH_ACCOUNTS=$r_login
		else GH_ACCOUNTS="$GH_ACCOUNTS,$r_login"; fi
	done <<EOF
$REC_DATA
EOF
fi

# ---------------------------------------------------------------------------
# 3. Ambiguity gate: if NO --host was given and MORE THAN ONE distinct host has
#    an active account, do NOT guess. Surface the full active set and fail.
# ---------------------------------------------------------------------------
if [ -z "$OPT_HOST" ] && [ "$ACTIVE_HOSTS_N" -gt 1 ]; then
	GH_ACTIVE_AMBIGUOUS=true
	# Build a deterministic (LC_ALL=C sorted) "login@host,..." set.
	GH_ACTIVE_ACCOUNTS=""
	for pair in $(printf '%s\n' "$ACT_DATA" | while IFS="$TAB" read -r a_host a_login; do
		[ -n "$a_login" ] && printf '%s@%s\n' "$a_login" "$a_host"
	done | sort); do
		if [ -z "$GH_ACTIVE_ACCOUNTS" ]; then GH_ACTIVE_ACCOUNTS=$pair
		else GH_ACTIVE_ACCOUNTS="$GH_ACTIVE_ACCOUNTS,$pair"; fi
	done
	error "multiple hosts have an active account ($GH_ACTIVE_ACCOUNTS); cannot pick one"
	warn  "re-run with --host HOST to resolve a single active account"
	emit
	exit 1
fi

# ---------------------------------------------------------------------------
# 4. Resolve the SINGLE active account + host (unambiguous, or host-scoped).
#    Priority:
#      (a) an "Active account: true" record (there is at most one active host
#          here, so at most one such record);
#      (b) the sole account, if exactly one is logged in (legacy gh, no marker);
#      (c) `gh api user --jq .login` — authoritative server-side fall-back. With
#          --host we query that host; without it the call hits github.com, so we
#          recover the host by PREFERRING a github.com match over first-match.
# ---------------------------------------------------------------------------
if [ "$FILT_ACTIVE" -ge 1 ]; then
	ACT_FIRST=$(printf '%s\n' "$ACT_DATA" | sed -n '1p')
	GH_HOST=$(printf '%s' "$ACT_FIRST" | cut -f1)
	GH_ACTIVE_ACCOUNT=$(printf '%s' "$ACT_FIRST" | cut -f2)
fi

if [ -z "$GH_ACTIVE_ACCOUNT" ] && [ "$ACCT_COUNT" -eq 1 ]; then
	FIRST_REC=$(printf '%s\n' "$REC_DATA" | sed -n '1p')
	GH_HOST=$(printf '%s' "$FIRST_REC" | cut -f1)
	GH_ACTIVE_ACCOUNT=$(printf '%s' "$FIRST_REC" | cut -f2)
fi

if [ -z "$GH_ACTIVE_ACCOUNT" ]; then
	if [ -n "$OPT_HOST" ]; then
		API_LOGIN=$(gh api user --hostname "$OPT_HOST" --jq '.login' 2>/dev/null || true)
		if [ -n "$API_LOGIN" ]; then
			GH_ACTIVE_ACCOUNT=$API_LOGIN
			GH_HOST=$OPT_HOST
		fi
	else
		API_LOGIN=$(gh api user --jq '.login' 2>/dev/null || true)
		if [ -n "$API_LOGIN" ]; then
			GH_ACTIVE_ACCOUNT=$API_LOGIN
			# Recover host: prefer github.com (the host `gh api user` queried),
			# else the first record carrying this login.
			API_HOST=""
			API_HOST_GH=""
			while IFS="$TAB" read -r r_host r_login _; do
				[ "$r_login" = "$API_LOGIN" ] || continue
				[ -n "$API_HOST" ] || API_HOST=$r_host
				[ "$r_host" = "github.com" ] && API_HOST_GH="github.com"
			done <<EOF
$REC_DATA
EOF
			[ -n "$API_HOST_GH" ] && API_HOST=$API_HOST_GH
			GH_HOST=$API_HOST
		fi
	fi
fi

# Default host if we resolved an account but never captured a host.
if [ -n "$GH_ACTIVE_ACCOUNT" ] && [ -z "$GH_HOST" ]; then
	GH_HOST=${OPT_HOST:-github.com}
fi

# The resolved active account, expressed as the single-element active set.
if [ -n "$GH_ACTIVE_ACCOUNT" ]; then
	GH_ACTIVE_ACCOUNTS="$GH_ACTIVE_ACCOUNT@$GH_HOST"
fi

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------
if [ -z "$GH_ACTIVE_ACCOUNT" ]; then
	if [ -n "$OPT_HOST" ]; then
		error "authenticated, but no active account resolved for host '$OPT_HOST'"
	else
		error "authenticated, but could not resolve an active account"
	fi
	emit
	exit 1
fi

emit
exit 0
