#!/usr/bin/env sh
#
# switch-identity.sh — deterministically set the git signing identity.
#
# Purpose:
#   The ONLY script in this suite that writes. It sets user.name, user.email,
#   user.signingkey and (optionally) gpg.format via `git config` — nothing
#   else. It NEVER touches keys, the keyring, or the repository tree. The key
#   is VALIDATED to exist before anything is written. IDEMPOTENT: the same
#   arguments always produce the same resulting config.
#
# Usage:
#   switch-identity.sh --email <e> --name <n> --signingkey <k>
#                      [--format gpg|ssh] [--scope repo|global]
#
#   --scope repo    (default) write repo-local config (must be in a git repo)
#   --scope global  write the user's global git config
#
# Output:
#   stdout — confirmation + a machine-parseable KEY=VALUE block of what was set.
#   Diagnostics go to stderr.
#
# Exit codes:
#   0  identity applied
#   1  invalid or missing signing key (nothing written)
#   2  usage error
#
# Portability: POSIX sh only. macOS (BSD) and Linux. shellcheck-clean.
#
set -eu

PROG=${0##*/}

error() { printf '%s: error: %s\n' "$PROG" "$*" >&2; }
die() { rc=$1; shift; error "$*"; exit "$rc"; }

usage() {
	cat <<EOF
Usage: $PROG --email <e> --name <n> --signingkey <k>
             [--format gpg|ssh] [--scope repo|global]

Deterministically set the git signing identity (git config only; never keys or
the repo tree). Validates the key exists before writing. Idempotent.

Options:
  --email E       Committer email to set (required).
  --name N        Committer name to set (required).
  --signingkey K  Signing key to set (required): a GPG key id/fingerprint, or
                  an SSH public-key file path / inline 'ssh-...' key.
  --format F      Signing format: gpg (openpgp) or ssh. If omitted, the current
                  gpg.format is used for validation and left unchanged.
  --scope S       repo (default, local) or global.

Exit codes:
  0  identity applied
  1  invalid or missing signing key (nothing written)
  2  usage error
EOF
}

git_cfg() { git config "$1" 2>/dev/null || true; }

# expand_home <path>: expand a leading '~/' to "$HOME/"; else unchanged.
expand_home() {
	eh_rest=${1#\~/}
	if [ "$eh_rest" != "$1" ]; then
		printf '%s\n' "$HOME/$eh_rest"
	else
		printf '%s\n' "$1"
	fi
}

# ssh_key_fields <line>: locate the SSH key by KEYTYPE PATTERN, tolerating a
# trailing comment. Prints "TYPE<TAB>BASE64<TAB>COMMENT" or nothing.
# Deliberately duplicated across the suite so each script stays self-contained.
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

need_arg() { [ -n "${2:-}" ] || { usage >&2; die 2 "option $1 requires an argument"; }; }

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
OPT_EMAIL=""
OPT_NAME=""
OPT_SIGNINGKEY=""
OPT_FORMAT=""
OPT_SCOPE=repo

while [ $# -gt 0 ]; do
	case "$1" in
		--email)      need_arg "$1" "${2:-}"; OPT_EMAIL=$2;      shift ;;
		--name)       need_arg "$1" "${2:-}"; OPT_NAME=$2;       shift ;;
		--signingkey) need_arg "$1" "${2:-}"; OPT_SIGNINGKEY=$2; shift ;;
		--format)     need_arg "$1" "${2:-}"; OPT_FORMAT=$2;     shift ;;
		--scope)      need_arg "$1" "${2:-}"; OPT_SCOPE=$2;      shift ;;
		-h|--help) usage; exit 0 ;;
		--) shift; break ;;
		-*) usage >&2; die 2 "unknown option: $1" ;;
		*)  usage >&2; die 2 "unexpected argument: $1" ;;
	esac
	shift
done

# This tool takes no positional operands; reject any left after '--'.
[ $# -eq 0 ] || { usage >&2; die 2 "unexpected argument: $1"; }

[ -n "$OPT_EMAIL" ]      || { usage >&2; die 2 "--email is required"; }
[ -n "$OPT_NAME" ]       || { usage >&2; die 2 "--name is required"; }
[ -n "$OPT_SIGNINGKEY" ] || { usage >&2; die 2 "--signingkey is required"; }

case "$OPT_SCOPE" in
	repo|global) ;;
	*) usage >&2; die 2 "--scope must be 'repo' or 'global' (got: $OPT_SCOPE)" ;;
esac

if [ -n "$OPT_FORMAT" ]; then
	case "$OPT_FORMAT" in
		gpg|openpgp) OPT_FORMAT=openpgp ;;
		ssh) ;;
		*) usage >&2; die 2 "--format must be 'gpg' or 'ssh' (got: $OPT_FORMAT)" ;;
	esac
fi

# Scope -> git config location flag.
if [ "$OPT_SCOPE" = repo ]; then
	git rev-parse --git-dir >/dev/null 2>&1 \
		|| die 2 "--scope repo requires running inside a git repository"
	SCOPE_FLAG=--local
else
	SCOPE_FLAG=--global
fi

# Effective format used for validation (explicit > current > openpgp default).
EFF_FORMAT=$OPT_FORMAT
[ -n "$EFF_FORMAT" ] || EFF_FORMAT=$(git_cfg gpg.format)
[ -n "$EFF_FORMAT" ] || EFF_FORMAT=openpgp

# ---------------------------------------------------------------------------
# Validate the signing key BEFORE writing anything
# ---------------------------------------------------------------------------
case "$EFF_FORMAT" in
	openpgp|gpg)
		command -v gpg >/dev/null 2>&1 \
			|| die 1 "cannot validate GPG key: 'gpg' is not installed"
		# '--' prevents a leading-'-' signingkey being read as a gpg option.
		gpg --list-secret-keys --with-colons -- "$OPT_SIGNINGKEY" >/dev/null 2>&1 \
			|| die 1 "no GPG secret key found for signingkey=$OPT_SIGNINGKEY"
		;;
	ssh)
		# Structural validation: a readable key FILE must actually contain a
		# recognizable key line (keytype + base64); an existence check alone
		# would let an empty/garbage file through.
		keyfile=$(expand_home "$OPT_SIGNINGKEY")
		if [ -f "$keyfile" ]; then
			sk_line=$(head -n 1 "$keyfile")
			sk_b64=$(ssh_key_fields "$sk_line" | cut -f2)
			[ -n "$sk_b64" ] \
				|| die 1 "SSH key file has no valid key line (keytype + base64): $keyfile"
		else
			case "$OPT_SIGNINGKEY" in
				ssh-*|sk-*)
					sk_b64=$(ssh_key_fields "$OPT_SIGNINGKEY" | cut -f2)
					[ -n "$sk_b64" ] \
						|| die 1 "inline SSH key is malformed (expected 'keytype base64'): $OPT_SIGNINGKEY"
					;;
				*) die 1 "SSH signing key is neither a readable file nor an inline 'ssh-...' key: $OPT_SIGNINGKEY" ;;
			esac
		fi
		;;
	*)
		die 1 "unsupported format '$EFF_FORMAT' (expected gpg or ssh)"
		;;
esac

# ---------------------------------------------------------------------------
# Apply (idempotent: git config overwrites in place)
# ---------------------------------------------------------------------------
git config "$SCOPE_FLAG" user.name       "$OPT_NAME"
git config "$SCOPE_FLAG" user.email      "$OPT_EMAIL"
git config "$SCOPE_FLAG" user.signingkey "$OPT_SIGNINGKEY"
if [ -n "$OPT_FORMAT" ]; then
	git config "$SCOPE_FLAG" gpg.format "$OPT_FORMAT"
fi

# ---------------------------------------------------------------------------
# Report what is now configured (read back for confirmation)
# ---------------------------------------------------------------------------
NOW_NAME=$(git_cfg user.name)
NOW_EMAIL=$(git_cfg user.email)
NOW_KEY=$(git_cfg user.signingkey)
NOW_FORMAT=$(git_cfg gpg.format)
[ -n "$NOW_FORMAT" ] || NOW_FORMAT=openpgp

printf 'Git signing identity set (%s scope)\n' "$OPT_SCOPE"
printf '  Name:        %s\n' "$NOW_NAME"
printf '  Email:       %s\n' "$NOW_EMAIL"
printf '  Signing key: %s\n' "$NOW_KEY"
printf '  Format:      %s\n' "$NOW_FORMAT"

printf '\n'
printf 'SWITCH_SCOPE=%s\n'            "$OPT_SCOPE"
printf 'SWITCH_NAME=%s\n'            "$NOW_NAME"
printf 'SWITCH_EMAIL=%s\n'           "$NOW_EMAIL"
printf 'SWITCH_SIGNINGKEY=%s\n'      "$NOW_KEY"
printf 'SWITCH_FORMAT=%s\n'          "$NOW_FORMAT"
printf 'SWITCH_STATUS=applied\n'

exit 0
