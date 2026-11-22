#!/usr/bin/env sh
# Records one change to an open flow, with its reason.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh flow-change.sh --flow NAME --file OPS --reason TEXT
       sh flow-change.sh --help | -h

Writes a flow.changed event. OPS is a JSON array of ops, applied in order:
  {"add": NODE, "before"?: ID}   a new step, appended when no before
  {"skip": ID}                   an open step will not be done
  {"move": ID, "before": ID}     a step moves
  {"reopen": ID}                 a done or skipped step is open again; only
                                 evidence newer than the reopen counts
  {"revise": {"step"?: ID, "done_when": DONE_WHEN}}
                                 an open step's check, or with no step the
                                 flow's own, is replaced; evidence written
                                 before the revise still counts
The agreed flow is never edited; the change is its own event.

  --flow NAME     the flow, as flow-agree.sh printed it
  --file OPS      the ops, one JSON array
  --reason TEXT   why, one line: one change, one reason

stdout: the event's path
Exit: 0 changed; 2 refused, nothing written, the reasons on stderr;
  6 the events lock stayed held: rerun
USAGE
}

fl_prog='flow-change.sh'
. "$(dirname -- "$0")/lib/flow.sh"
flow='' file='' reason=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--flow | --file | --reason)
			[ $# -ge 2 ] || fl_refuse "$1 needs a value"
			case $1 in --flow) flow=$2 ;; --file) file=$2 ;; --reason) reason=$2 ;; esac
			shift 2 ;;
		*) fl_refuse "unknown argument $1; try --help" ;;
	esac
done
fl_set_flow "${flow}"
jq -e 'type == "array"' "${file}" >/dev/null 2>&1 || fl_refuse '--file must hold one JSON array of ops'
fl_require_open
body=$(mktemp)
trap 'rm -f -- "${body}"' EXIT
jq --argjson flow "${fl_seq}" --arg reason "${reason}" '{flow: $flow, reason: $reason, ops: .}' "${file}" >"${body}"
fl_write flow.changed "${body}"
