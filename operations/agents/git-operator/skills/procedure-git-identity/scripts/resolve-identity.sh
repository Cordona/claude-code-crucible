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
#   unless --github is given.
#
# Usage:
#   resolve-identity.sh [--github] [--email E] [--name N]
#                       [--signingkey K] [--format gpg|ssh] [-h|--help]
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
#   -h,--help     Show this help.
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

PROG=${0##*/}

# Temp file holding gh's own stderr (created only on the --github path).
GH_ERR_FILE=""
# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() { [ -z "$GH_ERR_FILE" ] || rm -f "$GH_ERR_FILE"; }
trap cleanup EXIT INT TERM

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

usage() {
	cat <<EOF
Usage: $PROG [--github] [--email E] [--name N] [--signingkey K]
             [--format gpg|ssh] [-h|--help]

Resolve and reconcile the git signing identity before a commit or signed tag.
Read-only; no network unless --github is given.

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

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
DO_GITHUB=0
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

# The committer email is used as a PATTERN by every `grep -Fxq` reconciliation
# below, and grep -F treats an embedded newline as a list of ALTERNATIVE fixed
# patterns: an address containing one could match a line it does not equal and
# reconcile spuriously. No legitimate email contains whitespace, so reject it
# once, here, before it can reach any matcher.
case "$USER_EMAIL" in
	*[[:space:]]*) die 1 "user.email contains whitespace (not a valid address): $USER_EMAIL" ;;
esac

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

		if printf '%s' "$SIGN_KEY_EMAILS_SEEN" | grep -Fxq "$USER_EMAIL"; then
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

		if printf '%s\n' "$SIGN_KEY_EMAILS_SEEN" | grep -Fxq "$USER_EMAIL"; then
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
		GH_ERR_FILE=$(mktemp "${TMPDIR:-/tmp}/resolve-identity.XXXXXX")
		if ! verified=$(gh api user/emails --paginate --jq '.[] | select(.verified) | .email' 2>"$GH_ERR_FILE"); then
			GITHUB_STATUS=unknown
			warn "could not determine whether user.email ($USER_EMAIL) is GitHub-verified: 'gh api user/emails' failed (candidate causes: the gh token lacks the 'user' OAuth scope, a network failure, or an API rate limit). If it is the scope, grant it with: gh auth refresh -h github.com -s user"
			gh_err_text=$(cat "$GH_ERR_FILE")
			[ -z "$gh_err_text" ] || warn "gh reported: $gh_err_text"
		elif printf '%s\n' "$verified" | grep -Fxq "$USER_EMAIL"; then
			GITHUB_STATUS=verified
		else
			GITHUB_STATUS=unverified
			RECONCILE_FAIL=1
			error "user.email ($USER_EMAIL) is not a verified email on the GitHub account"
		fi
		rm -f "$GH_ERR_FILE"
		GH_ERR_FILE=""
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
# verified | unverified | unknown | skipped — consumed contract value.
printf 'IDENTITY_GITHUB=%s\n'                  "$GITHUB_STATUS"
printf 'IDENTITY_STATUS=%s\n'                  "$STATUS"

[ "$RECONCILE_FAIL" -eq 0 ] || exit 1
exit 0
