# Evidence run for crucible-effort.
E=/Users/cordona/IdeaProjects/cordona/claude-code-crucible/new-rewrite/framework/core/main-thread/crucible-effort/scripts
S="/private/tmp/claude-501/-Users-cordona-IdeaProjects-cordona-claude-code-crucible/480d0359-cf0d-4c14-a59e-2a72be5dba4f/scratchpad/effort test"; rm -rf "$S"; mkdir -p "$S"
export CRUCIBLE_HOME="$S/space" CLAUDE_CONFIG_DIR="$S/cfg" CLAUDE_CODE_SESSION_ID=sess-e
cd /
show() { echo "$1" | sed "s|$E/||g;s|$S|<S>|g;s|[0-9]\{8\}T[0-9]\{6\}-[0-9a-f]\{4\}|<id>|g;s|20[0-9-]*T[0-9:.]*Z|<at>|g"; }
run() { show "\$ $*"; out=$("$@" 2>&1); e=$?; show "$out" | sed 's|^|    |'; echo "    [exit $e]"; }
body() { jq -c '{type, by, body}' "$(ls "$1"/events/*.json | tail -1)" | sed 's|^|    last event: |'; }

echo "--- start: name to slug, folder, first event"
F=$(sh $E/main/effort-start.sh --name 'Prune old data!'); show "    started: $F"; body "$F"
G=$(sh $E/main/effort-start.sh --name '***'); show "    started: $G"
run sh $E/main/effort-start.sh --name 'a name that is far longer than forty characters in all'
run sh $E/main/effort-start.sh --name ''
echo "--- state and status while open"
run sh $E/main/effort-state.sh --effort "$F"
run sh $E/main/effort-status.sh --effort "$F"
echo "--- pause: words required, then paused"
run sh $E/main/effort-pause.sh --effort "$F" --words ''
run sh $E/main/effort-pause.sh --effort "$F" --words 'waiting on the DBA'
body "$F"
run sh $E/main/effort-state.sh --effort "$F"
run sh $E/main/effort-status.sh --effort "$F"
echo "--- pause again: refused"
run sh $E/main/effort-pause.sh --effort "$F" --words 'again'
echo "--- resume from paused"
run sh $E/main/effort-resume.sh --effort "$F" --words 'DBA answered'
run sh $E/main/effort-status.sh --effort "$F"
echo "--- resume and close need words too"
run sh $E/main/effort-close.sh --effort "$F" --outcome done --words ''
echo "--- resume while open: refused"
run sh $E/main/effort-resume.sh --effort "$F" --words 'again'
run sh $E/main/effort-pause.sh --effort "$F" --words 'one more pause'
run sh $E/main/effort-resume.sh --effort "$F" --words ''
run sh $E/main/effort-resume.sh --effort "$F" --words 'back again'
echo "--- close: bad outcome refused, then done"
run sh $E/main/effort-close.sh --effort "$F" --outcome finished --words 'x'
run sh $E/main/effort-close.sh --effort "$F" --outcome done --words 'shipped'
body "$F"
run sh $E/main/effort-state.sh --effort "$F"
run sh $E/main/effort-status.sh --effort "$F"
echo "--- close again: refused; pause a closed effort: refused"
run sh $E/main/effort-close.sh --effort "$F" --outcome done --words 'again'
run sh $E/main/effort-pause.sh --effort "$F" --words 'x'
echo "--- resume from closed (reopen)"
run sh $E/main/effort-resume.sh --effort "$F" --words 'a bug came back'
run sh $E/main/effort-state.sh --effort "$F"
echo "--- close a paused effort as dropped"
run sh $E/main/effort-pause.sh --effort "$F" --words 'parked'
run sh $E/main/effort-close.sh --effort "$F" --outcome dropped --words 'no longer needed'
echo "--- list: open and paused only; --all adds closed"
sleep 1  # newest change first is to the second; keep the two changes a second apart
run sh $E/main/effort-pause.sh --effort "$G" --words 'later'
run sh $E/main/effort-list.sh
run sh $E/main/effort-list.sh --all
run sh $E/main/effort-list.sh --bogus
echo "--- not an effort folder"
run sh $E/main/effort-state.sh --effort "$S"
run sh $E/main/effort-pause.sh --effort relative/path --words x
echo "--- the event log: seq in order, every move after opening has words"
jq -r '"\(.seq) \(.type) \(.body.words // "-")"' "$F"/events/*.json | sed 's|^|    |'
echo "--- the events lock held: refused with exit 6, nothing written; the rerun writes"
n=$(ls "$F"/events | wc -l | tr -d ' '); mkdir "$F/events/.lock"; echo $$ >"$F/events/.lock/pid"
run sh $E/main/effort-resume.sh --effort "$F" --words 'one more look'
rm -rf "$F/events/.lock"; echo "    events before $n, after $(ls "$F"/events | wc -l | tr -d ' ')"
run sh $E/main/effort-resume.sh --effort "$F" --words 'one more look'
