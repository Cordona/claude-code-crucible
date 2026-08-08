#!/usr/bin/env sh
#
# resolve-identity.sh — deterministically resolve & reconcile the git signing
#                       identity BEFORE a commit or signed tag.
#
# Purpose:
#   Reads the git config + signing-key material and asserts that the committer
#   email, the signing key's email, and the Signed-off-by it would write are one
#   consistent identity. Surfaces an author != committer divergence. READ-ONLY:
#   it never modifies git config, keys, or the repo, and makes no network call
#   unless --github or --gitlab is given.
#
# Usage:
#   resolve-identity.sh [--github] [--gitlab] [--gitlab-host HOST] [--email E]
#                       [--name N] [--signingkey K] [--format gpg|ssh]
#                       [-h|--help]
#
#   (no flag)     Run the three git-local checks + the author/committer note
#                 against the configured identity.
#   --email E     Reconcile a SPECIFIED committer email instead of the
#                 configured user.email (e.g. to re-verify after a switch).
#   --name N      Override user.name for the Signed-off-by line.
#   --signingkey K  Override user.signingkey.
#   --format F    Override gpg.format (gpg/openpgp or ssh).
#   --github      ADDITIONALLY verify user.email is a GitHub-verified address,
#                 but only if `gh` is installed AND authenticated. If gh is
#                 absent/unauthenticated the check is SKIPPED, and if the API
#                 call itself fails the result is UNKNOWN — neither is ever a
#                 failure. Only a SUCCESSFUL call that does not list the email
#                 is fatal.
#   --gitlab      ADDITIONALLY verify user.email is a GitLab-confirmed address,
#                 but only if `glab` (and `jq`) is installed AND glab is
#                 authenticated. Same four states and the same fatal-only-on-a-
#                 real-negative rule as --github: absent tooling is SKIPPED, a
#                 failed/unparseable call is UNKNOWN, and only a SUCCESSFUL call
#                 that does not list the email is fatal.
#                 The two flags are INDEPENDENT — either, both, or neither may be
#                 passed, and each computes its own status. (A real repo has one
#                 remote, so in practice one fires; a caller that does not yet
#                 know the backend may pass both.)
#   --gitlab-host HOST
#                 OPTIONAL companion to --gitlab: pin the GitLab INSTANCE the
#                 check queries (bare host, optional ':port', no scheme).
#                 Requires --gitlab. WITHOUT it --gitlab can only ever report
#                 'unknown' or 'skipped' — never a definite verified/unverified.
#                 See "HOST PINNING" below.
#   -h,--help     Show this help.
#
# HOST PINNING — why an UNPINNED --gitlab is CAPPED at 'unknown'/'skipped':
#   `glab` resolves its target instance from AMBIENT state — the cwd's git
#   remotes, an inherited $GITLAB_HOST, its own config, defaulting to
#   gitlab.com. The `glab auth status --all` precondition below only proves glab
#   is authenticated to SOME configured instance, not to the one this identity
#   belongs to. An unpinned resolution can therefore describe a DIFFERENT
#   instance/account than the identity being reconciled — and `verified` and
#   `unverified` are both CLAIMS ABOUT ONE SPECIFIC ACCOUNT that such a
#   resolution cannot back up: it could report `verified` because the address
#   happens to be confirmed on gitlab.com when the real target is self-managed,
#   or `unverified` (FATAL) when --gitlab was passed speculatively against a
#   non-GitLab remote.
#
#   So the answer is CAPPED, not merely caveated. With --gitlab and no
#   --gitlab-host: 'skipped' when the tooling is absent/unauthenticated (as
#   ever), otherwise 'unknown' with a warning — and NO api call is made, because
#   its answer could not be used either way. This is the same "never assert on a
#   channel that cannot support the assertion" rule the four-state machine
#   already applies to a query that failed.
#
#   --gitlab-host unlocks the full four states by exporting the caller's host as
#   GITLAB_HOST for this process before BOTH the auth check and every api call —
#   glab's documented per-invocation host selector. It also fails closed: when
#   the cwd is a checkout of a different instance glab refuses outright ("none of
#   the git remotes … correspond to the GITLAB_HOST environment variable")
#   instead of answering from the wrong place.
#
#   The flag stays OPTIONAL — unlike procedure-glab-mr/find-mr.sh's
#   --confirmed-host, which is REQUIRED because it guards a WRITE — specifically
#   so a caller that does not yet know the backend can pass --github AND
#   --gitlab speculatively. The cap is what makes that safe: the speculative
#   side yields 'unknown'/'skipped' rather than a possibly-wrong definite answer.
#
#   CALLER CONTRACT — the value's PROVENANCE matters as much as its shape: pass
#   only a host the GitLab ACCOUNT GATE (procedure-gitlab-auth) confirmed the
#   user is authenticated to, which is exactly the provenance find-mr.sh's
#   --confirmed-host requires. NEVER read a host straight off an untrusted
#   repo's remote URL without that cross-check: a handed-over or cloned repo can
#   point at an attacker-controlled instance whose /user response trivially
#   manufactures 'verified'. The allow-list below validates the value's SHAPE; it
#   cannot validate its TRUSTWORTHINESS.
#
# Output:
#   stdout — a human-readable identity block AND a machine-parseable KEY=VALUE
#            block the caller can relay. Diagnostics/warnings go to stderr.
#
# Exit codes:
#   0  fields reconcile — ready to commit
#   1  mismatch OR missing/misconfigured signing key — DO NOT commit
#   2  usage error
#
# Portability: POSIX sh only (no bashisms). Runs identically on macOS (BSD
#   userland / Bash 3.2) and Linux (GNU coreutils). shellcheck-clean.
#
set -eu

# Pin glab's own optional output/behavior at FILE TOP-LEVEL, exactly as every
# sibling glab script in this framework does (procedure-glab-mr/find-mr.sh,
# create-mr.sh, update-mr.sh; the procedure-glab-issues suite):
#   GLAB_NO_PROMPT       — glab must never ask this non-interactive script
#                          anything; a prompt would hang the commit gate.
#   GLAB_CHECK_UPDATE    — suppresses the "new version available" notice and the
#                          network round-trip that produces it.
#   GLAB_SHOW_WHATS_NEW  — suppresses the one-time post-upgrade banner.
#
# These are CORRECTNESS, not tidiness: either banner would land in the captured
# stdout of a `glab api` call, break the jq parse, and silently degrade a real
# answer to 'unknown'. They are set unconditionally because they affect nothing
# but glab — the git/gpg/ssh-keygen work below neither reads nor is influenced by
# them. (LC_ALL is the one pin that stays scoped to the --gitlab branch; see
# pin_glab_environment.)
GLAB_NO_PROMPT=true
GLAB_CHECK_UPDATE=false
GLAB_SHOW_WHATS_NEW=false
export GLAB_NO_PROMPT GLAB_CHECK_UPDATE GLAB_SHOW_WHATS_NEW

PROG=${0##*/}

# Temp files holding gh's / glab's own stderr (each created only on its own
# --github / --gitlab path). Two separate variables, not one reused slot: both
# flags may be passed in the same run, and a shared slot would leak whichever
# file was created first.
GH_ERR_FILE=""
GL_ERR_FILE=""
# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() {
	[ -z "$GH_ERR_FILE" ] || rm -f "$GH_ERR_FILE"
	[ -z "$GL_ERR_FILE" ] || rm -f "$GL_ERR_FILE"
}
# EXIT and INT/TERM are SPLIT, not one combined trap. A combined
# `trap cleanup EXIT INT TERM` does not actually terminate on a signal — POSIX
# runs the handler and then RESUMES — so a Ctrl-C during a slow `gh`/`glab` call
# would delete the capture file and then fall into the 'unknown' branch, whose
# read of that now-deleted file trips `set -e`. The script would surface exit 1
# ("identity mismatch, do not commit") for what was actually an interruption.
# Re-running cleanup from the INT/TERM handler is harmless (`rm -f` is
# idempotent); the explicit `exit 130` is what makes an interruption legible.
# Same shape as the sibling procedure-glab-mr/find-mr.sh.
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

# ---------------------------------------------------------------------------
# Diagnostics (all to stderr)
# ---------------------------------------------------------------------------
warn()  { printf '%s: warning: %s\n' "$PROG" "$*" >&2; }
error() { printf '%s: error: %s\n'   "$PROG" "$*" >&2; }

# die <exit-code> <message...>
die() {
	rc=$1
	shift
	error "$*"
	exit "$rc"
}

# make_err_file: print a fresh temp file path to hold a CLI's own stderr, or an
# EMPTY string when mktemp cannot deliver one (an unwritable TMPDIR).
#
# The empty-string fallback is the point. A bare `X=$(mktemp …)` is an UNGUARDED
# assignment: mktemp failing trips `set -e` and exits 1 — indistinguishable from
# a real identity mismatch — on a path whose entire contract is "tooling trouble
# is never fatal". Callers treat an empty slot as "stderr not captured" and
# degrade to discarding it, which costs only the relayed CLI message.
make_err_file() {
	mef=$(mktemp "${TMPDIR:-/tmp}/resolve-identity.XXXXXX" 2>/dev/null) || {
		warn "could not create a temp file under ${TMPDIR:-/tmp} to capture the platform CLI's stderr; its own error message will not be relayed (the check itself still runs)"
		printf '\n'
		return 0
	}
	# mktemp echoes back the template it was given, so a RELATIVE $TMPDIR yields a
	# relative path. This script never changes directory, so this is defensive —
	# it mirrors the sibling procedure-glab-mr scripts so the two cannot drift.
	case $mef in
		/*) ;;
		*) mef="$PWD/$mef" ;;
	esac
	printf '%s\n' "$mef"
}

# relay_tool_err <errfile> <tool>: relay the CLI's own captured stderr as a
# SECOND warning line, after the caller's deterministic sentence. That order is a
# consumed contract — procedure-git-identity's report template relays "line 1 =
# what went unchecked, line 2 = the CLI's real cause" — so this never warns
# first.
#
# The `cat` is deliberately tolerant of a missing/unreadable file: the slot is
# legitimately empty when make_err_file could not create one, and an INT/TERM
# whose handler already ran cleanup can delete it mid-flight. Neither may trip
# `set -e` here.
relay_tool_err() {
	[ -n "$1" ] || return 0
	rte_text=$(cat "$1" 2>/dev/null || true)
	[ -z "$rte_text" ] || warn "$2 reported: $rte_text"
}

usage() {
	cat <<EOF
Usage: $PROG [--github] [--gitlab] [--gitlab-host HOST] [--email E] [--name N]
             [--signingkey K] [--format gpg|ssh] [-h|--help]

Resolve and reconcile the git signing identity before a commit or signed tag.
Read-only; no network unless --github or --gitlab is given.

Options:
  --email E       Reconcile a specified committer email instead of user.email.
  --name N        Override user.name (for the Signed-off-by line).
  --signingkey K  Override user.signingkey.
  --format F      Override gpg.format (gpg/openpgp or ssh).
  --github        Additionally verify user.email is GitHub-verified (only if
                  'gh' is installed and authenticated; otherwise skipped).
                  Reports verified / unverified / unknown / skipped; only
                  'unverified' (a successful query that omits the email) is
                  fatal.
  --gitlab        Additionally verify user.email is GitLab-confirmed (only if
                  'glab' and 'jq' are installed and glab is authenticated;
                  otherwise skipped). Checks the account's PRIMARY address and
                  its additional confirmed addresses. Reports the same four
                  states with the same rule: only 'unverified' (both queries
                  succeeded and neither listed the email) is fatal. Independent
                  of --github; both may be passed.
  --gitlab-host HOST
                  Pin the GitLab instance --gitlab queries (bare hostname,
                  optional ':port', no scheme). Optional, but WITHOUT it
                  --gitlab is capped at 'unknown'/'skipped' and never reports a
                  definite verified/unverified: unpinned, glab picks the
                  instance from ambient state (cwd git remote, \$GITLAB_HOST, its
                  config, else gitlab.com), which may be a different account
                  than the identity being reconciled — and neither definite
                  answer would be about the right account. Pass a host the
                  GitLab account gate CONFIRMED, never one read off an untrusted
                  repo's remote. Requires --gitlab.
  -h, --help      Show this help.

Exit codes:
  0  identity reconciles — ready to commit
  1  mismatch or missing/misconfigured signing key — do not commit
  2  usage error
EOF
}

# ---------------------------------------------------------------------------
# git config helper — never triggers set -e on an unset key
# ---------------------------------------------------------------------------
git_cfg() {
	git config "$1" 2>/dev/null || true
}

# expand_home <path>: expand a leading '~/' to "$HOME/" (POSIX-safe; avoids
# tilde-in-quotes ambiguity). Any other path is returned unchanged.
expand_home() {
	eh_rest=${1#\~/}
	if [ "$eh_rest" != "$1" ]; then
		printf '%s\n' "$HOME/$eh_rest"
	else
		printf '%s\n' "$1"
	fi
}

# ssh_key_fields <line>: locate the SSH key by KEYTYPE PATTERN (not position),
# so a trailing comment field (common in id_*.pub / allowed_signers lines) can
# never be mistaken for the key. Prints "TYPE<TAB>BASE64<TAB>COMMENT" (COMMENT
# may be empty); prints nothing if the line carries no recognizable key.
# NOTE: this helper is deliberately duplicated across the suite's scripts so
# each remains a standalone, self-contained file (no sourcing dependency).
ssh_key_fields() {
	printf '%s\n' "$1" | awk '
		function iskt(t) {
			return (t == "ssh-ed25519" || t == "ssh-rsa" || t == "ssh-dss" ||
				t == "ecdsa-sha2-nistp256" || t == "ecdsa-sha2-nistp384" ||
				t == "ecdsa-sha2-nistp521" ||
				t == "sk-ssh-ed25519@openssh.com" ||
				t == "sk-ecdsa-sha2-nistp256@openssh.com")
		}
		{
			for (i = 1; i <= NF; i++) {
				if (iskt($i)) {
					b = (i < NF)     ? $(i + 1) : ""
					c = (i + 1 < NF) ? $(i + 2) : ""
					printf "%s\t%s\t%s\n", $i, b, c
					exit
				}
			}
		}'
}

# assert_printable_value <label> <value>: die when <value> carries a control
# character.
#
# This guards the MACHINE-PARSEABLE KEY=VALUE block, whose consumers (this
# skill's report template, and any script relaying it) parse it line by line. A
# `git config user.name` holding a literal newline — "Bob<LF>
# IDENTITY_GITLAB=verified" — would print as extra IDENTITY_* lines a consumer
# cannot distinguish from real ones: enough to forge IDENTITY_STATUS=reconciled,
# or to displace the {platform_unknown_notice} that exists precisely so a
# fail-open is never rendered quietly. Every value reaching that block is
# therefore checked, not just the email.
#
# The message never echoes the value: that would carry the very control bytes
# this rejects straight into the diagnostic stream. No legitimate name, key spec
# or path contains one, and ordinary spaces in a name are untouched — only
# [:cntrl:] is rejected.
#
# NOT rejected, deliberately: '<' and '>' in a name. IDENTITY_SIGNOFF's format is
# "NAME <EMAIL>", so a name containing them can make that ONE line's shape
# ambiguous ("A <x@y> B <e@f>") — but it cannot forge a KEY=VALUE line, cannot
# reach another field, and cannot flip a status; the sign-off is also presented
# to the human for confirmation before any commit. Rejecting them would refuse
# legitimate names, so this stays a documented residual instead.
assert_printable_value() {
	case "$2" in
		*[[:cntrl:]]*) die 1 "$1 contains a control character (it would forge lines in the machine-parseable output block); fix it before committing" ;;
	esac
}

# assert_reconcilable_email <label> <value>: the stricter check for a value used
# as an ADDRESS — it must survive both the output block and every matcher.
#
# Rejects, beyond assert_printable_value's control characters:
#   whitespace   the address is a PATTERN for `grep -F`, which reads an embedded
#                newline as a list of ALTERNATIVE fixed patterns: such an address
#                could match a line it does not equal and reconcile spuriously.
#                No legitimate address contains whitespace at all.
#   a leading -  belt-and-suspenders. Every matcher now passes its pattern via
#                `grep -Fxq -e`, so grep can no longer read one as an option —
#                but a bad address should never reach a matcher at all, and one
#                more case arm costs nothing. (Unguarded AND without the -e,
#                "--regexp=" made the effective pattern EMPTY, which -Fx matches
#                against the blank line an empty list prints: a false 'verified'
#                with nothing actually matched.)
#
# ORDER MATTERS, in both directions. Whitespace is tested FIRST because a newline
# is BOTH whitespace and a control character, and "contains whitespace" is the
# consumed diagnostic for that case (a test pins it). The leading-dash arm is
# tested LAST because it is the only one that echoes the value, which is safe only
# once the value is known to hold no whitespace and no control byte — echoing
# those would splice attacker-chosen bytes into the diagnostic stream.
assert_reconcilable_email() {
	case "$2" in
		*[[:space:]]*) die 1 "$1 contains whitespace (not a valid address)" ;;
	esac
	assert_printable_value "$1" "$2"
	case "$2" in
		-*) die 1 "$1 begins with '-' (not a valid address): $2" ;;
	esac
}

# glab_authenticated: true if glab is logged in to ANY configured instance.
# A bare `glab auth status` only checks the instance of the CURRENT CONTEXT, so a
# self-managed project read from an unrelated cwd could fail it spuriously and
# skip the check for no reason. `--all` covers every configured instance. Try the
# bare form first (cheapest, and works on any glab), then --all; only both failing
# means glab is genuinely authenticated nowhere. This two-step is the convention
# already established by the sibling procedure-glab-mr scripts (find-mr.sh).
# There is no `gh` equivalent to mirror here — gh's own `auth status` already
# reports every host — so this is glab-specific, not a divergence from --github.
#
# NOTE what this does NOT establish: `--all` green-lights on authentication to
# ANY instance, which is deliberately weaker than "authenticated to the instance
# this identity belongs to". Pinning GITLAB_HOST (--gitlab-host) is what makes
# the subsequent api calls — and this check itself, since the pin is exported
# first — target one known instance. See "HOST PINNING" in this file's header.
glab_authenticated() {
	glab auth status >/dev/null 2>&1 || glab auth status --all >/dev/null 2>&1
}

# is_valid_confirmed_host VALUE — allow-list for --gitlab-host before it becomes
# this process's GITLAB_HOST: letters, digits, '.', '-', '_' and an optional
# ':port'. Rejects whitespace, shell metacharacters, a leading '-' (which glab
# would read as a flag), and any empty label. Spelled the way `glab auth status`
# reports a host, so the account gate's answer can be passed straight through.
#
# A SCHEME-QUALIFIED value ("https://gitlab.com") is rejected on purpose: glab
# accepts both spellings, so allowing them here would let two different strings
# name one host, and the whole point of this flag is a single unambiguous target
# the caller and this script agree on.
#
# NAME and BODY are deliberately IDENTICAL to the copies in
# procedure-glab-mr/find-mr.sh + update-mr.sh and the procedure-glab-issues
# suite. Helpers in this framework are duplicated per script, never sourced, so
# the shared NAME is the only thing that makes all copies greppable as one family
# when one of them needs a fix — a differently-named copy silently misses that
# grep. Do not rename or diverge this in isolation.
#
# It validates the value's SHAPE only. Its PROVENANCE is a caller contract — see
# "HOST PINNING" in this file's header — and cannot be checked here.
is_valid_confirmed_host() {
	case "$1" in
		'') return 1 ;;
		*[!A-Za-z0-9._:-]*) return 1 ;;
		-*) return 1 ;;
		.*|*.|*..*) return 1 ;;
		*) return 0 ;;
	esac
}

# pin_glab_environment: make every `glab` invocation on the --gitlab path
# byte-deterministic, and target the caller's confirmed instance when one was
# named. Called before the preconditions so it also covers glab_authenticated.
#
# ONLY LC_ALL is set here — the other three glab pins (GLAB_NO_PROMPT,
# GLAB_CHECK_UPDATE, GLAB_SHOW_WHATS_NEW) live at file top-level with the
# siblings. LC_ALL is the one that must stay branch-scoped: unlike those three,
# which nothing but glab reads, LC_ALL=C changes the locale-sensitive output of
# the git/gpg/ssh-keygen work ABOVE, whose parsing this script must not disturb.
# Here it buys byte-deterministic collation and an ASCII-only case fold for
# email_listed.
#
# GITLAB_HOST is glab's documented per-invocation host selector; see "HOST
# PINNING" in this file's header for why an unpinned run cannot answer definitely.
pin_glab_environment() {
	LC_ALL=C
	export LC_ALL
	[ -z "$OPT_GITLAB_HOST" ] || { GITLAB_HOST=$OPT_GITLAB_HOST; export GITLAB_HOST; }
}

# gitlab_tls_verification_disabled: true when glab is configured to SKIP TLS
# certificate verification for the calls this script is about to make.
#
# Why this is checked rather than assumed: glab inherits `skip_tls_verify` from
# ambient configuration, so a user who once set it (commonly for a self-managed
# instance with a private CA) silently removes the only thing binding a `verified`
# answer to the real instance — an on-path attacker could answer /user and
# manufacture it. That is the same untrustworthy-channel case as a failed query,
# so the caller degrades to 'unknown' rather than asserting.
#
# `glab config get` resolves in glab's own documented order — environment
# variable, then local, then global config (verified against glab 1.112.0: the
# env spelling SKIP_TLS_VERIFY is picked up by this very call) — so one read
# covers the env equivalent too. The host-scoped read is a SECOND probe, because
# a per-host entry does not surface in the default lookup; it is guarded on the
# host being set, which the only caller (the PINNED branch) guarantees — the guard
# keeps the function correct on its own terms rather than on its caller's. Both
# reads are tolerant (`|| true`): this is an advisory, and a config read that
# fails must never break the identity gate.
gitlab_tls_verification_disabled() {
	gtvd_value=$(glab config get skip_tls_verify 2>/dev/null || true)
	if [ -n "$OPT_GITLAB_HOST" ] && ! gitlab_config_is_affirmative "$gtvd_value"; then
		gtvd_value=$(glab config get skip_tls_verify --host "$OPT_GITLAB_HOST" 2>/dev/null || true)
	fi
	gitlab_config_is_affirmative "$gtvd_value"
}

# gitlab_config_is_affirmative VALUE — true for the spellings a glab config
# boolean can legitimately carry. An unset key prints nothing (verified), and an
# unrecognized value is NOT treated as affirmative: degrading on a value nobody
# can interpret would warn on noise.
gitlab_config_is_affirmative() {
	case "$1" in
		true|TRUE|True|1|yes|YES|y|on) return 0 ;;
		*) return 1 ;;
	esac
}

# resolve_gitlab_status: print exactly one of verified|unverified|unknown for
# USER_EMAIL against the authenticated GitLab account. Diagnostics go to stderr;
# this always exits 0 — the printed STATUS is its answer, not its exit code.
#
# Only ever called on a PINNED host (see the --gitlab branch): an unpinned run is
# capped before it gets here, because none of these three answers except 'unknown'
# would be about a known account.
#
# TWO probes, because GitLab splits the account's addresses across two endpoints,
# and that split is the whole reason this is not a one-liner:
#
#   GET /user/emails  returns ONLY the ADDITIONAL (secondary) addresses. The
#                     account's PRIMARY address is NOT in this list — the
#                     endpoint presents `current_user.emails`, and GitLab's own
#                     User#verified_emails has to PREPEND `email` (the primary,
#                     held in the users.email column) before concatenating that
#                     association. So the single most common configuration —
#                     user.email IS the account's primary address — is absent
#                     here, and probing only this endpoint would report
#                     'unverified' and refuse the commit on essentially every
#                     real GitLab repo. This is the sharpest divergence from
#                     GitHub, whose /user/emails DOES include the primary.
#   GET /user         returns the PRIMARY address as `.email`, with its
#                     confirmation timestamp as top-level `.confirmed_at`
#                     (Entities::UserPublic exposes both). ONE OBJECT, not a
#                     list — so no --paginate, and a different filter.
#
# The primary probe is SHORT-CIRCUITED: it runs only when the secondary list did
# not already answer 'verified', so the multi-address case still costs one call.
#
# A probe that COULD NOT ANSWER contributes UNKNOWN, never a negative — the rule
# the whole state machine rests on, now applied across two calls. Only when both
# probes answered cleanly and NEITHER listed the address is the result the real
# negative 'unverified'. In particular a failed SECONDARY probe must never
# manufacture a false negative for an address that lives on the PRIMARY path.
resolve_gitlab_status() {
	rgs_unanswered=0

	if rgs_secondaries=$(gitlab_confirmed_secondaries); then
		if email_listed "$USER_EMAIL" "$rgs_secondaries"; then
			printf 'verified\n'
			return 0
		fi
	else
		rgs_unanswered=1
	fi

	if rgs_primary=$(gitlab_confirmed_primary); then
		if email_listed "$USER_EMAIL" "$rgs_primary"; then
			printf 'verified\n'
			return 0
		fi
	else
		rgs_unanswered=1
	fi

	if [ "$rgs_unanswered" -eq 1 ]; then
		printf 'unknown\n'
	else
		printf 'unverified\n'
	fi
	return 0
}

# gitlab_confirmed_secondaries: print the account's CONFIRMED ADDITIONAL email
# addresses, one per line (legitimately none). Exit 0 = the question was
# answered; 1 = it could not be, with the reason already warned.
#
# --paginate IS supported by `glab api` (verified in `glab api --help`) and is
# required for CORRECTNESS, not completeness: /user/emails is a paginated list
# endpoint defaulting to per_page=20 (verified live — the response carries
# `X-Per-Page: 20`) and `glab api` does not paginate on its own. Without it an
# account with more addresses than one page gets a query that SUCCEEDS over a
# truncated list, silently omitting user.email.
#
# Verified about --paginate's OUTPUT SHAPE, because the filter depends on it:
# under the default --output json glab emits ONE JSON ARRAY PER PAGE,
# concatenated — it does NOT merge them into a single array, despite what glab's
# own --help says. That is harmless only because jq consumes a STREAM of JSON
# values, so the filter runs once per page-array in turn; cross-checked
# element-for-element against `--output ndjson` on a deliberately 20-page
# endpoint. Do not "simplify" this to a filter that assumes one top-level array.
gitlab_confirmed_secondaries() {
	gcs_raw=$(gl_api user/emails --paginate) || {
		warn "could not determine whether user.email ($USER_EMAIL) is GitLab-confirmed: 'glab api user/emails' failed (candidate causes: the glab token lacks a scope that can read the account's email addresses ('read_user' or 'api'), a network failure, or an API rate limit). If it is the scope, re-authenticate with: glab auth login"
		relay_tool_err "$GL_ERR_FILE" glab
		return 1
	}
	if gitlab_body_is_blank "$gcs_raw"; then
		warn "could not determine whether user.email ($USER_EMAIL) is GitLab-confirmed: 'glab api user/emails' succeeded but returned a blank body"
		return 1
	fi
	# `type != "array"` is an explicit SHAPE GUARD, not decoration: a bare `.[]`
	# iterates an OBJECT's values too, so an error document served with a 0 exit
	# ({"message": "401 Unauthorized"}) would yield no output and read as a
	# definite negative. Erroring makes it UNKNOWN instead. Applied per top-level
	# value, so it also catches a bad page mid-stream.
	gcs_confirmed=$(printf '%s\n' "$gcs_raw" | jq -r '
		if type != "array" then error("not a JSON array") else .[] end
		| select(.confirmed_at != null) | .email // empty') || {
		warn "could not determine whether user.email ($USER_EMAIL) is GitLab-confirmed: the 'glab api user/emails' response did not parse as the expected JSON array of email objects"
		return 1
	}
	printf '%s\n' "$gcs_confirmed"
}

# gitlab_confirmed_primary: print the account's PRIMARY email address, but ONLY
# when it is confirmed (non-null top-level .confirmed_at) — otherwise print
# nothing. Exit 0 = the question was answered; 1 = it could not be.
#
# GET /user returns a single OBJECT: no --paginate (there is nothing to page),
# and the filter reads .email/.confirmed_at off the object directly instead of
# iterating an array. The `.id | type` guard is the same shape guard as the
# secondary probe's, for the same reason — without it an error document served
# with a 0 exit has a null .confirmed_at, gets filtered out, and would read as
# "answered: the primary is not confirmed". `// empty` keeps a null .email from
# printing as the literal string "null".
gitlab_confirmed_primary() {
	gcp_raw=$(gl_api user) || {
		warn "could not determine whether user.email ($USER_EMAIL) is the GitLab account's confirmed PRIMARY address: 'glab api user' failed (candidate causes: the glab token lacks a scope that can read the account ('read_user' or 'api'), a network failure, or an API rate limit). If it is the scope, re-authenticate with: glab auth login"
		relay_tool_err "$GL_ERR_FILE" glab
		return 1
	}
	if gitlab_body_is_blank "$gcp_raw"; then
		warn "could not determine whether user.email ($USER_EMAIL) is the GitLab account's confirmed PRIMARY address: 'glab api user' succeeded but returned a blank body"
		return 1
	fi
	gcp_email=$(printf '%s\n' "$gcp_raw" | jq -r '
		if (.id | type) != "number" then error("not a GitLab user object") else . end
		| select(.confirmed_at != null) | .email // empty') || {
		warn "could not determine whether user.email ($USER_EMAIL) is the GitLab account's confirmed PRIMARY address: the 'glab api user' response did not parse as the expected JSON user object"
		return 1
	}
	printf '%s\n' "$gcp_email"
}

# gl_api <args...>: run `glab api <args>`, capturing glab's own stderr to
# GL_ERR_FILE so a failure can be relayed verbatim (--paginate widens the failure
# set, so no single asserted cause would be right). An empty slot — mktemp could
# not deliver one, see make_err_file — degrades to discarding it. Prints the
# response body; the exit status is glab's, which is the signal the whole
# verified/unknown split rests on.
gl_api() {
	glab api "$@" 2>"${GL_ERR_FILE:-/dev/null}"
}

# gitlab_body_is_blank <body>: true when <body> holds no non-whitespace byte.
#
# Handing a blank body to jq yields no output at exit 0 (jq exits 0 on empty
# input), which would read as a definite negative — the one conflation this state
# machine exists to prevent. The test is "contains no non-blank character" rather
# than `[ -z … ]` because command substitution strips only TRAILING newlines: a
# whitespace-only body slips straight past an emptiness check.
gitlab_body_is_blank() {
	case $1 in
		*[![:space:]]*) return 1 ;;
		*) return 0 ;;
	esac
}

# email_listed <candidate> <newline-separated-list>: true when <candidate> occurs
# in <list>, compared CASE-INSENSITIVELY.
#
# WHY case-folded here but NOT on the --github path: GitLab down-cases the
# addresses it stores (Devise `case_insensitive_keys`), so a mixed-case
# `git config user.email` — "First.Last@corp.com" — would never match its own
# confirmed "first.last@corp.com" and would be refused as unverified. GitHub
# returns addresses in their REGISTERED form and an existing test pins that
# path's case-sensitive compare as deliberate, so only this side folds.
#
# `-e` passes the needle as a PATTERN, never as an operand grep could read as an
# option — see assert_reconcilable_email. <candidate> also cannot contain a
# newline (which grep -F would split into alternative patterns): both are
# rejected outright far above, before any matcher can see them.
email_listed() {
	el_needle=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
	printf '%s\n' "$2" | tr '[:upper:]' '[:lower:]' | grep -Fxq -e "$el_needle"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
DO_GITHUB=0
DO_GITLAB=0
OPT_GITLAB_HOST=""
OPT_EMAIL=""
OPT_NAME=""
OPT_SIGNINGKEY=""
OPT_FORMAT=""

# need_arg <flag> <value-or-empty>: fail 2 if the option value is missing.
need_arg() {
	[ -n "${2:-}" ] || { usage >&2; die 2 "option $1 requires an argument"; }
}

while [ $# -gt 0 ]; do
	case "$1" in
		--github) DO_GITHUB=1 ;;
		--gitlab) DO_GITLAB=1 ;;
		--gitlab-host) need_arg "$1" "${2:-}"; OPT_GITLAB_HOST=$2; shift ;;
		--email)      need_arg "$1" "${2:-}"; OPT_EMAIL=$2;      shift ;;
		--name)       need_arg "$1" "${2:-}"; OPT_NAME=$2;       shift ;;
		--signingkey) need_arg "$1" "${2:-}"; OPT_SIGNINGKEY=$2; shift ;;
		--format)     need_arg "$1" "${2:-}"; OPT_FORMAT=$2;     shift ;;
		-h|--help) usage; exit 0 ;;
		--) shift; break ;;
		-*) usage >&2; die 2 "unknown option: $1" ;;
		*)  usage >&2; die 2 "unexpected argument: $1" ;;
	esac
	shift
done

# This tool takes no positional operands; reject any left after '--'.
[ $# -eq 0 ] || { usage >&2; die 2 "unexpected argument: $1"; }

# --gitlab-host is validated BEFORE it can reach `export GITLAB_HOST`, and is a
# usage error (exit 2) without --gitlab rather than a silently-ignored no-op: a
# host that pins nothing is exactly the mistake this flag exists to prevent, and
# exit 2 can never be confused with exit 1's "identity mismatch, do not commit".
if [ -n "$OPT_GITLAB_HOST" ]; then
	is_valid_confirmed_host "$OPT_GITLAB_HOST" \
		|| { usage >&2; die 2 "--gitlab-host must be a bare hostname with an optional ':port' and no scheme, got: $OPT_GITLAB_HOST"; }
	[ "$DO_GITLAB" -eq 1 ] \
		|| { usage >&2; die 2 "--gitlab-host requires --gitlab (alone it pins an instance nothing queries)"; }
fi

# ---------------------------------------------------------------------------
# 0. Must be inside a git repository
# ---------------------------------------------------------------------------
if ! git rev-parse --git-dir >/dev/null 2>&1; then
	die 1 "not inside a git repository"
fi

# ---------------------------------------------------------------------------
# 1. Committer identity (user.name / user.email) — required
# ---------------------------------------------------------------------------
# Overrides (--email/--name) take precedence over the configured values so a
# caller can re-verify a SPECIFIED identity (e.g. right after a switch).
USER_NAME=${OPT_NAME:-$(git_cfg user.name)}
USER_EMAIL=${OPT_EMAIL:-$(git_cfg user.email)}

[ -n "$USER_EMAIL" ] || die 1 "user.email is not set (cannot determine committer identity)"
[ -n "$USER_NAME" ]  || die 1 "user.name is not set (cannot write a Signed-off-by line)"

# Validate EVERY value that will reach the machine-parseable KEY=VALUE block, and
# validate the addresses more strictly still because they are also used as
# matcher PATTERNS. Both checks run here, once, before any value can reach a
# matcher or the output block — see assert_printable_value /
# assert_reconcilable_email for what each rejects and why.
assert_reconcilable_email user.email "$USER_EMAIL"
assert_printable_value user.name "$USER_NAME"

# Field 3: the Signed-off-by line that would be written (== committer identity).
SIGNOFF="$USER_NAME <$USER_EMAIL>"

# ---------------------------------------------------------------------------
# 4. Author vs committer — resolve both, surface a divergence (a warning)
#    Precedence mirrors git: GIT_*_EMAIL > <role>.email > user.email
# ---------------------------------------------------------------------------
COMMITTER_EMAIL=${GIT_COMMITTER_EMAIL:-}
[ -n "$COMMITTER_EMAIL" ] || COMMITTER_EMAIL=$(git_cfg committer.email)
[ -n "$COMMITTER_EMAIL" ] || COMMITTER_EMAIL=$USER_EMAIL

AUTHOR_EMAIL=${GIT_AUTHOR_EMAIL:-}
[ -n "$AUTHOR_EMAIL" ] || AUTHOR_EMAIL=$(git_cfg author.email)
[ -n "$AUTHOR_EMAIL" ] || AUTHOR_EMAIL=$USER_EMAIL

# Both are printed (the author email into the machine block, the committer email
# into the divergence note), and both come from a source the caller does not
# necessarily control — GIT_*_EMAIL in the environment, or a repo-local config.
assert_reconcilable_email "the author email" "$AUTHOR_EMAIL"
assert_reconcilable_email "the committer email" "$COMMITTER_EMAIL"

AUTHOR_COMMITTER_MATCH=true
if [ "$AUTHOR_EMAIL" != "$COMMITTER_EMAIL" ]; then
	AUTHOR_COMMITTER_MATCH=false
	warn "author ($AUTHOR_EMAIL) != committer ($COMMITTER_EMAIL); ensure this is intentional"
fi

# ---------------------------------------------------------------------------
# 2. Signing key — required; email must match user.email
# ---------------------------------------------------------------------------
SIGNINGKEY=${OPT_SIGNINGKEY:-$(git_cfg user.signingkey)}
[ -n "$SIGNINGKEY" ] || die 1 "user.signingkey is not set (no signing key to reconcile)"

# Printed verbatim into the machine block as IDENTITY_SIGNING_KEY. An INLINE ssh
# key legitimately contains spaces ("ssh-ed25519 AAAA… comment"), so only control
# characters are rejected — a newline is what would forge an output line.
assert_printable_value user.signingkey "$SIGNINGKEY"

GPG_FORMAT=${OPT_FORMAT:-$(git_cfg gpg.format)}
[ -n "$GPG_FORMAT" ] || GPG_FORMAT=openpgp

SIGN_METHOD=""
SIGN_KEY_ID=""
SIGN_KEY_FPR=""
SIGN_KEY_EMAIL=""       # the email reconciled from the signing key (empty if none)
SIGN_KEY_EMAILS_SEEN="" # newline-separated, for diagnostics on mismatch

case "$GPG_FORMAT" in
	openpgp|gpg|"")
		SIGN_METHOD=openpgp
		command -v gpg >/dev/null 2>&1 \
			|| die 1 "gpg.format is openpgp but 'gpg' is not installed"

		# '--' guards against a signingkey that begins with '-' being taken
		# as a gpg option.
		if ! GPG_OUT=$(gpg --list-secret-keys --with-colons -- "$SIGNINGKEY" 2>/dev/null); then
			die 1 "no GPG secret key found for user.signingkey=$SIGNINGKEY"
		fi

		# Reject an ambiguous match: if the key spec resolves to more than one
		# primary secret key (>1 'sec' record) we must not blend id/fpr from one
		# key with an email from another. Require a unique key.
		SEC_COUNT=$(printf '%s\n' "$GPG_OUT" | grep -c '^sec:' || true)
		if [ "$SEC_COUNT" -gt 1 ]; then
			die 1 "user.signingkey=$SIGNINGKEY matches $SEC_COUNT secret keys; specify a full fingerprint"
		fi

		# Parse colon records: sec (key id), fpr (primary fingerprint), uid
		# (emails). uid field 2 is the validity: skip revoked ('r')/expired ('e')
		# UIDs so a dead UID email can never reconcile.
		while IFS= read -r line; do
			case "$line" in
				sec:*)
					[ -n "$SIGN_KEY_ID" ] || SIGN_KEY_ID=$(printf '%s\n' "$line" | cut -d: -f5)
					;;
				fpr:*)
					[ -n "$SIGN_KEY_FPR" ] || SIGN_KEY_FPR=$(printf '%s\n' "$line" | cut -d: -f10)
					;;
				uid:*)
					uid_val=$(printf '%s\n' "$line" | cut -d: -f2)
					case "$uid_val" in r|e) continue ;; esac
					uid_raw=$(printf '%s\n' "$line" | cut -d: -f10)
					uid_email=$(printf '%s\n' "$uid_raw" | sed -n 's/.*<\([^>]*\)>.*/\1/p')
					if [ -n "$uid_email" ]; then
						SIGN_KEY_EMAILS_SEEN="$SIGN_KEY_EMAILS_SEEN$uid_email
"
					fi
					;;
			esac
		done <<EOF
$GPG_OUT
EOF

		# `-e` passes the address as a PATTERN. As a bare operand a leading-dash
		# address would be parsed as a grep OPTION instead — "--regexp=" makes the
		# effective pattern EMPTY, which -Fx then matches against the blank line an
		# empty list prints, yielding a match nothing actually matched.
		# assert_reconcilable_email rejects such an address too; both, deliberately.
		if printf '%s' "$SIGN_KEY_EMAILS_SEEN" | grep -Fxq -e "$USER_EMAIL"; then
			SIGN_KEY_EMAIL=$USER_EMAIL
		fi
		;;

	ssh)
		SIGN_METHOD=ssh

		# Resolve the signing key's public blob (type + base64) by keytype
		# pattern, tolerating a trailing comment field.
		keyfile=$(expand_home "$SIGNINGKEY")
		if [ -f "$keyfile" ]; then
			keyline=$(head -n 1 "$keyfile")
		else
			case "$SIGNINGKEY" in
				ssh-*|sk-*) keyline=$SIGNINGKEY ;;
				*) die 1 "user.signingkey is neither a readable key file nor an inline ssh key: $SIGNINGKEY" ;;
			esac
		fi
		sk_fields=$(ssh_key_fields "$keyline")
		sk_type=$(printf '%s\n' "$sk_fields" | cut -f1)
		sk_b64=$(printf '%s\n' "$sk_fields" | cut -f2)
		[ -n "$sk_b64" ] || die 1 "could not parse the SSH signing key material"

		# The allowed-signers file supplies the authoritative principal (email).
		ALLOWED=$(git_cfg gpg.ssh.allowedSignersFile)
		[ -n "$ALLOWED" ] || die 1 "gpg.format is ssh but gpg.ssh.allowedSignersFile is not set"
		ALLOWED=$(expand_home "$ALLOWED")
		[ -f "$ALLOWED" ] || die 1 "allowed signers file not found: $ALLOWED"

		# Match on the base64 blob (found by keytype pattern), NOT on the last
		# field — allowed_signers lines routinely end with a comment.
		sk_principal=""
		while IFS= read -r line; do
			case "$line" in ''|'#'*) continue ;; esac
			line_b64=$(ssh_key_fields "$line" | cut -f2)
			if [ -n "$line_b64" ] && [ "$line_b64" = "$sk_b64" ]; then
				sk_principal=$(printf '%s\n' "$line" | awk '{print $1}')
				break
			fi
		done < "$ALLOWED"

		[ -n "$sk_principal" ] \
			|| die 1 "signing key not present in allowed signers file: $ALLOWED"
		SIGN_KEY_EMAILS_SEEN=$(printf '%s\n' "$sk_principal" | tr ',' '\n')

		# `-e` for the same reason as the openpgp path's compare above.
		if printf '%s\n' "$SIGN_KEY_EMAILS_SEEN" | grep -Fxq -e "$USER_EMAIL"; then
			SIGN_KEY_EMAIL=$USER_EMAIL
		fi

		SIGN_KEY_ID="$sk_type"
		if command -v ssh-keygen >/dev/null 2>&1; then
			SIGN_KEY_FPR=$(printf '%s %s\n' "$sk_type" "$sk_b64" \
				| ssh-keygen -lf - 2>/dev/null | awk '{print $2}' || true)
		fi
		;;

	*)
		die 1 "unsupported gpg.format '$GPG_FORMAT' (expected openpgp or ssh)"
		;;
esac

# ---------------------------------------------------------------------------
# Reconcile: signing-key email must equal user.email
# ---------------------------------------------------------------------------
RECONCILE_FAIL=0
if [ -z "$SIGN_KEY_EMAIL" ]; then
	RECONCILE_FAIL=1
	seen=$(printf '%s' "$SIGN_KEY_EMAILS_SEEN" | tr '\n' ' ')
	error "signing key email does not match user.email ($USER_EMAIL); key advertises: ${seen:-<none>}"
fi

# ---------------------------------------------------------------------------
# --github (optional): verify user.email is GitHub-verified. Four states, and
# ONLY 'unverified' is fatal:
#   verified    the query SUCCEEDED and listed user.email
#   unverified  the query SUCCEEDED and did NOT list user.email  -> FATAL
#   unknown     the query FAILED (missing 'user' OAuth scope, network, rate
#               limit, API change) — the question was never actually answered
#   skipped     gh is absent or unauthenticated
#
# The verified/unknown split is the whole point: a failed query must never be
# reported as a definite negative. So branch on the command's EXIT STATUS, not
# on whether its output is empty — a successful query can legitimately return
# an empty list, and that IS 'unverified'. `$(...) || true` would destroy
# exactly the signal this distinction rests on.
#
# --paginate is REQUIRED for correctness, not for completeness: user/emails is a
# GitHub list endpoint defaulting to per_page=30, and `gh api` does not paginate
# on its own. Without it an account with >30 addresses gets a query that
# SUCCEEDS with a truncated list omitting user.email — an invisible false
# 'unverified' that blocks a legitimate commit. `gh` applies --jq per page and
# concatenates the results, which is correct for this flat string filter.
# ---------------------------------------------------------------------------
GITHUB_STATUS=skipped
if [ "$DO_GITHUB" -eq 1 ]; then
	if ! command -v gh >/dev/null 2>&1; then
		warn "gh is not installed; skipping GitHub verification"
	elif ! gh auth status >/dev/null 2>&1; then
		warn "gh is not authenticated; skipping GitHub verification"
	else
		# gh's own stderr is captured rather than discarded: --paginate widened
		# the failure set (a mid-pagination error or a rate limit now lands
		# here too), so no single asserted cause is right. The deterministic
		# sentence stays FIRST and unconditional; gh's real message follows it
		# as a second line only when it said something.
		GH_ERR_FILE=$(make_err_file)
		if ! verified=$(gh api user/emails --paginate --jq '.[] | select(.verified) | .email' 2>"${GH_ERR_FILE:-/dev/null}"); then
			GITHUB_STATUS=unknown
			warn "could not determine whether user.email ($USER_EMAIL) is GitHub-verified: 'gh api user/emails' failed (candidate causes: the gh token lacks the 'user' OAuth scope, a network failure, or an API rate limit). If it is the scope, grant it with: gh auth refresh -h github.com -s user"
			relay_tool_err "$GH_ERR_FILE" gh
		elif printf '%s\n' "$verified" | grep -Fxq -e "$USER_EMAIL"; then
			# CASE-SENSITIVE on purpose, and NOT changed to match the --gitlab path's
			# case-folded compare below: GitHub returns addresses in their REGISTERED
			# form, the local part of an address is case-sensitive per RFC 5321, and an
			# existing test pins this direction deliberately. GitLab down-cases what it
			# stores, which is why only that path folds. See email_listed.
			GITHUB_STATUS=verified
		else
			GITHUB_STATUS=unverified
			RECONCILE_FAIL=1
			error "user.email ($USER_EMAIL) is not a verified email on the GitHub account"
		fi
		[ -z "$GH_ERR_FILE" ] || rm -f "$GH_ERR_FILE"
		GH_ERR_FILE=""
	fi
fi

# ---------------------------------------------------------------------------
# --gitlab (optional): verify user.email is a GitLab-CONFIRMED address. The
# CONTRACT is identical to --github's above — four states, only 'unverified'
# fatal, a query that could not answer never reported as a negative — but the
# MECHANICS differ substantially, because neither `glab api` nor GitLab's data
# model is a drop-in for gh's. Every divergence below was verified against
# glab 1.112.0 and GitLab's own source, not assumed:
#
#   1. `glab api` has NO --jq flag. (`gh api` does; so does `glab mr list`, which
#      is why the sibling procedure-glab-mr scripts can use one.) Verified:
#      `glab api user/emails --jq …` exits 1 with "Unknown flag: --jq". Filters
#      therefore run in an EXTERNAL jq, which makes jq a precondition — guarded
#      with `command -v`, like every other binary in this suite.
#   2. GitLab marks a confirmed address with a non-null `confirmed_at`
#      TIMESTAMP; there is no boolean `verified` field as on GitHub. Hence
#      `select(.confirmed_at != null)` rather than gh's `select(.verified)`.
#   3. GitLab splits the account's addresses across TWO endpoints, so this check
#      needs TWO probes where --github needs one. See resolve_gitlab_status.
#   4. GitLab down-cases the addresses it stores, so the comparison is
#      case-folded here and NOT on the --github path. See email_listed.
#
# The query and the filter are TWO SEPARATE STEPS throughout, deliberately. POSIX
# sh has no `pipefail`, so a single `glab … | jq …` inside one command
# substitution would report only JQ's exit status and discard glab's — and jq
# exits 0 on EMPTY input, so a failed query would arrive as an empty result and be
# misread as a definite negative. Splitting the steps keeps both statuses, which
# is exactly what the verified/unknown distinction rests on.
# ---------------------------------------------------------------------------

GITLAB_STATUS=skipped
if [ "$DO_GITLAB" -eq 1 ]; then
	pin_glab_environment
	if ! command -v glab >/dev/null 2>&1; then
		warn "glab is not installed; skipping GitLab verification"
	elif ! command -v jq >/dev/null 2>&1; then
		warn "jq is not installed (required to filter 'glab api' output, which has no --jq flag); skipping GitLab verification"
	elif ! glab_authenticated; then
		warn "glab is not authenticated; skipping GitLab verification"
	elif [ -z "$OPT_GITLAB_HOST" ]; then
		# UNPINNED: capped at 'unknown', and no api call is made. Both definite
		# states are claims about ONE SPECIFIC account, and glab's ambient instance
		# resolution (cwd git remote, $GITLAB_HOST, its config, else gitlab.com)
		# cannot establish which account answered — so a `verified` here could
		# belong to a different instance entirely, and an `unverified` (FATAL)
		# could be a --gitlab passed speculatively at a non-GitLab remote. 'unknown'
		# is what "the tooling ran but the answer would not be about this account"
		# actually is. See "HOST PINNING" in this file's header.
		GITLAB_STATUS=unknown
		warn "could not determine whether user.email ($USER_EMAIL) is GitLab-confirmed: --gitlab-host was not given, so glab would pick the instance from ambient state (cwd git remote, \$GITLAB_HOST, its config, else gitlab.com) and the answer could describe a different account than the identity being reconciled. The result is therefore capped at 'unknown' (never verified/unverified) and no query was made. Re-run with --gitlab-host HOST — the host the GitLab account gate confirmed — for a definite answer"
	elif gitlab_tls_verification_disabled; then
		# Same untrustworthy-channel rule, applied to the TRANSPORT: with TLS
		# verification off, an on-path attacker can answer /user and /user/emails,
		# so a `verified` would assert nothing. Degrade rather than assert.
		GITLAB_STATUS=unknown
		warn "could not determine whether user.email ($USER_EMAIL) is GitLab-confirmed: glab is configured to SKIP TLS certificate verification (skip_tls_verify) for $OPT_GITLAB_HOST, so a 'verified' answer could be manufactured by an on-path attacker and cannot be trusted. The result is capped at 'unknown'; no query was made. Turn TLS verification back on (glab config set skip_tls_verify false) to get a definite answer"
	else
		GL_ERR_FILE=$(make_err_file)
		GITLAB_STATUS=$(resolve_gitlab_status)
		if [ "$GITLAB_STATUS" = unverified ]; then
			RECONCILE_FAIL=1
			error "user.email ($USER_EMAIL) is not a confirmed email on the GitLab account (checked both the account's primary address and its additional confirmed addresses)"
		fi
		[ -z "$GL_ERR_FILE" ] || rm -f "$GL_ERR_FILE"
		GL_ERR_FILE=""
	fi
fi

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------
if [ "$RECONCILE_FAIL" -eq 0 ]; then
	STATUS=reconciled
else
	STATUS=mismatch
fi

# Human-readable block (stdout)
printf 'Git Signing Identity\n'
printf '  Name:            %s\n' "$USER_NAME"
printf '  Committer email: %s\n' "$USER_EMAIL"
printf '  Signing method:  %s\n' "$SIGN_METHOD"
printf '  Signing key:     %s\n' "$SIGNINGKEY"
[ -n "$SIGN_KEY_ID" ]  && printf '  Key id:          %s\n' "$SIGN_KEY_ID"
[ -n "$SIGN_KEY_FPR" ] && printf '  Fingerprint:     %s\n' "$SIGN_KEY_FPR"
printf '  Signed-off-by:   %s\n' "$SIGNOFF"
if [ "$AUTHOR_COMMITTER_MATCH" = false ]; then
	printf '  Author note:     author (%s) != committer (%s)\n' "$AUTHOR_EMAIL" "$COMMITTER_EMAIL"
fi
if [ "$DO_GITHUB" -eq 1 ]; then
	# The machine block below carries the bare token; this line may annotate the
	# states whose name alone does not convey whether they blocked the commit.
	case "$GITHUB_STATUS" in
		unknown) printf '  GitHub email:    %s (check could not run — not a failure)\n' "$GITHUB_STATUS" ;;
		*)       printf '  GitHub email:    %s\n' "$GITHUB_STATUS" ;;
	esac
fi
if [ "$DO_GITLAB" -eq 1 ]; then
	# Same annotation rule as the GitHub line above: 'unknown' does not say on its
	# own that it did NOT block the commit, so it is spelled out.
	case "$GITLAB_STATUS" in
		unknown) printf '  GitLab email:    %s (check could not run — not a failure)\n' "$GITLAB_STATUS" ;;
		*)       printf '  GitLab email:    %s\n' "$GITLAB_STATUS" ;;
	esac
fi
printf '  Status:          %s\n' "$STATUS"

# Machine-parseable block (stdout)
printf '\n'
printf 'IDENTITY_NAME=%s\n'                    "$USER_NAME"
printf 'IDENTITY_COMMITTER_EMAIL=%s\n'         "$USER_EMAIL"
printf 'IDENTITY_SIGNING_METHOD=%s\n'          "$SIGN_METHOD"
printf 'IDENTITY_SIGNING_KEY=%s\n'             "$SIGNINGKEY"
printf 'IDENTITY_SIGNING_KEY_ID=%s\n'          "$SIGN_KEY_ID"
printf 'IDENTITY_SIGNING_KEY_FPR=%s\n'         "$SIGN_KEY_FPR"
printf 'IDENTITY_SIGNING_KEY_EMAIL=%s\n'       "$SIGN_KEY_EMAIL"
printf 'IDENTITY_SIGNOFF=%s\n'                 "$SIGNOFF"
printf 'IDENTITY_AUTHOR_EMAIL=%s\n'            "$AUTHOR_EMAIL"
printf 'IDENTITY_AUTHOR_COMMITTER_MATCH=%s\n'  "$AUTHOR_COMMITTER_MATCH"
# verified | unverified | unknown | skipped — consumed contract values. The two
# are INDEPENDENT: each reflects only its own flag, and both lines always print.
printf 'IDENTITY_GITHUB=%s\n'                  "$GITHUB_STATUS"
printf 'IDENTITY_GITLAB=%s\n'                  "$GITLAB_STATUS"
printf 'IDENTITY_STATUS=%s\n'                  "$STATUS"

[ "$RECONCILE_FAIL" -eq 0 ] || exit 1
exit 0
