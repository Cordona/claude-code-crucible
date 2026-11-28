# Evidence run for the roll back, then roll forward of git-worktree's
# writing scripts: worktree-move.sh, worktree-catch-up.sh and
# worktree-discard.sh. For each, a timeline: the tree and the event log
# before; the same command with the events lock held (exit 6, both exactly
# as before); the lock released and the command run again (exit 0, the
# change made, one new event). Through the installed layout (a scratch
# skills folder of links), from /, with scratch keys only: its own HOME, git
# config and ssh agent, so the owner's agent and ~/.ssh are never read.
R=/Users/cordona/IdeaProjects/cordona/claude-code-crucible/new-rewrite
S=/private/tmp/claude-501/-Users-cordona-IdeaProjects-cordona-claude-code-crucible/480d0359-cf0d-4c14-a59e-2a72be5dba4f/scratchpad/grollback; rm -rf "$S"; mkdir -p "$S/home/.ssh" "$S/xdg" "$S/cfg/skills" "$S/msg"
# A Unix socket path holds about 100 bytes, so the ssh agent's socket sits
# in a short scratch folder of its own.
T=$(mktemp -d /tmp/grb.XXXXXX); chmod 700 "$S/home/.ssh"
# Stops only what this run started: its ssh agent, by its PID; then removes
# the short folder.
cleanup() {
	[ -z "${SSH_AGENT_PID-}" ] || kill "$SSH_AGENT_PID" 2>/dev/null
	rm -rf "$T"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
export HOME="$S/home" XDG_CONFIG_HOME="$S/xdg" GIT_CONFIG_GLOBAL="$S/home/.gitconfig" GIT_CONFIG_NOSYSTEM=1
export CRUCIBLE_HOME="$S/space" CLAUDE_CONFIG_DIR="$S/cfg" CLAUDE_CODE_SESSION_ID=sess-rb
unset SSH_AUTH_SOCK SSH_AGENT_PID GIT_CONFIG_COUNT GNUPGHOME
cd /
K="$S/cfg/skills"
for d in "$R"/framework/core/main-thread/*/ "$R"/domains/software-development/core/main-thread/*/; do d=${d%/}; ln -s "$d" "$K/${d##*/}"; done
GW=$K/git-worktree/scripts; GC=$K/git-commit/scripts; GI=$K/git-identity/scripts; GT=$K/crucible-gate
EV=$K/crucible-events/scripts

pass=0 fail=0
show() { sed "s|$S|<S>|g;s|$T|<T>|g;s|[0-9]\{8\}T[0-9]\{6\}-[0-9a-f]\{4\}|<id>|g"; }
check() {
	what=$1; shift
	if "$@" >/dev/null 2>&1; then pass=$((pass + 1)); echo "  PASS: $what"
	else fail=$((fail + 1)); echo "  FAIL: $what"; fi
}
is() { [ "$1" = "$2" ]; }
# Runs "$@", keeping the exit in $rc, and shows its stdout and stderr.
run() {
	echo "  \$ $(echo "$*" | sed "s|$GW/||g;s|$K/||g" | show)"
	"$@" >"$S/out" 2>"$S/err"; rc=$?
	[ ! -s "$S/out" ] || show <"$S/out" | sed 's/^/    out: /'
	[ ! -s "$S/err" ] || show <"$S/err" | sed 's/^/    err: /'
	echo "    [exit $rc]"
}
hold() { mkdir "$F/events/.lock"; echo $$ >"$F/events/.lock/pid"; echo "  (the events lock is held, by this run's live PID $$)"; }
release() { rm -rf "$F/events/.lock"; echo "  (the events lock is released)"; }
# The git state of tree $1: its branch tip and the base's, its files with
# their hashes, its status, and the kept refs under refs/crucible/.
snap() {
	tr=$F/worktrees/$1
	echo "tree $1 branch tip: $(git -C "$tr" rev-parse HEAD) ($(git -C "$tr" symbolic-ref --short HEAD | show))"
	echo "base main tip:      $(git -C "$S/repo" rev-parse main)"
	echo "files:"
	(cd "$tr" && find . -path ./.git -prune -o -type f -print | LC_ALL=C sort | while IFS= read -r f; do printf '  %s %s\n' "$(shasum <"$f" | cut -c1-12)" "$f"; done)
	echo "status:"
	git -C "$tr" status --porcelain=v1 --untracked-files=all | sed 's/^/  /'
	echo "kept refs:"
	git -C "$S/repo" for-each-ref --format='  %(refname) %(objectname)' refs/crucible/ | show
}
evlog() { sh $EV/internal/events-read.sh --effort "$F" | jq -r '.[] | "\(.seq) \(.type)"'; }
print_state() { echo "  git:"; printf '%s\n' "$1" | sed 's/^/    /'; echo "  events (seq type):"; printf '%s\n' "$2" | sed 's/^/    /'; }
# The timeline for tree $1, command $3..., expecting event type $2.
timeline() {
	name=$1 type=$2; shift 2
	echo "--- before"
	b_snap=$(snap "$name"); b_log=$(evlog)
	print_state "$b_snap" "$b_log"
	echo "--- the events lock held"
	hold; run "$@"; release
	h_snap=$(snap "$name"); h_log=$(evlog)
	print_state "$h_snap" "$h_log"
	check "exit 6" is "$rc" 6
	check "the git state is byte-identical to before" is "$h_snap" "$b_snap"
	check "the event log is byte-identical to before" is "$h_log" "$b_log"
	echo "--- the lock released: the same command again"
	run "$@"
	a_snap=$(snap "$name"); a_log=$(evlog)
	print_state "$a_snap" "$a_log"
	check "exit 0" is "$rc" 0
	check "the change is made: the git state differs from before" is "$([ "$a_snap" != "$b_snap" ] && echo changed)" changed
	n=$(printf '%s\n' "$b_log" | wc -l | tr -d ' ')
	check "exactly one new event, $type, after the earlier ones" is "$(printf '%s\n' "$a_log" | head -n "$n"):$(printf '%s\n' "$a_log" | sed -n "$((n + 1)),\$p" | cut -d ' ' -f 2)" "$b_log:$type"
}
pick_n=0
# One recorded choice gate through the real hooks: card, stop, question, answer.
pick() { # $1 subject, $2 card file, $3 question JSON file, $4 the human's answer
	pick_n=$((pick_n + 1)); t="pick-$pick_n"
	sh $GT/scripts/main/show-card.sh --record set-identity --effort "$F" --subject "$1" --choice "$2" >/dev/null
	jq -cn --rawfile m "$2" --arg s sess-rb '{session_id: $s, last_assistant_message: $m}' | sh $GT/hooks/stop/require-card-shown.sh >/dev/null
	jq -c --arg s sess-rb --arg t "$t" '{session_id: $s, tool_name: "AskUserQuestion", tool_use_id: $t, tool_input: .}' "$3" \
		| sh $GT/hooks/pre-tool-use/hold-question-until-card-shown.sh >/dev/null
	q=$(jq -r '.questions[0].question' "$3")
	jq -cn --arg s sess-rb --arg t "$t" --arg q "$q" --arg a "$4" '{session_id: $s, tool_name: "AskUserQuestion", tool_use_id: $t, tool_response: {answers: {($q): $a}}}' \
		| sh $GT/hooks/post-tool-use/record-gate-answer.sh
}
msg() { printf '{"kind":"build","text":"%s"}' "$2" >"$S/msg/$1.json"; sh $GC/main/commit-message.sh --input "$S/msg/$1.json" --out "$S/msg/$1"; echo "$S/msg/$1"; }
# Commits file $2 with text $3 in tree $1 through git-commit.
tree_commit() { printf '%s\n' "$3" >"$F/worktrees/$1/$2"; sh $GC/main/commit-tree.sh --worktree "$F/worktrees/$1" --message-file "$(msg "c-$1-$2" "change $2 in $1")" --effort "$F" >/dev/null; }
cut_tree() { sh $GW/main/worktree-cut.sh --effort "$F" --repo "$S/repo" --name "$1" --from "$2" >/dev/null 2>&1; }

echo "=== set-up: a scratch ssh key, a repository whose main is one commit past v1, an effort with an identity"
ssh-keygen -q -t ed25519 -N '' -C ssh@example.test -f "$HOME/.ssh/agent_key"
eval "$(ssh-agent -s -a "$T/agent.sock")" >/dev/null; ssh-add -q "$HOME/.ssh/agent_key" 2>/dev/null; rm "$HOME/.ssh/agent_key"
printf 'ssh@example.test %s\n' "$(cut -d ' ' -f 1,2 "$HOME/.ssh/agent_key.pub")" >"$HOME/.ssh/allowed_signers"
git config --global user.name 'Ssh Tester'
git config --global gpg.ssh.allowedSignersFile "$HOME/.ssh/allowed_signers"
git init -q -b main "$S/repo"
printf 'base\n' >"$S/repo/f.txt"; printf 'keep\n' >"$S/repo/a.txt"; printf 'old\n' >"$S/repo/gone.txt"
git -C "$S/repo" add -A; git -C "$S/repo" -c user.name=Human -c user.email=human@example.test commit -q -m base
git -C "$S/repo" tag v1
printf 'from main\n' >"$S/repo/main.txt"
git -C "$S/repo" add -A; git -C "$S/repo" -c user.name=Human -c user.email=human@example.test commit -q -m 'human: main.txt'
F=$(sh $K/crucible-effort/scripts/main/effort-start.sh --name rollback)
sh $GI/main/identity-list.sh >"$S/list.json" 2>/dev/null
sh $GI/main/identity-card.sh --list "$S/list.json" --repo "$S/repo" >"$S/card.md"
sh $GI/main/identity-card.sh --list "$S/list.json" --repo "$S/repo" --question >"$S/q.json"
REPO=$(cd "$S/repo" && pwd -P)
pick "$REPO:$(shasum -a 256 "$S/list.json" | cut -d ' ' -f 1)" "$S/card.md" "$S/q.json" "$(jq -r '[.[] | select(.signing.format == "ssh")][0].label' "$S/list.json")"
sh $GI/main/identity-set.sh --effort "$F" --repo "$S/repo" --list "$S/list.json" >/dev/null
check "the effort's identity is set through git-identity's real scripts" is "$(sh $GI/main/identity-get.sh --effort "$F" --repo "$S/repo" | jq -r .signing.format)" ssh
cut_tree mover ref:v1; tree_commit mover m.txt 'work main lacks'
cut_tree syncer ref:v1; tree_commit syncer s.txt 'work to keep'
cut_tree clearer checkout
printf 'edited\n' >"$F/worktrees/clearer/f.txt"; rm "$F/worktrees/clearer/gone.txt"
printf 'untracked\n' >"$F/worktrees/clearer/new.txt"
printf 'staged\n' >"$F/worktrees/clearer/staged.txt"; git -C "$F/worktrees/clearer" add staged.txt
echo "  trees: mover (one commit main lacks), syncer (one commit, behind main), clearer (an edit, a deletion, an untracked file, a staged file)"

echo
echo "=== worktree-move.sh: mover to main, its commit kept under refs/crucible/moved/"
timeline mover worktree.moved sh $GW/main/worktree-move.sh --effort "$F" --name mover --to main
check "after the rerun: mover is at main" is "$(git -C "$F/worktrees/mover" rev-parse HEAD)" "$(git -C "$S/repo" rev-parse main)"

echo
echo "=== worktree-catch-up.sh: syncer takes in main through a sync commit"
timeline syncer worktree.synced sh $GW/main/worktree-catch-up.sh --effort "$F" --name syncer --with main
check "after the rerun: syncer's tip holds main" is "$(git -C "$F/worktrees/syncer" merge-base --is-ancestor main HEAD && echo held)" held

echo
echo "=== worktree-discard.sh: clearer's changes kept under refs/crucible/discarded/, the tree cleared"
timeline clearer worktree.discarded sh $GW/main/worktree-discard.sh --effort "$F" --name clearer
check "after the rerun: clearer is clean" is "$(git -C "$F/worktrees/clearer" status --porcelain --untracked-files=all)" ""

echo
echo "=== $pass PASS, $fail FAIL"
[ "$fail" -eq 0 ]
