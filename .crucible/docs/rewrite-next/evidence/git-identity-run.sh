# Evidence run for git-identity and the gate's recorded choice: every case
# through the installed layout (a scratch skills folder of links) and the
# real hooks, from /. Only scratch keys: its own HOME, GnuPG home, ssh agent
# and git config, so the owner's agent, key ring and ~/.ssh are never read.
R=/Users/cordona/IdeaProjects/cordona/claude-code-crucible/new-rewrite
S=/private/tmp/claude-501/-Users-cordona-IdeaProjects-cordona-claude-code-crucible/480d0359-cf0d-4c14-a59e-2a72be5dba4f/scratchpad/gid; rm -rf "$S"; mkdir -p "$S/home/.ssh" "$S/xdg" "$S/cfg/skills"
# The agents' sockets need a short path (a Unix socket path holds about 100
# bytes), so the GnuPG home and the ssh agent's socket sit in a short scratch
# folder of their own, removed at the end.
T=$(mktemp -d /tmp/gid.XXXXXX); mkdir -p "$T/gnupg"; chmod 700 "$T/gnupg" "$S/home/.ssh"
# Stops this run's agents and removes the short folder, also when the run is
# cut short. The ssh agent is stopped by its own PID only.
cleanup() { [ -z "${SSH_AGENT_PID-}" ] || kill "$SSH_AGENT_PID" 2>/dev/null; gpgconf --kill all 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
export HOME="$S/home" GNUPGHOME="$T/gnupg" XDG_CONFIG_HOME="$S/xdg" GIT_CONFIG_NOSYSTEM=1
export CRUCIBLE_HOME="$S/space" CLAUDE_CONFIG_DIR="$S/cfg" CLAUDE_CODE_SESSION_ID=sess-gid
unset SSH_AUTH_SOCK SSH_AGENT_PID
cd /
K="$S/cfg/skills"
for d in "$R"/framework/core/main-thread/*/ "$R"/domains/software-development/core/main-thread/*/; do d=${d%/}; ln -s "$d" "$K/${d##*/}"; done
GI=$K/git-identity/scripts; GT=$K/crucible-gate
show() { sed "s|$S|<S>|g;s|$T|<T>|g;s|[0-9]\{8\}T[0-9]\{6\}-[0-9a-f]\{4\}|<id>|g;s|[0-9A-F]\{40\}|<FPR>|g;s|SHA256:[A-Za-z0-9+/]\{43\}|SHA256:<fp>|g;s|[0-9A-F]\{16\}|<KEYID>|g;s|AAAA[A-Za-z0-9+/=]\{20,\}|<b64>|g"; }
run() { echo "\$ $(echo "$*" | sed "s|$GI/||g;s|$K/||g" | show)"; out=$("$@" 2>&1); e=$?; echo "$out" | show | sed 's/^/    /'; echo "    [exit $e]"; }
# One recorded choice gate through the real hooks: card, stop, question, answer.
pick() { # $1 effort, $2 subject, $3 card file, $4 question JSON file, $5 the human's answer
	t="pick-$(date +%s%N)"
	sh $GT/scripts/main/show-card.sh --record set-identity --effort "$1" --subject "$2" --choice "$3" >/dev/null
	jq -cn --rawfile m "$3" --arg s sess-gid '{session_id: $s, last_assistant_message: $m}' | sh $GT/hooks/stop/require-card-shown.sh >/dev/null
	jq -c --arg s sess-gid --arg t "$t" '{session_id: $s, tool_name: "AskUserQuestion", tool_use_id: $t, tool_input: .}' "$4" \
		| sh $GT/hooks/pre-tool-use/hold-question-until-card-shown.sh | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' | sed 's/^/    hook: /'
	q=$(jq -r '.questions[0].question' "$4")
	jq -cn --arg s sess-gid --arg t "$t" --arg q "$q" --arg a "$5" '{session_id: $s, tool_name: "AskUserQuestion", tool_use_id: $t, tool_response: {answers: {($q): $a}}}' \
		| sh $GT/hooks/post-tool-use/record-gate-answer.sh
}

echo "=== scratch keys: one GPG key, two SSH keys (one in the agent, one only as .pub)"
gpg --batch --pinentry-mode loopback --passphrase '' --quick-gen-key 'Gpg Tester <gpg@example.test>' ed25519 sign never 2>/dev/null
GPGID=$(gpg --list-secret-keys --with-colons | awk -F: '$1 == "sec" {print $5; exit}')
ssh-keygen -q -t ed25519 -N '' -C ssh@example.test -f "$HOME/.ssh/agent_key"
ssh-keygen -q -t ed25519 -N '' -C lonely@example.test -f "$HOME/.ssh/lonely_key"; rm "$HOME/.ssh/lonely_key"
eval "$(ssh-agent -s -a "$T/agent.sock")" >/dev/null; ssh-add -q "$HOME/.ssh/agent_key" 2>/dev/null; rm "$HOME/.ssh/agent_key"
printf 'ssh@example.test %s\nlonely@example.test %s\n' "$(cut -d ' ' -f 1,2 "$HOME/.ssh/agent_key.pub")" "$(cut -d ' ' -f 1,2 "$HOME/.ssh/lonely_key.pub")" > "$HOME/.ssh/allowed_signers"
git config --global user.name 'Ssh Tester'
git config --global gpg.ssh.allowedSignersFile "$HOME/.ssh/allowed_signers"

echo "=== the list: the GPG id and the agent's SSH key; the .pub with no private key is left out"
run sh $GI/main/identity-list.sh
sh $GI/main/identity-list.sh > "$S/list.json" 2>/dev/null
echo "--- the same from any folder (global git config only)"
( cd "$S" && sh $GI/main/identity-list.sh 2>/dev/null | cmp -s - "$S/list.json" && echo "    same list" || echo "    DIFFERENT" )

echo "=== the repository: a checkout and a worktree are one repository"
git init -q "$S/repo"; git -C "$S/repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m one
git -C "$S/repo" worktree add -q "$S/wt" -b wt 2>/dev/null
F=$(sh $K/crucible-effort/scripts/main/effort-start.sh --name identity)

echo "=== the card: only identities that can sign here are offered; the rest named with why"
run sh $GI/main/identity-card.sh --list "$S/list.json" --repo "$S/repo"
echo "--- the card from the worktree names the checkout's repository"
run sh $GI/main/identity-card.sh --list "$S/list.json" --repo "$S/wt"
run sh $GI/main/identity-card.sh --list "$S/list.json" --repo "$S/repo" --question
sh $GI/main/identity-card.sh --list "$S/list.json" --repo "$S/repo" > "$S/card.md"
sh $GI/main/identity-card.sh --list "$S/list.json" --repo "$S/repo" --question > "$S/q.json"
REPO=$(cd "$S/repo" && pwd -P)
SUB="$REPO:$(shasum -a 256 "$S/list.json" | cut -d ' ' -f 1)"

echo "=== the gate's recorded choice"
echo "--- show-card refuses --accept with --choice"
run sh $GT/scripts/main/show-card.sh --record set-identity --effort "$F" --subject x --choice --accept y "$S/card.md"
echo "--- two questions are refused; each pick below goes out with no recommended option (no hook line means allowed)"
jq '.questions += .questions' "$S/q.json" > "$S/q2.json"
sh $GT/scripts/main/show-card.sh --record set-identity --effort "$F" --subject "$SUB" --choice "$S/card.md" >/dev/null
jq -cn --rawfile m "$S/card.md" '{session_id: "sess-gid", last_assistant_message: $m}' | sh $GT/hooks/stop/require-card-shown.sh >/dev/null
jq -c '{session_id: "sess-gid", tool_name: "AskUserQuestion", tool_use_id: "t-two", tool_input: .}' "$S/q2.json" | sh $GT/hooks/pre-tool-use/hold-question-until-card-shown.sh | jq -r '.hookSpecificOutput.permissionDecisionReason' | sed 's/^/    /'
echo "--- with no answer yet: identity-set refuses"
run sh $GI/main/identity-set.sh --effort "$F" --repo "$S/repo" --list "$S/list.json"
echo "--- a typed answer is recorded, and refused by identity-set"
pick "$F" "$SUB" "$S/card.md" "$S/q.json" "Me, with my laptop key"
run sh $K/crucible-gate/scripts/internal/gate-answer.sh --effort "$F" --record set-identity --subject "$SUB" --choice
run sh $K/crucible-gate/scripts/internal/gate-answer.sh --effort "$F" --record set-identity --subject "$SUB"
run sh $GI/main/identity-set.sh --effort "$F" --repo "$S/repo" --list "$S/list.json"
echo "--- a pick of the SSH identity sets it"
SSHLABEL=$(jq -r '[.[] | select(.signing.format == "ssh")][0].label' "$S/list.json")
pick "$F" "$SUB" "$S/card.md" "$S/q.json" "$SSHLABEL"
run sh $GI/main/identity-set.sh --effort "$F" --repo "$S/repo" --list "$S/list.json"
jq -c '.body' "$(ls "$F"/events/*identity.set.json | tail -1)" | show | sed 's/^/    body: /'
echo "--- the same pick can't set twice"
run sh $GI/main/identity-set.sh --effort "$F" --repo "$S/repo" --list "$S/list.json"
echo "--- identity-get from the checkout and from the worktree"
run sh $GI/main/identity-get.sh --effort "$F" --repo "$S/repo"
run sh $GI/main/identity-get.sh --effort "$F" --repo "$S/wt"
echo "--- a second pick, the GPG identity, replaces the first"
GPGLABEL=$(jq -r '[.[] | select(.signing.format == "openpgp")][0].label' "$S/list.json")
pick "$F" "$SUB" "$S/card.md" "$S/q.json" "$GPGLABEL"
run sh $GI/main/identity-set.sh --effort "$F" --repo "$S/wt" --list "$S/list.json"
run sh $GI/main/identity-get.sh --effort "$F" --repo "$S/repo"
echo "--- an unknown repository: exit 5"
git init -q "$S/other"
run sh $GI/main/identity-get.sh --effort "$F" --repo "$S/other"

echo "=== the list changed since the card: refused"
ssh-keygen -q -t ed25519 -N '' -C new@example.test -f "$HOME/.ssh/new_key"
printf 'new@example.test %s\n' "$(cut -d ' ' -f 1,2 "$HOME/.ssh/new_key.pub")" >> "$HOME/.ssh/allowed_signers"
run sh $GI/main/identity-set.sh --effort "$F" --repo "$S/repo" --list "$S/list.json"
rm "$HOME/.ssh/new_key" "$HOME/.ssh/new_key.pub"; sed -i '' '/new@example.test/d' "$HOME/.ssh/allowed_signers"

echo "=== a key that can't sign here is no option, and identity-check says why"
run sh $GI/internal/identity-check.sh --repo "$S/repo" --name 'Ssh Tester' --email ssh@example.test --format ssh --key "$HOME/.ssh/lonely_key.pub"
run sh $GI/internal/identity-check.sh --repo "$S/repo" --name 'Gpg Tester' --email nobody@example.test --format openpgp --key "$GPGID"
git -C "$S/other" config gpg.ssh.allowedSignersFile "$S/missing"
run sh $GI/main/identity-card.sh --list "$S/list.json" --repo "$S/other"

echo "=== one usable identity: the question adds None of these"
jq '[.[] | select(.signing.format == "openpgp")]' "$S/list.json" > "$S/one.json"
run sh $GI/main/identity-card.sh --list "$S/one.json" --repo "$S/repo" --question
echo "=== no usable identity: exit 3"
echo '[]' > "$S/none.json"
run sh $GI/main/identity-card.sh --list "$S/none.json" --repo "$S/repo"

echo "=== the rule checks the writer and the shape; that the answer is a recorded pick is identity-set.sh's check (a direct writer call is what core's Bash guard blocks)"
echo '{"repo":"/r","name":"n","email":"e@x","signing":{"format":"ssh","key":"k"},"fingerprint":"","answer":1}' > "$S/forged.json"
run sh $K/crucible-events/scripts/internal/event-write.sh --effort "$F" --type identity.set --by main.sh --body-file "$S/forged.json"
run sh $K/crucible-events/scripts/internal/event-write.sh --effort "$F" --type identity.set --by identity-set.sh --body-file "$S/forged.json"

echo "=== the step catalogue lists the domain's step"
run sh $K/crucible-dynamic-flow/scripts/main/flow-candidates.sh --stages
run sh $K/crucible-dynamic-flow/scripts/main/flow-candidates.sh --stage setup

echo "=== a flow holding the identity step, ended by identity.set"
G=$(sh $K/crucible-effort/scripts/main/effort-start.sh --name flowed)
echo '{"goal":"Sign the commits of this effort","steps":[{"id":1,"step":"git-identity/set-identity"}]}' > "$S/flow.json"
sh $K/crucible-dynamic-flow/scripts/main/flow-card.sh --file "$S/flow.json" > "$S/flow-card.md"
FSHA=$(shasum -a 256 "$S/flow.json" | cut -d ' ' -f 1)
sh $GT/scripts/main/show-card.sh --record flow-agree --effort "$G" --subject "$FSHA" --accept "Agree the flow (Recommended)" "$S/flow-card.md" >/dev/null
jq -cn --rawfile m "$S/flow-card.md" '{session_id: "sess-gid", last_assistant_message: $m}' | sh $GT/hooks/stop/require-card-shown.sh >/dev/null
jq -cn '{session_id: "sess-gid", tool_name: "AskUserQuestion", tool_use_id: "t-flow", tool_input: {questions: [{question: "Agree the flow?", header: "Flow", multiSelect: false, options: [{label: "Agree the flow (Recommended)", description: "yes"}, {label: "Change it", description: "no"}]}]}}' | sh $GT/hooks/pre-tool-use/hold-question-until-card-shown.sh >/dev/null
jq -cn '{session_id: "sess-gid", tool_name: "AskUserQuestion", tool_use_id: "t-flow", tool_response: {answers: {"Agree the flow?": "Agree the flow (Recommended)"}}}' | sh $GT/hooks/post-tool-use/record-gate-answer.sh
FLOW=$(sh $K/crucible-dynamic-flow/scripts/main/flow-agree.sh --effort "$G" --file "$S/flow.json")
pick "$G" "$SUB" "$S/card.md" "$S/q.json" "$SSHLABEL"
sh $GI/main/identity-set.sh --effort "$G" --repo "$S/repo" --list "$S/list.json" >/dev/null
run sh $K/crucible-dynamic-flow/scripts/main/flow-step-done.sh --flow "$FLOW" --step 1
run sh $K/crucible-dynamic-flow/scripts/main/flow-show.sh --flow "$FLOW" --all

echo "=== the event log"
sh $K/crucible-events/scripts/internal/events-read.sh --effort "$F" | jq -r '.[] | "    \(.seq) \(.type) by \(.by)\(if .type == "gate.answered" then ": \(.body.answer)" else "" end)"' | show


echo "=== a damaged log: identity-get and identity-set refuse, never \"no identity\" or \"not picked\""
SET=$(ls "$F"/events/*-identity.set.json | tail -n 1); chmod 000 "$SET"
run sh $GI/main/identity-get.sh --effort "$F" --repo "$S/repo"
chmod 444 "$SET"
ANS=$(ls "$F"/events/*-gate.answered.json | tail -n 1); chmod 000 "$ANS"
n=$(ls "$F"/events | wc -l)
run sh $GI/main/identity-set.sh --effort "$F" --repo "$S/repo" --list "$S/list.json"
[ "$(ls "$F"/events | wc -l)" = "$n" ] && echo "    no event written"
chmod 444 "$ANS"
echo "--- repaired"
run sh $GI/main/identity-get.sh --effort "$F" --repo "$S/repo"

echo "=== the events lock held: identity-set refuses with exit 6, nothing written; the rerun sets"
H=$(sh $K/crucible-effort/scripts/main/effort-start.sh --name locked)
pick "$H" "$SUB" "$S/card.md" "$S/q.json" "$SSHLABEL"
n=$(ls "$H"/events | wc -l | tr -d ' '); mkdir "$H/events/.lock"; echo $$ >"$H/events/.lock/pid"
run sh $GI/main/identity-set.sh --effort "$H" --repo "$S/repo" --list "$S/list.json"
rm -rf "$H/events/.lock"; echo "    events before $n, after $(ls "$H"/events | wc -l | tr -d ' ')"
run sh $GI/main/identity-get.sh --effort "$H" --repo "$S/repo"
run sh $GI/main/identity-set.sh --effort "$H" --repo "$S/repo" --list "$S/list.json"
