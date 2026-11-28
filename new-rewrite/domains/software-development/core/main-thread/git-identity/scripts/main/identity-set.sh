#!/usr/bin/env sh
# Records the identity the human picked for a repository, as identity.set.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2312 # each jq read is checked by the comparison or the check it feeds, which refuses a wrong value
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh identity-set.sh --effort FOLDER --repo DIR --list FILE

Records the identity the human picked at the gate as the one that signs
commits in DIR's repository. The last step of the git-identity skill.

Options:
  --effort FOLDER   the effort's folder, absolute; the effort must be open
  --repo DIR        a folder in a non-bare repository, absolute
  --list FILE       identity-list.sh's saved output the card was made from
Requires:  the card shown at a recorded choice gate, record set-identity,
           subject "<repository>:<sha256 hex of FILE>", the repository as
           identity-card.sh names it; the gate's newest answer is one of
           FILE's labels; FILE still matches the machine's identities (else
           make it and ask again); each answer sets an identity once
Writes:    one identity.set event in FOLDER's events; never git config
Stdout:    one line, the event's absolute path
Exit:
  0  written
  2  refused, nothing changed; the reason is on stderr
  6  the events lock stayed held: rerun
USAGE
}

gi_prog='identity-set.sh'
. "$(dirname -- "$0")/../lib/git-identity.sh"
effort='' repo_in='' list=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--effort | --repo | --list)
			[ $# -ge 2 ] || gi_refuse "$1 needs a value"
			case $1 in --effort) effort=$2 ;; --repo) repo_in=$2 ;; --list) list=$2 ;; *) ;; esac
			shift 2 ;;
		*) gi_refuse "unknown argument $1; try --help" ;;
	esac
done
gi_find_core "$0"
command -v jq >/dev/null 2>&1 || gi_refuse 'jq not found'
case ${effort} in /*) ;; *) gi_refuse '--effort must be an absolute folder' ;; esac
[ -d "${effort}/events" ] || gi_refuse "${effort} is not an effort folder"
[ -f "${list}" ] || gi_refuse "--list ${list} is not a file"
gi_set_repo "${repo_in}"
state=$(sh "${gi_core_state}" --effort "${effort}") || exit 2
[ "${state}" = open ] || gi_refuse "the effort is ${state}; an identity is set only while it's open"
here=$(dirname -- "$0")

# 1. The machine's identities, now, against the list the card showed.
now=$(sh "${here}/identity-list.sh" 2>/dev/null) || gi_refuse 'identity-list.sh failed; run it alone to see why'
[ "$(printf '%s' "${now}" | jq -cS .)" = "$(jq -cS . "${list}" 2>/dev/null)" ] \
	|| gi_refuse "this machine's identities changed since the card was made from ${list}; make the list and show the card again"

# 2. The human's recorded pick.
subject="${gi_repo}:$(gi_sha256 "${list}")"
pick=$(sh "${gi_core_answer}" --effort "${effort}" --record set-identity --subject "${subject}" --choice) || {
	[ $? -ne 1 ] || gi_refuse "the human has not picked an identity from this list for ${gi_repo}; ask at the recorded choice gate first"
	exit 2
}
seq=$(printf '%s\n' "${pick}" | sed -n 's/^ANSWER_SEQ: //p')
answer=$(printf '%s\n' "${pick}" | sed -n 's/^ANSWER: //p')

# 3. Exactly one of the list's labels.
identity=$(jq -c --arg a "${answer}" '[.[] | select(.label == $a)] | first // empty' "${list}")
[ -n "${identity}" ] || gi_refuse "the human's answer \"${answer}\" is none of the listed identities; nothing is set"

# 4. It can sign in this repository.
said=$(sh "${here}/../internal/identity-check.sh" --repo "${gi_repo}" --name "$(printf '%s' "${identity}" | jq -r '.name')" \
	--email "$(printf '%s' "${identity}" | jq -r '.email')" --format "$(printf '%s' "${identity}" | jq -r '.signing.format')" \
	--key "$(printf '%s' "${identity}" | jq -r '.signing.key')" 2>&1) || gi_refuse "${answer} can't sign in ${gi_repo}: ${said#SIGNS: no: }"

body=$(mktemp)
trap 'rm -f -- "${body}"' EXIT
printf '%s' "${identity}" | jq --arg repo "${gi_repo}" --argjson answer "${seq}" \
	'{repo: $repo, name, email, signing, fingerprint, answer: $answer}' >"${body}"
sh "${gi_core_writer}" --effort "${effort}" --type identity.set --by identity-set.sh --body-file "${body}"
