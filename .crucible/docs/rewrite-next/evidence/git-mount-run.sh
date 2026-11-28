# Evidence run for git-mount: every case through the installed layout (a
# scratch skills folder of links), from /. Only scratch keys: its own HOME,
# git config, GnuPG home and ssh agent, so the owner's agent, key ring,
# ~/.ssh and ~/.gnupg are never read. Trees are cut and committed through
# git-worktree's and git-commit's real scripts; the effort's identity is set
# through git-identity's real scripts and the gate's real hooks.
R=/Users/cordona/IdeaProjects/cordona/claude-code-crucible/new-rewrite
S=/private/tmp/claude-501/-Users-cordona-IdeaProjects-cordona-claude-code-crucible/480d0359-cf0d-4c14-a59e-2a72be5dba4f/scratchpad/gmount; rm -rf "$S"; mkdir -p "$S/home/.ssh" "$S/xdg" "$S/cfg/skills" "$S/msg"
# A Unix socket path holds about 100 bytes, so the GnuPG home and the ssh
# agent's socket sit in a short scratch folder of their own.
T=$(mktemp -d /tmp/gtb.XXXXXX); mkdir -p "$T/gnupg"; chmod 700 "$T/gnupg" "$S/home/.ssh"
# Stops only what this run started: its ssh agent and its own GnuPG home's
# daemons; then removes the short folder.
cleanup() {
	[ -z "${SSH_AGENT_PID-}" ] || kill "$SSH_AGENT_PID" 2>/dev/null
	gpgconf --kill all 2>/dev/null
	rm -rf "$T"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
export HOME="$S/home" GNUPGHOME="$T/gnupg" XDG_CONFIG_HOME="$S/xdg" GIT_CONFIG_GLOBAL="$S/home/.gitconfig" GIT_CONFIG_NOSYSTEM=1
export CRUCIBLE_HOME="$S/space" CLAUDE_CONFIG_DIR="$S/cfg" CLAUDE_CODE_SESSION_ID=sess-gm
# The run's own reads of the checkout must not refresh its index either.
export GIT_OPTIONAL_LOCKS=0
unset SSH_AUTH_SOCK SSH_AGENT_PID GIT_CONFIG_COUNT
cd /
K="$S/cfg/skills"
for d in "$R"/framework/core/main-thread/*/ "$R"/domains/software-development/core/main-thread/*/; do d=${d%/}; ln -s "$d" "$K/${d##*/}"; done
GM=$K/git-mount/scripts; GW=$K/git-worktree/scripts; GC=$K/git-commit/scripts; GI=$K/git-identity/scripts; GT=$K/crucible-gate
EV=$K/crucible-events/scripts; EF=$K/crucible-effort/scripts

pass=0 fail=0
: >"$S/ran"
show() { sed "s|$S|<S>|g;s|$T|<T>|g;s|[0-9]\{8\}T[0-9]\{6\}-[0-9a-f]\{4\}|<id>|g;s|[0-9a-f]\{40\}|<sha>|g;s|[0-9a-f]\{12\}|<short>|g;s|SHA256:[A-Za-z0-9+/]\{43\}|SHA256:<fp>|g;s|AAAA[A-Za-z0-9+/=]\{20,\}|<b64>|g"; }
# Runs "$@", keeping stdout in $out, stderr in $err and the exit in $rc, and
# shows them; notes each git-mount script it runs for the coverage check.
run() {
	for a in "$@"; do case $a in "$GM"/main/*.sh | "$GM"/internal/*.sh) echo "${a##*/}" >>"$S/ran" ;; esac; done
	echo "  \$ $(echo "$*" | sed "s|$GM/||g;s|$K/||g" | show)"
	"$@" >"$S/out" 2>"$S/err"; rc=$?
	out=$(cat "$S/out"); err=$(cat "$S/err")
	[ -z "$out" ] || echo "$out" | head -n 12 | show | sed 's/^/    out: /'
	[ -z "$err" ] || echo "$err" | head -n 12 | show | sed 's/^/    err: /'
	echo "    [exit $rc]"
}
check() {
	what=$1; shift
	if "$@" >/dev/null 2>&1; then pass=$((pass + 1)); echo "  PASS: $what"
	else fail=$((fail + 1)); echo "  FAIL: $what"; fi
}
is() { [ "$1" = "$2" ]; }
has() { printf '%s' "$1" | grep -q -- "$2"; }
last_event() { sh $EV/internal/events-read.sh --effort "$1" --type "$2" | jq -c 'last'; }
count_events() { sh $EV/internal/events-read.sh --effort "$1" | jq 'length'; }
# The human's index and refs: HEAD, its branch, every ref, the index file.
index_refs() {
	{ git -C "$S/repo" rev-parse HEAD; git -C "$S/repo" symbolic-ref -q HEAD; git -C "$S/repo" for-each-ref --format='%(refname) %(objectname)'; shasum "$S/repo/.git/index"; } | sed "s|$S||g"
}
# Every file of the checkout outside .git, with its bytes and mode.
files() { (cd "$S/repo" && find . -path ./.git -prune -o \( -type f -o -type l \) -print | LC_ALL=C sort | while IFS= read -r f; do printf '%s %s %s\n' "$f" "$(stat -f %p "$f")" "$(shasum <"$f" | cut -c1-40)"; done; cd "$S/repo" && find . -path ./.git -prune -o -type d -print | LC_ALL=C sort); }
pick() { # $1 effort, $2 subject, $3 card file, $4 question JSON file, $5 the human's answer
	sh $GT/scripts/main/show-card.sh --record set-identity --effort "$1" --subject "$2" --choice "$3" >/dev/null
	jq -cn --rawfile m "$3" '{session_id: "sess-gm", last_assistant_message: $m}' | sh $GT/hooks/stop/require-card-shown.sh >/dev/null
	jq -c '{session_id: "sess-gm", tool_name: "AskUserQuestion", tool_use_id: "t-id", tool_input: .}' "$4" | sh $GT/hooks/pre-tool-use/hold-question-until-card-shown.sh >/dev/null
	q=$(jq -r '.questions[0].question' "$4")
	jq -cn --arg q "$q" --arg a "$5" '{session_id: "sess-gm", tool_name: "AskUserQuestion", tool_use_id: "t-id", tool_response: {answers: {($q): $a}}}' \
		| sh $GT/hooks/post-tool-use/record-gate-answer.sh
}
n_msg=0
msg() { n_msg=$((n_msg + 1)); printf '{"kind":"build","text":"%s"}' "$1" >"$S/msg/$n_msg.json"; sh $GC/main/commit-message.sh --input "$S/msg/$n_msg.json" --out "$S/msg/$n_msg"; echo "$S/msg/$n_msg"; }
# Commits every change in tree $1 of effort $2 through git-commit.
tree_commit() { sh $GC/main/commit-tree.sh --worktree "$2/worktrees/$1" --message-file "$(msg "work in $1")" --effort "$2" | jq -r .commit; }
cut_tree() { sh $GW/main/worktree-cut.sh --effort "$1" --repo "${3:-$S/repo}" --name "$2" --from "${4:-checkout}" >/dev/null 2>&1; }
tip() { git -C "$S/repo" rev-parse "refs/heads/crucible/${2:-$FN}/$1"; }
human_commit() { git -C "$S/repo" add -A -- . ':!mine.txt'; git -C "$S/repo" -c user.name=Human -c user.email=human@example.test commit -q -m "$1"; }
REC="$S/repo/.git/crucible"

echo "=== set-up: scratch keys, a scratch repository, an effort with an identity"
gpg --batch --pinentry-mode loopback --passphrase '' --quick-gen-key 'Gpg Tester <gpg@example.test>' ed25519 sign never 2>/dev/null
ssh-keygen -q -t ed25519 -N '' -C ssh@example.test -f "$HOME/.ssh/agent_key"
eval "$(ssh-agent -s -a "$T/agent.sock")" >/dev/null; ssh-add -q "$HOME/.ssh/agent_key" 2>/dev/null; rm "$HOME/.ssh/agent_key"
printf 'ssh@example.test %s\n' "$(cut -d ' ' -f 1,2 "$HOME/.ssh/agent_key.pub")" >"$HOME/.ssh/allowed_signers"
git config --global user.name 'Ssh Tester'
git config --global gpg.ssh.allowedSignersFile "$HOME/.ssh/allowed_signers"
git init -q -b main "$S/repo"
printf 'base\n' >"$S/repo/f.txt"; printf 'gone soon\n' >"$S/repo/del.txt"; printf 'line one\nline two\n' >"$S/repo/eol.txt"
printf '#!/bin/sh\n' >"$S/repo/run.sh"; chmod 755 "$S/repo/run.sh"
git -C "$S/repo" add -A; git -C "$S/repo" -c user.name=Human -c user.email=human@example.test commit -q -m base
# A clean filter on eol.txt, so its bytes in the checkout (CRLF) and the
# content git stores (LF) differ, as under eol attributes.
git -C "$S/repo" config filter.crlf.clean "tr -d '\\r'"
printf 'eol.txt filter=crlf\n' >"$S/repo/.git/info/attributes"
printf 'line one\r\nline two\r\n' >"$S/repo/eol.txt"
printf 'mine\n' >"$S/repo/mine.txt"
REPO=$(cd "$S/repo" && pwd -P)
F=$(sh $EF/main/effort-start.sh --name mount-work); FN=${F##*/}
G=$(sh $EF/main/effort-start.sh --name other-work)
for e in "$F" "$G"; do
	sh $GI/main/identity-list.sh >"$S/list.json" 2>/dev/null
	sh $GI/main/identity-card.sh --list "$S/list.json" --repo "$S/repo" >"$S/card.md"
	sh $GI/main/identity-card.sh --list "$S/list.json" --repo "$S/repo" --question >"$S/q.json"
	pick "$e" "$REPO:$(shasum -a 256 "$S/list.json" | cut -d ' ' -f 1)" "$S/card.md" "$S/q.json" "$(jq -r '[.[] | select(.signing.format == "ssh")][0].label' "$S/list.json")"
	sh $GI/main/identity-set.sh --effort "$e" --repo "$S/repo" --list "$S/list.json" >/dev/null
done
check "both efforts' identities are set through git-identity's real scripts" is "$(sh $GI/main/identity-get.sh --effort "$F" --repo "$S/repo" | jq -r .signing.format)$(sh $GI/main/identity-get.sh --effort "$G" --repo "$S/repo" | jq -r .signing.format)" sshssh
HEAD0=$(git -C "$S/repo" rev-parse HEAD)
cut_tree "$F" one
printf 'changed by one\n' >"$F/worktrees/one/f.txt"; rm "$F/worktrees/one/del.txt"
mkdir -p "$F/worktrees/one/dir/sub"; printf 'new\n' >"$F/worktrees/one/dir/sub/new.txt"
printf 'line one\nline two\nline three\n' >"$F/worktrees/one/eol.txt"
ONE=$(tree_commit one "$F")
cut_tree "$F" two
printf 'two\n' >"$F/worktrees/two/t.txt"
TWO=$(tree_commit two "$F")
check "trees one and two are cut and committed through git-worktree and git-commit" is "$(git -C "$S/repo" log -1 --format=%P "$ONE"):$(git -C "$S/repo" log -1 --format=%P "$TWO")" "$HEAD0:$HEAD0"

echo
echo "=== mount-apply.sh: one tree"
IR0=$(index_refs); FILES0=$(files); N0=$(count_events "$F")
run sh $GM/main/mount-apply.sh --effort "$F" --name one
check "exit 0: target one's tip, start HEAD, 4 paths, mine.txt left alone" is "$rc:$(echo "$out" | jq -c '[.target == "'"$ONE"'", .start == "'"$HEAD0"'", .paths, .left_alone]')" '0:[true,true,4,1]'
E=$(last_event "$F" mount.made)
check "mount.made read back: by mount-apply.sh, {repo, names, target, start, paths}, its path printed" is "$(echo "$E" | jq -c '[.by, (.body | keys), .body.repo, .body.names, .body.target == "'"$ONE"'", .body.start == "'"$HEAD0"'", .body.paths]'):$(echo "$out" | jq -r .event)" "[\"mount-apply.sh\",[\"names\",\"paths\",\"repo\",\"start\",\"target\"],\"$REPO\",[\"one\"],true,true,4]:$(sh $EV/internal/events-read.sh --effort "$F" --paths | tail -n 1)"
check "the checkout holds one's work: changed, new (in new folders) and deleted files" is "$(cat "$S/repo/f.txt"):$(cat "$S/repo/dir/sub/new.txt"):$([ -e "$S/repo/del.txt" ] && echo still)" "changed by one:new:"
check "the index and refs are untouched" is "$(index_refs)" "$IR0"
check "the mounted paths show as uncommitted changes, mine.txt still there" is "$(git -C "$S/repo" status --porcelain | wc -l | tr -d ' '):$(cat "$S/repo/mine.txt")" "5:mine"
check "the record, patch and copies are in the checkout's git folder; the record is version 3" is "$(jq -r .version "$REC/mount.json"):$([ -s "$REC/mount.patch" ] && echo patch):$(ls "$REC/before" | wc -l | tr -d ' ')" "3:patch:3"

echo
echo "=== the reading scripts on a fresh mount"
run sh $GM/internal/mount-record.sh --repo "$S/repo/dir"
check "mount-record.sh from a subfolder: the record, its trees and paths" is "$rc:$(echo "$out" | jq -c '[.version, .effort == "'"$F"'", .trees[0].name, .trees[0].tip == "'"$ONE"'", (.paths | map(.path)), .start_is_snapshot]')" '0:[3,true,"one",true,["del.txt","dir/sub/new.txt","eol.txt","f.txt"],false]'
run sh $GM/internal/mount-paths.sh --repo "$S/repo"
check "mount-paths.sh: every path mounted, HEAD not moved, not finished" is "$rc:$(echo "$out" | jq -c '[.head_moved, .finished, ([.paths[].now] | unique)]')" '0:[false,false,["mounted"]]'
run sh $GM/main/mount-status.sh --repo "$S/repo" --effort "$F"
check "mount-status.sh: mounted, nothing moved, no edits, ours" is "$rc:$(echo "$out" | jq -c '[.mounted, .moved, .head_moved, .finished, .paths, .edited, .ours, .trees[0].moved]')" '0:[true,false,false,false,4,[],true,false]'
run sh $GM/main/mount-status.sh --repo "$S/repo" --effort "$G"
check "mount-status.sh --effort of another effort: ours false" is "$(echo "$out" | jq -c .ours)" false
run sh $GM/internal/open-work.sh --effort "$F"
check "open-work.sh: one line, mount <repo> <names>" is "$rc:$out" "0:mount $REPO one"
run sh $GM/internal/open-work.sh --effort "$G"
check "open-work.sh of an effort that mounted nothing: nothing" is "$rc:$out" "0:"
run sh $GM/internal/mount-restore.sh --repo "$S/repo"
check "mount-restore.sh while the mount's content is there: exit 2, nothing touched" is "$rc:$(has "$err" 'does not hold its content from before' && echo y):$(cat "$S/repo/f.txt")" "2:y:changed by one"

echo
echo "=== a second mount while one is in place"
run sh $GM/main/mount-apply.sh --effort "$F" --name two
check "refused: exit 2, a mount is in place, undo it first, nothing changed" is "$rc:$(has "$err" 'a mount is in place' && echo y):$([ -e "$S/repo/t.txt" ] && echo t)" "2:y:"

echo
echo "=== mount-status.sh after the tree moved, the human edited a path, HEAD moved"
printf 'more\n' >"$F/worktrees/one/more.txt"; ONE2=$(tree_commit one "$F")
run sh $GM/main/mount-status.sh --repo "$S/repo"
check "one moved on: moved true, now its new tip, no ours without --effort" is "$(echo "$out" | jq -c '[.moved, .trees[0].now == "'"$ONE2"'", .trees[0].tip == "'"$ONE"'", has("ours")]')" '[true,true,true,false]'
printf 'edited by the human\n' >"$S/repo/f.txt"; rm "$S/repo/dir/sub/new.txt"
run sh $GM/main/mount-status.sh --repo "$S/repo"
check "edited and deleted mounted paths are listed as edited" is "$(echo "$out" | jq -c .edited)" '["dir/sub/new.txt","f.txt"]'
run sh $GM/internal/mount-paths.sh --repo "$S/repo"
check "mount-paths.sh: f.txt edited, new.txt gone" is "$(echo "$out" | jq -c '[.paths[] | select(.now != "mounted") | [.path, .now]]')" '[["dir/sub/new.txt","gone"],["f.txt","edited"]]'
IR1=$(index_refs)
run sh $GM/main/mount-undo.sh --repo "$S/repo"
check "mount-undo.sh with edited paths: exit 2, each named, nothing touched" is "$rc:$(has "$err" 'changed since the mount: f.txt: edited' && echo y):$(cat "$S/repo/f.txt"):$(index_refs)" "2:y:edited by the human:$IR1"
printf 'changed by one\n' >"$S/repo/f.txt"; printf 'new\n' >"$S/repo/dir/sub/new.txt"
printf 'x\n' >"$S/repo/x.txt"; git -C "$S/repo" add x.txt; git -C "$S/repo" -c user.name=Human -c user.email=human@example.test commit -q -m 'human x'
run sh $GM/main/mount-status.sh --repo "$S/repo"
check "HEAD moved without the mounted paths: head_moved true, finished false" is "$(echo "$out" | jq -c '[.head_moved, .finished]')" '[true,false]'
run sh $GM/internal/mount-paths.sh --repo "$S/repo"
check "mount-paths.sh after HEAD moved: the paths are mounted, not committed" is "$(echo "$out" | jq -c '[.head_moved, ([.paths[].now] | unique)]')" '[true,["mounted"]]'
run sh $GM/main/mount-undo.sh --repo "$S/repo"
check "mount-undo.sh after HEAD moved: exit 2, the uncommitted paths named, nothing touched" is "$rc:$(has "$err" 'HEAD moved since the mount' && echo y):$(has "$err" 'not committed: f.txt' && echo y):$(cat "$S/repo/f.txt")" "2:y:y:changed by one"
git -C "$S/repo" reset -q --soft HEAD~1; git -C "$S/repo" reset -q -- x.txt; rm "$S/repo/x.txt"

echo
echo "=== mount-restore.sh: the saved bytes put back under a clean filter"
git -C "$S/repo" apply -R --binary "$REC/mount.patch"
check "with the patch taken out by hand, eol.txt holds LF bytes, not the human's CRLF" is "$(od -c "$S/repo/eol.txt" | grep -c '\\r')" 0
run sh $GM/internal/mount-restore.sh --repo "$S/repo"
check "exit 0: 3 saved, 1 restored, eol.txt holds the human's CRLF bytes again" is "$rc:$out:$(cmp -s "$S/repo/eol.txt" "$REC/before/2" && echo same)" '0:{"saved":3,"restored":1}:same'
run sh $GM/internal/mount-restore.sh --repo "$S/repo"
check "run again: nothing to restore" is "$rc:$out" '0:{"saved":3,"restored":0}'
mv "$REC/before/0" "$S/saved0"
run sh $GM/internal/mount-restore.sh --repo "$S/repo"
check "a saved copy missing: exit 2" is "$rc:$(has "$err" 'is missing' && echo y)" "2:y"
mv "$S/saved0" "$REC/before/0"
git -C "$S/repo" apply --binary "$REC/mount.patch"

echo
echo "=== mount-undo.sh: byte for byte"
IR0=$(index_refs)
run sh $GM/main/mount-undo.sh --repo "$S/repo"
check "exit 0: forgotten false, names one, 4 paths" is "$rc:$(echo "$out" | jq -c '[.forgotten, .names, .paths]')" '0:[false,["one"],4]'
check "every file, byte and mode, and every folder is as before the mount (new.txt's folders gone, del.txt back, eol.txt CRLF)" is "$(files)" "$FILES0"
check "the index and refs are untouched" is "$(index_refs)" "$IR0"
check "the record is gone" is "$([ -e "$REC" ] && echo there)" ""
E=$(last_event "$F" mount.undone)
check "mount.undone read back: by mount-undo.sh, {repo, forgotten: false}, its path printed" is "$(echo "$E" | jq -c '[.by, .body]'):$(echo "$out" | jq -r .event)" "[\"mount-undo.sh\",{\"repo\":\"$REPO\",\"forgotten\":false}]:$(sh $EV/internal/events-read.sh --effort "$F" --paths | tail -n 1)"
run sh $GM/main/mount-undo.sh --repo "$S/repo"
check "nothing mounted: exit 5" is "$rc" 5
run sh $GM/main/mount-status.sh --repo "$S/repo"
check "mount-status.sh with nothing mounted: {mounted: false}" is "$rc:$out" '0:{"mounted":false}'
run sh $GM/internal/mount-paths.sh --repo "$S/repo"
check "mount-paths.sh with nothing mounted: exit 5" is "$rc" 5
run sh $GM/internal/mount-record.sh --repo "$S/repo"
check "mount-record.sh with nothing mounted: exit 5" is "$rc" 5
run sh $GM/internal/mount-restore.sh --repo "$S/repo"
check "mount-restore.sh with nothing mounted: exit 5" is "$rc" 5
run sh $GM/internal/open-work.sh --effort "$F"
check "open-work.sh once undone: nothing" is "$rc:$out" "0:"

echo
echo "=== mount-apply.sh: two trees joined"
IR0=$(index_refs); FILES0=$(files)
run sh $GM/main/mount-apply.sh --effort "$F" --name one --name two
JT=$(echo "$out" | jq -r .target)
check "exit 0: the target is a new signed commit of one's and two's tips" is "$rc:$(git -C "$S/repo" log -1 --format=%P "$JT"):$(git -C "$S/repo" verify-commit "$JT" >/dev/null 2>&1 && echo signed)" "0:$ONE2 $TWO:signed"
check "the join names the trees and the effort; no ref points at it" is "$(git -C "$S/repo" log -1 --format='%s|%(trailers:key=Worktree,valueonly)|%(trailers:key=Effort,valueonly)' "$JT" | tr -d '\n'):$(git -C "$S/repo" for-each-ref --points-at "$JT" | wc -l | tr -d ' ')" "crucible(mount): join the tips of the trees mounted|one two|$FN:0"
check "the checkout holds both trees' work; index and refs untouched" is "$(cat "$S/repo/t.txt"):$(cat "$S/repo/more.txt"):$(index_refs)" "two:more:$IR0"
check "mount.made read back names both trees" is "$(last_event "$F" mount.made | jq -c .body.names)" '["one","two"]'
run sh $GM/main/mount-status.sh --repo "$S/repo" --effort "$F"
check "mount-status.sh: two trees, neither moved" is "$(echo "$out" | jq -c '[[.trees[].name], .moved]')" '[["one","two"],false]'
run sh $GM/main/mount-undo.sh --repo "$S/repo"
check "undone byte for byte" is "$rc:$(files)" "0:$FILES0"

echo
echo "=== the human committed the mount"
run sh $GM/main/mount-apply.sh --effort "$F" --name two
check "two mounted" is "$rc" 0
human_commit 'human takes two'
run sh $GM/main/mount-status.sh --repo "$S/repo"
check "mount-status.sh: head moved, finished" is "$(echo "$out" | jq -c '[.head_moved, .finished]')" '[true,true]'
run sh $GM/internal/mount-paths.sh --repo "$S/repo"
check "mount-paths.sh: every path committed" is "$(echo "$out" | jq -c '[.finished, ([.paths[].now] | unique)]')" '[true,["committed"]]'
run sh $GM/internal/open-work.sh --effort "$F"
check "open-work.sh: a committed mount is no open work" is "$rc:$out" "0:"
FILES1=$(files)
run sh $GM/main/mount-undo.sh --repo "$S/repo"
check "mount-undo.sh: exit 0, forgotten true, no file touched, the record gone" is "$rc:$(echo "$out" | jq -c .forgotten):$(files):$([ -e "$REC" ] && echo there)" "0:true:$FILES1:"
check "mount.undone read back: forgotten true" is "$(last_event "$F" mount.undone | jq -c .body.forgotten)" true
echo "--- a finished mount is forgotten by the next mount-apply.sh"
git -C "$S/repo" reset -q --hard HEAD~1
run sh $GM/main/mount-apply.sh --effort "$F" --name two
human_commit 'human takes two again'
N1=$(sh $EV/internal/events-read.sh --effort "$F" --type mount.undone | jq length)
run sh $GM/main/mount-apply.sh --effort "$F" --name one
check "the finished mount is forgotten (stderr says so, mount.undone written), then the range is refused: not on HEAD" is "$rc:$(has "$err" 'forgot the finished mount of two' && echo y):$(sh $EV/internal/events-read.sh --effort "$F" --type mount.undone | jq length):$(has "$err" 'is not an ancestor' && echo y):$([ -e "$REC" ] && echo there)" "2:y:$((N1 + 1)):y:"
git -C "$S/repo" reset -q --hard HEAD~1

echo
echo "=== a tree cut from a snapshot of the human's uncommitted work"
printf 'human wip\n' >"$S/repo/f.txt"
cut_tree "$F" snapped "$S/repo" snapshot
SNAP=$(git -C "$S/repo" rev-parse "refs/heads/crucible/$FN/snapped")
printf 'on the snapshot\n' >"$F/worktrees/snapped/s.txt"; SN=$(tree_commit snapped "$F")
run sh $GM/internal/effort-commits.sh --repo "$S/repo" --from "$HEAD0" --to "$SN" --effort "$F"
check "effort-commits.sh: ok, the start is the snapshot, 2 commits" is "$rc:$(echo "$out" | jq -c '[.ok, .start == "'"$SNAP"'", .from == "'"$HEAD0"'", .commits]')" '0:[true,true,true,2]'
run sh $GM/main/mount-apply.sh --effort "$F" --name snapped
check "mount-apply.sh: start the snapshot, only s.txt applied, the human's wip kept" is "$rc:$(echo "$out" | jq -c '[.start == "'"$SNAP"'", .paths]'):$(cat "$S/repo/f.txt"):$(cat "$S/repo/s.txt")" "0:[true,1]:human wip:on the snapshot"
check "the record says start_is_snapshot" is "$(jq -c .start_is_snapshot "$REC/mount.json")" true
run sh $GM/main/mount-undo.sh --repo "$S/repo"
check "undone, the human's wip still there" is "$rc:$(cat "$S/repo/f.txt"):$([ -e "$S/repo/s.txt" ] && echo s)" "0:human wip:"
git -C "$S/repo" checkout -q -- f.txt

echo
echo "=== effort-commits.sh refusals"
run sh $GM/internal/effort-commits.sh --repo "$S/repo" --from "$HEAD0" --to "$ONE2" --effort "$F"
check "a range of this effort's commits: ok, start --from, 2 commits" is "$rc:$(echo "$out" | jq -c '[.ok, .start == "'"$HEAD0"'", .commits]')" '0:[true,true,2]'
cut_tree "$F" foreign
printf 'f\n' >"$F/worktrees/foreign/foreign.txt"; git -C "$F/worktrees/foreign" add -A; git -C "$F/worktrees/foreign" -c user.name=Other -c user.email=o@example.test commit -q -m 'no trailer'
FOREIGN=$(tip foreign)
run sh $GM/internal/effort-commits.sh --repo "$S/repo" --from "$HEAD0" --to "$FOREIGN" --effort "$F"
check "a commit with no Effort trailer: exit 5, foreign_commit, naming it" is "$rc:$(echo "$out" | jq -c '[.ok, .reason, .commit == "'"$FOREIGN"'", .subject]')" '5:[false,"foreign_commit",true,"no trailer"]'
run sh $GM/internal/effort-commits.sh --repo "$S/repo" --from "$HEAD0" --to "$ONE2" --effort "$G"
check "another effort's commits: exit 5, foreign_commit" is "$rc:$(echo "$out" | jq -r .reason)" "5:foreign_commit"
run sh $GM/internal/effort-commits.sh --repo "$S/repo" --from "$ONE2" --to "$TWO" --effort "$F"
check "--from no ancestor of --to: exit 5, not_ancestor, commit null" is "$rc:$(echo "$out" | jq -c '[.reason, .commit]')" '5:["not_ancestor",null]'
ST1=$(git -C "$S/repo" mktree </dev/null)
ST2=$(git -C "$S/repo" rev-parse "$ONE^{tree}")
SM="crucible(snapshot): uncommitted changes

Effort: $FN"
S1=$(git -C "$S/repo" -c user.name=t -c user.email=t@t commit-tree "$ST1" -p "$HEAD0" -m "$SM")
S2=$(git -C "$S/repo" -c user.name=t -c user.email=t@t commit-tree "$ST2" -p "$HEAD0" -m "$SM")
SJ=$(git -C "$S/repo" -c user.name=t -c user.email=t@t commit-tree "$ST2" -p "$S1" -p "$S2" -m "join

Effort: $FN")
run sh $GM/internal/effort-commits.sh --repo "$S/repo" --from "$HEAD0" --to "$SJ" --effort "$F"
check "two snapshots with different trees: exit 5, snapshot_mismatch" is "$rc:$(echo "$out" | jq -r .reason)" "5:snapshot_mismatch"
run sh $GM/internal/effort-commits.sh --repo "$S/repo" --from -x --to "$ONE" --effort "$F"
check "--from starting with -: exit 2" is "$rc" 2
run sh $GM/internal/effort-commits.sh --repo "$S/repo" --from "$HEAD0" --to nosuch --effort "$F"
check "--to no commit: exit 2" is "$rc:$(has "$err" 'is no commit' && echo y)" "2:y"
run sh $GM/internal/effort-commits.sh --repo "$S/repo" --from '' --to "$ONE" --effort "$F"
check "--from empty: exit 2" is "$rc" 2
run sh $GM/internal/effort-commits.sh --repo "$S/repo" --from "$(printf 'a\tb')" --to "$ONE" --effort "$F"
check "--from with a control character: exit 2" is "$rc:$(has "$err" 'control character' && echo y)" "2:y"
run sh $GM/internal/effort-commits.sh --repo "$S/repo" --from "$HEAD0" --to "$ONE" --effort "$S/repo"
check "--effort no effort folder: exit 2" is "$rc" 2
run sh $GM/internal/effort-commits.sh --repo relative --from "$HEAD0" --to "$ONE" --effort "$F"
check "--repo not absolute: exit 2" is "$rc" 2
run sh $GM/internal/effort-commits.sh --repo "$S" --from "$HEAD0" --to "$ONE" --effort "$F"
check "--repo in no repository: exit 2" is "$rc" 2
run sh $GM/internal/effort-commits.sh --repo "$S/repo" --from "$HEAD0" --to
check "--to with no value: exit 2" is "$rc" 2
# git-commit tells the snapshots; a scratch skills folder without it, then
# with a stand-in whose answer fails.
K3="$S/k3/skills"; mkdir -p "$K3"; for d in dev-base git-mount; do ln -s "$(readlink "$K/$d")" "$K3/$d"; done
run sh $K3/git-mount/scripts/internal/effort-commits.sh --repo "$S/repo" --from "$HEAD0" --to "$ONE2" --effort "$F"
check "with git-commit not beside it: exit 2, install first" is "$rc:$(has "$err" "a neighbour isn't beside this skill" && echo y)" "2:y"
mkdir -p "$K3/git-commit/scripts/internal"; printf '#!/bin/sh\nexit 1\n' >"$K3/git-commit/scripts/internal/commit-snapshots.sh"
run sh $K3/git-mount/scripts/internal/effort-commits.sh --repo "$S/repo" --from "$HEAD0" --to "$ONE2" --effort "$F"
check "git-commit's answer failing: exit 4, nothing printed" is "$rc:$(has "$err" 'commit-snapshots.sh failed (exit 1)' && echo y):$out" "4:y:"
rm -rf "$S/k3"
run sh $GM/main/mount-apply.sh --effort "$F" --name foreign
check "mount-apply.sh of a tree holding a foreign commit: exit 2, effort-commits.sh's line, nothing written" is "$rc:$(has "$err" 'carries no Effort' && echo y):$([ -e "$REC" ] && echo there):$([ -e "$S/repo/foreign.txt" ] && echo f)" "2:y::"

echo
echo "=== mount-apply.sh refusals of names and trees"
run sh $GM/main/mount-apply.sh --effort "$F" --name nosuch
check "no live tree of that name: exit 2" is "$rc:$(has "$err" 'no live tree named nosuch' && echo y)" "2:y"
run sh $GM/main/mount-apply.sh --effort "$F" --name one --name nosuch
check "a second name that is no live tree: exit 2" is "$rc:$(has "$err" 'no live tree named nosuch' && echo y)" "2:y"
run sh $GM/main/mount-apply.sh --effort "$F" --name one --name one
check "a name given twice: exit 2" is "$rc:$(has "$err" 'given twice' && echo y)" "2:y"
run sh $GM/main/mount-apply.sh --effort "$F" --name Bad_Name
check "a name that is not lowercase words: exit 2" is "$rc" 2
run sh $GM/main/mount-apply.sh --effort "$F"
check "no --name: exit 2" is "$rc" 2
run sh $GM/main/mount-apply.sh --effort "$F" --name
check "--name with no value: exit 2" is "$rc" 2
run sh $GM/main/mount-apply.sh --effort "$S/repo" --name one
check "--effort no effort folder: exit 2" is "$rc" 2
run sh $GM/main/mount-apply.sh --effort relative --name one
check "--effort not absolute: exit 2" is "$rc" 2
printf 'wip\n' >"$F/worktrees/two/wip.txt"
run sh $GM/main/mount-apply.sh --effort "$F" --name two
check "a tree with uncommitted changes: exit 2" is "$rc:$(has "$err" 'uncommitted changes, which a mount would leave out' && echo y)" "2:y"
rm "$F/worktrees/two/wip.txt"
cut_tree "$F" gone-branch; git -C "$S/repo" worktree remove --force "$F/worktrees/gone-branch"; git -C "$S/repo" update-ref -d "refs/heads/crucible/$FN/gone-branch"
run sh $GM/main/mount-apply.sh --effort "$F" --name one --name gone-branch
check "a tree whose branch is gone: exit 2" is "$rc:$(has "$err" "gone-branch's branch is gone" && echo y)" "2:y"
run sh $GM/main/mount-apply.sh --effort "$F" --name gone-branch
check "a first tree whose folder is not there: exit 2" is "$rc:$(has "$err" 'is not there' && echo y)" "2:y"
git init -q -b main "$S/repo2"; git -C "$S/repo2" -c user.name=t -c user.email=t@t commit -q --allow-empty -m r2
cut_tree "$F" elsewhere "$S/repo2"
run sh $GM/main/mount-apply.sh --effort "$F" --name one --name elsewhere
check "trees of two repositories: exit 2" is "$rc:$(has "$err" 'is of another repository' && echo y)" "2:y"
run sh $GM/main/mount-apply.sh --effort "$F" --name one --name two --name nosuch --name elsewhere
check "every problem found is listed" is "$rc:$(echo "$err" | grep -c 'nosuch\|another repository')" "2:2"

echo
echo "=== mount-apply.sh refusals of the checkout and the work"
git -C "$S/repo" rev-parse HEAD >"$S/repo/.git/MERGE_HEAD"
run sh $GM/main/mount-apply.sh --effort "$F" --name one
check "a merge under way in the checkout: exit 2" is "$rc:$(has "$err" 'has a merge under way' && echo y)" "2:y"
rm "$S/repo/.git/MERGE_HEAD"
git -C "$S/repo" config core.sparseCheckout true
run sh $GM/main/mount-apply.sh --effort "$F" --name one
check "a sparse checkout: exit 2" is "$rc:$(has "$err" 'is sparse' && echo y)" "2:y"
git -C "$S/repo" config core.sparseCheckout false
git -C "$S/repo" symbolic-ref HEAD refs/heads/unborn
run sh $GM/main/mount-apply.sh --effort "$F" --name one
check "a checkout with no HEAD commit: exit 2" is "$rc:$(has "$err" 'no HEAD commit' && echo y)" "2:y"
git -C "$S/repo" symbolic-ref HEAD refs/heads/main
cut_tree "$F" clash; printf 'clash\n' >"$F/worktrees/clash/f.txt"; tree_commit clash "$F" >/dev/null
run sh $GM/main/mount-apply.sh --effort "$F" --name one --name clash
check "tips that conflict: exit 2, naming the path, nothing written" is "$rc:$(has "$err" 'conflict in f.txt' && echo y):$([ -e "$REC" ] && echo there)" "2:y:"
cut_tree "$F" empty
run sh $GM/main/mount-apply.sh --effort "$F" --name empty
check "a tree with no work: exit 2, nothing to mount" is "$rc:$(has "$err" 'nothing to mount' && echo y)" "2:y"
printf 'human edit\n' >"$S/repo/f.txt"; printf 'in the way\n' >"$S/repo/del.txt.tmp"
run sh $GM/main/mount-apply.sh --effort "$F" --name one
check "a path the human changed: exit 2, naming it, the file untouched" is "$rc:$(has "$err" 'the checkout differs from the start at f.txt' && echo y):$(cat "$S/repo/f.txt")" "2:y:human edit"
git -C "$S/repo" checkout -q -- f.txt; rm "$S/repo/del.txt.tmp"
printf 'untracked\n' >"$S/repo/t.txt"
run sh $GM/main/mount-apply.sh --effort "$F" --name two
check "an untracked file where the tree adds one: exit 2" is "$rc:$(has "$err" 'differs from the start at t.txt' && echo y)" "2:y"
rm "$S/repo/t.txt"
git -C "$S/repo" update-index --cacheinfo "100644,$(printf 'staged\n' | git -C "$S/repo" hash-object -w --stdin),f.txt"
run sh $GM/main/mount-apply.sh --effort "$F" --name one
check "a mounted path staged differently from HEAD and the start: exit 2" is "$rc:$(has "$err" 'f.txt is staged differently' && echo y)" "2:y"
git -C "$S/repo" reset -q -- f.txt
printf 'a file\n' >"$S/repo/dir"
run sh $GM/main/mount-apply.sh --effort "$F" --name one
check "a file where the patch needs a folder: exit 2, the path beyond a file" is "$rc:$(has "$err" 'differs from the start at dir/sub/new.txt: it holds beyond-file' && echo y)" "2:y"
rm "$S/repo/dir"
# Commits made with plumbing, on a tree whose folder is gone, so paths the
# file system can't hold need no file.
cut_tree "$F" odd; rm -rf "$F/worktrees/odd"
odd_commit() { # $1 path, $2 mode
	idx="$S/odd-index"; rm -f "$idx"
	GIT_INDEX_FILE=$idx git -C "$S/repo" read-tree "$HEAD0"
	GIT_INDEX_FILE=$idx git -C "$S/repo" update-index --add --cacheinfo "$2,$(printf 'x\n' | git -C "$S/repo" hash-object -w --stdin),$1"
	c=$(git -C "$S/repo" -c user.name=t -c user.email=t@t commit-tree "$(GIT_INDEX_FILE=$idx git -C "$S/repo" write-tree)" -p "$HEAD0" -m "odd

Effort: $FN")
	git -C "$S/repo" update-ref "refs/heads/crucible/$FN/odd" "$c"
}
odd_commit "$(printf 'new\nline.txt')" 100644
run sh $GM/main/mount-apply.sh --effort "$F" --name one --name odd
check "a path holding a newline: exit 2" is "$rc:$(has "$err" 'holding a newline' && echo y)" "2:y"
odd_commit "$(printf 'bad\377.txt')" 100644
run sh $GM/main/mount-apply.sh --effort "$F" --name one --name odd
check "a path that is not UTF-8: exit 2" is "$rc:$(has "$err" 'not valid UTF-8' && echo y)" "2:y"
idx="$S/odd-index"; rm -f "$idx"; GIT_INDEX_FILE=$idx git -C "$S/repo" read-tree "$HEAD0"
GIT_INDEX_FILE=$idx git -C "$S/repo" update-index --add --cacheinfo "160000,$HEAD0,sub"
c=$(git -C "$S/repo" -c user.name=t -c user.email=t@t commit-tree "$(GIT_INDEX_FILE=$idx git -C "$S/repo" write-tree)" -p "$HEAD0" -m "sub

Effort: $FN"); git -C "$S/repo" update-ref "refs/heads/crucible/$FN/odd" "$c"
run sh $GM/main/mount-apply.sh --effort "$F" --name one --name odd
check "a submodule in the diff: exit 2" is "$rc:$(has "$err" 'changes the submodule sub' && echo y)" "2:y"
check "none of these refusals wrote a record or touched the checkout" is "$([ -e "$REC" ] && echo there):$(git -C "$S/repo" status --porcelain)" ":?? mine.txt"

echo
echo "=== a busy tree, through git-worktree's worktree-busy.sh"
mkdir -p "$K/busy-standin/scripts/internal"
printf '#!/bin/sh\n! grep -qx -- "$4" "%s/busy-fail" 2>/dev/null || exit 1\n! grep -qx -- "$4" "%s/busy-names" 2>/dev/null || echo "busy standing in for $4"\n' "$S" "$S" >"$K/busy-standin/scripts/internal/busy.sh"
echo one >"$S/busy-names"
run sh $GM/main/mount-apply.sh --effort "$F" --name two --name one
check "mount-apply.sh refuses a busy tree: exit 2, the neighbour's line named, nothing written" is "$rc:$(has "$err" 'busy: busy-standin: one: busy standing in for one' && echo y):$([ -e "$REC" ] && echo there)" "2:y:"
: >"$S/busy-names"; echo two >"$S/busy-fail"
run sh $GM/main/mount-apply.sh --effort "$F" --name two
check "a check that fails counts as busy: exit 2, nothing written" is "$rc:$(has "$err" 'busy: busy-standin: two: busy.sh failed' && echo y):$([ -e "$REC" ] && echo there)" "2:y:"
rm -rf "$K/busy-standin" "$S/busy-fail"

echo
echo "=== mount-states.sh"
mkdir -p "$S/repo/sd"; ln -s ../f.txt "$S/repo/link"; ln -s sd "$S/repo/linkdir"; mkfifo "$S/repo/fifo"
printf '%s\n' f.txt run.sh link sd linkdir/x nothing fifo f.txt/x >"$S/paths"
run sh $GM/internal/mount-states.sh --repo "$S/repo" --paths "$S/paths"
check "a file, an executable, a symlink, a folder, beyond a symlink, absent, other, beyond a file" is "$rc:$(echo "$out" | jq -c '[.[] | .state | sub("[0-9a-f]{40}"; "<sha>")]')" '0:["100644 <sha>","100755 <sha>","120000 <sha>","directory","beyond-symlink","absent","other","beyond-file"]'
check "the blobs are git's: f.txt's is HEAD's, the link's its target text" is "$(echo "$out" | jq -r '.[0].state'):$(echo "$out" | jq -r '.[2].state')" "100644 $(git -C "$S/repo" rev-parse HEAD:f.txt):120000 $(printf '../f.txt' | git -C "$S/repo" hash-object --stdin)"
check "no object was written for the hashed files" is "$(git -C "$S/repo" cat-file -e "$(printf '../f.txt' | git -C "$S/repo" hash-object --stdin)" 2>/dev/null && echo written)" ""
rm -rf "$S/repo/sd" "$S/repo/link" "$S/repo/linkdir" "$S/repo/fifo"
printf '../x\n' >"$S/paths-bad"
run sh $GM/internal/mount-states.sh --repo "$S/repo" --paths "$S/paths-bad"
check "a path with a .. segment: exit 2" is "$rc:$(has "$err" 'root-relative' && echo y)" "2:y"
run sh $GM/internal/mount-states.sh --repo "$S/repo" --paths "$S/no-such-file"
check "--paths no file: exit 2" is "$rc" 2
run sh $GM/internal/mount-states.sh --repo "$S/bare.git" --paths "$S/paths"
check "--repo in no repository: exit 2" is "$rc" 2
git init -q --bare "$S/bare.git"
run sh $GM/internal/mount-states.sh --repo "$S/bare.git" --paths "$S/paths"
check "--repo a bare repository: exit 2" is "$rc:$(has "$err" 'bare repository' && echo y)" "2:y"
: >"$S/paths-empty"
run sh $GM/internal/mount-states.sh --repo "$S/repo" --paths "$S/paths-empty"
check "no paths: an empty array" is "$rc:$out" "0:[]"

echo
echo "=== mount-record.sh: records it refuses, and the others reading them"
mkdir -p "$REC"; printf 'old\n' >"$REC/mount.patch"
printf '{"version":2,"effort":"/e","repo":"%s","seats":[{"seat":"a","worktree":"/w","seat_commit":"%s"}]}\n' "$REPO" "$HEAD0" >"$REC/mount.json"
run sh $GM/internal/mount-record.sh --repo "$S/repo"
check "a version 2 record: exit 2, refused, not read" is "$rc:$(has "$err" 'not this record version; expected 3, so the record was not read' && echo y):$out" "2:y:"
for s in mount-status.sh mount-paths.sh mount-undo.sh mount-restore.sh; do
	run sh "$GM"/*/"$s" --repo "$S/repo"
	check "$s refuses the version 2 record: exit 2, the record kept" is "$rc:$([ -f "$REC/mount.json" ] && echo kept)" "2:kept"
done
run sh $GM/main/mount-apply.sh --effort "$F" --name one
check "mount-apply.sh refuses the version 2 record: exit 2, nothing applied" is "$rc:$(cat "$S/repo/f.txt")" "2:base"
printf '{"version":3,"effort":"rel","repo":"/r","trees":[{"name":"A","branch":"main","tip":"x"}],"start":"1","target":"%s","head":"%s","start_is_snapshot":"no","branch":null,"mounted_at":"t","paths":[{"path":"../x","before":"absent","after":"nope","saved":true}],"extra":1}\n' "$HEAD0" "$HEAD0" >"$REC/mount.json"
run sh $GM/internal/mount-record.sh --repo "$S/repo"
check "a version 3 record of the wrong shape: exit 2, one line per problem" is "$rc:$(for w in 'effort:' 'start:' 'start_is_snapshot:' 'trees\[0\].name' 'trees\[0\].branch' 'trees\[0\].tip' 'paths\[0\].path' 'paths\[0\].after' 'paths\[0\].saved'; do has "$err" "$w" || echo "miss $w"; done)" "2:"
printf 'not json' >"$REC/mount.json"
run sh $GM/internal/mount-record.sh --repo "$S/repo"
check "a record that is not JSON: exit 2" is "$rc:$(has "$err" 'not JSON' && echo y)" "2:y"
rm "$REC/mount.patch"; printf '{}' >"$REC/mount.json"
run sh $GM/internal/mount-record.sh --repo "$S/repo"
check "a record with no patch beside it: exit 2" is "$rc:$(has "$err" 'no mount.patch' && echo y)" "2:y"
rm "$REC/mount.json"; mkdir "$REC/mount.json"
run sh $GM/internal/mount-record.sh --repo "$S/repo"
check "a record that is a folder: exit 2" is "$rc:$(has "$err" 'not a regular file' && echo y)" "2:y"
rm -rf "$REC"
run sh $GM/internal/mount-record.sh --repo relative
check "mount-record.sh --repo not absolute: exit 2" is "$rc" 2
for s in mount-status.sh mount-paths.sh mount-undo.sh mount-restore.sh; do
	run sh "$GM"/*/"$s" --repo "$S/bare.git"
	check "$s --repo a bare repository: exit 2" is "$rc" 2
done
run sh $GM/main/mount-status.sh --repo "$S/repo" --effort "$S/repo"
check "mount-status.sh --effort no effort folder: exit 2" is "$rc" 2

echo
echo "=== mount-apply.sh rolls back when mount.made can't be written"
FILES0=$(files); IR0=$(index_refs); N0=$(count_events "$F")
mkdir "$F/events/.lock"; echo $$ >"$F/events/.lock/pid"
run sh $GM/main/mount-apply.sh --effort "$F" --name one
rm -rf "$F/events/.lock"
check "the events lock held: exit 6, no event, the patch taken out, the bytes put back, no record, index and refs untouched" is "$rc:$(count_events "$F"):$(has "$err" 'mount.made was not written' && echo y):$(has "$err" 'taken out again' && echo y):$(files):$([ -e "$REC" ] && echo there):$(index_refs)" "6:$N0:y:y:$FILES0::$IR0"

echo
echo "=== mount-undo.sh when mount.undone can't be written: the mount is out, no event"
run sh $GM/main/mount-apply.sh --effort "$F" --name one
N0=$(count_events "$F")
mkdir "$F/events/.lock"; echo $$ >"$F/events/.lock/pid"
run sh $GM/main/mount-undo.sh --repo "$S/repo"
rm -rf "$F/events/.lock"
check "the events lock held: exit 6, no mount.undone, every file as before the mount, no record, index and refs untouched, no open mount" is "$rc:$(count_events "$F"):$(has "$err" 'mount.undone was not written' && echo y):$(files):$([ -e "$REC" ] && echo there):$(index_refs):$(sh $GM/internal/open-work.sh --effort "$F")" "6:$N0:y:$FILES0::$IR0:"

echo
echo "=== a tree dropped while it is mounted: the patch taken out, no event"
# A git that pauses once: after the first git command matching PAUSE_AT
# that comes at or after one matching PAUSE_ARM, it waits for the go file,
# so a case can drop a tree while a script is part way through.
REAL_GIT=$(command -v git)
mkdir -p "$S/pausegit"
cat >"$S/pausegit/git" <<'SHIM'
#!/bin/sh
"$REAL_GIT" "$@"; rc=$?
case " $* " in *" $PAUSE_ARM "*) : >"$PAUSE_DIR/armed" ;; esac
if [ -e "$PAUSE_DIR/armed" ] && [ ! -e "$PAUSE_DIR/paused" ]; then
	case " $* " in
		*" $PAUSE_AT "*)
			: >"$PAUSE_DIR/paused"
			n=0; while [ ! -e "$PAUSE_DIR/go" ] && [ "$n" -lt 300 ]; do sleep 0.1; n=$((n + 1)); done ;;
	esac
fi
exit "$rc"
SHIM
chmod 755 "$S/pausegit/git"
# paused_start ARM AT CMD...: runs CMD in the background through that git
# and returns once it has paused.
paused_start() {
	rm -rf "$S/pause"; mkdir -p "$S/pause"
	pause_arm=$1 pause_at=$2; shift 2
	for a in "$@"; do case $a in */scripts/main/*.sh | */scripts/internal/*.sh) echo "${a##*/}" >>"$S/ran" ;; esac; done
	echo "  \$ $(echo "$*" | sed "s|$K/[a-z-]*/scripts/||g" | show)   (git paused after: $pause_at)"
	REAL_GIT="$REAL_GIT" PAUSE_DIR="$S/pause" PAUSE_ARM="$pause_arm" PAUSE_AT="$pause_at" PATH="$S/pausegit:$PATH" \
		"$@" >"$S/paused.out" 2>"$S/paused.err" &
	paused_pid=$!
	n=0; while [ ! -e "$S/pause/paused" ] && [ "$n" -lt 300 ]; do sleep 0.1; n=$((n + 1)); done
}
# paused_finish: lets the paused script go on, then shows how it ended.
paused_finish() {
	: >"$S/pause/go"
	rc=0; wait "$paused_pid" || rc=$?
	out=$(cat "$S/paused.out"); err=$(cat "$S/paused.err")
	[ -z "$out" ] || echo "$out" | show | sed 's/^/    out: /'
	[ -z "$err" ] || echo "$err" | show | sed 's/^/    err: /'
	echo "    [exit $rc]"
}
count_type() { sh $EV/internal/events-read.sh --effort "$1" --type "$2" | jq 'length'; }
# One recorded yes at the drop's gate through the real hooks: subject $2,
# the human's answer the yes label.
yes_n=0
drop_yes() { # $1 effort, $2 subject
	yes_n=$((yes_n + 1)); t="drop-yes-$yes_n"
	printf 'Drop %s?\n' "$2" >"$S/yes-card.md"
	sh $GT/scripts/main/show-card.sh --record drop-worktree --effort "$1" --subject "$2" --accept 'Drop it (Recommended)' "$S/yes-card.md" >/dev/null
	jq -cn --rawfile m "$S/yes-card.md" '{session_id: "sess-gm", last_assistant_message: $m}' | sh $GT/hooks/stop/require-card-shown.sh >/dev/null
	jq -cn --arg t "$t" '{session_id: "sess-gm", tool_name: "AskUserQuestion", tool_use_id: $t, tool_input: {questions: [{question: "Drop the tree?", header: "Drop", multiSelect: false, options: [{label: "Drop it (Recommended)", description: "its commits go"}, {label: "Keep it", description: "nothing changes"}]}]}}' \
		| sh $GT/hooks/pre-tool-use/hold-question-until-card-shown.sh >/dev/null
	jq -cn --arg t "$t" '{session_id: "sess-gm", tool_name: "AskUserQuestion", tool_use_id: $t, tool_response: {answers: {"Drop the tree?": "Drop it (Recommended)"}}}' \
		| sh $GT/hooks/post-tool-use/record-gate-answer.sh
}
cut_tree "$F" race; printf 'race\n' >"$F/worktrees/race/race.txt"; tree_commit race "$F" >/dev/null
drop_yes "$F" "race:$(tip race)"
# The drop removes the tree's branch, so the refs are compared without it.
other_refs() { index_refs | grep -v "/crucible/$FN/race "; }
FILES0=$(files); IR0=$(other_refs); N0=$(count_type "$F" mount.made)
paused_start 'apply --binary --whitespace=nowarn' 'apply --binary --whitespace=nowarn' sh $GM/main/mount-apply.sh --effort "$F" --name race
run sh $GW/main/worktree-drop.sh --effort "$F" --name race
paused_finish
check "mount-apply.sh, its tree dropped after the apply: exit 2, no mount.made, the checkout, index and other refs as before, no record" is "$rc:$(has "$err" 'tree race was dropped while mount-apply.sh ran; no mount.made was written' && echo y):$(count_type "$F" mount.made):$(files):$([ -e "$REC" ] && echo there):$(other_refs)" "2:y:$N0:$FILES0::$IR0"

echo
echo "=== an effort that is not open"
sh $EF/main/effort-pause.sh --effort "$F" --words 'a break' >/dev/null
run sh $GM/main/mount-apply.sh --effort "$F" --name one
check "a paused effort: exit 2" is "$rc:$(has "$err" 'the effort is paused' && echo y)" "2:y"
sh $EF/main/effort-resume.sh --effort "$F" --words 'back' >/dev/null

echo
echo "=== mount-undo.sh when the effort that made the mount is gone"
run sh $GM/main/mount-apply.sh --effort "$F" --name two
mv "$F" "$S/moved-effort"
run sh $GM/main/mount-undo.sh --repo "$S/repo"
mv "$S/moved-effort" "$F"
check "exit 0, undone, event null, stderr says no mount.undone written" is "$rc:$(echo "$out" | jq -c '[.forgotten, .event]'):$(has "$err" 'no mount.undone written' && echo y):$([ -e "$S/repo/t.txt" ] && echo t)" "0:[false,null]:y:"

echo
echo "=== open-work.sh and effort-close.sh"
C=$(sh $EF/main/effort-start.sh --name closing)
sh $GI/main/identity-list.sh >"$S/list.json" 2>/dev/null
sh $GI/main/identity-card.sh --list "$S/list.json" --repo "$S/repo" >"$S/card.md"
sh $GI/main/identity-card.sh --list "$S/list.json" --repo "$S/repo" --question >"$S/q.json"
pick "$C" "$REPO:$(shasum -a 256 "$S/list.json" | cut -d ' ' -f 1)" "$S/card.md" "$S/q.json" "$(jq -r '[.[] | select(.signing.format == "ssh")][0].label' "$S/list.json")"
sh $GI/main/identity-set.sh --effort "$C" --repo "$S/repo" --list "$S/list.json" >/dev/null
cut_tree "$C" only; printf 'c\n' >"$C/worktrees/only/c.txt"; tree_commit only "$C" >/dev/null
run sh $GM/main/mount-apply.sh --effort "$C" --name only
run sh $GM/internal/open-work.sh --effort "$C"
check "open-work.sh names the mount in place" is "$out" "mount $REPO only"
run sh $EF/main/effort-close.sh --effort "$C" --outcome done --words 'finished'
check "core's effort-close.sh refuses while the mount is in place, naming it" is "$rc:$(has "$err" "mount $REPO only" && echo y)" "2:y"
run sh $GM/main/mount-undo.sh --repo "$S/repo"
run sh $EF/main/effort-close.sh --effort "$C" --outcome done --words 'finished'
check "once undone, the mount is no longer named (the live tree still is)" is "$rc:$(has "$err" "mount $REPO" && echo y):$(has "$err" 'worktree only' && echo y)" "2::y"
mkdir -p "$REC"; printf 'x\n' >"$REC/mount.patch"; printf '{"version":2}\n' >"$REC/mount.json"
run sh $GM/internal/open-work.sh --effort "$C"
check "open-work.sh on a record it can't read: exit 4, so a close is refused" is "$rc:$(has "$err" 'could not be read' && echo y)" "4:y"
rm -rf "$REC"
run sh $GM/internal/open-work.sh --effort "$S/repo"
check "open-work.sh --effort no effort folder: exit 2" is "$rc" 2
run sh $GM/internal/open-work.sh --effort
check "open-work.sh --effort with no value: exit 2" is "$rc" 2

echo
echo "=== a saved patch that no longer reverses, and missing neighbours"
run sh $GM/main/mount-apply.sh --effort "$F" --name one
cp "$REC/mount.patch" "$S/real.patch"
git -C "$S/repo" diff-tree -p --binary --full-index "$HEAD0" "$TWO" >"$REC/mount.patch"
FILES1=$(files)
run sh $GM/main/mount-undo.sh --repo "$S/repo"
check "mount-undo.sh: git apply -R --check refuses the saved patch: exit 2, nothing touched" is "$rc:$(has "$err" 'git apply -R --check refused the saved patch' && echo y):$(files)" "2:y:$FILES1"
cp "$S/real.patch" "$REC/mount.patch"
run sh $GM/main/mount-undo.sh --repo "$S/repo"
check "with the real patch back, undone" is "$rc" 0
K2="$S/k2/skills"; mkdir -p "$K2"; for d in crucible-events crucible-effort git-mount; do ln -s "$(readlink "$K/$d")" "$K2/$d"; done
run sh $K2/git-mount/scripts/main/mount-apply.sh --effort "$F" --name one
echo mount-apply.sh >>"$S/ran"
check "mount-apply.sh with git-worktree not beside it: exit 2, install first" is "$rc:$(has "$err" "a neighbour isn't beside this skill" && echo y)" "2:y"
rm "$K2/crucible-events"
run sh $K2/git-mount/scripts/main/mount-undo.sh --repo "$S/repo"
echo mount-undo.sh >>"$S/ran"
check "mount-undo.sh with core not beside it: exit 2, install first" is "$rc:$(has "$err" "core isn't beside this skill" && echo y)" "2:y"

echo
echo "=== the flow step"
run sh $K/crucible-adaptive-flow/scripts/main/flow-candidates.sh --stage deliver
check "git-mount/mount is listed under deliver, ending with mount.made" has "$out" 'git-mount/mount · .* · ends with mount.made · stages: deliver · skills: git-mount · propose when: the human wants to try a tree'"'"'s work in their own checkout'
echo '{"goal":"Try the work","steps":[{"id":1,"step":"git-mount/mount"}]}' >"$S/flow.json"
sh $K/crucible-adaptive-flow/scripts/main/flow-card.sh --file "$S/flow.json" >"$S/flow-card.md"
FSHA=$(shasum -a 256 "$S/flow.json" | cut -d ' ' -f 1)
sh $GT/scripts/main/show-card.sh --record flow-agree --effort "$F" --subject "$FSHA" --accept "Agree the flow (Recommended)" "$S/flow-card.md" >/dev/null
jq -cn --rawfile m "$S/flow-card.md" '{session_id: "sess-gm", last_assistant_message: $m}' | sh $GT/hooks/stop/require-card-shown.sh >/dev/null
jq -cn '{session_id: "sess-gm", tool_name: "AskUserQuestion", tool_use_id: "t-flow", tool_input: {questions: [{question: "Agree the flow?", header: "Flow", multiSelect: false, options: [{label: "Agree the flow (Recommended)", description: "yes"}, {label: "Change it", description: "no"}]}]}}' | sh $GT/hooks/pre-tool-use/hold-question-until-card-shown.sh >/dev/null
jq -cn '{session_id: "sess-gm", tool_name: "AskUserQuestion", tool_use_id: "t-flow", tool_response: {answers: {"Agree the flow?": "Agree the flow (Recommended)"}}}' | sh $GT/hooks/post-tool-use/record-gate-answer.sh
FLOW=$(sh $K/crucible-adaptive-flow/scripts/main/flow-agree.sh --effort "$F" --file "$S/flow.json")
run sh $GM/main/mount-apply.sh --effort "$F" --name one
run sh $K/crucible-adaptive-flow/scripts/main/flow-step-done.sh --flow "$FLOW" --step 1
check "the step is ended by mount.made" is "$rc" 0
run sh $GM/main/mount-undo.sh --repo "$S/repo"

echo
echo "=== the rules: writer and shape"
forge() { printf '%s' "$3" >"$S/forged.json"; run sh $EV/internal/event-write.sh --effort "$F" --type "$1" --by "$2" --body-file "$S/forged.json"; }
forge mount.made main.sh "{\"repo\":\"$REPO\",\"names\":[\"one\"],\"target\":\"$ONE\",\"start\":\"$HEAD0\",\"paths\":1}"
check "mount.made by another writer: refused" is "$rc:$(has "$err" 'written only by mount-apply.sh' && echo y)" "2:y"
forge mount.made mount-apply.sh '{"repo":"r","names":["one",7],"target":"x","start":"y","paths":0,"extra":1}'
check "mount.made of the wrong shape: one reason per field, a name not a string" is "$rc:$(for w in 'extra is not' 'repo must' 'names must be a non-empty array of tree names' 'target and start' 'paths must'; do has "$err" "$w" || echo "miss $w"; done)" "2:"
forge mount.made mount-apply.sh "{\"repo\":\"$REPO\",\"names\":[\"one\",\"one\"],\"target\":\"$ONE\",\"start\":\"$HEAD0\",\"paths\":1.5}"
check "mount.made with a name twice and paths not whole: refused" is "$rc:$(has "$err" 'each once' && echo y):$(has "$err" 'whole number' && echo y)" "2:y:y"
forge mount.undone main.sh "{\"repo\":\"$REPO\",\"forgotten\":false}"
check "mount.undone by another writer: refused" is "$rc:$(has "$err" 'written only by mount-undo.sh' && echo y)" "2:y"
forge mount.undone mount-undo.sh '{"repo":"/never/mounted","forgotten":"no","x":1}'
check "mount.undone of the wrong shape: no mount there, forgotten not a boolean, an unknown field" is "$rc:$(for w in 'x is not' 'made no mount in' 'forgotten must'; do has "$err" "$w" || echo "miss $w"; done)" "2:"
forge mount.undone mount-undo.sh '{"repo":"rel","forgotten":true}'
check "mount.undone with repo not absolute: refused" is "$rc:$(has "$err" 'repo must be an absolute folder' && echo y)" "2:y"

echo
echo "=== the scripts' contracts"
for p in "$GM"/main/*.sh "$GM"/internal/*.sh; do
	s=${p##*/}
	sh "$p" --help >"$S/help" 2>&1; h=$?
	sh "$p" --bogus >/dev/null 2>&1; b=$?
	echo "$s" >>"$S/ran"
	check "$s: --help exits 0 in at most 25 lines, an unknown option exits 2" is "$h:$b:$([ "$(wc -l <"$S/help")" -le 25 ] && echo short)" "0:2:short"
done
check "shellcheck -x -o all is clean" shellcheck -x -o all "$R"/domains/software-development/core/main-thread/git-mount/scripts/main/*.sh "$R"/domains/software-development/core/main-thread/git-mount/scripts/internal/*.sh "$R"/domains/software-development/core/main-thread/git-mount/scripts/lib/*.sh

echo
echo "=== coverage: every script under scripts/ ran on a case"
for p in "$R"/domains/software-development/core/main-thread/git-mount/scripts/main/*.sh "$R"/domains/software-development/core/main-thread/git-mount/scripts/internal/*.sh; do
	s=${p##*/}
	cases=$(grep -cx -- "$s" "$S/ran")
	check "$s ran on a case ($((cases - 1)) runs)" test "$cases" -gt 1
done

echo
echo "=== $pass PASS, $fail FAIL"
[ "$fail" -eq 0 ]
