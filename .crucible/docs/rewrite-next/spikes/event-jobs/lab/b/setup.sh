#!/bin/sh
# Spike Stage B: make one fresh sandbox for a headless case.
# usage: setup.sh DIR   -> DIR/repo (git, one commit), DIR/effort, DIR/repo/.claude (agents, settings)
set -eu
LAB=$(cd "$(dirname "$0")/.." && pwd)
D=$1; mkdir -p "$D/effort" "$D/repo/.claude/agents"
D=$(cd "$D" && pwd)
cd "$D/repo"
git init -q . && printf 'hello\n' > a.txt && git add a.txt && git -c user.name=lab -c user.email=lab@lab commit -qm base
printf '.claude/\n' > .git/info/exclude
cp "$LAB"/agents/*.md .claude/agents/
h() { printf '{"type":"command","command":"EFFORT=%s sh %s/%s"}' "$D/effort" "$LAB" "$1"; }
cat > .claude/settings.json <<EOF
{ "env": { "EFFORT": "$D/effort", "LAB": "$LAB" },
  "hooks": {
    "PreToolUse": [
      { "matcher": "Agent|Task", "hooks": [ $(h pre-agent.sh) ] },
      { "matcher": "SendMessage", "hooks": [ $(h pre-send.sh) ] },
      { "matcher": "*", "hooks": [ $(h scope.sh) ] } ],
    "PostToolUse": [
      { "matcher": "Agent|Task", "hooks": [ $(h post-agent.sh) ] },
      { "matcher": "SendMessage", "hooks": [ $(h post-send.sh) ] } ],
    "SubagentStop": [ { "hooks": [ $(h agent-stop.sh) ] } ]
  } }
EOF
jq . .claude/settings.json >/dev/null
echo "$D"
