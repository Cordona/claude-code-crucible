#!/bin/sh
# Spike probe: does a fact given by main-stop.sh on an unheld Stop reach main,
# and does main show it? One headless run in a fresh sandbox made like
# b/setup.sh, with main-stop.sh on Stop; the effort holds one finished build
# with no review; main is only told to say hello and stop.
# usage: probe-fact.sh [N]    evidence in evidence/probe-fact/<N>
set -eu
C=$(cd "$(dirname "$0")" && pwd); LAB=$(dirname "$C"); SPIKE=$(dirname "$LAB")
n=${1:-1}
D=/Users/Shared/crucible-sandbox/event-jobs/probe-fact-$n
OUT=$SPIKE/evidence/probe-fact/$n
[ ! -e "$D" ] || { echo "probe-fact: $D exists; give another N" >&2; exit 1; }
mkdir -p "$OUT"
sh "$LAB/b/setup.sh" "$D" >/dev/null
EFFORT=$D/effort; export EFFORT
s=$D/repo/.claude/settings.json
jq --arg c "EFFORT=$EFFORT sh $LAB/main-stop.sh" '.hooks.Stop = [{hooks: [{type: "command", command: $c}]}]' "$s" > "$s.tmp" && mv "$s.tmp" "$s"
# the fixture: one build, submitted, with no round over it
unset CLAUDE_CODE_SESSION_ID
g=$("$LAB/ev.sh" --session probe --type gate.answered --body '{"step":"build","answer":"yes, build it"}')
j=$("$LAB/ev.sh" --session probe --type job.dispatched --body "{\"kind\":\"build\",\"target\":null,\"tree\":\"$D/repo\",\"report\":\"$EFFORT/reports/b.json\",\"agent_type\":\"lab-builder\",\"delivery\":\"cold\",\"hot_agent\":null,\"slot\":null,\"replaces\":null,\"approval\":$g,\"payload\":{\"task\":\"write a.txt\"},\"act\":{}}")
"$LAB/ev.sh" --session probe --type job.assigned --job "$j" --agent probe-builder --body '{"name":"build-probe","tool_use_id":"tu"}' >/dev/null
"$LAB/ev.sh" --session probe --type build.submitted --root self --job "$j" --agent probe-builder \
	--body "{\"commit\":\"$(git -C "$D/repo" rev-parse HEAD)\",\"files\":[\"a.txt\"],\"report\":\"$EFFORT/reports/b.json\",\"answers\":{},\"declines\":{}}" >/dev/null

(cd "$D/repo" && claude -p "Say hello, then stop." --permission-mode bypassPermissions --output-format stream-json --verbose) > "$OUT/main.jsonl" 2> "$OUT/main.err" || true
cp -R "$EFFORT/events" "$OUT/events"; cp -R "$EFFORT/hook-log" "$OUT/hook-log" 2>/dev/null || true
cp "$EFFORT/stops/main-stop.out" "$OUT/" 2>/dev/null || true
said=$(jq -r 'select(.type == "result") | .result // ""' "$OUT/main.jsonl")
{
	echo "stops run: $(ls "$OUT/hook-log" 2>/dev/null | grep -c '^main-stop-' || true)"
	echo "fact given: $(grep -c 'fact: ' "$OUT/main-stop.out" 2>/dev/null || echo 0)"
	echo "assistant turns: $(jq -c 'select(.type == "assistant")' "$OUT/main.jsonl" | wc -l | tr -d ' ')"
	echo "fact in the reply: $(printf '%s' "$said" | grep -Eqi 'no review|build [0-9]+|offer' && echo yes || echo no)"
	echo "reply: $said"
} > "$OUT/result.txt"
cat "$OUT/result.txt"
