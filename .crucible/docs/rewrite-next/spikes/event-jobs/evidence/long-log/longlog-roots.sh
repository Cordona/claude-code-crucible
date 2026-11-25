#!/bin/sh
# Long log, realistic shape: five roots of about 400 events each (a build,
# then gated review rounds, each merged and answered "fix nothing"); four of
# the roots closed. Times owes.sh and one write at the end.
# usage: longlog-roots.sh EFFORT_DIR
set -eu
LAB=$(cd "$(dirname "$0")/../../lab" && pwd)
EFFORT=$1; mkdir -p "$EFFORT/events"; export EFFORT
unset CLAUDE_CODE_SESSION_ID
e() { "$LAB/ev.sh" --session S1 --by long "$@"; }
start=$(date +%s)
for r in 1 2 3 4 5; do
	g=$(e --type gate.answered --body '{"step":"build","answer":"yes"}')
	j=$(e --type job.dispatched --body "{\"kind\":\"build\",\"target\":null,\"tree\":\"/t/$r\",\"report\":\"/r/$r\",\"agent_type\":\"lab-builder\",\"delivery\":\"cold\",\"hot_agent\":null,\"slot\":null,\"replaces\":null,\"approval\":$g,\"payload\":{\"task\":\"t\"},\"act\":{}}")
	e --type job.assigned --job "$j" --agent "b$r" --body '{"name":"n","tool_use_id":"u"}' >/dev/null
	b=$(e --type build.submitted --root self --job "$j" --agent "b$r" --body '{"commit":"c","files":["f"],"report":"/r","answers":{},"declines":{}}')
	i=0
	while [ "$i" -lt 56 ]; do
		i=$((i + 1))
		g=$(e --type gate.answered --root "$b" --body '{"step":"review","answer":"yes"}')
		rd=$(e --type round.made --root "$b" --body "{\"kind\":\"code\",\"targets\":[$b],\"base\":\"c0\",\"head\":\"c\",\"slots\":[{\"slot\":1,\"kind\":\"shell\",\"agent_type\":\"lab-reviewer\",\"cover\":[\"f\"]}],\"loop\":null}")
		v=$(e --type job.dispatched --root "$b" --round "$rd" --body "{\"kind\":\"review\",\"target\":$rd,\"tree\":\"/t/$r\",\"report\":\"/r/v\",\"agent_type\":\"lab-reviewer\",\"delivery\":\"cold\",\"hot_agent\":null,\"slot\":1,\"replaces\":null,\"approval\":$g,\"payload\":{\"cover\":[\"f\"],\"diff\":\"c0..c\",\"earlier\":[],\"skipped\":[]},\"act\":{}}")
		e --type job.assigned --root "$b" --round "$rd" --job "$v" --agent "v$r-$i" --body '{"name":"n","tool_use_id":"u"}' >/dev/null
		e --type review.submitted --root "$b" --round "$rd" --job "$v" --agent "v$r-$i" --body '{"report":"/r/v","findings":[]}' >/dev/null
		m=$(e --type review.merged --root "$b" --round "$rd" --body '{"findings":[],"verdict":"pass","targets":[],"gaps":[]}')
		e --type fix.none --root "$b" --body "{\"merge\":$m}" >/dev/null
	done
	[ "$r" -eq 5 ] || e --type root.closed --root "$b" --body '{"reason":"done"}' >/dev/null
	echo "root $r: $(ls "$EFFORT/events" | grep -c json) events at $(($(date +%s) - start)) s"
done
t0=$(date +%s); e --type gate.answered --body '{"step":"build","answer":"yes"}' >/dev/null; t1=$(date +%s)
echo "one write at $(ls "$EFFORT/events" | grep -c json) events: $((t1 - t0)) s"
t0=$(date +%s); n=$(sh "$LAB/owes.sh" --effort "$EFFORT" | wc -l | tr -d ' '); t1=$(date +%s)
echo "owes.sh: $((t1 - t0)) s, $n root(s) printed"
