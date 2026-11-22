# Evidence run for crucible-spec and the context's approved-spec check.
C=/Users/cordona/IdeaProjects/cordona/claude-code-crucible/new-rewrite/framework/core/main-thread
SA=$C/crucible-spec/scripts/spec-approve.sh; X=$C/crucible-context/scripts; E=$C/crucible-effort/scripts
. /Users/cordona/IdeaProjects/cordona/claude-code-crucible/.crucible/docs/rewrite-next/evidence/lib-decide.sh
S="/private/tmp/claude-501/-Users-cordona-IdeaProjects-cordona-claude-code-crucible/480d0359-cf0d-4c14-a59e-2a72be5dba4f/scratchpad/spec test"; rm -rf "$S"; mkdir -p "$S"
export CRUCIBLE_HOME="$S/space" CLAUDE_CONFIG_DIR="$S/cfg" CLAUDE_CODE_SESSION_ID=sess-s
F=$(sh $E/effort-start.sh --name spec)
run() { echo "\$ $(echo "$*" | sed "s|$SA|spec-approve.sh|g;s|$X/||g;s|$F|<F>|g;s|$S|<S>|g")"; out=$("$@" 2>&1); e=$?; echo "$out" | sed "s|$F|<F>|g;s|$S|<S>|g;s|^|    |"; echo "    [exit $e]"; }
sha() { shasum -a 256 "$1" | cut -d ' ' -f 1; }
mkdir -p "$F/spec"; D1="$F/spec/1.md"
printf '## Goal\nPrune old data nightly\n## Done when\nData older than 90 days is gone\n## Scope\nIn: the prune job. Out: archiving\n## Constraints\nNever delete live data\n## Open points\nNone\n' > "$D1"
echo "--- no answer yet: refused"
run sh $SA --effort "$F" --draft "$D1"
echo "--- a draft saved as spec.md by hand is never cut"
DOCS=$(sh $X/context-docs.sh --effort "$F"); cp "$D1" "$DOCS/spec.md"
run sh $X/context-fingerprint.sh --effort "$F"
rm "$DOCS/spec.md"
echo "--- yes, then no: refused"
decide "$F" spec-approval "$(sha "$D1")" "$D1" "Approve (Recommended)"; decide "$F" spec-approval "$(sha "$D1")" "$D1" "Change it"
run sh $SA --effort "$F" --draft "$D1"
echo "--- approved through the gate (the draft is the card)"
decide "$F" spec-approval "$(sha "$D1")" "$D1" "Approve (Recommended)"
run sh $SA --effort "$F" --draft "$D1"
cmp -s "$D1" "$DOCS/spec.md" && echo "    spec.md == draft 1"
jq -c '.body' "$(ls "$F"/events/*spec.approved.json | tail -1)"
echo "--- the same yes again: refused"
run sh $SA --effort "$F" --draft "$D1"
echo "--- the cut now takes it"
FP=$(sh $X/context-fingerprint.sh --effort "$F" | sed -n 's/FINGERPRINT: //p'); run sh $X/context-cut.sh --effort "$F" --expect "$FP"
echo "--- spec.md edited after approval, in a new draft docs folder: refused"
DOCS=$(sh $X/context-docs.sh --effort "$F"); cp "$D1" "$DOCS/spec.md"; echo "extra line" >> "$DOCS/spec.md"
run sh $X/context-fingerprint.sh --effort "$F"
rm "$DOCS/spec.md"
echo "--- a revision is a new file, approved again, then cut as v2"
D2="$F/spec/2.md"; sed 's/90 days/30 days/' "$D1" > "$D2"
run sh $SA --effort "$F" --draft "$D2"
decide "$F" spec-approval "$(sha "$D2")" "$D2" "Approve (Recommended)"
run sh $SA --effort "$F" --draft "$D2"
FP=$(sh $X/context-fingerprint.sh --effort "$F" | sed -n 's/FINGERPRINT: //p'); run sh $X/context-cut.sh --effort "$F" --expect "$FP"
V2=$(ls "$F"/events/*context.cut.json | tail -1); jq -r '.body.spec' "$V2" | sed "s|$F|<F>|"; grep -q '30 days' "$(jq -r '.body.spec' "$V2")" && echo "    v2's spec is draft 2"
echo "--- a context change with no new spec still cuts (the sealed spec is the approved one)"
sh $X/context-add.sh --effort "$F" --link "https://example.com/t/1" --why "the ticket" >/dev/null
FP=$(sh $X/context-fingerprint.sh --effort "$F" | sed -n 's/FINGERPRINT: //p'); run sh $X/context-cut.sh --effort "$F" --expect "$FP"
echo "--- an earlier approved draft put back by hand, after a later one was approved: refused"
DOCS=$(sh $X/context-docs.sh --effort "$F"); cp "$D1" "$DOCS/spec.md"
run sh $X/context-fingerprint.sh --effort "$F"
echo "--- the cut called directly, with a made-up fingerprint: the same refusal at the choke point"
run sh $X/context-cut.sh --effort "$F" --expect 0000000000000000000000000000000000000000000000000000000000000000
rm "$DOCS/spec.md"
echo "--- bad drafts"
printf '\000\001' > "$S/bin"; run sh $SA --effort "$F" --draft "$S/bin"
run sh $SA --effort "$F" --draft "$S/missing.md"
head -c 1048600 /dev/zero | tr '\0' 'a' > "$S/big.md"; run sh $SA --effort "$F" --draft "$S/big.md"
echo "--- paused effort"
D3="$F/spec/3.md"; echo "## Goal" > "$D3"; decide "$F" spec-approval "$(sha "$D3")" "$D3" "Approve (Recommended)"
sh $E/effort-pause.sh --effort "$F" --words later >/dev/null
run sh $SA --effort "$F" --draft "$D3"
