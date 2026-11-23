#!/usr/bin/env sh
# Records a flow the human and main agreed.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh flow-agree.sh --effort FOLDER --file FLOW

Records a flow accepted on flow-card.sh's card, before its steps start.

Options:
  --effort FOLDER  the effort's folder, absolute; the effort must be open
  --file FLOW      a file holding {"goal": "<one line>", "steps": [{"id": N,
                   "step": "<component>/<name>"}, ...]}; ids unique whole
                   numbers from 1; each step a key flow-candidates.sh lists
Requires:  the human's yes at a recorded yes gate, record flow-agree,
           subject FLOW's sha256, FLOW unchanged since; one yes agrees one
           flow
Writes:    one flow.agreed event
Stdout:    the flow's name <effort folder>:<seq>, the other scripts' --flow
Exit:
  0  agreed and written
  2  refused, nothing written; the reason is on stderr
  6  the events lock stayed held: rerun
USAGE
}

fl_prog='flow-agree.sh'
. "$(dirname -- "$0")/../lib/flow.sh"
. "$(dirname -- "$0")/../lib/catalogue.sh"
effort='' file=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--effort | --file)
			[ $# -ge 2 ] || fl_refuse "$1 needs a value"
			case $1 in --effort) effort=$2 ;; --file) file=$2 ;; esac
			shift 2 ;;
		*) fl_refuse "unknown argument $1; try --help" ;;
	esac
done
fl_set_effort "${effort}"
[ -f "${file}" ] || fl_refuse "--file ${file} is not a file"
problems=$(jq -r -L "${fl_lib}" 'include "flow-replay"; proposal_problems' "${file}" 2>/dev/null) || fl_refuse "--file ${file} is not JSON"
[ -z "${problems}" ] || fl_refuse "$(printf '%s' "${problems}" | paste -sd '|' - | sed 's/|/; /g')"
cat=$(ct_catalogue) || exit 2
resolved=$(jq -c '.steps' "${file}" | ct_resolve "${cat}")
problems=$(printf '%s' "${resolved}" | jq -r '.problems[]')
[ -z "${problems}" ] || fl_refuse "$(printf '%s' "${problems}" | paste -sd '|' - | sed 's/|/; /g')"
fl_require_open
. "${fl_here}/../../crucible-events/scripts/lib/sha256.sh"
sha=$(sh_sha256 "${file}")
gate_answer="${fl_here}/../../crucible-gate/scripts/internal/gate-answer.sh"
answer=$(sh "${gate_answer}" --effort "${fl_effort}" --record flow-agree --subject "${sha}") || {
	[ $? -ne 1 ] || fl_refuse "the human has not accepted this flow file (sha256 ${sha}); ask them first"
	exit 2
}
answer=${answer#ACCEPTED: }
body=$(mktemp)
trap 'rm -f -- "${body}"' EXIT
printf '%s' "${resolved}" | jq --argjson answer "${answer}" --arg goal "$(jq -r '.goal' "${file}")" \
	'{goal: $goal, steps: .steps, answer: $answer}' >"${body}"
event=$(fl_write flow.agreed "${body}") || exit $?
seq=${event##*/}
printf '%s:%s\n' "${fl_effort}" "$(printf '%s' "${seq%%-*}" | sed 's/^0*//')"
