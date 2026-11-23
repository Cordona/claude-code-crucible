#!/usr/bin/env sh
# Prints the effort's open flows, one line each: the open-work contract.
# shellcheck source-path=SCRIPTDIR
set -eu

usage() {
	cat <<'USAGE'
usage: sh open-work.sh --effort FOLDER

Run by crucible-effort's effort-close.sh; not for main to call.
An open flow is one agreed and not yet ended.

Options:
  --effort FOLDER  the effort's folder, absolute
Writes:    nothing
Stdout:    one line per open flow, oldest first, `flow <seq> "<goal>"`;
           nothing when none is open
Exit:
  0  checked; the lines are the open flows
  2  refused, nothing changed; the reason is on stderr
USAGE
}

fl_prog='open-work.sh'
. "$(dirname -- "$0")/../lib/flow.sh"
effort=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--effort) [ $# -ge 2 ] || fl_refuse '--effort needs a value'; effort=$2; shift 2 ;;
		*) fl_refuse "unknown argument $1; try --help" ;;
	esac
done
fl_set_effort "${effort}"
fl_read_events
printf '%s\n' "${fl_all}" | jq -r -L "${fl_lib}" 'include "flow-replay";
	. as $all | open_flows[] as $s
	| ($all[] | select(.seq == $s and .type == "flow.agreed") | .body.goal) as $goal
	| "flow \($s) \"\($goal)\""'
