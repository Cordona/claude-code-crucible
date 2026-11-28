#!/usr/bin/env sh
#
# list-identities.sh — enumerate the available git signing identities.
#
# Purpose:
#   READ-ONLY discovery. Lists GPG secret keys (key id, fingerprint, UID name +
#   email) and the SSH keys this machine can sign with (the configured
#   user.signingkey first, then gpg.ssh.allowedSignersFile's keys). Output is
#   DETERMINISTIC: identities are sorted into a stable order and numbered, so
#   the same environment always yields the same list.
#
# Usage:
#   list-identities.sh [-h|--help]
#
# Output:
#   stdout — a machine-parseable block of IDENTITY_<n>_* KEY=VALUE lines.
#            Diagnostics go to stderr.
#
# Exit codes:
#   0  at least one identity found
#   1  no signing identities found
#   2  usage error
#
# Portability: POSIX sh only. macOS (BSD) and Linux. shellcheck-clean.
#   Degrades gracefully when gpg / ssh-keygen are absent.
#
set -eu

PROG=${0##*/}

warn()  { printf '%s: warning: %s\n' "$PROG" "$*" >&2; }
error() { printf '%s: error: %s\n'   "$PROG" "$*" >&2; }
die() { rc=$1; shift; error "$*"; exit "$rc"; }

usage() {
	cat <<EOF
usage: $PROG [-h|--help]

Enumerate available GPG and SSH signing identities in a stable, numbered order.
Read-only. An SSH key is listed only when this machine can sign with it: the
agent holds it, or it is a .pub file with its private key beside it. The
configured SSH user.signingkey comes first, as its path when it is one.

stdout: per identity <n>, in a stable, numbered order:
  IDENTITY_<n>_METHOD=<gpg or ssh>
  IDENTITY_<n>_KEY_ID=<GPG key id, or the SSH key type>
  IDENTITY_<n>_FPR=<GPG fingerprint, or SSH SHA256:...; may be empty>
  IDENTITY_<n>_NAME=<the GPG UID name; empty for SSH>
  IDENTITY_<n>_EMAIL=<the UID email, or an SSH principal>
  IDENTITY_<n>_SIGNING_KEY=<the value git's user.signingkey takes>
  and last IDENTITY_COUNT=<n>

Exit codes:
  0  at least one identity found
  1  no signing identities found
  2  usage error

needs: POSIX sh, awk, sort; gpg, git, ssh-add and ssh-keygen, each optional
Environment:
  GNUPGHOME      the GPG key ring gpg reads; default \$HOME/.gnupg
  HOME           expands ~/ in git paths; holds .ssh/, searched for .pub files
  SSH_AUTH_SOCK  the ssh agent ssh-add -L asks; unset: no agent keys
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

# ssh_key_fields <line>: locate the SSH key by KEYTYPE PATTERN (not position),
# tolerating a trailing comment field. Prints "TYPE<TAB>BASE64<TAB>COMMENT"
# (COMMENT may be empty); nothing if the line has no recognizable key.
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

# Parse args (only -h/--help).
while [ $# -gt 0 ]; do
	case "$1" in
		-h|--help) usage; exit 0 ;;
		--) shift; break ;;
		*) usage >&2; die 2 "unexpected argument: $1" ;;
	esac
done

# This tool takes no positional operands; reject any left after '--'.
[ $# -eq 0 ] || { usage >&2; die 2 "unexpected argument: $1"; }

# Each record is a single line of fields separated by SEP (US, 0x1f):
#   RANK SEP METHOD SEP KEY_ID SEP FINGERPRINT SEP NAME SEP EMAIL SEP SIGNING_KEY
# RANK 0 sorts the configured SSH user.signingkey first, 1 everything else.
# SIGNING_KEY is the value git's user.signingkey takes for the identity.
# SEP is not IFS white space, so `read` keeps an empty field (an SSH
# identity's NAME) in its place; a tab would collapse it.
# Collected unsorted, then sorted for deterministic ordering.
SEP=$(printf '\037')
RECORDS=""

add_record() {
	# $1 rank  $2 method  $3 key_id  $4 fpr  $5 name  $6 email  $7 signing key
	RECORDS="$RECORDS$1$SEP$2$SEP$3$SEP$4$SEP$5$SEP$6$SEP$7
"
}

# ---------------------------------------------------------------------------
# GPG secret keys
# ---------------------------------------------------------------------------
if command -v gpg >/dev/null 2>&1; then
	if gpg_out=$(gpg --list-secret-keys --with-colons 2>/dev/null); then
		cur_id=""
		cur_fpr=""
		have_fpr=0
		while IFS= read -r line; do
			case "$line" in
				sec:*)
					cur_id=$(printf '%s\n' "$line" | cut -d: -f5)
					cur_fpr=""
					have_fpr=0
					;;
				fpr:*)
					if [ "$have_fpr" -eq 0 ]; then
						cur_fpr=$(printf '%s\n' "$line" | cut -d: -f10)
						have_fpr=1
					fi
					;;
				ssb:*)
					# subkey follows; its fpr must not overwrite the primary
					have_fpr=1
					;;
				uid:*)
					# skip revoked ('r') / expired ('e') UIDs (field 2 = validity)
					uid_val=$(printf '%s\n' "$line" | cut -d: -f2)
					case "$uid_val" in r|e) continue ;; esac
					uid_raw=$(printf '%s\n' "$line" | cut -d: -f10)
					uid_email=$(printf '%s\n' "$uid_raw" | sed -n 's/.*<\([^>]*\)>.*/\1/p')
					uid_name=$(printf '%s\n' "$uid_raw" | sed 's/ *<[^>]*>.*//')
					[ -n "$cur_id" ] && add_record 1 gpg "$cur_id" "$cur_fpr" "$uid_name" "$uid_email" "$cur_id"
					;;
			esac
		done <<EOF
$gpg_out
EOF
	fi
else
	warn "gpg not installed; skipping GPG identities"
fi

# ---------------------------------------------------------------------------
# SSH signing identities this machine can sign with, deduped by the base64
# key blob: the configured user.signingkey first, then the allowed-signers
# file's keys. A key signs when the agent holds it or a .pub file of it has
# its private key beside it.
# ---------------------------------------------------------------------------
SSH_SEEN_B64=""

ssh_fpr_of() {
	# $1 type  $2 b64  -> prints SHA256:... or empty
	if command -v ssh-keygen >/dev/null 2>&1; then
		printf '%s %s\n' "$1" "$2" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}' || true
	fi
}

# The blobs the agent holds, space-separated; empty with no agent.
AGENT_B64=""
if command -v ssh-add >/dev/null 2>&1; then
	agent_keys=$(ssh-add -L </dev/null 2>/dev/null || true)
	while IFS= read -r line; do
		a_b64=$(ssh_key_fields "$line" | cut -f2)
		[ -z "$a_b64" ] || AGENT_B64="$AGENT_B64 $a_b64"
	done <<EOF
$agent_keys
EOF
fi

# agent_holds <b64>: prints 1 when the agent holds the blob, else 0.
agent_holds() {
	case " $AGENT_B64 " in
		*" $1 "*) printf '1\n' ;;
		*) printf '0\n' ;;
	esac
}

# pub_with_private <b64>: prints the first ~/.ssh/*.pub holding the blob
# whose private key sits beside it; nothing when there is none.
pub_with_private() {
	for pub in "$HOME"/.ssh/*.pub; do
		[ -f "$pub" ] && [ -f "${pub%.pub}" ] || continue
		p_line=$(head -n 1 "$pub")
		p_b64=$(ssh_key_fields "$p_line" | cut -f2)
		if [ "$p_b64" = "$1" ]; then
			printf '%s\n' "$pub"
			return 0
		fi
	done
}

ALLOWED=$(git_cfg gpg.ssh.allowedSignersFile)
[ -n "$ALLOWED" ] && ALLOWED=$(expand_home "$ALLOWED")
[ -n "$ALLOWED" ] && [ -f "$ALLOWED" ] || ALLOWED=""

# allowed_principals <b64>: prints the allowed-signers principal list of the
# blob's first line; nothing when the file has none.
allowed_principals() {
	[ -n "$ALLOWED" ] || return 0
	while IFS= read -r line; do
		case "$line" in ''|'#'*) continue ;; *) ;; esac
		ap_b64=$(ssh_key_fields "$line" | cut -f2)
		if [ "$ap_b64" = "$1" ]; then
			printf '%s\n' "$line" | awk '{print $1}'
			return 0
		fi
	done < "$ALLOWED"
}

# A pipe would run the per-principal loop in a subshell, losing appended
# records; feed the loop via a here-doc so appends stay in this shell.
ssh_add_direct() {
	# $1 rank  $2 principal-list  $3 type  $4 b64  $5 signing key
	[ -n "$4" ] || return 0
	# base64 blobs contain no spaces, so a space-delimited seen-list is safe.
	case " $SSH_SEEN_B64 " in
		*" $4 "*) return 0 ;;
		*) ;;
	esac
	SSH_SEEN_B64="$SSH_SEEN_B64 $4"
	_fpr=$(ssh_fpr_of "$3" "$4")
	_plist=$(printf '%s\n' "$2" | tr ',' '\n')
	while IFS= read -r pr; do
		[ -n "$pr" ] || continue
		add_record "$1" ssh "$3" "$_fpr" "" "$pr" "$5"
	done <<EOF
$_plist
EOF
}

# Configured SSH signing key: a key:: or ssh- literal signs through the agent;
# a path stays the path git was given, its public half read from it, or from
# <path>.pub when it is the private key. Its principals come from the
# allowed-signers file, else its comment, often the email.
SIGNINGKEY=$(git_cfg user.signingkey)
GPG_FORMAT=$(git_cfg gpg.format)
if [ "$GPG_FORMAT" = ssh ] && [ -n "$SIGNINGKEY" ]; then
	k_signs=0
	case "$SIGNINGKEY" in
		key::*|ssh-*)
			kl=${SIGNINGKEY#key::}
			k_fields=$(ssh_key_fields "$kl")
			k_b64=$(printf '%s\n' "$k_fields" | cut -f2)
			k_type=$(printf '%s\n' "$k_fields" | cut -f1)
			k_key="key::$k_type $k_b64"
			k_signs=$(agent_holds "$k_b64")
			;;
		*)
			k_key=$(expand_home "$SIGNINGKEY")
			case "$k_key" in
				*.pub) k_pub=$k_key k_private=${k_key%.pub} ;;
				*) k_pub=$k_key.pub k_private=$k_key ;;
			esac
			kl=""
			[ -f "$k_pub" ] && kl=$(head -n 1 "$k_pub")
			k_fields=$(ssh_key_fields "$kl")
			k_b64=$(printf '%s\n' "$k_fields" | cut -f2)
			k_type=$(printf '%s\n' "$k_fields" | cut -f1)
			k_signs=$(agent_holds "$k_b64")
			[ ! -f "$k_private" ] || k_signs=1
			;;
	esac
	if [ "$k_signs" -eq 1 ]; then
		k_principals=$(allowed_principals "$k_b64")
		[ -n "$k_principals" ] || k_principals=$(printf '%s\n' "$k_fields" | cut -f3)
		ssh_add_direct 0 "$k_principals" "$k_type" "$k_b64" "$k_key"
	fi
fi

if [ -n "$ALLOWED" ]; then
	while IFS= read -r line; do
		case "$line" in ''|'#'*) continue ;; *) ;; esac
		# Principal is the first field; the key is found by keytype pattern so a
		# trailing comment can't be mistaken for the key type/blob.
		l_principal=$(printf '%s\n' "$line" | awk '{print $1}')
		l_fields=$(ssh_key_fields "$line")
		l_type=$(printf '%s\n' "$l_fields" | cut -f1)
		l_b64=$(printf '%s\n' "$l_fields" | cut -f2)
		[ -n "$l_b64" ] || continue
		l_in_agent=$(agent_holds "$l_b64")
		if [ "$l_in_agent" -eq 1 ]; then
			ssh_add_direct 1 "$l_principal" "$l_type" "$l_b64" "key::$l_type $l_b64"
		else
			l_pub=$(pub_with_private "$l_b64")
			[ -z "$l_pub" ] || ssh_add_direct 1 "$l_principal" "$l_type" "$l_b64" "$l_pub"
		fi
	done < "$ALLOWED"
fi

# ---------------------------------------------------------------------------
# Emit, deterministically ordered
# ---------------------------------------------------------------------------
if [ -z "$RECORDS" ]; then
	die 1 "no signing identities found (no GPG secret keys and no SSH signing keys)"
fi

SORTED=$(printf '%s' "$RECORDS" | LC_ALL=C sort)

# Machine-parseable block
n=0
printf '%s\n' "$SORTED" | while IFS="$SEP" read -r _ method key_id fpr name email signing_key; do
	[ -n "$method" ] || continue
	n=$((n + 1))
	printf 'IDENTITY_%d_METHOD=%s\n' "$n" "$method"
	printf 'IDENTITY_%d_KEY_ID=%s\n' "$n" "$key_id"
	printf 'IDENTITY_%d_FPR=%s\n'    "$n" "$fpr"
	printf 'IDENTITY_%d_NAME=%s\n'   "$n" "$name"
	printf 'IDENTITY_%d_EMAIL=%s\n'  "$n" "$email"
	printf 'IDENTITY_%d_SIGNING_KEY=%s\n' "$n" "$signing_key"
done

# IDENTITY_COUNT — computed from the sorted record set.
count=$(printf '%s\n' "$SORTED" | grep -c "$SEP" || true)
printf 'IDENTITY_COUNT=%s\n' "$count"

exit 0
