#!/usr/bin/env sh
# Evidence run for jobs step 1, the job defined, through the installed
# layout: a scratch Claude folder linked with install-entries.sh's own
# commands, a scratch space and effort with a real grill, context cut, spec
# and tree, and the jobs gate answered through the installed gate hooks.
# Only scratch: its own HOME, no key. Exits 1 when any expectation fails.
# shellcheck disable=SC2016,SC2312 # single-quoted jq and sh -c are meant literally; a read inside a check is what the check compares
set -u
R=/Users/cordona/IdeaProjects/cordona/claude-code-crucible/new-rewrite
S=$(mktemp -d "${TMPDIR:-/tmp}/jobs-1.XXXXXX") || exit 2
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
cut="{\"cut\": {\"repo\": \"${repo}\", \"from\": \"ref:main\"}}"

echo "=== 1. three builds resolve, show, are approved and defined"
jq -n --argjson p "${P}" --argjson cut "${cut}" --argjson t "${TREE}" \
	'{jobs: [{kind: "build", plugins: $p, work: {tree: $cut}}, {kind: "build", plugins: ($p | .standards = ["security"]), work: {tree: $cut}},
		{kind: "build", plugins: $p, work: {tree: {use: $t}}}]}' >"${S}/work/three.json"
run "${J}/job-resolve.sh" --effort "${effort}" --jobs "${S}/work/three.json"
check 'resolved: 3 jobs' has "${OUT}" '3 jobs resolved: '
P1=$(proposal_of "${OUT}")
check 'the proposal is named by its sha256' is "${P1##*/}" "$(shasum -a 256 "${P1}" | cut -d ' ' -f 1).json"
check 'each job takes the latest context, spec and grills' jq -e --argjson c "${CTX}" --argjson s "${SPEC}" --argjson g "${GRILL}" \
	'all(.jobs[]; .input_refs == {context: $c, spec: $s, grills: [$g]})' "${P1}"
check 'iterations: 1 on each cut tree, 2 on the used tree' jq -e '[.jobs[].work.loop.iteration] == [1, 1, 2]' "${P1}"
card_and_answer "${effort}" "${P1}" 'Approve (Recommended)'
sed 's/^/    card: /' "${S}/work/card.md" | show
check 'the gate holds the jobs record and the proposal sha256' sh -c 'sh "$1" --effort "$2" --type gate.answered | jq -e --arg s "$3" ".[-1].body | .record == \"jobs\" and .subject == \$s and .accepted == true"' _ "${ER}" "${effort}" "$(shasum -a 256 "${P1}" | cut -d ' ' -f 1)"
run "${J}/job-define.sh" --effort "${effort}" --gate "${GATE}"
check 'defined: 3 jobs, the two cut trees still to cut' sh -c '[ "$1" -eq 0 ] && printf "%s" "$2" | grep -q "^jobs .* defined$" && [ "$(printf "%s" "$2" | grep -c "still to be cut")" -eq 2 ]' _ "${RC}" "${OUT}"
check 'the log has 3 job.defined, positions 1-3 of the gate' sh -c 'sh "$1" --effort "$2" --type job.defined | jq -e --argjson g "$3" "[.[].body.approval_gate] == [{ref: \$g, position: 1}, {ref: \$g, position: 2}, {ref: \$g, position: 3}]"' _ "${ER}" "${effort}" "${GATE}"
check 'each job.defined is its proposal entry plus its approval_gate' sh -c 'sh "$1" --effort "$2" --type job.defined | jq -e --slurpfile p "$3" "[.[].body | del(.approval_gate)] == \$p[0].jobs"' _ "${ER}" "${effort}" "${P1}"

echo "=== 2. one wrong job refuses the whole proposal"
before=$(ls "${effort}/proposals" | wc -l | tr -d ' ')
jq -n --argjson p "${P}" --argjson cut "${cut}" \
	'{jobs: [{kind: "build", plugins: $p, work: {tree: $cut}}, {kind: "reveiw", plugins: $p, work: {tree: $cut}},
		{kind: "build", plugins: {language: "kotlin"}, work: {tree: {use: 1}}, input_refs: {lens: 3}}]}' >"${S}/work/wrong.json"
run "${J}/job-resolve.sh" --effort "${effort}" --jobs "${S}/work/wrong.json"
check 'refused with exit 2' is "${RC}" 2
check 'job 2: not a kind, the kinds named' has "${ERR}" "job 2: kind \"reveiw\" is not a kind; kinds: build"
check 'job 3: every fault on its own line' sh -c 'printf "%s" "$1" | grep -q "job 3: plugins.standards" && printf "%s" "$1" | grep -q "job 3: work.tree.use must be the seq of a worktree.cut" && printf "%s" "$1" | grep -q "job 3: a build takes no lens ref"' _ "${ERR}"
check 'nothing written' is "$(ls "${effort}/proposals" | wc -l | tr -d ' ')" "${before}"

echo "=== 3. the proposal changed after its card: define refuses"
jq -n --argjson p "${P}" --argjson cut "${cut}" '{jobs: [{kind: "build", plugins: $p, work: {tree: $cut}}]}' >"${S}/work/one.json"
run "${J}/job-resolve.sh" --effort "${effort}" --jobs "${S}/work/one.json"
P3=$(proposal_of "${OUT}")
card_and_answer "${effort}" "${P3}" 'Approve (Recommended)'
chmod u+w "${P3}" && printf ' ' >>"${P3}"
n=$(count "${effort}" job.defined)
run "${J}/job-define.sh" --effort "${effort}" --gate "${GATE}"
check 'refused: the card showed one sha256, the file is now another' sh -c '[ "$1" -eq 2 ] && printf "%s" "$2" | grep -q "the card showed .*, the file is now .*: resolve again"' _ "${RC}" "${ERR}"
check 'nothing defined' is "$(count "${effort}" job.defined)" "${n}"

echo "=== 4. a gate's jobs defined twice: refused"
run "${J}/job-define.sh" --effort "${effort}" --gate "$(sh "${ER}" --effort "${effort}" --type job.defined | jq '.[0].body.approval_gate.ref')"
check 'refused: already defined, the seqs named' sh -c '[ "$1" -eq 2 ] && printf "%s" "$2" | grep -q "jobs are already defined: "' _ "${RC}" "${ERR}"

echo "=== 5. a rejected gate: define refuses, nothing written"
run "${J}/job-resolve.sh" --effort "${effort}" --jobs "${S}/work/one.json"
P5=$(proposal_of "${OUT}")
check 'the same jobs resolve to the same name, the changed file written again' sh -c '[ "$1" -eq 0 ] && [ "$2" = "$3" ] && [ "$(shasum -a 256 "$3" | cut -d " " -f 1).json" = "${3##*/}" ]' _ "${RC}" "${P5}" "${P3}"
card_and_answer "${effort}" "${P5}" 'Change it'
n=$(count "${effort}" job.defined)
run "${J}/job-define.sh" --effort "${effort}" --gate "${GATE}"
check 'refused: not approved, nothing to define' sh -c '[ "$1" -eq 2 ] && printf "%s" "$2" | grep -q "not approved: nothing to define"' _ "${RC}" "${ERR}"
check 'nothing defined' is "$(count "${effort}" job.defined)" "${n}"

echo "=== 6. the stale case: two proposals, each a build on the same tree"
jq -n --argjson p "${P}" --argjson t "${TREE}" '{jobs: [{kind: "build", plugins: $p, work: {tree: {use: $t}}}]}' >"${S}/work/stale-a.json"
jq -n --argjson p "${P}" --argjson t "${TREE}" '{jobs: [{kind: "build", plugins: ($p | .standards = ["security"]), work: {tree: {use: $t}}}]}' >"${S}/work/stale-b.json"
run "${J}/job-resolve.sh" --effort "${effort}" --jobs "${S}/work/stale-a.json"; PA=$(proposal_of "${OUT}")
run "${J}/job-resolve.sh" --effort "${effort}" --jobs "${S}/work/stale-b.json"; PB=$(proposal_of "${OUT}")
check 'both resolved to iteration 3' sh -c 'jq -e ".jobs[0].work.loop.iteration == 3" "$1" && jq -e ".jobs[0].work.loop.iteration == 3" "$2"' _ "${PA}" "${PB}"
card_and_answer "${effort}" "${PA}" 'Approve (Recommended)'; GA=${GATE}
card_and_answer "${effort}" "${PB}" 'Approve (Recommended)'; GB=${GATE}
run "${J}/job-define.sh" --effort "${effort}" --gate "${GA}"
check 'the first is defined' is "${RC}" 0
run "${J}/job-define.sh" --effort "${effort}" --gate "${GB}"
check 'the second is refused at the write, with the iteration it should have' sh -c '[ "$1" -eq 2 ] && printf "%s" "$2" | grep -q "work.loop.iteration must be 4, the next build.s on its tree: resolve again"' _ "${RC}" "${ERR}"

echo "=== 7. no spec and no grills resolves; no context is refused"
small=$(sh "${K}/crucible-effort/scripts/main/effort-start.sh" --name 'small one')
sh "${K}/code-context/scripts/main/context-add-commit.sh" --effort "${small}" --repo "${repo}" --ref HEAD >/dev/null 2>&1
FP=$(sh "${K}/crucible-context/scripts/main/context-fingerprint.sh" --effort "${small}" | sed -n 's/FINGERPRINT: //p')
decide "${small}" context-done "${FP}" "${S}/work/ctx-card.md" 'Approve (Recommended)'
sh "${K}/crucible-context/scripts/main/context-cut.sh" --effort "${small}" >/dev/null
run "${J}/job-resolve.sh" --effort "${small}" --jobs "${S}/work/one.json"
check 'resolved, with context only' sh -c '[ "$1" -eq 0 ] && jq -e ".jobs[0].input_refs | keys == [\"context\"]" "$2"' _ "${RC}" "$(proposal_of "${OUT}")"
bare=$(sh "${K}/crucible-effort/scripts/main/effort-start.sh" --name 'bare one')
run "${J}/job-resolve.sh" --effort "${bare}" --jobs "${S}/work/one.json"
check 'refused: a build needs context, and the line says what is missing' sh -c '[ "$1" -eq 2 ] && printf "%s" "$2" | grep -q "job 1: a build needs context: there is no context.cut yet"' _ "${RC}" "${ERR}"

echo "=== 8. two builds on one tree in one proposal: refused"
jq -n --argjson p "${P}" --argjson t "${TREE}" '{jobs: [{kind: "build", plugins: $p, work: {tree: {use: $t}}}, {kind: "build", plugins: $p, work: {tree: {use: $t}}}]}' >"${S}/work/two.json"
run "${J}/job-resolve.sh" --effort "${effort}" --jobs "${S}/work/two.json"
check 'refused: one writing job per tree' sh -c '[ "$1" -eq 2 ] && printf "%s" "$2" | grep -q "jobs 1 and 2 write in tree .*: one writing job per tree"' _ "${RC}" "${ERR}"

echo "=== 9. the rule alone: only job-define.sh writes job.defined"
printf '%s\n' '{"kind": "build"}' >"${S}/work/forged.json"
rc=0; said=$(sh "${K}/crucible-events/scripts/internal/event-write.sh" --effort "${effort}" --type job.defined --by me.sh --body-file "${S}/work/forged.json" 2>&1) || rc=$?
check 'refused, naming the writer' sh -c '[ "$1" -eq 2 ] && printf "%s" "$2" | grep -q "job.defined is written only by job-define.sh"' _ "${rc}" "${said}"

echo "=== 10. the remote kinds: a foreign review gets its tree and range from its change; an external review names its review"
EVW="${K}/crucible-events/scripts/internal/event-write.sh"
HEADC=$(git -C "${repo}" rev-parse HEAD)
pin() { # pin KIND JSON: the next seq's pinned file; prints its sha256
	n=$(($(sh "${ER}" --effort "${effort}" --paths | wc -l | tr -d ' ') + 1))
	mkdir -p "${effort}/reports/$1"; printf '%s\n' "$2" >"${effort}/reports/$1/${n}.json"; chmod 444 "${effort}/reports/$1/${n}.json"
	shasum -a 256 "${effort}/reports/$1/${n}.json" | cut -d ' ' -f 1
}
sha=$(pin remote-change '{"title": "t", "description": "d", "base_branch": "main", "state": "open"}')
n=$(($(sh "${ER}" --effort "${effort}" --paths | wc -l | tr -d ' ') + 1))
jq -n --arg repo "${repo}" --arg h "${HEADC}" --arg sha "${sha}" --argjson n "${n}" '{host: "github", url: "https://github.com/o/r/pull/7", repo: $repo, number: 7,
	base: $h, head: $h, author: "someone", report: {path: "reports/remote-change/\($n).json", sha256: $sha}}' >"${S}/work/rc.json"
sh "${EVW}" --effort "${effort}" --type remote-change.fetched --by change-fetch.sh --body-file "${S}/work/rc.json" >/dev/null
CHG=${n}
sha=$(pin remote-review '{"threads": []}')
n=$(($(sh "${ER}" --effort "${effort}" --paths | wc -l | tr -d ' ') + 1))
jq -n --argjson c "${CHG}" --arg h "${HEADC}" --arg sha "${sha}" --argjson n "${n}" '{change: $c, head: $h, threads: 0, bots: [],
	report: {path: "reports/remote-review/\($n).json", sha256: $sha}}' >"${S}/work/rr.json"
sh "${EVW}" --effort "${effort}" --type remote-review.fetched --by review-fetch.sh --body-file "${S}/work/rr.json" >/dev/null
REV=${n}
L='{"language": "shell", "standards": ["security"]}'
jq -n --argjson p "${L}" --argjson c "${CHG}" '{jobs: [{kind: "foreign-review", plugins: $p, input_refs: {change: $c}}]}' >"${S}/work/foreign.json"
run "${J}/job-resolve.sh" --effort "${effort}" --jobs "${S}/work/foreign.json"
PF=$(proposal_of "${OUT}")
check 'a foreign review resolves: its tree cut from the change head in its repo, its range the change base..head' jq -e --arg repo "${repo}" --arg h "${HEADC}" --argjson c "${CHG}" \
	'.jobs[0] | .work.tree == {cut: {repo: $repo, from: "ref:\($h)"}} and .work.range == {base: $h, head: $h} and .input_refs.change == $c' "${PF}"
card_and_answer "${effort}" "${PF}" 'Approve (Recommended)'
run "${J}/job-define.sh" --effort "${effort}" --gate "${GATE}"
check 'defined: job.defined takes a range on a tree it cuts' sh -c '[ "$1" -eq 0 ] && sh "$2" --effort "$3" --type job.defined | jq -e ".[-1].body | .kind == \"foreign-review\" and (.work.range | type) == \"object\" and .work.tree.cut != null"' _ "${RC}" "${ER}" "${effort}"
jq -n --argjson p "${L}" --argjson c "${CHG}" --argjson t "${TREE}" '{jobs: [{kind: "foreign-review", plugins: $p, input_refs: {change: $c}, work: {tree: {use: $t}}}]}' >"${S}/work/foreign-work.json"
run "${J}/job-resolve.sh" --effort "${effort}" --jobs "${S}/work/foreign-work.json"
check 'refused: a foreign review takes no work from main' sh -c '[ "$1" -eq 2 ] && printf "%s" "$2" | grep -q "job 1: a foreign-review takes no work: its tree and range come from its change"' _ "${RC}" "${ERR}"
jq -n --argjson p "${L}" '{jobs: [{kind: "foreign-review", plugins: $p}]}' >"${S}/work/foreign-none.json"
run "${J}/job-resolve.sh" --effort "${effort}" --jobs "${S}/work/foreign-none.json"
check 'refused: a foreign review must name its change' sh -c '[ "$1" -eq 2 ] && printf "%s" "$2" | grep -q "job 1: a foreign-review needs change: name the seq of its remote-change.fetched"' _ "${RC}" "${ERR}"
jq -n --argjson p "${L}" --argjson r "${REV}" --argjson t "${TREE}" '{jobs: [{kind: "external-review", plugins: $p, input_refs: {review: $r}, work: {tree: {use: $t}}}]}' >"${S}/work/external.json"
run "${J}/job-resolve.sh" --effort "${effort}" --jobs "${S}/work/external.json"
check 'an external review resolves on the tree main names: the review named, the range its change'"'"'s base..head' jq -e --argjson r "${REV}" --arg h "${HEADC}" --argjson t "${TREE}" \
	'.jobs[0] | .input_refs.review == $r and .work.range == {base: $h, head: $h} and .work.tree == {use: $t}' "$(proposal_of "${OUT}")"
check 'its change ref is filled from the review'"'"'s own change, for the prompt to name its description' jq -e --argjson c "${CHG}" '.jobs[0].input_refs.change == $c' "$(proposal_of "${OUT}")"
check 'no earlier ref at the first judgement of the change' jq -e '.jobs[0].input_refs | has("earlier") | not' "$(proposal_of "${OUT}")"
jq --argjson c "${CHG}" '.jobs[0].input_refs.change = $c' "${S}/work/external.json" >"${S}/work/external-change.json"
run "${J}/job-resolve.sh" --effort "${effort}" --jobs "${S}/work/external-change.json"
check 'refused: main gives no change ref, it comes from the review' sh -c '[ "$1" -eq 2 ] && printf "%s" "$2" | grep -q "job 1: change comes from its review; give no change ref"' _ "${RC}" "${ERR}"
jq -n --argjson p '{"language": "shell", "standards": ["security", "clean-code"]}' --argjson r "${REV}" --argjson t "${TREE}" '{jobs: [{kind: "external-review", plugins: $p, input_refs: {review: $r}, work: {tree: {use: $t}}}]}' >"${S}/work/external-two.json"
run "${J}/job-resolve.sh" --effort "${effort}" --jobs "${S}/work/external-two.json"
check 'refused: an external review reads through one standard' sh -c '[ "$1" -eq 2 ] && printf "%s" "$2" | grep -q "reads through one standard"' _ "${RC}" "${ERR}"
# A judgement of the change handed in: the next one gets it as its earlier ref.
PE=$(proposal_of "$(sh "${J}/job-resolve.sh" --effort "${effort}" --jobs "${S}/work/external.json")")
card_and_answer "${effort}" "${PE}" 'Approve (Recommended)'
sh "${J}/job-define.sh" --effort "${effort}" --gate "${GATE}" >/dev/null
EJ=$(sh "${ER}" --effort "${effort}" --type job.defined | jq '.[-1].seq')
sha=$(pin external-review '{"items": []}')
n=$(($(sh "${ER}" --effort "${effort}" --paths | wc -l | tr -d ' ') + 1))
printf '%s\n' "{\"job\": ${EJ}, \"agent\": \"ae00000001\", \"tree\": ${TREE}}" >"${S}/work/ea.json"
printf '%s\n' '{"agent": "ae00000001", "base": "code-reviewer", "type": "code-reviewer-shell-security", "plugins": []}' >"${S}/work/ei.json"
sh "${EVW}" --effort "${effort}" --type agent.initialized --by job-assigned.sh --body-file "${S}/work/ei.json" >/dev/null
sh "${EVW}" --effort "${effort}" --type job.assigned --by job-assigned.sh --body-file "${S}/work/ea.json" >/dev/null
n=$(($(sh "${ER}" --effort "${effort}" --paths | wc -l | tr -d ' ') + 1))
mv "${effort}/reports/external-review/$((n - 2)).json" "${effort}/reports/external-review/${EJ}.json"
jq -n --argjson j "${EJ}" --arg sha "${sha}" '{job: $j, iteration: 1, agent: "ae00000001", report: {path: "reports/external-review/\($j).json", sha256: $sha}}' >"${S}/work/es.json"
sh "${EVW}" --effort "${effort}" --type external-review.submitted --by submission-event.sh --body-file "${S}/work/es.json" >/dev/null
SUB=$(sh "${ER}" --effort "${effort}" --type external-review.submitted | jq '.[-1].seq')
run "${J}/job-resolve.sh" --effort "${effort}" --jobs "${S}/work/external.json"
check 'the next judgement of the change gets the last one handed in as its earlier ref' jq -e --argjson s "${SUB}" '.jobs[0].input_refs.earlier == $s' "$(proposal_of "${OUT}")"
jq --argjson s "${SUB}" '.jobs[0].input_refs.earlier = $s' "${S}/work/external.json" >"${S}/work/external-earlier.json"
run "${J}/job-resolve.sh" --effort "${effort}" --jobs "${S}/work/external-earlier.json"
check 'refused: main gives no earlier ref' sh -c '[ "$1" -eq 2 ] && printf "%s" "$2" | grep -q "job 1: earlier is the last one of the same change; give no earlier ref"' _ "${RC}" "${ERR}"

echo
echo "${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
