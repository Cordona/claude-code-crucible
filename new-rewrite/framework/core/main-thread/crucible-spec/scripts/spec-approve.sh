#!/usr/bin/env sh
# Records a spec draft the human approved as the effort's spec: copies it
# into the context's draft docs as spec.md, then writes spec.approved.
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh spec-approve.sh --effort FOLDER --draft FILE
       sh spec-approve.sh --help | -h

Approves FILE, once the human accepted it. The gate must have recorded the
decision as spec-approval, with FILE's sha256 as its subject, and the human's
newest answer to it must be the option named as yes; one yes approves once.
Then FILE is copied into the context's draft docs folder as spec.md,
replacing an earlier one, and spec.approved {sha256, answer} is written last.

  --effort FOLDER   the effort's folder, absolute; the effort must be open
  --draft FILE      the draft: a text file of at most 1048576 bytes

stdout: the spec.approved event's path
Exit: 0 approved; 1 the human has not accepted this draft; 2 refused, the
  reason on stderr; 6 the events lock stayed held: rerun
USAGE
}

refuse() { printf 'spec-approve.sh: %s\n' "$1" >&2; exit 2; }
effort='' draft=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--effort | --draft)
			[ $# -ge 2 ] || refuse "$1 needs a value"
			case $1 in --effort) effort=$2 ;; --draft) draft=$2 ;; esac
			shift 2 ;;
		*) refuse "unknown argument $1; try --help" ;;
	esac
done
here=$(cd -- "$(dirname -- "$0")" && pwd)
core="${here}/../.."
case ${effort} in /*) ;; *) refuse '--effort must be an absolute folder' ;; esac
[ -f "${draft}" ] && [ ! -L "${draft}" ] || refuse "--draft ${draft} is not a regular file"
LC_ALL=C grep -Iq . "${draft}" 2>/dev/null || refuse "--draft ${draft} is empty or not text"
[ "$(wc -c <"${draft}")" -le 1048576 ] || refuse "--draft ${draft} is over 1048576 bytes"
. "${core}/crucible-events/scripts/lib/sha256.sh"
sha=$(sh_sha256 "${draft}")

answer=$(sh "${core}/crucible-gate/scripts/gate-answer.sh" --effort "${effort}" --record spec-approval --subject "${sha}") || exit $?
answer=${answer#ACCEPTED: }
used=$(sh "${core}/crucible-events/scripts/events-read.sh" --effort "${effort}" --type spec.approved \
	| jq --argjson a "${answer}" 'any(.[]; .body.answer == $a)')
[ "${used}" != true ] || refuse "the human's yes (event ${answer}) already approved this draft; ask again to approve it again"

docs=$(sh "${core}/crucible-context/scripts/context-docs.sh" --effort "${effort}") || exit 2
temp=$(mktemp "${docs}/.tmp.XXXXXX")
trap 'rm -f -- "${temp}"' EXIT
cat -- "${draft}" >"${temp}"
mv -f -- "${temp}" "${docs}/spec.md"

body=$(mktemp)
trap 'rm -f -- "${temp}" "${body}"' EXIT
jq -n --arg sha "${sha}" --argjson answer "${answer}" '{sha256: $sha, answer: $answer}' >"${body}"
sh "${core}/crucible-events/scripts/event-write.sh" --effort "${effort}" --type spec.approved \
	--by spec-approve.sh --body-file "${body}"
