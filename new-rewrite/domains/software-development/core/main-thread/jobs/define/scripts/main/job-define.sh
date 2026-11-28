#!/usr/bin/env sh
# Writes one job.defined per job the human approved at a jobs gate.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh job-define.sh --effort FOLDER --gate SEQ

Defines the jobs of the proposal approved at gate SEQ: the gate must be a
jobs gate the human accepted, and the proposal unchanged since its card.
They are written in the proposal's order; a job refused stops the rest,
and the ones already written are named.

Options:
  --effort FOLDER  the effort's folder, absolute
  --gate SEQ       the seq of the gate.answered job-card.sh's gate wrote
Writes:    one job.defined per job, in the proposal's order
Stdout:    "jobs SEQ, SEQ defined", then one line per job whose tree is
           still to be cut
Exit:
  0  all defined
  2  refused; nothing written, or the ones written named; reason on stderr
  6  the events lock stayed held: rerun
USAGE
}

prog='job-define.sh'
refuse() {
	printf '%s: %s\n' "${prog}" "$1" >&2
	exit 2
}

effort='' gate=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--effort | --gate)
			[ $# -ge 2 ] && [ -n "$2" ] || refuse "$1 needs a value"
			case $1 in --effort) effort=$2 ;; --gate) gate=$2 ;; *) ;; esac
			shift 2 ;;
		*) refuse "unknown argument $1; try --help" ;;
	esac
done
command -v jq >/dev/null 2>&1 || refuse 'jq not found'
case ${effort} in /*) ;; *) refuse '--effort must be an absolute folder' ;; esac
[ -d "${effort}/events" ] || refuse "${effort} is not an effort folder"
printf '%s\n' "${gate}" | grep -Eqx '[1-9][0-9]*' || refuse '--gate must be a whole number from 1'

self=$0
case ${self} in /*) ;; *) self="$(pwd)/${self}" ;; esac
skills=${self%/*/*/*/*}
reader="${skills}/crucible-events/scripts/internal/events-read.sh"
writer="${skills}/crucible-events/scripts/internal/event-write.sh"
for need in "${reader}" "${writer}"; do
	[ -f "${need}" ] || refuse "crucible-events isn't beside this skill (expected ${need}); install first"
done
. "${skills}/crucible-events/scripts/lib/sha256.sh"

work=$(mktemp -d "${TMPDIR:-/tmp}/job-define.XXXXXX") || refuse 'mktemp could not make a work folder'
trap 'rm -rf -- "${work}"' EXIT
sh "${reader}" --effort "${effort}" >"${work}/events" || refuse 'the effort'"'"'s events could not be read'

jq -c --argjson g "${gate}" '[.[] | select(.seq == $g)] | first // empty' "${work}/events" >"${work}/gate"
[ -s "${work}/gate" ] || refuse "there is no event ${gate} in ${effort}"
jq -e '.type == "gate.answered" and .body.record == "jobs"' "${work}/gate" >/dev/null \
	|| refuse "event ${gate} is not a jobs gate's answer"
jq -e '.body.accepted == true' "${work}/gate" >/dev/null \
	|| refuse "gate ${gate} was answered $(jq -c '.body.answer' "${work}/gate"), not approved: nothing to define"
defined=$(jq -r --argjson g "${gate}" '[.[] | select(.type == "job.defined" and .body.approval_gate.ref == $g) | .seq]
	| map(tostring) | join(", ")' "${work}/events")
[ -z "${defined}" ] || refuse "gate ${gate}'s jobs are already defined: ${defined}"

sha=$(jq -r '.body.subject' "${work}/gate")
proposal="${effort}/proposals/${sha}.json"
[ -f "${proposal}" ] || refuse "the card showed proposal ${sha}, and ${effort}/proposals has no such file: resolve again"
now=$(sh_sha256 "${proposal}")
[ "${now}" = "${sha}" ] || refuse "the card showed ${sha}, the file is now ${now}: resolve again"

count=$(jq '.jobs | length' "${proposal}")
done_seqs='' i=0
: >"${work}/seqs"
while [ "${i}" -lt "${count}" ]; do
	jq --argjson i "${i}" --argjson g "${gate}" '.jobs[$i] + {approval_gate: {ref: $g, position: ($i + 1)}}' \
		"${proposal}" >"${work}/body"
	rc=0
	path=$(sh "${writer}" --effort "${effort}" --type job.defined --by "${prog}" --body-file "${work}/body" 2>"${work}/said") || rc=$?
	if [ "${rc}" -ne 0 ]; then
		said=$(sed "s/^/  /" "${work}/said")
		if [ -n "${done_seqs}" ]; then
			printf '%s: job %s refused, so the rest are not defined; defined: %s\n%s\n' "${prog}" "$((i + 1))" "${done_seqs}" "${said}" >&2
		else
			printf '%s: job %s refused, nothing defined\n%s\n' "${prog}" "$((i + 1))" "${said}" >&2
		fi
		[ "${rc}" -eq 6 ] && exit 6
		exit 2
	fi
	seq=$(jq -r '.seq' "${path}")
	printf '%s\n' "${seq}" >>"${work}/seqs"
	done_seqs="${done_seqs:+${done_seqs}, }${seq}"
	i=$((i + 1))
done
if [ "${count}" -eq 1 ]; then noun='job'; else noun='jobs'; fi
printf '%s %s defined\n' "${noun}" "${done_seqs}"
jq -r --slurpfile seqs "${work}/seqs" '.jobs | to_entries[] | select(.value.work.tree.cut)
	| "job \($seqs[.key]): its tree is still to be cut, in \(.value.work.tree.cut.repo) from \(.value.work.tree.cut.from)"' "${proposal}"
