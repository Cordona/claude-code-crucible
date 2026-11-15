#!/usr/bin/env sh
#
# resolve-identity.sh — deterministically resolve & reconcile the git signing
#                       identity BEFORE a commit or signed tag.
#
# Purpose:
#   Reads the git config + signing-key material and asserts that the committer
#   email, the signing key's email, and the Signed-off-by it would write are one
#   consistent identity. Surfaces an author != committer divergence. READ-ONLY:
#   it never modifies git config, keys, or the repo, and makes no network call.
#
# Usage:
#   resolve-identity.sh [--email E] [--name N] [--signingkey K]
#                       [--format gpg|ssh] [-h|--help]
#
#   (no flag)     Run the three git-local checks + the author/committer note
#                 against the configured identity.
#   --email E     Reconcile a SPECIFIED committer email instead of the
#                 configured user.email (e.g. to re-verify after a switch).
#   --name N      Override user.name for the Signed-off-by line.
#   --signingkey K  Override user.signingkey.
#   --format F    Override gpg.format (gpg/openpgp or ssh).
#   -h,--help     Show this help.
#
# Output:
#   stdout — a machine-parseable KEY=VALUE block for the calling script.
#            Diagnostics/warnings go to stderr.
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
usage: $PROG [--email E] [--name N] [--signingkey K] [--format gpg|ssh]
             [-h|--help]

Resolve and reconcile the git signing identity before a commit or signed tag.
Read-only; no network.

Options:
  --email E       Reconcile a specified committer email instead of user.email.
  --name N        Override user.name (for the Signed-off-by line).
  --signingkey K  Override user.signingkey.
  --format F      Override gpg.format (gpg/openpgp or ssh).
  -h, --help      Show this help.

stdout: these lines, in this order:
  IDENTITY_NAME=<name>
  IDENTITY_COMMITTER_EMAIL=<email>
  IDENTITY_SIGNING_METHOD=<openpgp or ssh>
  IDENTITY_SIGNING_KEY=<the key, as given or configured>
  IDENTITY_SIGNING_KEY_ID=<GPG key id, or the SSH key type>
  IDENTITY_SIGNING_KEY_FPR=<GPG fingerprint, or SSH SHA256:...; may be empty>
  IDENTITY_SIGNING_KEY_EMAIL=<the email the key carries; empty on a mismatch>
  IDENTITY_SIGNOFF=<name <email>>
  IDENTITY_AUTHOR_EMAIL=<email>
  IDENTITY_AUTHOR_COMMITTER_MATCH=<true or false>
  IDENTITY_STATUS=<reconciled or mismatch>
  each value one line; none printed when it stops before the checks end
stderr: "$PROG: error: <reason>" on exit 1, warnings as "$PROG: warning: ..."

Exit codes:
  0  identity reconciles — ready to commit
  1  mismatch or missing/misconfigured signing key — do not commit
  2  usage error

needs: POSIX sh, git, in a git work tree; gpg (openpgp), ssh-keygen (ssh
  fingerprint)
Environment:
  GIT_AUTHOR_EMAIL, GIT_COMMITTER_EMAIL  checked against each other, as git
  GNUPGHOME  the GPG key ring gpg reads; default \$HOME/.gnupg
  HOME       expands ~/ in user.signingkey and the allowed-signers path
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
# IDENTITY_STATUS=reconciled" — would print as extra IDENTITY_* lines a consumer
# cannot distinguish from real ones. Every value reaching that block is
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
#   a leading -  belt-and-suspenders. Every matcher passes its pattern via
#                `grep -Fxq -e`, so grep can no longer read one as an option —
#                but a bad address should never reach a matcher at all, and one
#                more case arm costs nothing. (Unguarded AND without the -e,
#                "--regexp=" made the effective pattern EMPTY, which -Fx matches
#                against the blank line an empty list prints: a false match
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

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
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

command -v git >/dev/null 2>&1 || die 1 "git not found; expected git on PATH"

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
# Result
# ---------------------------------------------------------------------------
if [ "$RECONCILE_FAIL" -eq 0 ]; then
	STATUS=reconciled
else
	STATUS=mismatch
fi

# Machine-parseable block (stdout)
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
printf 'IDENTITY_STATUS=%s\n'                  "$STATUS"

[ "$RECONCILE_FAIL" -eq 0 ] || exit 1
exit 0
