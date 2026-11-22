# Evidence run for the completeness review's fixes: B1 read-only events,
# B2 effort-close and open work, C1 the event-writer guard, A2 the install.
R=/Users/cordona/IdeaProjects/cordona/claude-code-crucible/new-rewrite
C=$R/framework/core/main-thread; E=$C/crucible-effort/scripts; FL=$C/crucible-dynamic-flow/scripts; G=$C/crucible-grill/scripts
HOOK=$C/crucible-events/hooks/pre-tool-use/deny-direct-event-write.sh; I=$R/framework/core/install
. /Users/cordona/IdeaProjects/cordona/claude-code-crucible/.crucible/docs/rewrite-next/evidence/lib-decide.sh
S="/private/tmp/claude-501/-Users-cordona-IdeaProjects-cordona-claude-code-crucible/480d0359-cf0d-4c14-a59e-2a72be5dba4f/scratchpad/fixes test"; rm -rf "$S"; mkdir -p "$S/cfg" "$S/bin"
export CRUCIBLE_HOME="$S/space" CLAUDE_CONFIG_DIR="$S/cfg" CLAUDE_CODE_SESSION_ID=sess-x
cd /
show() { echo "$1" | sed "s|$S/main-thread-copy/|<copy>/|g;s|$C/||g;s|$I/||g;s|$R|<R>|g;s|$S|<S>|g;s|[0-9]\{8\}T[0-9]\{6\}-[0-9a-f]\{4\}|<id>|g;s|20[0-9-]*T[0-9:.]*Z|<at>|g"; }
run() { show "\$ $*"; out=$("$@" 2>&1); e=$?; show "$out" | sed 's|^|    |'; echo "    [exit $e]"; }
agree() { # $1 effort, $2 flow file: agreed through a recorded gate, the real hooks
	sha=$(shasum -a 256 "$2" | cut -d ' ' -f 1); sh $FL/flow-card.sh --file "$2" >"$S/card.md"
	decide "$1" flow-agree "$sha" "$S/card.md" "Approve (Recommended)" | tail -n 1 >/dev/null
	sh $FL/flow-agree.sh --effort "$1" --file "$2"
}
printf '{"goal":"Prune nightly","done_when":{"criteria":"the human says it works","by":"human"},"steps":[{"id":1,"do":"Write the job","done_when":{"criteria":"the job exists"}}]}\n' >"$S/flow.json"

echo "=== B1: events are read-only"
F=$(sh $E/effort-start.sh --name fixes); show "    started: $F"
for e in "$F"/events/*.json; do echo "    $(ls -l "$e" | cut -c1-10) ${e##*/}"; done
run sh $E/effort-pause.sh --effort "$F" --words 'the next event, after a read-only one'
run sh $E/effort-resume.sh --effort "$F" --words 'back'
for e in "$F"/events/*.json; do echo "    $(ls -l "$e" | cut -c1-10) ${e##*/}"; done
ls -a "$F/events" | grep -c lock | sed 's/^/    lock files left: /'

echo "=== B2: effort-close refuses while work is open"
run sh $FL/open-work.sh --effort "$F"
run sh $G/open-work.sh --effort "$F"
FLOW=$(agree "$F" "$S/flow.json"); show "    agreed: $FLOW"
D=$(sh $G/grill-new.sh --effort "$F" --topic 'second thoughts'); show "    grill: $D"
run sh $FL/open-work.sh --effort "$F"
run sh $G/open-work.sh --effort "$F"
run sh $E/effort-close.sh --effort "$F" --outcome done --words 'all done'
echo "--- the grill ends: only the flow is left"
sh $G/grill-end.sh --grill "$D" | sed "s|$F|<F>|;s|^|    ended: |"
run sh $E/effort-close.sh --effort "$F" --outcome done --words 'all done'
echo "--- --leave-open on the human's word: closed, what was open recorded by the script"
run sh $E/effort-close.sh --effort "$F" --outcome dropped --words 'stop here, leave the flow' --leave-open
jq -c '.body' "$(ls "$F"/events/*effort.closed.json | tail -1)" | sed 's|^|    body: |'
run sh $E/effort-status.sh --effort "$F"
echo "--- reopened, the flow ended: closes normally, nothing recorded"
run sh $E/effort-resume.sh --effort "$F" --words 'one more go'
run sh $FL/flow-end.sh --flow "$FLOW" --outcome dropped --words 'replaced by a new plan'
run sh $E/effort-close.sh --effort "$F" --outcome done --words 'finished' --leave-open
jq -c '.body' "$(ls "$F"/events/*effort.closed.json | tail -1)" | sed 's|^|    body: |'
echo "--- a paused effort with an open grill: refused the same way"
F2=$(sh $E/effort-start.sh --name paused); show "    started: $F2"
sh $G/grill-new.sh --effort "$F2" --topic 'open question' >/dev/null && echo "    grill opened"
run sh $E/effort-pause.sh --effort "$F2" --words 'later'
run sh $E/effort-close.sh --effort "$F2" --outcome dropped --words 'not needed'
echo "--- a component whose open-work check fails: refused; --leave-open records it"
F3=$(sh $E/effort-start.sh --name failing); show "    started: $F3"
# Run from a copy of main-thread in the scratch space, so the tree under test
# is never written: effort-close scans its sibling folders.
CP="$S/main-thread-copy"; cp -R "$C" "$CP"
mkdir -p "$CP/zz-broken/scripts"; printf '#!/bin/sh\necho broken >&2\nexit 5\n' >"$CP/zz-broken/scripts/open-work.sh"
run sh "$CP/crucible-effort/scripts/effort-close.sh" --effort "$F3" --outcome done --words 'done'
run sh "$CP/crucible-effort/scripts/effort-close.sh" --effort "$F3" --outcome done --words 'close anyway' --leave-open
jq -c '.body' "$(ls "$F3"/events/*effort.closed.json | tail -1)" | sed 's|^|    body: |'
[ ! -e "$C/zz-broken" ] && echo "    the repository tree is untouched"
echo "--- the rule: a hand-made left_open of the wrong shape is refused"
printf '{"outcome":"done","words":"x","left_open":"everything"}' >"$S/body.json"
F4=$(sh $E/effort-start.sh --name shape)
run sh $C/crucible-events/scripts/event-write.sh --effort "$F4" --type effort.closed --by evidence --body-file "$S/body.json"

echo "=== C1: the event-writer guard (PreToolUse on Bash)"
W=$C/crucible-events/scripts/event-write.sh
guard() { # $1 the tool, $2 the command
	out=$(jq -cn --arg t "$1" --arg c "$2" '{tool_name: $t, tool_input: {command: $c}}' | sh $HOOK 2>"$S/err"); e=$?
	if [ -n "$out" ]; then d=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision'); else d=allow; fi
	printf '    %-6s %s\n' "$d" "$(show "[$1] $2")"; [ -s "$S/err" ] && show "$(cat "$S/err")" | sed 's|^|           note: |'; [ $e -eq 0 ] || echo "           exit $e"
}
guard Bash "sh $W --effort x --type a.b"
guard Bash "bash '$W' --effort x"
guard Bash "$W --effort x"
guard Bash "cd $C/crucible-events/scripts && ./event-write.sh --effort x"
guard Bash "FOO=1 env nice sh $W --effort x"
guard Bash "sh -c \"sh $W --effort x\""
guard Bash "ls; sh $W --effort x | cat"
guard Bash "sh $W --help"
guard Bash "cat $W"
guard Bash "grep -n refuse $W"
guard Bash "sed -n 1,20p $W"
guard Bash "echo 'event-write.sh is the only writer'"
guard Bash "sh $E/effort-pause.sh --effort x --words y"
guard Bash "git status"
guard Edit "sh $W --effort x"
out=$(printf 'not json event-write.sh' | sh $HOOK 2>"$S/err"); echo "    bad JSON: stdout '${out}', note: $(cat "$S/err"), exit $?"
for b in sh cat tr; do ln -sf "$(command -v $b)" "$S/bin/$b"; done
out=$(jq -cn --arg c "sh $W --effort x" '{tool_name: "Bash", tool_input: {command: $c}}' | PATH="$S/bin" sh $HOOK 2>"$S/err"); echo "    jq missing: stdout '${out}', note: $(cat "$S/err")"

echo "=== A2: the install check (read-only)"
run sh $I/install-check.sh --settings "$S/missing.json"
echo '{}' >"$S/empty.json"
sh $I/install-check.sh --settings "$S/empty.json" >"$S/o"; echo "    empty settings: exit $?, $(wc -l <"$S/o" | tr -d ' ') lines missing"
echo "--- complete, from install-entries.sh's own output"
sh $I/install-entries.sh | sed -n '/^# Settings/,/^$/p' | sed '1d' >"$S/settings.json"
sh $I/install-entries.sh | sed -n '/^# Links/,/^$/p' | sed '1d' >"$S/links.sh"; sh "$S/links.sh"
before=$(shasum -a 256 "$S/settings.json" | cut -d ' ' -f 1); links_before=$(ls -l "$S/cfg/skills" | wc -l)
run sh $I/install-check.sh --settings "$S/settings.json"
echo "--- partial: two hooks taken out"
jq 'del(.hooks.Stop)' "$S/settings.json" >"$S/partial.json"
run sh $I/install-check.sh --settings "$S/partial.json"
echo "--- split across two files, as Claude Code merges them"
jq '{hooks}' "$S/settings.json" >"$S/a.json"; jq '{permissions}' "$S/settings.json" >"$S/b.json"
run sh $I/install-check.sh --settings "$S/a.json" --settings "$S/b.json"
echo "--- everything but CLAUDE.md"
mv "$S/cfg/CLAUDE.md" "$S/cfg/CLAUDE.md.off"
run sh $I/install-check.sh --settings "$S/settings.json"
mv "$S/cfg/CLAUDE.md.off" "$S/cfg/CLAUDE.md"
echo "--- a broken skill link"
rm "$S/cfg/skills/crucible-grill"; ln -s "$S/nowhere" "$S/cfg/skills/crucible-grill"
run sh $I/install-check.sh --settings "$S/settings.json"
rm "$S/cfg/skills/crucible-grill"; ln -s "$C/crucible-grill" "$S/cfg/skills/crucible-grill"
echo "--- everything but jq"
for b in sh cat tr mktemp rm dirname pwd; do ln -sf "$(command -v $b)" "$S/bin/$b"; done
run env PATH="$S/bin" sh $I/install-check.sh --settings "$S/settings.json"
echo "--- the check changed nothing"
[ "$(shasum -a 256 "$S/settings.json" | cut -d " " -f 1)" = "$before" ] && echo "    settings.json unchanged after every check"
[ "$(ls -l "$S/cfg/skills" | wc -l)" = "$links_before" ] && echo "    skill links unchanged after every check"
run sh $I/install-check.sh --settings "$S/settings.json"
