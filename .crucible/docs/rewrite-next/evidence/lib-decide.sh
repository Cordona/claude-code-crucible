# Shared by the evidence runs: one recorded gate answered through the real
# hooks. decide EFFORT RECORD SUBJECT CARD_FILE ANSWER [ACCEPT]
decide() {
	_gt=/Users/cordona/IdeaProjects/cordona/claude-code-crucible/new-rewrite/framework/core/main-thread/crucible-gate
	_acc=${6:-Approve (Recommended)}; _t="decide-$$-$(date +%s%N)"
	sh $_gt/scripts/show-card.sh --record "$2" --effort "$1" --subject "$3" --accept "$_acc" "$4" >/dev/null
	jq -cn --rawfile m "$4" --arg s "$CLAUDE_CODE_SESSION_ID" '{session_id: $s, last_assistant_message: $m}' | sh $_gt/hooks/stop/require-card-shown.sh >/dev/null
	jq -cn --arg s "$CLAUDE_CODE_SESSION_ID" --arg t "$_t" --arg a "$_acc" '{session_id: $s, tool_name: "AskUserQuestion", tool_use_id: $t, tool_input: {questions: [{question: "Decide?", header: "Decide", options: [{label: $a, description: "yes"}, {label: "Change it", description: "no"}]}]}}' | sh $_gt/hooks/pre-tool-use/hold-question-until-card-shown.sh >/dev/null
	jq -cn --arg s "$CLAUDE_CODE_SESSION_ID" --arg t "$_t" --arg a "$5" '{session_id: $s, tool_name: "AskUserQuestion", tool_use_id: $t, tool_response: {answers: {"Decide?": $a}}}' | sh $_gt/hooks/post-tool-use/record-gate-answer.sh
}
