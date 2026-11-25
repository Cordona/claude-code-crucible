#!/bin/sh
# Stage B5 steps, run by main; each prints the one tool call main must make.
#   gaveup  : a build job whose agent writes no report
#   broken  : a build job whose agent writes a broken report first
#   review  : a review round on the last build, whose reviewer also tries to write outside its report
set -eu
LAB=$(cd "$(dirname "$0")/.." && pwd); S=B5; mkdir -p "$EFFORT/acts"
v() { sh "$LAB/view.sh" --effort "$EFFORT"; }
case "$1" in
gaveup) printf '%s' '{"report":null}' > "$EFFORT/acts/build-1.json"
	sh "$LAB/gate.sh" --effort "$EFFORT" --step build --answer "yes, build it" --session $S >/dev/null
	sh "$LAB/job-dispatch.sh" --effort "$EFFORT" --kind build --tree "$TREE" --task "add b.txt" --session $S ;;
broken) printf '%s' '{"broken_first":true,"files":{"b.txt":"built\n"},"report":{"summary":"ok"}}' > "$EFFORT/acts/build-2.json"
	sh "$LAB/gate.sh" --effort "$EFFORT" --step build --answer "yes, try again" --session $S >/dev/null
	sh "$LAB/job-dispatch.sh" --effort "$EFFORT" --kind build --tree "$TREE" --task "add b.txt" --session $S ;;
review) build=$(v | jq -r '[.[] | select(.type=="build.submitted")] | last | .seq')
	printf '%s' '{"files":{"x.txt":"not mine\n"},"report":{"findings":[],"answers":{}}}' > "$EFFORT/acts/review-1.json"
	sh "$LAB/gate.sh" --effort "$EFFORT" --step review --answer "yes, review it" --about "$build" --session $S >/dev/null
	sh "$LAB/round.sh" --effort "$EFFORT" --kind code --targets "$build" --kinds shell --session $S ;;
esac
