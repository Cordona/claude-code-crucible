#!/usr/bin/env sh
# Evidence run for the review agent's submission, through the installed
# layout, as the builder's and tester's runs are: a scratch Claude folder
# linked with install-entries.sh's own commands, a scratch space, effort and
# repository, the jobs written through the real event writer, and each case
# fed to the real SubagentStop hook as Claude Code feeds it. The builds, the
# build-fix and the plan the reviewer reads are handed in by fixture agents
# through the same hook. Only scratch: its own HOME and git config, no key.
# Exits 1 when any expectation fails.
# shellcheck disable=SC2016,SC2312 # single-quoted jq, sh -c and file text are meant literally; a read inside a check is what the check compares
set -u
R=/Users/cordona/IdeaProjects/cordona/claude-code-crucible/new-rewrite
E=$(cd -- "$(dirname -- "$0")" && pwd)
F="${E}/fixtures"
S=$(mktemp -d "${TMPDIR:-/tmp}/review-agent.XXXXXX") || exit 2
S=$(cd -P -- "${S}" && pwd -P)
trap 'rm -rf -- "${S}"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "${S}/home" "${S}/cfg" "${S}/work"
export HOME="${S}/home" GIT_CONFIG_GLOBAL="${S}/home/.gitconfig" GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME="${S}/home/.config"
export CRUCIBLE_HOME="${S}/space" CLAUDE_CONFIG_DIR="${S}/cfg" CLAUDE_CODE_SESSION_ID=sess-ra
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

EW="${K}/crucible-events/scripts/internal/event-write.sh"
ER="${K}/crucible-events/scripts/internal/events-read.sh"
JOB_OF="${K}/agent-jobs/scripts/internal/job-of.sh"
HOOK="${K}/agent-submission/hooks/subagent-stop/submit-agent-work.sh"
CHECK="${K}/agent-submission/hooks/subagent-stop/steps/report-validation.sh"
CR="${R}/domains/software-development/core/agents/code-reviewer"

echo "=== install: install-entries.sh's own links and settings, then install-check.sh"
sh "${R}/framework/core/install/install-entries.sh" | sed -n '/^# Links/,/^$/p' | sed '1d' >"${S}/links.sh"
sh "${R}/framework/core/install/install-entries.sh" | sed -n '/^# Settings/,/^$/p' | sed '1d' >"${S}/settings.json"
sh "${S}/links.sh"
sh "${R}/framework/core/install/install-check.sh" --settings "${S}/settings.json" >"${S}/check.out" 2>&1
check 'install-check.sh agrees: installed, code-reviewer included' sh -c '[ "$(cat "$1")" = installed ] && [ -L "$2/code-reviewer" ]' _ "${S}/check.out" "${K}"
check 'code-reviewer lists what it hands in, one submissions file per kind' sh -c '[ "$(ls "$1/code-reviewer/submissions")" = "$(printf "external-review.json\nforeign-review.json\nreview.json\ntest-plan-challenge.json")" ]' _ "${K}"
for pair in review:review.submitted test-plan-challenge:test-plan.challenged external-review:external-review.submitted foreign-review:foreign-review.submitted; do
	kind=${pair%%:*} event=${pair#*:}
	check "submissions/${kind}.json: ${event}, no commit, its rules, facts and stamps installed" sh -c 'f="$1/code-reviewer/submissions/$2.json"; jq -e --arg e "$3" ".event == \$e and .commit == false" "$f" && [ -f "$1/$(jq -r .rules "$f").jq" ] && [ -f "$1/$(jq -r .facts "$f")" ] && [ -f "$1/$(jq -r .stamps.rules "$f").jq" ] && [ -f "$1/code-reviewer/events/$3.jq" ]' _ "${K}" "${kind}" "${event}"
done
check 'code-reviewer owns its rules: a common lib, one rules file per kind, its stamps' sh -c 'cd "$1/code-reviewer/scripts/lib" && [ "$(ls)" = "$(printf "external-review-report.jq\nforeign-review-report.jq\nreview-report.jq\nreviewer-common.jq\nreviewer-stamps.jq\ntest-plan-challenge-report.jq")" ]' _ "${K}"
check 'no agent includes another agent'"'"'s rules: every reviewer include is its own' sh -c '! grep -rh "^include" "$1/scripts/lib" "$1/events" | grep -vqE "include \"(code-reviewer|agent-jobs)/"' _ "${CR}"
check 'the reviewer names no other agent'"'"'s component' sh -c '! grep -rqE "code-(builder|tester)" "$1"' _ "${CR}"
check 'nothing in agent-submission or agent-jobs names a reviewer kind, or any agent' sh -c '! grep -rqE "code-(builder|tester|reviewer)|foreign-review|external-review|test-plan-challenge|\"review\"" "$1/agents/agent-submission" "$1/main-thread/agent-jobs"' _ "${R}/domains/software-development/core"
check 'the stop hook has its own lock, not the events lock' sh -c 'grep -q "stops/.lock" "$1" && ! grep -q "events/.lock" "$1"' _ "${K}/agent-submission/hooks/subagent-stop/submit-agent-work.sh"
for script in "${K}"/code-reviewer/scripts/internal/*.sh "${K}"/agent-submission/hooks/subagent-stop/steps/report-stamp.sh; do
	out=$(sh "${script}" --help 2>&1); rc=$?
	check "${script##*/} --help" sh -c '[ "$1" -eq 0 ] && printf "%s" "$2" | grep -q "^usage: " && printf "%s" "$2" | grep -q "^Exit:"' _ "${rc}" "${out}"
done

echo "=== set-up: a scratch repository, an effort, its identity (no key), four trees"
repo="${S}/repo"
git init -q -b main "${repo}"
mkdir -p "${repo}/src/upload" "${repo}/tests/Upload" "${repo}/tests/fixtures"
awk 'BEGIN { for (i = 1; i <= 20; i++) printf "# a.sh line %d\n", i }' >"${repo}/a.sh"
awk 'BEGIN { for (i = 1; i <= 40; i++) printf "# b.sh line %d\n", i }' >"${repo}/b.sh"
awk 'BEGIN { for (i = 1; i <= 5; i++) printf "# x.sh line %d\n", i }' >"${repo}/x.sh"
awk 'BEGIN { for (i = 1; i <= 90; i++) printf "// Client.kt line %d\n", i }' >"${repo}/src/upload/Client.kt"
awk 'BEGIN { for (i = 1; i <= 50; i++) printf "README line %d\n", i }' >"${repo}/README.md"
awk 'BEGIN { for (i = 1; i <= 30; i++) printf "// UploadClientTest line %d\n", i }' >"${repo}/tests/Upload/UploadClientTest.php"
printf '{"status": 503}\n' >"${repo}/tests/fixtures/503.json"
printf '*.log\n' >"${repo}/.gitignore"
git -C "${repo}" add -A
git -C "${repo}" -c user.name=Fixture -c user.email=fixture@example.test commit -q -m 'the project'
effort=$(sh "${K}/crucible-effort/scripts/main/effort-start.sh" --name 'upload retries') || { echo 'effort-start failed'; exit 1; }
repo_main=$(sh "${K}/dev-base/scripts/internal/repo-of.sh" --dir "${repo}" | jq -r '.repo')
jq -n --arg repo "${repo_main}" '{repo: $repo, name: "Review Fixture", email: "review@example.test",
	signing: {format: "ssh", key: "/nonexistent/fixture-key.pub"}, fingerprint: "", answer: 1}' >"${S}/identity.json"
sh "${EW}" --effort "${effort}" --type identity.set --by identity-set.sh --body-file "${S}/identity.json" >/dev/null
for t in upload next foreign rows; do
	sh "${K}/git-worktree/scripts/main/worktree-cut.sh" --effort "${effort}" --repo "${repo}" --name "${t}" --from checkout >/dev/null \
		|| { echo "worktree-cut ${t} failed"; exit 1; }
done
tree_of() { printf '%s/worktrees/%s' "${effort}" "$1"; }
SETUP='{"language": "shell", "standards": ["security"]}'
THREADS="${S}/threads.json"
cp -- "${F}/threads.json" "${THREADS}"

events_count() { sh "${ER}" --effort "${effort}" --paths | wc -l | tr -d ' '; }
# dispatch KIND AGENT_TYPE TREE AGENT NAME [EXTRA_JSON]: job.dispatched and
# job.assigned through the real event writer; the iteration is the tree's
# (the next for a build, none on a tree with no build). Sets JOB, AGENT,
# AGENT_TYPE, TREE and REPORT; returns 1 when refused, the reason in SAID.
dispatch() {
	JOB=$(($(events_count) + 1)) AGENT_TYPE=$2 TREE=$(tree_of "$3") AGENT=$4
	extra=${6-}
	[ -n "${extra}" ] || extra='{}'
	sh "${ER}" --effort "${effort}" >"${S}/work/all.json"
	jq -n --arg kind "$1" --arg type "$2" --arg tree "${TREE}" --arg report "reports/$1/${JOB}.json" \
		--argjson extra "${extra}" --argjson setup "${SETUP}" --slurpfile all "${S}/work/all.json" '
		([$all[0][] | select(.type == "job.dispatched" and .body.kind == "build" and .body.tree == $tree) | .body.iteration] | max) as $now
		| {kind: $kind, agent_type: $type, tree: $tree, report: $report}
		+ ($extra | del(.fix_round))
		+ {known_failures: []}
		+ (if $kind == "build" then {iteration: (($now // 0) + 1)} elif $now == null then {} else {iteration: $now} end)
		+ ($extra | with_entries(select(.key == "fix_round")))
		+ {setup: $setup}' >"${S}/work/dispatched.json"
	SAID=$(sh "${EW}" --effort "${effort}" --type job.dispatched --by job-dispatch.sh --body-file "${S}/work/dispatched.json" 2>&1) || return 1
	jq -n --argjson job "${JOB}" --arg agent "$4" --arg name "$5" '{job: $job, agent: $agent, name: $name, session: "sess-ra"}' >"${S}/work/assigned.json"
	sh "${EW}" --effort "${effort}" --type job.assigned --by assign-job.sh --body-file "${S}/work/assigned.json" >/dev/null \
		|| { echo "    job.assigned ${JOB} refused"; fail=$((fail + 1)); return 1; }
	REPORT="${effort}/reports/$1/${JOB}.json"
}
write_report() { mkdir -p "${REPORT%/*}"; rm -f -- "${REPORT}"; cp -- "${F}/reports/$1.json" "${REPORT}"; chmod 600 "${REPORT}"; }
# Changes line N of FILE in the tree: edit TREE FILE N TEXT.
edit() { awk -v n="$3" -v t="$4" 'NR == n { print t; next } { print }' "$1/$2" >"$1/$2.new" && mv -- "$1/$2.new" "$1/$2"; }
hook_json() {
	jq -cn --arg agent "${AGENT}" --arg type "${AGENT_TYPE}" --arg cwd "${TREE}" '{session_id: "sess-ra",
		cwd: $cwd, hook_event_name: "SubagentStop", stop_hook_active: false, agent_id: $agent, agent_type: $type,
		last_assistant_message: "Done; my report is written."}'
}
# Feeds the hook a SubagentStop; case folder $1, or none for a fixture.
stop() {
	BEFORE=$(events_count)
	hook_json | sh "${HOOK}" >"${S}/work/hook.out" 2>"${S}/work/hook.err"
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
	echo 'none: a reviewer never commits' >"${dir}/commit.txt"
	sed 's/^/    /' "${dir}/hook-output.txt"
}
ev() { printf '%s' "${EVENT}" | jq -r "$1"; }
held() { [ "$(printf '%s' "${HOOK_OUT}" | jq -r '.decision // ""')" = block ]; }
accepted() { [ -z "${HOOK_OUT}" ] && [ "${HOOK_RC}" -eq 0 ]; }
reason() { printf '%s' "${HOOK_OUT}" | jq -r '.reason // ""'; }
ids() { jq -r '[.findings[]?.id] | join(" ")' "${REPORT}"; }

# A build on TREE by a fixture builder, through the hook: line 3 and 12 of
# a.sh and line 2 of b.sh change. Sets BUILD_BASE and BUILD_HEAD.
build_on() {
	t=$(tree_of "$1")
	BUILD_BASE=$(git -C "${t}" rev-parse HEAD)
	dispatch build code-builder "$1" "$2" "build-shell-$2" || { echo "    build refused: ${SAID}"; return 1; }
	edit "${t}" a.sh 3 'echo "$1"'; edit "${t}" a.sh 12 'tenant=$2'; edit "${t}" b.sh 2 'for w in $input; do'
	write_report build; stop ''
	BUILD_HEAD=$(git -C "${t}" rev-parse HEAD)
}

build_on upload b1b1b1b1b1 || exit 1
check 'the build under review: build.submitted, committed' sh -c 'printf "%s" "$1" | jq -e ".type == \"build.submitted\" and (.body.commit | type) == \"string\""' _ "${EVENT}"
BASE=${BUILD_BASE} HEAD=${BUILD_HEAD}
LENS_SHELL="{\"lens\": \"shell\", \"base\": \"${BASE}\", \"head\": \"${HEAD}\"}"

echo "=== 1: a cold review with five findings"
dispatch review code-reviewer upload r1r1r1r1r1 review-shell-r1r1r1 "${LENS_SHELL}" || echo "    review refused: ${SAID}"
write_report review-1
stop 1-cold-review
check 'accepted: review.submitted, iteration 1, no commit' sh -c '[ -z "$1" ] && printf "%s" "$2" | jq -e ".type == \"review.submitted\" and .body.iteration == 1 and (.body | has(\"commit\") | not)"' _ "${HOOK_OUT}" "${EVENT}"
check 'the five findings are stamped SHELL-01 to SHELL-05, id first' sh -c '[ "$(jq -r "[.findings[] | keys_unsorted[0] + \"=\" + .id] | join(\" \")" "$1")" = "id=SHELL-01 id=SHELL-02 id=SHELL-03 id=SHELL-04 id=SHELL-05" ]' _ "${REPORT}"
check 'the report is at reports/review/<seq>.json, pinned read-only' sh -c '[ "$(printf "%s" "$1" | jq -r .body.report.path)" = "reports/review/$2.json" ] && [ -n "$(find "$3" -prune -perm 0444)" ]' _ "${EVENT}" "${JOB}" "${REPORT}"
check 'the body prints job, iteration, agent, report' is "$(ev '.body | keys_unsorted | join(",")')" 'job,iteration,agent,report'
check 'the tree is untouched: no commit was made' is "$(git -C "${TREE}" rev-parse HEAD)" "${HEAD}"

echo "=== 2: a clean review, {}"
dispatch review code-reviewer upload r2r2r2r2r2 review-shell-r2r2r2 "${LENS_SHELL}" || echo "    review refused: ${SAID}"
write_report clean
stop 2-clean-review
check 'accepted: review.submitted, the report {}' sh -c '[ -z "$1" ] && printf "%s" "$2" | jq -e ".type == \"review.submitted\"" && [ "$(jq -c . "$3")" = "{}" ]' _ "${HOOK_OUT}" "${EVENT}" "${REPORT}"

echo "=== 3: a refused review"
dispatch review code-reviewer upload r3r3r3r3r3 review-shell-r3r3r3 "${LENS_SHELL}" || echo "    review refused: ${SAID}"
write_report review-3-bad
stop 3-refused-review
r=$(reason)
check 'held' held
check 'the edge-case with no proof' has "${r}" 'findings[0] is an edge-case: add proof, the line that makes it reachable'
check 'the at outside the cover' has "${r}" 'findings[1].at x.sh:3 is outside this change: add relates_to, the changed line it relates to, or out_of_scope with its proof'
check 'a 240-character claim is no refusal: no length is checked' sh -c '! printf "%s" "$1" | grep -q "findings\[2\]"' _ "${r}"
check 'only job.refused try 1: no submission' sh -c '[ "$(jq -r "[.[] | .type + \" \" + (.body.try | tostring)] | join(\",\")" "$1")" = "job.refused 1" ]' _ "${E}/3-refused-review/event.json"

echo "=== 4: a reviewer that left changes in the tree"
dispatch review code-reviewer upload r4r4r4r4r4 review-shell-r4r4r4 "${LENS_SHELL}" || echo "    review refused: ${SAID}"
printf '# a reviewer edit\n' >>"${TREE}/x.sh"
write_report review-4
stop 4a-changed-tree
check 'held: you changed files' has "$(reason)" 'you changed files: undo your changes; a reviewer changes nothing'
git -C "${TREE}" checkout -q -- x.sh
printf 'a run log\n' >"${TREE}/review-run.log"
stop 4b-ignored-file
check 'an ignored file doesn'"'"'t count: accepted' sh -c '[ -z "$1" ] && printf "%s" "$2" | jq -e ".type == \"review.submitted\""' _ "${HOOK_OUT}" "${EVENT}"
rm -f -- "${TREE}/review-run.log"

echo "=== a build-fix on the cold review's findings, by a fixture builder"
FIX_BASE=$(git -C "$(tree_of upload)" rev-parse HEAD)
dispatch build-fix code-builder upload b1b1b1b1b1 build-fix-shell-b1b1b1 '{"findings": ["SHELL-01", "SHELL-02", "SHELL-03"], "fix_round": 1}' || echo "    build-fix refused: ${SAID}"
edit "${TREE}" a.sh 3 'echo "${1:?}"'
write_report build-fix; stop ''
check 'build-fix.submitted, fix round 1' sh -c 'printf "%s" "$1" | jq -e ".type == \"build-fix.submitted\" and .body.fix_round == 1"' _ "${EVENT}"
FIX_HEAD=$(git -C "$(tree_of upload)" rev-parse HEAD)
EARLIER='[{"id": "SHELL-01", "status": "done"}, {"id": "SHELL-02", "status": "partly", "reason": "quoted at a.sh:12; the caller is another repo"}, {"id": "SHELL-03", "status": "declined", "reason": "word input is the documented contract"}]'
RE_REVIEW="{\"lens\": \"shell\", \"base\": \"${FIX_BASE}\", \"head\": \"${FIX_HEAD}\", \"earlier\": ${EARLIER}, \"fix_round\": 1}"

echo "=== 5: a re-review after the build-fix"
dispatch review code-reviewer upload r5r5r5r5r5 review-shell-r5r5r5 "${RE_REVIEW}" || echo "    re-review refused: ${SAID}"
write_report re-review-5
stop 5-re-review
check 'accepted: review.submitted, iteration 1, fix round 1, the fix'"'"'s' sh -c '[ -z "$1" ] && printf "%s" "$2" | jq -e ".type == \"review.submitted\" and .body.iteration == 1 and .body.fix_round == 1"' _ "${HOOK_OUT}" "${EVENT}"
check 'fixed without a reason, open with one, agree on the decline' is "$(jq -r '[.fixes[] | "\(.id) \(.status) \(has("reason"))"] | join(", ")' "${REPORT}")" 'SHELL-01 fixed false, SHELL-02 open true, SHELL-03 agree true'
check 'the body prints job, iteration, fix_round, agent, report' is "$(ev '.body | keys_unsorted | join(",")')" 'job,iteration,fix_round,agent,report'

echo "=== 6: a re-review missing a status, and fixed on a decline: refused"
dispatch review code-reviewer upload r6r6r6r6r6 review-shell-r6r6r6 "${RE_REVIEW}" || echo "    re-review refused: ${SAID}"
write_report re-review-6-bad
stop 6-re-review-refused
r=$(reason)
check 'held: the missing status' has "${r}" 'give SHELL-02 a status: fixed or open (the fixer said partly)'
check 'held: fixed on a decline' has "${r}" 'SHELL-03 was declined: give agree or disagree, with a reason'

echo "=== a plan for the challenge, by a fixture tester"
dispatch test-plan code-tester upload t1t1t1t1t1 test-plan-shell-t1t1t1 || echo "    plan refused: ${SAID}"
write_report plan; stop ''
PLAN=$(ev '.seq')
check 'test-plan.submitted' is "$(ev '.type')" test-plan.submitted

echo "=== 7: a plan challenge with three challenges"
dispatch test-plan-challenge code-reviewer upload c7c7c7c7c7 challenge-c7c7c7 "{\"plan\": ${PLAN}}" || echo "    challenge refused: ${SAID}"
write_report challenge-7
stop 7-plan-challenge
check 'accepted: test-plan.challenged, no commit' sh -c '[ -z "$1" ] && printf "%s" "$2" | jq -e ".type == \"test-plan.challenged\" and (.body | has(\"commit\") | not)"' _ "${HOOK_OUT}" "${EVENT}"
check 'the challenges are stamped C-1 to C-3' is "$(jq -r '[.challenges[].id] | join(" ")' "${REPORT}")" 'C-1 C-2 C-3'
jq --argjson plan "${PLAN}" '{plan: $plan, challenges: [.challenges[] | {id, ask, target}]}' "${REPORT}" >"${S}/work/rework.json"
dispatch test-plan-update code-tester upload t1t1t1t1t1 test-plan-update-shell-t1t1t1 "$(cat "${S}/work/rework.json")"; rc=$?
check 'a test-plan-update job can carry the stamped challenges' is "${rc}" 0

echo "=== 8: an empty challenge approves the plan as it is"
dispatch test-plan-challenge code-reviewer upload c8c8c8c8c8 challenge-c8c8c8 "{\"plan\": ${PLAN}}" || echo "    challenge refused: ${SAID}"
write_report clean
stop 8-empty-challenge
check 'accepted: test-plan.challenged, the report {}' sh -c '[ -z "$1" ] && printf "%s" "$2" | jq -e ".type == \"test-plan.challenged\"" && [ "$(jq -c . "$3")" = "{}" ]' _ "${HOOK_OUT}" "${EVENT}" "${REPORT}"

echo "=== 9: an external review with all six verdicts"
dispatch external-review code-reviewer upload x9x9x9x9x9 external-review-x9x9x9 "{\"lens\": \"security\", \"threads\": \"${THREADS}\"}" || echo "    external review refused: ${SAID}"
write_report external-9
stop 9-external-review
check 'accepted: external-review.submitted, iteration 1' sh -c '[ -z "$1" ] && printf "%s" "$2" | jq -e ".type == \"external-review.submitted\" and .body.iteration == 1"' _ "${HOOK_OUT}" "${EVENT}"
check 'every item'"'"'s source stamped from the threads file' is "$(jq -r '[.items[] | "\(.thread)=\(.source)"] | unique | join(" ")' "${REPORT}")" 'description=human n11370=bot n11371=human n11372=bot n11373=human n11374=human'
check 'the valid findings'"'"' IDs from the job'"'"'s lens: SECURITY-01, SECURITY-02' is "$(jq -r '[.items[] | .finding.id? // empty] | join(" ")' "${REPORT}")" 'SECURITY-01 SECURITY-02'
check 'all six verdicts, an out_of_scope valid finding, and a noted with a reply' jq -e '([.items[].verdict] | unique) == ["already-fixed", "answered", "deferred", "noted", "rejected", "valid"]
	and any(.items[]; .finding.out_of_scope) and any(.items[]; .verdict == "noted" and has("reply"))' "${REPORT}"

echo "=== 10: an external review missing a thread, or with a reply on valid: refused"
dispatch external-review code-reviewer upload x0x0x0x0x0 external-review-x0x0x0 "{\"lens\": \"security\", \"threads\": \"${THREADS}\"}" || echo "    external review refused: ${SAID}"
jq '.items |= (map(select(.thread != "n11373")) | .[0].reply = "will fix")' "${F}/reports/external-9.json" >"${S}/work/ext-bad.json"
mkdir -p "${REPORT%/*}"; cp -- "${S}/work/ext-bad.json" "${REPORT}"
stop 10-external-refused
r=$(reason)
check 'held: the thread left unjudged' has "${r}" 'judge thread n11373: valid, rejected, already-fixed, deferred, answered or noted'
check 'held: the reply on valid' has "${r}" "items[0] is valid: remove its reply; it's drafted from the fix"

echo "=== 11: a foreign review with a note at a line"
dispatch foreign-review code-reviewer foreign f1f1f1f1f1 foreign-review-f1f1f1 '{"lens": "shell", "foreign": "acme/upload!42"}' || echo "    foreign review refused: ${SAID}"
check 'a job on a tree with no build has no iteration' sh -c 'sh "$1" --effort "$2" --job "$3" | jq -e "has(\"iteration\") | not"' _ "${JOB_OF}" "${effort}" "${JOB}"
write_report foreign-11
stop 11a-foreign-review
check 'accepted: foreign-review.submitted with no iteration' sh -c '[ -z "$1" ] && printf "%s" "$2" | jq -e ".type == \"foreign-review.submitted\" and (.body | has(\"iteration\") | not)"' _ "${HOOK_OUT}" "${EVENT}"
check 'its IDs numbered in the job, from 01' is "$(ids)" 'SHELL-01'
check 'the note keeps its line' jq -e '.notes[0].at == "src/upload/Client.kt:42"' "${REPORT}"
dispatch foreign-review code-reviewer foreign f2f2f2f2f2 foreign-review-f2f2f2 '{"lens": "shell", "foreign": "acme/upload!42"}' || echo "    foreign review refused: ${SAID}"
write_report foreign-11-fixes
stop 11b-foreign-with-fixes
check 'the same report with fixes: refused by the unknown-key rule' has "$(reason)" 'unknown key "fixes"; the keys are findings, noticed, notes'

echo "=== 12: IDs unique across two reviews of one lens, stopping together, and from 01 in the next iteration"
SEC="{\"lens\": \"security\", \"base\": \"${BASE}\", \"head\": \"${HEAD}\"}"
dispatch review code-reviewer upload p1p1p1p1p1 review-security-p1p1p1 "${SEC}"; J1=${JOB} R1=${REPORT}; write_report parallel
dispatch review code-reviewer upload p2p2p2p2p2 review-security-p2p2p2 "${SEC}"; J2=${JOB} R2=${REPORT}; write_report parallel
BEFORE=$(events_count)
AGENT=p1p1p1p1p1; hook_json >"${S}/work/h1.json"
AGENT=p2p2p2p2p2; hook_json >"${S}/work/h2.json"
sh "${HOOK}" <"${S}/work/h1.json" >"${S}/work/p1.out" 2>&1 &
p1=$!
sh "${HOOK}" <"${S}/work/h2.json" >"${S}/work/p2.out" 2>&1 &
p2=$!
wait "${p1}"; wait "${p2}"
mkdir -p "${E}/12-parallel"
{ printf 'job %s: %s\njob %s: %s\n' "${J1}" "$(jq -r '[.findings[].id] | join(" ")' "${R1}")" "${J2}" "$(jq -r '[.findings[].id] | join(" ")' "${R2}")"; cat "${S}/work/p1.out" "${S}/work/p2.out"; } | show >"${E}/12-parallel/ids.txt"
sh "${ER}" --effort "${effort}" | jq --argjson n "${BEFORE}" '[.[] | select(.seq > $n)]' | show >"${E}/12-parallel/event.json"
sed 's/^/    /' "${E}/12-parallel/ids.txt" | head -n 2
check 'both stops accepted: two review.submitted events' sh -c '[ "$(sh "$1" --effort "$2" | jq --argjson n "$3" "[.[] | select(.seq > \$n and .type == \"review.submitted\")] | length")" -eq 2 ]' _ "${ER}" "${effort}" "${BEFORE}"
check 'two distinct IDs after the external review'"'"'s: SECURITY-03 and SECURITY-04' is "$(jq -rs '[.[].findings[].id] | sort | join(" ")' "${R1}" "${R2}")" 'SECURITY-03 SECURITY-04'
build_on upload b2b2b2b2b2 || exit 1
check 'a second build opens iteration 2' sh -c 'printf "%s" "$1" | jq -e ".type == \"build.submitted\" and .body.iteration == 2"' _ "${EVENT}"
dispatch review code-reviewer upload p3p3p3p3p3 review-security-p3p3p3 "{\"lens\": \"security\", \"base\": \"${BUILD_BASE}\", \"head\": \"${BUILD_HEAD}\"}"
write_report parallel
stop 12-next-iteration
check 'numbered from 01 again in iteration 2: SECURITY-01' sh -c '[ "$(jq -r ".findings[0].id" "$1")" = SECURITY-01 ] && printf "%s" "$2" | jq -e ".body.iteration == 2"' _ "${REPORT}" "${EVENT}"

echo "=== 13: the stamps stop instead of guessing, and a job the reviewer can't judge: faults for the human"
fault() { # fault TEXT LINE STEP EVENT: the stop went through, the human told LINE, and the one event is EVENT at STEP
	check "$1" sh -c '[ "$2" -eq 0 ] && ! printf "%s" "$1" | jq -e ".decision" >/dev/null && printf "%s" "$1" | jq -r .systemMessage | grep -qF -- "$3"' _ "${HOOK_OUT}" "${HOOK_RC}" "$2"
	check "$1: $4 at step $3, and nothing else" is "$(sh "${ER}" --effort "${effort}" | jq -r --argjson n "${BEFORE}" '[.[] | select(.seq > $n) | "\(.type) \(.body.step)"] | join(",")')" "$4 $3"
}
dispatch review code-reviewer next n1n1n1n1n1 review-n1n1n1 "{\"base\": \"${BASE}\", \"head\": \"${HEAD}\"}" || echo "    review refused: ${SAID}"
write_report parallel
stop 13a-no-lens
fault 'a review job with no lens: no REVIEW-NN guessed' 'names no lens, so its findings can'"'"'t be given IDs' stamp job.stalled
jq '.threads |= map(if .id == "description" then del(.source) else . end)' "${THREADS}" >"${S}/threads-no-source.json"
dispatch external-review code-reviewer upload n2n2n2n2n2 external-review-n2n2n2 "{\"lens\": \"security\", \"threads\": \"${S}/threads-no-source.json\"}" || echo "    external review refused: ${SAID}"
write_report external-9
stop 13b-unknown-source
fault 'a thread with no source: no human guessed' 'thread description has no source, human or bot' stamp job.stalled
dispatch review code-reviewer upload n3n3n3n3n3 review-shell-n3n3n3 "{\"lens\": \"shell\", \"base\": \"${FIX_BASE}\", \"head\": \"${FIX_HEAD}\", \"earlier\": [{\"id\": \"SHELL-01\", \"status\": \"sorted\"}], \"fix_round\": 1}" \
	|| echo "    re-review refused: ${SAID}"
check 'job.dispatched leaves the fixer'"'"'s status to the reviewer: the job was written' is "$(sh "${JOB_OF}" --effort "${effort}" --job "${JOB}" | jq -r '.earlier[0].status')" sorted
write_report re-review-5
stop 13c-earlier-without-status
fault 'an earlier finding with no fixer'"'"'s status: the check can'"'"'t run' 'have no fixer'"'"'s status of done, partly or declined' check job.ended

echo "=== every repair line of review-agent.md section 6 (fixtures/repair-lines.json)"
build_on rows b4b4b4b4b4 || exit 1
ROWS=$(tree_of rows) ROWS_BASE=${BUILD_BASE} ROWS_HEAD=${BUILD_HEAD}
rows=$(jq 'length' "${F}/repair-lines.json")
: >"${E}/repair-lines.txt"
i=0
while [ "${i}" -lt "${rows}" ]; do
	jq -c --argjson i "${i}" '.[$i]' "${F}/repair-lines.json" >"${S}/work/row.json"
	rule=$(jq -r '.rule' "${S}/work/row.json")
	kind=$(jq -r '.kind' "${S}/work/row.json")
	git -C "${ROWS}" checkout -q -- . && git -C "${ROWS}" clean -qfdx
	jq -r '.writes // [] | .[]' "${S}/work/row.json" | while IFS= read -r file; do printf 'row work\n' >>"${ROWS}/${file}"; done
	row_job=$((9000 + i))
	row_report="${effort}/reports/${kind}/${row_job}.json"
	mkdir -p "${row_report%/*}"; rm -f -- "${row_report}"
	if jq -e 'has("report")' "${S}/work/row.json" >/dev/null; then jq '.report' "${S}/work/row.json" >"${row_report}"; fi
	jq --arg tree "${ROWS}" --argjson job "${row_job}" --arg base "${ROWS_BASE}" --arg head "${ROWS_HEAD}" \
		--arg threads "${THREADS}" --argjson plan "${PLAN}" '{job: $job, state: "assigned", kind, agent_type: "code-reviewer",
		tree: $tree, report: "reports/\(.kind)/\($job).json"}
		+ (if .kind == "review" or .kind == "foreign-review" then {lens: "shell", base: $base, head: $head} else {} end)
		+ (if has("earlier") then {earlier} else {} end)
		+ (if .kind == "test-plan-challenge" then {plan: $plan} else {} end)
		+ (if .kind == "external-review" then {lens: "security", threads: $threads} else {} end)
		+ {known_failures: []} + (if .kind == "foreign-review" then {} else {iteration: 1} end)
		+ {setup: {language: "shell", standards: ["security"]}}' "${S}/work/row.json" >"${S}/work/row-job.json"
	got=$(sh "${CHECK}" --effort "${effort}" --job "${S}/work/row-job.json" 2>&1); rc=$?
	expected=$(jq -r --arg r "${row_report}" '.expected | gsub("<REPORT>"; $r)' "${S}/work/row.json")
	want_rc=1
	[ -n "${expected}" ] || want_rc=0
	printf '%s\n  exit %s: %s\n' "${rule}" "${rc}" "${got:-(accepted)}" | show >>"${E}/repair-lines.txt"
	check "${rule}" sh -c '[ "$1" -eq "$2" ] && [ "$3" = "$4" ]' _ "${rc}" "${want_rc}" "${got}" "${expected}"
	i=$((i + 1))
done

echo "=== stamping a stamped report changes nothing, so finishing a stalled hand-in may stamp again"
check 'code-reviewer is the one agent with stamp rules, so its cases below cover every agent that has them' is "$(grep -l '"stamps"' "${K}"/*/submissions/*.json | sed 's|/submissions/.*||;s|.*/||' | sort -u | tr '\n' ' ')" 'code-reviewer '
check 'the stamp step'"'"'s help says stamp rules must leave a stamped report as it is' has "$(sh "${K}/agent-submission/hooks/subagent-stop/steps/report-stamp.sh" --help)" 'Stamp rules must leave a report'
for type in review.submitted foreign-review.submitted test-plan.challenged external-review.submitted; do
	sub=$(sh "${ER}" --effort "${effort}" --type "${type}" | jq -c '[.[] | select(.by == "submission-event.sh")] | last')
	seq=$(printf '%s' "${sub}" | jq -r '.body.job')
	sh "${JOB_OF}" --effort "${effort}" --job "${seq}" | jq '.report = "reports/again/\(.job).json"' >"${S}/work/again-job.json"
	mkdir -p "${effort}/reports/again"
	again="${effort}/reports/again/${seq}.json"
	cp -- "${effort}/$(printf '%s' "${sub}" | jq -r '.body.report.path')" "${again}"
	chmod 600 "${again}"
	sh "${K}/agent-submission/hooks/subagent-stop/steps/report-stamp.sh" --effort "${effort}" --job "${S}/work/again-job.json" 2>"${S}/work/again.err"; rc=$?
	check "${type}: its pinned report stamped again is byte for byte the same" sh -c '[ "$1" -eq 0 ] && cmp -s "$2" "$3"' _ "${rc}" "${again}" "${effort}/$(printf '%s' "${sub}" | jq -r '.body.report.path')"
	rm -f -- "${again}"
done

echo
echo "=== ${pass} PASS, ${fail} FAIL"
[ "${fail}" -eq 0 ]
