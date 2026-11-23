#!/usr/bin/env sh
# Records one change to an open flow, with its reason.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh flow-change.sh --flow NAME --file FILE --reason TEXT

Records one change to an agreed flow as a flow.changed event. Use it when the
human changes the plan of a flow.

Options:
  --flow NAME     the flow's name, as flow-agree.sh printed it
  --file FILE     a file holding one non-empty JSON array of ops, in order:
    {"add": {"id": N, "step": "<component>/<name>"}, "before"?: ID}
                                adds a declared step (flow-candidates.sh);
                                N is an id this flow never used; last
                                when there is no before
    {"skip": ID}                skips an open step
    {"move": ID, "before": ID}  moves a step in front of another
    {"reopen": ID}              opens a done or skipped step again; only
                                evidence newer than the reopen marks it done
  --reason TEXT   why, one line
Requires:  the effort is open and the flow has not ended
Writes:    one flow.changed event {flow, reason, ops}
Stdout:    the event's absolute path
Exit:
  0  changed
  2  refused, nothing written; the reasons on stderr
  6  the events lock stayed held: rerun
USAGE
}

fl_prog='flow-change.sh'
. "$(dirname -- "$0")/../lib/flow.sh"
. "$(dirname -- "$0")/../lib/catalogue.sh"
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
problems=$(jq -r -L "${fl_lib}" 'include "flow-replay";
	to_entries[] | select(.value | type == "object" and has("add")) | .value.add | proposed_problems("add")' "${file}")
[ -z "${problems}" ] || fl_refuse "$(printf '%s' "${problems}" | paste -sd '|' - | sed 's/|/; /g')"
fl_require_open
if jq -e 'any(.[]; type == "object" and has("add"))' "${file}" >/dev/null; then
	cat=$(ct_catalogue) || exit 2
	resolved=$(jq -c '[.[] | select(type == "object" and has("add")) | .add]' "${file}" | ct_resolve "${cat}")
	problems=$(printf '%s' "${resolved}" | jq -r '.problems[]')
	[ -z "${problems}" ] || fl_refuse "$(printf '%s' "${problems}" | paste -sd '|' - | sed 's/|/; /g')"
else
	resolved='{"steps": []}'
fi
body=$(mktemp)
trap 'rm -f -- "${body}"' EXIT
jq --argjson flow "${fl_seq}" --arg reason "${reason}" --argjson resolved "${resolved}" '
	($resolved.steps | map({key: (.id | tostring), value: .}) | from_entries) as $by
	| {flow: $flow, reason: $reason,
	   ops: map(if type == "object" and has("add") then .add = $by[.add.id | tostring] else . end)}' "${file}" >"${body}"
fl_write flow.changed "${body}"
