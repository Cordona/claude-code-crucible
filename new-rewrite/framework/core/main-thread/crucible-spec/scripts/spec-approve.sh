#!/usr/bin/env sh
# Records a spec draft the human approved as the effort's spec: seals it
# read-only where it is, then writes spec.approved naming it.
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh spec-approve.sh --effort FOLDER --draft FILE
       sh spec-approve.sh --help | -h

Approves FILE, once the human accepted it. The gate must have recorded the
decision as spec-approval, with FILE's sha256 as its subject, and the human's
newest answer to it must be the option named as yes; one yes approves once.
FILE stays where it was drafted and becomes read-only (mode 444); then
spec.approved {sha256, answer, path} is written. A revision is a new file
and a new approval; the newest spec.approved is the spec. If the event
can't be written, FILE is left read-only and unapproved, and a rerun works.
No context is required: the facts may have lived in the conversation.

  --effort FOLDER   the effort's folder, absolute; the effort must be open
  --draft FILE      the draft, in this effort's spec/ folder: a text file of
                    at most 1048576 bytes

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
state=$(sh "${core}/crucible-effort/scripts/effort-state.sh" --effort "${effort}") || exit 2
[ "${state}" = open ] || refuse "the effort is ${state}; a spec is approved only while it's open"
[ -f "${draft}" ] && [ ! -L "${draft}" ] || refuse "--draft ${draft} is not a regular file"
# The draft lives in this effort's spec/ folder, so the approved spec is durable.
draft_dir=$(cd -P -- "$(dirname -- "${draft}")" 2>/dev/null && pwd -P) || refuse "--draft ${draft} is not a regular file"
spec_dir=$(cd -P -- "${effort}/spec" 2>/dev/null && pwd -P) || spec_dir=''
[ -n "${spec_dir}" ] && [ "${draft_dir}" = "${spec_dir}" ] \
	|| refuse "--draft ${draft} is not in this effort's spec/ folder (${effort}/spec/)"
draft="${draft_dir}/$(basename -- "${draft}")"
LC_ALL=C grep -Iq . "${draft}" 2>/dev/null || refuse "--draft ${draft} is empty or not text"
[ "$(wc -c <"${draft}")" -le 1048576 ] || refuse "--draft ${draft} is over 1048576 bytes"
. "${core}/crucible-events/scripts/lib/sha256.sh"
sha=$(sh_sha256 "${draft}")

answer=$(sh "${core}/crucible-gate/scripts/gate-answer.sh" --effort "${effort}" --record spec-approval --subject "${sha}") || exit $?
answer=${answer#ACCEPTED: }
used=$(sh "${core}/crucible-events/scripts/events-read.sh" --effort "${effort}" --type spec.approved \
	| jq --argjson a "${answer}" 'any(.[]; .body.answer == $a)')
[ "${used}" != true ] || refuse "the human's yes (event ${answer}) already approved this draft; ask again to approve it again"

# Sealed where it is first, then the event: a failed write leaves a read-only,
# unapproved draft that a rerun approves.
chmod 444 "${draft}" || refuse "--draft ${draft} could not be made read-only"
body=$(mktemp)
trap 'rm -f -- "${body}"' EXIT
jq -n --arg sha "${sha}" --argjson answer "${answer}" --arg path "${draft}" '{sha256: $sha, answer: $answer, path: $path}' >"${body}"
sh "${core}/crucible-events/scripts/event-write.sh" --effort "${effort}" --type spec.approved \
	--by spec-approve.sh --body-file "${body}"
