#!/bin/sh
set -eu
pr=$("$EV" --session S1 --type pr.review-requested --root self --body '{"pr":"pr-9","base":"f0","head":"f1","tree":"foreign"}')
gr=$("$EV" --session S1 --type gate.answered --root "$pr" --body '{"step":"review","answer":"yes, review their change"}')
r1=$("$EV" --session S1 --type round.made --root "$pr" --body '{"kind":"code","targets":['"$pr"'],"base":"f0","head":"f1","slots":[{"slot":1,"kind":"shell","agent_type":"lab-reviewer","cover":["x.sh"]}],"loop":null}')
v1=$("$EV" --session S1 --type job.dispatched --root "$pr" --round "$r1" --body '{"kind":"review","target":'"$r1"',"tree":"foreign","report":"reports/4.json","agent_type":"lab-reviewer","delivery":"cold","hot_agent":null,"slot":1,"replaces":null,"approval":'"$gr"',"payload":{"cover":["x.sh"],"diff":"f0..f1","earlier":[],"skipped":[]},"act":{}}')
"$EV" --session S1 --type job.assigned --root "$pr" --round "$r1" --job "$v1" --agent ar1 --body '{"name":"review-shell-ar1","tool_use_id":"tu-v1"}' >/dev/null
"$EV" --session S1 --type review.submitted --root "$pr" --round "$r1" --job "$v1" --agent ar1 --body '{"report":"reports/'"$v1"'.json","findings":[{"kind":"shell","file":"x.sh","severity":"high","realism":"realistic","title":"eval of user input"}]}' >/dev/null
m1=$("$EV" --session S1 --type review.merged --root "$pr" --round "$r1" --body '{"findings":[{"id":"SHELL-01","kind":"shell","file":"x.sh","severity":"high","realism":"realistic","status":"open"}],"verdict":"changes","targets":["SHELL-01"],"gaps":[]}')
"$EV" --session S1 --type pr.posted --root "$pr" --body '{"items":[{"id":"SHELL-01","kind":"comment"}]}' >/dev/null
hm=$("$EV" --session S1 --type pr.head-moved --root "$pr" --body '{"pr":"pr-9","old_head":"f1","head":"f2","replies":{"SHELL-01":"quoted it and dropped the eval"}}')
g2=$("$EV" --session S1 --type gate.answered --root "$pr" --body '{"step":"review","answer":"yes, look at their new push"}')
r2=$("$EV" --session S1 --type round.made --root "$pr" --body '{"kind":"code","targets":['"$hm"'],"base":"f1","head":"f2","slots":[{"slot":1,"kind":"shell","agent_type":"lab-reviewer","cover":["x.sh"]}],"loop":null}')
v2=$("$EV" --session S1 --type job.dispatched --root "$pr" --round "$r2" --body '{"kind":"review","target":'"$r2"',"tree":"foreign","report":"reports/12.json","agent_type":"lab-reviewer","delivery":"hot","hot_agent":"ar1","slot":1,"replaces":null,"approval":'"$g2"',"payload":{"cover":["x.sh"],"diff":"f1..f2","earlier":[{"id":"SHELL-01","status":"open","title":"eval of user input","answer":"done","decline":null}],"skipped":[]},"act":{}}')
"$EV" --session S1 --type job.assigned --root "$pr" --round "$r2" --job "$v2" --agent ar1 --body '{"name":"review-shell-ar1","tool_use_id":"tu-v2"}' >/dev/null
"$EV" --session S1 --type review.submitted --root "$pr" --round "$r2" --job "$v2" --agent ar1 --body '{"report":"reports/'"$v2"'.json","findings":[],"answers":{"SHELL-01":"fixed"}}' >/dev/null
m2=$("$EV" --session S1 --type review.merged --root "$pr" --round "$r2" --body '{"findings":[{"id":"SHELL-01","kind":"shell","file":"x.sh","severity":"high","realism":"realistic","status":"fixed"}],"verdict":"pass","targets":[],"gaps":[]}')
