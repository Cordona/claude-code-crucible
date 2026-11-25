export EFFORT=/private/tmp/claude-501/-Users-cordona-IdeaProjects-cordona-claude-code-crucible/480d0359-cf0d-4c14-a59e-2a72be5dba4f/scratchpad/ej-long/effort; rm -rf /private/tmp/claude-501/-Users-cordona-IdeaProjects-cordona-claude-code-crucible/480d0359-cf0d-4c14-a59e-2a72be5dba4f/scratchpad/ej-long; mkdir -p $EFFORT
start=$(date +%s)
for i in $(seq 500); do
  g=$(/Users/cordona/IdeaProjects/cordona/claude-code-crucible/.crucible/docs/rewrite-next/spikes/event-jobs/lab/ev.sh --session S1 --by long --type gate.answered --body '{"step":"build","answer":"yes"}')
  j=$(/Users/cordona/IdeaProjects/cordona/claude-code-crucible/.crucible/docs/rewrite-next/spikes/event-jobs/lab/ev.sh --session S1 --by long --type job.dispatched --body "{\"kind\":\"build\",\"target\":null,\"tree\":\"/t/$i\",\"report\":\"/r/$i\",\"agent_type\":\"lab-builder\",\"delivery\":\"cold\",\"hot_agent\":null,\"slot\":null,\"replaces\":null,\"approval\":$g,\"payload\":{\"task\":\"t\"},\"act\":{}}")
  /Users/cordona/IdeaProjects/cordona/claude-code-crucible/.crucible/docs/rewrite-next/spikes/event-jobs/lab/ev.sh --session S1 --by long --type job.assigned --job $j --agent a$i --body '{"name":"n","tool_use_id":"u"}' >/dev/null
  /Users/cordona/IdeaProjects/cordona/claude-code-crucible/.crucible/docs/rewrite-next/spikes/event-jobs/lab/ev.sh --session S1 --by long --type build.submitted --root self --job $j --agent a$i --body '{"commit":"c","files":["f"],"report":"/r","answers":{},"declines":{}}' >/dev/null
  [ $((i % 100)) -eq 0 ] && echo "$((i*4)) events at $(($(date +%s)-start)) s"
done
t0=$(date +%s); /Users/cordona/IdeaProjects/cordona/claude-code-crucible/.crucible/docs/rewrite-next/spikes/event-jobs/lab/ev.sh --session S1 --by long --type gate.answered --body '{"step":"build","answer":"yes"}' >/dev/null; t1=$(date +%s); echo "one write at 2001 events: $((t1-t0)) s"
t0=$(date +%s); sh /Users/cordona/IdeaProjects/cordona/claude-code-crucible/.crucible/docs/rewrite-next/spikes/event-jobs/lab/owes.sh --effort $EFFORT --session S1 | wc -l; t1=$(date +%s); echo "owes.sh at 2001 events: $((t1-t0)) s"
