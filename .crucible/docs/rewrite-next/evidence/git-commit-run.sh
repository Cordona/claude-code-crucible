# Evidence run for git-commit: every case through the installed layout (a
# scratch skills folder of links), from /. Only scratch keys: its own HOME,
# git config, GnuPG home and ssh agent, so the owner's agent, key ring,
# ~/.ssh and ~/.gnupg are never read. The identities are set through
# git-identity's real scripts and the gate's real hooks.
R=/Users/cordona/IdeaProjects/cordona/claude-code-crucible/new-rewrite
E=/Users/cordona/IdeaProjects/cordona/claude-code-crucible/.crucible/docs/rewrite-next/evidence
S=/private/tmp/claude-501/-Users-cordona-IdeaProjects-cordona-claude-code-crucible/480d0359-cf0d-4c14-a59e-2a72be5dba4f/scratchpad/gcommit; rm -rf "$S"; mkdir -p "$S/home/.ssh" "$S/xdg" "$S/cfg/skills" "$S/msg"
# A Unix socket path holds about 100 bytes, so the GnuPG home and the ssh
# agent's socket sit in a short scratch folder of their own.
T=$(mktemp -d /tmp/gtb.XXXXXX); mkdir -p "$T/gnupg"; chmod 700 "$T/gnupg" "$S/home/.ssh"
# Stops only what this run started: its ssh agent, the hanging signers it
# made (their PIDs written by the signer itself), its own GnuPG home's
# daemons; then removes the short folder.
cleanup() {
	[ -z "${SSH_AGENT_PID-}" ] || kill "$SSH_AGENT_PID" 2>/dev/null
	[ ! -f "$S/hang.pids" ] || while IFS= read -r p; do kill "$p" 2>/dev/null; done <"$S/hang.pids"
	gpgconf --kill all 2>/dev/null
	rm -rf "$T"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
export HOME="$S/home" GNUPGHOME="$T/gnupg" XDG_CONFIG_HOME="$S/xdg" GIT_CONFIG_GLOBAL="$S/home/.gitconfig" GIT_CONFIG_NOSYSTEM=1
export CRUCIBLE_HOME="$S/space" CLAUDE_CONFIG_DIR="$S/cfg" CLAUDE_CODE_SESSION_ID=sess-gc
unset SSH_AUTH_SOCK SSH_AGENT_PID GIT_CONFIG_COUNT
cd /
K="$S/cfg/skills"
for d in "$R"/framework/core/main-thread/*/ "$R"/domains/software-development/core/main-thread/*/; do d=${d%/}; ln -s "$d" "$K/${d##*/}"; done
GC=$K/git-commit/scripts; GI=$K/git-identity/scripts; GT=$K/crucible-gate

pass=0 fail=0
show() { sed "s|$S|<S>|g;s|$T|<T>|g;s|[0-9]\{8\}T[0-9]\{6\}-[0-9a-f]\{4\}|<id>|g;s|[0-9a-f]\{40\}|<sha>|g;s|[0-9A-F]\{40\}|<FPR>|g;s|[0-9A-F]\{16\}|<KEYID>|g;s|SHA256:[A-Za-z0-9+/]\{43\}|SHA256:<fp>|g;s|AAAA[A-Za-z0-9+/=]\{20,\}|<b64>|g"; }
# Runs "$@", keeping stdout in $out, stderr in $err and the exit in $rc, and shows them.
run() {
	for a in "$@"; do case $a in "$GC"/main/*.sh | "$GC"/internal/*.sh) echo "${a##*/}" >>"$S/ran" ;; esac; done
	echo "  \$ $(echo "$*" | sed "s|$GC/||g;s|$K/||g" | show)"
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
# The state the design says a script leaves alone: every ref, every index
# and the status of the checkout and its trees, and the git config files.
state() {
	{
		git -C "$S/repo" for-each-ref --format='%(refname) %(objectname)'
		for g in "$S/repo/.git/index" "$S/repo/.git/worktrees"/*/index; do [ ! -f "$g" ] || shasum "$g"; done
		git -C "$S/repo" status --porcelain=v2 --untracked-files=all
		shasum "$GIT_CONFIG_GLOBAL" "$S/repo/.git/config"
	} | sed "s|$S||g"
}
trailer() { git -C "$1" log -1 --format='%(trailers:key=Effort,valueonly)' "$2" | sed '/^$/d'; }
pick_n=0
# One recorded choice gate through the real hooks: card, stop, question, answer.
pick() { # $1 effort, $2 subject, $3 card file, $4 question JSON file, $5 the human's answer
	pick_n=$((pick_n + 1)); t="pick-$pick_n"
	sh $GT/scripts/main/show-card.sh --record set-identity --effort "$1" --subject "$2" --choice "$3" >/dev/null
	jq -cn --rawfile m "$3" --arg s sess-gc '{session_id: $s, last_assistant_message: $m}' | sh $GT/hooks/stop/require-card-shown.sh >/dev/null
	jq -c --arg s sess-gc --arg t "$t" '{session_id: $s, tool_name: "AskUserQuestion", tool_use_id: $t, tool_input: .}' "$4" \
		| sh $GT/hooks/pre-tool-use/hold-question-until-card-shown.sh >/dev/null
	q=$(jq -r '.questions[0].question' "$4")
	jq -cn --arg s sess-gc --arg t "$t" --arg q "$q" --arg a "$5" '{session_id: $s, tool_name: "AskUserQuestion", tool_use_id: $t, tool_response: {answers: {($q): $a}}}' \
		| sh $GT/hooks/post-tool-use/record-gate-answer.sh
}
msg() { printf '%s\n' "$2" >"$S/msg/$1"; echo "$S/msg/$1"; }

echo "=== set-up: scratch keys (one GPG key, one SSH key in a scratch agent), a scratch repository, three efforts"
gpg --batch --pinentry-mode loopback --passphrase '' --quick-gen-key 'Gpg Tester <gpg@example.test>' ed25519 sign never 2>/dev/null
ssh-keygen -q -t ed25519 -N '' -C ssh@example.test -f "$HOME/.ssh/agent_key"
eval "$(ssh-agent -s -a "$T/agent.sock")" >/dev/null; ssh-add -q "$HOME/.ssh/agent_key" 2>/dev/null; rm "$HOME/.ssh/agent_key"
printf 'ssh@example.test %s\n' "$(cut -d ' ' -f 1,2 "$HOME/.ssh/agent_key.pub")" >"$HOME/.ssh/allowed_signers"
git config --global user.name 'Ssh Tester'
git config --global gpg.ssh.allowedSignersFile "$HOME/.ssh/allowed_signers"
git init -q -b main "$S/repo"
printf 'one\n' >"$S/repo/a.txt"; printf 'keep\n' >"$S/repo/b.txt"; printf 'gone\n' >"$S/repo/c.txt"; printf 'base\n' >"$S/repo/f.txt"
git -C "$S/repo" add -A; git -C "$S/repo" -c user.name=Human -c user.email=human@example.test commit -q -m base
REPO=$(cd "$S/repo" && pwd -P)
SSHE=$(sh $K/crucible-effort/scripts/main/effort-start.sh --name ssh-work)
GPGE=$(sh $K/crucible-effort/scripts/main/effort-start.sh --name gpg-work)
NONE=$(sh $K/crucible-effort/scripts/main/effort-start.sh --name no-identity)
SN=${SSHE##*/}; GN=${GPGE##*/}; NN=${NONE##*/}
sh $GI/main/identity-list.sh >"$S/list.json" 2>/dev/null
sh $GI/main/identity-card.sh --list "$S/list.json" --repo "$S/repo" >"$S/card.md"
sh $GI/main/identity-card.sh --list "$S/list.json" --repo "$S/repo" --question >"$S/q.json"
SUB="$REPO:$(shasum -a 256 "$S/list.json" | cut -d ' ' -f 1)"
pick "$SSHE" "$SUB" "$S/card.md" "$S/q.json" "$(jq -r '[.[] | select(.signing.format == "ssh")][0].label' "$S/list.json")"
sh $GI/main/identity-set.sh --effort "$SSHE" --repo "$S/repo" --list "$S/list.json" >/dev/null
pick "$GPGE" "$SUB" "$S/card.md" "$S/q.json" "$(jq -r '[.[] | select(.signing.format == "openpgp")][0].label' "$S/list.json")"
sh $GI/main/identity-set.sh --effort "$GPGE" --repo "$S/repo" --list "$S/list.json" >/dev/null
run sh $GI/main/identity-get.sh --effort "$SSHE" --repo "$S/repo"
check "the ssh effort's identity is set through git-identity" is "$(echo "$out" | jq -r .signing.format)" ssh
run sh $GI/main/identity-get.sh --effort "$GPGE" --repo "$S/repo"
check "the gpg effort's identity is set through git-identity" is "$(echo "$out" | jq -r .signing.format)" openpgp
git -C "$S/repo" worktree add -q -b "crucible/$SN/one" "$SSHE/worktrees/one" 2>/dev/null
git -C "$S/repo" worktree add -q -b "crucible/$GN/two" "$GPGE/worktrees/two" 2>/dev/null
W1=$SSHE/worktrees/one W2=$GPGE/worktrees/two
BEFORE_CONFIG=$(shasum "$GIT_CONFIG_GLOBAL" "$S/repo/.git/config")

echo
echo "=== commit-message.sh"
printf '{"kind":"build","text":"add the parser","trailers":{"iteration":2,"change-id":"abc"}}' >"$S/in1.json"
run sh $GC/main/commit-message.sh --input "$S/in1.json" --out "$S/msg/m1"
check "exit 0, nothing printed" is "$rc:$out" "0:"
printf 'crucible(build): add the parser\n\nIteration: 2\nChange-Id: abc\n' >"$S/want1"
sed 's/^/    file: /' "$S/msg/m1"
check "subject crucible(<kind>): <text>, a blank line, the trailers in order" cmp -s "$S/msg/m1" "$S/want1"
printf '{"kind":"snapshot","text":"uncommitted changes"}' >"$S/in2.json"
run sh $GC/main/commit-message.sh --input "$S/in2.json" --out "$S/msg/m2"
check "no trailers: the subject alone" is "$(cat "$S/msg/m2")" 'crucible(snapshot): uncommitted changes'
printf '{"kind":"Build!","text":"%s","trailers":{"Bad Key":"x","effort":"two\\nlines"},"extra":1}' "$(printf 'x%.0s' $(seq 1 70))" >"$S/in3.json"
run sh $GC/main/commit-message.sh --input "$S/in3.json" --out "$S/msg/m3"
check "an invalid input: exit 2, one line per problem, no file" is "$rc:$(echo "$err" | wc -l | tr -d ' '):$([ -e "$S/msg/m3" ] && echo file)" "2:5:"
printf 'not json' >"$S/in4.json"
run sh $GC/main/commit-message.sh --input "$S/in4.json" --out "$S/msg/m4"
check "not JSON: exit 2" is "$rc" 2

echo
echo "=== commit-tree.sh: a tree's changes, signed with the SSH identity"
printf 'two\n' >"$W1/a.txt"; rm "$W1/c.txt"; printf 'new\n' >"$W1/new.txt"
MAIN_BEFORE=$(git -C "$S/repo" rev-parse HEAD; shasum "$S/repo/.git/index"; git -C "$S/repo" status --porcelain)
run sh $GC/main/commit-tree.sh --worktree "$W1" --message-file "$S/msg/m1" --effort "$SSHE"
C1=$(echo "$out" | jq -r .commit)
check "exit 0 and signed: true" is "$rc:$(echo "$out" | jq -r .signed)" "0:true"
check "git verify-commit accepts the SSH signature" git -C "$S/repo" verify-commit "$C1"
check "the commit is the tree's branch tip" is "$(git -C "$S/repo" rev-parse "crucible/$SN/one")" "$C1"
check "author and committer are the identity" is "$(git -C "$S/repo" log -1 --format='%an <%ae>|%cn <%ce>' "$C1")" 'Ssh Tester <ssh@example.test>|Ssh Tester <ssh@example.test>'
check "the Effort trailer names the effort folder" is "$(trailer "$S/repo" "$C1")" "$SN"
check "the message keeps the given trailers before Effort" is "$(git -C "$S/repo" log -1 --format=%B "$C1" | sed '/^$/d' | tail -n 3 | tr '\n' '|')" "Iteration: 2|Change-Id: abc|Effort: $SN|"
check "added, modified and deleted are all in it" is "$(git -C "$S/repo" diff-tree --no-commit-id --name-status -r "$C1" | tr '\t\n' ' |')" "M a.txt|D c.txt|A new.txt|"
check "the tree is clean after the commit" is "$(git -C "$W1" status --porcelain)" ""
check "the human's checkout (HEAD, index, status) is untouched" is "$(git -C "$S/repo" rev-parse HEAD; shasum "$S/repo/.git/index"; git -C "$S/repo" status --porcelain)" "$MAIN_BEFORE"

echo
echo "=== commit-tree.sh: signed with the GPG identity"
printf 'gpg\n' >"$W2/g.txt"
run sh $GC/main/commit-tree.sh --worktree "$W2" --message-file "$S/msg/m2" --effort "$GPGE"
C2=$(echo "$out" | jq -r .commit)
check "exit 0 and signed: true" is "$rc:$(echo "$out" | jq -r .signed)" "0:true"
check "git verify-commit accepts the OpenPGP signature" git -C "$S/repo" verify-commit "$C2"
check "the Effort trailer is added to a message with none" is "$(trailer "$S/repo" "$C2")" "$GN"

echo
echo "=== commit-tree.sh: the refusals"
run sh $GC/main/commit-tree.sh --worktree "$W2" --message-file "$S/msg/m2" --effort "$GPGE"
check "nothing to commit: exit 3" is "$rc" 3
printf 'other\n' >"$W2/g.txt"
printf 'crucible(build): x\n\nEffort: some-other-effort\n' >"$S/msg/foreign"
run sh $GC/main/commit-tree.sh --worktree "$W2" --message-file "$S/msg/foreign" --effort "$GPGE"
check "an Effort trailer naming another effort: exit 2, nothing committed" is "$rc:$(git -C "$W2" rev-parse HEAD)" "2:$C2"
printf 'crucible(build): x\n\nEffort: %s\n' "$GN" >"$S/msg/own"
run sh $GC/main/commit-tree.sh --worktree "$W2" --message-file "$S/msg/own" --effort "$GPGE"
check "an Effort trailer naming this effort is kept, not repeated" is "$rc:$(git -C "$S/repo" log -1 --format=%B "crucible/$GN/two" | grep -c '^Effort:')" "0:1"
git -C "$S/repo" worktree add -q -b feature/x "$SSHE/worktrees/plain" 2>/dev/null
printf 'p\n' >"$SSHE/worktrees/plain/p.txt"
run sh $GC/main/commit-tree.sh --worktree "$SSHE/worktrees/plain" --message-file "$S/msg/m1" --effort "$SSHE"
check "a branch not under crucible/<effort>/: exit 2" is "$rc:$(has "$err" 'expected a branch under crucible/' && echo y)" "2:y"
printf 'w\n' >"$W2/wrong.txt"
run sh $GC/main/commit-tree.sh --worktree "$W2" --message-file "$S/msg/m2" --effort "$SSHE"
check "another effort's crucible/ branch: exit 2" is "$rc" 2
git -C "$W2" checkout -q -- . 2>/dev/null; rm -f "$W2/wrong.txt"
printf 'h\n' >"$S/repo/h.txt"
run sh $GC/main/commit-tree.sh --worktree "$S/repo" --message-file "$S/msg/m1" --effort "$SSHE"
check "the human's main checkout: exit 2" is "$rc:$(has "$err" 'main checkout' && echo y)" "2:y"
rm "$S/repo/h.txt"
git -C "$S/repo" worktree add -q -b "crucible/$NN/three" "$NONE/worktrees/three" 2>/dev/null
printf 'n\n' >"$NONE/worktrees/three/n.txt"
run sh $GC/main/commit-tree.sh --worktree "$NONE/worktrees/three" --message-file "$S/msg/m1" --effort "$NONE"
check "an effort with no identity for the repository: exit 2, set the identity first" is "$rc:$(has "$err" 'set the identity first' && echo y)" "2:y"
check "  ... and nothing was staged" is "$(git -C "$NONE/worktrees/three" diff --cached --name-only)" ""

echo
echo "=== commit-tree.sh: finishing a merge under way"
git -C "$S/repo" -c user.name=Human -c user.email=human@example.test commit -q --allow-empty -m 'human side' 2>/dev/null
git -C "$S/repo" branch -q side main
git -C "$S/repo" worktree add -q "$S/side" side 2>/dev/null
printf 'side\n' >"$S/side/f.txt"; git -C "$S/side" -c user.name=Human -c user.email=human@example.test commit -q -am side
git -C "$S/repo" worktree remove "$S/side"
printf 'ours\n' >"$W1/f.txt"
sh $GC/main/commit-tree.sh --worktree "$W1" --message-file "$S/msg/m1" --effort "$SSHE" >/dev/null 2>&1
OURS=$(git -C "$W1" rev-parse HEAD); SIDE=$(git -C "$S/repo" rev-parse side)
git -C "$W1" -c user.name=x -c user.email=x@x merge -q --no-ff side >/dev/null 2>&1
check "the merge conflicts in the tree" test -e "$(git -C "$W1" rev-parse --absolute-git-dir)/MERGE_HEAD"
run sh $GC/main/commit-tree.sh --worktree "$W1" --message-file "$S/msg/m1" --effort "$SSHE"
check "a path still holding conflict markers: exit 2, naming it" is "$rc:$(has "$err" 'f.txt' && echo y)" "2:y"
printf 'resolved\n' >"$W1/f.txt"
printf '{"kind":"merge","text":"take in side"}' >"$S/in5.json"; sh $GC/main/commit-message.sh --input "$S/in5.json" --out "$S/msg/m5"
run sh $GC/main/commit-tree.sh --worktree "$W1" --message-file "$S/msg/m5" --effort "$SSHE"
CM=$(echo "$out" | jq -r .commit)
check "exit 0, signed: true" is "$rc:$(echo "$out" | jq -r .signed)" "0:true"
check "the merge commit's parents are HEAD and MERGE_HEAD" is "$(git -C "$S/repo" log -1 --format=%P "$CM")" "$OURS $SIDE"
check "the merge is finished, the tree clean" is "$(test -e "$(git -C "$W1" rev-parse --absolute-git-dir)/MERGE_HEAD" && echo left)$(git -C "$W1" status --porcelain)" ""
check "git verify-commit accepts the merge commit" git -C "$S/repo" verify-commit "$CM"

echo
echo "=== commits-merge.sh: two and three commits into one commit object"
B=$(git -C "$S/repo" rev-parse main)
mk() { # $1 file, $2 text: an unsigned commit on main's tip touching one file, through a scratch index
	GIT_INDEX_FILE="$S/idx.$1" git -C "$S/repo" read-tree "$B"
	blob=$(printf '%s\n' "$2" | git -C "$S/repo" hash-object -w --stdin)
	GIT_INDEX_FILE="$S/idx.$1" git -C "$S/repo" update-index --add --cacheinfo "100644,$blob,$1"
	tree=$(GIT_INDEX_FILE="$S/idx.$1" git -C "$S/repo" write-tree)
	git -C "$S/repo" -c user.name=Human -c user.email=human@example.test commit-tree "$tree" -p "$B" -m "$1"
}
X=$(mk x.txt x); Y=$(mk y.txt y); Z=$(mk z.txt z); Q=$(mk x.txt conflicting)
printf '{"kind":"merge","text":"join the trees"}' >"$S/in6.json"; sh $GC/main/commit-message.sh --input "$S/in6.json" --out "$S/msg/m6"
S0=$(state)
run sh $GC/internal/commits-merge.sh --repo "$W2" --commit "$X" --commit "$Y" --message-file "$S/msg/m6" --effort "$GPGE"
M2=$(echo "$out" | jq -r .commit)
check "exit 0, new: true, signed: true" is "$rc:$(echo "$out" | jq -c '[.new, .signed]')" "0:[true,true]"
check "its parents are the two commits, in order" is "$(git -C "$S/repo" log -1 --format=%P "$M2")" "$X $Y"
check "its tree holds both changes" is "$(git -C "$S/repo" ls-tree --name-only "$M2" | grep -c '^[xy]\.txt$')" 2
check "git verify-commit accepts it" git -C "$S/repo" verify-commit "$M2"
check "the Effort trailer names the effort" is "$(trailer "$S/repo" "$M2")" "$GN"
check "no ref, index, status or config changed" is "$(state)" "$S0"
run sh $GC/internal/commits-merge.sh --repo "$S/repo" --commit "$X" "$Y" "$Z" --message-file "$S/msg/m6" --effort "$SSHE"
M3=$(echo "$out" | jq -r .commit)
check "three commits after one --commit: exit 0, signed, three parents in order" is "$rc:$(echo "$out" | jq -r .signed):$(git -C "$S/repo" log -1 --format=%P "$M3")" "0:true:$X $Y $Z"
check "its tree holds all three changes" is "$(git -C "$S/repo" ls-tree --name-only "$M3" | grep -c '^[xyz]\.txt$')" 3
check "git verify-commit accepts it (SSH)" git -C "$S/repo" verify-commit "$M3"
check "no ref, index, status or config changed" is "$(state)" "$S0"
run sh $GC/internal/commits-merge.sh --repo "$S/repo" --commit "$M2" --commit "$X" --message-file "$S/msg/m6" --effort "$GPGE"
check "one commit holding the other: it is the answer, new: false" is "$rc:$(echo "$out" | jq -c '[.commit == "'"$M2"'", .new, .signed]')" "0:[true,false,true]"

echo
echo "=== commits-merge.sh: the refusals"
run sh $GC/internal/commits-merge.sh --repo "$S/repo" --commit "$X" --commit "$Q" --message-file "$S/msg/m6" --effort "$GPGE"
check "a conflict: exit 3, naming the path" is "$rc:$(echo "$out" | jq -c .conflicts):$(has "$err" 'x.txt' && echo y)" '3:["x.txt"]:y'
check "  ... and no ref, index, status or config changed" is "$(state)" "$S0"
run sh $GC/internal/commits-merge.sh --repo "$S/repo" --commit "$X" --commit "$Y" --message-file "$S/msg/m6" --effort "$NONE"
check "an effort with no identity for the repository: exit 2, set the identity first" is "$rc:$(has "$err" 'set the identity first' && echo y)" "2:y"
run sh $GC/internal/commits-merge.sh --repo "$S/repo" --commit "$X" --message-file "$S/msg/m6" --effort "$GPGE"
check "one commit: exit 2" is "$rc" 2
run sh $GC/internal/commits-merge.sh --repo "$S/repo" --commit "$X" --commit nosuch --message-file "$S/msg/m6" --effort "$GPGE"
check "a value that is no commit: exit 2" is "$rc" 2

echo
echo "=== the signing fallback: a signer that hangs is given up after 10 s, the commit made unsigned"
# The hanging signer is set for these commands only, through git's
# GIT_CONFIG_* environment, so no config file is changed. It starts a child
# of its own, as a signer starts a pinentry, writes both PIDs, then waits.
printf '#!/bin/sh\nprintf "%%s\\n" "$$" >>"%s/hang.pids"\nsleep 30 &\nprintf "%%s\\n" "$!" >>"%s/hang.pids"\nwait\n' "$S" "$S" >"$S/hang-gpg"; chmod 755 "$S/hang-gpg"
# How many of the hanging signers' PIDs are still running, after a moment
# for the stopped ones to be reaped.
hang_left() { sleep 1; n=0; while IFS= read -r p; do kill -0 "$p" 2>/dev/null && n=$((n + 1)); done <"$S/hang.pids"; echo "$n:$(wc -l <"$S/hang.pids" | tr -d ' ')"; }
printf 'slow\n' >"$W2/slow.txt"
t0=$(date +%s)
run env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=gpg.program GIT_CONFIG_VALUE_0="$S/hang-gpg" sh $GC/main/commit-tree.sh --worktree "$W2" --message-file "$S/msg/m2" --effort "$GPGE"
t1=$(date +%s); CU=$(echo "$out" | jq -r .commit)
echo "    took $((t1 - t0)) s"
check "commit-tree: exit 0, signed: false" is "$rc:$(echo "$out" | jq -r .signed)" "0:false"
check "commit-tree: stderr says signing timed out after 10 s" has "$err" 'unsigned: signing timed out after 10 s'
check "commit-tree: it took about 10 s, not the signer's 30" test "$((t1 - t0))" -ge 10 -a "$((t1 - t0))" -lt 20
check "commit-tree: the commit carries no signature, has the Effort trailer, the tree is clean" is "$(git -C "$S/repo" cat-file commit "$CU" | grep -c '^gpgsig'):$(trailer "$S/repo" "$CU"):$(git -C "$W2" status --porcelain)" "0:$GN:"
check "commit-tree: the signer and the program it started are both stopped" is "$(hang_left)" "0:2"
S1=$(state)
t0=$(date +%s)
run env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=gpg.program GIT_CONFIG_VALUE_0="$S/hang-gpg" sh $GC/internal/commits-merge.sh --repo "$S/repo" --commit "$X" --commit "$Z" --message-file "$S/msg/m6" --effort "$GPGE"
t1=$(date +%s); MU=$(echo "$out" | jq -r .commit)
echo "    took $((t1 - t0)) s"
check "commits-merge: exit 0, new: true, signed: false" is "$rc:$(echo "$out" | jq -c '[.new, .signed]')" "0:[true,false]"
check "commits-merge: stderr says signing timed out after 10 s" has "$err" 'unsigned: signing timed out after 10 s'
check "commits-merge: the commit carries no signature, parents in order" is "$(git -C "$S/repo" cat-file commit "$MU" | grep -c '^gpgsig'):$(git -C "$S/repo" log -1 --format=%P "$MU")" "0:$X $Z"
check "commits-merge: no ref, index, status or config changed" is "$(state)" "$S1"
check "commits-merge: the signer and the program it started are both stopped" is "$(hang_left)" "0:4"
printf 'fails\n' >"$W2/fails.txt"
run env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=gpg.program GIT_CONFIG_VALUE_0=/usr/bin/false sh $GC/main/commit-tree.sh --worktree "$W2" --message-file "$S/msg/m2" --effort "$GPGE"
check "a signer that fails: committed with signed: false, the reason on stderr" is "$rc:$(echo "$out" | jq -r .signed):$(has "$err" 'unsigned:' && echo y)" "0:false:y"

echo
echo "=== commit-object.sh: one commit object from a tree and its parents"
printf '{"kind":"snapshot","text":"uncommitted changes"}' >"$S/in7.json"; sh $GC/main/commit-message.sh --input "$S/in7.json" --out "$S/msg/m7"
TX=$(git -C "$S/repo" rev-parse "$X^{tree}"); TM=$(git -C "$S/repo" rev-parse "$M3^{tree}")
S2=$(state)
run sh $GC/internal/commit-object.sh --repo "$S/repo" --tree "$TX" --parent "$B" --message-file "$S/msg/m7" --effort "$SSHE"
O1=$(echo "$out" | jq -r .commit)
check "SSH: exit 0, signed: true" is "$rc:$(echo "$out" | jq -r .signed)" "0:true"
check "SSH: git verify-commit accepts it" git -C "$S/repo" verify-commit "$O1"
check "its tree and parent are the ones given" is "$(git -C "$S/repo" log -1 --format='%T %P' "$O1")" "$TX $B"
check "its author is the identity, its Effort trailer the effort" is "$(git -C "$S/repo" log -1 --format='%an <%ae>' "$O1"):$(trailer "$S/repo" "$O1")" "Ssh Tester <ssh@example.test>:$SN"
run sh $GC/internal/commit-object.sh --repo "$W2" --tree "$TM" --parent "$X" "$Y" --parent "$Z" --message-file "$S/msg/m6" --effort "$GPGE"
O2=$(echo "$out" | jq -r .commit)
check "OpenPGP, three parents: exit 0, signed: true" is "$rc:$(echo "$out" | jq -r .signed)" "0:true"
check "OpenPGP: git verify-commit accepts it" git -C "$S/repo" verify-commit "$O2"
check "its parents are the three given, in order" is "$(git -C "$S/repo" log -1 --format=%P "$O2")" "$X $Y $Z"
check "no ref, index, status or config changed" is "$(state)" "$S2"
run sh $GC/internal/commit-object.sh --repo "$S/repo" --tree "$X" --parent "$B" --message-file "$S/msg/m7" --effort "$SSHE"
check "a commit given as the tree: exit 2" is "$rc:$(has "$err" 'is not a tree' && echo y)" "2:y"
run sh $GC/internal/commit-object.sh --repo "$S/repo" --tree 0123456789abcdef0123456789abcdef01234567 --parent "$B" --message-file "$S/msg/m7" --effort "$SSHE"
check "a tree that is no object: exit 2" is "$rc" 2
run sh $GC/internal/commit-object.sh --repo "$S/repo" --tree "$TX" --parent "$TX" --message-file "$S/msg/m7" --effort "$SSHE"
check "a tree given as a parent: exit 2" is "$rc:$(has "$err" 'is not a commit' && echo y)" "2:y"
run sh $GC/internal/commit-object.sh --repo "$S/repo" --tree "$TX" --message-file "$S/msg/m7" --effort "$SSHE"
check "no parent: exit 2" is "$rc" 2
run sh $GC/internal/commit-object.sh --repo "$S/repo" --tree "$TX" --parent "$B" --message-file "$S/msg/m7" --effort "$NONE"
check "an effort with no identity for the repository: exit 2, set the identity first" is "$rc:$(has "$err" 'set the identity first' && echo y)" "2:y"
check "  ... and no ref, index, status or config changed by the refusals" is "$(state)" "$S2"
t0=$(date +%s)
run env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=gpg.program GIT_CONFIG_VALUE_0="$S/hang-gpg" sh $GC/internal/commit-object.sh --repo "$S/repo" --tree "$TX" --parent "$B" --message-file "$S/msg/m7" --effort "$GPGE"
t1=$(date +%s); OU=$(echo "$out" | jq -r .commit)
echo "    took $((t1 - t0)) s"
check "a hanging signer: exit 0, signed: false, timed out after 10 s" is "$rc:$(echo "$out" | jq -r .signed):$(has "$err" 'unsigned: signing timed out after 10 s' && echo y)" "0:false:y"
check "  ... about 10 s, no signature on the object, its tree and parent as given" is "$( [ "$((t1 - t0))" -ge 10 ] && [ "$((t1 - t0))" -lt 20 ] && echo ok):$(git -C "$S/repo" cat-file commit "$OU" | grep -c '^gpgsig'):$(git -C "$S/repo" log -1 --format='%T %P' "$OU")" "ok:0:$TX $B"
check "  ... and the signer and the program it started are both stopped" is "$(hang_left)" "0:6"
check "  ... and no ref, index, status or config changed" is "$(state)" "$S2"

echo
echo "=== commit-snapshots.sh: which commits are snapshots"
printf '{"kind":"snapshot","text":"other words"}' >"$S/in8.json"; sh $GC/main/commit-message.sh --input "$S/in8.json" --out "$S/msg/m8"
printf '{"kind":"snapshots","text":"uncommitted changes"}' >"$S/in9.json"; sh $GC/main/commit-message.sh --input "$S/in9.json" --out "$S/msg/m9"
O8=$(sh $GC/internal/commit-object.sh --repo "$S/repo" --tree "$TX" --parent "$B" --message-file "$S/msg/m8" --effort "$SSHE" 2>/dev/null | jq -r .commit)
O9=$(sh $GC/internal/commit-object.sh --repo "$S/repo" --tree "$TX" --parent "$B" --message-file "$S/msg/m9" --effort "$SSHE" 2>/dev/null | jq -r .commit)
S3=$(state)
run sh $GC/internal/commit-snapshots.sh --repo "$S/repo" --commit "$B" --commit "$O8" --commit "$O9" --commit "$(git -C "$S/repo" rev-parse --short "$O1")"
check "exit 0: the commits of kind snapshot, whatever their text, as full shas in the order given" is "$rc:$(echo "$out" | jq -c .snapshots)" "0:[\"$O8\",\"$O1\"]"
check "  ... a plain commit and one of kind snapshots are not snapshots, and nothing changed" is "$(echo "$out" | jq -c '[.snapshots[] | select(. == "'"$B"'" or . == "'"$O9"'")]'):$(state)" "[]:$S3"
run sh $GC/internal/commit-snapshots.sh --repo "$W2" --commit "$O2"
check "from a worktree, a commit of another kind: exit 0, no snapshot" is "$rc:$(echo "$out" | jq -c .snapshots)" "0:[]"
run sh $GC/internal/commit-snapshots.sh --commit "$O1"
check "no --repo: exit 2" is "$rc:$(has "$err" '\-\-repo missing' && echo y)" "2:y"
run sh $GC/internal/commit-snapshots.sh --repo "$S/repo"
check "no --commit: exit 2" is "$rc:$(has "$err" '\-\-commit missing' && echo y)" "2:y"
run sh $GC/internal/commit-snapshots.sh --repo "$S/repo" --commit
check "--commit with no value: exit 2" is "$rc:$(has "$err" 'needs a value' && echo y)" "2:y"
run sh $GC/internal/commit-snapshots.sh --repo "$S/repo" --commit --all
check "--commit starting with -: exit 2" is "$rc:$(has "$err" 'starts with -' && echo y)" "2:y"
run sh $GC/internal/commit-snapshots.sh --repo "$S/repo" --commit "$TX"
check "--commit naming a tree: exit 2" is "$rc:$(has "$err" 'is no commit' && echo y)" "2:y"
run sh $GC/internal/commit-snapshots.sh --repo relative --commit "$O1"
check "--repo not absolute: exit 2" is "$rc:$(has "$err" 'must be an absolute folder' && echo y)" "2:y"
run sh $GC/internal/commit-snapshots.sh --repo "$S" --commit "$O1"
check "--repo in no repository: exit 2" is "$rc" 2
mkdir -p "$S/cs-nogit" "$S/cs-nojq"
for t in dirname mktemp rm; do ln -s "$(command -v $t)" "$S/cs-nogit/$t"; ln -s "$(command -v $t)" "$S/cs-nojq/$t"; done
ln -s "$(command -v git)" "$S/cs-nojq/git"
run env PATH="$S/cs-nogit" /bin/sh $GC/internal/commit-snapshots.sh --repo "$S/repo" --commit "$O1"
check "without git: exit 4" is "$rc:$(has "$err" 'git not found' && echo y)" "4:y"
run env PATH="$S/cs-nojq" /bin/sh $GC/internal/commit-snapshots.sh --repo "$S/repo" --commit "$O1"
check "without jq: exit 4" is "$rc:$(has "$err" 'jq not found' && echo y)" "4:y"

echo
echo "=== the human's git config"
check "the global and repository config files are as before the run" is "$(shasum "$GIT_CONFIG_GLOBAL" "$S/repo/.git/config")" "$BEFORE_CONFIG"
check "no Crucible key was written to any config" is "$(git -C "$S/repo" config --list --show-origin | grep -c -i 'signingkey\|gpg.format\|hookspath' || true)" 0

echo
echo "=== the scripts' contracts"
for s in commit-message.sh commit-tree.sh commits-merge.sh commit-object.sh commit-snapshots.sh; do
	sh "$GC"/*/"$s" --help >/dev/null 2>&1; h=$?
	sh "$GC"/*/"$s" --bogus >/dev/null 2>&1; b=$?
	check "$s: --help exits 0, an unknown option exits 2" is "$h:$b" "0:2"
done
if command -v shellcheck >/dev/null 2>&1; then
	check "shellcheck -x -o all is clean" shellcheck -x -o all "$R"/domains/software-development/core/main-thread/git-commit/scripts/main/*.sh "$R"/domains/software-development/core/main-thread/git-commit/scripts/internal/*.sh "$R"/domains/software-development/core/main-thread/git-commit/scripts/lib/*.sh
fi

echo
echo "=== coverage: every script under scripts/ ran on a case"
for p in "$R"/domains/software-development/core/main-thread/git-commit/scripts/main/*.sh "$R"/domains/software-development/core/main-thread/git-commit/scripts/internal/*.sh; do
	s=${p##*/}
	cases=$(grep -cx -- "$s" "$S/ran" || true)
	check "$s ran on a case ($cases runs)" test "$cases" -gt 0
done

echo
echo "=== $pass PASS, $fail FAIL"
[ "$fail" -eq 0 ]
