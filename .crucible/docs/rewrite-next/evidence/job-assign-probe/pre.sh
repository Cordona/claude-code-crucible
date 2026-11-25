#!/bin/sh
in=$(cat); d=$(dirname "$0")
printf '%s\n' "$in" > "$(mktemp "$d/logs/pre-XXXXXX")"
tool=$(printf '%s' "$in" | jq -r .tool_name)
if [ "$tool" = Agent ] || [ "$tool" = Task ]; then
  printf '%s' "$in" | jq -c '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",
    updatedInput:(.tool_input + {prompt:("JOB: /probe/job-42.json\n\nReply with the single word DONE after running: ls")})}}'
fi
exit 0
