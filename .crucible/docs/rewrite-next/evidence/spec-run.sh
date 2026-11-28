# Evidence run for crucible-spec: approval at a recorded gate, the approved
# draft sealed in place, independent of the context.
C=/Users/cordona/IdeaProjects/cordona/claude-code-crucible/new-rewrite/framework/core/main-thread
SA=$C/crucible-spec/scripts/main/spec-approve.sh; X=$C/crucible-context/scripts; E=$C/crucible-effort/scripts; V=$C/crucible-events/scripts
. /Users/cordona/IdeaProjects/cordona/claude-code-crucible/.crucible/docs/rewrite-next/evidence/lib-decide.sh
S="/private/tmp/claude-501/-Users-cordona-IdeaProjects-cordona-claude-code-crucible/480d0359-cf0d-4c14-a59e-2a72be5dba4f/scratchpad/spec test"; rm -rf "$S"; mkdir -p "$S"
export CRUCIBLE_HOME="$S/space" CLAUDE_CONFIG_DIR="$S/cfg" CLAUDE_CODE_SESSION_ID=sess-s
cd /
F=$(sh $E/main/effort-start.sh --name spec)
G=$(sh $E/main/effort-start.sh --name other)
show() { echo "$1" | sed "s|$SA|spec-approve.sh|g;s|$X/||g;s|$C/||g;s|${H:-@@}|<H>|g;s|$G|<G>|g;s|$F|<F>|g;s|$S|<S>|g"; }
run() { show "\$ $*"; out=$("$@" 2>&1); e=$?; show "$out" | sed 's|^|    |'; echo "    [exit $e]"; }
sha() { shasum -a 256 "$1" | cut -d ' ' -f 1; }
mkdir -p "$F/spec"; D1="$F/spec/1.md"
printf '## Goal\nPrune old data nightly\n## Done when\nData older than 90 days is gone\n## Scope\nIn: the prune job. Out: archiving\n## Constraints\nNever delete live data\n## Open points\nNone\n' > "$D1"

echo "--- no context at all, and no answer yet: refused for the answer only"
run sh $V/internal/events-read.sh --effort "$F" --type context.cut --paths
run sh $SA --effort "$F" --draft "$D1"
echo "--- yes, then no: refused"
decide "$F" spec-approval "$(sha "$D1")" "$D1" "Approve (Recommended)"; decide "$F" spec-approval "$(sha "$D1")" "$D1" "Change it"
run sh $SA --effort "$F" --draft "$D1"
echo "--- approved through the gate (the draft is the card), with no context"
decide "$F" spec-approval "$(sha "$D1")" "$D1" "Approve (Recommended)"
run sh $SA --effort "$F" --draft "$D1"
sh $V/internal/events-read.sh --effort "$F" --type spec.approved | jq -c '.[-1].body' | show "$(cat)" | sed 's|^|    body: |'
echo "    the approved draft: $(ls -l "$D1" | cut -c1-10)"
[ ! -e "$F/context/draft/docs/spec.md" ] && echo "    nothing written into the context"
echo "--- the same yes again: refused"
run sh $SA --effort "$F" --draft "$D1"
echo "--- an approved spec can't be edited in place"
[ -w "$D1" ] && echo "    WRITABLE: the approved spec can be edited" || echo "    the approved spec is not writable"
echo "--- a revision is a new file, approved again; the newest spec.approved is the spec"
D2="$F/spec/2.md"; sed 's/90 days/30 days/' "$D1" > "$D2"
run sh $SA --effort "$F" --draft "$D2"
decide "$F" spec-approval "$(sha "$D2")" "$D2" "Approve (Recommended)"
run sh $SA --effort "$F" --draft "$D2"
sh $V/internal/events-read.sh --effort "$F" --type spec.approved | jq -r '.[-1].body.path' | show "$(cat)" | sed 's|^|    newest spec: |'
echo "--- where the draft may be"
cp "$D2" "$S/loose.md"; decide "$F" spec-approval "$(sha "$S/loose.md")" "$S/loose.md" "Approve (Recommended)" >/dev/null
run sh $SA --effort "$F" --draft "$S/loose.md"
mkdir -p "$G/spec"; printf '## Goal\nSomething else\n' >"$G/spec/x.md"
decide "$F" spec-approval "$(sha "$G/spec/x.md")" "$G/spec/x.md" "Approve (Recommended)" >/dev/null
run sh $SA --effort "$F" --draft "$G/spec/x.md"
mkdir -p "$F/spec/sub"; cp "$D2" "$F/spec/sub/y.md"
run sh $SA --effort "$F" --draft "$F/spec/sub/y.md"
echo "--- bad drafts"
printf '\000\001' > "$F/spec/bin"; run sh $SA --effort "$F" --draft "$F/spec/bin"
run sh $SA --effort "$F" --draft "$F/spec/missing.md"
head -c 1048600 /dev/zero | tr '\0' 'a' > "$F/spec/big.md"; run sh $SA --effort "$F" --draft "$F/spec/big.md"
echo "--- the context is independent: it cuts with no spec, and refuses a stray spec.md"
printf 'Context to cut\n' >"$S/card.md"
FP=$(sh $X/main/context-fingerprint.sh --effort "$F" | sed -n 's/FINGERPRINT: //p')
decide "$F" context-done "$FP" "$S/card.md" "Approve (Recommended)" >/dev/null
run sh $X/main/context-cut.sh --effort "$F"
DOCS=$(sh $X/main/context-docs.sh --effort "$F"); cp "$D2" "$DOCS/spec.md"
run sh $X/main/context-fingerprint.sh --effort "$F"
rm -f "$DOCS/spec.md"
echo "--- a paused effort: refused"
D3="$F/spec/3.md"; echo "## Goal" > "$D3"; decide "$F" spec-approval "$(sha "$D3")" "$D3" "Approve (Recommended)" >/dev/null
run sh $E/main/effort-pause.sh --effort "$F" --words later
run sh $SA --effort "$F" --draft "$D3"
echo "--- the events lock held: refused with exit 6, the draft already read-only, no spec.approved; the rerun approves"
H=$(sh $E/main/effort-start.sh --name locked); mkdir -p "$H/spec"; cp "$D2" "$H/spec/1.md"; chmod 644 "$H/spec/1.md"
decide "$H" spec-approval "$(sha "$H/spec/1.md")" "$H/spec/1.md" "Approve (Recommended)" >/dev/null
mkdir "$H/events/.lock"; echo $$ >"$H/events/.lock/pid"
run sh $SA --effort "$H" --draft "$H/spec/1.md"
rm -rf "$H/events/.lock"
echo "    spec.approved events: $(sh $V/internal/events-read.sh --effort "$H" --type spec.approved | jq length); the draft: $(ls -l "$H/spec/1.md" | cut -c1-10)"
run sh $SA --effort "$H" --draft "$H/spec/1.md"
