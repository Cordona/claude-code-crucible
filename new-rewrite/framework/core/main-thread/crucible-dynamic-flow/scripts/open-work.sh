#!/usr/bin/env sh
# Prints the effort's open flows, one line each: the open-work contract.
# shellcheck source-path=SCRIPTDIR
set -eu

usage() {
	cat <<'USAGE'
usage: sh open-work.sh --effort FOLDER
       sh open-work.sh --help | -h

Prints one line per open flow (agreed, not ended), oldest first:
  flow <seq> "<goal>"
and nothing when none is open. Reads only.

  --effort FOLDER   the effort's folder, absolute

Exit: 0 printed; 2 refused, the reason on stderr
USAGE
}

fl_prog='open-work.sh'
. "$(dirname -- "$0")/lib/flow.sh"
effort=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--effort) [ $# -ge 2 ] || fl_refuse '--effort needs a value'; effort=$2; shift 2 ;;
		*) fl_refuse "unknown argument $1; try --help" ;;
	esac
done
fl_set_effort "${effort}"
fl_events | jq -r -L "${fl_lib}" 'include "flow-replay";
	. as $all | open_flows[] as $s
	| ($all[] | select(.seq == $s and .type == "flow.agreed") | .body.goal) as $goal
	| "flow \($s) \"\($goal)\""'
