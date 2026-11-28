#!/usr/bin/env sh
# Lists the signing identities this machine can use, as JSON. Reads only.
set -eu

usage() {
	cat <<'USAGE'
usage: sh identity-list.sh

Lists the identities this machine can sign with: GPG secret keys, and SSH keys
named by git's global user.signingkey or allowed-signers file. Run it before
identity-card.sh; save stdout unchanged as the --list FILE of identity-card.sh
and identity-set.sh.

Reads:     GNUPGHOME, SSH_AUTH_SOCK, HOME (~/.ssh)
Writes:    nothing
Stdout:    one JSON array, [] when none, of {label (unique), name, email,
           signing: {format: "openpgp" | "ssh", key}, fingerprint ("" if
           unknown)}
Exit:
  0  printed
  2  refused, nothing changed; the reason is on stderr
USAGE
}

prog='identity-list.sh'
case ${1-} in -h | --help) usage; exit 0 ;; '') ;; *) printf '%s: unknown argument %s; try --help\n' "${prog}" "$1" >&2; exit 2 ;; esac
command -v jq >/dev/null 2>&1 || { printf '%s: jq not found\n' "${prog}" >&2; exit 2; }

git_cfg() { git config --global "$1" 2>/dev/null || true; }
# shellcheck disable=SC2088 # a literal ~/ in a git path, expanded here
expand_home() { case $1 in '~/'*) printf '%s\n' "${HOME}/${1#\~/}" ;; *) printf '%s\n' "$1" ;; esac; }

# Prints "<type>\t<base64>\t<comment>" for the first SSH key in line $1.
ssh_key_fields() {
	printf '%s\n' "$1" | awk '
		function iskt(t) {
			return (t == "ssh-ed25519" || t == "ssh-rsa" || t == "ssh-dss" ||
				t == "ecdsa-sha2-nistp256" || t == "ecdsa-sha2-nistp384" ||
				t == "ecdsa-sha2-nistp521" ||
				t == "sk-ssh-ed25519@openssh.com" ||
				t == "sk-ecdsa-sha2-nistp256@openssh.com")
		}
		{ for (i = 1; i <= NF; i++) if (iskt($i)) {
			printf "%s\t%s\t%s\n", $i, (i < NF) ? $(i + 1) : "", (i + 1 < NF) ? $(i + 2) : ""
			exit } }'
}

records=$(mktemp)
trap 'rm -f -- "${records}"' EXIT
# One identity per line as JSON: {name, email, signing: {format, key}, fingerprint}.
add() { jq -cn --arg n "$1" --arg e "$2" --arg f "$3" --arg k "$4" --arg p "$5" \
	'{name: $n, email: $e, signing: {format: $f, key: $k}, fingerprint: $p}' >>"${records}"; }

# GPG: each secret key's usable user ids.
if command -v gpg >/dev/null 2>&1; then
	if gpg_out=$(gpg --list-secret-keys --with-colons 2>/dev/null); then
		id='' fpr='' have_fpr=0
		while IFS= read -r line; do
			case ${line} in
				sec:*) id=$(printf '%s\n' "${line}" | cut -d: -f5); fpr=''; have_fpr=0 ;;
				fpr:*) [ "${have_fpr}" -eq 1 ] || { fpr=$(printf '%s\n' "${line}" | cut -d: -f10); have_fpr=1; } ;;
				ssb:*) have_fpr=1 ;;
				uid:*)
					case $(printf '%s\n' "${line}" | cut -d: -f2) in r | e) continue ;; esac
					raw=$(printf '%s\n' "${line}" | cut -d: -f10)
					email=$(printf '%s\n' "${raw}" | sed -n 's/.*<\([^>]*\)>.*/\1/p')
					name=$(printf '%s\n' "${raw}" | sed 's/ *<[^>]*>.*//; s/ *([^)]*) *$//')
					[ -z "${id}" ] || [ -z "${email}" ] || add "${name}" "${email}" openpgp "${id}" "${fpr}"
					;;
			esac
		done <<EOF
${gpg_out}
EOF
	fi
else
	printf '%s: gpg not installed; no GPG identities\n' "${prog}" >&2
fi

# SSH: the keys this machine can sign with.
agent=''
if command -v ssh-add >/dev/null 2>&1; then
	keys=$(ssh-add -L </dev/null 2>/dev/null || true)
	while IFS= read -r line; do
		b64=$(ssh_key_fields "${line}" | cut -f2)
		[ -z "${b64}" ] || agent="${agent} ${b64}"
	done <<EOF
${keys}
EOF
else
	printf '%s: ssh-add not installed; no agent keys\n' "${prog}" >&2
fi
command -v ssh-keygen >/dev/null 2>&1 || printf '%s: ssh-keygen not installed; SSH fingerprints left empty\n' "${prog}" >&2
agent_holds() { case " ${agent} " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
fpr_of() { command -v ssh-keygen >/dev/null 2>&1 || return 0; printf '%s %s\n' "$1" "$2" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}' || true; }
pub_with_private() {
	for pub in "${HOME}"/.ssh/*.pub; do
		[ -f "${pub}" ] && [ -f "${pub%.pub}" ] || continue
		[ "$(ssh_key_fields "$(head -n 1 "${pub}")" | cut -f2)" = "$1" ] && { printf '%s\n' "${pub}"; return 0; }
	done
	return 1
}
ssh_name=$(git_cfg user.name)
allowed=$(git_cfg gpg.ssh.allowedSignersFile)
[ -z "${allowed}" ] || allowed=$(expand_home "${allowed}")
[ -n "${allowed}" ] && [ -f "${allowed}" ] || allowed=''
seen=''
# Adds SSH key $3 ($1 type, $2 base64) for each principal in comma list $4.
add_ssh() {
	case " ${seen} " in *" $2 "*) return 0 ;; esac
	seen="${seen} $2"
	f=$(fpr_of "$1" "$2")
	printf '%s\n' "$4" | tr ',' '\n' | while IFS= read -r principal; do
		[ -z "${principal}" ] || add "${ssh_name}" "${principal}" ssh "$3" "${f}"
	done
}
principals_of() {
	[ -n "${allowed}" ] || return 0
	while IFS= read -r line; do
		case ${line} in '' | '#'*) continue ;; esac
		[ "$(ssh_key_fields "${line}" | cut -f2)" = "$1" ] && { printf '%s\n' "${line}" | awk '{print $1}'; return 0; }
	done <"${allowed}"
}
# The configured signing key first, when git signs with SSH.
signingkey=$(git_cfg user.signingkey)
if [ "$(git_cfg gpg.format)" = ssh ] && [ -n "${signingkey}" ]; then
	case ${signingkey} in
		key::* | ssh-*)
			fields=$(ssh_key_fields "${signingkey#key::}")
			type=$(printf '%s\n' "${fields}" | cut -f1); b64=$(printf '%s\n' "${fields}" | cut -f2)
			key="key::${type} ${b64}"; signs=0; agent_holds "${b64}" && signs=1 ;;
		*)
			key=$(expand_home "${signingkey}")
			case ${key} in *.pub) pub=${key} private=${key%.pub} ;; *) pub=${key}.pub private=${key} ;; esac
			line=''; [ ! -f "${pub}" ] || line=$(head -n 1 "${pub}")
			fields=$(ssh_key_fields "${line}")
			type=$(printf '%s\n' "${fields}" | cut -f1); b64=$(printf '%s\n' "${fields}" | cut -f2)
			signs=0; { [ -n "${b64}" ] && agent_holds "${b64}"; } && signs=1; [ ! -f "${private}" ] || signs=1 ;;
	esac
	if [ "${signs}" -eq 1 ] && [ -n "${b64}" ]; then
		who=$(principals_of "${b64}")
		[ -n "${who}" ] || who=$(printf '%s\n' "${fields}" | cut -f3)
		add_ssh "${type}" "${b64}" "${key}" "${who}"
	fi
fi
# Then every allowed signer this machine can sign as.
if [ -n "${allowed}" ]; then
	while IFS= read -r line; do
		case ${line} in '' | '#'*) continue ;; esac
		who=$(printf '%s\n' "${line}" | awk '{print $1}')
		fields=$(ssh_key_fields "${line}")
		type=$(printf '%s\n' "${fields}" | cut -f1); b64=$(printf '%s\n' "${fields}" | cut -f2)
		[ -n "${b64}" ] || continue
		if agent_holds "${b64}"; then
			add_ssh "${type}" "${b64}" "key::${type} ${b64}" "${who}"
		elif pub=$(pub_with_private "${b64}"); then
			add_ssh "${type}" "${b64}" "${pub}" "${who}"
		fi
	done <"${allowed}"
fi

# Each identity labelled; a repeated label gains " #2", " #3".
jq -s '[.[] | . + {label: "\(.name) <\(.email)> · \(.signing.format) \(if .fingerprint == "" then "no fingerprint" elif .signing.format == "openpgp" then .fingerprint[-8:] else .fingerprint | sub("^SHA256:"; "") | .[0:8] end)"}]
	| reduce .[] as $i ([]; . as $acc
		| ([$acc[] | select(.base == $i.label)] | length) as $n
		| $acc + [$i + {base: $i.label, label: (if $n == 0 then $i.label else "\($i.label) #\($n + 1)" end)}])
	| map({label, name, email, signing, fingerprint})' "${records}"
