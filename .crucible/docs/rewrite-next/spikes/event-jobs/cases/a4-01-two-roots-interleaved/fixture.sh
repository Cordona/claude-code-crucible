#!/bin/sh
set -eu
ga=$("$EV" --session S1 --type gate.answered --body '{"step":"build","answer":"yes, build the cli"}')
ja=$("$EV" --session S1 --type job.dispatched --body '{"kind":"build","target":null,"tree":"repo","report":"reports/2.json","agent_type":"lab-builder","delivery":"cold","hot_agent":null,"slot":null,"replaces":null,"approval":'"$ga"',"payload":{"task":"write a.sh"},"act":{}}')
gb=$("$EV" --session S1 --type gate.answered --body '{"step":"build","answer":"and the installer, in parallel"}')
jb=$("$EV" --session S1 --type job.dispatched --body '{"kind":"build","target":null,"tree":"repo-b","report":"reports/4.json","agent_type":"lab-builder","delivery":"cold","hot_agent":null,"slot":null,"replaces":null,"approval":'"$gb"',"payload":{"task":"write b.sh"},"act":{}}')
"$EV" --session S1 --type job.assigned --job "$ja" --agent ab1 --body '{"name":"build-ab1","tool_use_id":"tu-b1"}' >/dev/null
"$EV" --session S1 --type job.assigned --job "$jb" --agent ab2 --body '{"name":"build-ab2","tool_use_id":"tu-b2"}' >/dev/null
sa=$("$EV" --session S1 --type build.submitted --root self --job "$ja" --agent ab1 --body '{"commit":"c1","files":["a.sh"],"report":"reports/'"$ja"'.json","answers":{},"declines":{}}')
sb=$("$EV" --session S1 --type build.submitted --root self --job "$jb" --agent ab2 --body '{"commit":"d1","files":["b.sh"],"report":"reports/'"$jb"'.json","answers":{},"declines":{}}')
gra=$("$EV" --session S1 --type gate.answered --root "$sa" --body '{"step":"review","answer":"yes, review it"}')
grb=$("$EV" --session S1 --type gate.answered --root "$sb" --body '{"step":"review","answer":"that one too"}')
ra=$("$EV" --session S1 --type round.made --root "$sa" --body '{"kind":"code","targets":['"$sa"'],"base":"c0","head":"c1","slots":[{"slot":1,"kind":"shell","agent_type":"lab-reviewer","cover":["a.sh"]}],"loop":null}')
rb=$("$EV" --session S1 --type round.made --root "$sb" --body '{"kind":"code","targets":['"$sb"'],"base":"d0","head":"d1","slots":[{"slot":1,"kind":"shell","agent_type":"lab-reviewer","cover":["b.sh"]}],"loop":null}')
va=$("$EV" --session S1 --type job.dispatched --root "$sa" --round "$ra" --body '{"kind":"review","target":'"$ra"',"tree":"repo","report":"reports/13.json","agent_type":"lab-reviewer","delivery":"cold","hot_agent":null,"slot":1,"replaces":null,"approval":'"$gra"',"payload":{"cover":["a.sh"],"diff":"c0..c1","earlier":[],"skipped":[]},"act":{}}')
vb=$("$EV" --session S1 --type job.dispatched --root "$sb" --round "$rb" --body '{"kind":"review","target":'"$rb"',"tree":"repo-b","report":"reports/14.json","agent_type":"lab-reviewer","delivery":"cold","hot_agent":null,"slot":1,"replaces":null,"approval":'"$grb"',"payload":{"cover":["b.sh"],"diff":"d0..d1","earlier":[],"skipped":[]},"act":{}}')
"$EV" --session S1 --type job.assigned --root "$sa" --round "$ra" --job "$va" --agent ar1 --body '{"name":"review-shell-ar1","tool_use_id":"tu-va"}' >/dev/null
vba=$("$EV" --session S1 --type job.assigned --root "$sb" --round "$rb" --job "$vb" --agent ar2 --body '{"name":"review-shell-ar2","tool_use_id":"tu-vb"}')
"$EV" --session S1 --type review.submitted --root "$sa" --round "$ra" --job "$va" --agent ar1 --body '{"report":"reports/'"$va"'.json","findings":[]}' >/dev/null
