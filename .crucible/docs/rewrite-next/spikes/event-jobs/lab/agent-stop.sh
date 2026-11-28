#!/bin/sh
# Spike hook, SubagentStop. A lab agent stops only with a valid report: then
# a tree job is committed and its *.submitted is written. A missing or bad
# report is refused twice; the second refusal writes job.ended gave-up.
set -eu
LAB=$(cd "$(dirname "$0")" && pwd); . "$LAB/lib.sh"
in=$(cat); log_hook agent-stop "$in"
aid=$(printf '%s' "$in" | jq -r '.agent_id // ""'); atype=$(printf '%s' "$in" | jq -r '.agent_type // ""')
case "$atype" in lab-*) ;; *) exit 0 ;; esac
sess=$(printf '%s' "$in" | jq -r .session_id)
job=$(wait_job_of_agent "$aid")
[ -n "$job" ] || exit 0
je=$(job_event "$job"); kind=$(printf '%s' "$je" | jq -r .body.kind)
root=$(printf '%s' "$je" | jq -r '.root // "null"'); round=$(printf '%s' "$je" | jq -r '.round // "null"')
tree=$(printf '%s' "$je" | jq -r '.body.tree // ""')
report=$(printf '%s' "$je" | jq -r '.body.report')
mkdir -p "$EFFORT/stops"; count_file="$EFFORT/stops/$job"

refuse() {
	n=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$count_file"
	if [ "$n" -ge 2 ]; then
		"$EV" --session "$sess" --by agent-stop.sh --type job.ended --root "$root" --round "$round" --job "$job" --agent "$aid" --body '{"reason":"gave-up"}' >/dev/null
		exit 0
	fi
	jq -nc --arg r "$1" '{decision:"block", reason:$r}'; exit 0
}

[ -f "$report" ] && jq -e 'type == "object"' "$report" >/dev/null 2>&1 || refuse "write your report as JSON to $report before you stop"
ids_needed() { printf '%s' "$je" | jq -c "$1"; }
covers() { # jq path in report, needed ids JSON
	jq -e --argjson need "$2" "($1 // {}) as \$a | all(\$need[]; \$a[.] != null)" "$report" >/dev/null
}
case "$kind" in
fix) covers .answers "$(ids_needed '[.body.payload.findings[].id]')" || refuse "answer every finding id: done or declined" ;;
review) covers .answers "$(ids_needed '[.body.payload.earlier[].id]')" || refuse "answer every earlier id: fixed, open, withdrawn or insisted"
	jq -e '.findings | type == "array"' "$report" >/dev/null 2>&1 || refuse "findings must be a list" ;;
arbiter) covers .rulings "$(ids_needed '[.body.payload.keys[].id]')" || refuse "rule every key: fix or drop" ;;
external-review) covers .threads "$(ids_needed '[.body.payload.threads[]]')" || refuse "judge every thread: valid or rejected" ;;
challenge) jq -e '.challenges | type == "array"' "$report" >/dev/null 2>&1 || refuse "challenges must be a list" ;;
esac

# a reviewing job reads a pinned head: refuse when the tree moved
if [ "$round" != null ] && [ -n "$tree" ]; then
	head=$(job_event "$round" | jq -r '.body.head // ""')
	now=$(git -C "$tree" rev-parse HEAD 2>/dev/null || echo none)
	case "$kind" in review|arbiter|external-review) [ "$head" = "$now" ] || refuse "the tree moved off the round's head $head" ;; esac
fi

commit=null
case "$kind" in build|fix|test)
	if ! git -C "$tree" log --format=%s | grep -qx "job $job"; then
		git -C "$tree" add -A
		if git -C "$tree" diff --cached --quiet; then
			[ "$kind" = fix ] || refuse "a $kind job must change the tree"
		else
			git -C "$tree" -c user.name=lab -c user.email=lab@lab commit -qm "job $job"
		fi
	fi
	c=$(git -C "$tree" log --format='%H %s' | grep " job $job\$" | cut -d' ' -f1 | head -1)
	[ -n "$c" ] && commit="\"$c\"" && files=$(git -C "$tree" show --name-only --format= "$c" | jq -Rsc 'split("\n") | map(select(length > 0))') ;;
esac
files=${files:-[]}

# challenge keys are given here, numbered across the effort
if [ "$kind" = challenge ]; then
	n=$(all_events | jq '[.[] | select(.type == "review.submitted") | .body.challenges[]?] | length')
	jq --argjson n "$n" '.challenges |= (to_entries | map(.value + {key: ("C-" + ((.key + $n + 1) | tostring))}))' "$report" > "$report.tmp" && mv "$report.tmp" "$report"
fi

case "$kind" in
build|fix) type=build.submitted ;; test) type=test.submitted ;; test-plan) type=plan.submitted ;; *) type=review.submitted ;;
esac
body=$(jq -c --argjson commit "$commit" --argjson files "$files" --arg report "$report" --arg kind "$kind" '
	if $kind == "test-plan" then {draft: $report, answers: (.answers // {})}
	elif ($kind | test("^(build|fix|test)$")) then {commit: $commit, files: $files, report: $report, answers: (.answers // {}), declines: (.declines // {})}
	else {report: $report, findings: (.findings // []), answers: (.answers // {}), rulings: (.rulings // {}),
	      challenges: (.challenges // []), threads: (.threads // {})} end' "$report")
[ "$root" = null ] && rootarg=self || rootarg=$root
# the events lock may be held: wait for it, so one commit gets one event
EV_LOCK_TRIES=600 "$EV" --session "$sess" --by agent-stop.sh --type "$type" --root "$rootarg" --round "$round" --job "$job" --agent "$aid" --body "$body" >/dev/null
exit 0
