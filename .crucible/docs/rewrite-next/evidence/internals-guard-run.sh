# Evidence run for deny-sealed-reads.sh, the read guard's step that denies
# main and agents a path into a component's sealed folders from another
# project. The step runs through its installed link (a scratch skills
# folder), fed real hook JSON for Read, Grep, Glob and Bash. Scratch HOME,
# XDG and git config only.
R=/Users/cordona/IdeaProjects/cordona/claude-code-crucible/new-rewrite
ROOT=${R%/*}
S=/private/tmp/claude-501/-Users-cordona-IdeaProjects-cordona-claude-code-crucible/480d0359-cf0d-4c14-a59e-2a72be5dba4f/scratchpad/internals-guard; rm -rf "$S"; mkdir -p "$S/home" "$S/xdg" "$S/cfg/skills" "$S/bin"
export HOME="$S/home" XDG_CONFIG_HOME="$S/xdg" GIT_CONFIG_GLOBAL="$S/home/.gitconfig" GIT_CONFIG_NOSYSTEM=1
export CRUCIBLE_HOME="$S/space" CLAUDE_CONFIG_DIR="$S/cfg" CLAUDE_CODE_SESSION_ID=sess-ig
cd /
K="$S/cfg/skills"
for d in "$R"/framework/core/main-thread/*/ "$R"/domains/software-development/core/main-thread/*/ "$R"/domains/software-development/core/agents/*/; do d=${d%/}; ln -s "$d" "$K/${d##*/}"; done
HOOK=$K/crucible-events/hooks/pre-tool-use/steps/deny-sealed-reads.sh
C=$R/framework/core/main-thread
INTERNAL=$C/crucible-gate/scripts/internal/gate-answer.sh
LIB=$C/crucible-events/scripts/lib/lock.sh
HOOKS=$C/crucible-gate/hooks/stop/require-card-shown.sh
EVENTS=$(ls "$C"/crucible-effort/events/* | head -n 1)
MAIN=$(ls "$C"/crucible-effort/scripts/main/*.sh | head -n 1)
SKILL=$C/crucible-effort/SKILL.md

# A scratch project: a lookalike tree with the same folder names, a file link
# and a folder link into the framework.
P="$S/project"
mkdir -p "$P/scripts/internal" "$P/scripts/lib" "$P/hooks/pre-tool-use" "$P/events"
for f in scripts/internal/a.sh scripts/lib/b.sh hooks/pre-tool-use/c.sh events/d.jq; do echo 'echo lookalike' >"$P/$f"; done
ln -s "$INTERNAL" "$P/peek.sh"
ln -s "$R" "$P/fw"

pass=0 fail=0
show() { sed "s|$K/|<skills>/|g;s|$R|<R>|g;s|$ROOT|<ROOT>|g;s|$S|<S>|g"; }
# feed JSON: runs the hook on JSON, keeping stdout in $out, stderr in $err and the exit in $rc.
feed() {
	printf '%s' "$1" | sh "$HOOK" >"$S/out" 2>"$S/err"; rc=$?
	out=$(cat "$S/out"); err=$(cat "$S/err")
}
# call TOOL CWD INPUT_JSON [AGENT_ID]: one hook call, shown.
call() {
	json=$(jq -cn --arg t "$1" --arg c "$2" --argjson i "$3" --arg a "${4-}" \
		'{session_id: "sess-ig", hook_event_name: "PreToolUse", tool_name: $t, cwd: $c, tool_input: $i} + (if $a == "" then {} else {agent_id: $a, agent_type: "general-purpose"} end)')
	echo "  \$ $(echo "$json" | show)"
	feed "$json"
	shown
}
shown() {
	[ -z "$out" ] || echo "    out: $(echo "$out" | jq -c '.hookSpecificOutput | {permissionDecision, permissionDecisionReason}' 2>/dev/null | show)"
	[ -z "$err" ] || echo "$err" | show | sed 's/^/    err: /'
	echo "    [exit $rc]"
}
check() {
	what=$1; shift
	if "$@" >/dev/null 2>&1; then pass=$((pass + 1)); echo "  PASS: $what"
	else fail=$((fail + 1)); echo "  FAIL: $what"; fi
}
denied() { [ "$rc" = 0 ] && [ "$(echo "$out" | jq -r '.hookSpecificOutput.permissionDecision')" = deny ]; }
allowed() { [ "$rc" = 0 ] && [ -z "$out" ]; }
path() { jq -cn --arg k "$1" --arg v "$2" '{($k): $v}'; }
bash_cmd() { jq -cn --arg c "$1" '{command: $c, description: "look"}'; }

echo "=== help"
sh "$HOOK" --help >"$S/out"; rc=$?
check "--help exits 0 and prints its usage" [ "$rc" = 0 -a -s "$S/out" ]
check "--help says it stops a mistake, not a command built to get round it" grep -q "it is not a wall against a" "$S/out"
sh "$HOOK" -h >"$S/out"; rc=$?
check "-h exits 0 and prints its usage" [ "$rc" = 0 -a -s "$S/out" ]

echo "=== each tool on an internal path, from a scratch project: denied"
call Read "$P" "$(path file_path "$INTERNAL")"
check "Read of scripts/internal/ denied" denied
check "the deny reason names scripts/main/ and --help" sh -c 'echo "$1" | grep -q "scripts/main/ and each script.s --help"' _ "$out"
call Grep "$P" "$(jq -cn --arg p "$C/crucible-events/scripts/lib" '{pattern: "ls_", path: $p}')"
check "Grep in scripts/lib/ denied" denied
call Glob "$P" "$(jq -cn --arg p "$C/crucible-gate/hooks" '{pattern: "**/*.sh", path: $p}')"
check "Glob with path hooks/ denied" denied
call Glob "$P" "$(path pattern "$C/crucible-effort/events/*.jq")"
check "Glob with an absolute pattern into events/ denied" denied
call Bash "$P" "$(bash_cmd "cat '$C/crucible-effort/events/'*.jq | head -n 3")"
check "Bash naming events/ denied" denied

echo "=== each folder kind, by Read"
call Read "$P" "$(path file_path "$LIB")"
check "scripts/lib/ denied" denied
call Read "$P" "$(path file_path "$HOOKS")"
check "hooks/ denied" denied
call Read "$P" "$(path file_path "$EVENTS")"
check "events/ denied" denied
call Read "$P" "$(path file_path "$C/crucible-gate/scripts/internal")"
check "the scripts/internal folder itself denied" denied

echo "=== through the installed skill links"
call Read "$P" "$(path file_path "$K/crucible-gate/scripts/internal/gate-answer.sh")"
check "Read of an internal script through its skill link denied" denied
call Bash "$P" "$(bash_cmd "sed -n 1,20p \"$K/crucible-events/scripts/lib/lock.sh\"")"
check "Bash reading a lib through its skill link denied" denied
mkdir -p "$S/home/.claude"; ln -s "$K" "$S/home/.claude/skills"
call Bash "$P" "$(bash_cmd 'cat ~/.claude/skills/crucible-gate/hooks/stop/require-card-shown.sh')"
check "Bash with ~ through the skill links denied" denied
call Bash "$P" "$(bash_cmd 'head "$HOME/.claude/skills/crucible-gate/scripts/internal/gate-answer.sh"')"
check "Bash with \$HOME through the skill links denied" denied
call Bash "$P" "$(bash_cmd "FILE=$INTERNAL; less \"\$FILE\"")"
check "Bash with an internal path behind NAME= denied" denied
call Bash "$P" "$(bash_cmd "sh '$INTERNAL' --help")"
check "Bash running an internal script directly denied" denied

echo "=== scripts/main/ and SKILL.md: allowed"
call Read "$P" "$(path file_path "$MAIN")"
check "Read of scripts/main/ allowed" allowed
call Read "$P" "$(path file_path "$SKILL")"
check "Read of SKILL.md allowed" allowed
call Bash "$P" "$(bash_cmd "sh '$MAIN' --help")"
check "Bash running a scripts/main/ help allowed" allowed
call Glob "$P" "$(jq -cn --arg p "$C/crucible-effort/scripts/main" '{pattern: "*.sh", path: $p}')"
check "Glob in scripts/main/ allowed" allowed
call Read "$P" "$(path file_path "$C/crucible-effort/flow-step.json")"
check "Read of a component's flow-step.json allowed" allowed

echo "=== a lookalike tree in the scratch project: allowed"
call Read "$P" "$(path file_path "$P/scripts/internal/a.sh")"
check "lookalike scripts/internal/ allowed" allowed
call Grep "$P" "$(path path "$P/scripts/lib")"
check "lookalike scripts/lib/ allowed" allowed
call Glob "$P" "$(path pattern "$P/hooks/**/*.sh")"
check "lookalike hooks/ allowed" allowed
call Bash "$P" "$(bash_cmd 'cat events/d.jq scripts/internal/a.sh')"
check "lookalike events/ and scripts/internal/, relative, allowed" allowed

echo "=== links in the scratch project that resolve into the internals: denied"
call Read "$P" "$(path file_path "$P/peek.sh")"
check "a file link to an internal script denied" denied
call Read "$P" "$(path file_path "$P/fw/framework/core/main-thread/crucible-events/hooks/pre-tool-use/deny-direct-event-write.sh")"
check "a path through a folder link denied" denied
call Grep "$P" "$(path path "fw/framework/core/main-thread/crucible-gate/scripts/lib")"
check "a relative path through a folder link, from the cwd, denied" denied
call Bash "$P" "$(bash_cmd 'cat fw/framework/core/main-thread/crucible-events/scripts/internal/*.sh')"
check "Bash with a relative glob through a folder link denied" denied

echo "=== stand-aside: a session in the framework's repository"
call Read "$ROOT" "$(path file_path "$INTERNAL")"
check "cwd at the repository root: allowed" allowed
call Bash "$ROOT" "$(bash_cmd "cat '$LIB'")"
check "cwd at the repository root, Bash: allowed" allowed
call Read "$C/crucible-gate/scripts" "$(path file_path "$INTERNAL")"
check "cwd deep inside new-rewrite: allowed" allowed
call Read "$ROOT/.crucible/docs" "$(path file_path "$HOOKS")"
check "cwd elsewhere in the repository: allowed" allowed
call Read "$P/fw" "$(path file_path "$INTERNAL")"
check "cwd a link into the repository: allowed" allowed
call Read "$S" "$(path file_path "$INTERNAL")"
check "cwd in a scratch folder: denied" denied

echo "=== the sealed folders: main and agents alike, and scripts/main/ for agents"
AG=a6f3079fde04546c5
A=$R/domains/software-development/core/agents
SUBMISSIONS=$K/code-builder/submissions/build.json
call Read "$P" "$(path file_path "$SUBMISSIONS")"
check "main: submissions/ denied" denied
for sealed in "$INTERNAL" "$LIB" "$HOOKS" "$EVENTS" "$SUBMISSIONS" "$MAIN"; do
	call Read "$P" "$(path file_path "$sealed")" "$AG"
	check "an agent: ${sealed#"$R"/} denied" denied
done
call Bash "$P" "$(bash_cmd "cat '$LIB'")" "$AG"
check "an agent's Bash naming a lib denied" denied
call Glob "$P" "$(jq -cn --arg p "$C/crucible-effort/scripts/main" '{pattern: "*.sh", path: $p}')" "$AG"
check "an agent's Glob in scripts/main/ denied" denied
check "an agent's deny says it needs no framework script" sh -c 'echo "$1" | grep -q "an agent works in its tree and writes its report"' _ "$out"
call Read "$P" "$(path file_path "$R/domains/software-development/core/agents/plugins/tech/languages/shell/references/build.md")" "$AG"
check "an agent reads a plugin's references/" allowed
call Read "$P" "$(path file_path "$R/domains/software-development/core/agents/plugins/standards/security/SKILL.md")" "$AG"
check "an agent reads a plugin's SKILL.md" allowed
call Read "$P" "$(path file_path "$K/code-builder/code-builder.md")" "$AG"
check "an agent reads an agent definition" allowed
call Read "$P" "$(path file_path "$K/agent-conduct/SKILL.md")" "$AG"
check "an agent reads a component's SKILL.md" allowed
call Read "$ROOT" "$(path file_path "$MAIN")" "$AG"
check "an agent of a session in the framework's repository: allowed" allowed
call Glob "$P" "$(jq -cn --arg p "$C/crucible-effort/scripts/main" '{pattern: "*.sh", path: $p}')"
check "main still globs scripts/main/" allowed

echo "=== other tools pass"
call Write "$P" "$(jq -cn --arg p "$INTERNAL" '{file_path: $p, content: "x"}')"
check "another tool allowed" allowed
call Read "" "$(path file_path "$INTERNAL")"
check "no cwd: still denied" denied

echo "=== faults allow the call"
for bad in 'not json' '[1, 2]' '"a string"' ''; do
	echo "  \$ input: '$bad'"; feed "$bad"; shown
	check "malformed input '$bad' allowed" allowed
done
for b in sh cat dirname sed; do ln -sf "$(command -v $b)" "$S/bin/$b"; done
json=$(jq -cn --arg p "$INTERNAL" --arg c "$P" '{tool_name: "Read", cwd: $c, tool_input: {file_path: $p}}')
echo "  \$ jq missing"; printf '%s' "$json" | PATH="$S/bin" sh "$HOOK" >"$S/out" 2>"$S/err"; rc=$?; out=$(cat "$S/out"); err=$(cat "$S/err"); shown
check "jq missing: allowed, a note on stderr" sh -c '[ "$1" = 0 ] && [ -z "$2" ] && [ -n "$3" ]' _ "$rc" "$out" "$err"
ln -sf "$(command -v jq)" "$S/bin/jq"
echo "  \$ realpath missing"; printf '%s' "$json" | PATH="$S/bin" sh "$HOOK" >"$S/out" 2>"$S/err"; rc=$?; out=$(cat "$S/out"); err=$(cat "$S/err"); shown
check "realpath missing: allowed, a note on stderr" sh -c '[ "$1" = 0 ] && [ -z "$2" ] && [ -n "$3" ]' _ "$rc" "$out" "$err"

echo "=== the install expects it"
sh "$R/framework/core/install/install-entries.sh" --json >"$S/needs.json"
check "install-entries lists its wrapper, guard-framework.sh, on Read|Grep|Glob|Bash" jq -e '.hooks | any(.event == "PreToolUse" and .matcher == "Read|Grep|Glob|Bash" and (.path | endswith("/guard-framework.sh")))' "$S/needs.json"
sh "$R/framework/core/install/install-entries.sh" | sed -n '/^# Settings/,/^$/p' | sed '1d' >"$S/settings.json"
jq '.hooks.PreToolUse |= map(select(.matcher != "Read|Grep|Glob|Bash"))' "$S/settings.json" >"$S/without.json"
mkdir -p "$S/check" && cd "$S/check" || exit 1
sh "$R/framework/core/install/install-check.sh" --settings "$S/without.json" >"$S/out"; rc=$?
sed 's/^/    /' "$S/out" | show | grep internals
check "install-check names it missing when its entry is left out" sh -c '[ "$1" = 1 ] && grep -q "missing: PreToolUse hook \[Read|Grep|Glob|Bash\] .*guard-framework.sh" "$2"' _ "$rc" "$S/out"
cd /

echo
echo "=== $pass PASS, $fail FAIL"
[ "$fail" = 0 ]
