#!/bin/sh
# Spike: judges a live Stage C run against its dry run. Fails the run on:
# - the sequence: per root, the live events differ from expected.json (in
#   order; the events of one round compared as a set; "any" is the same
#   value on both sides, as sequence.jq gives it);
# - (a) a send between a fix.chosen and its end card, other than a request
#   the dry run also made while the loop was live;
# - (b) an answer sent while no question or offer was on screen;
# - (c) a stop main-stop.sh let through with "not held again";
# - (d) a tool call of main inside a loop that is not a lab script, a gate
#   script, a printed Agent or SendMessage call, or a gate question (a
#   ToolSearch loading a named tool main then calls counts as that call);
#   reads of the project inside a loop are reported, not failed;
# - (e) main reading the events (the folder or the view) inside a loop.
# usage: compare.sh RUN RUN_FOLDER    (RUN_FOLDER as tmux-drive.sh made it)
# Writes RUN_FOLDER/compare.json; prints one pass or fail line.
set -eu
C=$(cd "$(dirname "$0")" && pwd); LAB=$(dirname "$C"); SPIKE=$(dirname "$LAB")
RUN=${1:?usage: compare.sh RUN RUN_FOLDER}; D=${2:?usage: compare.sh RUN RUN_FOLDER}
EFFORT=$D/effort
ASK_RE=${ASK_RE:-'\(Recommended\)|Type something'}
EXPECTED=$SPIKE/evidence/dry/$RUN/expected.json
[ -f "$EXPECTED" ] && [ -d "$EFFORT/events" ] || { echo "compare: missing $EXPECTED or $EFFORT/events" >&2; exit 1; }
mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1"; }

view=$(sh "$LAB/view.sh" --effort "$EFFORT")
printf '%s' "$view" | jq -L "$C" --arg run "$RUN" 'include "sequence"; sequence($run)' > "$D/live-sequence.json"

# per root: runs of one round's events become one sorted block
seq_check=$(jq -nc --slurpfile want "$EXPECTED" --slurpfile got "$D/live-sequence.json" '
	def blocks: reduce .[] as $x ([]; if $x.round != null and (.[-1][0].round? == $x.round) then .[-1] += [$x] else . + [[$x]] end)
		| map(sort_by(tojson));
	[$want[0].roots, $got[0].roots] as [$w, $g]
	| if ($w | length) != ($g | length) then {ok: false, why: "\($w | length) roots expected, \($g | length) live"}
	  else [range($w | length) as $i | select(($w[$i].events | blocks) != ($g[$i].events | blocks))
	        | "root \($i + 1) (\($w[$i].root)) differs"] as $bad
	       | {ok: ($bad == []), why: ($bad | join("; "))} end')

# the loop windows: from each fix.chosen to the showing of its end card
windows=$(printf '%s' "$view" | jq -c '[.[] | select(.type == "fix.chosen") | {loop: .seq, from: (.at | fromdateiso8601)}]')
windows=$(printf '%s' "$windows" | jq -c '.[]' | while IFS= read -r w; do
	l=$(printf '%s' "$w" | jq -r .loop); card=$EFFORT/cards/end-card-loop-$l.md
	# the loop ends when main first shows its end card: the first show-card
	# call for it in main's tool log (the card file's time if none)
	shown=$(for f in "$EFFORT"/hook-log/scope-*; do
		[ -f "$f" ] || continue
		jq -e --arg s "--subject loop:$l " '(.tool_input.command // "") | contains("show-card.sh --record end-card") and contains($s)' "$f" >/dev/null 2>&1 && mtime "$f"
	done | sort -n | head -1)
	to=${shown:-$(if [ -f "$card" ]; then mtime "$card"; else date +%s; fi)}
	printf '%s' "$w" | jq -c --argjson to "$to" '. + {to: $to}'
done | jq -sc .)

sends=$(jq -sc . "$D/sends.log" 2>/dev/null || echo '[]')
a=$(jq -nc --argjson s "$sends" --argjson w "$windows" '[$s[] as $x | $w[] | select($x.t > .from and $x.t < .to and $x.kind != "request in loop")
	| "sent \"\($x.words)\" inside loop \(.loop)"]')
b=$(jq -nc --argjson s "$sends" --arg re "$ASK_RE" '[$s[] | select(.kind == "answer" and (.screen_tail | test($re) | not)) | "answered \"\(.words)\" with nothing asked"]')
c=$(cat "$EFFORT/stops/main-stop.out" 2>/dev/null | jq -sc '[.[] | .systemMessage // empty | select(test("not held again"))]' || echo '[]')
# (d) and (e): main's calls inside a loop, judged by what each does
# (effect.jq): fails an unnamed write, dispatch, question or internal script
# (unnamed) and any read of the events, cards or stops folder (events read);
# reports a read-only look at the project; ignores an echo of a literal or $?,
# a cd and a plain assignment
calls=$(for f in "$EFFORT"/hook-log/scope-*; do
	[ -f "$f" ] || continue
	jq -c --argjson t "$(mtime "$f")" 'select((.agent_id // "") == "") | {t: $t, tool: .tool_name, command: (.tool_input.command // ""), query: (.tool_input.query // ""), path: (.tool_input.file_path // .tool_input.path // "")}' "$f"
done | jq -sc --argjson w "$windows" --arg lab "$LAB" --arg effort "$EFFORT" -f "$C/effect.jq")
d=$(printf '%s' "$calls" | jq -c .unnamed); e=$(printf '%s' "$calls" | jq -c .events_read); reads=$(printf '%s' "$calls" | jq -c .reads)
# (f) a request the driver typed while a question was open is a driver
# fault: the run fails as not run
f=$(jq -sc --arg re "$ASK_RE" '[.[] | select(.kind != "answer" and (.screen_tail | test($re))) | "sent \"\(.words)\" while a question was open"]' "$D/sends.log" 2>/dev/null || echo '[]')
# every held stop, with what it held: reported, never failed (main asks
# next.sh first; the hold is the net). Only a dropped hold fails, (c).
holds=$(cat "$EFFORT/stops/main-stop.out" 2>/dev/null | jq -sc '[.[] | select(.decision == "block") | .reason | split("\n") | map(select(startswith("owed: ")) | ltrimstr("owed: ") | .[0:120])]' || echo '[]')

jq -n --arg run "$RUN" --argjson s "$seq_check" --argjson a "$a" --argjson b "$b" --argjson c "$c" --argjson d "$d" --argjson r "$reads" --argjson e "$e" --argjson h "$holds" --argjson f "$f" \
	'{run: $run, sequence: $s, typed_in_loop: $a, answered_unasked: $b, holds_dropped: $c, unnamed_steps: $d, events_read: $e, reads_reported: $r, holds_fired: $h, driver_fault: $f}
	 | .passed = (.sequence.ok and .typed_in_loop == [] and .answered_unasked == [] and .holds_dropped == [] and .unnamed_steps == [] and .events_read == [] and .driver_fault == [])' > "$D/compare.json"
jq -r '"\(.run) \(if .passed then "pass" else "FAIL" end): sequence \(if .sequence.ok then "ok" else .sequence.why end); typed in loop \(.typed_in_loop | length); answered unasked \(.answered_unasked | length); holds dropped \(.holds_dropped | length); unnamed steps \(.unnamed_steps | length); events read \(.events_read | length); reads reported \(.reads_reported | length); holds fired \(.holds_fired | length)\(if .driver_fault != [] then "; DRIVER FAULT, not run" else "" end)"' "$D/compare.json"
jq -e .passed "$D/compare.json" >/dev/null
