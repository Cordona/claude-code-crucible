#!/usr/bin/env sh
# Says whether the human's newest answer to a recorded gate accepted it: the
# one home of that reading rule, for every piece that acts on a decision.
set -eu

usage() {
	cat <<'USAGE'
usage: sh gate-answer.sh --effort FOLDER --record NAME [--subject TEXT]
                         [--choice]
       sh gate-answer.sh --effort FOLDER --record NAME --subject-prefix TEXT
                         [--after SEQ]

Run by scripts that act on a recorded gate's answer; not for main to call.
Reports the human's newest answer to a show-card.sh --record gate. Only the
newest counts: a later "no" cancels an earlier "yes". Single use of an
acceptance is the caller's own rule.

Options:
  --effort FOLDER        the effort the gate was shown in, absolute
  --record NAME          the NAME given to show-card.sh --record
  --subject TEXT         the TEXT given to show-card.sh --subject; default ""
  --choice               for a show-card.sh --choice gate; refused for a yes one
  --subject-prefix TEXT  list each yes-gate subject starting with TEXT, as
                         written, whose newest answer accepted
  --after SEQ            with --subject-prefix: answers after event SEQ only
Stdout:    "ACCEPTED: SEQ"; with --choice "ANSWER_SEQ: SEQ" then "ANSWER: the
           answer"; with --subject-prefix one JSON object {answers: [{seq,
           subject}]}, oldest first; SEQ is the answer event's integer seq
Exit:
  0  accepted; with --choice an answer exists; with --subject-prefix listed
  1  no answer, or the newest answer did not accept; reason on stderr
  2  refused, nothing changed; the reason is on stderr
USAGE
}

refuse() { printf 'gate-answer.sh: %s\n' "$1" >&2; exit 2; }

# Prints the subjects of record $record starting with $prefix whose newest
# answer accepted and came after event $after, as {answers: [{seq, subject}]}.
list_accepted() {
	# shellcheck disable=SC2016 # the $ names are jq's
	newest=$(printf '%s\n' "${answers}" | jq -c --arg r "${record}" --arg p "${prefix}" '[.[] | select(.by == "record-gate-answer.sh"
		and .body.record == $r and (.body.subject | startswith($p)))] | group_by(.body.subject) | map(max_by(.seq))')
	all_yes=$(printf '%s' "${newest}" | jq 'all(.[]; .body | has("accept"))')
	[ "${all_yes}" = true ] || refuse "an answer for ${record} is a choice; read it with --choice"
	# shellcheck disable=SC2016 # the $ names are jq's
	printf '%s' "${newest}" | jq -c --arg after "${after}" '{answers: [.[] | select(.body.accepted == true
		and .seq > ($after | tonumber)) | {seq, subject: .body.subject}] | sort_by(.seq)}'
}

effort='' record='' subject='' choice='' prefix='' prefix_given='' after=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--effort | --record | --subject | --subject-prefix | --after)
			[ $# -ge 2 ] || refuse "$1 needs a value"
			case $1 in
				--effort) effort=$2 ;; --record) record=$2 ;; --subject) subject=$2 ;;
				--subject-prefix) prefix=$2; prefix_given=1 ;; --after) after=$2 ;;
				*) ;;
			esac
			shift 2 ;;
		--choice) choice=1; shift ;;
		*) refuse "unknown argument $1; try --help" ;;
	esac
done
case ${effort} in /*) ;; *) refuse '--effort must be an absolute folder' ;; esac
[ -d "${effort}/events" ] || refuse "${effort} is not an effort folder"
[ -n "${record}" ] || refuse '--record is empty'
if [ -n "${prefix_given}" ]; then
	[ -n "${prefix}" ] || refuse '--subject-prefix is empty'
	[ -z "${subject}" ] || refuse '--subject and --subject-prefix go apart'
	[ -z "${choice}" ] || refuse '--choice and --subject-prefix go apart'
	case ${after:-0} in *[!0-9]*) refuse "--after must be an event seq, a whole number; got ${after}" ;; *) ;; esac
	after=${after:-0}
else
	[ -z "${after}" ] || refuse '--after goes with --subject-prefix'
fi
command -v jq >/dev/null 2>&1 || refuse 'jq not found'
answers=$(sh "$(dirname -- "$0")/../../../crucible-events/scripts/internal/events-read.sh" --effort "${effort}" --type gate.answered) \
	|| exit 2
if [ -n "${prefix_given}" ]; then
	list_accepted
	exit 0
fi
# shellcheck disable=SC2016 # the $ names are jq's
newest=$(printf '%s\n' "${answers}" | jq -c --arg r "${record}" --arg s "${subject}" '[.[] | select(.by == "record-gate-answer.sh"
		and .body.record == $r and .body.subject == $s)] | last // empty')
[ -n "${newest}" ] || { printf 'gate-answer.sh: no answer for %s on %s\n' "${record}" "${subject}" >&2; exit 1; }
is_choice=$(printf '%s' "${newest}" | jq -r 'if .body | has("accept") then "no" else "yes" end')
seq=$(printf '%s' "${newest}" | jq -r '.seq')
said=$(printf '%s' "${newest}" | jq -r '.body.answer')
if [ -n "${choice}" ]; then
	[ "${is_choice}" = yes ] || refuse "the answer for ${record} is a yes gate's; read it with --choice"
	printf 'ANSWER_SEQ: %s\nANSWER: %s\n' "${seq}" "${said}"
	exit 0
fi
[ "${is_choice}" = no ] || refuse "the answer for ${record} is a choice; read it with --choice"
accepted=$(printf '%s' "${newest}" | jq -r '.body.accepted')
if [ "${accepted}" = true ]; then
	printf 'ACCEPTED: %s\n' "${seq}"
else
	printf 'gate-answer.sh: the newest answer (event %s) did not accept: %s\n' "${seq}" "${said}" >&2
	exit 1
fi
