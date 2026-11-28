# Evidence run for crucible-adaptive-flow with the step catalogue: every case
# through the real scripts and hooks, from /, every path from stdout.
C=/Users/cordona/IdeaProjects/cordona/claude-code-crucible/new-rewrite/framework/core/main-thread
S="/private/tmp/claude-501/-Users-cordona-IdeaProjects-cordona-claude-code-crucible/480d0359-cf0d-4c14-a59e-2a72be5dba4f/scratchpad/flow test"; rm -rf "$S"; mkdir -p "$S"
export CRUCIBLE_HOME="$S/space" CLAUDE_CONFIG_DIR="$S/cfg" CLAUDE_CODE_SESSION_ID=sess-1
# A skills folder of links, as an install makes it, plus stand-in components:
# probe declares more steps; broken and notjson hold files of the wrong shape.
K="${S%/*}/flow-links/skills"; rm -rf "${K%/skills}"; mkdir -p "$K"
for c in "$C"/*/; do c=${c%/}; ln -s "$c" "$K/${c##*/}"; done
mkdir -p "$K/probe" "$K/broken" "$K/notjson"
cat > "$K/probe/flow-step.json" <<'J'
[ { "name": "wanted-grill", "stage": ["build", "test"], "does": "Grill the topic that matters", "propose_when": "when the wanted topic is open", "ends_with": { "event": "grill.ended", "match": { "topic": "wanted" } }, "skills": ["crucible-grill"] },
  { "name": "pause", "stage": ["setup"], "does": "Pause the effort for a while", "propose_when": "when the work must wait", "ends_with": { "event": "effort.paused" }, "skills": ["crucible-effort"] } ]
J
cat > "$K/broken/flow-step.json" <<'J'
[ { "name": "criterion", "stage": ["build"], "does": "Check by hand", "propose_when": "never", "ends_with": { "criteria": "it looks right" }, "skills": ["crucible-grill"] },
  { "name": "raw-gate", "stage": ["build"], "does": "Ask the human", "propose_when": "never", "ends_with": { "event": "gate.answered" }, "skills": ["crucible-gate"] },
  { "name": "no-rule", "stage": ["build"], "does": "Wait for a fact nobody writes", "propose_when": "never", "ends_with": { "event": "nobody.writes" }, "skills": ["crucible-grill"] },
  { "name": "twice", "stage": ["build"], "does": "One", "propose_when": "never", "ends_with": { "event": "grill.ended" }, "skills": ["crucible-grill"] },
  { "name": "twice", "stage": ["build"], "does": "Two", "propose_when": "never", "ends_with": { "event": "grill.ended" }, "skills": ["crucible-grill"] },
  { "name": "no-stage", "stage": [], "does": "Belongs nowhere", "propose_when": "never", "ends_with": { "event": "grill.ended" }, "skills": ["crucible-grill"] },
  { "name": "no-skill", "stage": ["build"], "does": "Needs a skill nobody installed", "propose_when": "never", "ends_with": { "event": "grill.ended" }, "skills": ["crucible-grill", "not-installed"] },
  { "name": "skills-string", "stage": ["build"], "does": "Names skills the old way", "propose_when": "never", "ends_with": { "event": "grill.ended" }, "uses": "crucible-grill, crucible-spec" } ]
J
printf '[ { "name": ' > "$K/notjson/flow-step.json"
FL=$K/crucible-adaptive-flow/scripts; HK=$K/crucible-adaptive-flow/hooks/stop/remind-flow-position.sh
RFL=$C/crucible-adaptive-flow/scripts
E=$C/crucible-effort/scripts; G=$C/crucible-grill/scripts; GT=$C/crucible-gate
F=$(sh $E/main/effort-start.sh --name prune)
run() { echo "\$ $(echo "$*" | sed "s|$RFL/||g;s|$FL/||g;s|$K|<K>|g;s|$E/||g;s|$G/||g;s|$S|<S>|g;s|$F|<F>|g")"; out=$("$@" 2>&1); e=$?; echo "$out" | sed "s|$F|<F>|g;s|$S|<S>|g;s|^|    |"; echo "    [exit $e]"; }
hook() { echo "\$ stop hook ($1)"; printf '{"session_id":"%s","stop_hook_active":%s}' "$1" "${2:-false}" | sh "$HK" | sed "s|$F|<F>|g" | jq -r '.hookSpecificOutput.additionalContext // empty' | sed 's/^/    /'; echo "    [end]"; }
# The human's answer to the flow gate, the real way: the card flow-card.sh
# prints, shown through show-card --record flow-agree, the question through
# the hooks, the answer through record-gate-answer.sh.
say() { # $1 effort, $2 flow file, $3 the human's answer
	sha=$(shasum -a 256 "$2" | cut -d ' ' -f 1); card="$S/card-$sha.md"; t="say-$sha-$(date +%s%N)"
	sh "$FL"/main/flow-card.sh --file "$2" > "$card" || return 2
	sh $GT/scripts/main/show-card.sh --record flow-agree --effort "$1" --subject "$sha" --accept "Agree this flow (Recommended)" "$card" >/dev/null
	jq -cn --rawfile m "$card" --arg s "$CLAUDE_CODE_SESSION_ID" '{session_id: $s, last_assistant_message: $m}' | sh $GT/hooks/stop/require-card-shown.sh >/dev/null
	jq -cn --arg s "$CLAUDE_CODE_SESSION_ID" --arg t "$t" '{session_id: $s, tool_name: "AskUserQuestion", tool_use_id: $t, tool_input: {questions: [{question: "Agree this flow?", header: "Flow", options: [{label: "Agree this flow (Recommended)", description: "It reaches the goal"}, {label: "Change it", description: "Something is off"}]}]}}' | sh $GT/hooks/pre-tool-use/hold-question-until-card-shown.sh >/dev/null
	jq -cn --arg s "$CLAUDE_CODE_SESSION_ID" --arg t "$t" --arg a "$3" '{session_id: $s, tool_name: "AskUserQuestion", tool_use_id: $t, tool_response: {answers: {"Agree this flow?": $a}}}' | sh $GT/hooks/post-tool-use/record-gate-answer.sh
}
agree() { say "$1" "$2" "Agree this flow (Recommended)" && sh "$FL"/main/flow-agree.sh --effort "$1" --file "$2"; }
seq_of() { sed 's|.*/||;s/-.*//;s/^0*//'; }
grill_end() { d=$(sh $G/main/grill-new.sh --effort "$1" --topic "$2"); sh $G/main/grill-end.sh --grill "$d" | seq_of; }

echo "=== 1. The catalogue"
echo "--- core alone, by its real path: the three prepare steps"
run sh $RFL/main/flow-candidates.sh
run sh $RFL/main/flow-candidates.sh --stages
run sh $RFL/main/flow-candidates.sh --stage build
echo "--- installed, through the links: core and the stand-ins; the wrong ones left out, named on stderr, exit 0"
run sh "$FL"/main/flow-candidates.sh
run sh "$FL"/main/flow-candidates.sh --stages
run sh "$FL"/main/flow-candidates.sh --stage prepare
run sh "$FL"/main/flow-candidates.sh --stage build
run sh "$FL"/main/flow-candidates.sh --stage x --stages

echo "=== 2. Agreeing"
cat > "$S/flow.json" <<'J'
{ "goal": "Know the prune work well enough to build it",
  "steps": [ { "id": 1, "step": "crucible-grill/grill" },
             { "id": 2, "step": "probe/wanted-grill" },
             { "id": 3, "step": "crucible-grill/grill" } ] }
J
echo '{"goal":"x","steps":[{"id":1,"does":"free text","ends_with":{"criteria":"looks right"}}]}' > "$S/free.json"
echo '{"goal":"x","ends_with":{"criteria":"c"},"steps":[{"id":1,"step":"crucible-grill/grill"}]}' > "$S/own-check.json"
echo '{"goal":"x","steps":[{"id":1,"step":"nobody/nothing"},{"id":2,"step":"broken/raw-gate"},{"id":3,"step":"broken/twice"}]}' > "$S/unknown.json"
echo "--- free text, a criterion, a flow-level check: refused, at the card and at agree"
run sh "$FL"/main/flow-card.sh --file "$S/free.json"
run sh "$FL"/main/flow-agree.sh --effort "$F" --file "$S/free.json"
run sh "$FL"/main/flow-agree.sh --effort "$F" --file "$S/own-check.json"
echo "--- a key not declared, and keys whose entries the scan left out: refused, with the scan's reason"
run sh "$FL"/main/flow-card.sh --file "$S/unknown.json"
run sh "$FL"/main/flow-agree.sh --effort "$F" --file "$S/unknown.json"
echo "--- without the human's recorded yes: refused"
run sh "$FL"/main/flow-agree.sh --effort "$F" --file "$S/flow.json"
echo "--- the card, resolved from the catalogue; the same step twice under two ids"
run sh "$FL"/main/flow-card.sh --file "$S/flow.json"
echo "--- agreed through the gate; the event holds each entry's copy"
FLOW=$(agree "$F" "$S/flow.json"); echo "flow: $(echo "$FLOW" | sed "s|$F|<F>|")"
jq -c '.body' "$F/events/$(printf '%06d' "${FLOW##*:}")-flow.agreed.json" | sed 's/^/    /'
echo "--- yes, then no on the same file: the no counts"
jq '.goal = "A flow the human changed their mind on"' "$S/flow.json" > "$S/flow-yn.json"
say "$F" "$S/flow-yn.json" "Agree this flow (Recommended)"; say "$F" "$S/flow-yn.json" "Change it"
run sh "$FL"/main/flow-agree.sh --effort "$F" --file "$S/flow-yn.json"
echo "--- the same yes can't agree a second flow"
run sh "$FL"/main/flow-agree.sh --effort "$F" --file "$S/flow.json"
hook sess-1
hook sess-1

echo "=== 3. Marking"
run sh "$FL"/main/flow-step-done.sh --flow "$FLOW" --step 1
run sh "$FL"/main/flow-step-done.sh --flow "$FLOW" --step 1 --evidence "the human said so"
G1=$(grill_end "$F" other)
hook sess-1
echo "--- a grill on another topic doesn't end the step that matches topic wanted"
run sh "$FL"/main/flow-step-done.sh --flow "$FLOW" --step 2
run sh "$FL"/main/flow-step-done.sh --flow "$FLOW" --step 1
echo "--- the same step's second occurrence needs its own event"
run sh "$FL"/main/flow-step-done.sh --flow "$FLOW" --step 3 --event "$G1"
G2=$(grill_end "$F" wanted)
run sh "$FL"/main/flow-step-done.sh --flow "$FLOW" --step 2 --event "$G2"
echo "--- two events waiting for one step: pick one"
G3=$(grill_end "$F" third); G4=$(grill_end "$F" fourth)
run sh "$FL"/main/flow-step-done.sh --flow "$FLOW" --step 3
run sh "$FL"/main/flow-step-done.sh --flow "$FLOW" --step 3 --event "$G4"
run sh "$FL"/main/flow-show.sh --flow "$FLOW"

echo "=== 4. Changing"
echo '[{"add":{"id":4,"step":"probe/pause"},"before":3}]' > "$S/ops1.json"
echo '[{"add":{"id":4,"step":"nobody/nothing"}}]' > "$S/ops-unknown.json"
echo '[{"add":{"id":4,"does":"Check with ops","ends_with":{"criteria":"ops agreed"}}}]' > "$S/ops-free.json"
echo '[{"revise":{"step":1,"ends_with":{"event":"effort.paused"}}}]' > "$S/ops-revise.json"
run sh "$FL"/main/flow-change.sh --flow "$FLOW" --file "$S/ops-free.json" --reason "x"
run sh "$FL"/main/flow-change.sh --flow "$FLOW" --file "$S/ops-unknown.json" --reason "x"
run sh "$FL"/main/flow-change.sh --flow "$FLOW" --file "$S/ops-revise.json" --reason "x"
echo "--- the events lock held: refused with exit 6, nothing written"
n=$(ls "$F"/events | wc -l | tr -d ' '); mkdir "$F/events/.lock"; echo $$ >"$F/events/.lock/pid"
run sh "$FL"/main/flow-change.sh --flow "$FLOW" --file "$S/ops1.json" --reason "The human wants a pause before the last grill"
rm -rf "$F/events/.lock"; echo "    events before $n, after $(ls "$F"/events | wc -l | tr -d ' ')"
run sh "$FL"/main/flow-change.sh --flow "$FLOW" --file "$S/ops1.json" --reason "The human wants a pause before the last grill"
jq -c '.body' "$(ls "$F"/events/*-flow.changed.json | tail -1)" | sed 's/^/    /'
echo '[{"reopen":1}]' > "$S/ops3.json"
run sh "$FL"/main/flow-change.sh --flow "$FLOW" --file "$S/ops3.json" --reason "The goal changed after the grill"
echo "--- after a reopen, an older event no longer counts"
run sh "$FL"/main/flow-step-done.sh --flow "$FLOW" --step 1 --event "$G3"
echo '[{"move":4,"before":1}]' > "$S/ops4.json"
run sh "$FL"/main/flow-change.sh --flow "$FLOW" --file "$S/ops4.json" --reason "The pause comes first"
run sh "$FL"/main/flow-show.sh --flow "$FLOW"

echo "=== 5. Ending"
run sh "$FL"/main/flow-end.sh --flow "$FLOW" --outcome done
run sh "$FL"/main/flow-end.sh --flow "$FLOW" --outcome done --evidence "x"
sh $E/main/effort-pause.sh --effort "$F" --words "a short pause" >/dev/null; sh $E/main/effort-resume.sh --effort "$F" --words back >/dev/null
run sh "$FL"/main/flow-step-done.sh --flow "$FLOW" --step 4
echo '[{"skip":1}]' > "$S/ops2.json"
run sh "$FL"/main/flow-change.sh --flow "$FLOW" --file "$S/ops2.json" --reason "The human says one grill was enough"
hook sess-1
run sh "$FL"/main/flow-end.sh --flow "$FLOW" --outcome done
run sh "$FL"/main/flow-show.sh --flow "$FLOW" --all
run sh "$FL"/main/flow-end.sh --flow "$FLOW" --outcome done
run sh "$FL"/main/flow-change.sh --flow "$FLOW" --file "$S/ops2.json" --reason "after end"
echo "--- a second flow, dropped with the human's words"
echo '{"goal":"Pause and wait","steps":[{"id":1,"step":"probe/pause"}]}' > "$S/flow2.json"
F2=$(agree "$F" "$S/flow2.json"); echo "flow 2: ${F2##*:}"
run sh "$FL"/main/flow-end.sh --flow "$F2" --outcome dropped
run sh "$FL"/main/flow-end.sh --flow "$F2" --outcome dropped --words "The human moved to other work"
run sh "$FL"/main/flow-show.sh --effort "$F"

echo "=== 6. The stop hook across sessions"
echo '{"goal":"A third flow","steps":[{"id":1,"step":"crucible-grill/grill"}]}' > "$S/flow3.json"
F3=$(agree "$F" "$S/flow3.json"); echo "flow 3: ${F3##*:}"
CLAUDE_CODE_SESSION_ID=sess-2 sh $G/main/grill-end.sh --grill "$(CLAUDE_CODE_SESSION_ID=sess-2 sh $G/main/grill-new.sh --effort "$F" --topic late)" >/dev/null
hook sess-2
hook sess-2
hook sess-1 true
printf '{"session_id":"sess-1","agent_id":"sub","stop_hook_active":false}' | sh "$HK"; echo "    [subagent: no output]"
echo "--- a damaged log: the flow scripts refuse; the hook stays silent and lets the stop through"
damaged=$(ls "$F"/events/*.json | sed -n 2p); chmod 000 "$damaged"; echo "    unreadable: ${damaged##*/}"
rm -rf "$S/cfg/cache/crucible-adaptive-flow"
run sh "$FL"/main/flow-show.sh --flow "$F3"
run sh "$FL"/main/flow-show.sh --effort "$F"
run sh "$FL"/internal/open-work.sh --effort "$F"
run sh "$FL"/main/flow-step-done.sh --flow "$F3" --step 1
run sh "$FL"/main/flow-end.sh --flow "$F3" --outcome dropped --words "x"
run sh "$FL"/main/flow-agree.sh --effort "$F" --file "$S/flow3.json"
printf '{"session_id":"sess-2","stop_hook_active":false}' | sh "$HK"; echo "    [exit $?, no output]"
chmod 444 "$damaged"
echo "  repaired: the hook speaks again"
hook sess-2
echo "--- paused effort: no writes, the hook silent"
sh $E/main/effort-pause.sh --effort "$F" --words later >/dev/null
run sh "$FL"/main/flow-step-done.sh --flow "$F3" --step 1
hook sess-2
echo "--- junk input"; echo nope | sh "$HK"; echo "    [exit $?]"

echo "=== 7. The skill's example names only declared steps"
sed -n '/^```json/,/^```/p' $C/crucible-adaptive-flow/SKILL.md | sed '1d;$d' > "$S/example.json"
run sh $RFL/main/flow-card.sh --file "$S/example.json"
