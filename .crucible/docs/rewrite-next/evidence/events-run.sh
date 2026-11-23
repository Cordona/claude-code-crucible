# Evidence run for crucible-events: the one reader, and the writer finding
# each type's one rule itself.
C=/Users/cordona/IdeaProjects/cordona/claude-code-crucible/new-rewrite/framework/core/main-thread
V=$C/crucible-events/scripts; E=$C/crucible-effort/scripts
S="/private/tmp/claude-501/-Users-cordona-IdeaProjects-cordona-claude-code-crucible/480d0359-cf0d-4c14-a59e-2a72be5dba4f/scratchpad/events test"; rm -rf "$S"; mkdir -p "$S"
export CRUCIBLE_HOME="$S/space" CLAUDE_CONFIG_DIR="$S/cfg" CLAUDE_CODE_SESSION_ID=sess-v
cd /
show() { echo "$1" | sed "s|$S/main-thread-copy/|<copy>/|g;s|$C/||g;s|$S|<S>|g;s|[0-9]\{8\}T[0-9]\{6\}-[0-9a-f]\{4\}|<id>|g"; }
run() { show "\$ $*"; out=$("$@" 2>&1); e=$?; show "$out" | sed 's|^|    |'; echo "    [exit $e]"; }
F=$(sh $E/main/effort-start.sh --name events); show "    started: $F"
run sh $E/main/effort-pause.sh --effort "$F" --words 'a'; run sh $E/main/effort-resume.sh --effort "$F" --words 'b'

echo "=== the reader"
run sh $V/internal/events-read.sh --effort "$F" --paths
sh $V/internal/events-read.sh --effort "$F" | jq -c 'map({seq, type})' | sed 's|^|    array: |'
sh $V/internal/events-read.sh --effort "$F" --type effort.paused | jq -c 'map(.seq)' | sed 's|^|    effort.paused: |'
sh $V/internal/events-read.sh --effort "$F" --type 'effort.*' | jq -c 'map(.seq)' | sed 's|^|    effort.*: |'
sh $V/internal/events-read.sh --effort "$F" --type grill.ended | sed 's|^|    none of a type: |'
run sh $V/internal/events-read.sh --effort "$F" --type grill.ended --paths
F0="$S/space/efforts/empty"; mkdir -p "$F0/events"
sh $V/internal/events-read.sh --effort "$F0" | sed 's|^|    no events: |'
rm -rf "$F0"
run sh $V/internal/events-read.sh --effort relative
run sh $V/internal/events-read.sh --effort "$S"
run sh $V/internal/events-read.sh --effort "$F" --type 'Effort.paused'
echo "=== the writer finds the rule itself"
printf '{"words":"through the found rule"}' >"$S/b.json"
run sh $V/internal/event-write.sh --effort "$F" --type effort.paused --by evidence --body-file "$S/b.json"
run sh $V/internal/event-write.sh --effort "$F" --type nothing.here --by evidence --body-file "$S/b.json"
run sh $V/internal/event-write.sh --effort "$F" --type effort.paused --by evidence --rules /tmp --body-file "$S/b.json"
echo "--- two rules for one type, in a scratch copy: refused, naming both"
CP="$S/main-thread-copy"; cp -R "$C" "$CP"
mkdir -p "$CP/zz-second/events"; cp "$CP/crucible-effort/events/effort.resumed.jq" "$CP/zz-second/events/"
run sh "$CP/crucible-events/scripts/internal/event-write.sh" --effort "$F" --type effort.resumed --by evidence --body-file "$S/b.json"
[ ! -e "$C/zz-second" ] && echo "    the repository tree is untouched"
echo "--- the log after all of it"
sh $V/internal/events-read.sh --effort "$F" | jq -r '.[] | "    \(.seq) \(.type)"'

echo "=== a damaged log: the reader prints nothing, and its readers refuse"
. /Users/cordona/IdeaProjects/cordona/claude-code-crucible/.crucible/docs/rewrite-next/evidence/lib-decide.sh
GA=$C/crucible-gate/scripts/internal/gate-answer.sh; SA=$C/crucible-spec/scripts/main/spec-approve.sh; G=$C/crucible-grill/scripts
D=$(sh $E/main/effort-start.sh --name damaged); show "    started: $D"
printf 'Approve?\n' >"$S/card.md"
decide "$D" spec-approval abc "$S/card.md" "Approve (Recommended)"
mkdir -p "$D/spec"; printf '## Goal\nA spec\n' >"$D/spec/1.md"
decide "$D" spec-approval "$(shasum -a 256 "$D/spec/1.md" | cut -d ' ' -f 1)" "$S/card.md" "Approve (Recommended)"
sh $SA --effort "$D" --draft "$D/spec/1.md" >/dev/null
Q=$(sh $G/main/grill-new.sh --effort "$D" --topic "a topic")
sh $G/main/grill-add.sh --grill "$Q" --question "Why?" --recommendation r --reason w >/dev/null
sh $G/main/grill-answer.sh --grill "$Q" --id q1 --text "Because" >/dev/null
sh $G/main/grill-end.sh --grill "$Q" >/dev/null
ls "$D/events" | sed 's|^|    |'
event() { ls "$D"/events/*-"$1".json; }
echo "--- the healthy log, as each reader gives it"
run sh $GA --effort "$D" --record spec-approval --subject abc
run sh $E/main/effort-state.sh --effort "$D"
echo "--- a gate.answered event can't be read"
chmod 000 "$(event gate.answered | head -n 1)"
run sh $V/internal/events-read.sh --effort "$D"
sh $V/internal/events-read.sh --effort "$D" 2>/dev/null | wc -c | sed 's|^ *|    bytes on stdout: |'
run sh $V/internal/events-read.sh --effort "$D" --type gate.answered
sh $V/internal/events-read.sh --effort "$D" --paths | wc -l | sed 's|^ *|    --paths still lists: |'
run sh $GA --effort "$D" --record spec-approval --subject abc
chmod 444 "$(event gate.answered | head -n 1)"
echo "--- a spec.approved event can't be read: the same yes is not used again"
chmod 000 "$(event spec.approved)"
run sh $SA --effort "$D" --draft "$D/spec/1.md"
chmod 444 "$(event spec.approved)"
ls "$D"/events/*-spec.approved.json | wc -l | sed 's|^ *|    spec.approved events: |'
echo "--- a grill.ended event can't be read"
chmod 000 "$(event grill.ended)"
run sh $G/main/grill-list.sh --effort "$D"
run sh $G/main/grill-new.sh --effort "$D" --topic "another"
chmod 444 "$(event grill.ended)"
echo "--- an effort event is not valid JSON"
opened=$(event effort.opened); cp "$opened" "$S/opened.json"
chmod 644 "$opened"; printf '{"type": "effort.opened", "seq": 1,' >"$opened"
run sh $V/internal/events-read.sh --effort "$D" --type 'effort.*'
run sh $E/main/effort-state.sh --effort "$D"
run sh $E/main/effort-status.sh --effort "$D"
echo "--- effort-list.sh over the damaged effort and the healthy one: the healthy one listed, the damaged one named, exit 3"
run sh $E/main/effort-list.sh
cp "$S/opened.json" "$opened"; chmod 444 "$opened"
echo "--- repaired: every reader reads it again"
run sh $E/main/effort-state.sh --effort "$D"
run sh $GA --effort "$D" --record spec-approval --subject abc
run sh $G/main/grill-list.sh --effort "$D"
echo "--- the writer: a damaged log is refused, nothing written"
chmod 000 "$(event gate.answered | head -n 1)"
n=$(ls "$D/events" | wc -l)
printf '{"words":"over a damaged log"}' >"$S/b.json"
run sh $V/internal/event-write.sh --effort "$D" --type effort.paused --by evidence --body-file "$S/b.json"
[ "$(ls "$D/events" | wc -l)" = "$n" ] && echo "    no event written"
chmod 444 "$(event gate.answered | head -n 1)"
run sh $V/internal/event-write.sh --effort "$D" --type effort.paused --by evidence --body-file "$S/b.json"
