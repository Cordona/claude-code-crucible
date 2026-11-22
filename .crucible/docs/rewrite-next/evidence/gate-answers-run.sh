# Evidence run for the gate answer events: every case through the real hooks.
C=/Users/cordona/IdeaProjects/cordona/claude-code-crucible/new-rewrite/framework/core/main-thread
GT=$C/crucible-gate; E=$C/crucible-effort/scripts
SC=$GT/scripts/show-card.sh; STOP=$GT/hooks/stop/require-card-shown.sh; HOLD=$GT/hooks/pre-tool-use/hold-question-until-card-shown.sh; POST=$GT/hooks/post-tool-use/record-gate-answer.sh
S="/private/tmp/claude-501/-Users-cordona-IdeaProjects-cordona-claude-code-crucible/480d0359-cf0d-4c14-a59e-2a72be5dba4f/scratchpad/gate answers test"; rm -rf "$S"; mkdir -p "$S"
export CRUCIBLE_HOME="$S/space" CLAUDE_CONFIG_DIR="$S/cfg" CLAUDE_CODE_SESSION_ID=sess-g
F=$(sh $E/effort-start.sh --name gates)
show() { sed "s|$F|<F>|g;s|$S|<S>|g;s|^|    |"; }
printf 'Approve the spec?\n\n- draft 9f2c\n' > "$S/card.md"
q() { # $1 tool_use_id, $2 questions JSON
	printf '{"session_id":"sess-g","tool_name":"AskUserQuestion","tool_use_id":"%s","tool_input":{"questions":%s}}' "$1" "$2"; }
ONE='[{"question":"Approve this spec?","header":"Spec","options":[{"label":"Approve the spec (Recommended)","description":"It covers the goal"},{"label":"Change it","description":"Something is off"}]}]'
shown() { printf '%s' '{"session_id":"sess-g","last_assistant_message":"Approve the spec?\n\n- draft 9f2c"}' | sh $STOP >/dev/null; }
answer() { printf '{"session_id":"sess-g","tool_name":"AskUserQuestion","tool_use_id":"%s","tool_response":{"answers":{"Approve this spec?":"%s"}}}' "$1" "$2" | sh $POST; }
events() { ls "$F/events" | sed 's/^/    /'; }

echo "--- show-card refusals for a recorded gate"
sh $SC --record spec-approval "$S/card.md" 2>&1 | tail -1 | show
sh $SC --record Spec_Approval --effort "$F" --accept x "$S/card.md" 2>&1 | tail -1 | show
sh $SC --record spec-approval --effort "$F" "$S/card.md" 2>&1 | tail -1 | show

echo "--- a recorded gate: the question must be one, single-select, offering the yes option"
sh $SC --record spec-approval --effort "$F" --subject 9f2c --accept "Approve the spec (Recommended)" "$S/card.md" >/dev/null; shown
q t1 "[$(echo "$ONE" | jq -c '.[0]'),$(echo "$ONE" | jq -c '.[0] | .question = "Second?"')]" | sh $HOLD | jq -r '.hookSpecificOutput.permissionDecisionReason' | show
q t1 "$(echo "$ONE" | jq -c '.[0].multiSelect = true')" | sh $HOLD | jq -r '.hookSpecificOutput.permissionDecisionReason' | show
q t1 "$(echo "$ONE" | jq -c '.[0].options[0].label = "Approve"')" | sh $HOLD | jq -r '.hookSpecificOutput.permissionDecisionReason' | show
echo "  the good question: allowed, a hand-off left"
q t1 "$ONE" | sh $HOLD; echo "    [no output = allowed]"; ls "$S/cfg/cache/crucible-gate/sess-g/answers/" | show
echo "--- the human picks the yes option: accepted true"
answer t1 "Approve the spec (Recommended)"; events; jq -c '{by, body}' "$F"/events/*gate.answered.json | show
ls "$S/cfg/cache/crucible-gate/sess-g/answers/" | wc -l | show

echo "--- the human types their own answer: accepted false"
sh $SC --record spec-approval --effort "$F" --subject 9f2c --accept "Approve the spec (Recommended)" "$S/card.md" >/dev/null; shown
q t2 "$ONE" | sh $HOLD
answer t2 "Approve, but fix section 2 first"; jq -c '.body | {answer, accepted}' "$(ls "$F"/events/*gate.answered.json | tail -1)" | show

echo "--- an ordinary gate (no --record): no event"
before=$(ls "$F/events" | wc -l)
sh $SC "$S/card.md" >/dev/null; shown; q t3 "$ONE" | sh $HOLD; answer t3 "Change it"
echo "    events before $before, after $(ls "$F/events" | wc -l)"
echo "--- a subagent's answer: no event"
printf '{"session_id":"sess-g","agent_id":"sub","tool_name":"AskUserQuestion","tool_use_id":"t1","tool_response":{"answers":{}}}' | sh $POST; echo "    [no output]"
echo "--- only the hook may write gate.answered"
echo '{"record":"spec-approval","subject":"9f2c","question":"q","accept":"a","answer":"a","accepted":true}' > "$S/forged.json"
sh $C/crucible-events/scripts/event-write.sh --effort "$F" --type gate.answered --by main.sh --body-file "$S/forged.json" 2>&1 | show
echo '{"record":"spec-approval","subject":"9f2c","question":"q","accept":"a","answer":"b","accepted":true}' > "$S/lie.json"
sh $C/crucible-events/scripts/event-write.sh --effort "$F" --type gate.answered --by record-gate-answer.sh --body-file "$S/lie.json" 2>&1 | show
echo "--- junk input: exit 0"
echo nope | sh $POST 2>/dev/null; echo "    [exit $?]"
echo "--- the shared reader: the newest answer counts"
RD=$GT/scripts/gate-answer.sh
rd() { out=$(sh $RD --effort "$F" --record "$1" --subject "$2" 2>&1); e=$?; echo "$out" | show; echo "    [exit $e]"; }
echo "  spec-approval on 9f2c: the newest is the typed answer (no)"; rd spec-approval 9f2c
sh $SC --record spec-approval --effort "$F" --subject 9f2c --accept "Approve the spec (Recommended)" "$S/card.md" >/dev/null; shown
q t4 "$ONE" | sh $HOLD; answer t4 "Approve the spec (Recommended)"
echo "  then a yes: accepted"; rd spec-approval 9f2c
sh $SC --record spec-approval --effort "$F" --subject 9f2c --accept "Approve the spec (Recommended)" "$S/card.md" >/dev/null; shown
q t5 "$ONE" | sh $HOLD; answer t5 "Change it"
echo "  then a no: the earlier yes no longer counts"; rd spec-approval 9f2c
echo "  another subject, and no answer at all"; rd spec-approval other; rd effort-start 9f2c
