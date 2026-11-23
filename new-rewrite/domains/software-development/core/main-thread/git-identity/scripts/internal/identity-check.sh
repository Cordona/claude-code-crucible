#!/usr/bin/env sh
# Says whether one identity can sign commits in one repository. Reads only.
set -eu

usage() {
	cat <<'USAGE'
usage: sh identity-check.sh --repo DIR --name NAME --email EMAIL
         --format openpgp|ssh --key KEY

Run by identity-card.sh and identity-set.sh; not for main to call.
Says whether this machine can sign commits in one repository as one identity.
Yes means: openpgp, KEY's secret key is live with a live user id for EMAIL;
ssh, the agent or KEY's private key file holds KEY, and the repository's
gpg.ssh.allowedSignersFile names EMAIL with KEY.

Options:
  --repo DIR            DIR, absolute: any folder inside a git repository
  --name NAME           the name to sign as; not matched against the key
  --email EMAIL         the email to sign as
  --format openpgp|ssh  the kind of key KEY is
  --key KEY             openpgp: a gpg key id or fingerprint; ssh: a key file
                        (.pub optional, ~/ allowed), a key line or key::LINE
Reads:     GNUPGHOME, SSH_AUTH_SOCK, HOME
Writes:    nothing
Stdout:    one line: SIGNS: yes, or SIGNS: no: REASON
Exit:
  0  it can sign
  1  it can't sign; REASON says why
  2  refused, nothing changed; the reason is on stderr
USAGE
}

prog='identity-check.sh'
refuse() { printf '%s: %s\n' "${prog}" "$1" >&2; exit 2; }
no() { printf 'SIGNS: no: %s\n' "$1"; exit 1; }
repo='' name='' email='' format='' key=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--repo | --name | --email | --format | --key)
			[ $# -ge 2 ] || refuse "$1 needs a value"
			case $1 in --repo) repo=$2 ;; --name) name=$2 ;; --email) email=$2 ;; --format) format=$2 ;; --key) key=$2 ;; esac
			shift 2 ;;
		*) refuse "unknown argument $1; try --help" ;;
	esac
done
case ${repo} in /*) ;; *) refuse '--repo must be an absolute folder' ;; esac
git -C "${repo}" rev-parse --git-dir >/dev/null 2>&1 || refuse "--repo ${repo} is not in a git repository"
case ${format} in openpgp | ssh) ;; *) refuse '--format must be openpgp or ssh' ;; esac
[ -n "${key}" ] || refuse '--key is empty'
printf '%s' "${name}" | grep -q '[^[:space:]]' || no 'the name is empty'
case ${email} in *@*) ;; *) no "the email ${email} has no @" ;; esac

if [ "${format}" = openpgp ]; then
	command -v gpg >/dev/null 2>&1 || no 'gpg is not installed'
	uids=$(gpg --list-secret-keys --with-colons -- "${key}" 2>/dev/null) || no "no secret key ${key} in the key ring"
	printf '%s\n' "${uids}" | awk -F: -v e="${email}" '
		$1 == "sec" && ($2 == "r" || $2 == "e") { dead = 1 }
		$1 == "uid" && $2 != "r" && $2 != "e" && index($10, "<" e ">") { found = 1 }
		END { exit !(found && !dead) }' || no "key ${key} carries no usable user id with ${email}"
	printf 'SIGNS: yes\n'
	exit 0
fi

# ssh: the key's base64, and whether this machine can sign with it.
fields() {
	printf '%s\n' "$1" | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^(ssh-|ecdsa-|sk-)/) { print $(i + 1); exit } }'
}
# shellcheck disable=SC2088 # a literal ~/ in a git path, expanded here
expand_home() { case $1 in "~/"*) printf '%s\n' "${HOME}/${1#\~/}" ;; *) printf '%s\n' "$1" ;; esac; }
case ${key} in
	key::* | ssh-* | ecdsa-* | sk-*) b64=$(fields "${key#key::}"); private='' ;;
	*)
		file=$(expand_home "${key}")
		case ${file} in *.pub) pub=${file} private=${file%.pub} ;; *) pub=${file}.pub private=${file} ;; esac
		[ -f "${pub}" ] || no "key file ${pub} is not there"
		b64=$(fields "$(head -n 1 "${pub}")") ;;
esac
[ -n "${b64}" ] || no "key ${key} is not an SSH key"
agent=$(ssh-add -L </dev/null 2>/dev/null || true)
if ! printf '%s\n' "${agent}" | awk -v b="${b64}" '{ for (i = 1; i <= NF; i++) if ($i == b) f = 1 } END { exit !f }'; then
	[ -n "${private}" ] && [ -f "${private}" ] || no "this machine can't sign with key ${key}: the agent doesn't hold it and its private key isn't there"
fi
allowed=$(git -C "${repo}" config gpg.ssh.allowedSignersFile 2>/dev/null || true)
[ -n "${allowed}" ] || no 'git has no gpg.ssh.allowedSignersFile for this repository, so no SSH signature can be verified'
allowed=$(expand_home "${allowed}")
[ -f "${allowed}" ] || no "the allowed-signers file ${allowed} is not there"
awk -v e="${email}" -v b="${b64}" '
	/^[[:space:]]*(#|$)/ { next }
	{ n = split($1, who, ","); for (i = 1; i <= n; i++) if (who[i] == e) for (j = 2; j <= NF; j++) if ($j == b) f = 1 }
	END { exit !f }' "${allowed}" || no "the allowed-signers file doesn't name ${email} with this key"
printf 'SIGNS: yes\n'
