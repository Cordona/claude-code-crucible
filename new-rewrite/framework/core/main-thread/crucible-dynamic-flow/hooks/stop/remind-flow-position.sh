#!/usr/bin/env sh
# Claude Code Stop hook: tells main where it stands in its open flows, but
# only on a certain signal, once per signal; otherwise it stays silent.
set -eu
umask 077
# A hook fault lets the stop through.
trap 'exit 0' EXIT

usage() {
	cat <<'USAGE'
usage: sh remind-flow-position.sh < stop-hook-input.json
       sh remind-flow-position.sh --help | -h

A Claude Code Stop hook. For each open flow in an open effort that this
session wrote an event to, it speaks one line when a signal is new since it
last spoke for that flow in this session:
  an open step's evidence is waiting unmarked;
  the position moved (the next step, or how many are done);
  every step is done or skipped and the flow is still open.
A new session speaks each open flow once. Its memory of the last position
spoken is the only loop guard: it speaks a position once, so a second stop
in the same turn stays silent. It speaks also when another hook already
continued the turn (stop_hook_active), as after every gate. A subagent's
stop passes.

stdin: the Stop hook JSON; reads session_id, agent_id
Environment: CRUCIBLE_HOME (default $HOME/.crucible), CLAUDE_CONFIG_DIR
Writes: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/cache/crucible-dynamic-flow/<session>/
  one file per flow: the last position spoken
stdout, only when it speaks:
  {"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":"<lines>"}}
Exit: always 0
USAGE
}

case ${1-} in -h | --help) usage; exit 0 ;; esac
command -v jq >/dev/null 2>&1 || exit 0
here=$(cd -- "$(dirname -- "$0")" && pwd)
lib="${here}/../../scripts/lib"
effort_state="${here}/../../../crucible-effort/scripts/effort-state.sh"
reader="${here}/../../../crucible-events/scripts/events-read.sh"
input=$(cat)
[ -z "$(printf '%s' "${input}" | jq -r '.agent_id // empty')" ] || exit 0
session=$(printf '%s' "${input}" | jq -r '.session_id // empty')
case ${session} in '' | *[!A-Za-z0-9._-]*) exit 0 ;; esac
memory="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/cache/crucible-dynamic-flow/${session}"
efforts="${CRUCIBLE_HOME:-${HOME}/.crucible}/efforts"
[ -d "${efforts}" ] || exit 0

lines=''
for effort in "${efforts}"/*; do
	[ -d "${effort}/events" ] || continue
	# A cheap first pass on the bare id, whatever the spacing; then the real
	# test on the claude_session_id field.
	grep -rlqF -- "${session}" "${effort}/events" 2>/dev/null || continue
	all=$(sh "${reader}" --effort "${effort}" 2>/dev/null) || continue
	printf '%s' "${all}" | jq -e --arg s "${session}" 'any(.[]; .claude_session_id == $s)' >/dev/null || continue
	[ "$(sh "${effort_state}" --effort "${effort}" 2>/dev/null)" = open ] || continue
	positions=$(printf '%s' "${all}" \
		| jq -c -L "${lib}" --arg effort "${effort}" 'include "flow-replay";
			. as $all
			| [open_flows[] as $seq | ($all | flow_state($seq)) as $f | {seq: $seq, f: $f, w: ($all | waiting($f))}] as $flows
			| ([$flows[].w[].events[]] | group_by(.) | map(select(length > 1) | .[0])) as $shared
			| $flows[] | .seq as $seq | .f as $f | .w as $w
			| [$f.steps[] | select(.status == "open")] as $open
			| ([$f.steps[] | select(.status != "open")] | length) as $done
			| {seq: $seq,
			   key: "\($open[0].id // "end"):\($done):\($w | map(.id) | tostring)",
			   line: ("Flow \($effort):\($seq) \"\($f.goal)\": "
				+ (if ($open | length) == 0 then "every step is done or skipped; end it when its goal is met."
				   elif ($w | length) > 0 then "step \($w[0].id) has its evidence waiting (event \($w[0].events | map(tostring) | join(", "))): mark it."
					+ (if ($w[0].events | any(. as $e | $shared | index([$e]))) then " That event also fits another open step, and can prove only one of them." else "" end)
				   else "step \($open[0].id) \"\($open[0].do)\" is next (\($done) of \($f.steps | length) done). Go on, mark it, or wait for what is running." end))}')
	[ -n "${positions}" ] || continue
	mkdir -p -- "${memory}"
	while IFS= read -r position; do
		seq=$(printf '%s' "${position}" | jq -r '.seq')
		key=$(printf '%s' "${position}" | jq -r '.key')
		file="${memory}/${effort##*/}-${seq}"
		[ "$(cat -- "${file}" 2>/dev/null || true)" != "${key}" ] || continue
		printf '%s\n' "${key}" >"${file}"
		lines="${lines}$(printf '%s' "${position}" | jq -r '.line')
"
	done <<EOF2
${positions}
EOF2
done
[ -n "${lines}" ] || exit 0
printf '%s' "${lines}" | jq -Rsc '{hookSpecificOutput: {hookEventName: "Stop", additionalContext: (. | rtrimstr("\n"))}}'
