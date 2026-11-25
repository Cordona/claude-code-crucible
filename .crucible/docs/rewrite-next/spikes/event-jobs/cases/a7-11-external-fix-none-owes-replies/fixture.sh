#!/bin/sh
set -eu
er=$("$EV" --session S1 --type external-review.received --root self --body '{"pr":"pr-1","head":"h1","threads":[{"thread":"t1","file":"a.sh","text":"quote this variable"},{"thread":"t2","file":null,"text":"add a usage line"}]}')
gr=$("$EV" --session S1 --type gate.answered --root "$er" --body '{"step":"review","answer":"yes, judge the review"}')
r1=$("$EV" --session S1 --type round.made --root "$er" --body '{"kind":"external","targets":['"$er"'],"base":null,"head":"h1","slots":[{"slot":1,"kind":"shell","agent_type":"lab-reviewer","cover":["t1","t2"]}],"loop":null}')
v1=$("$EV" --session S1 --type job.dispatched --root "$er" --round "$r1" --body '{"kind":"external-review","target":'"$r1"',"tree":"repo","report":"reports/4.json","agent_type":"lab-reviewer","delivery":"cold","hot_agent":null,"slot":1,"replaces":null,"approval":'"$gr"',"payload":{"threads":["t1","t2"]},"act":{}}')
"$EV" --session S1 --type job.assigned --root "$er" --round "$r1" --job "$v1" --agent ar1 --body '{"name":"review-shell-ar1","tool_use_id":"tu-v1"}' >/dev/null
"$EV" --session S1 --type review.submitted --root "$er" --round "$r1" --job "$v1" --agent ar1 --body '{"report":"reports/'"$v1"'.json","findings":[{"kind":"shell","file":"a.sh","severity":"medium","realism":"realistic","title":"unquoted variable","thread":"t1"},{"kind":"shell","file":"a.sh","severity":"low","realism":"realistic","title":"usage line missing","thread":"t2"}],"threads":{"t1":"rejected","t2":"rejected"}}' >/dev/null
m1=$("$EV" --session S1 --type review.merged --root "$er" --round "$r1" --body '{"findings":[{"id":"SHELL-01","kind":"shell","file":"a.sh","severity":"medium","realism":"realistic","status":"open"},{"id":"SHELL-02","kind":"shell","file":"a.sh","severity":"low","realism":"realistic","status":"open"}],"verdict":"pass","targets":[],"gaps":[]}')
"$EV" --session S1 --type fix.none --root "$er" --body '{"merge":'"$m1"'}' >/dev/null
