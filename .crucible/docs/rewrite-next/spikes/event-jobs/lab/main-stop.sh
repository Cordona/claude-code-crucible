#!/bin/sh
# Spike hook, Stop on main. Ends the jobs of closed sessions, then asks
# owes.sh what each root owes. An owed step holds the stop with one line per
# step, `owed: sh <script> <args>`; a gate step names the core gate's
# show-card.sh for its card. Waiting on an agent never holds. With nothing
# owed, each new fact is shown once, as `fact: <words>` and the line that
# offers it. A step whose script refuses is not held: a live loop on its root
# ends with reason refused.
# Like the core gate's stop hook it is bounded: a line held twice with no new
# event in between (a gate line once) lets the stop through and says so.
set -eu
LAB=$(cd "$(dirname "$0")" && pwd); . "$LAB/lib.sh"
# --next: main asks what is next (next.sh). The same lines from the same
# code, printed as text; nothing counted as held.
mode=stop
if [ "${1:-}" = --next ]; then
	mode=next; sess=${CLAUDE_CODE_SESSION_ID:-}
	[ -n "$sess" ] || { echo "next.sh: no CLAUDE_CODE_SESSION_ID" >&2; exit 1; }
else
	in=$(cat); log_hook main-stop "$in"
	[ -z "$(printf '%s' "$in" | jq -r '.agent_id // empty')" ] || exit 0
	sess=$(printf '%s' "$in" | jq -r '.session_id // empty')
fi
[ -n "$sess" ] || exit 0
mkdir -p "$EFFORT/stops"
sh "$LAB/orphans.sh" --effort "$EFFORT" --session "$sess" >/dev/null
owes=$(sh "$LAB/owes.sh" --effort "$EFFORT" --session "$sess")
last=$(all_events | jq 'last.seq // 0')
lab() { printf 'sh %s/%s --effort %s' "$LAB" "$1" "$EFFORT"; }

held='' notes=''
note() { notes="${notes}${notes:+
}$1"; }
hold() { held="${held}${held:+
}owed: $1"; }
# a line already held at this point of the log, as often as it may be
times_held() { grep -cxF "$last $1" "$EFFORT/stops/held" 2>/dev/null || true; }

# an answered gate whose follow-up has not run yet: its follow-up is owed
# (for a choice, the line that takes the human's words), and its gate line
# is not held again
all_events | jq -c 'def done_types: {build: ["job.dispatched"], test: ["job.dispatched"], "test-plan": ["job.dispatched"],
		review: ["round.made", "fact.answered"], "fix-choice": ["fix.chosen", "fix.none", "loop.stopped"],
		"end-card": ["loop.ended"], "plan-gate": ["plan.approved"], replies: ["pr.posted"], comments: ["pr.posted"]};
	. as $all | .[] | select(.type == "gate.answered") | . as $a | ($a.body.step // $a.body.record // "") as $rec | done_types[$rec] as $t
	| select($t != null and ([$all[] | select(.seq > $a.seq and (.type | IN($t[])))] | length == 0))
	| $a.body | {record: $rec, subject, answer, accepted}' > "$EFFORT/stops/answered"
answered_subjects=' '
while IFS= read -r a; do
	rec=$(printf '%s' "$a" | jq -r .record); subj=$(printf '%s' "$a" | jq -r .subject)
	f="$EFFORT/stops/follow/$rec-$(printf '%s' "$subj" | tr -c 'A-Za-z0-9-' '-').json"
	[ -f "$f" ] || continue
	answered_subjects="$answered_subjects$subj "
	case "$(printf '%s' "$a" | jq -r '.accepted')" in
	true) line=$(jq -r '.yes // empty' "$f") ;;
	false) line=$(jq -r '.no // empty' "$f") ;;
	*) t=$(jq -r '.answer // empty' "$f")
		line=${t:+"from the human's answer \"$(printf '%s' "$a" | jq -r .answer)\": $t"}
		[ -z "$line" ] || line="$line  (the choice takes those options and nothing else)" ;;
	esac
	[ -n "$line" ] || continue
	if [ "$mode" = stop ]; then
		n=$(times_held "$line"); n=${n:-0}
		if [ "$n" -ge 2 ]; then note "held ${n} times with nothing new, so not held again: $line"; continue; fi
		echo "$last $line" >> "$EFFORT/stops/held"
	fi
	hold "$line"
done < "$EFFORT/stops/answered"

printf '%s' "$owes" | jq -c 'select(.owed != null) | {root, loop: .loop.chosen, step: .owed.step, args: .owed.args}' > "$EFFORT/stops/steps"
while IFS= read -r s; do
	step=$(printf '%s' "$s" | jq -r .step)
	args=$(printf '%s' "$s" | jq -c .args)
	flags=$(printf '%s' "$args" | jq -r 'to_entries | map("--\(.key) \(.value | if type == "array" then map(tostring) | join(",") else tostring end)") | join(" ")')
	gate='' why_line=''
	case "$step" in
	choose | end-card | plan-gate | replies | comments)
		line=$(sh "$LAB/gate.sh" --effort "$EFFORT" --owed "$step" --args "$args" </dev/null); gate=1 ;;
	make-round) line="$(lab round.sh) $flags" ;;
	merge) line="$(lab merge.sh) $flags" ;;
	fix) line="$(lab job-dispatch.sh) $flags" ;;
	replace) j=$(printf '%s' "$args" | jq -r .job)
		why=$(all_events | jq -r --argjson j "$j" '([.[] | select(.type == "job.assigned" and .job == $j)] | last | .body.name // "its agent") as $n
			| [.[] | select(.type == "job.ended" and .job == $j)] | last | "\($n) ended its job: \(.body.reason)"')
		line="$(lab job-dispatch.sh) $flags"; why_line="why: $why" ;;
	plan-rework) line="$(lab job-dispatch.sh) $flags" ;;
	*) note "no script for owed step $step"; continue ;;
	esac
	if [ -z "$gate" ]; then
		check=$(eval "$line --check" 2>&1 </dev/null) || true
		if ! printf '%s' "$check" | jq -e '.ok == true' >/dev/null 2>&1; then
			loop=$(printf '%s' "$s" | jq -r '.loop // empty')
			[ -z "$loop" ] || sh "$LAB/loop-end.sh" --effort "$EFFORT" --session "$sess" --loop "$loop" --reason refused </dev/null >/dev/null 2>&1 || true
			note "the owed $step was refused ($check); ${loop:+its loop ended: refused}"
			continue
		fi
	fi
	# a gate whose card the core gate records as shown waits on the human:
	# neither owed nor dropped
	if [ -n "$gate" ]; then
		subj=$(printf '%s' "$line" | sed -n 's/.*--subject \([^ ]*\).*/\1/p')
		case "$answered_subjects" in *" $subj "*) continue ;; esac
		gdir=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/cache/crucible-gate/$sess/owed
		[ -z "$subj" ] || ! cat "$gdir"/*.json 2>/dev/null | jq -se --arg s "$subj" 'any(.[]; .status == "shown" and .record.subject == $s)' >/dev/null || continue
	fi
	if [ "$mode" = next ]; then hold "$line"; [ -z "$why_line" ] || held="$held
$why_line"; continue; fi
	n=$(times_held "$line"); n=${n:-0}
	limit=2; [ -z "$gate" ] || limit=1
	if [ "$n" -ge "$limit" ]; then
		note "held ${n} times with nothing new, so not held again: $line"
		continue
	fi
	echo "$last $line" >> "$EFFORT/stops/held"
	hold "$line"
	[ -z "$why_line" ] || held="$held
$why_line"
done < "$EFFORT/stops/steps"

# what it says is also kept, one JSON line per stop, for the run's evidence
say() { tee -a "$EFFORT/stops/main-stop.out"; }
if [ -n "$held" ]; then
	held="Owed now, decided already: run each line as given and make the calls it prints; do not ask the human.
$held"
	if [ "$mode" = next ]; then printf '%s\n' "$held"; [ -z "$notes" ] || printf 'note: %s\n' "$notes"; exit 0; fi
	jq -nc --arg r "$held" --arg n "$notes" '{decision: "block", reason: $r} + (if $n == "" then {} else {systemMessage: $n} end)' | say
	exit 0
fi

touch "$EFFORT/stops/facts-shown"
facts=''
printf '%s' "$owes" | jq -c '.facts[]' > "$EFFORT/stops/facts"
while IFS= read -r f; do
	key=$(printf '%s' "$f" | jq -r .key)
	! grep -qxF "$key" "$EFFORT/stops/facts-shown" || continue
	echo "$key" >> "$EFFORT/stops/facts-shown"
	facts="${facts}${facts:+
}fact: $(printf '%s' "$f" | jq -r .words)
offer: $(sh "$LAB/gate.sh" --effort "$EFFORT" --fact "$key" </dev/null)"
done < "$EFFORT/stops/facts"
if [ "$mode" = next ]; then
	[ -z "$facts" ] || printf '%s\n' "$facts"
	[ -z "$notes" ] || printf 'note: %s\n' "$notes"
	if [ -z "$facts$notes" ]; then
		w=$(printf '%s' "$owes" | jq -s '[.[] | .waiting // [] | .[]] | length')
		if [ "$w" -gt 0 ]; then echo "Nothing owed. $w job(s) working: end your turn; you are woken when one ends."
		else echo "Nothing owed and nothing new."; fi
	fi
	exit 0
fi
[ -n "$facts$notes" ] || exit 0
jq -nc --arg f "$facts" --arg n "$notes" '
	(if $f == "" then {} else {hookSpecificOutput: {hookEventName: "Stop", additionalContext: $f}} end)
	+ (if $n == "" then {} else {systemMessage: $n} end)' | say
