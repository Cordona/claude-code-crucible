#!/usr/bin/env sh
#
# list-identities.sh — enumerate the available git signing identities so a
#                      user (or the git-operator) can choose one to switch to.
#
# Purpose:
#   READ-ONLY discovery. Lists GPG secret keys (key id, fingerprint, UID name +
#   email) and SSH signing identities (from gpg.ssh.allowedSignersFile and the
#   configured user.signingkey). Output is DETERMINISTIC: identities are sorted
#   into a stable order and numbered, so the same environment always yields the
#   same list.
#
# Usage:
#   list-identities.sh [-h|--help]
#
# Output:
#   stdout — a numbered human-readable list AND a machine-parseable block of
#            IDENTITY_<n>_* KEY=VALUE lines. Diagnostics go to stderr.
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
Usage: $PROG [-h|--help]

Enumerate available GPG and SSH signing identities in a stable, numbered order.
Read-only.

Exit codes:
  0  at least one identity found
  1  no signing identities found
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

# Each record is a single tab-separated line:
#   METHOD \t KEY_ID \t FINGERPRINT \t NAME \t EMAIL
# Collected unsorted, then sorted for deterministic ordering.
TAB=$(printf '\t')
RECORDS=""

add_record() {
	# $1 method  $2 key_id  $3 fpr  $4 name  $5 email
	RECORDS="$RECORDS$1$TAB$2$TAB$3$TAB$4$TAB$5
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
					[ -n "$cur_id" ] && add_record gpg "$cur_id" "$cur_fpr" "$uid_name" "$uid_email"
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
# SSH signing identities (allowed-signers file + configured key), deduped by
# the base64 key blob.
# ---------------------------------------------------------------------------
SSH_SEEN_B64=""

ssh_fpr_of() {
	# $1 type  $2 b64  -> prints SHA256:... or empty
	if command -v ssh-keygen >/dev/null 2>&1; then
		printf '%s %s\n' "$1" "$2" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}' || true
	fi
}

# A pipe would run the per-principal loop in a subshell, losing appended
# records; feed the loop via a here-doc so appends stay in this shell.
ssh_add_direct() {
	# $1 principal-list  $2 type  $3 b64
	[ -n "$3" ] || return 0
	# base64 blobs contain no spaces, so a space-delimited seen-list is safe.
	case " $SSH_SEEN_B64 " in
		*" $3 "*) return 0 ;;
	esac
	SSH_SEEN_B64="$SSH_SEEN_B64 $3"
	_fpr=$(ssh_fpr_of "$2" "$3")
	_plist=$(printf '%s\n' "$1" | tr ',' '\n')
	while IFS= read -r pr; do
		[ -n "$pr" ] || continue
		add_record ssh "$2" "$_fpr" "" "$pr"
	done <<EOF
$_plist
EOF
}

ALLOWED=$(git_cfg gpg.ssh.allowedSignersFile)
[ -n "$ALLOWED" ] && ALLOWED=$(expand_home "$ALLOWED")
if [ -n "$ALLOWED" ] && [ -f "$ALLOWED" ]; then
	while IFS= read -r line; do
		case "$line" in ''|'#'*) continue ;; esac
		# Principal is the first field; the key is found by keytype pattern so a
		# trailing comment can't be mistaken for the key type/blob.
		l_principal=$(printf '%s\n' "$line" | awk '{print $1}')
		l_fields=$(ssh_key_fields "$line")
		l_type=$(printf '%s\n' "$l_fields" | cut -f1)
		l_b64=$(printf '%s\n' "$l_fields" | cut -f2)
		ssh_add_direct "$l_principal" "$l_type" "$l_b64"
	done < "$ALLOWED"
fi

# Configured SSH signing key (if any and readable): its comment is often the email.
SIGNINGKEY=$(git_cfg user.signingkey)
GPG_FORMAT=$(git_cfg gpg.format)
if [ "$GPG_FORMAT" = ssh ] && [ -n "$SIGNINGKEY" ]; then
	skf=$(expand_home "$SIGNINGKEY")
	if [ -f "$skf" ]; then
		kl=$(head -n 1 "$skf")
		k_fields=$(ssh_key_fields "$kl")
		k_type=$(printf '%s\n' "$k_fields" | cut -f1)
		k_b64=$(printf '%s\n' "$k_fields" | cut -f2)
		k_comment=$(printf '%s\n' "$k_fields" | cut -f3)
		ssh_add_direct "$k_comment" "$k_type" "$k_b64"
	fi
fi

# ---------------------------------------------------------------------------
# Emit, deterministically ordered
# ---------------------------------------------------------------------------
if [ -z "$RECORDS" ]; then
	die 1 "no signing identities found (no GPG secret keys and no SSH signing keys)"
fi

SORTED=$(printf '%s' "$RECORDS" | LC_ALL=C sort)

# Human-readable numbered list
printf 'Available signing identities\n'
n=0
printf '%s\n' "$SORTED" | while IFS="$TAB" read -r method key_id fpr name email; do
	[ -n "$method" ] || continue
	n=$((n + 1))
	printf '  %d) [%s] %s <%s>\n' "$n" "$method" "${name:-(no name)}" "${email:-(no email)}"
	printf '        key id: %s  fpr: %s\n' "${key_id:-?}" "${fpr:-?}"
done

# Machine-parseable block
printf '\n'
n=0
printf '%s\n' "$SORTED" | while IFS="$TAB" read -r method key_id fpr name email; do
	[ -n "$method" ] || continue
	n=$((n + 1))
	printf 'IDENTITY_%d_METHOD=%s\n' "$n" "$method"
	printf 'IDENTITY_%d_KEY_ID=%s\n' "$n" "$key_id"
	printf 'IDENTITY_%d_FPR=%s\n'    "$n" "$fpr"
	printf 'IDENTITY_%d_NAME=%s\n'   "$n" "$name"
	printf 'IDENTITY_%d_EMAIL=%s\n'  "$n" "$email"
done

# IDENTITY_COUNT — computed from the sorted record set.
count=$(printf '%s\n' "$SORTED" | grep -c "$TAB" || true)
printf 'IDENTITY_COUNT=%s\n' "$count"

exit 0
