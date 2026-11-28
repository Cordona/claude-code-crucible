#!/bin/sh
set -eu
g0=$("$EV" --session S1 --type gate.answered --body '{"step":"build","answer":"yes, build it"}')
bj=$("$EV" --session S1 --type job.dispatched --body '{"kind":"build","target":null,"tree":"repo","report":"reports/2.json","agent_type":"lab-builder","delivery":"cold","hot_agent":null,"slot":null,"replaces":null,"approval":'"$g0"',"payload":{"task":"write the scripts"},"act":{}}')
bja=$("$EV" --session S1 --type job.assigned --job "$bj" --agent ab1 --body '{"name":"build-ab1","tool_use_id":"tu-b1"}')
bs=$("$EV" --session S1 --type build.submitted --root self --job "$bj" --agent ab1 --body '{"commit":"c1","files":["a.sh","b.sh"],"report":"reports/'"$bj"'.json","answers":{},"declines":{}}')
"$EV" --session S1 --type fact.answered --root "$bs" --body '{"fact":"no-review:'"$bs"'","answer":"no"}' >/dev/null
gtp=$("$EV" --session S1 --type gate.answered --root "$bs" --body '{"step":"test-plan","answer":"yes, plan the tests"}')
tp=$("$EV" --session S1 --type job.dispatched --root "$bs" --body '{"kind":"test-plan","target":'"$bs"',"tree":"repo","report":"reports/7.json","agent_type":"lab-tester","delivery":"cold","hot_agent":null,"slot":null,"replaces":null,"approval":'"$gtp"',"payload":{"build":'"$bs"'},"act":{}}')
"$EV" --session S1 --type job.assigned --root "$bs" --job "$tp" --agent at1 --body '{"name":"test-at1","tool_use_id":"tu-t1"}' >/dev/null
p1=$("$EV" --session S1 --type plan.submitted --root "$bs" --job "$tp" --agent at1 --body '{"draft":"plans/plan-1.json","answers":{}}')
