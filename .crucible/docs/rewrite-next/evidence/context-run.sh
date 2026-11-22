# Evidence run for crucible-context's scripts.
C=/Users/cordona/IdeaProjects/cordona/claude-code-crucible/new-rewrite/framework/core/main-thread
X=$C/crucible-context/scripts; E=$C/crucible-effort/scripts; SA=$C/crucible-spec/scripts/spec-approve.sh
. /Users/cordona/IdeaProjects/cordona/claude-code-crucible/.crucible/docs/rewrite-next/evidence/lib-decide.sh
S="/private/tmp/claude-501/-Users-cordona-IdeaProjects-cordona-claude-code-crucible/480d0359-cf0d-4c14-a59e-2a72be5dba4f/scratchpad/context test"; rm -rf "$S"; mkdir -p "$S/repo"
export CRUCIBLE_HOME="$S/space" CLAUDE_CONFIG_DIR="$S/cfg" CLAUDE_CODE_SESSION_ID=sess-c
cd /
F=$(sh $E/effort-start.sh --name context)
show() { echo "$1" | sed "s|$X/||g;s|$C/||g;s|$F|<F>|g;s|$S|<S>|g"; }
run() { show "\$ $*"; out=$("$@" 2>&1); e=$?; show "$out" | sed 's|^|    |'; echo "    [exit $e]"; }
fp() { sh $X/context-fingerprint.sh --effort "$F" | sed -n 's/FINGERPRINT: //p'; }
printf 'retention: 90 days\n' >"$S/repo/rules.md"

echo "--- nothing yet"
run sh $X/context-status.sh --effort "$F"
run sh $X/context-fingerprint.sh --effort "$F"

echo "--- the path rule"
for p in "$S/repo/rules.md" "$S/repo/.env" "$S/repo/.env.local" "$S/repo/.git/config" "$S/repo/id_rsa" \
	"$S/repo/CLAUDE.md" "$S/repo/.claude/settings.json" "$S/repo/.claude/settings.local.json" "$S/cfg/settings.json" "$S/cfg/agents/a.md" "$S/repo/skills/x/SKILL.md" "relative/x.md" "$S/repo/../repo/rules.md" "$S/repo/it's.md"; do
	run sh $X/context-path-check.sh "$p"
done

echo "--- add: a path, a link, the same again, refusals"
run sh $X/context-add.sh --effort "$F" --path "$S/repo/rules.md" --why 'the retention rule the prune must follow'
run sh $X/context-add.sh --effort "$F" --link 'https://example.com/runbook' --why 'how the nightly job is run'
run sh $X/context-add.sh --effort "$F" --path "$S/repo/rules.md" --why 'again'
run sh $X/context-add.sh --effort "$F" --path "$S/repo/missing.md" --why 'x'
run sh $X/context-add.sh --effort "$F" --path "$S/repo/rules.md" --why ''
run sh $X/context-add.sh --effort "$F" --link 'https://example.com/$(id)' --why 'x'
run sh $X/context-add.sh --effort "$F" --path "$F/context" --why 'x'
run sh $X/context-status.sh --effort "$F"

echo "--- the docs folder: a note, a name it may not hold, too much"
DOCS=$(sh $X/context-docs.sh --effort "$F"); show "    docs: $DOCS"
printf 'We keep 90 days: the DBA confirmed it.\n' >"$DOCS/decisions.md"
run sh $X/context-fingerprint.sh --effort "$F"
printf 'x\n' >"$DOCS/notes.txt"
mkdir -p "$F/spec"; printf '## Goal\nPrune nightly\n## Done when\nNothing older than 90 days\n## Scope\nIn: the job\n## Constraints\nNo live data deleted\n## Open points\nNone\n' >"$F/spec/1.md"
decide "$F" spec-approval "$(shasum -a 256 "$F/spec/1.md" | cut -d ' ' -f 1)" "$F/spec/1.md" "Approve (Recommended)" | tail -n 1 | sed 's|^|    gate: |'
run sh $SA --effort "$F" --draft "$F/spec/1.md"
run sh $X/context-fingerprint.sh --effort "$F"
rm "$DOCS/notes.txt"; head -c 1100000 /dev/zero | tr '\0' 'a' >"$DOCS/big.md"
run sh $X/context-fingerprint.sh --effort "$F"
rm "$DOCS/big.md"

echo "--- cut v1: a stale fingerprint is refused, the pinned one cuts"
run sh $X/context-cut.sh --effort "$F" --expect 0000000000000000000000000000000000000000000000000000000000000000
FP1=$(fp); run sh $X/context-cut.sh --effort "$F" --expect "$FP1"
V1=$(ls "$F"/events/*context.cut.json | tail -1)
jq -c '.body' "$V1" | show "$(cat)" | sed 's|^|    body: |'
ls -l "$F/context/v1" | awk 'NR>1 {print "    " $1 " " $NF}'
run sh $X/context-status.sh --effort "$F"
echo "--- the same cut again: nothing new, the latest version, nothing written"
n=$(ls "$F"/events | wc -l); run sh $X/context-cut.sh --effort "$F" --expect "$FP1"; [ "$(ls "$F"/events | wc -l)" = "$n" ] && echo "    no event written"
run sh $X/context-verify.sh --effort "$F" --file "$V1"

echo "--- after the cut: pending changes go to v2; drop, retire, undo"
run sh $X/context-add.sh --effort "$F" --link 'https://example.com/dashboard' --why 'where the runs of the job show'
run sh $X/context-add.sh --effort "$F" --path "$S/repo/rules.md" --why 'already there'
run sh $X/context-drop.sh --effort "$F" --link 'https://example.com/dashboard' --why 'the human: not needed'
run sh $X/context-drop.sh --effort "$F" --link 'https://example.com/runbook' --why 'the human: outdated'
run sh $X/context-drop.sh --effort "$F" --link 'https://example.com/runbook' --why 'again'
run sh $X/context-add.sh --effort "$F" --link 'https://example.com/runbook' --why 'how the nightly job is run'
run sh $X/context-drop.sh --effort "$F" --link 'https://example.com/runbook' --why 'the human: outdated after all'
run sh $X/context-drop.sh --effort "$F" --link 'https://example.com/never-added' --why 'x'
run sh $X/context-cut.sh --effort "$F" --expect "$FP1"
FP2=$(fp); run sh $X/context-cut.sh --effort "$F" --expect "$FP2"
V2=$(ls "$F"/events/*context.cut.json | tail -1)
jq -c '.body' "$V2" | show "$(cat)" | sed 's|^|    body: |'

echo "--- verify: the older version is stale, the newest is usable, tampering is caught"
run sh $X/context-verify.sh --effort "$F" --file "$V1"
run sh $X/context-verify.sh --effort "$F" --file "$V2"
run sh $X/context-verify.sh --effort "$F" --file "$S/repo/rules.md"
chmod u+w "$F/context/v1/decisions.md"; echo 'edited' >>"$F/context/v1/decisions.md"
run sh $X/context-verify.sh --effort "$F" --file "$V2"

echo "--- a paused effort: writes refused, reads still work"
run sh $E/effort-pause.sh --effort "$F" --words 'break'
run sh $X/context-add.sh --effort "$F" --link 'https://example.com/x' --why 'x'
run sh $X/context-docs.sh --effort "$F"
run sh $X/context-status.sh --effort "$F"
