#!/bin/sh
set -eu
gr=$("$EV" --session S1 --type gate.answered --body '{"step":"review","answer":"review my last three commits"}')
ri=$("$EV" --session S1 --type range.imported --root self --body '{"base":"r0","head":"r1","tree":"repo"}')
r1=$("$EV" --session S1 --type round.made --root "$ri" --body '{"kind":"code","targets":['"$ri"'],"base":"r0","head":"r1","slots":[{"slot":1,"kind":"shell","agent_type":"lab-reviewer","cover":["a.sh"]}],"loop":null}')
v1=$("$EV" --session S1 --type job.dispatched --root "$ri" --round "$r1" --body '{"kind":"review","target":'"$r1"',"tree":"repo","report":"reports/4.json","agent_type":"lab-reviewer","delivery":"cold","hot_agent":null,"slot":1,"replaces":null,"approval":'"$gr"',"payload":{"cover":["a.sh"],"diff":"r0..r1","earlier":[],"skipped":[]},"act":{}}')
"$EV" --session S1 --type job.assigned --root "$ri" --round "$r1" --job "$v1" --agent ar1 --body '{"name":"review-shell-ar1","tool_use_id":"tu-v1"}' >/dev/null
"$EV" --session S1 --type review.submitted --root "$ri" --round "$r1" --job "$v1" --agent ar1 --body '{"report":"reports/'"$v1"'.json","findings":[{"kind":"shell","file":"a.sh","severity":"high","realism":"realistic","title":"unquoted variable"}]}' >/dev/null
m1=$("$EV" --session S1 --type review.merged --root "$ri" --round "$r1" --body '{"findings":[{"id":"SHELL-01","kind":"shell","file":"a.sh","severity":"high","realism":"realistic","status":"open"}],"verdict":"changes","targets":["SHELL-01"],"gaps":[]}')
