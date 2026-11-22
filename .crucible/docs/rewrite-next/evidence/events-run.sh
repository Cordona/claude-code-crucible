# Evidence run for crucible-events: the one reader, and the writer finding
# each type's one rule itself.
C=/Users/cordona/IdeaProjects/cordona/claude-code-crucible/new-rewrite/framework/core/main-thread
V=$C/crucible-events/scripts; E=$C/crucible-effort/scripts
S="/private/tmp/claude-501/-Users-cordona-IdeaProjects-cordona-claude-code-crucible/480d0359-cf0d-4c14-a59e-2a72be5dba4f/scratchpad/events test"; rm -rf "$S"; mkdir -p "$S"
export CRUCIBLE_HOME="$S/space" CLAUDE_CONFIG_DIR="$S/cfg" CLAUDE_CODE_SESSION_ID=sess-v
cd /
show() { echo "$1" | sed "s|$S/main-thread-copy/|<copy>/|g;s|$C/||g;s|$S|<S>|g;s|[0-9]\{8\}T[0-9]\{6\}-[0-9a-f]\{4\}|<id>|g"; }
run() { show "\$ $*"; out=$("$@" 2>&1); e=$?; show "$out" | sed 's|^|    |'; echo "    [exit $e]"; }
F=$(sh $E/effort-start.sh --name events); show "    started: $F"
run sh $E/effort-pause.sh --effort "$F" --words 'a'; run sh $E/effort-resume.sh --effort "$F" --words 'b'

echo "=== the reader"
run sh $V/events-read.sh --effort "$F" --paths
sh $V/events-read.sh --effort "$F" | jq -c 'map({seq, type})' | sed 's|^|    array: |'
sh $V/events-read.sh --effort "$F" --type effort.paused | jq -c 'map(.seq)' | sed 's|^|    effort.paused: |'
sh $V/events-read.sh --effort "$F" --type 'effort.*' | jq -c 'map(.seq)' | sed 's|^|    effort.*: |'
sh $V/events-read.sh --effort "$F" --type grill.ended | sed 's|^|    none of a type: |'
run sh $V/events-read.sh --effort "$F" --type grill.ended --paths
F0="$S/space/efforts/empty"; mkdir -p "$F0/events"
sh $V/events-read.sh --effort "$F0" | sed 's|^|    no events: |'
run sh $V/events-read.sh --effort relative
run sh $V/events-read.sh --effort "$S"
run sh $V/events-read.sh --effort "$F" --type 'Effort.paused'
echo "=== the writer finds the rule itself"
printf '{"words":"through the found rule"}' >"$S/b.json"
run sh $V/event-write.sh --effort "$F" --type effort.paused --by evidence --body-file "$S/b.json"
run sh $V/event-write.sh --effort "$F" --type nothing.here --by evidence --body-file "$S/b.json"
run sh $V/event-write.sh --effort "$F" --type effort.paused --by evidence --rules /tmp --body-file "$S/b.json"
echo "--- two rules for one type, in a scratch copy: refused, naming both"
CP="$S/main-thread-copy"; cp -R "$C" "$CP"
mkdir -p "$CP/zz-second/events"; cp "$CP/crucible-effort/events/effort.resumed.jq" "$CP/zz-second/events/"
run sh "$CP/crucible-events/scripts/event-write.sh" --effort "$F" --type effort.resumed --by evidence --body-file "$S/b.json"
[ ! -e "$C/zz-second" ] && echo "    the repository tree is untouched"
echo "--- the log after all of it"
sh $V/events-read.sh --effort "$F" | jq -r '.[] | "    \(.seq) \(.type)"'
