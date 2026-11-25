#!/usr/bin/env sh
# Evidence run for the test agent's submission, through the installed
# layout, as the builder's run is: a scratch Claude folder linked with
# install-entries.sh's own commands, a scratch space, effort and repository,
# the jobs written through the real event writer, and each case fed to the
# real SubagentStop hook as Claude Code feeds it. Each tree gets a real build
# first; the plan's approval is a gate.answered written as the core gate's
# rule allows. Only scratch: its own HOME and git config, no key. Exits 1
# when any expectation fails.
# shellcheck disable=SC2016,SC2312 # single-quoted jq, sh -c and file text are meant literally; a read inside a check is what the check compares
set -u
R=/Users/cordona/IdeaProjects/cordona/claude-code-crucible/new-rewrite
E=$(cd -- "$(dirname -- "$0")" && pwd)
F="${E}/fixtures"
S=$(mktemp -d "${TMPDIR:-/tmp}/test-agent.XXXXXX") || exit 2
S=$(cd -P -- "${S}" && pwd -P)
trap 'rm -rf -- "${S}"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "${S}/home" "${S}/cfg" "${S}/work"
export HOME="${S}/home" GIT_CONFIG_GLOBAL="${S}/home/.gitconfig" GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME="${S}/home/.config"
export CRUCIBLE_HOME="${S}/space" CLAUDE_CONFIG_DIR="${S}/cfg" CLAUDE_CODE_SESSION_ID=sess-ta
unset SSH_AUTH_SOCK SSH_AGENT_PID GIT_DIR GIT_WORK_TREE GPG_TTY
cd / || exit 2
K="${S}/cfg/skills"

pass=0 fail=0
show() { sed "s|${S}|<S>|g;s|${K}/|<skills>/|g;s|${R}|<R>|g"; }
check() { # check WHAT COMMAND...: PASS when the command succeeds
	what=$1; shift
	if "$@" >/dev/null 2>&1; then pass=$((pass + 1)); echo "  PASS: ${what}"
	else fail=$((fail + 1)); echo "  FAIL: ${what}"; fi
}
is() { [ "$1" = "$2" ]; }
has() { printf '%s' "$1" | grep -qF -- "$2"; }
sum256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum -- "$1" | cut -d ' ' -f 1; else shasum -a 256 -- "$1" | cut -d ' ' -f 1; fi; }

EW="${K}/crucible-events/scripts/internal/event-write.sh"
ER="${K}/crucible-events/scripts/internal/events-read.sh"
JOB_OF="${K}/agent-jobs/scripts/internal/job-of.sh"
VIEW="${K}/agent-jobs/scripts/internal/events-view.sh"
HOOK="${K}/agent-submission/hooks/subagent-stop/submit-agent-work.sh"
VAL="${K}/code-tester/scripts/internal"

echo "=== install: install-entries.sh's own links and settings, then install-check.sh"
sh "${R}/framework/core/install/install-entries.sh" | sed -n '/^# Links/,/^$/p' | sed '1d' >"${S}/links.sh"
sh "${R}/framework/core/install/install-entries.sh" | sed -n '/^# Settings/,/^$/p' | sed '1d' >"${S}/settings.json"
sh "${S}/links.sh"
sh "${R}/framework/core/install/install-entries.sh" --json >"${S}/entries.json"
check 'install-entries.sh lists code-tester' jq -e 'any(.skills[]; .name == "code-tester")' "${S}/entries.json"
sh "${R}/framework/core/install/install-check.sh" --settings "${S}/settings.json" >"${S}/check.out" 2>&1
check 'install-check.sh agrees: installed' is "$(cat "${S}/check.out")" installed
check 'code-tester lists what it hands in, one submissions file per kind' sh -c '[ "$(ls "$1/code-tester/submissions")" = "$(printf "test-fix.json\ntest-plan-update.json\ntest-plan.json\ntest.json")" ]' _ "${K}"
for pair in test-plan:test-plan.submitted test-plan-update:test-plan.updated test:test.submitted test-fix:test-fix.submitted; do
	kind=${pair%%:*} event=${pair#*:}
	check "code-tester's submissions/${kind}.json names ${event}, its rules, def and facts, all installed" sh -c 'f="$1/code-tester/submissions/$2.json"; jq -e --arg e "$3" ".event == \$e and (.commit | type) == \"boolean\" and (.problems | type) == \"string\"" "$f" && [ -f "$1/$(jq -r .rules "$f").jq" ] && [ -f "$1/$(jq -r .facts "$f")" ] && [ -f "$1/code-tester/events/$3.jq" ]' _ "${K}" "${kind}" "${event}"
done
check 'a plan job does not commit; a test job and a test-fix do' is "$(for k in test-plan test-plan-update test test-fix; do jq -r .commit "${K}/code-tester/submissions/${k}.json"; done | tr '\n' ' ')" 'false false true true '
check 'code-tester owns its rules: a common lib and one rules file per kind' sh -c 'cd "$1/code-tester/scripts/lib" && [ "$(ls)" = "$(printf "test-fix-report.jq\ntest-plan-report.jq\ntest-plan-update-report.jq\ntest-report.jq\ntester-common.jq")" ]' _ "${K}"
check 'code-tester holds no per-kind scripts: its kinds are data' sh -c '[ "$(ls "$1/code-tester/scripts/internal")" = tester-facts.sh ]' _ "${K}"
check 'the kind and its event are paired only in the submission file' sh -c '! grep -rqE "jobs_submission_problems\(" "$1/code-tester/events"' _ "${K}"
check 'neither agent names the other component; the tester names only the builder'"'"'s kinds' sh -c '! grep -rq "code-builder" "$1/code-tester/" && ! grep -rq "code-tester" "$1/code-builder/" && ! grep -rqE "code-(builder|tester)" "$1/agent-submission/"' _ "${K}"
check 'no agent includes another agent'"'"'s rules: every tester include is its own' sh -c 'grep -rh "^include" "$1/code-tester/scripts/lib" "$1/code-tester/events" | grep -vE "include \"(code-tester|agent-jobs)/" | grep -q . && exit 1; exit 0' _ "${K}"
check 'nothing in agent-submission or agent-jobs names an agent or one of its kinds, but build' sh -c '! grep -rqE "code-builder|code-tester|build-fix|test-fix|test-plan|\"test\"|\"fix\"" "$1/agents/agent-submission" "$1/main-thread/agent-jobs"' _ "${R}/domains/software-development/core"

echo "=== every tester script answers --help"
for script in "${VAL}"/*.sh; do
	out=$(sh "${script}" --help 2>&1); rc=$?
	check "${script##*/} --help" sh -c '[ "$1" -eq 0 ] && printf "%s" "$2" | grep -q "^usage: " && printf "%s" "$2" | grep -q "^Exit:"' _ "${rc}" "${out}"
done

echo "=== set-up: a scratch repository, an effort, its identity (no key), five trees, each with a real build"
repo="${S}/repo"
git init -q -b main "${repo}"
mkdir -p "${repo}/app/Upload" "${repo}/tests/Upload" "${repo}/tests/fixtures"
awk 'BEGIN { for (i = 1; i <= 88; i++) printf "// Client.php line %d\n", i }' >"${repo}/app/Upload/Client.php"
awk 'BEGIN { for (i = 1; i <= 30; i++) printf "// Auth.php line %d\n", i }' >"${repo}/app/Upload/Auth.php"
awk 'BEGIN { for (i = 1; i <= 90; i++) printf "// UploadClientTest.php line %d\n", i }' >"${repo}/tests/Upload/UploadClientTest.php"
printf '// OldClientTest.php\n' >"${repo}/tests/Upload/OldClientTest.php"
printf '{"status": 503}\n' >"${repo}/tests/fixtures/503.json"
git -C "${repo}" add -A
git -C "${repo}" -c user.name=Fixture -c user.email=fixture@example.test commit -q -m 'the project'
effort=$(sh "${K}/crucible-effort/scripts/main/effort-start.sh" --name 'upload retries') || { echo 'effort-start failed'; exit 1; }
effort_name=${effort##*/}
repo_main=$(sh "${K}/dev-base/scripts/internal/repo-of.sh" --dir "${repo}" | jq -r '.repo')
jq -n --arg repo "${repo_main}" '{repo: $repo, name: "Test Agent", email: "test-agent@example.test",
	signing: {format: "ssh", key: "/nonexistent/fixture-key.pub"}, fingerprint: "", answer: 1}' >"${S}/identity.json"
sh "${EW}" --effort "${effort}" --type identity.set --by identity-set.sh --body-file "${S}/identity.json" >/dev/null
TREES='upload scope bug mutation rows'
for t in ${TREES}; do
	sh "${K}/git-worktree/scripts/main/worktree-cut.sh" --effort "${effort}" --repo "${repo}" --name "${t}" --from checkout >/dev/null \
		|| { echo "worktree-cut ${t} failed"; exit 1; }
done
tree_of() { printf '%s/worktrees/%s' "${effort}" "$1"; }
SETUP='{"language": "php", "frameworks": ["laravel"], "standards": ["testing", "security"]}'

events_count() { sh "${ER}" --effort "${effort}" --paths | wc -l | tr -d ' '; }
# dispatch KIND AGENT_TYPE TREE AGENT NAME ITERATION [EXTRA_JSON]: writes
# job.dispatched and job.assigned through the real event writer; sets JOB,
# AGENT, AGENT_TYPE, TREE and REPORT. Returns 1 when the dispatch is refused,
# its reason in DISPATCH_SAID.
dispatch() {
	JOB=$(($(events_count) + 1)) AGENT_TYPE=$2 TREE=$(tree_of "$3") AGENT=$4
	extra=${7-}
	[ -n "${extra}" ] || extra='{}'
	jq -n --arg kind "$1" --arg type "$2" --arg tree "${TREE}" --arg report "reports/$1/${JOB}.json" \
		--argjson iteration "$6" --argjson extra "${extra}" --argjson setup "${SETUP}" '
		{kind: $kind, agent_type: $type, tree: $tree, report: $report}
		+ ($extra | with_entries(select(.key != "fix_round")))
		+ {known_failures: [], iteration: $iteration}
		+ ($extra | with_entries(select(.key == "fix_round")))
		+ {setup: $setup}' >"${S}/work/dispatched.json"
	DISPATCH_SAID=$(sh "${EW}" --effort "${effort}" --type job.dispatched --by job-dispatch.sh --body-file "${S}/work/dispatched.json" 2>&1) \
		|| return 1
	jq -n --argjson job "${JOB}" --arg agent "$4" --arg name "$5" '{job: $job, agent: $agent, name: $name, session: "sess-ta"}' >"${S}/work/assigned.json"
	sh "${EW}" --effort "${effort}" --type job.assigned --by assign-job.sh --body-file "${S}/work/assigned.json" >/dev/null \
		|| { echo "    job.assigned ${JOB} refused"; fail=$((fail + 1)); return 1; }
	REPORT="${effort}/reports/$1/${JOB}.json"
}
# The agent hands in: its report from fixtures/reports/$1.
write_report() { mkdir -p "${REPORT%/*}"; rm -f -- "${REPORT}"; cp -- "${F}/reports/$1.json" "${REPORT}"; chmod 600 "${REPORT}"; }
# The agent's work in the tree: one appended line per file named.
work_on() { for file in "$@"; do mkdir -p "${TREE}/${file%/*}"; printf '// work %s\n' "${JOB}" >>"${TREE}/${file}"; done; }
# Feeds the hook the JSON Claude Code gives a SubagentStop; case folder $1.
stop() {
	BEFORE=$(events_count)
	HEAD_BEFORE=$(git -C "${TREE}" rev-parse HEAD)
	jq -cn --arg agent "${AGENT}" --arg type "${AGENT_TYPE}" --arg cwd "${TREE}" --arg s "${S}" '{session_id: "sess-ta",
		transcript_path: ($s + "/transcript.jsonl"), cwd: $cwd, permission_mode: "acceptEdits",
		hook_event_name: "SubagentStop", stop_hook_active: false, agent_id: $agent, agent_type: $type,
		agent_transcript_path: ($s + "/agent-\($agent).jsonl"), last_assistant_message: "Done; my report is written."}' \
		| sh "${HOOK}" >"${S}/work/hook.out" 2>"${S}/work/hook.err"
	HOOK_RC=$?
	HOOK_OUT=$(cat "${S}/work/hook.out")
	[ -z "$1" ] || save "$1"
	EVENT=$(sh "${ER}" --effort "${effort}" | jq -c --argjson n "${BEFORE}" '[.[] | select(.seq > $n)] | last // empty')
}
# Saves case folder $1: report.json, hook-output.txt, event.json, commit.txt.
save() {
	dir="${E}/$1"
	rm -rf -- "${dir}"; mkdir -p "${dir}"
	if [ -f "${REPORT}" ]; then cp -- "${REPORT}" "${dir}/report.json"; chmod 644 "${dir}/report.json"; else echo none >"${dir}/report.json"; fi
	{ cat "${S}/work/hook.out"; [ ! -s "${S}/work/hook.err" ] || sed 's/^/stderr: /' "${S}/work/hook.err"; echo "exit ${HOOK_RC}"; } | show >"${dir}/hook-output.txt"
	sh "${ER}" --effort "${effort}" | jq --argjson n "${BEFORE}" '[.[] | select(.seq > $n)] | if length == 0 then "none" else . end' \
		| show >"${dir}/event.json"
	if [ "$(git -C "${TREE}" rev-parse HEAD)" != "${HEAD_BEFORE}" ]; then
		{ git -C "${TREE}" log -1 --format=%B; git -C "${TREE}" show --stat --format='commit %H%nAuthor: %an <%ae>%nSigned: %G?' HEAD; } | show >"${dir}/commit.txt"
	else
		echo none >"${dir}/commit.txt"
	fi
	sed 's/^/    /' "${dir}/hook-output.txt"
}
ev() { printf '%s' "${EVENT}" | jq -r "$1"; }
held() { [ "$(printf '%s' "${HOOK_OUT}" | jq -r '.decision // ""')" = block ]; }
accepted() { [ -z "${HOOK_OUT}" ] && [ "${HOOK_RC}" -eq 0 ]; }
reason() { printf '%s' "${HOOK_OUT}" | jq -r '.reason // ""'; }
message_of() { git -C "${TREE}" log -1 --format=%B; }
# approve SEQ: the human's yes at the plan gate, as the core gate writes it.
approve() {
	jq -n --arg seq "$1" '{record: "test-plan", subject: $seq, question: "Approve the test plan?",
		accept: "Approve (Recommended)", answer: "Approve (Recommended)", accepted: true}' >"${S}/work/answer.json"
	sh "${EW}" --effort "${effort}" --type gate.answered --by record-gate-answer.sh --body-file "${S}/work/answer.json" >/dev/null
}
# prepare TREE N: a real build on TREE, through the hook, then a basic plan
# for it, approved; sets PLAN to the plan event's seq.
prepare() {
	dispatch build code-builder "$1" "b0${2}000000" "build-php-b0${2}000" 1 || { echo "    build on $1 refused: ${DISPATCH_SAID}"; return 1; }
	work_on app/Upload/Client.php tests/Upload/UploadClientTest.php
	write_report build; stop ''
	dispatch test-plan code-tester "$1" "c0${2}000000" "test-plan-php-c0${2}000" 1 || { echo "    plan on $1 refused: ${DISPATCH_SAID}"; return 1; }
	write_report plan-basic; stop ''
	PLAN=$(ev '.seq')
	approve "${PLAN}"
}

prepare scope 1 || { echo 'prepare scope failed'; exit 1; }
PLAN_SCOPE=${PLAN}
prepare bug 2 || { echo 'prepare bug failed'; exit 1; }
PLAN_BUG=${PLAN}
prepare mutation 3 || { echo 'prepare mutation failed'; exit 1; }
PLAN_MUTATION=${PLAN}
prepare rows 4 || { echo 'prepare rows failed'; exit 1; }
PLAN_ROWS=${PLAN}
echo "    plans approved: scope ${PLAN_SCOPE}, bug ${PLAN_BUG}, mutation ${PLAN_MUTATION}, rows ${PLAN_ROWS}"
dispatch build code-builder upload a0b1c2d300 build-php-a0b1c2 1
work_on app/Upload/Client.php tests/Upload/UploadClientTest.php
write_report build
stop build-under-test
check 'the build under test: build.submitted, iteration 1, committed' is "$(ev '"\(.type) \(.body.iteration) \(.body | has("commit"))"')" 'build.submitted 1 true'
TESTER=77de01a0b1

echo "=== 2: a plan with no_tests"
dispatch test-plan code-tester upload "${TESTER}" test-plan-php-77de01 1
write_report plan-2-no-tests
stop 2-plan-no-tests
check 'accepted: test-plan.submitted, iteration 1' sh -c '[ -z "$1" ] && printf "%s" "$2" | jq -e ".type == \"test-plan.submitted\" and .body.iteration == 1"' _ "${HOOK_OUT}" "${EVENT}"
check 'its report is at reports/test-plan/<job seq>.json' is "$(ev '.body.report.path')" "reports/test-plan/${JOB}.json"
check 'a plan job makes no commit' sh -c '[ "$1" = none ] && ! printf "%s" "$2" | jq -e ".body | has(\"commit\")"' _ "$(cat "${E}/2-plan-no-tests/commit.txt")" "${EVENT}"

echo "=== 1: a plan with tests, then its rework answering two challenges"
dispatch test-plan code-tester upload "${TESTER}" test-plan-php-77de01 1
write_report plan-1
stop 1a-plan
P1=$(ev '.seq')
check 'accepted: test-plan.submitted, no commit' sh -c '[ -z "$1" ] && printf "%s" "$2" | jq -e ".type == \"test-plan.submitted\" and (.body | has(\"commit\") | not)"' _ "${HOOK_OUT}" "${EVENT}"
check 'the body prints job, iteration, agent, report' is "$(ev '.body | keys_unsorted | join(",")')" 'job,iteration,agent,report'
check 'the pin matches the report' is "$(ev '.body.report.sha256')" "$(sum256 "${REPORT}")"
dispatch test-plan-update code-tester upload "${TESTER}" test-plan-update-php-77de01 1 \
	"{\"plan\": ${P1}, \"challenges\": [{\"id\": \"C-1\", \"ask\": \"add\", \"target\": \"B-1\"}, {\"id\": \"C-2\", \"ask\": \"prove\", \"target\": \"N-1\"}]}" \
	|| echo "    rework refused: ${DISPATCH_SAID}"
write_report plan-1-update
stop 1b-rework-two-challenges
check 'accepted: test-plan.updated, no commit' sh -c '[ -z "$1" ] && printf "%s" "$2" | jq -e ".type == \"test-plan.updated\" and (.body | has(\"commit\") | not)"' _ "${HOOK_OUT}" "${EVENT}"
check 'its answers: C-1 applied, C-2 cannot' is "$(jq -r '[.answers[] | "\(.id) \(.answer)"] | join(", ")' "${REPORT}")" 'C-1 applied, C-2 cannot'
check 'its report is at reports/test-plan-update/<job seq>.json' is "$(ev '.body.report.path')" "reports/test-plan-update/${JOB}.json"
U1=$(ev '.seq')

echo "=== a rework whose challenge asks nothing a rework can apply: a job fault for the human"
dispatch test-plan-update code-tester upload fa17fa17fa test-plan-update-php-fa17fa 1 \
	"{\"plan\": ${U1}, \"challenges\": [{\"id\": \"C-9\", \"ask\": \"fix\"}]}" || echo "    rework refused: ${DISPATCH_SAID}"
write_report plan-1-update
stop rework-bad-ask
check 'job.dispatched leaves the ask to the tester: the job was written' is "$(sh "${JOB_OF}" --effort "${effort}" --job "${JOB}" | jq -r '.challenges[0].ask')" fix
check 'the stop goes through with the fault told to the human' sh -c '[ "$2" -eq 0 ] && ! printf "%s" "$1" | jq -e ".decision" >/dev/null && printf "%s" "$1" | jq -r .systemMessage | grep -qF "ask nothing a rework can apply"' _ "${HOOK_OUT}" "${HOOK_RC}"
check 'a fault before acceptance: job.ended fault at step check, no refusal' is "$(jq -r '[.[] | "\(.type) \(.body.reason) \(.body.step)"] | join(",")' "${E}/rework-bad-ask/event.json")" 'job.ended fault check'

echo "=== 3: a refused plan, with its repair lines"
dispatch test-plan code-tester upload 3a3a3a3a00 test-plan-php-3a3a3a 1
write_report plan-3-bad
stop 3-plan-refused
r=$(reason)
check 'held' held
check 'the line for the missing keeps' has "${r}" 'tests[1] modifies a test: add keeps, what it must still assert'
check 'the line for the unknown guard' has "${r}" 'tests[0].guards names B-9, which isn'"'"'t a behaviour in this plan'
check 'the line for the internal ID in human text' has "${r}" 'tests[0].why names T-2: say it in words; the IDs are for scripts'
check 'only job.refused try 1: no submission' sh -c '[ "$(jq -r "[.[] | .type + \" \" + (.body.try | tostring)] | join(\",\")" "$1")" = "job.refused 1" ]' _ "${E}/3-plan-refused/event.json"

echo "=== 4: a plan job that changed the tree: refused"
dispatch test-plan code-tester upload 4b4b4b4b00 test-plan-php-4b4b4b 1
work_on tests/Upload/Scratch.php
write_report plan-4
stop 4-plan-changed-tree
check 'held, naming the file to undo' has "$(reason)" 'a plan job changes nothing in the tree: undo the change to tests/Upload/Scratch.php'
check 'only job.refused try 1, no commit' sh -c '[ "$(jq -r "[.[] | .type + \" \" + (.body.try | tostring)] | join(\",\")" "$1")" = "job.refused 1" ] && [ "$2" = none ]' _ "${E}/4-plan-changed-tree/event.json" "$(cat "${E}/4-plan-changed-tree/commit.txt")"
rm -f -- "${TREE}/tests/Upload/Scratch.php"

echo "=== 9: a rework from the human's words at the gate"
dispatch test-plan-update code-tester upload "${TESTER}" test-plan-update-php-77de01 1 \
	"{\"plan\": ${U1}, \"words\": \"make the 429 test end to end\"}" || echo "    rework refused: ${DISPATCH_SAID}"
write_report plan-9-words
stop 9-rework-from-words
check 'accepted: test-plan.updated' sh -c '[ -z "$1" ] && printf "%s" "$2" | jq -e ".type == \"test-plan.updated\""' _ "${HOOK_OUT}" "${EVENT}"
check 'no challenge answers' jq -e 'has("answers") | not' "${REPORT}"
U2=$(ev '.seq')

echo "=== the plan, approved at the gate (the dispatch, not the event rule, will hold a job for it)"
approve "${U2}"

echo "=== 5: the tests written: test.submitted and its commit"
dispatch test code-tester upload "${TESTER}" test-php-77de01 1 "{\"plan\": ${U2}}" || echo "    test refused: ${DISPATCH_SAID}"
check 'the approved newest plan starts the test job' is "$(sh "${JOB_OF}" --effort "${effort}" --job "${JOB}" | jq -r '.plan')" "${U2}"
work_on tests/Upload/UploadClientTest.php tests/fixtures/503.json
git -C "${TREE}" rm -q tests/Upload/OldClientTest.php
write_report test-5
stop 5-tests-written
check 'accepted: test.submitted, iteration 1, committed' sh -c '[ -z "$1" ] && printf "%s" "$2" | jq -e ".type == \"test.submitted\" and .body.iteration == 1 and (.body.commit | type) == \"string\""' _ "${HOOK_OUT}" "${EVENT}"
check 'the body prints job, iteration, agent, report, commit' is "$(ev '.body | keys_unsorted | join(",")')" 'job,iteration,agent,report,commit'
check 'the commit: crucible(test), Effort, Job, Iteration and the setup' is "$(message_of)" "crucible(test): cover the retry limit and the 4xx case

Effort: ${effort_name}
Job: ${JOB} test-php-77de01
Iteration: 1
Language: php
Framework: laravel
Standards: testing, security"
check 'the planned file the build also changed was accepted, and committed' sh -c 'git -C "$1" show --stat HEAD | grep -q UploadClientTest.php' _ "${TREE}"
check 'the report is pinned read-only' sh -c '[ -n "$(find "$1" -prune -perm 0444)" ]' _ "${REPORT}"

echo "=== a build-fix on the build under test, by the builder: its own loop"
dispatch build-fix code-builder upload a0b1c2d300 build-fix-php-a0b1c2 1 "{\"findings\": [\"REVIEW-01\"], \"fix_round\": 1}" \
	|| echo "    build-fix refused: ${DISPATCH_SAID}"
work_on app/Upload/Client.php
write_report build-fix
stop build-fix-under-test
check 'build-fix.submitted, fix round 1' sh -c 'printf "%s" "$1" | jq -e ".type == \"build-fix.submitted\" and .body.fix_round == 1"' _ "${EVENT}"

echo "=== 8: a tester's fix: test-fix.submitted with its fix round, counted apart from the build's"
dispatch test-fix code-tester upload "${TESTER}" test-fix-php-77de01 1 "{\"findings\": [\"TEST-01\"], \"plan\": ${U2}, \"fix_round\": 2}"; rc=$?
check 'a test-fix counting on from the build-fix'"'"'s round is refused: its round is 1' sh -c '[ "$1" -ne 0 ] && printf "%s" "$2" | grep -qF "fix_round must be 1"' _ "${rc}" "${DISPATCH_SAID}"
dispatch test-fix code-tester upload "${TESTER}" test-fix-php-77de01 1 "{\"findings\": [\"TEST-01\"], \"plan\": ${U2}, \"fix_round\": 1}" \
	|| echo "    test-fix refused: ${DISPATCH_SAID}"
work_on tests/Upload/UploadClientTest.php
write_report fix-8
stop 8-tester-fix
check 'accepted: test-fix.submitted, iteration 1, fix round 1, committed' sh -c '[ -z "$1" ] && printf "%s" "$2" | jq -e ".type == \"test-fix.submitted\" and .body.iteration == 1 and .body.fix_round == 1 and (.body.commit | type) == \"string\""' _ "${HOOK_OUT}" "${EVENT}"
check 'the commit: crucible(test-fix) with Fix-Round' is "$(message_of | sed -n '1p;6p')" "crucible(test-fix): assert the 4xx rows by status, not by message
Fix-Round: 1"
check 'its report is at reports/test-fix/<job seq>.json' is "$(ev '.body.report.path')" "reports/test-fix/${JOB}.json"
sh "${JOB_OF}" --effort "${effort}" --job "${JOB}" >"${S}/work/fix-job.json"
sh "${VAL}/tester-facts.sh" --effort "${effort}" --job "${S}/work/fix-job.json" >"${S}/work/facts.json"
check 'the build under test is the build and build-fix commits: the builder'"'"'s files, not the tester'"'"'s' \
	jq -e '(.build_files | index("app/Upload/Client.php")) and (.build_files | index("tests/fixtures/503.json") | not)' "${S}/work/facts.json"

echo "=== 6: a test that finds a production bug: blocked, the tests still committed"
dispatch test code-tester bug 6c6c6c6c00 test-php-6c6c6c 1 "{\"plan\": ${PLAN_BUG}}" || echo "    test refused: ${DISPATCH_SAID}"
work_on tests/Upload/UploadClientTest.php
write_report test-6-bug
stop 6-production-bug
check 'accepted with the production_bug blocker covering the red test' accepted
check 'test.submitted with a commit' sh -c 'printf "%s" "$1" | jq -e ".type == \"test.submitted\" and (.body.commit | type) == \"string\""' _ "${EVENT}"
check 'the red test is committed' sh -c 'git -C "$1" show --stat HEAD | grep -q UploadClientTest.php' _ "${TREE}"
check 'the pinned report holds the production_bug' jq -e '.blockers[0].kind == "production_bug"' "${REPORT}"

echo "=== 7: the plan as scope"
dispatch test code-tester scope 7d7d7d7d00 test-php-7d7d7d 1 "{\"plan\": ${PLAN_SCOPE}}" || echo "    test refused: ${DISPATCH_SAID}"
work_on tests/Upload/UploadClientTest.php app/Upload/Client.php
write_report test-7a
stop 7a-unplanned-build-file
check 'held: an unplanned file the build changed' has "$(reason)" "you changed app/Upload/Client.php, which the build under test changed and the plan doesn't name: undo it, and say what you need in a question or a cannot blocker"
check 'the planned file the build also changed draws no line' sh -c '! printf "%s" "$1" | grep -q "you changed tests/Upload/UploadClientTest.php"' _ "$(reason)"
git -C "${TREE}" checkout -q -- app/Upload/Client.php
work_on tests/Upload/HelperTest.php
write_report test-7b
stop 7b-planned-and-explained
check 'accepted: the planned file, and a file outside the plan explained in decisions' accepted
check 'test.submitted, committing both' sh -c 'printf "%s" "$1" | jq -e ".type == \"test.submitted\"" && git -C "$2" show --stat HEAD | grep -q HelperTest.php && git -C "$2" show --stat HEAD | grep -q UploadClientTest.php' _ "${EVENT}" "${TREE}"

echo "=== 10: the mutation gate"
dispatch test code-tester mutation 9e9e9e9e00 test-php-9e9e9e 1 "{\"plan\": ${PLAN_MUTATION}}" || echo "    test refused: ${DISPATCH_SAID}"
work_on tests/Upload/UploadClientTest.php
write_report test-10a
stop 10a-no-mutation-gate
check 'held: the mutation gate missing' has "$(reason)" 'list the mutation gate: pass with a note, fail with what survived, or not_run with why'
write_report test-10b
stop 10b-failed-mutation
check 'accepted: a failed mutation gate needs no blocker' accepted
check 'test.submitted, committed' sh -c 'printf "%s" "$1" | jq -e ".type == \"test.submitted\" and (.body.commit | type) == \"string\""' _ "${EVENT}"

echo "=== the view joins every tester submission to its pinned report"
check 'events-view.sh reads the effort whole, each submission with its report' sh -c 'sh "$1" --effort "$2" | jq -e "[.[] | select((.body.report | type) == \"object\")] | length > 10 and all(.[]; .report | type == \"object\")"' _ "${VIEW}" "${effort}"

echo "=== every repair line of test-agent.md section 5 (fixtures/repair-lines.json)"
ROWS=$(tree_of rows)
mkdir -p "${S}/work/rows"
rows=$(jq 'length' "${F}/repair-lines.json")
: >"${E}/repair-lines.txt"
i=0
while [ "${i}" -lt "${rows}" ]; do
	jq -c --argjson i "${i}" '.[$i]' "${F}/repair-lines.json" >"${S}/work/row.json"
	rule=$(jq -r '.rule' "${S}/work/row.json")
	kind=$(jq -r '.kind' "${S}/work/row.json")
	git -C "${ROWS}" checkout -q -- . && git -C "${ROWS}" clean -qfd
	jq -r '.writes // [] | .[]' "${S}/work/row.json" | while IFS= read -r file; do
		mkdir -p "${ROWS}/${file%/*}"; printf '// row work\n' >>"${ROWS}/${file}"
	done
	row_job=$((9000 + i))
	row_report="${effort}/reports/${kind}/${row_job}.json"
	mkdir -p "${row_report%/*}"
	jq '.report' "${S}/work/row.json" >"${row_report}"
	jq --arg tree "${ROWS}" --argjson plan "${PLAN_ROWS}" --argjson job "${row_job}" '{job: $job, state: "assigned", kind, agent_type: "code-tester",
		tree: $tree, report: "reports/\(.kind)/\($job).json"} + (.job // {})
		+ (if .kind == "test" or .kind == "test-fix" or .kind == "test-plan-update" then {plan: $plan} else {} end)
		+ {known_failures: (.job.known_failures // []), iteration: 1}
		+ (if .kind == "test-fix" then {fix_round: 1} else {} end)
		+ {setup: {language: "php", standards: ["testing"]}}' "${S}/work/row.json" >"${S}/work/row-job.json"
	got=$(sh "${K}/agent-submission/hooks/subagent-stop/report-validation.sh" --effort "${effort}" --job "${S}/work/row-job.json" 2>&1); rc=$?
	expected=$(jq -r '.expected' "${S}/work/row.json")
	want_rc=1
	[ -n "${expected}" ] || want_rc=0
	printf '%s\n  exit %s: %s\n' "${rule}" "${rc}" "${got:-(accepted)}" | show >>"${E}/repair-lines.txt"
	check "${rule}" sh -c '[ "$1" -eq "$2" ] && [ "$3" = "$4" ]' _ "${rc}" "${want_rc}" "${got}" "${expected}"
	i=$((i + 1))
done

echo
echo "=== ${pass} PASS, ${fail} FAIL"
[ "${fail}" -eq 0 ]
