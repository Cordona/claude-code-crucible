#!/usr/bin/env sh
# Says whether the human's newest answer to a recorded gate accepted it: the
# one home of that reading rule, for every piece that acts on a decision.
set -eu

usage() {
	cat <<'USAGE'
usage: sh gate-answer.sh --effort FOLDER --record NAME --subject TEXT
       sh gate-answer.sh --help | -h

Reads the effort's gate.answered events written by record-gate-answer.sh
for NAME and TEXT, and takes the newest: the human's current answer. A
later "no" cancels an earlier "yes". Whether an acceptance may be used
twice is the caller's own rule.

  --effort FOLDER   the effort's folder, absolute
  --record NAME     the decision, as show-card.sh --record named it
  --subject TEXT    what exactly was decided on

stdout, when the newest answer accepted: ACCEPTED: <its seq>
Exit: 0 accepted; 1 the newest answer did not accept, or there is none
  (stderr says which); 2 refused, the reason on stderr
USAGE
}

refuse() { printf 'gate-answer.sh: %s\n' "$1" >&2; exit 2; }
effort='' record='' subject=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--effort | --record | --subject)
			[ $# -ge 2 ] || refuse "$1 needs a value"
			case $1 in --effort) effort=$2 ;; --record) record=$2 ;; --subject) subject=$2 ;; esac
			shift 2 ;;
		*) refuse "unknown argument $1; try --help" ;;
	esac
done
case ${effort} in /*) ;; *) refuse '--effort must be an absolute folder' ;; esac
[ -d "${effort}/events" ] || refuse "${effort} is not an effort folder"
[ -n "${record}" ] || refuse '--record is empty'
command -v jq >/dev/null 2>&1 || refuse 'jq not found'
# shellcheck disable=SC2016 # the $ names are jq's
newest=$(sh "$(dirname -- "$0")/../../crucible-events/scripts/events-read.sh" --effort "${effort}" --type gate.answered \
	| jq -c --arg r "${record}" --arg s "${subject}" '[.[] | select(.by == "record-gate-answer.sh"
		and .body.record == $r and .body.subject == $s)] | last // empty')
[ -n "${newest}" ] || { printf 'gate-answer.sh: no answer for %s on %s\n' "${record}" "${subject}" >&2; exit 1; }
if [ "$(printf '%s' "${newest}" | jq -r '.body.accepted')" = true ]; then
	printf 'ACCEPTED: %s\n' "$(printf '%s' "${newest}" | jq -r '.seq')"
else
	printf 'gate-answer.sh: the newest answer (event %s) did not accept: %s\n' \
		"$(printf '%s' "${newest}" | jq -r '.seq')" "$(printf '%s' "${newest}" | jq -r '.body.answer')" >&2
	exit 1
fi
