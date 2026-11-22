C=/Users/cordona/IdeaProjects/cordona/claude-code-crucible/new-rewrite/framework/core/main-thread
FL=$C/crucible-dynamic-flow/scripts; HK=$C/crucible-dynamic-flow/hooks/stop/remind-flow-position.sh; E=$C/crucible-effort/scripts; G=$C/crucible-grill/scripts
S="/private/tmp/claude-501/-Users-cordona-IdeaProjects-cordona-claude-code-crucible/480d0359-cf0d-4c14-a59e-2a72be5dba4f/scratchpad/flow test"; rm -rf "$S"; mkdir -p "$S"
export CRUCIBLE_HOME="$S/space" CLAUDE_CONFIG_DIR="$S/cfg" CLAUDE_CODE_SESSION_ID=sess-1
F=$(sh $E/effort-start.sh --name prune)
GT=$C/crucible-gate
# Agrees a flow the real way: its card from flow-show --file, shown through
# show-card --record flow-agree, the question through the hooks, the human's
# yes through record-gate-answer.sh, then flow-agree.sh. Prints the flow name.
say() { # $1 effort, $2 flow file, $3 the human's answer: one recorded gate
	sha=$(shasum -a 256 "$2" | cut -d ' ' -f 1); card="$S/card-$sha.md"; t="say-$sha-$(date +%s%N)"
	sh $FL/flow-card.sh --file "$2" > "$card" || return 2
	sh $GT/scripts/show-card.sh --record flow-agree --effort "$1" --subject "$sha" --accept "Agree this flow (Recommended)" "$card" >/dev/null
	jq -cn --rawfile m "$card" --arg s "$CLAUDE_CODE_SESSION_ID" '{session_id: $s, last_assistant_message: $m}' | sh $GT/hooks/stop/require-card-shown.sh >/dev/null
	jq -cn --arg s "$CLAUDE_CODE_SESSION_ID" --arg t "$t" '{session_id: $s, tool_name: "AskUserQuestion", tool_use_id: $t, tool_input: {questions: [{question: "Agree this flow?", header: "Flow", options: [{label: "Agree this flow (Recommended)", description: "It reaches the goal"}, {label: "Change it", description: "Something is off"}]}]}}' | sh $GT/hooks/pre-tool-use/hold-question-until-card-shown.sh >/dev/null
	jq -cn --arg s "$CLAUDE_CODE_SESSION_ID" --arg t "$t" --arg a "$3" '{session_id: $s, tool_name: "AskUserQuestion", tool_use_id: $t, tool_response: {answers: {"Agree this flow?": $a}}}' | sh $GT/hooks/post-tool-use/record-gate-answer.sh
}
agree() { # $1 effort, $2 flow file
	sha=$(shasum -a 256 "$2" | cut -d ' ' -f 1); card="$S/card-$sha.md"
	sh $FL/flow-card.sh --file "$2" > "$card" || return 2
	sh $GT/scripts/show-card.sh --record flow-agree --effort "$1" --subject "$sha" --accept "Agree this flow (Recommended)" "$card" >/dev/null
	jq -cn --rawfile m "$card" --arg s "$CLAUDE_CODE_SESSION_ID" '{session_id: $s, last_assistant_message: $m}' | sh $GT/hooks/stop/require-card-shown.sh >/dev/null
	jq -cn --arg s "$CLAUDE_CODE_SESSION_ID" --arg t "agree-$sha" '{session_id: $s, tool_name: "AskUserQuestion", tool_use_id: $t, tool_input: {questions: [{question: "Agree this flow?", header: "Flow", options: [{label: "Agree this flow (Recommended)", description: "It reaches the goal"}, {label: "Change it", description: "Something is off"}]}]}}' | sh $GT/hooks/pre-tool-use/hold-question-until-card-shown.sh >/dev/null
	jq -cn --arg s "$CLAUDE_CODE_SESSION_ID" --arg t "agree-$sha" '{session_id: $s, tool_name: "AskUserQuestion", tool_use_id: $t, tool_response: {answers: {"Agree this flow?": "Agree this flow (Recommended)"}}}' | sh $GT/hooks/post-tool-use/record-gate-answer.sh
	sh $FL/flow-agree.sh --effort "$1" --file "$2"
}
run() { echo "\$ $(echo "$*" | sed "s|$FL/||g;s|$E/||g;s|$G/||g;s|$S|<S>|g;s|$F|<F>|g")"; out=$("$@" 2>&1); e=$?; echo "$out" | sed "s|$F|<F>|g;s|$S|<S>|g;s|^|    |"; echo "    [exit $e]"; }
hook() { echo "\$ stop hook ($1)"; printf '{"session_id":"%s","stop_hook_active":%s}' "$1" "${2:-false}" | sh $HK | sed "s|$F|<F>|g" | jq -r '.hookSpecificOutput.additionalContext // empty' | sed 's/^/    /'; echo "    [end]"; }
cat > "$S/flow.json" <<'J'
{ "goal": "Share one understanding of what the prune work must achieve",
  "done_when": { "criteria": "the human says we share one understanding of the goal", "by": "human" },
  "steps": [
    { "id": 1, "do": "Find out what the work is about", "done_when": { "criteria": "the human confirmed the goal and what must not break", "by": "human" } },
    { "id": 2, "do": "Grill the open goal", "uses": "crucible-grill", "done_when": { "event": "grill.ended" } } ] }
J
echo '{"goal":"","steps":[{"id":1,"do":"x","done_when":{"maybe":"x"}},{"id":1,"do":"y","done_when":{"criteria":"c","by":"robot"}}]}' > "$S/bad.json"
run sh $FL/flow-agree.sh --effort "$F" --file "$S/bad.json"
echo "--- without the human's recorded yes: refused"
run sh $FL/flow-agree.sh --effort "$F" --file "$S/flow.json"
echo "--- the card flow-show --file renders for agreeing"
run sh $FL/flow-card.sh --file "$S/flow.json"
echo "--- agreed through the gate"
FLOW=$(agree "$F" "$S/flow.json"); echo "flow: $(echo "$FLOW" | sed "s|$F|<F>|")"
echo "--- yes, then no on the same file: the no counts, nothing is agreed"
cp "$S/flow.json" "$S/flow-yes-no.json"; jq '.goal = "A flow the human changed their mind on"' "$S/flow-yes-no.json" > "$S/flow-yn.json"
say "$F" "$S/flow-yn.json" "Agree this flow (Recommended)"; say "$F" "$S/flow-yn.json" "Change it"
run sh $FL/flow-agree.sh --effort "$F" --file "$S/flow-yn.json"
echo "--- the same yes can't agree a second flow"
run sh $FL/flow-agree.sh --effort "$F" --file "$S/flow.json"
hook sess-1
hook sess-1
run sh $FL/flow-show.sh --flow "$FLOW"
run sh $FL/flow-step-done.sh --flow "$FLOW" --step 2
run sh $FL/flow-step-done.sh --flow "$FLOW" --step 1
run sh $FL/flow-step-done.sh --flow "$FLOW" --step 1 --evidence "Yes: nightly prune, must not delete live data"
run sh $FL/flow-step-done.sh --flow "$FLOW" --step 1 --evidence "again"
hook sess-1
echo "--- a grill runs and ends"
D=$(sh $G/grill-new.sh --effort "$F" --topic prune); sh $G/grill-add.sh --grill "$D" --question "Cron or person?" --recommendation cron --reason nightly >/dev/null; sh $G/grill-answer.sh --grill "$D" --id q1 --text cron >/dev/null
GE=$(sh $G/grill-end.sh --grill "$D"); echo "grill.ended: ${GE##*/}"
hook sess-1
hook sess-1
run sh $FL/flow-show.sh --flow "$FLOW"
echo "--- change mid-flow: add a step, skip it, then reopen step 2"
echo '[{"add":{"id":3,"do":"Check with ops","done_when":{"criteria":"ops agreed","by":"human"}},"before":2}]' > "$S/ops1.json"
run sh $FL/flow-change.sh --flow "$FLOW" --file "$S/ops1.json" --reason "The human wants ops in the loop first"
echo '[{"add":{"id":3,"do":"dup","done_when":{"criteria":"x"}}}]' > "$S/ops-bad.json"
run sh $FL/flow-change.sh --flow "$FLOW" --file "$S/ops-bad.json" --reason "x"
echo '[{"skip":3}]' > "$S/ops2.json"
run sh $FL/flow-change.sh --flow "$FLOW" --file "$S/ops2.json" --reason "Ops is away; the human accepts the risk"
run sh $FL/flow-step-done.sh --flow "$FLOW" --step 2
echo '[{"reopen":2}]' > "$S/ops3.json"
run sh $FL/flow-change.sh --flow "$FLOW" --file "$S/ops3.json" --reason "The goal changed after the grill"
run sh $FL/flow-step-done.sh --flow "$FLOW" --step 2 --event "$(basename "$GE" | sed 's/-.*//;s/^0*//')"
run sh $FL/flow-show.sh --flow "$FLOW"
echo "--- a second grill: evidence again"
D=$(sh $G/grill-new.sh --effort "$F" --topic prune-2); GE2=$(sh $G/grill-end.sh --grill "$D")
run sh $FL/flow-step-done.sh --flow "$FLOW" --step 2
hook sess-1
echo "--- end: every step done, the human confirms the goal"
run sh $FL/flow-end.sh --flow "$FLOW" --outcome done --evidence "x"
run sh $FL/flow-show.sh --flow "$FLOW" --all
run sh $FL/flow-end.sh --flow "$FLOW" --outcome done --evidence "again"
run sh $FL/flow-change.sh --flow "$FLOW" --file "$S/ops2.json" --reason "after end"
echo "--- a second flow: event done_when, end refused while open, then dropped"
cat > "$S/flow2.json" <<'J'
{ "goal": "Prove the hook handles two flows", "done_when": { "event": "grill.ended" },
  "steps": [ { "id": 1, "do": "Grill again", "done_when": { "event": "grill.ended" } },
             { "id": 2, "do": "Confirm", "done_when": { "criteria": "it works" } } ] }
J
F2=$(agree "$F" "$S/flow2.json"); echo "flow 2: ${F2##*:}"
cat > "$S/flow3.json" <<'J'
{ "goal": "A third flow side by side", "done_when": { "criteria": "done" }, "steps": [ { "id": 1, "do": "Wait", "done_when": { "criteria": "waited" } } ] }
J
F3=$(agree "$F" "$S/flow3.json"); echo "flow 3: ${F3##*:}"
hook sess-1
run sh $FL/flow-show.sh --effort "$F"
run sh $FL/flow-end.sh --flow "$F2" --outcome done
run sh $FL/flow-end.sh --flow "$F2" --outcome dropped
run sh $FL/flow-end.sh --flow "$F2" --outcome dropped --words "The human moved to other work"
run sh $FL/flow-show.sh --effort "$F"
echo "--- a new session speaks once; a repeat stop and a subagent stay silent; a stop after another hook continued the turn speaks a new position once"
CLAUDE_CODE_SESSION_ID=sess-2 sh $FL/flow-step-done.sh --flow "$F3" --step 1 --evidence "waited 5 minutes" | sed "s|$F|<F>|"
hook sess-2
hook sess-2
hook sess-1 true
hook sess-1 true
printf '{"session_id":"sess-1","agent_id":"sub","stop_hook_active":false}' | sh $HK; echo "[subagent: no output]"
echo "--- paused effort"
sh $E/effort-pause.sh --effort "$F" --words later >/dev/null
run sh $FL/flow-end.sh --flow "$F3" --outcome done --evidence "done"
hook sess-2
echo "--- junk input"; echo nope | sh $HK; echo "[exit $?]"
echo "=== PROBES (Fable's gaps, plus revise)"
sh $E/effort-resume.sh --effort "$F" --words back >/dev/null
P=$(sh $E/effort-start.sh --name probes)
grill_end() { d=$(sh $G/grill-new.sh --effort "$P" --topic "$1"); sh $G/grill-end.sh --grill "$d" | sed 's|.*/||;s/-.*//;s/^0*//'; }
cat > "$S/p1.json" <<'J'
{ "goal": "Two steps want the same event type", "done_when": { "event": "grill.ended" },
  "steps": [ { "id": 1, "do": "A", "done_when": { "event": "grill.ended" } },
             { "id": 2, "do": "B", "done_when": { "event": "grill.ended" } },
             { "id": 3, "do": "C, a criterion main verifies", "done_when": { "criteria": "the README says how to run it" } },
             { "id": 4, "do": "D, matches topic", "done_when": { "event": "grill.ended", "match": { "topic": "wanted" } } } ] }
J
P1=$(agree "$P" "$S/p1.json")
cat > "$S/p2.json" <<'J'
{ "goal": "A second flow wanting the same event", "done_when": { "criteria": "x" }, "steps": [ { "id": 1, "do": "Z", "done_when": { "event": "grill.ended" } } ] }
J
P2=$(agree "$P" "$S/p2.json")
F="$P"
E1=$(grill_end "other")
echo "--- one event, several steps and flows: the hook says only one can be proven"
hook sess-1
run sh $FL/flow-step-done.sh --flow "$P1" --step 1 --event "$E1"
run sh $FL/flow-step-done.sh --flow "$P1" --step 2 --event "$E1"
run sh $FL/flow-step-done.sh --flow "$P2" --step 1 --event "$E1"
echo "--- match: a non-matching event is refused, the matching one taken"
run sh $FL/flow-step-done.sh --flow "$P1" --step 4
E2=$(grill_end "wanted")
run sh $FL/flow-step-done.sh --flow "$P1" --step 4
echo "--- a wrong event type forced with --event"
AG=$(echo "$P1" | sed 's/.*://')
run sh $FL/flow-step-done.sh --flow "$P1" --step 2 --event "$AG"
echo "--- a criterion main verifies: mark [m]"
run sh $FL/flow-step-done.sh --flow "$P1" --step 3 --evidence "README.md has a Run section"
echo "--- move"
echo '[{"move":2,"before":1}]' > "$S/m.json"
run sh $FL/flow-change.sh --flow "$P1" --file "$S/m.json" --reason "B comes first now"
run sh $FL/flow-show.sh --flow "$P1"
echo "--- revise: step 2 named the wrong event type; revised to effort.paused, written before the revise, which still counts"
sh $E/effort-pause.sh --effort "$P" --words "short pause" >/dev/null; sh $E/effort-resume.sh --effort "$P" --words "back" >/dev/null
echo '[{"revise":{"step":2,"done_when":{"event":"effort.paused"}}}]' > "$S/r1.json"
run sh $FL/flow-change.sh --flow "$P1" --file "$S/r1.json" --reason "The pause was the real signal"
run sh $FL/flow-step-done.sh --flow "$P1" --step 2
echo "--- revise a done step: refused; revise a bad done_when: refused"
echo '[{"revise":{"step":1,"done_when":{"criteria":"x"}}}]' > "$S/r2.json"
run sh $FL/flow-change.sh --flow "$P1" --file "$S/r2.json" --reason "x"
echo '[{"revise":{"step":2,"done_when":{"maybe":"x"}}}]' > "$S/r3.json"
run sh $FL/flow-change.sh --flow "$P1" --file "$S/r3.json" --reason "x"
echo "--- the flow-level check is not a claim: P1 ends done on a grill.ended its steps already used"
run sh $FL/flow-end.sh --flow "$P1" --outcome done
echo "--- revise the flow's own check, then end"
echo '[{"revise":{"done_when":{"criteria":"the human says the probe is over","by":"human"}}}]' > "$S/r4.json"
run sh $FL/flow-change.sh --flow "$P2" --file "$S/r4.json" --reason "The goal check was wrong"
echo '[{"skip":1}]' > "$S/r5.json"; sh $FL/flow-change.sh --flow "$P2" --file "$S/r5.json" --reason "Its event went to the other flow" >/dev/null
run sh $FL/flow-end.sh --flow "$P2" --outcome done --evidence "Yes, the probe is over"
run sh $FL/flow-show.sh --flow "$P2" --all
echo "--- flow-show on an unknown flow"
run sh $FL/flow-show.sh --flow "$P:999"
echo "--- the stop hook reads events as JSON: an effort written as compact lines is still found"
FC=$(sh $E/effort-start.sh --name compact)
agree "$FC" "$S/flow.json" >/dev/null
for f in "$FC"/events/*.json; do chmod u+w "$f"; jq -c . "$f" >"$f.c" && mv "$f.c" "$f"; chmod 444 "$f"; done
grep -c '"claude_session_id":"sess-1"' "$FC"/events/*.json | awk -F: '{n += $2} END {print "    events with the compact field: " n}'
hook sess-1 | sed "s|$FC|<FC>|g"
echo "--- a flow agreed after work began: an older event may be named for a step, never one older than its reopen"
FL2=$(sh $E/effort-start.sh --name late)
LG=$(sh $G/grill-new.sh --effort "$FL2" --topic 'done before the flow'); sh $G/grill-end.sh --grill "$LG" >/dev/null
OLD=$(sh $C/crucible-events/scripts/events-read.sh --effort "$FL2" --type grill.ended | jq '.[0].seq')
cat > "$S/late.json" <<'J'
{ "goal": "Finish what was started", "done_when": { "criteria": "the human says so", "by": "human" },
  "steps": [ { "id": 1, "do": "Grill the goal", "uses": "crucible-grill", "done_when": { "event": "grill.ended" } } ] }
J
LF=$(agree "$FL2" "$S/late.json")
run sh $FL/flow-step-done.sh --flow "$LF" --step 1
run sh $FL/flow-step-done.sh --flow "$LF" --step 1 --event "$OLD"
echo '[{"reopen":1}]' > "$S/late-r.json"; run sh $FL/flow-change.sh --flow "$LF" --file "$S/late-r.json" --reason "the human: it needs another round"
run sh $FL/flow-step-done.sh --flow "$LF" --step 1 --event "$OLD"
echo "--- the skill's example names only real events: each has exactly one rule file"
sed -n '/^```json/,/^```/p' $C/crucible-dynamic-flow/SKILL.md | sed '1d;$d' | jq -r '.. | objects | .event? // empty' | while IFS= read -r ev; do
	n=$(ls $C/*/events/"$ev".jq 2>/dev/null | wc -l | tr -d ' ')
	echo "    $ev: $n rule file(s)"
done
