#!/usr/bin/env sh
# Prints the card, or the question, for picking a repository's identity.
# shellcheck source-path=SCRIPTDIR
# Reads only.
set -eu

usage() {
	cat <<'USAGE'
usage: sh identity-card.sh --list FILE --repo DIR [--question]

Prints the card for picking which identity signs commits in a repository,
or, with --question, the AskUserQuestion input for that pick. It names the
repository by its main checkout's top folder (physical path), for any
worktree or subfolder.

Options:
  --list FILE   identity-list.sh's output saved to a file
  --repo DIR    a folder in a non-bare repository, absolute
  --question    print the question, not the card
Writes:    nothing
Stdout:    the card (usable identities numbered, with their key, then the
           others with reasons), or one JSON question to ask as printed:
           one option per usable identity, labelled as in FILE, plus
           "None of these" (stop) when only one can sign
Exit:
  0  printed; 1 to 4 identities can sign
  2  refused, nothing changed; the reason is on stderr
  3  none can sign: tell the human to set up a signing key, and stop;
     or more than 4 can: show the card, do not ask the question, and
     have the human answer with one of the card's labels
USAGE
}

gi_prog='identity-card.sh'
. "$(dirname -- "$0")/../lib/git-identity.sh"
list='' repo_in='' question=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--list | --repo)
			[ $# -ge 2 ] || gi_refuse "$1 needs a value"
			case $1 in --list) list=$2 ;; --repo) repo_in=$2 ;; *) ;; esac
			shift 2 ;;
		--question) question=1; shift ;;
		*) gi_refuse "unknown argument $1; try --help" ;;
	esac
done
command -v jq >/dev/null 2>&1 || gi_refuse 'jq not found'
[ -f "${list}" ] || gi_refuse "--list ${list} is not a file"
jq -e 'type == "array" and all(.[]; (.label | type) == "string" and (.signing.format | type) == "string")' "${list}" >/dev/null 2>&1 \
	|| gi_refuse "--list ${list} is not a list identity-list.sh printed"
gi_find_skills "$0"
gi_set_repo "${repo_in}"
check="$(dirname -- "$0")/../internal/identity-check.sh"

# Each identity with what identity-check.sh says of it in this repository.
checked=$(jq -c '.[]' "${list}" | while IFS= read -r id; do
	said=$(sh "${check}" --repo "${gi_repo}" --name "$(printf '%s' "${id}" | jq -r '.name')" \
		--email "$(printf '%s' "${id}" | jq -r '.email')" --format "$(printf '%s' "${id}" | jq -r '.signing.format')" \
		--key "$(printf '%s' "${id}" | jq -r '.signing.key')" 2>&1 || true)
	printf '%s' "${id}" | jq -c --arg said "${said}" '. + {said: $said}'
done | jq -s .)
usable=$(printf '%s' "${checked}" | jq '[.[] | select(.said == "SIGNS: yes")] | length')

printf '%s' "${checked}" | jq -r --arg repo "${gi_repo}" --argjson q "${question:-0}" '
	[.[] | select(.said == "SIGNS: yes")] as $ok | [.[] | select(.said != "SIGNS: yes")] as $not
	| if $q == 1 then
		{questions: [{header: "Identity", multiSelect: false,
		  question: "Which identity signs this effort'"'"'s commits in \($repo)?",
		  options: ([$ok[] | {label, description: "\(.signing.format) key \(if .fingerprint == "" then .signing.key else .fingerprint end)"}]
			+ (if ($ok | length) == 1 then [{label: "None of these", description: "Stop: set up another signing key first"}] else [] end))}]}
		| tojson
	  else
		"Git identity for \($repo)",
		"Pick the identity this effort'"'"'s commits in \($repo) are signed as.",
		(if ($ok | length) == 0 then "  No identity on this machine can sign here." else
			($ok | to_entries[] | "  \(.key + 1). \(.value.label)", "     key \(if .value.fingerprint == "" then .value.signing.key else .value.fingerprint end)") end),
		(if ($not | length) > 0 then "Not usable here:", ($not[] | "  - \(.label): \(.said | sub("^SIGNS: no: "; ""))") else empty end)
	  end'
if [ "${usable}" -eq 0 ]; then
	printf '%s: no identity on this machine can sign in %s; set up a signing key first\n' "${gi_prog}" "${gi_repo}" >&2
	exit 3
fi
if [ "${usable}" -gt 4 ]; then
	printf '%s: %s identities can sign in %s, and the question holds at most 4\n' "${gi_prog}" "${usable}" "${gi_repo}" >&2
	exit 3
fi
