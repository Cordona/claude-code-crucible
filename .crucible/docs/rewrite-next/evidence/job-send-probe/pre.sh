#!/bin/sh
in=$(cat); d=$(dirname "$0")
printf '%s\n' "$in" > "$(mktemp "$d/logs/pre-XXXXXX")"
tool=$(printf '%s' "$in" | jq -r .tool_name)
case "$tool" in
Agent|Task)
  printf '%s' "$in" | jq -c '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",
    updatedInput:(.tool_input + {prompt:"JOB: /probe/job-42.json\n\nReply with the single word FIRST."})}}' ;;
SendMessage)
  if printf '%s' "$in" | jq -e '.tool_input.message | test("DENYME")' >/dev/null; then
    jq -nc '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:"probe: no JOB line"}}'
  else
    printf '%s' "$in" | jq -c '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",
      updatedInput:(.tool_input + {message:"JOB: /probe/job-43.json\n\nReply with the single word SECOND."})}}'
  fi ;;
esac
exit 0
