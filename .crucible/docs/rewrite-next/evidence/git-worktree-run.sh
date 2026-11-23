# Evidence run for git-worktree: every case through the installed layout (a
# scratch skills folder of links), from /. Only scratch keys: its own HOME,
# git config, GnuPG home and ssh agent, so the owner's agent, key ring,
# ~/.ssh and ~/.gnupg are never read. The effort's identity is set through
# git-identity's real scripts and the gate's real hooks; the human's yes to a
# drop goes through the gate's real hooks too.
R=/Users/cordona/IdeaProjects/cordona/claude-code-crucible/new-rewrite
S=/private/tmp/claude-501/-Users-cordona-IdeaProjects-cordona-claude-code-crucible/480d0359-cf0d-4c14-a59e-2a72be5dba4f/scratchpad/gworktree; rm -rf "$S"; mkdir -p "$S/home/.ssh" "$S/xdg" "$S/cfg/skills" "$S/msg"
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
export CRUCIBLE_HOME="$S/space" CLAUDE_CONFIG_DIR="$S/cfg" CLAUDE_CODE_SESSION_ID=sess-gw
unset SSH_AUTH_SOCK SSH_AGENT_PID GIT_CONFIG_COUNT
cd /
K="$S/cfg/skills"
for d in "$R"/framework/core/main-thread/*/ "$R"/domains/software-development/core/main-thread/*/; do d=${d%/}; ln -s "$d" "$K/${d##*/}"; done
GW=$K/git-worktree/scripts; GC=$K/git-commit/scripts; GI=$K/git-identity/scripts; GT=$K/crucible-gate
EV=$K/crucible-events/scripts

pass=0 fail=0
: >"$S/ran"
show() { sed "s|$S|<S>|g;s|$T|<T>|g;s|[0-9]\{8\}T[0-9]\{6\}-[0-9a-f]\{4\}|<id>|g;s|[0-9a-f]\{40\}|<sha>|g;s|[0-9a-f]\{12\}|<short>|g;s|[0-9A-F]\{40\}|<FPR>|g;s|[0-9A-F]\{16\}|<KEYID>|g;s|SHA256:[A-Za-z0-9+/]\{43\}|SHA256:<fp>|g;s|AAAA[A-Za-z0-9+/=]\{20,\}|<b64>|g"; }
# Runs "$@", keeping stdout in $out, stderr in $err and the exit in $rc, and
# shows them; notes each git-worktree script it runs for the coverage check.
run() {
	for a in "$@"; do case $a in "$GW"/main/*.sh | "$GW"/internal/*.sh) echo "${a##*/}" >>"$S/ran" ;; esac; done
	echo "  \$ $(echo "$*" | sed "s|$GW/||g;s|$K/||g" | show)"
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
# The newest event of type $2 in effort $1, read back with core's reader.
last_event() { sh $EV/internal/events-read.sh --effort "$1" --type "$2" | jq -c 'last'; }
count_events() { sh $EV/internal/events-read.sh --effort "$1" | jq 'length'; }
# The human's checkout: HEAD, every ref outside the effort's own (crucible
# branches and kept refs), the index, the status, the stashes and the config.
human() {
	{
		git -C "$S/repo" rev-parse HEAD; git -C "$S/repo" symbolic-ref HEAD
		git -C "$S/repo" for-each-ref --format='%(refname) %(objectname)' | grep -Ev '^refs/heads/crucible/|^refs/crucible/'
		shasum "$S/repo/.git/index"
		git -C "$S/repo" status --porcelain=v2 --untracked-files=all
		git -C "$S/repo" stash list
		shasum "$S/repo/.git/config"
	} | sed "s|$S||g"
}
all_refs() { git -C "$S/repo" for-each-ref --format='%(refname) %(objectname)'; }
pick_n=0
# One recorded choice gate through the real hooks: card, stop, question, answer.
pick() { # $1 effort, $2 subject, $3 card file, $4 question JSON file, $5 the human's answer
	pick_n=$((pick_n + 1)); t="pick-$pick_n"
	sh $GT/scripts/main/show-card.sh --record set-identity --effort "$1" --subject "$2" --choice "$3" >/dev/null
	jq -cn --rawfile m "$3" --arg s sess-gw '{session_id: $s, last_assistant_message: $m}' | sh $GT/hooks/stop/require-card-shown.sh >/dev/null
	jq -c --arg s sess-gw --arg t "$t" '{session_id: $s, tool_name: "AskUserQuestion", tool_use_id: $t, tool_input: .}' "$4" \
		| sh $GT/hooks/pre-tool-use/hold-question-until-card-shown.sh >/dev/null
	q=$(jq -r '.questions[0].question' "$4")
	jq -cn --arg s sess-gw --arg t "$t" --arg q "$q" --arg a "$5" '{session_id: $s, tool_name: "AskUserQuestion", tool_use_id: $t, tool_response: {answers: {($q): $a}}}' \
		| sh $GT/hooks/post-tool-use/record-gate-answer.sh
}
# One recorded yes gate through the real hooks: record $2, subject $3, the
# human's answer $4 (the yes label, or another).
yes_gate() { # $1 effort, $2 record, $3 subject, $4 the human's answer
	pick_n=$((pick_n + 1)); t="yes-$pick_n"
	printf '%s\n' "Drop $3? It holds work the checkout lacks." >"$S/yes-card.md"
	sh $GT/scripts/main/show-card.sh --record "$2" --effort "$1" --subject "$3" --accept 'Drop it (Recommended)' "$S/yes-card.md" >/dev/null
	jq -cn --rawfile m "$S/yes-card.md" '{session_id: "sess-gw", last_assistant_message: $m}' | sh $GT/hooks/stop/require-card-shown.sh >/dev/null
	jq -cn --arg t "$t" '{session_id: "sess-gw", tool_name: "AskUserQuestion", tool_use_id: $t, tool_input: {questions: [{question: "Drop the tree?", header: "Drop", multiSelect: false, options: [{label: "Drop it (Recommended)", description: "its commits go"}, {label: "Keep it", description: "nothing changes"}]}]}}' \
		| sh $GT/hooks/pre-tool-use/hold-question-until-card-shown.sh >/dev/null
	jq -cn --arg t "$t" --arg a "$4" '{session_id: "sess-gw", tool_name: "AskUserQuestion", tool_use_id: $t, tool_response: {answers: {"Drop the tree?": $a}}}' \
		| sh $GT/hooks/post-tool-use/record-gate-answer.sh
}
msg() { printf '{"kind":"build","text":"%s"}' "$2" >"$S/msg/$1.json"; sh $GC/main/commit-message.sh --input "$S/msg/$1.json" --out "$S/msg/$1"; echo "$S/msg/$1"; }
# Commits file $2 with text $3 in tree $1 of effort $4 through git-commit.
tree_commit() { printf '%s\n' "$3" >"$4/worktrees/$1/$2"; sh $GC/main/commit-tree.sh --worktree "$4/worktrees/$1" --message-file "$(msg "c-$1-$2" "change $2 in $1")" --effort "$4" | jq -r .commit; }
tip() { git -C "$S/repo" rev-parse "refs/heads/crucible/${F##*/}/$1"; }
human_commit() { printf '%s\n' "$2" >"$S/repo/$1"; git -C "$S/repo" add "$1"; git -C "$S/repo" -c user.name=Human -c user.email=human@example.test commit -q -m "human: $1"; }

echo "=== set-up: scratch keys, a scratch repository with dependency folders and secrets, two efforts (one with no identity)"
gpg --batch --pinentry-mode loopback --passphrase '' --quick-gen-key 'Gpg Tester <gpg@example.test>' ed25519 sign never 2>/dev/null
ssh-keygen -q -t ed25519 -N '' -C ssh@example.test -f "$HOME/.ssh/agent_key"
eval "$(ssh-agent -s -a "$T/agent.sock")" >/dev/null; ssh-add -q "$HOME/.ssh/agent_key" 2>/dev/null; rm "$HOME/.ssh/agent_key"
printf 'ssh@example.test %s\n' "$(cut -d ' ' -f 1,2 "$HOME/.ssh/agent_key.pub")" >"$HOME/.ssh/allowed_signers"
git config --global user.name 'Ssh Tester'
git config --global gpg.ssh.allowedSignersFile "$HOME/.ssh/allowed_signers"
git init -q -b main "$S/repo"
printf 'node_modules/\n.venv/\n.env\n' >"$S/repo/.gitignore"
printf '{}\n' >"$S/repo/package.json"; printf 'base\n' >"$S/repo/f.txt"; printf 'keep\n' >"$S/repo/a.txt"
git -C "$S/repo" add -A; git -C "$S/repo" -c user.name=Human -c user.email=human@example.test commit -q -m base
git -C "$S/repo" tag v1
mkdir -p "$S/repo/node_modules/left-pad" "$S/repo/.venv/bin"
printf 'module\n' >"$S/repo/node_modules/left-pad/index.js"
printf 'home = /usr\n' >"$S/repo/.venv/pyvenv.cfg"
printf 'VIRTUAL_ENV="%s/.venv"\n' "$S/repo" >"$S/repo/.venv/bin/activate"
printf 'SECRET=hush\n' >"$S/repo/.env"
printf '//registry/:_authToken=hush\n' >"$S/repo/.npmrc"
printf '.npmrc\n.worktreeinclude\n' >>"$S/repo/.git/info/exclude"
REPO=$(cd "$S/repo" && pwd -P)
F=$(sh $K/crucible-effort/scripts/main/effort-start.sh --name tree-work)
NONE=$(sh $K/crucible-effort/scripts/main/effort-start.sh --name no-identity)
FN=${F##*/}
sh $GI/main/identity-list.sh >"$S/list.json" 2>/dev/null
sh $GI/main/identity-card.sh --list "$S/list.json" --repo "$S/repo" >"$S/card.md"
sh $GI/main/identity-card.sh --list "$S/list.json" --repo "$S/repo" --question >"$S/q.json"
SUB="$REPO:$(shasum -a 256 "$S/list.json" | cut -d ' ' -f 1)"
pick "$F" "$SUB" "$S/card.md" "$S/q.json" "$(jq -r '[.[] | select(.signing.format == "ssh")][0].label' "$S/list.json")"
sh $GI/main/identity-set.sh --effort "$F" --repo "$S/repo" --list "$S/list.json" >/dev/null
check "the effort's identity is set through git-identity's real scripts" is "$(sh $GI/main/identity-get.sh --effort "$F" --repo "$S/repo" | jq -r .signing.format)" ssh
# A stand-in neighbour that answers the busy scan, in this scratch skills
# folder only: busy for a name listed in its file, failing for "broken".
mkdir -p "$K/busy-standin/scripts/internal"
printf '#!/bin/sh\n[ "$4" != broken-check ] || exit 1\n! grep -qx -- "$4" "%s/busy-names" 2>/dev/null || echo "busy standing in for $4"\n' "$S" >"$K/busy-standin/scripts/internal/busy.sh"
: >"$S/busy-names"
HEAD0=$(git -C "$S/repo" rev-parse HEAD)

echo
echo "=== worktree-facts.sh"
run sh $GW/main/worktree-facts.sh --repo "$S/repo"
check "a clean checkout: repo, head, branch, uncommitted 0, no trees key" is "$(echo "$out" | jq -c '[.repo == "'"$REPO"'", .head == "'"$HEAD0"'", .branch, .uncommitted, has("trees")]')" '[true,true,"refs/heads/main",0,false]'
printf 'dirty\n' >"$S/repo/a.txt"; printf 'new\n' >"$S/repo/new.txt"
run sh $GW/main/worktree-facts.sh --repo "$S/repo" --effort "$F"
check "a checkout with uncommitted changes: 2 paths, and no live trees yet" is "$(echo "$out" | jq -c '[.uncommitted, .trees]')" '[2,[]]'

echo
echo "=== worktree-snapshot.sh"
H0=$(human)
run sh $GW/main/worktree-snapshot.sh --repo "$S/repo" --effort "$F"
SNAP=$(echo "$out" | jq -r .commit)
check "a snapshot: exit 0, new: true, signed: true" is "$rc:$(echo "$out" | jq -c '[.new, .signed]')" '0:[true,true]'
check "git verify-commit accepts it" git -C "$S/repo" verify-commit "$SNAP"
check "its parent is HEAD, its tree holds the change and the untracked file" is "$(git -C "$S/repo" log -1 --format=%P "$SNAP"):$(git -C "$S/repo" show "$SNAP:a.txt"):$(git -C "$S/repo" show "$SNAP:new.txt")" "$HEAD0:dirty:new"
check "ignored files are not in it" is "$(git -C "$S/repo" ls-tree -r --name-only "$SNAP" | grep -Ec 'node_modules|\.env|\.venv')" 0
check "the human's HEAD, refs, index, status, stashes and config are untouched" is "$(human)" "$H0"
check "no ref at all was written" is "$(all_refs | grep -c "$SNAP")" 0
run sh $GW/main/worktree-snapshot.sh --repo "$S/repo" --effort "$NONE"
check "no identity for the repository: exit 2, set the identity first" is "$rc:$(has "$err" 'set the identity first' && echo y)" "2:y"
git -C "$S/repo" stash -q -u; H1=$(human)
run sh $GW/main/worktree-snapshot.sh --repo "$S/repo" --effort "$F"
check "a clean checkout: new: false, the commit is HEAD, nothing written" is "$rc:$(echo "$out" | jq -c '[.commit == "'"$HEAD0"'", .new]'):$(human)" "0:[true,false]:$H1"
git -C "$S/repo" stash pop -q

echo
echo "=== worktree-setup.sh on its own"
git -C "$S/repo" worktree add -q --detach "$S/plain" HEAD 2>/dev/null
run sh $GW/internal/worktree-setup.sh --from "$S/repo" --to "$S/plain"
check "exit 0: node and python detected, node_modules and the virtual env copied" is "$rc:$(echo "$out" | grep -Ec '^(detected node|detected python|copied node_modules|copied \.venv)$')" "0:4"
check "the venv's launcher is repointed at the copy" is "$(cat "$S/plain/.venv/bin/activate")" "VIRTUAL_ENV=\"$S/plain/.venv\""
check ".env and .npmrc are not copied without .worktreeinclude" is "$([ -e "$S/plain/.env" ] && echo env)$([ -e "$S/plain/.npmrc" ] && echo npmrc)" ""
run sh $GW/internal/worktree-setup.sh --from "$S/repo" --to "$S/repo"
check "--to the same as --from: exit 2" is "$rc:$(has "$err" 'same folder' && echo y)" "2:y"
run sh $GW/internal/worktree-setup.sh --from "$S/plain" --to "$S/repo"
check "--from a linked worktree: exit 2" is "$rc:$(has "$err" 'linked worktree' && echo y)" "2:y"
run sh $GW/internal/worktree-setup.sh --from relative --to "$S/plain"
check "--from not absolute: exit 2" is "$rc" 2
run sh $GW/internal/worktree-setup.sh --from "$S/repo"
check "--to missing: exit 2" is "$rc" 2
printf '!.env\n' >"$S/repo/.worktreeinclude"
run sh $GW/internal/worktree-setup.sh --from "$S/repo" --to "$S/plain"
check "a .worktreeinclude negation line: exit 2, nothing copied" is "$rc:$(has "$err" 'negation' && echo y)" "2:y"
rm "$S/repo/.worktreeinclude"
git -C "$S/repo" worktree remove --force "$S/plain"

echo
echo "=== setup-plan.sh, setup-copy.sh and setup-repoint.sh on their own"
# A checkout of its own: dependency folders, a tracked folder named like
# one, an absolute link into the checkout, a launcher and a binary.
git init -q -b main "$S/sr"
printf 'node_modules/\n.venv/\n.env\n' >"$S/sr/.gitignore"; printf '{}\n' >"$S/sr/package.json"
mkdir -p "$S/sr/lib/node_modules" "$S/sr/node_modules/left-pad" "$S/sr/node_modules/.bin" "$S/sr/.venv/bin"
printf 'kept\n' >"$S/sr/lib/node_modules/keep.js"
git -C "$S/sr" add -A; git -C "$S/sr" add -f lib/node_modules/keep.js
git -C "$S/sr" -c user.name=t -c user.email=t@t commit -q -m base
printf 'module\n' >"$S/sr/node_modules/left-pad/index.js"
ln -s "$S/sr/node_modules/left-pad/index.js" "$S/sr/node_modules/.bin/left-pad"
printf 'home = /usr\n' >"$S/sr/.venv/pyvenv.cfg"
printf 'VIRTUAL_ENV="%s/.venv"\n' "$S/sr" >"$S/sr/.venv/bin/activate"
printf 'bin\000%s/.venv\n' "$S/sr" >"$S/sr/.venv/bin/python"
printf 'SECRET=hush\n' >"$S/sr/.env"; printf '{"t":1}\n' >"$S/sr/auth.json"
printf '.worktreeinclude\n' >>"$S/sr/.git/info/exclude"
git -C "$S/sr" worktree add -q --detach "$S/sw" HEAD 2>/dev/null
run sh $GW/internal/setup-plan.sh --from "$S/sr" --to "$S/sw"
echo "$out" >"$S/plan.json"
check "setup-plan.sh: exit 0, node and python detected, from, from_given and to" is "$rc:$(echo "$out" | jq -c '[.detected, .from == "'"$S/sr"'", .from_given == "'"$S/sr"'", .to == "'"$S/sw"'"]')" '0:[["node","python"],true,true,true]'
check "  ... node_modules for node, .venv for python, the tracked lib/node_modules marked, bin to repoint" is "$(echo "$out" | jq -c '[.items[] | [.do, .path, .technology]], .repoint')" '[["copy","node_modules","node"],["copy",".venv","python"],["tracked","lib/node_modules",null]]
{"python":["bin"]}'
check "  ... read only: nothing in the tree yet" is "$([ -e "$S/sw/node_modules" ] && echo nm)" ""
run sh $GW/internal/setup-plan.sh --from "$S/sr/" --to "$S/sw"
check "--from with a trailing /: from_given without it" is "$rc:$(echo "$out" | jq -r .from_given)" "0:$S/sr"
printf '.env\nauth.json\n' >"$S/sr/.worktreeinclude"
run sh $GW/internal/setup-plan.sh --from "$S/sr" --to "$S/sw"
check "a .worktreeinclude listing .env and auth.json: both planned as copies with no technology" is "$(echo "$out" | jq -c '[.items[] | select(.technology == null and .do == "copy") | .path]')" '[".env","auth.json"]'
mkdir -p "$S/sr/cfg"; : >"$S/sr/cfg/$(printf 'a\tb')"; printf 'cfg/*\n' >"$S/sr/.worktreeinclude"
mkdir -p "$S/sr/$(printf 'odd\nenv')"; : >"$S/sr/$(printf 'odd\nenv')/pyvenv.cfg"
run sh $GW/internal/setup-plan.sh --from "$S/sr" --to "$S/sw"
check "names holding a control character, from a glob and from the search, planned as bad" is "$rc:$(echo "$out" | jq -c '[.items[] | select(.do == "bad") | .path]')" '0:["cfg/a?b","odd?env/pyvenv.cfg"]'
echo "$out" >"$S/plan-bad.json"
rm -rf "$S/sr/cfg" "$S/sr/$(printf 'odd\nenv')" "$S/sr/.worktreeinclude"
git -C "$S/sr" worktree add -q --detach "$S/sr/inner" HEAD 2>/dev/null; mkdir -p "$S/sr/inner/node_modules"
run sh $GW/internal/setup-plan.sh --from "$S/sr" --to "$S/sr/inner"
check "a --to inside --from is never searched" is "$rc:$(echo "$out" | jq -c '[.items[].path | select(startswith("inner"))]')" '0:[]'
git -C "$S/sr" worktree remove --force "$S/sr/inner"
mkdir -p "$S/sr/locked"; chmod 000 "$S/sr/locked"
run sh $GW/internal/setup-plan.sh --from "$S/sr" --to "$S/sw"
check "a folder find can't read: exit 0, said on stderr" is "$rc:$(has "$err" 'find could not read 1 places' && echo y)" "0:y"
chmod 755 "$S/sr/locked"; rmdir "$S/sr/locked"
run sh $GW/internal/setup-plan.sh --from
check "--from with no value: exit 2" is "$rc:$(has "$err" 'needs a value' && echo y)" "2:y"
run sh $GW/internal/setup-plan.sh --to "$S/sw"
check "no --from: exit 2" is "$rc:$(has "$err" '--from needs a value' && echo y)" "2:y"
run sh $GW/internal/setup-plan.sh --from "$S/sr"
check "no --to: exit 2" is "$rc:$(has "$err" '--to needs a value' && echo y)" "2:y"
run sh $GW/internal/setup-plan.sh --from "$(printf '/tmp/a\tb')" --to "$S/sw"
check "--from holding a control character: exit 2" is "$rc:$(has "$err" 'holds a control character' && echo y)" "2:y"
mkdir -p "$S/plan-nogit" "$S/plan-nojq"
for t in dirname tr mktemp rm; do ln -s "$(command -v $t)" "$S/plan-nogit/$t"; ln -s "$(command -v $t)" "$S/plan-nojq/$t"; done
ln -s "$(command -v git)" "$S/plan-nojq/git"
run env PATH="$S/plan-nogit" /bin/sh $GW/internal/setup-plan.sh --from "$S/sr" --to "$S/sw"
check "setup-plan.sh without git: exit 4, git 2.31+ asked for" is "$rc:$(has "$err" 'git not found; expected git 2.31+ on PATH' && echo y)" "4:y"
run env PATH="$S/plan-nojq" /bin/sh $GW/internal/setup-plan.sh --from "$S/sr" --to "$S/sw"
check "setup-plan.sh without jq: exit 4" is "$rc:$(has "$err" 'jq not found; expected jq 1.6+ on PATH' && echo y)" "4:y"
run sh $GW/internal/setup-plan.sh --from "$S/nothing" --to "$S/sw"
check "--from not a folder: exit 2" is "$rc:$(has "$err" 'is not a folder' && echo y)" "2:y"
run sh $GW/internal/setup-plan.sh --from "$S/sr/lib" --to "$S/sw"
check "--from not a work tree's top folder: exit 2" is "$rc:$(has "$err" 'is not the top folder' && echo y)" "2:y"
run sh $GW/internal/setup-plan.sh --from "$S/sw" --to "$S/sr"
check "--from a linked worktree: exit 2" is "$rc:$(has "$err" 'linked worktree' && echo y)" "2:y"
run sh $GW/internal/setup-plan.sh --from "$S/sr" --to "$S/sr"
check "--to the same as --from: exit 2" is "$rc:$(has "$err" 'same folder' && echo y)" "2:y"
run sh $GW/internal/setup-plan.sh --from "$S/sr" --to relative
check "--to not absolute, every problem listed: exit 2" is "$rc:$(has "$err" '--to relative is not absolute' && echo y)" "2:y"
mkdir "$S/sr/.worktreeinclude"
run sh $GW/internal/setup-plan.sh --from "$S/sr" --to "$S/sw"
check ".worktreeinclude not a readable file: exit 2" is "$rc:$(has "$err" 'not a readable file' && echo y)" "2:y"
rmdir "$S/sr/.worktreeinclude"; printf '!x\nnode_modules/**\n' >"$S/sr/.worktreeinclude"
run sh $GW/internal/setup-plan.sh --from "$S/sr" --to "$S/sw"
check "a negation and a ** line: exit 2, one line each" is "$rc:$(echo "$err" | grep -c 'negation\|holds \*\*')" "2:2"
rm "$S/sr/.worktreeinclude"
# The data file lives in the scripts' lib folder, so its own problems run
# from a copy of the scripts folder; the plan needs nothing else beside it.
mkdir -p "$S/alt"; cp -R "$R/domains/software-development/core/main-thread/git-worktree/scripts" "$S/alt/scripts"
rm "$S/alt/scripts/lib/worktree-setup.json"
run sh "$S/alt/scripts/internal/setup-plan.sh" --from "$S/sr" --to "$S/sw"; echo setup-plan.sh >>"$S/ran"
check "the data file missing: exit 2" is "$rc:$(has "$err" 'the data file' && echo y)" "2:y"
printf '{' >"$S/alt/scripts/lib/worktree-setup.json"
run sh "$S/alt/scripts/internal/setup-plan.sh" --from "$S/sr" --to "$S/sw"; echo setup-plan.sh >>"$S/ran"
check "the data file not JSON: exit 2" is "$rc:$(has "$err" 'not valid JSON' && echo y)" "2:y"
printf '{"technologies":5,"x":1}' >"$S/alt/scripts/lib/worktree-setup.json"
run sh "$S/alt/scripts/internal/setup-plan.sh" --from "$S/sr" --to "$S/sw"; echo setup-plan.sh >>"$S/ran"
check "the data file of the wrong shape: exit 2, one line per problem" is "$rc:$(echo "$err" | grep -c 'technologies is a JSON number\|field "x" is not known')" "2:2"

echo "--- setup-copy.sh"
run sh $GW/internal/setup-copy.sh --plan "$S/plan.json"
check "exit 0: a copy method, node_modules and .venv copied for their technology, lib/node_modules tracked" is "$rc:$(echo "$out" | jq -c '[(.method | IN("cp -c", "reflink", "plain")), [.done[] | select(.did != "flag") | [.did, .path, .technology]]]')" '0:[true,[["copied","node_modules","node"],["copied",".venv","python"],["tracked","lib/node_modules",null]]]'
check "  ... the absolute link into the checkout flagged with its target" is "$(echo "$out" | jq -c '[.done[] | select(.did == "flag") | [.path, .target == "'"$S/sr/node_modules/left-pad/index.js"'"]]')" '[["node_modules/.bin/left-pad",true]]'
check "  ... the copies are there, the launcher not yet repointed" is "$(cat "$S/sw/node_modules/left-pad/index.js"):$(cat "$S/sw/.venv/bin/activate")" "module:VIRTUAL_ENV=\"$S/sr/.venv\""
run sh $GW/internal/setup-copy.sh --plan "$S/plan.json"
check "a second run overwrites nothing: exists for both" is "$rc:$(echo "$out" | jq -c '[.done[] | select(.did == "exists") | .path]')" '0:["node_modules",".venv"]'
jq -c '.items = [{do: "copy", path: ".env"}, {do: "copy", path: "auth.json"}]' "$S/plan.json" >"$S/plan-secret.json"
run sh $GW/internal/setup-copy.sh --plan "$S/plan-secret.json"
check "a .env git ignores in the tree copied, an auth.json it doesn't left out as unignored" is "$rc:$(echo "$out" | jq -c '[.done[] | [.did, .path]]'):$(cat "$S/sw/.env"):$([ -e "$S/sw/auth.json" ] && echo auth)" '0:[["copied",".env"],["unignored","auth.json"]]:SECRET=hush:'
mkdir -p "$S/elsewhere" "$S/sr/out" "$S/sr/ro/a" "$S/sw/ro"; : >"$S/sr/out/x"; : >"$S/sr/ro/a/b"
ln -s "$S/elsewhere" "$S/sw/out"; chmod 555 "$S/sw/ro"
jq -c '.items = [{do: "bad", path: "odd?env"}, {do: "copy", path: "out/x"}, {do: "copy", path: "missing-thing"}, {do: "copy", path: "ro/a/b"}, {do: "copy", path: "package.json", technology: "node"}]' "$S/plan.json" >"$S/plan-problems.json"
run sh $GW/internal/setup-copy.sh --plan "$S/plan-problems.json"
check "exit 4, the rest copied, one line per problem: a bad name, a folder leading outside, a failed cp, a failed mkdir" is "$rc:$(echo "$out" | jq -c '[.done[] | [.did, .path]]'):$(for w in 'odd?env was not copied: its name holds a control character' 'out/x was not copied: its folder in --to is not a folder inside --to' 'missing-thing was not copied: cp' 'ro/a/b was not copied: mkdir'; do has "$err" "$w" || echo "miss $w"; done):$([ -e "$S/elsewhere/x" ] && echo leaked)" '4:[["exists","package.json"]]::'
chmod 755 "$S/sw/ro"
run sh $GW/internal/setup-copy.sh --plan "$S/plan-bad.json"
check "the plan with bad names: exit 4 after copying the rest" is "$rc:$(echo "$err" | grep -c 'its name holds a control character')" "4:2"
run sh $GW/internal/setup-copy.sh
check "setup-copy.sh with no --plan: exit 2" is "$rc" 2
run sh $GW/internal/setup-copy.sh --plan
check "--plan with no value: exit 2" is "$rc" 2
run sh $GW/internal/setup-copy.sh --plan "$S/no-plan.json"
check "--plan not a readable file: exit 2" is "$rc:$(has "$err" 'not a readable file' && echo y)" "2:y"
printf '{' >"$S/plan-broken.json"
run sh $GW/internal/setup-copy.sh --plan "$S/plan-broken.json"
check "--plan not JSON: exit 2" is "$rc:$(has "$err" 'is not a plan setup-plan.sh prints' && echo y)" "2:y"
jq -c '.items = [{do: "copy", path: "/etc/passwd"}]' "$S/plan.json" >"$S/plan-shape.json"
run sh $GW/internal/setup-copy.sh --plan "$S/plan-shape.json"
check "a plan item with an absolute path: exit 2, nothing copied" is "$rc:$(has "$err" 'is not a plan' && echo y)" "2:y"
jq -c '.from = "'"$S/nothing"'"' "$S/plan.json" >"$S/plan-from.json"
run sh $GW/internal/setup-copy.sh --plan "$S/plan-from.json"
check "a plan whose checkout is no folder: exit 2" is "$rc:$(has "$err" "checkout" && echo y)" "2:y"
jq -c '.to = "'"$S/nothing"'"' "$S/plan.json" >"$S/plan-to.json"
run sh $GW/internal/setup-copy.sh --plan "$S/plan-to.json"
check "a plan whose tree is no folder: exit 2" is "$rc:$(has "$err" "tree" && echo y)" "2:y"
jq -c '.to = .from' "$S/plan.json" >"$S/plan-same.json"
run sh $GW/internal/setup-copy.sh --plan "$S/plan-same.json"
check "a plan whose tree is its checkout: exit 2" is "$rc:$(has "$err" 'is its checkout' && echo y)" "2:y"

echo "--- setup-repoint.sh"
run sh $GW/internal/setup-repoint.sh --from "$S/sr" --to "$S/sw" --folder .venv --subfolder bin
check "exit 0: one launcher repointed, the binary left alone" is "$rc:$out:$(cat "$S/sw/.venv/bin/activate"):$(grep -c "$S/sr" "$S/sw/.venv/bin/python")" "0:{\"folder\":\".venv\",\"repointed\":1}:VIRTUAL_ENV=\"$S/sw/.venv\":1"
check "  ... the checkout's own launcher unchanged" is "$(cat "$S/sr/.venv/bin/activate")" "VIRTUAL_ENV=\"$S/sr/.venv\""
run sh $GW/internal/setup-repoint.sh --from "$S/sr/" --to "$S/sw" --folder .venv --subfolder bin --subfolder Scripts
check "again, with a second --subfolder not there: nothing left to repoint" is "$rc:$(echo "$out" | jq -r .repointed)" "0:0"
mkdir -p "$S/outside-venv/bin"; printf '%s/.venv/lnk\n' "$S/sr" >"$S/outside-venv/bin/act"; ln -s "$S/outside-venv" "$S/sw/.venv/lnk"
printf '%s/.venv\n' "$S/sr" >"$S/sr/.venv/bin/hard"; ln "$S/sr/.venv/bin/hard" "$S/sw/.venv/bin/hard"
printf '%s/.venv\n' "$S/sr" >"$S/sw/.venv/bin/locked"; chmod 444 "$S/sw/.venv/bin/locked"
run sh $GW/internal/setup-repoint.sh --from "$S/sr" --to "$S/sw" --folder .venv --subfolder bin --subfolder lnk/bin
check "exit 4, one line each: a subfolder leading outside, a launcher that is the source, one not writable" is "$rc:$(for w in 'lnk/bin was not repointed: it leads outside' 'hard was not repointed: it is the source file itself' 'locked was not repointed: it could not be written'; do has "$err" "$w" || echo "miss $w"; done):$(cat "$S/outside-venv/bin/act")" "4::$S/sr/.venv/lnk"
rm -f "$S/sw/.venv/lnk" "$S/sw/.venv/bin/hard" "$S/sr/.venv/bin/hard"; chmod 644 "$S/sw/.venv/bin/locked"; rm "$S/sw/.venv/bin/locked"
run sh $GW/internal/setup-repoint.sh --to "$S/sw" --folder .venv --subfolder bin
check "setup-repoint.sh with no --from: exit 2" is "$rc" 2
run sh $GW/internal/setup-repoint.sh --from "$S/sr" --to "$S/sw" --folder .venv
check "no --subfolder: exit 2" is "$rc" 2
run sh $GW/internal/setup-repoint.sh --from "$S/sr" --to "$S/sw" --folder
check "--folder with no value: exit 2" is "$rc" 2
run sh $GW/internal/setup-repoint.sh --from relative --to "$S/sw" --folder .venv --subfolder bin
check "--from not absolute: exit 2" is "$rc:$(has "$err" 'is not absolute' && echo y)" "2:y"
run sh $GW/internal/setup-repoint.sh --from "$(printf '/tmp/a\tb')" --to "$S/sw" --folder .venv --subfolder bin
check "--from holding a control character: exit 2" is "$rc:$(has "$err" 'control character' && echo y)" "2:y"
run sh $GW/internal/setup-repoint.sh --from "$S/sr" --to "$S/nothing" --folder .venv --subfolder bin
check "--to not a folder: exit 2" is "$rc:$(has "$err" 'is not a folder' && echo y)" "2:y"
run sh $GW/internal/setup-repoint.sh --from "$S/sr" --to "$S/sw" --folder /etc --subfolder bin
check "--folder absolute: exit 2" is "$rc:$(has "$err" 'not a plain relative path' && echo y)" "2:y"
run sh $GW/internal/setup-repoint.sh --from "$S/sr" --to "$S/sw" --folder .venv --subfolder /bin
check "--subfolder absolute: exit 2" is "$rc:$(has "$err" 'not a plain relative path' && echo y)" "2:y"
run sh $GW/internal/setup-repoint.sh --from "$S/sr" --to "$S/sw" --folder ../sr --subfolder bin
check "--folder leading outside --to: exit 2, nothing changed" is "$rc:$(has "$err" 'is not a folder inside --to' && echo y):$(cat "$S/sr/.venv/bin/activate")" "2:y:VIRTUAL_ENV=\"$S/sr/.venv\""

echo "--- worktree-setup.sh through the three"
git -C "$S/sr" worktree add -q --detach "$S/sw2" HEAD 2>/dev/null
chmod 444 "$S/sr/.venv/bin/activate"
run sh $GW/internal/worktree-setup.sh --from "$S/sr" --to "$S/sw2"
check "a launcher copied read-only: copied, repointed 0, exit 4 with the problem after the lines" is "$rc:$(echo "$out" | grep -Ec '^(copied \.venv|repointed 0 \.venv)$'):$(has "$err" 'activate was not repointed' && echo y)" "4:2:y"
chmod 644 "$S/sr/.venv/bin/activate"
check "  ... the lines in order: detected, method, then each thing done, the flag after its copy" is "$(echo "$out" | sed 's/^method .*/method/' | tr '\n' '|')" "detected node|detected python|method|copied node_modules|flag symlink node_modules/.bin/left-pad -> $S/sr/node_modules/left-pad/index.js|copied .venv|repointed 0 .venv|tracked lib/node_modules|"
mkdir -p "$S/sr/cfg"; : >"$S/sr/cfg/$(printf 'a\tb')"; printf 'cfg/*\n' >"$S/sr/.worktreeinclude"
git -C "$S/sr" worktree add -q --detach "$S/sw3" HEAD 2>/dev/null
run sh $GW/internal/worktree-setup.sh --from "$S/sr" --to "$S/sw3"
check "a bad name: the rest copied and repointed, exit 4" is "$rc:$(echo "$out" | grep -Ec '^(copied node_modules|repointed 1 \.venv)$'):$(has "$err" 'cfg/a?b was not copied' && echo y)" "4:2:y"
rm -rf "$S/sr/cfg" "$S/sr/.worktreeinclude"
run sh $GW/internal/worktree-setup.sh --from "$S/sr" --from "$S/sr" --to "$S/sw3"
check "--from given twice: exit 2" is "$rc:$(has "$err" 'given twice' && echo y)" "2:y"
run sh $GW/internal/worktree-setup.sh --to "$S/sw3"
check "--from missing: exit 2" is "$rc:$(has "$err" '--from missing' && echo y)" "2:y"
run sh $GW/internal/worktree-setup.sh --from
check "--from with no value: exit 2" is "$rc:$(has "$err" 'needs a value' && echo y)" "2:y"
for w in sw sw2 sw3; do git -C "$S/sr" worktree remove --force "$S/$w"; done

echo
echo "=== worktree-uncommitted.sh and worktree-changes.sh"
git init -q -b main "$S/u"; printf 'a\n' >"$S/u/a.txt"; printf 'b\n' >"$S/u/b.txt"; printf 'ignored.txt\n' >"$S/u/.gitignore"
git -C "$S/u" add -A; git -C "$S/u" -c user.name=t -c user.email=t@t commit -q -m u; UH=$(git -C "$S/u" rev-parse HEAD)
run sh $GW/internal/worktree-uncommitted.sh --dir "$S/u"
check "a clean folder: 0" is "$rc:$out" '0:{"uncommitted":0}'
run sh $GW/internal/worktree-changes.sh --dir "$S/u" --head "$UH"
check "a clean folder: tree and head_tree the same" is "$rc:$(echo "$out" | jq -c '[.tree == .head_tree, .head_tree == "'"$(git -C "$S/u" rev-parse "$UH^{tree}")"'"]')" '0:[true,true]'
printf 'changed\n' >"$S/u/a.txt"; git -C "$S/u" mv b.txt c.txt; printf 'new\n' >"$S/u/new.txt"; printf 'x\n' >"$S/u/ignored.txt"
run sh $GW/internal/worktree-uncommitted.sh --dir "$S/u"
check "a change, a rename counted once by its new path, an untracked file, no ignored one: 3" is "$rc:$out" '0:{"uncommitted":3}'
UI=$(shasum "$S/u/.git/index"); US=$(git -C "$S/u" status --porcelain)
run sh $GW/internal/worktree-changes.sh --dir "$S/u" --head "$UH"
CT=$(echo "$out" | jq -r .tree)
check "every change in the tree object, nothing ignored" is "$rc:$(git -C "$S/u" show "$CT:a.txt"):$(git -C "$S/u" ls-tree --name-only "$CT" | tr '\n' ' ')" "0:changed:.gitignore a.txt c.txt new.txt "
check "  ... the folder's index and status untouched" is "$(shasum "$S/u/.git/index"):$(git -C "$S/u" status --porcelain)" "$UI:$US"
run sh $GW/internal/worktree-changes.sh --dir "$S/u" --head HEAD
check "--head a name resolves to its commit" is "$rc:$(echo "$out" | jq -r .tree)" "0:$CT"
mkdir -p "$S/plain-dir"
run sh $GW/internal/worktree-uncommitted.sh --dir "$S/plain-dir"
check "worktree-uncommitted.sh in no git work tree: exit 4" is "$rc:$(has "$err" 'git status failed' && echo y)" "4:y"
run sh $GW/internal/worktree-uncommitted.sh --dir relative
check "worktree-uncommitted.sh --dir not absolute: exit 2" is "$rc" 2
run sh $GW/internal/worktree-uncommitted.sh --dir
check "worktree-uncommitted.sh --dir with no value: exit 2" is "$rc" 2
run sh $GW/internal/worktree-uncommitted.sh
check "worktree-uncommitted.sh with no --dir: exit 2" is "$rc" 2
run sh $GW/internal/worktree-changes.sh --dir "$S/plain-dir" --head "$UH"
check "worktree-changes.sh in no git work tree: exit 2" is "$rc:$(has "$err" 'is not in a git work tree' && echo y)" "2:y"
run sh $GW/internal/worktree-changes.sh --dir relative --head "$UH"
check "worktree-changes.sh --dir not absolute: exit 2" is "$rc" 2
run sh $GW/internal/worktree-changes.sh --head "$UH"
check "worktree-changes.sh with no --dir: exit 2" is "$rc" 2
run sh $GW/internal/worktree-changes.sh --dir "$S/u"
check "worktree-changes.sh with no --head: exit 2" is "$rc:$(has "$err" 'needs a commit' && echo y)" "2:y"
run sh $GW/internal/worktree-changes.sh --dir "$S/u" --head -x
check "--head starting with -: exit 2" is "$rc:$(has "$err" 'starts with -' && echo y)" "2:y"
run sh $GW/internal/worktree-changes.sh --dir "$S/u" --head "$(printf 'a\tb')"
check "--head holding a control character: exit 2" is "$rc:$(has "$err" 'control character' && echo y)" "2:y"
run sh $GW/internal/worktree-changes.sh --dir "$S/u" --head nosuch
check "--head no commit: exit 2" is "$rc:$(has "$err" 'is no commit' && echo y)" "2:y"
run sh $GW/internal/worktree-changes.sh --dir "$S/u" --head
check "--head with no value: exit 2" is "$rc" 2

echo
echo "=== worktree-cut.sh: from checkout, snapshot, ref, and a tree"
H2=$(human); N0=$(count_events "$F")
run sh $GW/main/worktree-cut.sh --effort "$F" --repo "$S/repo" --name one --from checkout
E=$(last_event "$F" worktree.cut)
check "from checkout: exit 0, stdout the event's path" is "$rc:$out" "0:$(sh $EV/internal/events-read.sh --effort "$F" --paths | tail -n 1)"
check "worktree.cut read back: by worktree-cut.sh, {name, repo, path, branch, base, from}" is "$(echo "$E" | jq -c '[.by, (.body | keys), .body.name, .body.repo, .body.path, .body.branch, .body.base, .body.from]')" "[\"worktree-cut.sh\",[\"base\",\"branch\",\"from\",\"name\",\"path\",\"repo\"],\"one\",\"$REPO\",\"$F/worktrees/one\",\"crucible/$FN/one\",\"$HEAD0\",\"checkout\"]"
check "the tree is on its branch at the base, clean" is "$(git -C "$F/worktrees/one" symbolic-ref HEAD):$(git -C "$F/worktrees/one" rev-parse HEAD):$(git -C "$F/worktrees/one" status --porcelain)" "refs/heads/crucible/$FN/one:$HEAD0:"
check "set up: node_modules and the venv copied, .env and .npmrc not" is "$([ -f "$F/worktrees/one/node_modules/left-pad/index.js" ] && echo nm)$([ -f "$F/worktrees/one/.venv/pyvenv.cfg" ] && echo venv)$([ -e "$F/worktrees/one/.env" ] && echo env)$([ -e "$F/worktrees/one/.npmrc" ] && echo npmrc)" "nmvenv"
check "the setup's lines went to stderr" has "$err" 'copied node_modules'
check "the human's HEAD, refs, index, status, stashes and config are untouched by the cut" is "$(human)" "$H2"
run sh $GW/main/worktree-cut.sh --effort "$F" --repo "$S/repo" --name snap --from snapshot
E=$(last_event "$F" worktree.cut); SB=$(echo "$E" | jq -r .body.base)
check "from snapshot: exit 0, from snapshot, base a new commit on HEAD holding the changes" is "$rc:$(echo "$E" | jq -r .body.from):$(git -C "$S/repo" log -1 --format=%P "$SB"):$(cat "$F/worktrees/snap/a.txt")" "0:snapshot:$HEAD0:dirty"
check "  ... signed, and the human's checkout untouched" is "$(git -C "$S/repo" verify-commit "$SB" >/dev/null 2>&1 && echo signed):$(human)" "signed:$H2"
check "  ... worktree.cut read back carries signed: true" is "$(echo "$E" | jq -c .body.signed)" true
run sh $GW/main/worktree-cut.sh --effort "$F" --repo "$S/repo" --name byref --from ref:v1
E=$(last_event "$F" worktree.cut)
check "from ref:v1: exit 0, from ref:v1, base the tag's commit, no signed (the cut made no base)" is "$rc:$(echo "$E" | jq -c '[.body.from, .body.base == "'"$HEAD0"'", (.body | has("signed"))]')" '0:["ref:v1",true,false]'
ONE1=$(tree_commit one o.txt 'one work' "$F")
run sh $GW/main/worktree-cut.sh --effort "$F" --repo "$S/f-other-folder-ok" --name nope --from checkout
check "a --repo in no repository: exit 2" is "$rc" 2
run sh $GW/main/worktree-cut.sh --effort "$F" --repo "$S/repo" --name child --from worktree:one
E=$(last_event "$F" worktree.cut)
check "from worktree:one: exit 0, base one's tip" is "$rc:$(echo "$E" | jq -c '[.body.from, .body.base == "'"$ONE1"'"]')" '0:["worktree:one",true]'

echo
echo "=== worktree-cut.sh: joined from two trees, and the refusals"
SNAP1=$(tree_commit snap s.txt 'snap work' "$F")
run sh $GW/main/worktree-cut.sh --effort "$F" --repo "$S/repo" --name joined --from worktree:one --from worktree:snap
E=$(last_event "$F" worktree.cut); JB=$(echo "$E" | jq -r .body.base)
check "two trees: exit 0, from \"worktree:one worktree:snap\", base a merge of both tips" is "$rc:$(echo "$E" | jq -r .body.from):$(git -C "$S/repo" log -1 --format=%P "$JB")" "0:worktree:one worktree:snap:$ONE1 $SNAP1"
check "  ... worktree.cut read back carries signed: true" is "$(echo "$E" | jq -c .body.signed)" true
check "  ... signed through commits-merge.sh, both changes in the tree" is "$(git -C "$S/repo" verify-commit "$JB" >/dev/null 2>&1 && echo signed):$(cat "$F/worktrees/joined/o.txt" "$F/worktrees/joined/s.txt" | tr '\n' ' ')" "signed:one work snap work "
run sh $GW/main/worktree-cut.sh --effort "$F" --repo "$S/repo" --name one --from checkout
check "a name in use: exit 2" is "$rc:$(has "$err" 'already has a live tree named one' && echo y)" "2:y"
run sh $GW/main/worktree-cut.sh --effort "$F" --repo "$S/repo" --name Bad_Name --from checkout
check "a name that is not lowercase words with dashes: exit 2" is "$rc" 2
run sh $GW/main/worktree-cut.sh --effort "$F" --repo "$S/repo" --name x --from elsewhere
check "an unknown --from: exit 2" is "$rc" 2
run sh $GW/main/worktree-cut.sh --effort "$F" --repo "$S/repo" --name x --from checkout --from worktree:one
check "checkout repeated with a tree: exit 2" is "$rc:$(has "$err" 'only worktree:NAME repeats' && echo y)" "2:y"
run sh $GW/main/worktree-cut.sh --effort "$F" --repo "$S/repo" --name x --from worktree:nosuch
check "a tree that is not live: exit 2" is "$rc" 2
run sh $GW/main/worktree-cut.sh --effort "$F" --repo "$S/repo" --name x --from ref:no-such-ref
check "a ref that is no commit: exit 2" is "$rc" 2
run sh $GW/main/worktree-cut.sh --effort "$F" --repo "$S/repo" --name x --from ref:-x
check "a ref starting with -: exit 2" is "$rc" 2
run sh $GW/main/worktree-cut.sh --effort "$NONE" --repo "$S/repo" --name x --from snapshot
check "a snapshot with no identity: exit 2, set the identity first, no tree" is "$rc:$(has "$err" 'set the identity first' && echo y):$([ -e "$NONE/worktrees/x" ] && echo tree)" "2:y:"
tree_commit byref o.txt 'clash' "$F" >/dev/null
run sh $GW/main/worktree-cut.sh --effort "$F" --repo "$S/repo" --name x --from worktree:one --from worktree:byref
check "joined tips that conflict: exit 2, naming the path, no tree, no branch" is "$rc:$(has "$err" 'o.txt' && echo y):$([ -e "$F/worktrees/x" ] && echo tree):$(git -C "$S/repo" branch --list "crucible/$FN/x")" "2:y::"

echo
echo "=== worktree-cut.sh: a failing setup leaves no tree and no event"
printf '!bad\n' >"$S/repo/.worktreeinclude"
N1=$(count_events "$F")
run sh $GW/main/worktree-cut.sh --effort "$F" --repo "$S/repo" --name failing --from checkout
check "exit 4, the setup's reason and the rollback on stderr" is "$rc:$(has "$err" 'negation' && echo y):$(has "$err" 'removed the tree failing' && echo y)" "4:y:y"
check "no folder, no registration, no branch, no event" is "$([ -e "$F/worktrees/failing" ] && echo folder):$(git -C "$S/repo" worktree list | grep -c failing):$(git -C "$S/repo" branch --list "crucible/$FN/failing"):$(count_events "$F")" ":0::$N1"

echo
echo "=== worktree-cut.sh: secrets copied when .worktreeinclude lists them"
printf '# secrets this repository lets a tree have\n.env\n.npmrc\nauth.json\n' >"$S/repo/.worktreeinclude"
printf '{"token":"hush"}\n' >"$S/repo/auth.json"
run sh $GW/main/worktree-cut.sh --effort "$F" --repo "$S/repo" --name secrets --from checkout
check "exit 0: the listed .env and .npmrc copied (git ignores both)" is "$rc:$(cat "$F/worktrees/secrets/.env" 2>/dev/null):$(cat "$F/worktrees/secrets/.npmrc" 2>/dev/null)" "0:SECRET=hush://registry/:_authToken=hush"
check "  ... the listed auth.json git doesn't ignore is left out as unignored" is "$([ -e "$F/worktrees/secrets/auth.json" ] && echo auth):$(has "$err" 'unignored auth.json' && echo y)" ":y"
rm "$S/repo/.worktreeinclude" "$S/repo/auth.json"

echo
echo "=== worktree-facts.sh with live trees"
run sh $GW/main/worktree-facts.sh --repo "$F/worktrees/one" --effort "$F"
check "from a tree's folder: the same repository, every live tree listed" is "$(echo "$out" | jq -c '[.repo == "'"$REPO"'", [.trees[].name]]')" '[true,["one","snap","byref","child","joined","secrets"]]'
check "one's tip is not in the checkout, and child and joined hold it" is "$(echo "$out" | jq -c '.trees[] | select(.name == "one") | [.tip == "'"$ONE1"'", .present, .uncommitted, .in_checkout, (.not_in | index("child")), (.not_in | index("joined"))]')" '[true,true,0,false,null,null]'
check "secrets, with no commits of its own, is held by the checkout" is "$(echo "$out" | jq -c '.trees[] | select(.name == "secrets") | .in_checkout')" true

echo
echo "=== worktree-trees.sh"
run sh $GW/internal/worktree-trees.sh --effort "$F"
check "every live tree, oldest cut first, on one line" is "$rc:$(echo "$out" | wc -l | tr -d ' '):$(echo "$out" | jq -c '[.[].name]')" '0:1:["one","snap","byref","child","joined","secrets"]'
check "  ... each with name, repo, path, branch, from, cut_base, base and seq" is "$(echo "$out" | jq -c '.[0] | [keys, .repo == "'"$REPO"'", .path == "'"$F/worktrees/one"'", .cut_base == .base]')" '[["base","branch","cut_base","from","name","path","repo","seq"],true,true,true]'
run sh $GW/internal/worktree-trees.sh --effort "$F" --name joined
check "--name joined: that tree only, from both trees" is "$rc:$(echo "$out" | jq -c '[.[] | [.name, .from]]')" '0:[["joined","worktree:one worktree:snap"]]'
run sh $GW/internal/worktree-trees.sh --effort "$F" --name nosuch
check "--name of no live tree: an empty list" is "$rc:$out" '0:[]'
run sh $GW/internal/worktree-trees.sh --effort "$F" --name Bad_Name
check "--name not lowercase words: exit 2" is "$rc" 2
run sh $GW/internal/worktree-trees.sh --effort "$S/repo"
check "--effort no effort folder: exit 2" is "$rc:$(has "$err" 'is not an effort folder' && echo y)" "2:y"
run sh $GW/internal/worktree-trees.sh --effort relative
check "--effort not absolute: exit 2" is "$rc" 2
run sh $GW/internal/worktree-trees.sh --effort
check "--effort with no value: exit 2" is "$rc" 2

echo
echo "=== a chain of three trees, and chain-sync"
run sh $GW/main/worktree-cut.sh --effort "$F" --repo "$S/repo" --name mid --from worktree:child
MID1=$(tree_commit mid m.txt 'mid work' "$F")
run sh $GW/main/worktree-cut.sh --effort "$F" --repo "$S/repo" --name leaf --from worktree:mid
run sh $GW/main/worktree-chain.sh --effort "$F" --name leaf
check "chain of leaf: mid (direct), child and one (via mid), all held" is "$(echo "$out" | jq -c '[[.ancestors[] | [.name, .via, .held]], .moved]')" '[[["mid","mid",true],["child","mid",true],["one","mid",true]],false]'
run sh $GW/main/worktree-chain-sync.sh --effort "$F" --name leaf
check "chain-sync with nothing moved: in_sync, nothing written" is "$rc:$out" '0:{"result":"in_sync"}'
ONE2=$(tree_commit one o2.txt 'one more' "$F")
run sh $GW/main/worktree-chain.sh --effort "$F" --name leaf
check "one moved: two levels up, one is not held, moved true" is "$(echo "$out" | jq -c '[[.ancestors[] | select(.held | not) | .name], .moved, (.ancestors[] | select(.name == "one") | .tip == "'"$ONE2"'")]')" '[["one"],true,true]'
run sh $GW/main/worktree-chain-sync.sh --effort "$F" --name leaf
check "chain-sync takes one's tip in: merged, signed, leaf now holds it" is "$rc:$(echo "$out" | jq -c '[.result, .signed]'):$(git -C "$S/repo" merge-base --is-ancestor "$ONE2" "$(tip leaf)" && echo held)" '0:["merged",true]:held'
E=$(last_event "$F" worktree.synced)
check "worktree.synced read back: by worktree-catch-up.sh, with one's tip, merged" is "$(echo "$E" | jq -c '[.by, .body.name, .body.with == "'"$ONE2"'", .body.result, .body.commit == "'"$(tip leaf)"'", .body.signed]')" '["worktree-catch-up.sh","leaf",true,"merged",true,true]'
tree_commit one o3.txt 'one again' "$F" >/dev/null; tree_commit child c.txt 'child work' "$F" >/dev/null
run sh $GW/main/worktree-chain-sync.sh --effort "$F" --name leaf
check "two moved at two levels: joined first, then merged in; leaf holds both tips" is "$rc:$(echo "$out" | jq -r .result):$(git -C "$S/repo" merge-base --is-ancestor "$(tip one)" "$(tip leaf)" && git -C "$S/repo" merge-base --is-ancestor "$(tip child)" "$(tip leaf)" && echo both)" "0:merged:both"
tree_commit one clash.txt 'one side' "$F" >/dev/null; tree_commit mid clash.txt 'mid side' "$F" >/dev/null
LEAF_BEFORE=$(tip leaf)
run sh $GW/main/worktree-chain-sync.sh --effort "$F" --name leaf
check "moved trees whose tips conflict: exit 3, the paths on stdout, leaf unchanged" is "$rc:$(echo "$out" | jq -c .conflicts):$(tip leaf)" "3:[\"clash.txt\"]:$LEAF_BEFORE"

echo
echo "=== worktree-catch-up.sh"
human_commit h.txt 'human work'
run sh $GW/main/worktree-catch-up.sh --effort "$F" --name joined --with main
check "a clean catch-up of main: merged, signed, verify-commit, two parents" is "$rc:$(echo "$out" | jq -c '[.result, .signed]'):$(git -C "$S/repo" verify-commit "$(tip joined)" >/dev/null 2>&1 && echo ok):$(git -C "$S/repo" log -1 --format=%P "$(tip joined)" | wc -w | tr -d ' ')" '0:["merged",true]:ok:2'
check "  ... the sync commit names the tree and the effort" is "$(git -C "$S/repo" log -1 --format='%s|%(trailers:key=Worktree,valueonly)|%(trailers:key=Effort,valueonly)' "$(tip joined)" | tr -d '\n')" "crucible(sync): take in $(git -C "$S/repo" rev-parse --short=12 main)|joined|$FN"
run sh $GW/main/worktree-catch-up.sh --effort "$F" --name joined --with v1
check "already in sync: in_sync, no commit" is "$rc:$(echo "$out" | jq -c '[.result, has("commit")]'):$(last_event "$F" worktree.synced | jq -r .body.result)" '0:["in_sync",false]:in_sync'
N0=$(ls "$F/events" | wc -l)
run sh $GW/main/worktree-catch-up.sh --effort "$F" --name nosuch --with main
check "a name that is no live tree: exit 2, no event" is "$rc:$(has "$err" 'no live tree named nosuch' && echo y):$(ls "$F/events" | wc -l)" "2:y:$N0"
human_commit f.txt 'human side'
tree_commit secrets f.txt 'tree side' "$F" >/dev/null
SEC_TIP=$(tip secrets)
run sh $GW/main/worktree-catch-up.sh --effort "$F" --name secrets --with main
check "a conflict: result conflict, f.txt named, the merge left under way" is "$rc:$(echo "$out" | jq -c '[.result, .conflicts]'):$(git -C "$F/worktrees/secrets" rev-parse MERGE_HEAD)" "0:[\"conflict\",[\"f.txt\"]]:$(git -C "$S/repo" rev-parse main)"
check "worktree.synced conflict read back, no commit" is "$(last_event "$F" worktree.synced | jq -c '[.body.result, (.body | has("commit"))]')" '["conflict",false]'
run sh $GW/main/worktree-catch-up.sh --effort "$F" --name secrets --with main
check "a second catch-up during the merge: exit 2" is "$rc:$(has "$err" 'MERGE_HEAD under way' && echo y)" "2:y"
run sh $GW/main/worktree-catch-up.sh --effort "$F" --name secrets --abort
check "--abort: aborted, back at the tip, clean" is "$rc:$(echo "$out" | jq -r .result):$(git -C "$F/worktrees/secrets" rev-parse HEAD):$(git -C "$F/worktrees/secrets" status --porcelain)" "0:aborted:$SEC_TIP:"
check "worktree.synced aborted read back, with the merge's commit" is "$(last_event "$F" worktree.synced | jq -c '[.body.result, .body.with == "'"$(git -C "$S/repo" rev-parse main)"'"]')" '["aborted",true]'
run sh $GW/main/worktree-catch-up.sh --effort "$F" --name secrets --abort
check "--abort with no merge under way: exit 2" is "$rc" 2
run sh $GW/main/worktree-catch-up.sh --effort "$F" --name secrets --with main --abort
check "--with and --abort together: exit 2" is "$rc" 2
run sh $GW/main/worktree-catch-up.sh --effort "$F" --name secrets
check "neither --with nor --abort: exit 2" is "$rc" 2
printf 'wip\n' >"$F/worktrees/secrets/wip.txt"
run sh $GW/main/worktree-catch-up.sh --effort "$F" --name secrets --with main
check "a tree with uncommitted changes: exit 2" is "$rc" 2
rm "$F/worktrees/secrets/wip.txt"

echo
echo "=== worktree-move.sh"
BYREF_TIP=$(tip byref)
run sh $GW/main/worktree-move.sh --effort "$F" --name byref --to main
E=$(last_event "$F" worktree.moved)
check "a move that leaves commits out: exit 0, the old tip kept under refs/crucible/moved/<effort>/byref/1" is "$rc:$(echo "$E" | jq -r .body.kept):$(git -C "$S/repo" rev-parse "refs/crucible/moved/$FN/byref/1")" "0:refs/crucible/moved/$FN/byref/1:$BYREF_TIP"
check "worktree.moved read back: by worktree-move.sh, from the old tip, to main" is "$(echo "$E" | jq -c '[.by, .body.from == "'"$BYREF_TIP"'", .body.to == "'"$(git -C "$S/repo" rev-parse main)"'"]')" '["worktree-move.sh",true,true]'
check "the tree is at main, clean" is "$(tip byref):$(git -C "$F/worktrees/byref" status --porcelain)" "$(git -C "$S/repo" rev-parse main):"
run sh $GW/main/worktree-move.sh --effort "$F" --name byref --to main
check "already there: in place, no event" is "$rc:$(has "$out" 'in place' && echo y):$(last_event "$F" worktree.moved | jq -r .seq)" "0:y:$(echo "$E" | jq -r .seq)"
tree_commit snap s2.txt 'more snap' "$F" >/dev/null
run sh $GW/main/worktree-move.sh --effort "$F" --name byref --to "$(tip snap)"
check "a move to another line of work keeps the old tip as /2" is "$rc:$(last_event "$F" worktree.moved | jq -r '.body.kept // "none"')" "0:refs/crucible/moved/$FN/byref/2"
run sh $GW/main/worktree-move.sh --effort "$F" --name child --to "$(tip leaf)"
check "a fast-forward move keeps nothing" is "$rc:$(last_event "$F" worktree.moved | jq -r '.body | has("kept")')" "0:false"
printf 'wip\n' >"$F/worktrees/byref/wip.txt"
run sh $GW/main/worktree-move.sh --effort "$F" --name byref --to main
check "a tree with uncommitted changes: exit 2, nothing moved" is "$rc:$(tip byref)" "2:$(tip snap)"
rm "$F/worktrees/byref/wip.txt"
run sh $GW/main/worktree-move.sh --effort "$F" --name byref --to nosuch
check "--to no commit: exit 2" is "$rc" 2
N0=$(ls "$F/events" | wc -l)
run sh $GW/main/worktree-move.sh --effort "$F" --name nosuch --to main
check "a name that is no live tree: exit 2, no event" is "$rc:$(has "$err" 'no live tree named nosuch' && echo y):$(ls "$F/events" | wc -l)" "2:y:$N0"

echo
echo "=== worktree-kept.sh"
run sh $GW/internal/worktree-kept.sh --effort "$F" --name byref
check "byref's kept refs, both moves" is "$rc:$out" "0:{\"kept\":[\"refs/crucible/moved/$FN/byref/1\",\"refs/crucible/moved/$FN/byref/2\"]}"
run sh $GW/internal/worktree-kept.sh --effort "$F" --name byref --next moved
check "--next moved: the next free one, /3" is "$rc:$(echo "$out" | jq -r .next)" "0:refs/crucible/moved/$FN/byref/3"
run sh $GW/internal/worktree-kept.sh --effort "$F" --name byref --next discarded
check "--next discarded: /1 of its own kind" is "$rc:$(echo "$out" | jq -r .next)" "0:refs/crucible/discarded/$FN/byref/1"
run sh $GW/internal/worktree-kept.sh --effort "$F" --name one
check "a tree with none: an empty list, no next" is "$rc:$out" '0:{"kept":[]}'
run sh $GW/internal/worktree-trees.sh --effort "$F" --name child
check "worktree-trees.sh after a move: base the move's to, cut_base the cut's" is "$(echo "$out" | jq -c '.[0] | [.base == "'"$(last_event "$F" worktree.moved | jq -r .body.to)"'", .cut_base == "'"$ONE1"'"]')" '[true,true]'
run sh $GW/internal/worktree-kept.sh --effort "$F" --name byref --next stashed
check "--next neither moved nor discarded: exit 2" is "$rc:$(has "$err" 'neither moved nor discarded' && echo y)" "2:y"
run sh $GW/internal/worktree-kept.sh --effort "$F" --name nosuch
check "a name of no live tree: exit 2" is "$rc:$(has "$err" 'no live tree named nosuch' && echo y)" "2:y"
run sh $GW/internal/worktree-kept.sh --effort "$F" --name Bad_Name
check "a name not lowercase words: exit 2" is "$rc" 2
run sh $GW/internal/worktree-kept.sh --effort "$S/repo" --name byref
check "--effort no effort folder: exit 2" is "$rc" 2
run sh $GW/internal/worktree-kept.sh --effort "$F" --name
check "--name with no value: exit 2" is "$rc" 2

echo
echo "=== worktree-diff.sh"
H3=$(human)
run sh $GW/main/worktree-diff.sh --effort "$F" --name one
D=$out
check "the diff file: <effort>/diffs/one-<base>-<tip>.patch" is "$D" "$F/diffs/one-$(git -C "$S/repo" rev-parse --short=12 "$HEAD0")-$(git -C "$S/repo" rev-parse --short=12 "$(tip one)").patch"
check "it holds one's four commits from the cut's base, the changed files and the diff" is "$(grep -c '^commit ' "$D"):$(grep -c '^A	o.txt$' "$D"):$(grep -c '^+one work$' "$D")" "4:1:1"
check "the human's checkout untouched by the diff" is "$(human)" "$H3"
run sh $GW/main/worktree-diff.sh --effort "$F" --name child
check "after a move, the base is the move's to" has "$out" "child-$(git -C "$S/repo" rev-parse --short=12 "$(tip leaf)")-"
run sh $GW/main/worktree-diff.sh --effort "$F" --name one --base "$ONE1"
check "--base names another base: only the three later commits" is "$rc:$(grep -c '^commit ' "$out")" "0:3"
run sh $GW/main/worktree-diff.sh --effort "$F" --name nosuch
check "a tree that is not live: exit 2" is "$rc" 2

echo
echo "=== worktree-discard.sh"
printf 'changed\n' >"$F/worktrees/joined/o.txt"; printf 'untracked\n' >"$F/worktrees/joined/u.txt"
JT=$(tip joined)
run sh $GW/main/worktree-discard.sh --effort "$F" --name joined
E=$(last_event "$F" worktree.discarded); KEPT=$(echo "$E" | jq -r .body.kept)
check "exit 0: worktree.discarded by worktree-discard.sh, kept refs/crucible/discarded/<effort>/joined/1" is "$rc:$(echo "$E" | jq -r .by):$KEPT" "0:worktree-discard.sh:refs/crucible/discarded/$FN/joined/1"
check "worktree.discarded read back carries signed: true" is "$(echo "$E" | jq -c .body.signed)" true
check "the kept commit holds both changes, parent the tip, signed" is "$(git -C "$S/repo" show "$KEPT:o.txt"):$(git -C "$S/repo" show "$KEPT:u.txt"):$(git -C "$S/repo" log -1 --format=%P "$KEPT"):$(git -C "$S/repo" verify-commit "$KEPT" >/dev/null 2>&1 && echo signed)" "changed:untracked:$JT:signed"
check "the tree is back at its tip, clean, its ignored dependency folder kept" is "$(git -C "$F/worktrees/joined" rev-parse HEAD):$(git -C "$F/worktrees/joined" status --porcelain):$([ -d "$F/worktrees/joined/node_modules" ] && echo nm)" "$JT::nm"
run sh $GW/main/worktree-discard.sh --effort "$F" --name joined
check "nothing uncommitted: exit 2" is "$rc" 2
N0=$(ls "$F/events" | wc -l)
run sh $GW/main/worktree-discard.sh --effort "$F" --name nosuch
check "a name that is no live tree: exit 2, no event" is "$rc:$(has "$err" 'no live tree named nosuch' && echo y):$(ls "$F/events" | wc -l)" "2:y:$N0"

echo
echo "=== the refusals of a tree's state, a repository's and an identity's"
run sh $GW/main/worktree-catch-up.sh --effort "$F" --name secrets --with main
check "a conflict left in secrets again" is "$rc:$(echo "$out" | jq -r .result)" "0:conflict"
run sh $GW/main/worktree-move.sh --effort "$F" --name secrets --to main
check "worktree-move.sh: a merge under way: exit 2" is "$rc:$(has "$err" 'MERGE_HEAD under way' && echo y)" "2:y"
run sh $GW/main/worktree-discard.sh --effort "$F" --name secrets
check "worktree-discard.sh: a merge under way: exit 2" is "$rc:$(has "$err" 'MERGE_HEAD under way' && echo y)" "2:y"
run sh $GW/main/worktree-catch-up.sh --effort "$F" --name secrets --abort
git -C "$F/worktrees/one" checkout -q --detach
for s in move discard catch-up; do
	case $s in move) run sh $GW/main/worktree-move.sh --effort "$F" --name one --to main ;; discard) run sh $GW/main/worktree-discard.sh --effort "$F" --name one ;; *) run sh $GW/main/worktree-catch-up.sh --effort "$F" --name one --with main ;; esac
	check "worktree-$s.sh: a tree not on its branch: exit 2" is "$rc:$(has "$err" 'is not on its branch' && echo y)" "2:y"
done
git -C "$F/worktrees/one" checkout -q "crucible/$FN/one"
run sh $GW/main/worktree-cut.sh --effort "$F" --repo "$S/repo" --name gone --from checkout
rm -rf "$F/worktrees/gone"
for s in move discard catch-up; do
	case $s in move) run sh $GW/main/worktree-move.sh --effort "$F" --name gone --to main ;; discard) run sh $GW/main/worktree-discard.sh --effort "$F" --name gone ;; *) run sh $GW/main/worktree-catch-up.sh --effort "$F" --name gone --with main ;; esac
	check "worktree-$s.sh: a tree whose folder is gone: exit 2" is "$rc:$(has "$err" 'is not there' && echo y)" "2:y"
done
run sh $GW/main/worktree-drop.sh --effort "$F" --name gone
check "a tree with nothing of its own and its folder gone drops with no gate" is "$rc:$(last_event "$F" worktree.dropped | jq -c .body)" '0:{"name":"gone"}'
run sh $GW/main/worktree-chain.sh --effort "$F" --name gone
check "worktree-chain.sh: a tree that is not live: exit 2" is "$rc" 2
run sh $GW/main/worktree-chain-sync.sh --effort "$F" --name gone
check "worktree-chain-sync.sh: a tree that is not live: exit 2" is "$rc" 2
run sh $GW/internal/open-work.sh --effort "$S/repo"
check "open-work.sh: a folder that is no effort: exit 2" is "$rc" 2
git init -q --bare "$S/bare.git"
run sh $GW/main/worktree-facts.sh --repo "$S/bare.git"
check "worktree-facts.sh: a bare repository: exit 2" is "$rc:$(has "$err" 'bare repository' && echo y)" "2:y"
git init -q -b main "$S/empty"
run sh $GW/main/worktree-snapshot.sh --repo "$S/empty" --effort "$F"
check "worktree-snapshot.sh: a checkout with no HEAD commit: exit 2" is "$rc:$(has "$err" 'no HEAD commit' && echo y)" "2:y"
git init -q -b main "$S/odd"; git -C "$S/odd" -c user.name=t -c user.email=t@t commit -q --allow-empty -m one
printf 'x\n' >"$S/odd/x.txt"
git -C "$S/odd" config core.sparseCheckout true
run sh $GW/main/worktree-snapshot.sh --repo "$S/odd" --effort "$F"
check "worktree-snapshot.sh: a sparse checkout: exit 2" is "$rc:$(has "$err" 'is sparse' && echo y)" "2:y"
git -C "$S/odd" config core.sparseCheckout false
git -C "$S/odd" rev-parse HEAD >"$S/odd/.git/MERGE_HEAD"
run sh $GW/main/worktree-snapshot.sh --repo "$S/odd" --effort "$F"
check "worktree-snapshot.sh: a merge under way in the checkout: exit 2" is "$rc:$(has "$err" 'MERGE_HEAD under way' && echo y)" "2:y"
rm "$S/odd/.git/MERGE_HEAD"
echo "--- an effort with no identity: catch-up and discard refuse"
run sh $GW/main/worktree-cut.sh --effort "$NONE" --repo "$S/repo" --name bare-tree --from ref:v1
printf 'n\n' >"$NONE/worktrees/bare-tree/n.txt"
git -C "$NONE/worktrees/bare-tree" add n.txt; git -C "$NONE/worktrees/bare-tree" -c user.name=t -c user.email=t@t commit -q -m n
run sh $GW/main/worktree-catch-up.sh --effort "$NONE" --name bare-tree --with main
check "worktree-catch-up.sh: no identity: exit 2, set the identity first, the tree unchanged" is "$rc:$(has "$err" 'set the identity first' && echo y):$(git -C "$NONE/worktrees/bare-tree" status --porcelain)" "2:y:"
printf 'u\n' >"$NONE/worktrees/bare-tree/u.txt"
run sh $GW/main/worktree-discard.sh --effort "$NONE" --name bare-tree
check "worktree-discard.sh: no identity: exit 2, the change still there, no kept ref" is "$rc:$(has "$err" 'set the identity first' && echo y):$(cat "$NONE/worktrees/bare-tree/u.txt"):$(git -C "$S/repo" for-each-ref refs/crucible/discarded/ | grep -c "${NONE##*/}")" "2:y:u:0"

echo
echo "=== a signer that hangs or fails: the cut and the discard say signed: false"
# The signer is set for these commands only, through git's GIT_CONFIG_*
# environment, so no config file is changed. The hanging one writes its own
# PID so the cleanup can stop it, then sleeps.
printf '#!/bin/sh\nprintf "%%s\\n" "$$" >>"%s/hang.pids"\nexec sleep 30\n' "$S" >"$S/hang-ssh"; chmod 755 "$S/hang-ssh"
t0=$(date +%s)
run env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=gpg.ssh.program GIT_CONFIG_VALUE_0="$S/hang-ssh" sh $GW/main/worktree-cut.sh --effort "$F" --repo "$S/repo" --name unsigned --from snapshot
t1=$(date +%s); E=$(last_event "$F" worktree.cut)
echo "    took $((t1 - t0)) s"
check "a hanging signer: the cut from snapshot is made, stderr says signing timed out after 10 s" is "$rc:$(has "$err" 'unsigned: signing timed out after 10 s' && echo y)" "0:y"
check "  ... worktree.cut read back carries signed: false, and its base carries no signature" is "$(echo "$E" | jq -c '[.body.name, .body.signed]'):$(git -C "$S/repo" cat-file commit "$(echo "$E" | jq -r .body.base)" | grep -c '^gpgsig')" '["unsigned",false]:0'
printf 'w\n' >"$F/worktrees/unsigned/w.txt"
run env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=gpg.ssh.program GIT_CONFIG_VALUE_0=/usr/bin/false sh $GW/main/worktree-discard.sh --effort "$F" --name unsigned
E=$(last_event "$F" worktree.discarded)
check "a failing signer: the discard keeps the changes, stderr says unsigned" is "$rc:$(has "$err" 'unsigned:' && echo y):$(git -C "$S/repo" show "$(echo "$E" | jq -r .body.kept):w.txt")" "0:y:w"
check "  ... worktree.discarded read back carries signed: false" is "$(echo "$E" | jq -c '[.body.name, .body.signed]')" '["unsigned",false]'

echo
echo "=== the busy scan: a stand-in neighbour's busy.sh"
echo joined >"$S/busy-names"
for s in worktree-drop.sh worktree-discard.sh worktree-move.sh; do
	printf 'x\n' >"$F/worktrees/joined/busy.txt"
	case $s in worktree-move.sh) run sh "$GW"/*/"$s" --effort "$F" --name joined --to main ;; *) run sh "$GW"/*/"$s" --effort "$F" --name joined ;; esac
	check "$s refuses a busy tree: exit 2, naming the neighbour's line" is "$rc:$(has "$err" 'tree joined is busy: busy-standin: joined: busy standing in for joined' && echo y)" "2:y"
	rm -f "$F/worktrees/joined/busy.txt"
done
run sh $GW/main/worktree-catch-up.sh --effort "$F" --name joined --with main
check "worktree-catch-up.sh refuses a busy tree: exit 2" is "$rc:$(has "$err" 'busy' && echo y)" "2:y"
echo "--- worktree-busy.sh"
echo joined >"$S/busy-names"
run sh $GW/internal/worktree-busy.sh --effort "$F" --name joined --name one
check "exit 5, the busy tree's line named with its component and tree" is "$rc:$(echo "$out" | jq -c .busy)" '5:["busy-standin: joined: busy standing in for joined"]'
run sh $GW/internal/worktree-busy.sh --effort "$F" --name broken-check
check "a check that fails counts as busy" is "$rc:$(echo "$out" | jq -c .busy)" '5:["busy-standin: broken-check: busy.sh failed"]'
: >"$S/busy-names"
run sh $GW/internal/worktree-busy.sh --effort "$F" --name joined
check "nothing busy: exit 0, an empty list" is "$rc:$out" '0:{"busy":[]}'
run sh $GW/internal/worktree-busy.sh --effort "$F"
check "no --name: exit 2" is "$rc" 2
run sh $GW/internal/worktree-busy.sh --effort "$F" --name Bad
check "a bad name: exit 2" is "$rc" 2
run sh $GW/internal/worktree-busy.sh --effort "$S/repo" --name joined
check "no effort folder: exit 2" is "$rc" 2
run sh $GW/internal/worktree-busy.sh --effort "$F" --name
check "--name with no value: exit 2" is "$rc" 2
echo joined >"$S/busy-names"
: >"$S/busy-names"
run sh $GW/main/worktree-cut.sh --effort "$F" --repo "$S/repo" --name broken-check --from checkout
run sh $GW/main/worktree-drop.sh --effort "$F" --name broken-check
check "a busy.sh that fails counts as busy: exit 2" is "$rc:$(has "$err" 'busy-standin: broken-check: busy.sh failed' && echo y)" "2:y"
rm -rf "$K/busy-standin"
run sh $GW/internal/worktree-busy.sh --effort "$F" --name broken-check
check "worktree-busy.sh with no neighbour answering: nothing busy" is "$rc:$out" '0:{"busy":[]}'
run sh $GW/main/worktree-drop.sh --effort "$F" --name broken-check
check "with no neighbour answering, a clean tree with nothing unlanded drops with no gate" is "$rc:$(last_event "$F" worktree.dropped | jq -c .body)" '0:{"name":"broken-check"}'

echo
echo "=== worktree-drop.sh"
run sh $GW/main/worktree-drop.sh --effort "$F" --name mid
check "unlanded commits, no recorded yes: exit 2, naming record and subject" is "$rc:$(has "$err" "record drop-worktree, subject mid:$(tip mid)" && echo y)" "2:y"
check "  ... and nothing removed" is "$([ -d "$F/worktrees/mid" ] && echo folder):$(git -C "$S/repo" branch --list "crucible/$FN/mid" | wc -l | tr -d ' ')" "folder:1"
yes_gate "$F" drop-worktree "mid:$(tip mid)" 'Keep it'
run sh $GW/main/worktree-drop.sh --effort "$F" --name mid
check "the human said no: exit 2" is "$rc" 2
MID_TIP=$(tip mid)
yes_gate "$F" drop-worktree "mid:$MID_TIP" 'Drop it (Recommended)'
YES=$(sh $GT/scripts/internal/gate-answer.sh --effort "$F" --record drop-worktree --subject "mid:$MID_TIP" | sed 's/^ACCEPTED: //')
run sh $GW/main/worktree-drop.sh --effort "$F" --name mid
E=$(last_event "$F" worktree.dropped)
check "with the recorded yes: exit 0, worktree.dropped by worktree-drop.sh carries answer" is "$rc:$(echo "$E" | jq -c '[.by, .body.name, .body.answer == '"$YES"']')" '0:["worktree-drop.sh","mid",true]'
check "  ... the folder, registration and branch are gone" is "$([ -e "$F/worktrees/mid" ] && echo folder):$(git -C "$S/repo" worktree list | grep -c "/mid$"):$(git -C "$S/repo" branch --list "crucible/$FN/mid")" ":0:"
echo "--- the same yes, on a tree with the same name and tip: refused"
run sh $GW/main/worktree-cut.sh --effort "$F" --repo "$S/repo" --name mid --from "ref:$ONE1"
run sh $GW/main/worktree-catch-up.sh --effort "$F" --name mid --with "$MID_TIP"
check "the new mid takes the old tip in" is "$(tip mid)" "$MID_TIP"
run sh $GW/main/worktree-drop.sh --effort "$F" --name mid
check "the yes already used: exit 2, nothing removed" is "$rc:$(has "$err" "yes $YES already dropped a tree" && echo y):$([ -d "$F/worktrees/mid" ] && echo folder)" "2:y:folder"
echo "--- kept refs go with the tree, under the yes"
BT=$(tip byref)
run sh $GW/main/worktree-drop.sh --effort "$F" --name byref
check "byref holds kept refs with unlanded commits: exit 2 without a yes" is "$rc" 2
yes_gate "$F" drop-worktree "byref:$BT" 'Drop it (Recommended)'
run sh $GW/main/worktree-drop.sh --effort "$F" --name byref
check "with the yes: exit 0, its kept refs under refs/crucible/moved/ are gone" is "$rc:$(git -C "$S/repo" for-each-ref "refs/crucible/moved/$FN/byref/" | wc -l | tr -d ' ')" "0:0"
printf 'x\n' >"$F/worktrees/joined/o.txt"
run sh $GW/main/worktree-drop.sh --effort "$F" --name joined
check "a tree with uncommitted changes: exit 2, discard or commit first" is "$rc:$(has "$err" 'discard them first' && echo y)" "2:y"
git -C "$F/worktrees/joined" checkout -q -- o.txt
JT=$(tip joined)
yes_gate "$F" drop-worktree "joined:$JT" 'Drop it (Recommended)'
run sh $GW/main/worktree-drop.sh --effort "$F" --name joined
check "joined drops with its yes, and its discarded kept ref is gone" is "$rc:$(git -C "$S/repo" for-each-ref "refs/crucible/discarded/$FN/joined/" | wc -l | tr -d ' ')" "0:0"
echo "--- a folder deleted by hand"
ST=$(tip snap)
rm -rf "$F/worktrees/snap"
yes_gate "$F" drop-worktree "snap:$ST" 'Drop it (Recommended)'
run sh $GW/main/worktree-drop.sh --effort "$F" --name snap
check "exit 0: the registration and the branch removed too" is "$rc:$(git -C "$S/repo" worktree list --porcelain | grep -c '/snap$'):$(git -C "$S/repo" branch --list "crucible/$FN/snap")" "0:0:"
run sh $GW/main/worktree-drop.sh --effort "$F" --name snap
check "a tree no longer live: exit 2" is "$rc" 2

echo
echo "=== a tree dropped while a move, a catch-up or a discard runs: no event"
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
HEAD_NOW=$(git -C "$S/repo" rev-parse HEAD)
sh $GW/main/worktree-cut.sh --effort "$F" --repo "$S/repo" --name race-move --from ref:v1 >/dev/null 2>&1
sh $GW/main/worktree-cut.sh --effort "$F" --repo "$S/repo" --name race-sync --from checkout >/dev/null 2>&1
sh $GW/main/worktree-cut.sh --effort "$F" --repo "$S/repo" --name race-discard --from checkout >/dev/null 2>&1
printf 'gone soon\n' >"$F/worktrees/race-discard/race.txt"
for t in race-move race-sync race-discard; do yes_gate "$F" drop-worktree "$t:$HEAD_NOW" 'Drop it (Recommended)'; done
N0=$(count_type "$F" worktree.moved)
paused_start 'reset --quiet --keep' 'reset --quiet --keep' sh $GW/main/worktree-move.sh --effort "$F" --name race-move --to main
run sh $GW/main/worktree-drop.sh --effort "$F" --name race-move
paused_finish
check "worktree-move.sh, its tree dropped after the move: exit 2, no worktree.moved" is "$rc:$(has "$err" 'tree race-move was dropped while worktree-move.sh ran; no worktree.moved was written' && echo y):$(count_type "$F" worktree.moved)" "2:y:$N0"
N0=$(count_type "$F" worktree.synced)
paused_start 'merge-base --is-ancestor' 'merge-base --is-ancestor' sh $GW/main/worktree-catch-up.sh --effort "$F" --name race-sync --with v1
run sh $GW/main/worktree-drop.sh --effort "$F" --name race-sync
paused_finish
check "worktree-catch-up.sh, its tree dropped before the record: exit 2, no worktree.synced" is "$rc:$(has "$err" 'tree race-sync was dropped while worktree-catch-up.sh ran; no worktree.synced was written' && echo y):$(count_type "$F" worktree.synced)" "2:y:$N0"
N0=$(count_type "$F" worktree.discarded)
paused_start 'clean -f -d' 'status --porcelain=v1' sh $GW/main/worktree-discard.sh --effort "$F" --name race-discard
run sh $GW/main/worktree-drop.sh --effort "$F" --name race-discard
paused_finish
check "worktree-discard.sh, its tree dropped after the clear: exit 2, no worktree.discarded" is "$rc:$(has "$err" 'tree race-discard was dropped while worktree-discard.sh ran; no worktree.discarded was written' && echo y):$(count_type "$F" worktree.discarded)" "2:y:$N0"

echo
echo "=== the events lock held: a cut, a move and a drop refused with exit 6, no event"
hold_lock() { mkdir "$1/events/.lock"; echo $$ >"$1/events/.lock/pid"; }
REFS0=$(all_refs); N0=$(count_type "$F" worktree.cut)
hold_lock "$F"
run sh $GW/main/worktree-cut.sh --effort "$F" --repo "$S/repo" --name locked --from checkout
rm -rf "$F/events/.lock"
check "worktree-cut.sh: exit 6, no worktree.cut, no folder, no registration, the refs as before" is "$rc:$(has "$err" 'worktree.cut was not written' && echo y):$(count_type "$F" worktree.cut):$([ -e "$F/worktrees/locked" ] && echo there):$(git -C "$S/repo" worktree list --porcelain | grep -c '/locked$'):$(all_refs)" "6:y:$N0::0:$REFS0"
sh $GW/main/worktree-cut.sh --effort "$F" --repo "$S/repo" --name lock-move --from ref:v1 >/dev/null 2>&1
others() { all_refs | grep -v "/crucible/$FN/lock-move "; }
REFS0=$(others); N0=$(count_type "$F" worktree.moved); LOCK_TIP=$(tip lock-move)
hold_lock "$F"
run sh $GW/main/worktree-move.sh --effort "$F" --name lock-move --to main
rm -rf "$F/events/.lock"
check "worktree-move.sh: exit 6, the branch back at its old tip, no worktree.moved, no kept ref or other ref changed" is "$rc:$(tip lock-move):$(count_type "$F" worktree.moved):$(others)" "6:$LOCK_TIP:$N0:$REFS0"
sh $GW/main/worktree-drop.sh --effort "$F" --name lock-move >/dev/null 2>&1
sh $GW/main/worktree-cut.sh --effort "$F" --repo "$S/repo" --name lock-drop --from checkout >/dev/null 2>&1
tree_commit lock-drop d.txt 'unlanded' "$F" >/dev/null
DROP_TIP=$(tip lock-drop)
yes_gate "$F" drop-worktree "lock-drop:$DROP_TIP" 'Drop it (Recommended)'
DROP_YES=$(sh $GT/scripts/internal/gate-answer.sh --effort "$F" --record drop-worktree --subject "lock-drop:$DROP_TIP" | sed 's/^ACCEPTED: //')
N0=$(count_type "$F" worktree.dropped)
hold_lock "$F"
run sh $GW/main/worktree-drop.sh --effort "$F" --name lock-drop
rm -rf "$F/events/.lock"
check "worktree-drop.sh with its yes: exit 6, no worktree.dropped, the folder, registration and branch already gone" is "$rc:$(has "$err" 'the events lock stayed held' && echo y):$(count_type "$F" worktree.dropped):$([ -e "$F/worktrees/lock-drop" ] && echo folder):$(git -C "$S/repo" worktree list --porcelain | grep -c '/lock-drop$'):$(git -C "$S/repo" branch --list "crucible/$FN/lock-drop")" "6:y:$N0::0:"
check "  ... worktree-trees.sh still lists it" is "$(sh $GW/internal/worktree-trees.sh --effort "$F" --name lock-drop | jq -r '.[].name')" lock-drop
run sh $GW/main/worktree-drop.sh --effort "$F" --name lock-drop
check "the rerun, the lock free: exit 0, exactly one worktree.dropped for lock-drop, carrying the yes the first attempt read" is "$rc:$(sh $EV/internal/events-read.sh --effort "$F" --type worktree.dropped | jq -c '[.[] | select(.body.name == "lock-drop") | [.by, .body.answer == '"$DROP_YES"']]'):$(count_type "$F" worktree.dropped)" "0:[[\"worktree-drop.sh\",true]]:$((N0 + 1))"
check "  ... worktree-trees.sh no longer lists it" is "$(sh $GW/internal/worktree-trees.sh --effort "$F" --name lock-drop)" '[]'
run sh $GW/main/worktree-drop.sh --effort "$F" --name lock-drop
check "a second rerun: exit 2, the tree is no longer live, nothing written" is "$rc:$(has "$err" 'no live tree named lock-drop' && echo y):$(count_type "$F" worktree.dropped)" "2:y:$((N0 + 1))"
echo "--- lock-drop cut again with nothing of its own, its drop under the held lock: the used yes does not carry the rerun"
sh $GW/main/worktree-cut.sh --effort "$F" --repo "$S/repo" --name lock-drop --from checkout >/dev/null 2>&1
N0=$(count_type "$F" worktree.dropped)
hold_lock "$F"
run sh $GW/main/worktree-drop.sh --effort "$F" --name lock-drop
rm -rf "$F/events/.lock"
check "nothing unlanded, so no yes asked: exit 6, the folder and branch gone, no worktree.dropped" is "$rc:$([ -e "$F/worktrees/lock-drop" ] && echo folder):$(git -C "$S/repo" branch --list "crucible/$FN/lock-drop"):$(count_type "$F" worktree.dropped)" "6:::$N0"
run sh $GW/main/worktree-drop.sh --effort "$F" --name lock-drop
check "the rerun: exit 2, no unused yes given since this cut, nothing written" is "$rc:$(has "$err" 'no unused recorded yes since its cut' && echo y):$(count_type "$F" worktree.dropped)" "2:y:$N0"
yes_gate "$F" drop-worktree "lock-drop:none" 'Drop it (Recommended)'
NONE_YES=$(sh $GT/scripts/internal/gate-answer.sh --effort "$F" --record drop-worktree --subject "lock-drop:none" | sed 's/^ACCEPTED: //')
run sh $GW/main/worktree-drop.sh --effort "$F" --name lock-drop
check "with a yes for lock-drop:none: exit 0, worktree.dropped carries it" is "$rc:$(last_event "$F" worktree.dropped | jq -c '[.body.name, .body.answer == '"$NONE_YES"']')" '0:["lock-drop",true]'

echo
echo "=== open-work.sh and effort-close.sh"
run sh $GW/internal/open-work.sh --effort "$F"
check "one line per live tree: worktree <name> <path>" is "$(echo "$out" | head -n 1)" "worktree one $F/worktrees/one"
G=$(sh $K/crucible-effort/scripts/main/effort-start.sh --name closing)
run sh $GW/internal/open-work.sh --effort "$G"
check "an effort with no trees: nothing" is "$rc:$out" "0:"
sh $GW/main/worktree-cut.sh --effort "$G" --repo "$S/repo" --name only --from checkout >/dev/null 2>&1; echo worktree-cut.sh >>"$S/ran"
run sh $K/crucible-effort/scripts/main/effort-close.sh --effort "$G" --outcome done --words 'finished'
check "effort-close.sh refused while a tree is live, naming it" is "$rc:$(has "$err" 'worktree only' && echo y)" "2:y"
run sh $GW/main/worktree-drop.sh --effort "$G" --name only
run sh $K/crucible-effort/scripts/main/effort-close.sh --effort "$G" --outcome done --words 'finished'
check "allowed once the tree is dropped" is "$rc" 0
run sh $GW/main/worktree-cut.sh --effort "$G" --repo "$S/repo" --name late --from checkout
check "a closed effort: a cut is refused" is "$rc:$(has "$err" 'the effort is closed' && echo y)" "2:y"
for s in worktree-move.sh worktree-catch-up.sh worktree-discard.sh worktree-chain-sync.sh; do
	case $s in worktree-move.sh) run sh "$GW"/*/"$s" --effort "$G" --name only --to main ;; worktree-catch-up.sh) run sh "$GW"/*/"$s" --effort "$G" --name only --with main ;; *) run sh "$GW"/*/"$s" --effort "$G" --name only ;; esac
	check "a closed effort: $s is refused" is "$rc:$(has "$err" 'the effort is closed' && echo y)" "2:y"
done

echo
echo "=== the flow step"
run sh $K/crucible-dynamic-flow/scripts/main/flow-candidates.sh --stage setup
check "git-worktree/cut-worktree is listed under setup, ending with worktree.cut" has "$out" 'git-worktree/cut-worktree · .* · ends with worktree.cut · stages: setup · skills: git-worktree · propose when: whenever the coming work writes code'
H=$(sh $K/crucible-effort/scripts/main/effort-start.sh --name flowed)
echo '{"goal":"Two trees for the work","steps":[{"id":1,"step":"git-worktree/cut-worktree"},{"id":2,"step":"git-worktree/cut-worktree"}]}' >"$S/flow.json"
sh $K/crucible-dynamic-flow/scripts/main/flow-card.sh --file "$S/flow.json" >"$S/flow-card.md"
FSHA=$(shasum -a 256 "$S/flow.json" | cut -d ' ' -f 1)
sh $GT/scripts/main/show-card.sh --record flow-agree --effort "$H" --subject "$FSHA" --accept "Agree the flow (Recommended)" "$S/flow-card.md" >/dev/null
jq -cn --rawfile m "$S/flow-card.md" '{session_id: "sess-gw", last_assistant_message: $m}' | sh $GT/hooks/stop/require-card-shown.sh >/dev/null
jq -cn '{session_id: "sess-gw", tool_name: "AskUserQuestion", tool_use_id: "t-flow", tool_input: {questions: [{question: "Agree the flow?", header: "Flow", multiSelect: false, options: [{label: "Agree the flow (Recommended)", description: "yes"}, {label: "Change it", description: "no"}]}]}}' | sh $GT/hooks/pre-tool-use/hold-question-until-card-shown.sh >/dev/null
jq -cn '{session_id: "sess-gw", tool_name: "AskUserQuestion", tool_use_id: "t-flow", tool_response: {answers: {"Agree the flow?": "Agree the flow (Recommended)"}}}' | sh $GT/hooks/post-tool-use/record-gate-answer.sh
FLOW=$(sh $K/crucible-dynamic-flow/scripts/main/flow-agree.sh --effort "$H" --file "$S/flow.json")
run sh $GW/main/worktree-cut.sh --effort "$H" --repo "$S/repo" --name builder --from checkout
run sh $K/crucible-dynamic-flow/scripts/main/flow-step-done.sh --flow "$FLOW" --step 1
check "a step of two cut-worktree lines is ended by the first worktree.cut" is "$rc" 0
run sh $GW/main/worktree-cut.sh --effort "$H" --repo "$S/repo" --name other --from checkout
run sh $K/crucible-dynamic-flow/scripts/main/flow-step-done.sh --flow "$FLOW" --step 2
check "the second line by the second tree's worktree.cut" is "$rc" 0
run sh $K/crucible-dynamic-flow/scripts/main/flow-show.sh --flow "$FLOW" --all

echo
echo "=== the rules: writer, shape and used-once answer"
forge() { printf '%s' "$3" >"$S/forged.json"; run sh $EV/internal/event-write.sh --effort "$F" --type "$1" --by "$2" --body-file "$S/forged.json"; }
forge worktree.cut main.sh '{"name":"z","repo":"/r","path":"/e/worktrees/z","branch":"crucible/e/z","base":"0123456789abcdef0123456789abcdef01234567","from":"checkout"}'
check "worktree.cut by another writer: refused" is "$rc:$(has "$err" 'written only by worktree-cut.sh' && echo y)" "2:y"
forge worktree.cut worktree-cut.sh '{"name":"One!","repo":"r","path":"/e/x","branch":"main","base":"abc","from":"somewhere","extra":1}'
check "worktree.cut of the wrong shape: one reason per field, the name's included" is "$rc:$(for w in 'extra is not' 'name must be lowercase words joined by dashes' 'repo must' 'path must' 'branch must' 'base must' 'from must'; do has "$err" "$w" || echo miss; done)" "2:"
forge worktree.cut worktree-cut.sh '{"name":"z","repo":"/r","path":"/e/worktrees/z","branch":"crucible/e/z","base":"0123456789abcdef0123456789abcdef01234567","from":"checkout","signed":true}'
check "worktree.cut with signed when the cut made no base: refused" is "$rc:$(has "$err" 'signed belongs only to a cut that made its base' && echo y)" "2:y"
forge worktree.cut worktree-cut.sh '{"name":"z","repo":"/r","path":"/e/worktrees/z","branch":"crucible/e/z","base":"0123456789abcdef0123456789abcdef01234567","from":"snapshot"}'
check "worktree.cut from snapshot without signed: refused" is "$rc:$(has "$err" 'signed must be a boolean when the cut made its base' && echo y)" "2:y"
forge worktree.cut worktree-cut.sh '{"name":"z","repo":"/r","path":"/e/worktrees/z","branch":"crucible/e/z","base":"0123456789abcdef0123456789abcdef01234567","from":"worktree:a worktree:b","signed":"yes"}'
check "worktree.cut from several trees with signed not a boolean: refused" is "$rc:$(has "$err" 'signed must be a boolean when the cut made its base' && echo y)" "2:y"
forge worktree.dropped main.sh '{"name":"one"}'
check "worktree.dropped by another writer: refused" is "$rc:$(has "$err" 'written only by worktree-drop.sh' && echo y)" "2:y"
forge worktree.dropped worktree-drop.sh "{\"name\":\"one\",\"answer\":$YES}"
check "worktree.dropped reusing an answer: refused" is "$rc:$(has "$err" "answer $YES already dropped a tree" && echo y)" "2:y"
forge worktree.dropped worktree-drop.sh "{\"name\":\"one\",\"answer\":$DROP_YES}"
check "worktree.dropped reusing the answer a rerun carried: refused" is "$rc:$(has "$err" "answer $DROP_YES already dropped a tree" && echo y)" "2:y"
forge worktree.dropped worktree-drop.sh '{"name":5,"answer":"yes","x":1}'
check "worktree.dropped of the wrong shape: name not a string, answer not a seq, an unknown field" is "$rc:$(for w in 'x is not' "name must be a tree's name" 'answer must be the seq'; do has "$err" "$w" || echo miss; done)" "2:"
forge worktree.moved main.sh '{"name":"one","from":"0123456789abcdef0123456789abcdef01234567","to":"1123456789abcdef0123456789abcdef01234567"}'
check "worktree.moved by another writer: refused" is "$rc:$(has "$err" 'written only by worktree-move.sh' && echo y)" "2:y"
forge worktree.moved worktree-move.sh '{"name":"one","from":"0123456789abcdef0123456789abcdef01234567","to":"0123456789abcdef0123456789abcdef01234567","kept":"refs/crucible/moved/e/other/1"}'
check "worktree.moved of the wrong shape: from equal to, kept for another tree" is "$rc:$(for w in 'from and to' 'kept must'; do has "$err" "$w" || echo miss; done)" "2:"
forge worktree.synced main.sh '{"name":"one","with":"0123456789abcdef0123456789abcdef01234567","result":"in_sync"}'
check "worktree.synced by another writer: refused" is "$rc:$(has "$err" 'written only by worktree-catch-up.sh' && echo y)" "2:y"
forge worktree.synced worktree-catch-up.sh '{"name":"one","with":"x","result":"merged"}'
check "worktree.synced of the wrong shape: with not a sha, merged without commit and signed" is "$rc:$(for w in 'with must' 'a merged sync carries'; do has "$err" "$w" || echo miss; done)" "2:"
forge worktree.synced worktree-catch-up.sh '{"name":"one","with":"0123456789abcdef0123456789abcdef01234567","result":"conflict","commit":"0123456789abcdef0123456789abcdef01234567"}'
check "worktree.synced: only a merged sync carries a commit" is "$rc:$(has "$err" 'only a merged sync' && echo y)" "2:y"
forge worktree.discarded main.sh '{"name":"one","kept":"refs/crucible/discarded/e/one/1","signed":true}'
check "worktree.discarded by another writer: refused" is "$rc:$(has "$err" 'written only by worktree-discard.sh' && echo y)" "2:y"
forge worktree.discarded worktree-discard.sh '{"name":"one","kept":"refs/heads/x","signed":true}'
check "worktree.discarded of the wrong shape: kept not under refs/crucible/discarded/" is "$rc:$(has "$err" 'kept must' && echo y)" "2:y"
forge worktree.discarded worktree-discard.sh '{"name":"one","kept":"refs/crucible/discarded/e/one/1"}'
check "worktree.discarded without signed: refused" is "$rc:$(has "$err" 'signed must be a boolean' && echo y)" "2:y"
forge worktree.discarded worktree-discard.sh '{"name":"one","kept":"refs/crucible/discarded/e/one/1","signed":"no"}'
check "worktree.discarded with signed not a boolean: refused" is "$rc:$(has "$err" 'signed must be a boolean' && echo y)" "2:y"
# Liveness is the writing script's question, not the rule's: a write that
# claims the script as its writer passes for a name that was never cut.
# Core's guard on the writer is what stops main making one.
forge worktree.moved worktree-move.sh '{"name":"never-cut","from":"0123456789abcdef0123456789abcdef01234567","to":"1123456789abcdef0123456789abcdef01234567"}'
check "a well-formed worktree.moved by worktree-move.sh for a name never cut: accepted, the known limit" is "$rc:$(last_event "$F" worktree.moved | jq -r .body.name)" "0:never-cut"
check "  ... and worktree-trees.sh still lists no tree of that name" is "$(sh $GW/internal/worktree-trees.sh --effort "$F" --name never-cut)" "[]"

echo
echo "=== the scripts' contracts"
for p in "$GW"/main/*.sh "$GW"/internal/*.sh; do
	s=${p##*/}
	sh "$p" --help >"$S/help" 2>&1; h=$?
	sh "$p" --bogus >/dev/null 2>&1; b=$?
	echo "$s" >>"$S/ran"
	check "$s: --help exits 0, an unknown option exits 2" is "$h:$b" "0:2"
	case $s in
		setup-*.sh | worktree-busy.sh | worktree-changes.sh | worktree-kept.sh | worktree-trees.sh | worktree-uncommitted.sh)
			check "  ... and its --help is short: at most 25 lines of at most 80 characters" is "$([ "$(wc -l <"$S/help")" -le 25 ] && echo lines):$(awk 'length > 80' "$S/help" | wc -l | tr -d ' ')" "lines:0" ;;
		*) ;;
	esac
done
echo "--- the scripts that read the events, with core not beside them"
K2="$S/k2/skills"; mkdir -p "$K2"; ln -s "$(readlink "$K/git-worktree")" "$K2/git-worktree"
for s in worktree-trees.sh worktree-busy.sh worktree-kept.sh; do
	run sh "$K2/git-worktree/scripts/internal/$s" --effort "$F" --name one
	echo "$s" >>"$S/ran"
	check "$s with core not beside it: exit 2, install first" is "$rc:$(has "$err" "core isn't beside this skill" && echo y)" "2:y"
done
check "shellcheck -x -o all is clean" shellcheck -x -o all "$R"/domains/software-development/core/main-thread/git-worktree/scripts/main/*.sh "$R"/domains/software-development/core/main-thread/git-worktree/scripts/internal/*.sh "$R"/domains/software-development/core/main-thread/git-worktree/scripts/lib/*.sh

echo
echo "=== coverage: every script under scripts/ ran on a case"
for p in "$R"/domains/software-development/core/main-thread/git-worktree/scripts/main/*.sh "$R"/domains/software-development/core/main-thread/git-worktree/scripts/internal/*.sh; do
	s=${p##*/}
	cases=$(grep -cx -- "$s" "$S/ran")
	# Each script also ran once for its contract; a case needs one more.
	check "$s ran on a case ($((cases - 1)) runs)" test "$cases" -gt 1
done

echo
echo "=== $pass PASS, $fail FAIL"
[ "$fail" -eq 0 ]
