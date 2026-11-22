#!/usr/bin/env sh
# Records a flow the human and main agreed.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh flow-agree.sh --effort FOLDER --file FLOW
       sh flow-agree.sh --help | -h

Writes FLOW as a flow.agreed event, once its shape is checked and the human
accepted it. The gate must have recorded the decision as flow-agree, with
FLOW's sha256 as its subject, and the human's newest answer to it must be the
option named as yes; one yes agrees one flow. The flow:
  {"goal": "<one line>", "done_when": DONE_WHEN, "steps": [NODE, ...]}
  NODE: {"id": N, "do": "<one line>", "uses"?: "<one line>", "done_when": DONE_WHEN}
  DONE_WHEN: {"event": "<type>", "match"?: {<body field>: <value>}}
    or {"criteria": "<one line, true or false>", "by"?: "human"}

  --effort FOLDER   the effort's folder, absolute; the effort must be open
  --file FLOW       the flow as one JSON object

stdout: the flow's name, <effort folder>:<seq>, for the other flow scripts
Exit: 0 agreed; 2 refused, nothing written, the reasons on stderr;
  6 the events lock stayed held: rerun
USAGE
}

fl_prog='flow-agree.sh'
. "$(dirname -- "$0")/lib/flow.sh"
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
problems=$(jq -r -L "${fl_lib}" 'include "flow-replay"; flow_problems' "${file}" 2>/dev/null) || fl_refuse "--file ${file} is not JSON"
[ -z "${problems}" ] || fl_refuse "$(printf '%s' "${problems}" | paste -sd '|' - | sed 's/|/; /g')"
fl_require_open
. "${fl_here}/../../crucible-events/scripts/lib/sha256.sh"
sha=$(sh_sha256 "${file}")
gate_answer="${fl_here}/../../crucible-gate/scripts/gate-answer.sh"
answer=$(sh "${gate_answer}" --effort "${fl_effort}" --record flow-agree --subject "${sha}") \
	|| fl_refuse "the human has not accepted this flow file (sha256 ${sha}); ask them first"
answer=${answer#ACCEPTED: }
body=$(mktemp)
trap 'rm -f -- "${body}"' EXIT
jq --argjson answer "${answer}" '. + {answer: $answer}' "${file}" >"${body}" 2>/dev/null || fl_refuse "--file ${file} is not JSON"
event=$(fl_write flow.agreed "${body}") || exit $?
seq=${event##*/}
printf '%s:%s\n' "${fl_effort}" "$(printf '%s' "${seq%%-*}" | sed 's/^0*//')"
