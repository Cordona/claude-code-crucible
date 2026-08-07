#!/usr/bin/env sh
#
# glab-auth-status.sh — deterministically report the GitLab CLI account auth
#                       state BEFORE any GitLab operation (open/update an MR,
#                       cut a release).
#
# Purpose:
#   Resolves, from `glab auth status`, whether `glab` is installed AND
#   authenticated; the ACTIVE account (login); the HOST (gitlab.com or a
#   self-managed instance); and — when several instances are configured — the
#   full list. AGENT-FRIENDLY: fully non-interactive, machine-parseable, and
#   READ-ONLY (it never writes anything and never prompts).
#
#   IMPORTANT — the account is PER HOST. `glab` stores one credential per
#   GitLab instance, so a user logged into gitlab.com AND a self-managed host
#   has TWO accounts, and "the active account" is only well-defined once a host
#   is chosen. When more than one candidate account is found and no --hostname
#   is given, this is reported as AMBIGUOUS rather than silently guessing one
#   (an output-order-dependent guess could present a plausible-but-wrong
#   account+host to confirm). This is the same "never guess" posture as the
#   sibling gh-auth-status.sh.
#
#   Observed `glab auth status` output this parses (glab 1.112.0, gitlab.com):
#     gitlab.com
#       ✓ Logged in to gitlab.com as Cordona (keyring)
#       ✓ Git operations for gitlab.com configured to use https protocol.
#       ...
#   Parsing is KEYWORD-anchored on the stable "Logged in to" substring plus the
#   "to"/"as" keywords — never on column positions — so decoration around the
#   login line (glyphs, protocol/endpoint/token lines) cannot break it, and a
#   "✗ Not logged in to ..." / "Failed to log in to ..." line never matches
#   (different capitalization / wording).
#
#   NO server-side fall-back (a deliberate divergence from gh-auth-status.sh,
#   which calls `gh api user` when gh's LEGACY output carries no active-account
#   marker): every glab login line observed carries "as <LOGIN>" inline, so
#   there is no format here that needs an extra network round-trip to resolve.
#   If a future glab wording defeats the parser we fail CLOSED (exit 1,
#   "could not resolve an account") instead of quietly reaching for the API.
#
# Usage:
#   glab-auth-status.sh [--hostname HOST] [-h|--help]
#     --hostname HOST  Scope resolution to a single instance (e.g. gitlab.com
#                      or a self-managed host). Deterministically resolves the
#                      account FOR THAT HOST — the way to get a single answer
#                      when several instances are configured. Spelled the way
#                      `glab auth status` itself spells it (gh's equivalent flag
#                      is --host; glab's is --hostname).
#
# Output:
#   stdout — a human-readable status block AND a machine-parseable GLAB_*=VALUE
#            block a caller/agent can relay. Diagnostics go to stderr.
#
#   Machine keys (emitted on exit 0 and exit 1; a usage error, exit 2, prints
#   usage + the error only and emits none of these keys):
#     GLAB_INSTALLED=true|false
#     GLAB_AUTHENTICATED=true|false
#     GLAB_ACTIVE_ACCOUNT=<login>              (empty if none / if ambiguous)
#     GLAB_HOST=<host>                         (empty if none / if ambiguous)
#     GLAB_ACCOUNTS=<login[,login...]>         (comma-separated inventory, may be empty)
#     GLAB_ACTIVE_AMBIGUOUS=true|false         (true => >1 candidate account)
#     GLAB_ACTIVE_ACCOUNTS=<login@host[,...]>  (the resolved account, or the
#                                               full candidate set when ambiguous)
#
# Exit codes:
#   0  authenticated AND a SINGLE account was resolved — ready to act
#   1  glab absent, OR not authenticated, OR no account resolved, OR AMBIGUOUS
#      (several candidates and no --hostname) — DO NOT act
#   2  usage error
#
# Portability: POSIX sh only (no bashisms). Runs identically on macOS (BSD
#   userland / Bash 3.2, BSD sed/grep) and Linux (GNU coreutils). Every external
#   binary is guarded with `command -v`. Self-contained: sources nothing.
#   Deterministic: same `glab` state -> same output (LC_ALL=C pins ordering;
#   the GLAB_* env below pins glab's own chattiness out of stdout).
#
set -eu

# Pin collation/formatting so parsing + ordering are byte-stable everywhere.
LC_ALL=C
export LC_ALL

# Pin glab's own optional output/behavior so stdout stays deterministic and
# nothing can block on a prompt:
#   GLAB_NO_PROMPT        — glab must never ask this non-interactive script
#                           anything (it would hang an agent caller).
#   GLAB_CHECK_UPDATE     — suppresses the "new version available" notice and
#                           the network round-trip that produces it.
#   GLAB_SHOW_WHATS_NEW   — suppresses the one-time post-upgrade banner.
GLAB_NO_PROMPT=true
GLAB_CHECK_UPDATE=false
GLAB_SHOW_WHATS_NEW=false
export GLAB_NO_PROMPT GLAB_CHECK_UPDATE GLAB_SHOW_WHATS_NEW

PROG=${0##*/}

# ---------------------------------------------------------------------------
# Diagnostics (all to stderr — stdout stays machine-clean)
# ---------------------------------------------------------------------------
warn()  { printf '%s: warning: %s\n' "$PROG" "$*" >&2; }
error() { printf '%s: error: %s\n'   "$PROG" "$*" >&2; }

usage() {
	cat <<EOF
Usage: $PROG [--hostname HOST] [-h|--help]

Report the GitLab CLI account authentication state (agent-friendly,
non-interactive, read-only).

Options:
  --hostname HOST   Scope resolution to a single instance (gitlab.com or a
                    self-managed host). Use this to get a single account when
                    several instances are configured (the account is per host).
  -h, --help        Show this help.

Prints a human-readable block plus machine-parseable GLAB_*=VALUE lines:
  GLAB_INSTALLED, GLAB_AUTHENTICATED, GLAB_ACTIVE_ACCOUNT, GLAB_HOST,
  GLAB_ACCOUNTS, GLAB_ACTIVE_AMBIGUOUS, GLAB_ACTIVE_ACCOUNTS

Exit codes:
  0  authenticated with a single resolved account — ready to act
  1  glab absent / not authenticated / no account / ambiguous — do not act
  2  usage error
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
OPT_HOSTNAME=""

need_arg() {
	[ -n "${2:-}" ] || { usage >&2; error "option $1 requires an argument"; exit 2; }
}

while [ $# -gt 0 ]; do
	case "$1" in
		--hostname) need_arg "$1" "${2:-}"; OPT_HOSTNAME=$2; shift ;;
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
GLAB_INSTALLED=false
GLAB_AUTHENTICATED=false
GLAB_ACTIVE_ACCOUNT=""
GLAB_HOST=""
GLAB_ACCOUNTS=""
GLAB_ACTIVE_AMBIGUOUS=false
GLAB_ACTIVE_ACCOUNTS=""
REC_DATA=""        # newline list of "host<TAB>login" (host-filtered, deduped)

# ---------------------------------------------------------------------------
# emit — print the human block (stdout) then the machine block (stdout).
# Always called exactly once before exit so output is uniform for every path.
# ---------------------------------------------------------------------------
emit() {
	printf 'GitLab CLI Authentication\n'
	printf '  Installed:       %s\n' "$GLAB_INSTALLED"
	printf '  Authenticated:   %s\n' "$GLAB_AUTHENTICATED"
	if [ "$GLAB_AUTHENTICATED" = true ]; then
		if [ "$GLAB_ACTIVE_AMBIGUOUS" = true ]; then
			printf '  Active account:  <ambiguous — several accounts configured>\n'
			printf '  Candidates:      %s\n' "$GLAB_ACTIVE_ACCOUNTS"
			printf '  Hint:            re-run with --hostname HOST to pick one\n'
		else
			printf '  Active account:  %s\n' "${GLAB_ACTIVE_ACCOUNT:-<none>}"
			printf '  Host:            %s\n' "${GLAB_HOST:-<none>}"
		fi
		if [ -n "$REC_DATA" ]; then
			printf '  Accounts:\n'
			# A row is starred when it is the resolved active pair. Match login
			# AND host so a same-login row on another host is not mis-starred.
			printf '%s\n' "$REC_DATA" | while IFS="$TAB" read -r e_host e_login; do
				[ -n "$e_login" ] || continue
				if [ "$e_login" = "$GLAB_ACTIVE_ACCOUNT" ] && [ "$e_host" = "$GLAB_HOST" ]; then
					printf '    * %s (%s) [active]\n' "$e_login" "$e_host"
				else
					printf '      %s (%s)\n' "$e_login" "$e_host"
				fi
			done
		fi
	fi

	printf '\n'
	printf 'GLAB_INSTALLED=%s\n'        "$GLAB_INSTALLED"
	printf 'GLAB_AUTHENTICATED=%s\n'    "$GLAB_AUTHENTICATED"
	printf 'GLAB_ACTIVE_ACCOUNT=%s\n'   "$GLAB_ACTIVE_ACCOUNT"
	printf 'GLAB_HOST=%s\n'             "$GLAB_HOST"
	printf 'GLAB_ACCOUNTS=%s\n'         "$GLAB_ACCOUNTS"
	printf 'GLAB_ACTIVE_AMBIGUOUS=%s\n' "$GLAB_ACTIVE_AMBIGUOUS"
	printf 'GLAB_ACTIVE_ACCOUNTS=%s\n'  "$GLAB_ACTIVE_ACCOUNTS"
}

# ---------------------------------------------------------------------------
# parse_records — print "REC<TAB>host<TAB>login" for every login line in
# STATUS_OUT (respecting the optional --hostname filter), plus a trailing
# "META<TAB>COUNT<TAB>n". Identical host+login pairs are deduped, so a glab
# version that prints an instance twice cannot manufacture ambiguity.
# ---------------------------------------------------------------------------
parse_records() {
	printf '%s\n' "$1" | awk -v want="$OPT_HOSTNAME" '
		/Logged in to /{
			host=""; login=""
			for (i = 1; i <= NF; i++) {
				if      ($i == "to") host  = $(i + 1)
				else if ($i == "as") login = $(i + 1)
			}
			if (host == "" || login == "") next
			if (want != "" && host != want) next
			key = host "\t" login
			if (key in seen) next
			seen[key] = 1
			n++
			printf "REC\t%s\t%s\n", host, login
		}
		END { printf "META\tCOUNT\t%d\n", n + 0 }
	'
}

# ---------------------------------------------------------------------------
# 0. glab must be installed (and awk, which does all the parsing).
# ---------------------------------------------------------------------------
if ! command -v glab >/dev/null 2>&1; then
	error "GitLab CLI (glab) is not installed"
	warn  "install it from https://gitlab.com/gitlab-org/cli then re-run"
	emit
	exit 1
fi
GLAB_INSTALLED=true

if ! command -v awk >/dev/null 2>&1; then
	error "awk is not installed (required to parse glab auth status)"
	emit
	exit 1
fi

# ---------------------------------------------------------------------------
# 1. Ask glab for the auth state. Capture combined output (glab writes parts of
#    this block to stderr) and key the verdict off WHAT WE PARSED, not off the
#    exit code: `--all` covers several instances at once, so one instance with a
#    bad credential must not hide the healthy ones. A non-zero exit with usable
#    records is surfaced as a warning; a non-zero exit with NO records is
#    "not authenticated".
#
#    Without --hostname we ask for --all: a bare `glab auth status` reports only
#    the instance of the CURRENT CONTEXT (git remote / GITLAB_HOST / config), so
#    it would silently hide a second configured instance — exactly the
#    plausible-but-wrong answer this script exists to refuse. If --all is
#    rejected (an older glab without that flag), we retry the bare form rather
#    than mis-reporting an authenticated user as logged out.
# ---------------------------------------------------------------------------
# load_records COMMAND... — run COMMAND (a `glab auth status` invocation), then
# parse and count what it reported. Sets FOUR globals, which is why it has a
# header at all (the same discipline manage_glab_accounts.sh's parse_auth
# follows):
#   STATUS_OUT  — COMMAND's combined stdout+stderr, VERBATIM. Never echoed to the
#                 user: `glab auth status` can include token material, so this is
#                 used only to decide WHAT to say, never quoted in a diagnostic.
#   STATUS_RC   — COMMAND's exit status. Kept because a non-zero exit is the only
#                 way to distinguish "glab could not answer" (locked keyring,
#                 unreachable self-managed host) from "glab answered: logged out".
#   PARSED      — parse_records's REC/META lines.
#   ACCT_COUNT  — the parsed account count, defaulted to 0.
# Factored out because this exact four-step sequence runs TWICE — once for the
# primary query, once for the bare-glab fallback below — and it was previously
# copy-pasted, so the two copies could drift.
load_records() {
	if STATUS_OUT=$("$@" 2>&1); then
		STATUS_RC=0
	else
		STATUS_RC=$?
	fi
	PARSED=$(parse_records "$STATUS_OUT")
	ACCT_COUNT=$(printf '%s\n' "$PARSED" | awk -F"$TAB" '$1=="META"&&$2=="COUNT"{print $3}')
	: "${ACCT_COUNT:=0}"
}

if [ -n "$OPT_HOSTNAME" ]; then
	load_records glab auth status --hostname "$OPT_HOSTNAME"
else
	load_records glab auth status --all
fi

if [ "$ACCT_COUNT" -eq 0 ] && [ -z "$OPT_HOSTNAME" ]; then
	load_records glab auth status
fi

if [ "$ACCT_COUNT" -eq 0 ]; then
	if [ -n "$OPT_HOSTNAME" ]; then
		error "glab is installed but not authenticated to host '$OPT_HOSTNAME'"
	else
		error "glab is installed but not authenticated to any host"
	fi

	# WHY THIS BRANCH ALSO REPORTS STATUS_RC (OBS-001): zero parsed records has
	# THREE causes, and this branch used to name only one of them — so a locked
	# keyring, an unreachable self-managed host, or a future glab whose output this
	# parser cannot read all came back as a flat "logged out", sending the operator
	# into a login loop that could not fix the real problem. The verdict above is
	# unchanged (fail closed, do not act), but the reason is no longer asserted
	# where it is not known: what follows DISAMBIGUATES rather than guesses.
	#
	# STATUS_OUT itself is still NOT echoed. `glab auth status` output can carry
	# token material, and keeping it out of this script's diagnostics is a
	# deliberate privacy choice — only its EMPTINESS is reported, never its
	# content.
	if [ "$STATUS_RC" -ne 0 ]; then
		warn "glab auth status itself exited $STATUS_RC, so glab may not have been ABLE to answer rather than answering \"logged out\" — a locked keyring or an unreachable self-managed host looks exactly like this"
		warn "run 'glab auth status --all' yourself before assuming the credential is missing"
	elif [ -z "$OPT_HOSTNAME" ] && [ -n "$STATUS_OUT" ]; then
		# Only meaningful UNSCOPED: with --hostname, parse_records also drops every
		# line for another host, so zero records is the expected result for a host
		# that simply has no login and says nothing about the parser.
		warn "glab exited 0 and DID print something, but no parseable 'Logged in to <host> as <login>' line was found — the parser may need updating for this glab version"
		warn "run 'glab auth status --all' yourself to see the output this script could not read"
	elif [ -n "$OPT_HOSTNAME" ]; then
		warn "a --hostname query cannot tell \"this host has no login\" apart from \"glab printed something this parser could not read\" — re-run without --hostname if you believe a credential exists for it"
	fi

	warn  "if the credential really is missing, authenticate (or switch) with the interactive manage_glab_accounts.sh"
	emit
	exit 1
fi
GLAB_AUTHENTICATED=true

if [ "$STATUS_RC" -ne 0 ]; then
	warn "glab auth status exited $STATUS_RC but reported usable accounts; at least one configured instance may be unhealthy"
fi

REC_DATA=$(printf '%s\n' "$PARSED" | awk -F"$TAB" -v OFS="$TAB" '$1=="REC"{print $2,$3}')

# Inventory of logins (host-filtered), comma-separated, in glab's output order.
GLAB_ACCOUNTS=""
while IFS="$TAB" read -r _ r_login; do
	[ -n "$r_login" ] || continue
	if [ -z "$GLAB_ACCOUNTS" ]; then GLAB_ACCOUNTS=$r_login
	else GLAB_ACCOUNTS="$GLAB_ACCOUNTS,$r_login"; fi
done <<EOF
$REC_DATA
EOF

# ---------------------------------------------------------------------------
# 2. Ambiguity gate: MORE THAN ONE candidate account (normally one per host,
#    but also a defensive guard against a future glab surfacing two logins for
#    the SAME host) means the active one is not knowable. Do NOT guess: surface
#    the full candidate set and fail closed.
# ---------------------------------------------------------------------------
if [ "$ACCT_COUNT" -gt 1 ]; then
	GLAB_ACTIVE_AMBIGUOUS=true
	# Build a deterministic (LC_ALL=C sorted) "login@host,..." set.
	#
	# `set -f` guards the unquoted command substitution: splitting it on
	# whitespace is the INTENDED mechanism (one pair per line), but globbing is
	# not — a '*' or '?' surviving from a parsed login/host would otherwise be
	# filename-expanded against the cwd and fabricate the candidate set. Same
	# guard the MR scripts' split_csv_list puts on its own `set -- $value`.
	set -f
	for pair in $(printf '%s\n' "$REC_DATA" | while IFS="$TAB" read -r a_host a_login; do
		[ -n "$a_login" ] && printf '%s@%s\n' "$a_login" "$a_host"
	done | sort); do
		if [ -z "$GLAB_ACTIVE_ACCOUNTS" ]; then GLAB_ACTIVE_ACCOUNTS=$pair
		else GLAB_ACTIVE_ACCOUNTS="$GLAB_ACTIVE_ACCOUNTS,$pair"; fi
	done
	set +f
	error "several accounts are configured ($GLAB_ACTIVE_ACCOUNTS); cannot pick one"
	if [ -n "$OPT_HOSTNAME" ]; then
		warn "host '$OPT_HOSTNAME' itself reported more than one login — resolve it interactively with manage_glab_accounts.sh"
	else
		warn "re-run with --hostname HOST to resolve a single account"
	fi
	emit
	exit 1
fi

# ---------------------------------------------------------------------------
# 3. Resolve THE single account + host (exactly one record survives here).
# ---------------------------------------------------------------------------
# `|| true`: a `read` that hits EOF returns non-zero, which would abort the
# script under `set -e` instead of reaching the explicit empty-value check below.
IFS="$TAB" read -r GLAB_HOST GLAB_ACTIVE_ACCOUNT <<EOF || true
$REC_DATA
EOF

if [ -z "$GLAB_ACTIVE_ACCOUNT" ]; then
	if [ -n "$OPT_HOSTNAME" ]; then
		error "authenticated, but no account resolved for host '$OPT_HOSTNAME'"
	else
		error "authenticated, but could not resolve an account"
	fi
	emit
	exit 1
fi

# Default host if we resolved an account but never captured a host.
[ -n "$GLAB_HOST" ] || GLAB_HOST=${OPT_HOSTNAME:-gitlab.com}

# The resolved account, expressed as the single-element candidate set.
GLAB_ACTIVE_ACCOUNTS="$GLAB_ACTIVE_ACCOUNT@$GLAB_HOST"

emit
exit 0
