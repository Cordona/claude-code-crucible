#!/usr/bin/env sh
# Evidence run for jobs step 2 (the test and review kinds, the agent files,
# the door and its hooks, before the rewire), through the installed
# layout: a scratch Claude folder linked with install-entries.sh's own
# commands, a scratch space and effort with a real grill, context cut, spec
# and tree, and the jobs gate answered through the installed gate hooks.
# Only scratch: its own HOME, no key. Exits 1 when any expectation fails.
# shellcheck disable=SC2016,SC2312 # single-quoted jq and sh -c are meant literally; a read inside a check is what the check compares
set -u
R=/Users/cordona/IdeaProjects/cordona/claude-code-crucible/new-rewrite
S=$(mktemp -d "${TMPDIR:-/tmp}/jobs-2.XXXXXX") || exit 2
S=$(cd -P -- "${S}" && pwd -P)
trap 'rm -rf -- "${S}"' EXIT
mkdir -p "${S}/home" "${S}/cfg" "${S}/work"
export HOME="${S}/home" GIT_CONFIG_GLOBAL="${S}/home/.gitconfig" GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME="${S}/home/.config"
export CRUCIBLE_HOME="${S}/space" CLAUDE_CONFIG_DIR="${S}/cfg" CLAUDE_CODE_SESSION_ID=sess-j1
unset SSH_AUTH_SOCK SSH_AGENT_PID GIT_DIR GIT_WORK_TREE GPG_TTY
cd / || exit 2
K="${S}/cfg/skills"
J="${K}/jobs-define/scripts/main"
ER="${K}/crucible-events/scripts/internal/events-read.sh"

pass=0 fail=0
show() { sed "s|${S}|<S>|g;s|${K}/|<skills>/|g;s|[0-9a-f]\{64\}|<sha>|g"; }
check() { # check WHAT COMMAND...: PASS when the command succeeds
	what=$1; shift
	if "$@" >/dev/null 2>&1; then pass=$((pass + 1)); echo "  PASS: ${what}"
	else fail=$((fail + 1)); echo "  FAIL: ${what}"; fi
}
is() { [ "$1" = "$2" ]; }
has() { printf '%s' "$1" | grep -qF -- "$2"; }
# run SCRIPT ARGS...: OUT, ERR and RC; both printed, scrubbed.
run() {
	RC=0
	OUT=$(sh "$@" 2>"${S}/work/err") || RC=$?
	ERR=$(cat "${S}/work/err")
	printf '    $ %s\n' "${1##*/} ${2-} ${3-}" | show
	[ -z "${OUT}" ] || printf '%s\n' "${OUT}" | sed 's/^/    out: /' | show
	[ -z "${ERR}" ] || printf '%s\n' "${ERR}" | sed 's/^/    err: /' | show
	printf '    [exit %s]\n' "${RC}"
}
count() { sh "${ER}" --effort "$1" --type "$2" | jq 'length'; }
# decide EFFORT RECORD SUBJECT CARD ANSWER: one recorded gate answered
# through the installed hooks, as a session would.
decide() {
	t="t-$2-$(date +%s)-$$-${RANDOM:-0}"
	sh "${K}/crucible-gate/scripts/main/show-card.sh" --record "$2" --effort "$1" --subject "$3" --accept 'Approve (Recommended)' "$4" >/dev/null
	gate_hooks "$4" "${t}" "$5"
}
gate_hooks() { # CARD TOOL_USE_ID ANSWER: the card's stop, the question, the answer
	jq -cn --rawfile m "$1" '{session_id: "sess-j1", last_assistant_message: $m}' | sh "${K}/crucible-gate/hooks/stop/require-card-shown.sh" >/dev/null
	jq -cn --arg t "$2" '{session_id: "sess-j1", tool_name: "AskUserQuestion", tool_use_id: $t, tool_input: {questions: [{question: "Decide?", header: "Jobs", options: [{label: "Approve (Recommended)", description: "yes"}, {label: "Change it", description: "no"}]}]}}' \
		| sh "${K}/crucible-gate/hooks/pre-tool-use/hold-question-until-card-shown.sh" >/dev/null
	jq -cn --arg t "$2" --arg a "$3" '{session_id: "sess-j1", tool_name: "AskUserQuestion", tool_use_id: $t, tool_response: {answers: {"Decide?": $a}}}' \
		| sh "${K}/crucible-gate/hooks/post-tool-use/record-gate-answer.sh"
}
# card_and_answer EFFORT PROPOSAL ANSWER: job-card.sh, then the human's answer;
# GATE is the gate.answered seq.
card_and_answer() {
	t="t-jobs-$(date +%s)-$$-${RANDOM:-0}"
	sh "${J}/job-card.sh" --effort "$1" --proposal "$2" >"${S}/work/card.md"
	gate_hooks "${S}/work/card.md" "${t}" "$3"
	GATE=$(sh "${ER}" --effort "$1" --type gate.answered | jq '.[-1].seq')
}
proposal_of() { printf '%s' "$1" | sed -n 's/.* resolved: \(.*\), sha256 .*/\1/p'; }

echo "=== install: install-entries.sh's own links and settings"
sh "${R}/framework/core/install/install-entries.sh" | sed -n '/^# Links/,/^$/p' | sed '1d' >"${S}/links.sh"
sh "${R}/framework/core/install/install-entries.sh" | sed -n '/^# Settings/,/^$/p' | sed '1d' >"${S}/settings.json"
sh "${S}/links.sh"
check 'jobs/define installs as jobs-define, the build kind in its kinds folder' sh -c '[ "$(readlink "$1/jobs-define")" = "$2/domains/software-development/core/main-thread/jobs/define" ] && [ -f "$1/jobs-define/kinds/build.json" ] && [ ! -e "$1/jobs" ]' _ "${K}" "${R}"
out=$(sh "${R}/framework/core/install/install-check.sh" --settings "${S}/settings.json" 2>&1)
check 'the install check names no extra folder for the new components' sh -c '! printf "%s" "$1" | grep -q "extra: folder .*jobs/"' _ "${out}"
for script in job-resolve.sh job-card.sh job-define.sh; do
	out=$(sh "${J}/${script}" --help 2>&1); rc=$?
	check "${script} --help" sh -c '[ "$1" -eq 0 ] && printf "%s" "$2" | grep -q "^usage: " && printf "%s" "$2" | grep -q "^Exit:"' _ "${rc}" "${out}"
done
check 'the core is unchanged: no job word in framework/core' sh -c '! grep -rqE "jobs-define|job\.defined|kinds/build" "$1/framework/core"' _ "${R}"
check 'jobs/define names no kind but build, and that only in the iteration count' sh -c '[ "$(grep -rhoE "\"build\"" "$1" | wc -l | tr -d " ")" -le 4 ] && ! grep -rqE "code-builder|code-tester|code-reviewer" "$1"' _ "${R}/domains/software-development/core/main-thread/jobs/define/scripts" "${R}/domains/software-development/core/main-thread/jobs/define/events"

echo "=== an effort with a grill, a context cut, a spec and a tree"
effort=$(sh "${K}/crucible-effort/scripts/main/effort-start.sh" --name 'jobs one') || { echo 'effort-start failed'; exit 1; }
repo="${S}/repo"
git init -q "${repo}" && printf 'one\n' >"${repo}/a.txt" && git -C "${repo}" add a.txt \
	&& git -C "${repo}" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm one || exit 1
D=$(sh "${K}/crucible-grill/scripts/main/grill-new.sh" --effort "${effort}" --topic 'what to build')
sh "${K}/crucible-grill/scripts/main/grill-add.sh" --grill "${D}" --question 'Which file?' --recommendation 'a.txt' --reason 'It exists' >/dev/null
sh "${K}/crucible-grill/scripts/main/grill-answer.sh" --grill "${D}" --id q1 --text 'a.txt' >/dev/null
GE=$(sh "${K}/crucible-grill/scripts/main/grill-end.sh" --grill "${D}")
sh "${K}/code-context/scripts/main/context-add-commit.sh" --effort "${effort}" --repo "${repo}" --ref HEAD >/dev/null
sh "${K}/crucible-context/scripts/main/context-add.sh" --effort "${effort}" --path "${GE}" --why 'the grill' >/dev/null
printf 'Context to cut\n' >"${S}/work/ctx-card.md"
FP=$(sh "${K}/crucible-context/scripts/main/context-fingerprint.sh" --effort "${effort}" | sed -n 's/FINGERPRINT: //p')
decide "${effort}" context-done "${FP}" "${S}/work/ctx-card.md" 'Approve (Recommended)'
sh "${K}/crucible-context/scripts/main/context-cut.sh" --effort "${effort}" >/dev/null
mkdir -p "${effort}/spec"; printf '## Goal\nBuild it\n## Done when\nIt runs\n## Scope\nIn: a.txt\n## Constraints\nNone\n## Open points\nNone\n' >"${effort}/spec/1.md"
SSHA=$(shasum -a 256 "${effort}/spec/1.md" | cut -d ' ' -f 1)
decide "${effort}" spec-approval "${SSHA}" "${effort}/spec/1.md" 'Approve (Recommended)'
sh "${K}/crucible-spec/scripts/main/spec-approve.sh" --effort "${effort}" --draft "${effort}/spec/1.md" >/dev/null
sh "${K}/git-worktree/scripts/main/worktree-cut.sh" --effort "${effort}" --repo "${repo}" --name tree-a --from checkout >/dev/null
CTX=$(sh "${ER}" --effort "${effort}" --type context.cut | jq '.[-1].seq')
SPEC=$(sh "${ER}" --effort "${effort}" --type spec.approved | jq '.[-1].seq')
GRILL=$(sh "${ER}" --effort "${effort}" --type grill.ended | jq '.[-1].seq')
TREE=$(sh "${ER}" --effort "${effort}" --type worktree.cut | jq '.[-1].seq')
check 'the effort holds a context cut, a spec, a grill and a tree' sh -c '[ "$1" != null ] && [ "$2" != null ] && [ "$3" != null ] && [ "$4" != null ]' _ "${CTX}" "${SPEC}" "${GRILL}" "${TREE}"

P='{"language": "kotlin", "frameworks": ["spring"], "standards": ["clean-code"]}'
cut="{\"cut\": {\"repo\": \"${repo}\", \"from\": \"checkout\"}}"

A="${K}/jobs-assign"
AF="${K}/jobs-agent-init/scripts/main/agent-files.sh"
DOOR="${A}/scripts/main/job-assign.sh"
NOTES="${S}/cfg/cache/jobs-assign/sess-j1"
# hook EVENT_FOLDER SCRIPT JSON: one hook run through its installed link;
# OUT its stdout, ERR its stderr, RC its exit.
hook() {
	RC=0
	OUT=$(printf '%s' "$3" | sh "${A}/hooks/$1/$2" 2>"${S}/work/herr") || RC=$?
	ERR=$(cat "${S}/work/herr")
}
deny_of() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty'; }

echo "=== install: the new pieces and their hooks"
check 'jobs-assign and jobs-agent-init are installed' sh -c '[ -f "$1/jobs-assign/scripts/main/job-assign.sh" ] && [ -f "$1/jobs-agent-init/scripts/main/agent-files.sh" ]' _ "${K}"
check 'the start and tree hooks are registered as SubagentStart and WorktreeCreate' jq -e '(.hooks.SubagentStart[].hooks[].command | test("jobs-assign/hooks/subagent-start/job-assigned.sh")) and (.hooks.WorktreeCreate[].hooks[].command | test("jobs-assign/hooks/worktree-create/job-tree.sh")) and any(.hooks.PreToolUse[]; .matcher == "Agent") and any(.hooks.PostToolUse[]; .matcher == "SendMessage")' "${S}/settings.json"
for script in "${DOOR}" "${AF}" "${A}"/hooks/*/*.sh; do
	out=$(sh "${script}" --help 2>&1); rc=$?
	check "${script##*/} --help" sh -c '[ "$1" -eq 0 ] && printf "%s" "$2" | grep -q "^usage: " && printf "%s" "$2" | grep -q "^Exit:"' _ "${rc}" "${out}"
done
check 'each kind states its write scope once: none left in the three kinds'"'"' submissions files' sh -c 'for k in code-builder/submissions/build code-tester/submissions/test code-reviewer/submissions/review; do jq -e "has(\"writes\") | not" "$1/$k.json" || exit 1; done' _ "${K}"

echo "=== 1. the test and review kinds resolve"
jq -n --argjson p "${P}" --argjson t "${TREE}" '{jobs: [{kind: "test", plugins: $p, work: {tree: {use: $t}}}]}' >"${S}/work/test.json"
run "${J}/job-resolve.sh" --effort "${effort}" --jobs "${S}/work/test.json"
check 'a test with no plan is refused: main names it' sh -c '[ "$1" -eq 2 ] && printf "%s" "$2" | grep -q "job 1: a test needs plan: name the seq of its test-plan.submitted or test-plan.updated"' _ "${RC}" "${ERR}"
jq -n --argjson p "${P}" --argjson t "${TREE}" --argjson c "${CTX}" '{jobs: [{kind: "test", plugins: $p, work: {tree: {use: $t}}, input_refs: {plan: $c}}]}' >"${S}/work/test-wrong.json"
run "${J}/job-resolve.sh" --effort "${effort}" --jobs "${S}/work/test-wrong.json"
check 'a plan that is no plan is refused, naming both types' has "${ERR}" "job 1: plan must be the seq of a test-plan.submitted or test-plan.updated"
jq -n --argjson p "${P}" --argjson cut "${cut}" '{jobs: [{kind: "test", plugins: $p, work: {tree: $cut}}]}' >"${S}/work/test-cut.json"
run "${J}/job-resolve.sh" --effort "${effort}" --jobs "${S}/work/test-cut.json"
check 'a test that cuts a tree is refused: a test uses one' has "${ERR}" "a test's tree is {use}, not {cut}"
RP=$(printf '%s' "${P}" | jq -c '.standards = ["security"]')
jq -n --argjson p "${P}" --argjson rp "${RP}" --argjson t "${TREE}" --argjson cut "${cut}" \
	'{jobs: [{kind: "build", plugins: $p, work: {tree: $cut, known_failures: ["lint"]}}, {kind: "review", plugins: $rp, work: {tree: {use: $t}}}]}' >"${S}/work/br.json"
run "${J}/job-resolve.sh" --effort "${effort}" --jobs "${S}/work/br.json"
PBR=$(proposal_of "${OUT}")
TPATH=$(sh "${ER}" --effort "${effort}" --type worktree.cut | jq -r '.[-1].body.path')
check 'the review'"'"'s range is its tree'"'"'s base to its head now' jq -e --arg h "$(git -C "${TPATH}" rev-parse HEAD)" --arg b "$(sh "${ER}" --effort "${effort}" --type worktree.cut | jq -r '.[-1].body.base')" '.jobs[1].work.range == {base: $b, head: $h}' "${PBR}"
check 'the build keeps its known failures; the review has none to keep' jq -e '.jobs[0].work.known_failures == ["lint"] and (.jobs[1].work | has("known_failures") | not)' "${PBR}"
check 'the review takes its tree'"'"'s current iteration, 1' jq -e '.jobs[1].work.loop.iteration == 1' "${PBR}"
jq -n --argjson p "${RP}" --argjson t "${TREE}" '{jobs: [{kind: "review", plugins: $p, work: {tree: {use: $t}, known_failures: ["x"]}}]}' >"${S}/work/review-kf.json"
run "${J}/job-resolve.sh" --effort "${effort}" --jobs "${S}/work/review-kf.json"
check 'known failures on a review are refused' has "${ERR}" "work.known_failures is not main's to give for a review"

jq -n --argjson t "${TREE}" '{jobs: [{kind: "review", plugins: {language: "kotlin", standards: ["security", "clean-code"]}, work: {tree: {use: $t}}}]}' >"${S}/work/review-two.json"
run "${J}/job-resolve.sh" --effort "${effort}" --jobs "${S}/work/review-two.json"
check 'a review through two standards is refused: one lens per review' has "${ERR}" "a review reads through one standard, its lens: give one, a job per lens"

jq -n --argjson p "${P}" --argjson t "${TREE}" '{jobs: [{kind: "test-plan-update", plugins: $p, work: {tree: {use: $t}}}]}' >"${S}/work/update-bare.json"
run "${J}/job-resolve.sh" --effort "${effort}" --jobs "${S}/work/update-bare.json"
check 'a plan rework with no plan, and neither a challenge nor words: refused, both said' sh -c 'printf "%s" "$1" | grep -q "a test-plan-update needs plan: name the seq of its test-plan.submitted or test-plan.updated" && printf "%s" "$1" | grep -q "a test-plan-update needs challenge or words: name one"' _ "${ERR}"

echo "=== 2. the card names the agent files; the jobs are defined"
t="t-jobs-$(date +%s)-$$"
sh "${J}/job-card.sh" --effort "${effort}" --proposal "${PBR}" >"${S}/work/card.md" 2>"${S}/work/card.err"
check 'the card'"'"'s run names agent-files.sh and the proposal' has "$(cat "${S}/work/card.err")" "agent-files.sh --proposal ${PBR}"
gate_hooks "${S}/work/card.md" "${t}" 'Approve (Recommended)'
GATE=$(sh "${ER}" --effort "${effort}" --type gate.answered | jq '.[-1].seq')
run "${J}/job-define.sh" --effort "${effort}" --gate "${GATE}"
BUILD=$(sh "${ER}" --effort "${effort}" --type job.defined | jq '.[-2].seq')
REVIEW=$(sh "${ER}" --effort "${effort}" --type job.defined | jq '.[-1].seq')
check 'both defined' sh -c '[ "$1" -eq 0 ] && [ "$2" != null ] && [ "$3" != null ]' _ "${RC}" "${BUILD}" "${REVIEW}"

echo "=== 3. the agent files, from the real plugins installed as skills"
check 'every plugin is linked as its own skills, none hidden from the model' sh -c '[ -L "$1/language-kotlin" ] && [ -f "$1/language-kotlin-review/SKILL.md" ] && [ -f "$1/standard-security-build/SKILL.md" ] && ! grep -l "^disable-model-invocation: *true" "$1"/language-*/SKILL.md "$1"/framework-*/SKILL.md "$1"/standard-*/SKILL.md 2>/dev/null | grep -q .' _ "${K}"
REAL=$(readlink "${K}/language-kotlin")
BEFORE_SUM=$(cat "${K}/language-kotlin/SKILL.md" "${K}/standard-security/SKILL.md" | shasum -a 256)
mv "${K}/language-kotlin" "${S}/work/kotlin-link"
run "${AF}" --proposal "${PBR}"
check 'refused while a plugin isn'"'"'t installed as a skill, naming it' sh -c '[ "$1" -eq 2 ] && printf "%s" "$2" | grep -q "no skill language-kotlin "' _ "${RC}" "${ERR}"
mv "${S}/work/kotlin-link" "${K}/language-kotlin"
# A hidden stand-in in place of the security link, never written through it.
SEC=$(readlink "${K}/standard-security")
[ -L "${K}/standard-security" ] && rm -f "${K}/standard-security"
mkdir -p "${K}/standard-security" && printf -- '---\nname: standard-security\ndescription: Hidden.\ndisable-model-invocation: true\n---\n' >"${K}/standard-security/SKILL.md"
run "${AF}" --proposal "${PBR}"
check 'refused for a skill hidden from the model, nothing written' sh -c '[ "$1" -eq 2 ] && printf "%s" "$2" | grep -q "skill standard-security is hidden from the model" && [ ! -d "$3/agents" ]' _ "${RC}" "${ERR}" "${S}/cfg"
[ ! -L "${K}/standard-security" ] && rm -rf "${K}/standard-security"
ln -s "${SEC}" "${K}/standard-security"
check 'the real plugin files are untouched' is "$(cat "${K}/language-kotlin/SKILL.md" "${K}/standard-security/SKILL.md" | shasum -a 256)" "${BEFORE_SUM}"
run "${AF}" --proposal "${PBR}"
BT=code-builder-kotlin-spring-clean-code RT=code-reviewer-kotlin-spring-security
check 'two files written, each named for its base and plugin set' sh -c '[ "$1" -eq 0 ] && printf "%s" "$2" | grep -q "^$3 written$" && printf "%s" "$2" | grep -q "^$4 written$"' _ "${RC}" "${OUT}" "${BT}" "${RT}"
check 'the reviewer'"'"'s file: its name, the base'"'"'s skills then the plugins, the base'"'"'s body' sh -c '
	f="$1/agents/$2.md"; b="$3/code-reviewer/code-reviewer.md"
	grep -q "^name: $2$" "$f" \
	&& [ "$(awk "/^skills:/{s=1;next} s&&/^  - /{print;next} s{exit}" "$f" | tr -d " -" | tr "\n" ,)" = "agentconduct,agentreport,languagekotlin,languagekotlinreview,frameworkspring,frameworkspringreview,standardsecurity,standardsecurityreview," ] \
	&& [ "$(sed "1,/^---$/d" "$f" | sed "1,/^---$/d")" = "$(sed "1,/^---$/d" "$b" | sed "1,/^---$/d")" ]' _ "${S}/cfg" "${RT}" "${K}"
run "${AF}" --proposal "${PBR}"
check 'run again: both already there, none rewritten' sh -c '[ "$(printf "%s" "$1" | grep -c "already there")" -eq 2 ]' _ "${OUT}"

echo "=== 4. the door"
run "${DOOR}" --effort "${effort}" --job "${BUILD}"
check 'a build that cuts its tree: refused until the tree is cut, the line says how' has "${ERR}" "cuts its tree: cut it with git-worktree's worktree-cut.sh (repo ${repo}, from checkout)"
run "${DOOR}" --effort "${effort}" --job "${BUILD}" --tree "${TREE}"
check 'a tree another job already uses is refused as a fresh cut' sh -c '[ "$1" -eq 2 ] && printf "%s" "$2" | grep -q "is already another job.s tree; job $3 cuts a fresh one"' _ "${RC}" "${ERR}" "${BUILD}"
sh "${K}/git-worktree/scripts/main/worktree-cut.sh" --effort "${effort}" --repo "${repo}" --name tree-b --from checkout >/dev/null
TB=$(sh "${ER}" --effort "${effort}" --type worktree.cut | jq '.[-1].seq')
TBPATH=$(sh "${ER}" --effort "${effort}" --type worktree.cut | jq -r '.[-1].body.path')
rm -f "${NOTES}"/cold-*.json
run "${DOOR}" --effort "${effort}" --job "${BUILD}" --tree "${TB}"
BCALL=$(printf '%s' "${OUT}" | tail -n 1)
check 'the build'"'"'s call: an Agent call on its agent file, in a worktree' sh -c 'printf "%s" "$1" | jq -e --arg t "$2" ".tool == \"Agent\" and .subagent_type == \$t and .isolation == \"worktree\" and (has(\"run_in_background\") | not) and .description == \"job-$3\""' _ "${BCALL}" "${BT}" "${BUILD}"
check 'its prompt: the job, its tree, its report, what to read (no context folder for an empty cut), its known failures' sh -c 'p=$(printf "%s" "$1" | jq -r .prompt); printf "%s" "$p" | grep -q "^Job $2, a build.$" && printf "%s" "$p" | grep -q "^Tree: $3$" && printf "%s" "$p" | grep -q "^Report: $4/reports/build/$2.json$" && ! printf "%s" "$p" | grep -q "^Context:" && [ ! -e "$4/context/v1" ] && printf "%s" "$p" | grep -q "^Spec: $4/spec/1.md$" && printf "%s" "$p" | grep -q "^Grills: $4/events/" && printf "%s" "$p" | grep -q "^Known failures: lint$"' _ "${BCALL}" "${BUILD}" "${TBPATH}" "${effort}"
check 'the first line says one per message' has "$(printf '%s' "${OUT}" | head -n 1)" 'Send one per message'
check 'a note for this session, not an event' sh -c '[ -f "$1/cold-$2.json" ] && ! sh "$3" --effort "$4" --type job.assigned | jq -e "length > 0"' _ "${NOTES}" "${BUILD}" "${ER}" "${effort}"
run "${DOOR}" --effort "${effort}" --job "${REVIEW}"
RCALL=$(printf '%s' "${OUT}" | tail -n 1)
check 'the review'"'"'s call, with its range' sh -c 'printf "%s" "$1" | jq -r .prompt | grep -q "^Range: [0-9a-f]\{40\}\.\.[0-9a-f]\{40\}$"' _ "${RCALL}"
mv "${S}/cfg/agents/${RT}.md" "${S}/work/rt.md"; rm -f "${NOTES}/cold-${REVIEW}.json"
run "${DOOR}" --effort "${effort}" --job "${REVIEW}"
check 'no agent file: refused, naming agent-files.sh' sh -c '[ "$1" -eq 2 ] && printf "%s" "$2" | grep -q "run jobs-agent-init.s agent-files.sh"' _ "${RC}" "${ERR}"
mv "${S}/work/rt.md" "${S}/cfg/agents/${RT}.md"
run "${DOOR}" --effort "${effort}" --job "${REVIEW}"
run "${DOOR}" --effort "${effort}" --job "${REVIEW}" --hot a0000001
check 'hot to an agent that never started: refused' has "${ERR}" "agent a0000001 never started a job: start a fresh agent"

echo "=== 5. the hooks"
ag() { jq -cn --arg t "$1" --arg d "$2" --arg p "$3" --arg iso "${4-worktree}" '{session_id: "sess-j1", tool_name: "Agent", tool_input: ({subagent_type: $t, description: $d, prompt: $p} + (if $iso == "" then {} else {isolation: $iso} end))}'; }
hook pre-tool-use start-from-door.sh "$(ag general-purpose x hello)"
check 'another agent'"'"'s Agent call: no decision' is "${OUT}" ''
hook pre-tool-use start-from-door.sh "$(ag "${BT}" "job-${BUILD}" 'Job 1, my own words.')"
check 'a job agent with a prompt not the door'"'"'s: denied' has "$(deny_of "${OUT}")" "this is not the call job-assign.sh printed for job ${BUILD}"
hook pre-tool-use start-from-door.sh "$(ag "${BT}" "job-999" 'x')"
check 'a job agent with no door call: denied' has "$(deny_of "${OUT}")" 'a job agent starts only from the call job-assign.sh printed'
hook pre-tool-use start-from-door.sh "$(ag "${BT}" "job-${BUILD}" "$(printf '%s' "${BCALL}" | jq -r .prompt)")"
check 'the door'"'"'s call: allowed, its note claimed' sh -c '[ -z "$1" ] && [ -f "$2/claimed-$3.json" ]' _ "${OUT}" "${NOTES}" "${BUILD}"
hook pre-tool-use start-from-door.sh "$(ag "${RT}" "job-${REVIEW}" "$(printf '%s' "${RCALL}" | jq -r .prompt)")"
check 'a second start in the same message: denied, one per message' has "$(deny_of "${OUT}")" 'one job agent per message'
cp -- "${NOTES}/claimed-${BUILD}.json" "${NOTES}/cold-${BUILD}.json"
hook pre-tool-use start-from-door.sh "$(ag "${BT}" "job-${BUILD}" "$(printf '%s' "${BCALL}" | jq -r .prompt)")"
check 'the same job again after Claude Code refused its start (the door run again): allowed, its claim taken over' sh -c '[ -z "$1" ] && [ -f "$2/claimed-$3.json" ] && [ ! -f "$2/cold-$3.json" ]' _ "${OUT}" "${NOTES}" "${BUILD}"
hook worktree-create job-tree.sh '{"session_id": "sess-j1", "name": "agent-x"}'
check 'the tree hook answers the claimed job'"'"'s tree' sh -c '[ "$1" -eq 0 ] && [ "$2" = "$3" ]' _ "${RC}" "${OUT}" "${TBPATH}"
hook subagent-start job-assigned.sh "$(jq -cn --arg t "${BT}" '{session_id: "sess-j1", agent_id: "ab00000001", agent_type: $t}')"
check 'the start writes agent.initialized: its base, type and plugins' sh -c 'sh "$1" --effort "$2" --type agent.initialized | jq -e --arg t "$3" ".[-1].body == {agent: \"ab00000001\", base: \"code-builder\", type: \$t, plugins: [\"language-kotlin\", \"language-kotlin-build\", \"framework-spring\", \"framework-spring-build\", \"standard-clean-code\", \"standard-clean-code-build\"]}"' _ "${ER}" "${effort}" "${BT}"
check 'and job.assigned: the job, the agent, the tree' sh -c 'sh "$1" --effort "$2" --type job.assigned | jq -e --argjson j "$3" --argjson t "$4" ".[-1].body == {job: \$j, agent: \"ab00000001\", tree: \$t}"' _ "${ER}" "${effort}" "${BUILD}" "${TB}"
check 'the claim is cleared' sh -c '! ls "$1"/claimed-*.json >/dev/null 2>&1' _ "${NOTES}"
hook worktree-create job-tree.sh "$(jq -cn --arg cwd "${repo}" '{session_id: "sess-j1", name: "agent-y", cwd: $cwd}')"
check 'a tree start no job claimed: steps aside, a plain worktree as Claude Code makes one' sh -c '[ "$1" -eq 0 ] && [ "$2" = "$3/.claude/worktrees/agent-y" ] && git -C "$2" rev-parse --abbrev-ref HEAD | grep -qx worktree-agent-y' _ "${RC}" "${OUT}" "${repo}"
hook worktree-create job-tree.sh '{"session_id": "sess-j1", "name": "agent-z", "cwd": "/"}'
check 'outside a repository: refused, saying so' sh -c '[ "$1" -eq 1 ] && printf "%s" "$2" | grep -q "is not in a git repository"' _ "${RC}" "${ERR}"
hook subagent-start job-assigned.sh "$(jq -cn --arg t "${BT}" '{session_id: "sess-j1", agent_id: "ab00000001", agent_type: $t}')"
check 'the agent resumed: no second agent.initialized' is "$(count "${effort}" agent.initialized)" 1
hook subagent-start job-assigned.sh '{"session_id": "sess-j1", "agent_id": "x1", "agent_type": "general-purpose"}'
check 'another agent'"'"'s start: nothing written' is "$(count "${effort}" agent.initialized)" 1
hook post-tool-use job-sent.sh '{"session_id": "sess-j1", "tool_name": "SendMessage", "tool_input": {"to": "ab00000001", "message": "hi"}}'
check 'a message the door didn'"'"'t print: nothing' sh -c '[ -z "$1" ] && [ -z "$2" ]' _ "${OUT}" "${ERR}"
rc=0; said=$(printf '%s\n' '{"agent": "z", "base": "code-builder", "type": "code-builder-x", "plugins": ["a"]}' >"${S}/work/ai.json"; sh "${K}/crucible-events/scripts/internal/event-write.sh" --effort "${effort}" --type agent.initialized --by me.sh --body-file "${S}/work/ai.json" 2>&1) || rc=$?
check 'only job-assigned.sh writes agent.initialized' sh -c '[ "$1" -eq 2 ] && printf "%s" "$2" | grep -q "written only by job-assigned.sh"' _ "${rc}" "${said}"

echo "=== 6. hot: a second review sent to the reviewer that ran the first"
rm -f "${NOTES}/cold-${REVIEW}.json"
run "${DOOR}" --effort "${effort}" --job "${REVIEW}"
RCALL=$(printf '%s' "${OUT}" | tail -n 1)
hook pre-tool-use start-from-door.sh "$(ag "${RT}" "job-${REVIEW}" "$(printf '%s' "${RCALL}" | jq -r .prompt)")"
hook subagent-start job-assigned.sh "$(jq -cn --arg t "${RT}" '{session_id: "sess-j1", agent_id: "ar00000001", agent_type: $t}')"
check 'the reviewer started cold: assigned to the review'"'"'s tree' sh -c 'sh "$1" --effort "$2" --type job.assigned | jq -e --argjson j "$3" --argjson t "$4" ".[-1].body == {job: \$j, agent: \"ar00000001\", tree: \$t}"' _ "${ER}" "${effort}" "${REVIEW}" "${TREE}"
# The first review handed in (its hand-in is the agent runs' to prove).
mkdir -p "${effort}/reports/review" && printf '{}\n' >"${effort}/reports/review/${REVIEW}.json"
jq -n --argjson j "${REVIEW}" --arg sha "$(shasum -a 256 "${effort}/reports/review/${REVIEW}.json" | cut -d " " -f 1)" \
	'{job: $j, iteration: 1, agent: "ar00000001", report: {path: "reports/review/\($j).json", sha256: $sha}}' >"${S}/work/sub.json"
sh "${K}/crucible-events/scripts/internal/event-write.sh" --effort "${effort}" --type review.submitted --by submission-event.sh --body-file "${S}/work/sub.json" >/dev/null || echo '    review.submitted refused'
jq -n --argjson p "${RP}" --argjson t "${TREE}" '{jobs: [{kind: "review", plugins: $p, work: {tree: {use: $t}}}]}' >"${S}/work/r2.json"
run "${J}/job-resolve.sh" --effort "${effort}" --jobs "${S}/work/r2.json"
card_and_answer "${effort}" "$(proposal_of "${OUT}")" 'Approve (Recommended)'
run "${J}/job-define.sh" --effort "${effort}" --gate "${GATE}"
R2=$(sh "${ER}" --effort "${effort}" --type job.defined | jq '.[-1].seq')
run "${DOOR}" --effort "${effort}" --job "${R2}" --hot ab00000001
check 'hot to the builder: refused, wrong base' has "${ERR}" "agent ab00000001 is a code-builder; job ${R2} needs a code-reviewer"
run "${DOOR}" --effort "${effort}" --job "${R2}" --hot ar00000001
HCALL=$(printf '%s' "${OUT}" | tail -n 1)
check 'hot to the reviewer: a SendMessage to it, the job as its message' sh -c '[ "$1" -eq 0 ] && printf "%s" "$2" | jq -e ".tool == \"SendMessage\" and .to == \"ar00000001\" and (.message | startswith(\"Job $3, a review.\"))"' _ "${RC}" "${HCALL}" "${R2}"
hook post-tool-use job-sent.sh "$(jq -cn --argjson c "${HCALL}" '{session_id: "sess-j1", tool_name: "SendMessage", tool_input: {to: $c.to, message: $c.message}}')"
check 'the send writes job.assigned: the job, the agent, the same tree' sh -c 'sh "$1" --effort "$2" --type job.assigned | jq -e --argjson j "$3" --argjson t "$4" ".[-1].body == {job: \$j, agent: \"ar00000001\", tree: \$t}"' _ "${ER}" "${effort}" "${R2}" "${TREE}"
check 'no second agent.initialized for the hot agent' is "$(sh "${ER}" --effort "${effort}" --type agent.initialized | jq '[.[] | select(.body.agent == "ar00000001")] | length')" 1
jq -n --argjson p "${RP}" --argjson t "${TB}" '{jobs: [{kind: "review", plugins: $p, work: {tree: {use: $t}}}]}' >"${S}/work/r3.json"
run "${J}/job-resolve.sh" --effort "${effort}" --jobs "${S}/work/r3.json"
card_and_answer "${effort}" "$(proposal_of "${OUT}")" 'Approve (Recommended)'
run "${J}/job-define.sh" --effort "${effort}" --gate "${GATE}"
R3=$(sh "${ER}" --effort "${effort}" --type job.defined | jq '.[-1].seq')
run "${DOOR}" --effort "${effort}" --job "${R3}" --hot ar00000001
check 'hot while it still works on job R2: refused, one open job per agent' has "${ERR}" "agent ar00000001 still works on job ${R2}: one open job per agent"

echo
echo "${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
