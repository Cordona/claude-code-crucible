# Evidence run for crucible-grill: the grill is its own fact, never a context entry.
C=/Users/cordona/IdeaProjects/cordona/claude-code-crucible/new-rewrite/framework/core/main-thread; G=$C/crucible-grill/scripts; E=$C/crucible-effort/scripts; X=$C/crucible-context/scripts
S="/private/tmp/claude-501/-Users-cordona-IdeaProjects-cordona-claude-code-crucible/480d0359-cf0d-4c14-a59e-2a72be5dba4f/scratchpad/grill test"; rm -rf "$S"; mkdir -p "$S"; export CRUCIBLE_HOME="$S/space" CLAUDE_CONFIG_DIR="$S/cfg" CLAUDE_CODE_SESSION_ID=sess-g
. /Users/cordona/IdeaProjects/cordona/claude-code-crucible/.crucible/docs/rewrite-next/evidence/lib-decide.sh
cd /
F=$(sh $E/effort-start.sh --name prune)
run() { echo "\$ $(echo "$*" | sed "s|$G/||g;s|$E/||g;s|$X/||g;s|$C/||g;s|$F|<F>|g")"; out=$("$@" 2>&1); e=$?; echo "$out" | sed "s|$F|<F>|g;s|^|    |"; echo "    [exit $e]"; }
D=$(sh $G/grill-new.sh --effort "$F" --topic "How the prune command should behave"); echo "    draft: $D" | sed "s|$F|<F>|g"
run sh $G/grill-add.sh --grill "$D" --question "Who runs the prune: a person or a cron job?" --recommendation "A cron job" --reason "It runs nightly"
run sh $G/grill-add.sh --grill "$D" --question "Should it email on failure?" --recommendation "Yes" --reason "No one watches cron" --parent q1 --question "Dry run by default?" --recommendation "Yes" --reason "Safe first run"
run sh $G/grill-add.sh --grill "$D" --question "Orphan?" --recommendation "x" --reason "y" --parent q9
run sh $G/grill-add.sh --grill "$D" --question "No reason?" --recommendation "x"
run sh $G/grill-show.sh --grill "$D" --open
run sh $G/grill-answer.sh --grill "$D" --id q1 --text "A cron job" --id q2 --text "No"
run sh $G/grill-answer.sh --grill "$D" --id q1 --text "A person"
run sh $G/grill-answer.sh --grill "$D" --id q3 --text "Yes" --change-reason "x"
run sh $G/grill-answer.sh --grill "$D" --id q7 --text "x"
run sh $G/grill-answer.sh --grill "$D" --id q1 --text "x" --id q1 --text "y" --change-reason z
run sh $G/grill-answer.sh --grill "$D" --id q1 --text "A person, on demand" --change-reason "Ops runs it by hand"
run sh $G/grill-mark.sh --grill "$D" --id q3 --to deferred --reason "needs the ops team"
run sh $G/grill-mark.sh --grill "$D" --id q3 --to deferred --reason "again"
run sh $G/grill-mark.sh --grill "$D" --id q2 --to dropped --reason "no cron, no email"
run sh $G/grill-answer.sh --grill "$D" --id q2 --text "x"
run sh $G/grill-mark.sh --grill "$D" --id q2 --to open --reason "it matters again"
run sh $G/grill-answer.sh --grill "$D" --id q3 --text "Yes, dry run first"
run sh $G/grill-show.sh --grill "$D"
echo "--- draft"; jq -c '.questions[]' "$D"
D2=$(sh $G/grill-new.sh --effort "$F" --topic "second grill"); echo "    draft: $D2" | sed "s|$F|<F>|g"
echo "--- five concurrent adds on grill 2: each gets its own id"
for i in 1 2 3 4 5; do (out=$(sh $G/grill-add.sh --grill "$D2" --question "Q$i?" --recommendation r --reason w 2>&1); echo "$? $out") & done >"$S/adds"; wait
sort "$S/adds" | awk '{print "    exit " $1 ", id " $2}' | sort
jq -r '"    ids in the draft: \([.questions[].id] | sort | join(",")); questions: \([.questions[].text] | sort | join(" "))"' "$D2"
run sh $G/grill-list.sh --effort "$F"
EV=$(sh $G/grill-end.sh --grill "$D"); echo "    ended: $EV" | sed "s|$F|<F>|g"
run sh $G/grill-end.sh --grill "$D"
run sh $G/grill-show.sh --grill "$EV" --open
run sh $G/grill-list.sh --effort "$F"
run sh $G/grill-new.sh --effort "$F" --topic "third"
echo "--- the ended grill is its own fact: read from the events, never added to the context"
sh $C/crucible-events/scripts/events-read.sh --effort "$F" --type grill.ended | jq -r '.[] | "    grill.ended seq \(.seq): grill \(.body.number) \"\(.body.topic)\""'
run sh $X/context-add.sh --effort "$F" --path "$EV" --why "grill: How the prune command should behave"
echo "--- paused effort"
run sh $E/effort-pause.sh --effort "$F" --words later
run sh $G/grill-add.sh --grill "$D2" --question "x?" --recommendation r --reason w
run sh $G/grill-list.sh --effort "$F"
