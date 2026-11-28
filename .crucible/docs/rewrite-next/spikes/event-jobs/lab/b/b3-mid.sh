#!/bin/sh
# Stage B3, run by main between the build and the hot fix: a review round with
# one faked reviewer submission, the merge, the choice, then the hot fix dispatch.
# Prints the SendMessage call main must make.
set -eu
LAB=$(cd "$(dirname "$0")/.." && pwd); S=B3
build=$(sh "$LAB/view.sh" --effort "$EFFORT" | jq -r '[.[] | select(.type=="build.submitted")] | last | .seq')
builder=$(sh "$LAB/view.sh" --effort "$EFFORT" | jq -r '[.[] | select(.type=="build.submitted")] | last | .agent')
sh "$LAB/gate.sh" --effort "$EFFORT" --step review --answer "yes, review it" --about "$build" --session $S >/dev/null
sh "$LAB/round.sh" --effort "$EFFORT" --kind code --targets "$build" --kinds shell --session $S >/dev/null
v() { sh "$LAB/view.sh" --effort "$EFFORT"; }
round=$(v | jq -r '[.[] | select(.type=="round.made")] | last | .seq')
rjob=$(v | jq -r --argjson r "$round" '[.[] | select(.type=="job.dispatched" and .round==$r)] | last | .seq')
root=$(v | jq -r --argjson r "$round" '.[] | select(.seq==$r) | .root')
"$LAB/ev.sh" --session $S --by b3-mid.sh --type job.assigned --root "$root" --round "$round" --job "$rjob" --agent fake-reviewer --body '{"name":"review-reviewer-fake","tool_use_id":"none"}' >/dev/null
"$LAB/ev.sh" --session $S --by b3-mid.sh --type review.submitted --root "$root" --round "$round" --job "$rjob" --agent fake-reviewer \
  --body '{"report":"none","findings":[{"kind":"shell","file":"b.txt","severity":"high","realism":"realistic","title":"b.txt says built, should say fixed"}],"answers":{},"rulings":{},"challenges":[],"threads":{}}' >/dev/null
sh "$LAB/merge.sh" --effort "$EFFORT" --round "$round" --session $S >/dev/null
merge=$(v | jq -r '[.[] | select(.type=="review.merged")] | last | .seq')
sh "$LAB/choose.sh" --effort "$EFFORT" --merge "$merge" --severity high --cap 1 --session $S >/dev/null
id=$(v | jq -r '[.[] | select(.type=="fix.chosen")] | last | .body.ids[0]')
printf '{"files":{"b.txt":"fixed\\n"},"report":{"answers":{"%s":"done"}}}' "$id" > "$EFFORT/acts/fix-1.json"
sh "$LAB/job-dispatch.sh" --effort "$EFFORT" --merge "$merge" --side production --delivery hot --hot-agent "$builder" --session $S
