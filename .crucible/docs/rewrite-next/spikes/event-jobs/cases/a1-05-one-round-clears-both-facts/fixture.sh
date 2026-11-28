#!/bin/sh
set -eu
g0=$("$EV" --session S1 --type gate.answered --body '{"step":"build","answer":"yes, build it"}')
bj=$("$EV" --session S1 --type job.dispatched --body '{"kind":"build","target":null,"tree":"repo","report":"reports/2.json","agent_type":"lab-builder","delivery":"cold","hot_agent":null,"slot":null,"replaces":null,"approval":'"$g0"',"payload":{"task":"write the scripts"},"act":{}}')
bja=$("$EV" --session S1 --type job.assigned --job "$bj" --agent ab1 --body '{"name":"build-ab1","tool_use_id":"tu-b1"}')
bs=$("$EV" --session S1 --type build.submitted --root self --job "$bj" --agent ab1 --body '{"commit":"c1","files":["a.sh","b.sh"],"report":"reports/'"$bj"'.json","answers":{},"declines":{}}')
g2=$("$EV" --session S1 --type gate.answered --root "$bs" --body '{"step":"build","answer":"now add the help text"}')
bj2=$("$EV" --session S1 --type job.dispatched --root "$bs" --body '{"kind":"build","target":null,"tree":"repo","report":"reports/6.json","agent_type":"lab-builder","delivery":"hot","hot_agent":"ab1","slot":null,"replaces":null,"approval":'"$g2"',"payload":{"task":"add the help text"},"act":{}}')
"$EV" --session S1 --type job.assigned --root "$bs" --job "$bj2" --agent ab1 --body '{"name":"build-ab1","tool_use_id":"tu-b2"}' >/dev/null
bs2=$("$EV" --session S1 --type build.submitted --root "$bs" --job "$bj2" --agent ab1 --body '{"commit":"c2","files":["b.sh"],"report":"reports/'"$bj2"'.json","answers":{},"declines":{}}')
gr=$("$EV" --session S1 --type gate.answered --root "$bs" --body '{"step":"review","answer":"yes, review it"}')
r1=$("$EV" --session S1 --type round.made --root "$bs" --body '{"kind":"code","targets":['"$bs"','"$bs2"'],"base":"c0","head":"c2","slots":[{"slot":1,"kind":"shell","agent_type":"lab-reviewer","cover":["a.sh","b.sh"]}],"loop":null}')
v1=$("$EV" --session S1 --type job.dispatched --root "$bs" --round "$r1" --body '{"kind":"review","target":'"$r1"',"tree":"repo","report":"reports/11.json","agent_type":"lab-reviewer","delivery":"cold","hot_agent":null,"slot":1,"replaces":null,"approval":'"$gr"',"payload":{"cover":["a.sh","b.sh"],"diff":"c0..c2","earlier":[],"skipped":[]},"act":{}}')
v1a=$("$EV" --session S1 --type job.assigned --root "$bs" --round "$r1" --job "$v1" --agent ar1 --body '{"name":"review-shell-ar1","tool_use_id":"tu-v1"}')
