# Evidence run for dev-base: repo-of.sh and run-timed.sh, every option and
# refusal, through the installed layout (a scratch skills folder of links),
# from /; then each caller's refusal when dev-base isn't beside it. Scratch
# HOME, XDG and git config only. Every process a case starts writes its own
# PID, and only those PIDs are ever signalled.
R=/Users/cordona/IdeaProjects/cordona/claude-code-crucible/new-rewrite
S=/private/tmp/claude-501/-Users-cordona-IdeaProjects-cordona-claude-code-crucible/480d0359-cf0d-4c14-a59e-2a72be5dba4f/scratchpad/devbase; rm -rf "$S"; mkdir -p "$S/home" "$S/xdg" "$S/cfg/skills" "$S/pids"
# Stops whatever a case left running, by the PIDs the processes wrote.
cleanup() { cat "$S"/pids/* 2>/dev/null | while IFS= read -r p; do kill -KILL "$p" 2>/dev/null; done; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
export HOME="$S/home" XDG_CONFIG_HOME="$S/xdg" GIT_CONFIG_GLOBAL="$S/home/.gitconfig" GIT_CONFIG_NOSYSTEM=1
export CRUCIBLE_HOME="$S/space" CLAUDE_CONFIG_DIR="$S/cfg" CLAUDE_CODE_SESSION_ID=sess-db
cd /
K="$S/cfg/skills"
for d in "$R"/framework/core/main-thread/*/ "$R"/domains/software-development/core/main-thread/*/; do d=${d%/}; ln -s "$d" "$K/${d##*/}"; done
DB=$K/dev-base/scripts/internal
RO="$DB/repo-of.sh"; RT="$DB/run-timed.sh"

pass=0 fail=0
show() { sed "s|$S|<S>|g" | tr '\001' '?'; }
# Runs "$@", keeping stdout in $out, stderr in $err and the exit in $rc, and shows them.
run() {
	for a in "$@"; do case $a in "$DB"/*.sh) echo "${a##*/}" >>"$S/ran" ;; esac; done
	echo "  \$ $(echo "$*" | sed "s|$DB/||g;s|$K/||g" | show)"
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
# Prints how many of the PIDs in file $1 are still running; the file must
# list at least one PID.
alive() {
	[ -s "$1" ] || { echo none-written; return; }
	n=0
	while IFS= read -r p; do kill -0 "$p" 2>/dev/null && n=$((n + 1)); done <"$1"
	echo "$n"
}

echo "=== set-up: a checkout with a linked worktree, a bare repository and its worktree, a plain folder"
git init -q -b main "$S/repo"; mkdir -p "$S/repo/sub/deep"; printf 'a\n' >"$S/repo/a.txt"
git -C "$S/repo" add -A; git -C "$S/repo" -c user.name=T -c user.email=t@example.test commit -q -m base
git -C "$S/repo" worktree add -q -b side "$S/wt" 2>/dev/null; mkdir -p "$S/wt/inner"
git init -q --bare "$S/bare.git"; git -C "$S/repo" push -q "$S/bare.git" main 2>/dev/null
git -C "$S/bare.git" worktree add -q "$S/bare-wt" main 2>/dev/null
mkdir -p "$S/plain" "$S/with space/x"; git init -q -b main "$S/with space/x"
ln -s "$S/repo/sub" "$S/link-to-sub"
REPO=$(cd "$S/repo" && pwd -P); SPACED=$(cd "$S/with space/x" && pwd -P)

echo
echo "=== repo-of.sh: the repository and its main checkout"
for d in "$S/repo" "$S/repo/sub/deep" "$S/wt" "$S/wt/inner" "$S/repo/.git" "$S/link-to-sub"; do
	run sh "$RO" --dir "$d"
	check "$(echo "$d" | show): the checkout and its .git folder, physical" is "$rc:$out" "0:{\"repo\":\"$REPO\",\"git_dir\":\"$REPO/.git\"}"
done
run sh "$RO" --dir "$S/with space/x"
check "a folder with a space: named whole" is "$rc:$(echo "$out" | jq -r .repo)" "0:$SPACED"
run env GIT_DIR="$S/with space/x/.git" GIT_WORK_TREE="$S/with space/x" sh "$RO" --dir "$S/repo/sub"
check "an inherited GIT_DIR and GIT_WORK_TREE are ignored: the folder's own repository" is "$rc:$(echo "$out" | jq -r .repo)" "0:$REPO"
run env CDPATH="$S/repo:$S" sh "$RO" --dir "$S/wt"
check "CDPATH set: stdout is still the one JSON line" is "$rc:$out" "0:{\"repo\":\"$REPO\",\"git_dir\":\"$REPO/.git\"}"

echo
echo "=== repo-of.sh: no repository, a bare one"
run sh "$RO" --dir "$S/plain"
check "a folder in no git repository: exit 3, nothing on stdout" is "$rc:$out:$(has "$err" 'plain is not in a git repository' && echo y)" "3::y"
run sh "$RO" --dir "$S/nowhere"
check "a folder that isn't there: exit 3" is "$rc:$(has "$err" 'nowhere is not in a git repository' && echo y)" "3:y"
run sh "$RO" --dir "$(printf '%s/odd\001name' "$S")"
check "a control character in the folder is shown as ?" is "$rc:$(has "$err" 'odd?name is not in a git repository' && echo y)" "3:y"
mkdir -p "$S/locked/repo"; git init -q "$S/locked/repo"; chmod 000 "$S/locked/repo/.git"
run sh "$RO" --dir "$S/locked/repo"
chmod 700 "$S/locked/repo/.git"
check "a git folder that can't be read: exit 3, nothing on stdout" is "$rc:$out" "3:"
run sh "$RO" --dir "$S/bare.git"
check "a bare repository: exit 5, no checkout" is "$rc:$out:$(has "$err" 'belongs to no checkout (a bare repository)' && echo y)" "5::y"
run sh "$RO" --dir "$S/bare-wt"
check "a worktree of a bare repository: exit 5" is "$rc:$(has "$err" 'belongs to no checkout' && echo y)" "5:y"

echo
echo "=== repo-of.sh: the refusals and missing tools"
run sh "$RO"
check "no --dir: exit 2" is "$rc:$(has "$err" '--dir missing' && echo y)" "2:y"
run sh "$RO" --dir
check "--dir with no value: exit 2" is "$rc:$(has "$err" '--dir needs a value' && echo y)" "2:y"
run sh "$RO" --dir "$S/repo" --dir "$S/wt"
check "--dir twice: exit 2" is "$rc:$(has "$err" '--dir given twice' && echo y)" "2:y"
run sh "$RO" --dir repo
check "a relative folder: exit 2" is "$rc:$(has "$err" '--dir must be an absolute folder' && echo y)" "2:y"
run sh "$RO" --dir "$S/repo" --bogus
check "an unknown argument: exit 2" is "$rc:$(has "$err" 'unknown argument --bogus' && echo y)" "2:y"
run sh "$RO" --help
check "--help: exit 0, the usage first" is "$rc:$(echo "$out" | head -n 1)" "0:usage: sh repo-of.sh --dir FOLDER"
mkdir -p "$S/nogit" "$S/nojq"
for t in tr; do ln -s "$(command -v $t)" "$S/nogit/$t"; ln -s "$(command -v $t)" "$S/nojq/$t"; done
ln -s "$(command -v git)" "$S/nojq/git"
run env PATH="$S/nogit" /bin/sh "$RO" --dir "$S/repo"
check "git not found: exit 4" is "$rc:$(has "$err" 'git not found' && echo y)" "4:y"
run env PATH="$S/nojq" /bin/sh "$RO" --dir "$S/repo"
check "jq not found: exit 4" is "$rc:$(has "$err" 'jq not found' && echo y)" "4:y"

echo
echo "=== run-timed.sh: a command that ends within the limit"
run sh "$RT" --seconds 5 -- sh -c 'echo to-stdout; echo to-stderr >&2; exit 7'
check "its stdout, its stderr and its own exit 7 pass through" is "$rc:$out:$err" "7:to-stdout:to-stderr"
t0=$(date +%s)
run sh "$RT" --seconds 30 -- true
check "a fast command returns at once with exit 0, not after the limit" is "$rc:$([ "$(($(date +%s) - t0))" -lt 3 ] && echo fast)" "0:fast"
printf 'given\n' >"$S/stdin"
run sh "$RT" --seconds 5 -- sh -c 'cat; echo read-to-end' <"$S/stdin"
check "stdin is closed: the command reads nothing" is "$rc:$out" "0:read-to-end"
run sh "$RT" --seconds 1 -- sh -c 'exit 0'
check "--seconds 1, the least: accepted" is "$rc" 0
run sh "$RT" --seconds 3600 -- sh -c 'exit 0'
check "--seconds 3600, the most: accepted" is "$rc" 0
run sh "$RT" --seconds 5 -- "$S/no-such-command"
check "a command that can't be run: the shell's own failure and reason, no time-out" is "$([ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && echo failed):$(has "$err" 'no-such-command' && echo y)" "failed:y"
run sh "$RT" --seconds 5 -- sh -c 'exit 2'
check "a command's own exit 2 passes through" is "$rc:$err" "2:"

echo
echo "=== run-timed.sh: at the limit, the command and every process beneath it are stopped"
# The tree: the command, a child shell, and a grandchild sleeping under it,
# plus a sleep of the command's own; each writes its PID.
cat >"$S/tree.sh" <<EOF
#!/bin/sh
echo \$\$ >>"$S/pids/tree"
sh -c 'echo \$\$ >>"$S/pids/tree"; sleep 300 & echo \$! >>"$S/pids/tree"; wait' &
sleep 300 & echo \$! >>"$S/pids/tree"
wait
EOF
t0=$(date +%s)
run sh "$RT" --seconds 2 -- sh "$S/tree.sh"
took=$(($(date +%s) - t0)); echo "    took $took s"
sleep 1
check "exit 124 after about 2 s, nothing printed of its own" is "$rc:$out:$err:$([ "$took" -ge 2 ] && [ "$took" -lt 6 ] && echo on-time)" "124:::on-time"
check "the tree wrote four PIDs" is "$(wc -l <"$S/pids/tree" | tr -d ' ')" 4
check "  ... and none of the four is running: the child and the grandchild were stopped too" is "$(alive "$S/pids/tree")" 0
# A command that ignores TERM, with a child that ignores it too.
cat >"$S/stubborn.sh" <<EOF
#!/bin/sh
trap '' TERM
echo \$\$ >>"$S/pids/stubborn"
sleep 300 & echo \$! >>"$S/pids/stubborn"
wait
EOF
t0=$(date +%s)
run sh "$RT" --seconds 1 -- sh "$S/stubborn.sh"
took=$(($(date +%s) - t0)); echo "    took $took s"
sleep 1
check "a tree that ignores TERM: exit 124, KILL about 2 s after the limit" is "$rc:$([ "$took" -ge 3 ] && [ "$took" -lt 7 ] && echo on-time)" "124:on-time"
check "  ... and none of it is running" is "$(alive "$S/pids/stubborn")" 0

echo
echo "=== run-timed.sh: told to stop before the limit"
# The runner runs in the foreground, as a caller runs it, so INT reaches it;
# it writes its own PID first, and a helper signals that PID once the tree
# has written its four.
for sig in TERM INT HUP; do
	: >"$S/pids/told-$sig"
	sed "s|pids/tree|pids/told-$sig|g" "$S/tree.sh" >"$S/told-$sig.sh"
	(
		n=0
		while [ "$(wc -l <"$S/pids/told-$sig" | tr -d ' ')" -lt 4 ] && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n + 1)); done
		kill -"$sig" "$(cat "$S/pids/runner-$sig")"
	) &
	rc=0; sh -c 'echo $$ >"$1"; shift; exec "$@"' sh "$S/pids/runner-$sig" sh "$RT" --seconds 300 -- sh "$S/told-$sig.sh" >/dev/null 2>&1 || rc=$?
	echo run-timed.sh >>"$S/ran"
	wait
	sleep 1
	case $sig in TERM) want=143 ;; INT) want=130 ;; HUP) want=129 ;; esac
	echo "  \$ kill -$sig <the runner's PID>: [exit $rc]"
	check "$sig to the runner: exit $want, and none of the command's tree is running" is "$rc:$(alive "$S/pids/told-$sig")" "$want:0"
done

echo
echo "=== run-timed.sh: without pgrep only the command itself is found"
mkdir -p "$S/nopgrep"
for t in sh sleep cat tr wc; do ln -s "$(command -v $t)" "$S/nopgrep/$t"; done
cat >"$S/two.sh" <<EOF
#!/bin/sh
echo \$\$ >>"$S/pids/two-root"
sleep 300 & echo \$! >>"$S/pids/two-child"
wait
EOF
run env PATH="$S/nopgrep" /bin/sh "$RT" --seconds 1 -- /bin/sh "$S/two.sh"
sleep 3
check "exit 124; the command stopped, its child left running (the known limit)" is "$rc:$(alive "$S/pids/two-root"):$(alive "$S/pids/two-child")" "124:0:1"
kill -KILL "$(cat "$S/pids/two-child")" 2>/dev/null

echo
echo "=== run-timed.sh: the refusals; nothing runs"
# CMD stands for a command that would leave a file behind.
for args in '' '--seconds' '--seconds 5' '--seconds 5 --' '--seconds 5 CMD' '--seconds 0 -- CMD' '--seconds 07 -- CMD' \
	'--seconds 1.5 -- CMD' '--seconds abc -- CMD' '--seconds 3601 -- CMD' '--seconds 99999 -- CMD' '--bogus 5 -- CMD'; do
	rm -f "$S/touched"
	set --
	for w in ${args}; do
		if [ "$w" = CMD ]; then set -- "$@" touch "$S/touched"; else set -- "$@" "$w"; fi
	done
	run sh "$RT" "$@"
	check "run-timed.sh ${args:-(no arguments)}: exit 2, nothing ran" is "$rc:$([ -e "$S/touched" ] && echo ran)" "2:"
done
run sh "$RT" --help
check "--help: exit 0, the usage first" is "$rc:$(echo "$out" | head -n 1)" "0:usage: sh run-timed.sh --seconds N -- COMMAND [ARG]..."

echo
echo "=== the callers, with dev-base not beside them: each refuses, install first"
K3="$S/k3/skills"; mkdir -p "$K3"
for d in "$K"/*; do [ "${d##*/}" = dev-base ] || ln -s "$(readlink "$d")" "$K3/${d##*/}"; done
printf '[]' >"$S/empty-list.json"
run sh "$K3/git-worktree/scripts/main/worktree-facts.sh" --repo "$S/repo"
check "git-worktree (worktree-facts.sh): exit 2" is "$rc:$(has "$err" "dev-base isn't beside this skill" && echo y)" "2:y"
run sh "$K3/git-mount/scripts/main/mount-status.sh" --repo "$S/repo"
check "git-mount (mount-status.sh): exit 2" is "$rc:$(has "$err" "a neighbour isn't beside this skill (expected .*/dev-base/" && echo y)" "2:y"
run sh "$K3/git-identity/scripts/main/identity-card.sh" --list "$S/empty-list.json" --repo "$S/repo"
check "git-identity (identity-card.sh): exit 2" is "$rc:$(has "$err" "dev-base isn't beside this skill" && echo y)" "2:y"
run sh "$K3/git-commit/scripts/main/commit-tree.sh" --worktree "$S/wt" --message-file "$S/stdin" --effort "$S/plain"
check "git-commit (commit-tree.sh): exit 2" is "$rc:$(has "$err" "dev-base isn't beside this skill" && echo y)" "2:y"
run sh "$K3/git-push/scripts/main/push-tree.sh" --effort "$S/plain" --name one --remote origin
check "git-push (push-tree.sh): exit 2" is "$rc:$(has "$err" "a neighbour isn't beside this skill (expected .*/dev-base/" && echo y)" "2:y"
run sh "$K3/trackers/scripts/main/tracker-read.sh" --url 'https://github.com/cli/cli/issues/1'
check "trackers (tracker-read.sh): exit 2, before any tracker call" is "$rc:$(has "$err" "dev-base isn't beside this skill" && echo y)" "2:y"

echo
echo "=== the callers' repository refusals come from repo-of.sh"
run sh "$K/git-worktree/scripts/main/worktree-facts.sh" --repo "$S/bare.git"
check "worktree-facts.sh on a bare repository: exit 2, --repo and repo-of.sh's reason" is "$rc:$(has "$err" "worktree-facts.sh: --repo .*bare.git belongs to no checkout (a bare repository)" && echo y)" "2:y"
run sh "$K/git-mount/scripts/main/mount-status.sh" --repo "$S/plain"
check "mount-status.sh on a plain folder: exit 2" is "$rc:$(has "$err" "mount-status.sh: --repo .*plain is not in a git repository" && echo y)" "2:y"
run sh "$K/git-identity/scripts/main/identity-card.sh" --list "$S/empty-list.json" --repo "$S/bare-wt"
check "identity-card.sh on a bare repository's worktree: exit 2" is "$rc:$(has "$err" "identity-card.sh: --repo .*bare-wt belongs to no checkout" && echo y)" "2:y"
EFF=$(sh "$K/crucible-effort/scripts/main/effort-start.sh" --name dev-base)
printf 'crucible(x): y\n' >"$S/msg"
run sh "$K/git-commit/scripts/internal/commit-object.sh" --repo "$S/bare.git" --tree x --parent y --message-file "$S/msg" --effort "$EFF"
check "commit-object.sh on a bare repository: exit 2" is "$rc:$(has "$err" "commit-object.sh: --repo .*bare.git belongs to no checkout" && echo y)" "2:y"
run sh "$K/git-commit/scripts/internal/commits-merge.sh" --repo "$S/plain" --commit x y --message-file "$S/msg" --effort "$EFF"
check "commits-merge.sh on a plain folder: exit 2" is "$rc:$(has "$err" "commits-merge.sh: --repo .*plain is not in a git repository" && echo y)" "2:y"

echo
echo "=== the scripts' contracts"
if command -v shellcheck >/dev/null 2>&1; then
	check "shellcheck -x -o all is clean" shellcheck -x -o all "$R"/domains/software-development/core/main-thread/dev-base/scripts/internal/*.sh
fi
check "dev-base has no SKILL.md, as core's crucible-events" test ! -e "$R/domains/software-development/core/main-thread/dev-base/SKILL.md"

echo
echo "=== coverage: every script under scripts/ ran on a case"
for p in "$R"/domains/software-development/core/main-thread/dev-base/scripts/internal/*.sh; do
	s=${p##*/}
	cases=$(grep -cx -- "$s" "$S/ran" || true)
	check "$s ran on a case ($cases runs)" test "$cases" -gt 0
done

echo
echo "=== $pass PASS, $fail FAIL"
[ "$fail" -eq 0 ]
