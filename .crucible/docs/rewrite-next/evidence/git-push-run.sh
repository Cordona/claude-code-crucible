# Evidence run for git-push: every case through the installed layout (a
# scratch skills folder of links), from /. Its own HOME and git config, no
# keys at all (the trees' commits are plain ones made by hand), and no
# network: the remotes are a scratch bare repository on disk, a fake ssh
# that hangs or runs git-receive-pack locally, and a fake remote helper that
# asks for a credential. Trees are cut and moved through git-worktree's real
# scripts; the human's yes goes through the gate's real hooks.
R=/Users/cordona/IdeaProjects/cordona/claude-code-crucible/new-rewrite
S=/private/tmp/claude-501/-Users-cordona-IdeaProjects-cordona-claude-code-crucible/480d0359-cf0d-4c14-a59e-2a72be5dba4f/scratchpad/gpush; rm -rf "$S"; mkdir -p "$S/home" "$S/xdg" "$S/cfg/skills" "$S/bin"
# Stops only what this run started: the hanging transports it made (their
# PIDs written by the fake ssh itself) and a push left in the background.
cleanup() {
	[ ! -f "$S/hang.pids" ] || while IFS= read -r p; do kill "$p" 2>/dev/null; done <"$S/hang.pids"
	[ -z "${BG-}" ] || kill "$BG" 2>/dev/null
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
export HOME="$S/home" XDG_CONFIG_HOME="$S/xdg" GIT_CONFIG_GLOBAL="$S/home/.gitconfig" GIT_CONFIG_NOSYSTEM=1
export CRUCIBLE_HOME="$S/space" CLAUDE_CONFIG_DIR="$S/cfg" CLAUDE_CODE_SESSION_ID=sess-gp
export PATH="$S/bin:$PATH"
# A prompt anywhere would show here: the askpass programs a push could
# reach only note that they were asked.
export GIT_ASKPASS="$S/bin/askpass" SSH_ASKPASS="$S/bin/askpass"
export GIT_SSH_COMMAND="sh $S/bin/fake-ssh"
unset SSH_AUTH_SOCK SSH_AGENT_PID GIT_CONFIG_COUNT
cd /
K="$S/cfg/skills"
for d in "$R"/framework/core/main-thread/*/ "$R"/domains/software-development/core/main-thread/*/; do d=${d%/}; ln -s "$d" "$K/${d##*/}"; done
GP=$K/git-push/scripts; GW=$K/git-worktree/scripts; GT=$K/crucible-gate
EV=$K/crucible-events/scripts; EF=$K/crucible-effort/scripts; DF=$K/crucible-adaptive-flow/scripts

pass=0 fail=0
: >"$S/ran"
show() { sed "s|$S|<S>|g;s|[0-9]\{8\}T[0-9]\{6\}-[0-9a-f]\{4\}|<id>|g;s|[0-9a-f]\{40\}|<sha>|g"; }
# Runs "$@", keeping stdout in $out, stderr in $err and the exit in $rc, and
# shows them; notes each git-push script it runs for the coverage check.
run() {
	for a in "$@"; do case $a in "$GP"/main/*.sh | */git-push/scripts/main/*.sh) echo "${a##*/}" >>"$S/ran" ;; esac; done
	echo "  \$ $(echo "$*" | sed "s|$GP/||g;s|$K/||g" | show)"
	"$@" >"$S/out" 2>"$S/err"; rc=$?
	out=$(cat "$S/out"); err=$(cat "$S/err")
	[ -z "$out" ] || echo "$out" | show | sed 's/^/    out: /'
	[ -z "$err" ] || echo "$err" | show | sed 's/^/    err: /'
	echo "    [exit $rc]"
}
# check WHAT CONDITION...: PASS when the condition command succeeds.
check() {
	what=$1; shift
	if "$@" >/dev/null 2>&1; then pass=$((pass + 1)); echo "  PASS: $what"
	else fail=$((fail + 1)); echo "  FAIL: $what"; fi
}
is() { [ "$1" = "$2" ]; }
has() { printf '%s' "$1" | grep -q -- "$2"; }
last_event() { sh $EV/internal/events-read.sh --effort "$1" --type "$2" | jq -c 'last'; }
count_type() { sh $EV/internal/events-read.sh --effort "$1" --type "$2" | jq 'length'; }
yes_n=0 n_commit=0
# One recorded yes gate through the real hooks: record push-tree, subject
# $2, the human's answer $3 (the yes label, or another).
yes_gate() { # $1 effort, $2 subject, $3 the human's answer
	yes_n=$((yes_n + 1)); t="yes-$yes_n"
	printf '%s\n' "Push $2 to the remote?" >"$S/yes-card.md"
	sh $GT/scripts/main/show-card.sh --record "${4:-push-tree}" --effort "$1" --subject "$2" --accept 'Push it (Recommended)' "$S/yes-card.md" >/dev/null
	jq -cn --rawfile m "$S/yes-card.md" '{session_id: "sess-gp", last_assistant_message: $m}' | sh $GT/hooks/stop/require-card-shown.sh >/dev/null
	jq -cn --arg t "$t" '{session_id: "sess-gp", tool_name: "AskUserQuestion", tool_use_id: $t, tool_input: {questions: [{question: "Push the tree?", header: "Push", multiSelect: false, options: [{label: "Push it (Recommended)", description: "it goes public"}, {label: "Not now", description: "nothing is pushed"}]}]}}' \
		| sh $GT/hooks/pre-tool-use/hold-question-until-card-shown.sh >/dev/null
	jq -cn --arg t "$t" --arg a "$3" '{session_id: "sess-gp", tool_name: "AskUserQuestion", tool_use_id: $t, tool_response: {answers: {"Push the tree?": $a}}}' \
		| sh $GT/hooks/post-tool-use/record-gate-answer.sh
}
yes_seq() { sh $GT/scripts/internal/gate-answer.sh --effort "$1" --record push-tree --subject "$2" | sed 's/^ACCEPTED: //'; }
# A plain commit of file $2 in tree $1 of effort $3, made by hand.
tree_commit() {
	n_commit=$((n_commit + 1))
	printf '%s\n' "$2 $n_commit" >"$3/worktrees/$1/$2"
	git -C "$3/worktrees/$1" add "$2"
	git -C "$3/worktrees/$1" -c user.name=Worker -c user.email=worker@example.test commit -q -m "change $2 in $1"
	git -C "$3/worktrees/$1" rev-parse HEAD
}
tip() { git -C "$S/repo" rev-parse "refs/heads/$(branch "$1" "${2:-$F}")"; }
branch() { b=${2:-$F}; echo "crucible/${b##*/}/$1"; }
on_remote() { git -C "$S/remote.git" rev-parse --verify --quiet "refs/heads/$1" 2>/dev/null; }
# Writes an event file by hand, as a log edited outside the writer would be.
hand_event() { # $1 effort, $2 type, $3 body JSON
	n=$(($(sh $EV/internal/events-read.sh --effort "$1" | jq length) + 1))
	jq -n --arg t "$2" --argjson s "$n" --argjson b "$3" '{type: $t, seq: $s, at: "2026-11-22T00:00:00Z", by: "worktree-cut.sh", claude_session_id: null, body: $b}' \
		>"$1/events/$(printf '%06d' "$n")-$2.json"
	chmod 444 "$1/events/$(printf '%06d' "$n")-$2.json"
}

echo "=== set-up: the fakes, a scratch repository, a bare remote, an effort with a tree"
cat >"$S/bin/askpass" <<EOF
#!/bin/sh
echo "\$*" >>"$S/asked"
echo secret
EOF
# The fake ssh: hang.example.test notes its PID and hangs; slow.example.test
# waits, then runs the remote command locally, as sshd would.
cat >"$S/bin/fake-ssh" <<EOF
echo "\$*" >>"$S/ssh-args"
for a in "\$@"; do last=\$a; case \$a in *.example.test) host=\$a ;; esac; done
case \$host in
	hang.example.test) echo \$\$ >>"$S/hang.pids"; exec sleep 60 ;;
	slow.example.test) sleep 4; exec sh -c "\$last" ;;
esac
exit 255
EOF
# A remote helper for fake:: URLs that asks git for a credential first, as
# an https transport does, and notes what git said.
cat >"$S/bin/git-remote-fake" <<EOF
#!/bin/sh
printf 'protocol=https\nhost=example.test\n\n' | git credential fill >"$S/cred.out" 2>"$S/cred.err"
echo "credential exit \$?" >>"$S/cred.err"
exit 1
EOF
chmod 755 "$S/bin/askpass" "$S/bin/git-remote-fake"
git init -q -b main "$S/repo"
printf 'base\n' >"$S/repo/f.txt"; git -C "$S/repo" add f.txt; git -C "$S/repo" -c user.name=Human -c user.email=human@example.test commit -q -m base
HEAD0=$(git -C "$S/repo" rev-parse HEAD)
git init -q --bare "$S/remote.git"
git -C "$S/repo" remote add origin "$S/remote.git"
REPO=$(cd "$S/repo" && pwd -P)
F=$(sh $EF/main/effort-start.sh --name push-work); FN=${F##*/}
sh $GW/main/worktree-cut.sh --effort "$F" --repo "$S/repo" --name one --from checkout >/dev/null 2>&1
ONE1=$(tree_commit one a.txt "$F")
check "tree one is cut through git-worktree and holds a commit" is "$(git -C "$S/repo" rev-parse "$(branch one)"):$(sh $GW/internal/worktree-trees.sh --effort "$F" --name one | jq -r '.[0].branch')" "$ONE1:crucible/$FN/one"

echo
echo "=== push-remote.sh"
run sh $GP/main/push-remote.sh --repo "$S/repo" --remote origin
check "origin: exit 0, {remote, urls}" is "$rc:$out" "0:{\"remote\":\"origin\",\"urls\":[\"$S/remote.git\"]}"
run sh $GP/main/push-remote.sh --repo "$F/worktrees/one" --remote origin
check "from a tree of the repository: exit 0" is "$rc" 0
run sh $GP/main/push-remote.sh --repo "$S/repo" --remote upstream
check "a remote not configured: exit 2, add it first" is "$rc:$(has "$err" 'has no remote upstream; add it first' && echo y)" "2:y"
git -C "$S/repo" remote add self "$S/repo"
git -C "$S/repo" remote add selfgit "file://$S/repo/.git"
git -C "$S/repo" remote add dot .
git -C "$S/repo" remote add tree "$F/worktrees/one"
for r in self selfgit dot tree; do
	run sh $GP/main/push-remote.sh --repo "$S/repo" --remote "$r"
	check "remote $r (the repository by path, file:// git folder, relative ., one of its worktrees): exit 2, is the repository itself" is "$rc:$(has "$err" "remote $r is the repository itself" && echo y)" "2:y"
done
git -C "$S/repo" remote add sneaky "$S/remote.git"; git -C "$S/repo" remote set-url --push sneaky "$S/repo"
run sh $GP/main/push-remote.sh --repo "$S/repo" --remote sneaky
check "a remote whose push URL alone is the repository: exit 2" is "$rc:$(has "$err" 'sneaky is the repository itself' && echo y)" "2:y"
git -C "$S/repo" remote add twice "$S/remote.git"; git -C "$S/repo" remote set-url --add --push twice "$S/remote.git"; git -C "$S/repo" remote set-url --add --push twice "$S/repo/.git"
run sh $GP/main/push-remote.sh --repo "$S/repo" --remote twice
check "a remote with two push URLs, the second the repository's git folder: exit 2" is "$rc:$(has "$err" 'twice is the repository itself' && echo y)" "2:y"
mkdir -p "$S/repo/sub"; git -C "$S/repo" remote add subdir "$S/repo/sub"
git -C "$S/repo" remote add slow "ssh://slow.example.test$S/remote.git"
run sh $GP/main/push-remote.sh --repo "$S/repo" --remote subdir
check "a folder inside the checkout that is no repository: not the repository itself, exit 0" is "$rc" 0
run sh $GP/main/push-remote.sh --repo "$S/repo" --remote slow
check "an ssh URL: not checked as a folder, exit 0" is "$rc:$(echo "$out" | jq -r '.urls[0]')" "0:ssh://slow.example.test$S/remote.git"
run sh $GP/main/push-remote.sh --repo "$S/repo" --remote -x
check "a remote starting with -: exit 2" is "$rc:$(has "$err" 'starts with -' && echo y)" "2:y"
run sh $GP/main/push-remote.sh --repo "$S/repo" --remote 'a b'
check "a remote with a space: exit 2" is "$rc:$(has "$err" 'holds a space' && echo y)" "2:y"
run sh $GP/main/push-remote.sh --repo "$S/repo"
check "no --remote: exit 2" is "$rc:$(has "$err" '--remote needs a name' && echo y)" "2:y"
run sh $GP/main/push-remote.sh --repo repo --remote origin
check "a relative --repo: exit 2" is "$rc:$(has "$err" 'must be an absolute folder' && echo y)" "2:y"
run sh $GP/main/push-remote.sh --repo "$S/home" --remote origin
check "a --repo in no repository: exit 2" is "$rc:$(has "$err" 'is not in a git repository' && echo y)" "2:y"
run sh $GP/main/push-remote.sh --repo
check "an option without its value: exit 2" is "$rc:$(has "$err" '--repo needs a value' && echo y)" "2:y"

echo
echo "=== push-tree.sh: the human's yes"
run sh $GP/main/push-tree.sh --effort "$F" --name one --remote origin
check "no recorded yes: exit 2, naming record and subject, nothing on the remote" is "$rc:$(has "$err" "record push-tree, subject one:$ONE1" && echo y):$(on_remote "$(branch one)")" "2:y:"
yes_gate "$F" "one:$ONE1" 'Not now'
run sh $GP/main/push-tree.sh --effort "$F" --name one --remote origin
check "the human said no: exit 2, nothing on the remote" is "$rc:$(on_remote "$(branch one)")" "2:"
yes_gate "$F" "one:$ONE1" 'Push it (Recommended)' push-other
run sh $GP/main/push-tree.sh --effort "$F" --name one --remote origin
check "a yes under another record does not count: exit 2" is "$rc" 2
yes_gate "$F" "one:$ONE1" 'Push it (Recommended)'
YES1=$(yes_seq "$F" "one:$ONE1")
rm -f "$S/asked"
run sh $GP/main/push-tree.sh --effort "$F" --name one --remote origin
check "with the yes: exit 0, {name, remote, branch, commit, lease null, event}" is "$rc:$(echo "$out" | jq -c '[.name, .remote, .branch, .commit == "'"$ONE1"'", .lease]')" "0:[\"one\",\"origin\",\"crucible/$FN/one\",true,null]"
check "the remote's branch of the same name is at the tip" is "$(on_remote "$(branch one)")" "$ONE1"
E=$(last_event "$F" push.made)
check "push.made read back: by push-tree.sh, {name, remote, commit, answer}, its path printed" is "$(echo "$E" | jq -c '[.by, .body]'):$(echo "$out" | jq -r .event)" "[\"push-tree.sh\",{\"name\":\"one\",\"remote\":\"origin\",\"commit\":\"$ONE1\",\"answer\":$YES1}]:$(sh $EV/internal/events-read.sh --effort "$F" --paths | tail -n 1)"
check "no askpass program was asked" is "$([ -e "$S/asked" ] && echo asked)" ""
check "the push set no upstream and wrote nothing to the repository's config" is "$(git -C "$S/repo" config --get "branch.crucible/$FN/one.remote")" ""
run sh $GP/main/push-tree.sh --effort "$F" --name one --remote origin
check "the same yes again: exit 2, already pushed" is "$rc:$(has "$err" "yes $YES1 already pushed" && echo y)" "2:y"
ONE2=$(tree_commit one b.txt "$F")
run sh $GP/main/push-tree.sh --effort "$F" --name one --remote origin
check "a new tip needs a new yes: exit 2, the remote unchanged" is "$rc:$(has "$err" "subject one:$ONE2" && echo y):$(on_remote "$(branch one)")" "2:y:$ONE1"
yes_gate "$F" "one:$ONE2" 'Push it (Recommended)'
run sh $GP/main/push-tree.sh --effort "$F" --name one --remote origin --timeout 30
check "--timeout 30, a fast-forward: exit 0, no lease, the remote at the new tip" is "$rc:$(echo "$out" | jq -c .lease):$(on_remote "$(branch one)")" "0:null:$ONE2"

echo
echo "=== push-tree.sh: after a move, by lease"
sh $GW/main/worktree-move.sh --effort "$F" --name one --to "$HEAD0" >/dev/null
ONE3=$(tree_commit one c.txt "$F")
check "tree one moved back to the base and made new work: its tip leaves the pushed one out" is "$(git -C "$S/repo" merge-base --is-ancestor "$ONE2" "$ONE3" && echo holds):$(count_type "$F" worktree.moved)" ":1"
yes_gate "$F" "one:$ONE3" 'Push it (Recommended)'
run sh $GP/main/push-tree.sh --effort "$F" --name one --remote origin
check "exit 0, lease the last push's commit, the remote branch replaced" is "$rc:$(echo "$out" | jq -r .lease):$(on_remote "$(branch one)")" "0:$ONE2:$ONE3"
ONE4=$(tree_commit one d.txt "$F")
yes_gate "$F" "one:$ONE4" 'Push it (Recommended)'
run sh $GP/main/push-tree.sh --effort "$F" --name one --remote origin
check "the next push after it: the move is older than the last push, no lease" is "$rc:$(echo "$out" | jq -c .lease):$(on_remote "$(branch one)")" "0:null:$ONE4"
echo "--- a lease that fails: someone else pushed after the tree moved"
sh $GW/main/worktree-move.sh --effort "$F" --name one --to "$HEAD0" >/dev/null
ONE5=$(tree_commit one e.txt "$F")
git clone -q "$S/remote.git" "$S/other" 2>/dev/null
git -C "$S/other" checkout -q "$(branch one)"
printf 'theirs\n' >"$S/other/theirs.txt"; git -C "$S/other" add theirs.txt
git -C "$S/other" -c user.name=Other -c user.email=other@example.test commit -q -m theirs
git -C "$S/other" push -q origin "$(branch one)"
THEIRS=$(git -C "$S/other" rev-parse HEAD)
yes_gate "$F" "one:$ONE5" 'Push it (Recommended)'
N0=$(count_type "$F" push.made)
run sh $GP/main/push-tree.sh --effort "$F" --name one --remote origin
check "exit 5: the remote branch is no longer at the last push; nothing forced, no push.made" is "$rc:$(has "$err" "no longer at $ONE4" && echo y):$(on_remote "$(branch one)"):$(count_type "$F" push.made)" "5:y:$THEIRS:$N0"
echo "--- a tree that never moved, behind the remote"
sh $GW/main/worktree-cut.sh --effort "$F" --repo "$S/repo" --name three --from checkout >/dev/null 2>&1
THREE1=$(tree_commit three a.txt "$F")
yes_gate "$F" "three:$THREE1" 'Push it (Recommended)'
sh $GP/main/push-tree.sh --effort "$F" --name three --remote origin >/dev/null; echo push-tree.sh >>"$S/ran"
git -C "$S/other" fetch -q origin; git -C "$S/other" checkout -q "$(branch three)"
printf 'theirs\n' >"$S/other/t3.txt"; git -C "$S/other" add t3.txt
git -C "$S/other" -c user.name=Other -c user.email=other@example.test commit -q -m theirs3; git -C "$S/other" push -q origin "$(branch three)"
THREE2=$(tree_commit three b.txt "$F")
yes_gate "$F" "three:$THREE2" 'Push it (Recommended)'
run sh $GP/main/push-tree.sh --effort "$F" --name three --remote origin
check "exit 5: rejected, the remote holds commits the tree lacks; nothing forced" is "$rc:$(has "$err" 'holds commits this tree lacks; nothing was forced' && echo y):$(on_remote "$(branch three)")" "5:y:$(git -C "$S/other" rev-parse HEAD)"

echo
echo "=== push-tree.sh: never waits, never asks"
git -C "$S/repo" remote add hang "ssh://hang.example.test/x.git"
: >"$S/ssh-args"
yes_gate "$F" "one:$ONE5" 'Push it (Recommended)'
start=$(date +%s)
run sh $GP/main/push-tree.sh --effort "$F" --name one --remote hang --timeout 2
took=$(($(date +%s) - start))
HP=$(tail -n 1 "$S/hang.pids")
check "a remote that hangs: exit 5, timed out after 2 s, back within 10 s" is "$rc:$(has "$err" 'timed out after 2 s' && echo y):$([ "$took" -lt 10 ] && echo fast)" "5:y:fast"
check "the hanging transport was stopped by its PID" is "$(kill -0 "$HP" 2>/dev/null && echo alive)" ""
check "ssh was told never to ask: BatchMode=yes and a connect time limit" is "$(has "$(cat "$S/ssh-args")" '-o BatchMode=yes -o ConnectTimeout=10' && echo y)" y
check "no push.made for the timed-out push" is "$(last_event "$F" push.made | jq -r .body.remote)" origin
git -C "$S/repo" remote add fake "fake::anything"
rm -f "$S/asked"
printf 'protocol=https\nhost=example.test\n\n' | GIT_TERMINAL_PROMPT=0 git credential fill >/dev/null 2>&1
check "control: outside push-tree.sh, a credential request reaches the askpass program" is "$([ -e "$S/asked" ] && echo asked)" asked
rm -f "$S/asked"
run sh $GP/main/push-tree.sh --effort "$F" --name one --remote fake
check "a remote asking for a credential: exit 5, the push failed" is "$rc:$(has "$err" 'failed (exit' && echo y)" "5:y"
check "git refused to prompt (terminal prompts disabled), and no askpass program was asked" is "$(has "$(cat "$S/cred.err")" 'terminal prompts disabled' && echo y):$([ -e "$S/asked" ] && echo asked)" "y:"

echo
echo "=== push-tree.sh: the push lands but its event can't be written"
sh $GW/main/worktree-cut.sh --effort "$F" --repo "$S/repo" --name two --from checkout >/dev/null 2>&1
TWO1=$(tree_commit two a.txt "$F")
yes_gate "$F" "two:$TWO1" 'Push it (Recommended)'
yes_gate "$F" "two:$TWO1" 'Push it (Recommended)' drop-worktree
echo push-tree.sh >>"$S/ran"
sh $GP/main/push-tree.sh --effort "$F" --name two --remote slow >"$S/bg.out" 2>"$S/bg.err" &
BG=$!
sleep 2
sh $GW/main/worktree-drop.sh --effort "$F" --name two >/dev/null 2>&1
wait "$BG"; rc=$?; BG=''
echo "  (tree two dropped while its push ran through the slow fake ssh)"; sed 's/^/    err: /' "$S/bg.err" | show; echo "    [exit $rc]"
check "exit 4: pushed, but push.made was not written (the tree is no longer live)" is "$rc:$(has "$(cat "$S/bg.err")" 'is pushed to slow at' && echo y):$(on_remote "$(branch two)")" "4:y:$TWO1"
check "no push.made names tree two" is "$(sh $EV/internal/events-read.sh --effort "$F" --type push.made | jq '[.[] | select(.body.name == "two")] | length')" 0
sh $GW/main/worktree-cut.sh --effort "$F" --repo "$S/repo" --name four --from checkout >/dev/null 2>&1
FOUR1=$(tree_commit four a.txt "$F")
yes_gate "$F" "four:$FOUR1" 'Push it (Recommended)'
N0=$(count_type "$F" push.made)
mkdir "$F/events/.lock"; echo $$ >"$F/events/.lock/pid"
run sh $GP/main/push-tree.sh --effort "$F" --name four --remote origin
rm -rf "$F/events/.lock"
check "the events lock held: exit 6, pushed, no push.made" is "$rc:$(has "$err" 'is pushed to origin at' && echo y):$(on_remote "$(branch four)"):$(count_type "$F" push.made)" "6:y:$FOUR1:$N0"
run sh $GP/main/push-tree.sh --effort "$F" --name four --remote origin
check "run again: the unused yes still counts, the remote already holds it, push.made written" is "$rc:$(last_event "$F" push.made | jq -c '[.body.name, .body.commit == "'"$FOUR1"'"]')" '0:["four",true]'

echo
echo "=== push-tree.sh: after the effort ended"
sh $EF/main/effort-close.sh --effort "$F" --outcome done --words 'done, trees left for later' --leave-open >/dev/null
FOUR2=$(tree_commit four b.txt "$F")
yes_gate "$F" "four:$FOUR2" 'Push it (Recommended)'
run sh $GP/main/push-tree.sh --effort "$F" --name four --remote origin
CLOSED=$(last_event "$F" effort.closed | jq .seq)
check "a closed effort's tree: exit 0, pushed, push.made written after effort.closed, the effort still closed" is "$rc:$(on_remote "$(branch four)"):$([ "$(last_event "$F" push.made | jq .seq)" -gt "$CLOSED" ] && echo after):$(sh $EF/main/effort-state.sh --effort "$F")" "0:$FOUR2:after:closed"

echo
echo "=== push-tree.sh: a tree's branch it must never push (a log edited by hand)"
P=$(sh $EF/main/effort-start.sh --name hand-edited); PN=${P##*/}
cut_body() { jq -cn --arg n "$1" --arg r "$2" --arg b "$3" --arg p "$P/worktrees/$1" --arg base "$HEAD0" '{name: $n, repo: $r, path: $p, branch: $b, base: $base, from: "checkout"}'; }
hand_event "$P" worktree.cut "$(cut_body prot "$S/repo" main)"
hand_event "$P" worktree.cut "$(cut_body rel "$S/repo" release/1.0)"
hand_event "$P" worktree.cut "$(cut_body feat "$S/repo" feature/x)"
hand_event "$P" worktree.cut "$(cut_body away /nonexistent-gp "crucible/$PN/away")"
hand_event "$P" worktree.cut "$(cut_body nobranch "$S/repo" "crucible/$PN/nobranch")"
hand_event "$P" worktree.cut "$(cut_body real "$S/repo" "crucible/$PN/real")"
git -C "$S/repo" branch "crucible/$PN/real" "$HEAD0"
check "the hand-written cuts read back as live trees" is "$(sh $GW/internal/worktree-trees.sh --effort "$P" | jq -c 'map(.name)')" '["prot","rel","feat","away","nobranch","real"]'
for c in "prot:the protected branch main" "rel:the protected branch release/1.0" "feat:feature/x is not a crucible/ branch" "away:is not there" "nobranch:is gone"; do
	run sh $GP/main/push-tree.sh --effort "$P" --name "${c%%:*}" --remote origin
	check "tree ${c%%:*}: exit 2, ${c#*:}, nothing on the remote" is "$rc:$(has "$err" "${c#*:}" && echo y)" "2:y"
done
check "main and release/1.0 are not on the remote" is "$(git -C "$S/remote.git" for-each-ref --format='%(refname)' refs/heads/main refs/heads/release)" ""

echo
echo "=== push-tree.sh: the other refusals"
run sh $GP/main/push-tree.sh --effort "$P" --name real --remote upstream
check "a remote not configured: exit 2, push-remote.sh's reason" is "$rc:$(has "$err" 'push-remote.sh: the repository has no remote upstream' && echo y)" "2:y"
run sh $GP/main/push-tree.sh --effort "$P" --name real --remote self
check "the repository itself as the remote: exit 2" is "$rc:$(has "$err" 'is the repository itself' && echo y)" "2:y"
run sh $GP/main/push-tree.sh --effort "$P" --name nope --remote origin
check "no live tree of that name: exit 2" is "$rc:$(has "$err" 'no live tree named nope' && echo y)" "2:y"
run sh $GP/main/push-tree.sh --effort "$P" --name Bad_Name --remote origin
check "a name that is not lowercase words: exit 2" is "$rc:$(has "$err" 'must be lowercase words joined by dashes' && echo y)" "2:y"
run sh $GP/main/push-tree.sh --effort relative --name real --remote origin
check "a relative --effort: exit 2" is "$rc:$(has "$err" 'must be an absolute folder' && echo y)" "2:y"
run sh $GP/main/push-tree.sh --effort "$S/home" --name real --remote origin
check "a folder that is no effort: exit 2" is "$rc:$(has "$err" 'is not an effort folder' && echo y)" "2:y"
for t in 0 abc 0010 601; do
	run sh $GP/main/push-tree.sh --effort "$P" --name real --remote origin --timeout "$t"
	check "--timeout $t: exit 2" is "$rc:$(has "$err" '--timeout' && echo y)" "2:y"
done
run sh $GP/main/push-tree.sh --effort "$P" --name real --remote origin --bogus x
check "an unknown option: exit 2" is "$rc:$(has "$err" 'unknown argument --bogus' && echo y)" "2:y"
run sh $GP/main/push-tree.sh --effort "$P" --name
check "an option without its value: exit 2" is "$rc:$(has "$err" '--name needs a value' && echo y)" "2:y"
run env TMPDIR=/nonexistent-gp sh $GP/main/push-tree.sh --effort "$P" --name real --remote origin
check "no work folder: exit 4" is "$rc:$(has "$err" 'mktemp could not make a work folder' && echo y)" "4:y"
OPENED="$P/events/000001-effort.opened.json"; cp "$OPENED" "$S/opened.json"; chmod 644 "$OPENED"; echo 'not json' >"$OPENED"
run sh $GP/main/push-tree.sh --effort "$P" --name real --remote origin
cp "$S/opened.json" "$OPENED"; chmod 444 "$OPENED"
check "core's reader failing: exit 4, nothing pushed" is "$rc:$(has "$err" 'events-read.sh failed' && echo y):$(on_remote "crucible/$PN/real")" "4:y:"
mkdir -p "$S/nogit" "$S/nojq"
for t in dirname tr; do ln -s "$(command -v $t)" "$S/nogit/$t"; ln -s "$(command -v $t)" "$S/nojq/$t"; done
ln -s "$(command -v git)" "$S/nojq/git"
for s in push-tree.sh push-remote.sh; do
	case $s in push-tree.sh) set -- --effort "$P" --name real --remote origin ;; *) set -- --repo "$S/repo" --remote origin ;; esac
	run env PATH="$S/nogit" /bin/sh "$GP"/*/"$s" "$@"
	check "$s without git: exit 4" is "$rc:$(has "$err" 'git not found' && echo y)" "4:y"
	run env PATH="$S/nojq" /bin/sh "$GP"/*/"$s" "$@"
	check "$s without jq: exit 4" is "$rc:$(has "$err" 'jq not found' && echo y)" "4:y"
done
K2="$S/k2/skills"; mkdir -p "$K2"; ln -s "$(readlink "$K/git-push")" "$K2/git-push"
run sh "$K2/git-push/scripts/main/push-tree.sh" --effort "$P" --name real --remote origin
check "push-tree.sh with core and git-worktree not beside it: exit 2, install first" is "$rc:$(has "$err" "a neighbour isn't beside this skill" && echo y)" "2:y"
yes_gate "$P" "real:$HEAD0" 'Push it (Recommended)'
run sh $GP/main/push-tree.sh --effort "$P" --name real --remote origin
check "and once the human said yes, the hand-edited effort's crucible tree pushes: exit 0" is "$rc:$(on_remote "crucible/$PN/real")" "0:$HEAD0"

echo
echo "=== the push.made rule"
forge() { printf '%s' "$3" >"$S/forged.json"; run sh $EV/internal/event-write.sh --effort "$F" --type push.made --by "$2" --body-file "$S/forged.json"; }
forge push.made main.sh "{\"name\":\"one\",\"remote\":\"origin\",\"commit\":\"$ONE1\",\"answer\":9999}"
check "by another writer: refused" is "$rc:$(has "$err" 'written only by push-tree.sh' && echo y)" "2:y"
forge push.made push-tree.sh "{\"name\":\"one\",\"remote\":\"origin\",\"commit\":\"$ONE1\",\"answer\":$YES1}"
check "reusing an answer: refused" is "$rc:$(has "$err" "answer $YES1 already pushed" && echo y)" "2:y"
forge push.made push-tree.sh '{"name":2,"remote":"-x","commit":"abc","answer":"yes","x":1}'
check "the wrong shape: one reason per field, a name not a string included" is "$rc:$(for w in 'x is not a push.made field' "name must be a tree's name" 'remote must be' 'commit must be' 'answer must be the seq'; do has "$err" "$w" || echo "miss $w"; done)" "2:"
forge push.made push-tree.sh "{\"name\":\"one\",\"remote\":\"origin\",\"commit\":\"$ONE1\",\"answer\":9999}"
check "a right one, in the closed effort: accepted" is "$rc:$(last_event "$F" push.made | jq .body.answer)" "0:9999"

echo
echo "=== the step and the scripts' contracts"
run sh $DF/main/flow-candidates.sh --stage deliver
check "flow-candidates.sh lists git-push/push-tree, ends with push.made, left nothing out" is "$(printf '%s\n' "$out" | grep '^git-push/push-tree ' | grep -c 'ends with push.made · stages: deliver · skills: git-push'):$(has "$err" 'left out' && echo left)" "1:"
for p in "$GP"/main/*.sh; do
	s=${p##*/}
	sh "$p" --help >"$S/help" 2>&1; h=$?
	sh "$p" --bogus >/dev/null 2>&1; b=$?
	echo "$s" >>"$S/ran"
	check "$s: --help exits 0, an unknown option exits 2" is "$h:$b" "0:2"
	check "  ... and its --help is short: at most 25 lines of at most 80 characters" is "$([ "$(wc -l <"$S/help")" -le 25 ] && echo lines):$(awk 'length > 80' "$S/help" | wc -l | tr -d ' ')" "lines:0"
done
check "shellcheck -x -o all is clean" shellcheck -x -o all "$R"/domains/software-development/core/main-thread/git-push/scripts/main/*.sh "$R"/domains/software-development/core/main-thread/git-push/scripts/lib/*.sh

echo
echo "=== coverage: every script under scripts/ ran on a case"
for p in "$R"/domains/software-development/core/main-thread/git-push/scripts/main/*.sh; do
	s=${p##*/}
	cases=$(grep -cx -- "$s" "$S/ran")
	# Each script also ran once for its contract; a case needs one more.
	check "$s ran on a case ($((cases - 1)) runs)" test "$cases" -gt 1
done

echo
echo "=== $pass PASS, $fail FAIL"
[ "$fail" -eq 0 ]
