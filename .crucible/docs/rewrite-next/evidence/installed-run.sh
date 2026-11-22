# Evidence run through the installed layout: a scratch Claude folder, linked
# with install-entries.sh's own commands, and every component called through
# its skill link, as main calls them.
R=/Users/cordona/IdeaProjects/cordona/claude-code-crucible/new-rewrite
S="/private/tmp/claude-501/-Users-cordona-IdeaProjects-cordona-claude-code-crucible/480d0359-cf0d-4c14-a59e-2a72be5dba4f/scratchpad/installed test"; rm -rf "$S"; mkdir -p "$S/cfg" "$S/repo"
export CRUCIBLE_HOME="$S/space" CLAUDE_CONFIG_DIR="$S/cfg" CLAUDE_CODE_SESSION_ID=sess-i
cd /
K="$S/cfg/skills"
show() { echo "$1" | sed "s|$K/|<skills>/|g;s|$R|<R>|g;s|$S|<S>|g;s|[0-9]\{8\}T[0-9]\{6\}-[0-9a-f]\{4\}|<id>|g;s|[0-9a-f]\{64\}|<hex>|g;s|20[0-9-]*T[0-9:.]*Z|<at>|g"; }
run() { show "\$ $*"; out=$("$@" 2>&1); e=$?; show "$out" | sed 's|^|    |'; echo "    [exit $e]"; }
# One recorded gate through the installed hooks: card, stop, question, answer.
decide() { # $1 effort, $2 record, $3 subject, $4 card file, $5 answer
	t="t-$2-$(date +%s%N)"
	sh "$K/crucible-gate/scripts/show-card.sh" --record "$2" --effort "$1" --subject "$3" --accept "Approve (Recommended)" "$4" >/dev/null
	jq -cn --rawfile m "$4" --arg s sess-i '{session_id: $s, last_assistant_message: $m}' | sh "$K/crucible-gate/hooks/stop/require-card-shown.sh" >/dev/null
	jq -cn --arg s sess-i --arg t "$t" '{session_id: $s, tool_name: "AskUserQuestion", tool_use_id: $t, tool_input: {questions: [{question: "Decide?", header: "Decide", options: [{label: "Approve (Recommended)", description: "yes"}, {label: "Change it", description: "no"}]}]}}' | sh "$K/crucible-gate/hooks/pre-tool-use/hold-question-until-card-shown.sh" >/dev/null
	jq -cn --arg s sess-i --arg t "$t" --arg a "$5" '{session_id: $s, tool_name: "AskUserQuestion", tool_use_id: $t, tool_response: {answers: {"Decide?": $a}}}' | sh "$K/crucible-gate/hooks/post-tool-use/record-gate-answer.sh"
}

echo "=== install, with install-entries.sh's own output"
sh $R/framework/core/install/install-entries.sh | sed -n '/^# Settings/,/^$/p' | sed '1d' >"$S/settings.json"
sh $R/framework/core/install/install-entries.sh | sed -n '/^# Links/,/^$/p' | sed '1d' >"$S/links.sh"
sh "$S/links.sh"
ls "$K" | sed 's|^|    linked: |'
run sh $R/framework/core/install/install-check.sh --settings "$S/settings.json"

echo "=== effort, through its link"
F=$(sh "$K/crucible-effort/scripts/effort-start.sh" --name installed); show "    started: $F"
run sh "$K/crucible-effort/scripts/effort-state.sh" --effort "$F"

echo "=== flow and gate"
printf '{"goal":"Know the work","done_when":{"criteria":"the human says so","by":"human"},"steps":[{"id":1,"do":"Grill it","uses":"crucible-grill","done_when":{"event":"grill.ended"}}]}\n' >"$S/flow.json"
run sh "$K/crucible-dynamic-flow/scripts/flow-card.sh" --file "$S/flow.json"
sh "$K/crucible-dynamic-flow/scripts/flow-card.sh" --file "$S/flow.json" >"$S/card.md"
FSHA=$(shasum -a 256 "$S/flow.json" | cut -d ' ' -f 1)
decide "$F" flow-agree "$FSHA" "$S/card.md" "Approve (Recommended)" >/dev/null
run sh "$K/crucible-gate/scripts/gate-answer.sh" --effort "$F" --record flow-agree --subject "$FSHA"
FLOW=$(sh "$K/crucible-dynamic-flow/scripts/flow-agree.sh" --effort "$F" --file "$S/flow.json"); show "    agreed: $FLOW"
run sh "$K/crucible-dynamic-flow/scripts/open-work.sh" --effort "$F"

echo "=== grill"
D=$(sh "$K/crucible-grill/scripts/grill-new.sh" --effort "$F" --topic 'what to fetch'); show "    draft: $D"
run sh "$K/crucible-grill/scripts/grill-add.sh" --grill "$D" --question 'Which limits?' --recommendation 'All' --reason 'One call'
run sh "$K/crucible-grill/scripts/grill-answer.sh" --grill "$D" --id q1 --text 'All of them'
GE=$(sh "$K/crucible-grill/scripts/grill-end.sh" --grill "$D"); show "    ended: $GE"

run sh "$K/crucible-dynamic-flow/scripts/flow-step-done.sh" --flow "$FLOW" --step 1

echo "=== code-context, in full"
git -C "$S/repo" init -q; printf 'one\n' >"$S/repo/a.txt"; git -C "$S/repo" add a.txt; git -C "$S/repo" -c user.name=t -c user.email=t@t commit -qm one
printf 'two\n' >>"$S/repo/a.txt"; git -C "$S/repo" -c user.name=t -c user.email=t@t commit -qam two
run sh "$K/code-context/scripts/context-add-commit.sh" --effort "$F" --repo "$S/repo" --ref HEAD

echo "=== trackers, in full (reads GitHub)"
run sh "$K/trackers/scripts/tracker-read.sh" --url 'https://example.com/page'
sh "$K/trackers/scripts/tracker-read.sh" --url 'https://github.com/cli/cli/issues/1' | head -n 1 | sed 's|^|    first line: |'
run sh "$K/trackers/scripts/context-add-ticket.sh" --effort "$F" --url 'https://github.com/cli/cli/issues/1'

echo "=== context"
run sh "$K/crucible-context/scripts/context-add.sh" --effort "$F" --path "$GE" --why 'the grill on what to fetch'
run sh "$K/crucible-context/scripts/context-status.sh" --effort "$F"

echo "=== spec, then the cut"
mkdir -p "$F/spec"; printf '## Goal\nFetch the limits\n## Done when\nThey show\n## Scope\nIn: the fetch\n## Constraints\nNone\n## Open points\nNone\n' >"$F/spec/1.md"
SSHA=$(shasum -a 256 "$F/spec/1.md" | cut -d ' ' -f 1)
decide "$F" spec-approval "$SSHA" "$F/spec/1.md" "Approve (Recommended)" >/dev/null
run sh "$K/crucible-spec/scripts/spec-approve.sh" --effort "$F" --draft "$F/spec/1.md"
FP=$(sh "$K/crucible-context/scripts/context-fingerprint.sh" --effort "$F" | sed -n 's/FINGERPRINT: //p')
run sh "$K/crucible-context/scripts/context-cut.sh" --effort "$F" --expect "$FP"
V=$(sh "$K/crucible-context/scripts/context-status.sh" --effort "$F" | sed -n 's/CONTEXT_FILE: //p')
ls "$F/context/v1" | sed 's|^|    v1 holds: |'
run sh "$K/crucible-context/scripts/context-verify.sh" --effort "$F" --file "$V"

echo "=== effort-close sees a domain neighbour's open work"
mkdir -p "$S/zz-domain-probe/scripts"; printf '#!/bin/sh\necho "probe 1 \\"left running\\""\n' >"$S/zz-domain-probe/scripts/open-work.sh"
ln -s "$S/zz-domain-probe" "$K/zz-domain-probe"
run sh "$K/crucible-effort/scripts/effort-close.sh" --effort "$F" --outcome done --words 'done'
rm "$K/zz-domain-probe"
run sh "$K/crucible-dynamic-flow/scripts/flow-end.sh" --flow "$FLOW" --outcome done --evidence 'The human says so'
run sh "$K/crucible-effort/scripts/effort-close.sh" --effort "$F" --outcome done --words 'done'
run sh "$K/crucible-effort/scripts/effort-status.sh" --effort "$F"

echo "=== a domain script where core isn't beside it: refused plainly"
mkdir -p "$S/lonely"; ln -s "$R/domains/software-development/core/main-thread/trackers" "$S/lonely/trackers"
run sh "$S/lonely/trackers/scripts/context-add-ticket.sh" --effort "$F" --url 'https://github.com/cli/cli/issues/1'
run sh "$R/domains/software-development/core/main-thread/code-context/scripts/context-add-commit.sh" --effort "$F" --repo "$S/repo" --ref HEAD

echo "=== the event log, read through the installed reader"
sh "$R/framework/core/main-thread/crucible-events/scripts/events-read.sh" --effort "$F" | jq -r '.[] | "    \(.seq) \(.type) by \(.by)"'
