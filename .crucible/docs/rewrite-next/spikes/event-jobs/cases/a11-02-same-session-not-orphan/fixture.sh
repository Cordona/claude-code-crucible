#!/bin/sh
set -eu
g0=$("$EV" --session S1 --type gate.answered --body '{"step":"build","answer":"yes, build it"}')
bj=$("$EV" --session S1 --type job.dispatched --body '{"kind":"build","target":null,"tree":"repo","report":"reports/2.json","agent_type":"lab-builder","delivery":"cold","hot_agent":null,"slot":null,"replaces":null,"approval":'"$g0"',"payload":{"task":"write the scripts"},"act":{}}')
bja=$("$EV" --session S1 --type job.assigned --job "$bj" --agent ab1 --body '{"name":"build-ab1","tool_use_id":"tu-b1"}')
bs=$("$EV" --session S1 --type build.submitted --root self --job "$bj" --agent ab1 --body '{"commit":"c1","files":["a.sh","b.sh"],"report":"reports/'"$bj"'.json","answers":{},"declines":{}}')
gr=$("$EV" --session S1 --type gate.answered --root "$bs" --body '{"step":"review","answer":"yes, review it"}')
r1=$("$EV" --session S2 --type round.made --root "$bs" --body '{"kind":"code","targets":['"$bs"'],"base":"c0","head":"c1","slots":[{"slot":1,"kind":"shell","agent_type":"lab-reviewer","cover":["a.sh"]}],"loop":null}')
v1=$("$EV" --session S2 --type job.dispatched --root "$bs" --round "$r1" --body '{"kind":"review","target":'"$r1"',"tree":"repo","report":"reports/7.json","agent_type":"lab-reviewer","delivery":"cold","hot_agent":null,"slot":1,"replaces":null,"approval":'"$gr"',"payload":{"cover":["a.sh"],"diff":"c0..c1","earlier":[],"skipped":[]},"act":{}}')
v1a=$("$EV" --session S2 --type job.assigned --root "$bs" --round "$r1" --job "$v1" --agent ar1 --body '{"name":"review-shell-ar1","tool_use_id":"tu-v1"}')
