#!/usr/bin/env sh
# Evidence run for the build agent's submission, through the installed
# layout: a scratch Claude folder linked with install-entries.sh's own
# commands, a scratch space, effort and repository, the jobs written from
# fixtures/ through the real event writer, and each case fed to the real
# SubagentStop hook as Claude Code feeds it. Only scratch: its own HOME and
# git config, no key; the working commits are unsigned. Exits 1 when any
# expectation fails.
# shellcheck disable=SC2016,SC2312 # single-quoted jq, sh -c and file text are meant literally; a read inside a check is what the check compares
set -u
R=/Users/cordona/IdeaProjects/cordona/claude-code-crucible/new-rewrite
E=$(cd -- "$(dirname -- "$0")" && pwd)
F="${E}/fixtures"
S=$(mktemp -d "${TMPDIR:-/tmp}/build-agent.XXXXXX") || exit 2
S=$(cd -P -- "${S}" && pwd -P)
TMP_TREE=''
trap 'rm -rf -- "${S}" ${TMP_TREE:+"${TMP_TREE}"}' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "${S}/home" "${S}/cfg" "${S}/work"
export HOME="${S}/home" GIT_CONFIG_GLOBAL="${S}/home/.gitconfig" GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME="${S}/home/.config"
export CRUCIBLE_HOME="${S}/space" CLAUDE_CONFIG_DIR="${S}/cfg" CLAUDE_CODE_SESSION_ID=sess-ba
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
VIEW="${K}/agent-jobs/scripts/internal/events-view.sh"
HOOK="${K}/agent-submission/hooks/subagent-stop/submit-agent-work.sh"
STEPS="${K}/agent-submission/hooks/subagent-stop/steps"
RECOVER="${K}/agent-submission/scripts/main/recover-submission.sh"

echo "=== install: install-entries.sh's own links and settings, then install-check.sh"
sh "${R}/framework/core/install/install-entries.sh" | sed -n '/^# Links/,/^$/p' | sed '1d' >"${S}/links.sh"
sh "${R}/framework/core/install/install-entries.sh" | sed -n '/^# Settings/,/^$/p' | sed '1d' >"${S}/settings.json"
sh "${S}/links.sh"
sh "${R}/framework/core/install/install-entries.sh" --json >"${S}/entries.json"
for name in agent-jobs agent-submission code-builder; do
	check "install-entries.sh lists the component ${name}" jq -e --arg n "${name}" 'any(.skills[]; .name == $n)' "${S}/entries.json"
done
check 'install-entries.sh maps hooks/subagent-stop to SubagentStop, for every agent' \
	jq -e '[.hooks[] | select(.event == "SubagentStop")] | length == 1 and .[0].matcher == null
		and (.[0].command_path | endswith("/skills/agent-submission/hooks/subagent-stop/submit-agent-work.sh"))' "${S}/entries.json"
check 'only submit-agent-work.sh is registered, not its steps' \
	jq -e '[.hooks[] | select(.path | contains("subagent-stop/"))] | length == 1' "${S}/entries.json"
sh "${R}/framework/core/install/install-check.sh" --settings "${S}/settings.json" >"${S}/check.out" 2>&1
check 'install-check.sh agrees: installed' is "$(cat "${S}/check.out")" installed
show <"${S}/check.out" | sed 's/^/    /'
cp -R "${R}" "${S}/twin-tree"
mkdir -p "${S}/twin-tree/domains/software-development/core/agents/git-commit"
twin=$(sh "${S}/twin-tree/framework/core/install/install-entries.sh" --json 2>&1); twin_rc=$?
echo "${twin}" | show | sed 's/^/    /'
check 'two components with one name are refused, exit 2' is "${twin_rc}" 2
check 'the refusal names both folders' has "${twin}" 'two components share a name'
check 'core'"'"'s install-check.sh knows no agent convention, only the folder contract'"'"'s names' sh -c '! grep -qE "submissions/<kind>|report-validation|code-(builder|tester)" "$1"' _ "${R}/framework/core/install/install-check.sh"
check 'nothing in core names an agent, its kinds or a submissions file' sh -c '! grep -rqE "code-builder|code-tester|build-fix|test-fix|test-plan|submissions/[a-z]" "$1/framework"' _ "${R}"
check 'nothing in agent-submission or agent-jobs names an agent or one of its kinds, but build' sh -c '! grep -rqE "code-builder|code-tester|build-fix|test-fix|test-plan|\"test\"|\"fix\"|crucible\((test|fix)\)" "$1/agents/agent-submission" "$1/main-thread/agent-jobs"' _ "${R}/domains/software-development/core"
check 'no agent includes another agent'"'"'s rules, or shared rules' sh -c '! grep -rqE "include \"(code-tester|agent-submission)/" "$1/code-builder" && ! grep -rqE "include \"(code-builder|agent-submission)/" "$1/code-tester"' _ "${R}/domains/software-development/core/agents"
check 'agent-jobs knows no agent and no approval' sh -c '! grep -rqE "code-builder|code-tester|test-plan|gate\.answered|approv" "$1"' _ "${R}/domains/software-development/core/main-thread/agent-jobs"

echo "=== every new or changed script answers --help"
for script in "${K}"/agent-jobs/scripts/internal/*.sh "${K}"/agent-submission/hooks/subagent-stop/*.sh "${K}"/agent-submission/hooks/subagent-stop/steps/*.sh \
	"${K}"/agent-submission/hooks/pre-tool-use/*.sh "${K}"/agent-submission/hooks/pre-tool-use/steps/*.sh \
	"${K}"/agent-submission/scripts/internal/*.sh "${K}"/agent-submission/scripts/main/*.sh \
	"${K}/git-commit/scripts/main/commit-tree.sh" "${R}/framework/core/install/install-entries.sh"; do
	out=$(sh "${script}" --help 2>&1); rc=$?
	check "${script##*/} --help" sh -c '[ "$1" -eq 0 ] && printf "%s" "$2" | grep -q "^usage: " && printf "%s" "$2" | grep -q "^Exit:"' _ "${rc}" "${out}"
done
check 'report-hash.sh --help' sh "${K}/agent-jobs/scripts/internal/report-hash.sh" --help
check 'commit-message.sh --help no longer says "No effort key"' sh -c '! sh "$1" --help | grep -q "No effort key"' _ "${K}/git-commit/scripts/main/commit-message.sh"
check 'event-write.sh --help names the rules'"'"' search path' has "$(sh "${EW}" --help)" 'include "<component>/scripts/lib/<module>"'
check 'no rule includes a lib by a relative search path' sh -c '! grep -rq "search:" "$1"/agent-jobs/events "$1"/code-builder/events "$1"/code-tester/events' _ "${K}"
check 'the domain no longer sources crucible-events'"'"' sha256.sh' sh -c '! grep -rq "sha256.sh" "$1"/main-thread/agent-jobs "$1"/agents' _ "${R}/domains/software-development/core"
check 'commit-message.sh --help takes the job'"'"'s kind, with no list of kinds' sh -c 'h=$(sh "$1" --help); printf "%s" "$h" | grep -q "takes its job.s kind" && ! printf "%s" "$h" | grep -qE "crucible\((build|fix|test)\)"' _ "${K}/git-commit/scripts/main/commit-message.sh"
check 'trailers.sh lists no kinds' sh -c '! grep -qE "build or fix|crucible\((build|fix|test)\)" "$1"' _ "${K}/agent-submission/scripts/lib/trailers.sh"
check 'agent-submission holds no report rules and no event rule: plumbing only' sh -c '[ "$(ls "$1/agent-submission/scripts/lib")" = "$(printf "stamps.jq\nstop-lock.sh\ntrailers.sh")" ] && [ ! -e "$1/agent-submission/events" ]' _ "${K}"
check 'code-builder owns its rules: a common lib and one rules file per kind' sh -c 'cd "$1/code-builder/scripts/lib" && [ "$(ls)" = "$(printf "build-fix-report.jq\nbuild-report.jq\nbuilder-common.jq")" ]' _ "${K}"
check 'code-builder lists what it hands in, one submissions file per kind' sh -c '[ "$(ls "$1/code-builder/submissions")" = "$(printf "build-fix.json\nbuild.json")" ]' _ "${K}"
for kind in build build-fix; do
	check "code-builder's submissions/${kind}.json names its event ${kind}.submitted, commit, rules and def, all installed" sh -c 'f="$1/code-builder/submissions/$2.json"; jq -e --arg e "$2.submitted" ".event == \$e and (.commit | type) == \"boolean\" and (.problems | type) == \"string\"" "$f" && [ -f "$1/$(jq -r .rules "$f").jq" ] && [ -f "$1/code-builder/events/$2.submitted.jq" ]' _ "${K}" "${kind}"
done
check 'the kind and its event are paired only in the submissions file' sh -c '! grep -rqE "jobs_submission_problems\(" "$1"/code-builder/events' _ "${K}"
check 'code-builder names no other agent' sh -c '! grep -rq "code-tester" "$1/code-builder/"' _ "${K}"
check 'the plumbing'"'"'s contract with a report is stated in the hook'"'"'s help' sh -c 'sh "$1" --help | grep -q "one JSON object" && sh "$1" --help | grep -q "a summary, the commit"' _ "${HOOK}"
check 'commit-tree.sh --help names --unsigned' has "$(sh "${K}/git-commit/scripts/main/commit-tree.sh" --help)" '--unsigned'

echo "=== set-up: a scratch repository, an effort, its identity (no key), seven trees"
repo="${S}/repo"
git init -q -b main "${repo}"
mkdir -p "${repo}/app/Upload" "${repo}/tests/Upload" "${repo}/config" "${repo}/.deploy/helm"
awk 'BEGIN { for (i = 1; i <= 88; i++) printf "// Client.php line %d\n", i }' >"${repo}/app/Upload/Client.php"
awk 'BEGIN { for (i = 1; i <= 30; i++) printf "// Auth.php line %d\n", i }' >"${repo}/app/Upload/Auth.php"
awk 'BEGIN { for (i = 1; i <= 90; i++) printf "// UploadClientTest.php line %d\n", i }' >"${repo}/tests/Upload/UploadClientTest.php"
awk 'BEGIN { for (i = 1; i <= 40; i++) printf "# values line %d\n", i }' >"${repo}/.deploy/helm/values.prod.yaml"
printf 'APP_ENV=dev\nAPP_DEBUG=true\nCLOUD_KEY=placeholder\n' >"${repo}/config/dev.env"
printf '#!/bin/sh\n# a.sh\necho $1\n' >"${repo}/a.sh"
printf '#!/bin/sh\n# b.sh: takes the word input\necho "$input"\n' >"${repo}/b.sh"
git -C "${repo}" add -A
git -C "${repo}" -c user.name=Fixture -c user.email=fixture@example.test commit -q -m 'the project'
effort=$(sh "${K}/crucible-effort/scripts/main/effort-start.sh" --name 'upload retries') || { echo 'effort-start failed'; exit 1; }
effort_name=${effort##*/}
repo_main=$(sh "${K}/dev-base/scripts/internal/repo-of.sh" --dir "${repo}" | jq -r '.repo')
jq -n --arg repo "${repo_main}" '{repo: $repo, name: "Build Agent", email: "build-agent@example.test",
	signing: {format: "ssh", key: "/nonexistent/fixture-key.pub"}, fingerprint: "", answer: 1}' >"${S}/identity.json"
sh "${EW}" --effort "${effort}" --type identity.set --by identity-set.sh --body-file "${S}/identity.json" >/dev/null
for t in upload retry quote recover sketch lines-changed lines-clean; do
	sh "${K}/git-worktree/scripts/main/worktree-cut.sh" --effort "${effort}" --repo "${repo}" --name "${t}" --from checkout >/dev/null \
		|| { echo "worktree-cut ${t} failed"; exit 1; }
done
tree_of() { printf '%s/worktrees/%s' "${effort}" "$1"; }
echo "    effort ${effort_name}; trees: upload retry quote recover sketch lines-changed lines-clean"
mkdir -p "${effort}/reports"

events_count() { sh "${ER}" --effort "${effort}" --paths | wc -l | tr -d ' '; }
# Writes job KEY from fixtures/jobs.json: job.dispatched, then job.assigned;
# sets JOB to its seq.
dispatch() {
	JOB=$(($(events_count) + 1))
	KIND=$(jq -r --arg k "$1" '.[$k].dispatched.kind' "${F}/jobs.json")
	jq --arg key "$1" --arg tree "$(tree_of "$(jq -r --arg k "$1" '.[$k].tree' "${F}/jobs.json")")" --arg report "reports/${KIND}/${JOB}.json" '
		.[$key].dispatched as $d
		| {kind: $d.kind, agent_type: $d.agent_type, tree: $tree, report: $report}
		+ ($d | with_entries(select(.key == "findings" or .key == "sent_back")))
		+ {known_failures: $d.known_failures, iteration: $d.iteration}
		+ ($d | with_entries(select(.key == "fix_round")))
		+ {setup: $d.setup}' "${F}/jobs.json" >"${S}/work/dispatched.json"
	sh "${EW}" --effort "${effort}" --type job.dispatched --by job-dispatch.sh --body-file "${S}/work/dispatched.json" >/dev/null \
		|| { echo "    job.dispatched ${1} refused"; fail=$((fail + 1)); return 1; }
	jq --arg key "$1" --argjson job "${JOB}" '{job: $job, agent: .[$key].agent, name: .[$key].name, session: "sess-ba"}' "${F}/jobs.json" >"${S}/work/assigned.json"
	sh "${EW}" --effort "${effort}" --type job.assigned --by assign-job.sh --body-file "${S}/work/assigned.json" >/dev/null \
		|| { echo "    job.assigned ${1} refused"; fail=$((fail + 1)); return 1; }
	AGENT=$(jq -r --arg k "$1" '.[$k].agent' "${F}/jobs.json")
	TREE=$(tree_of "$(jq -r --arg k "$1" '.[$k].tree' "${F}/jobs.json")")
	REPORT="${effort}/reports/${KIND}/${JOB}.json"
}
# The builder hands in: its report from fixtures/reports/$1.
write_report() { mkdir -p "${REPORT%/*}"; cp -- "${F}/reports/$1" "${REPORT}"; chmod 600 "${REPORT}"; }
# Feeds the hook the JSON Claude Code gives a SubagentStop; case folder $1.
stop() {
	BEFORE=$(events_count)
	HEAD_BEFORE=$(git -C "${TREE}" rev-parse HEAD)
	jq -cn --arg agent "${AGENT}" --arg cwd "${TREE}" --arg s "${S}" '{session_id: "sess-ba",
		transcript_path: ($s + "/transcript.jsonl"), cwd: $cwd, permission_mode: "acceptEdits",
		hook_event_name: "SubagentStop", stop_hook_active: false, agent_id: $agent, agent_type: "code-builder",
		agent_transcript_path: ($s + "/agent-\($agent).jsonl"), last_assistant_message: "Done; my report is written."}' \
		| sh "${HOOK}" >"${S}/work/hook.out" 2>"${S}/work/hook.err"
	HOOK_RC=$?
	HOOK_OUT=$(cat "${S}/work/hook.out")
	save "$1"
}
# Saves case folder $1: report.json, hook-output.txt, event.json, commit.txt.
save() {
	dir="${E}/$1"
	rm -rf -- "${dir}"; mkdir -p "${dir}"
	if [ -f "${REPORT}" ]; then cp -- "${REPORT}" "${dir}/report.json"; chmod 644 "${dir}/report.json"; else echo none >"${dir}/report.json"; fi
	{ cat "${S}/work/hook.out"; [ ! -s "${S}/work/hook.err" ] || sed 's/^/stderr: /' "${S}/work/hook.err"; echo "exit ${HOOK_RC}"; } | show >"${dir}/hook-output.txt"
	sh "${ER}" --effort "${effort}" | jq --argjson n "${BEFORE}" '[.[] | select(.seq > $n)] | if length == 0 then "none" else . end' \
		| show >"${dir}/event.json"
	EVENT=$(sh "${ER}" --effort "${effort}" | jq -c --argjson n "${BEFORE}" '[.[] | select(.seq > $n)] | last // empty')
	HEAD_AFTER=$(git -C "${TREE}" rev-parse HEAD)
	if [ "${HEAD_AFTER}" != "${HEAD_BEFORE}" ]; then
		{ git -C "${TREE}" log -1 --format=%B; git -C "${TREE}" show --stat --format='commit %H%nAuthor: %an <%ae>%nSigned: %G?' HEAD; } | show >"${dir}/commit.txt"
	else
		echo none >"${dir}/commit.txt"
	fi
	sed 's/^/    /' "${dir}/hook-output.txt"
}
ev() { printf '%s' "${EVENT}" | jq -r "$1"; }
message_of() { git -C "${TREE}" log -1 --format=%B; }
sum256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum -- "$1" | cut -d ' ' -f 1; else shasum -a 256 -- "$1" | cut -d ' ' -f 1; fi; }
read_only() { [ -n "$(find "$1" -prune -perm 0444)" ]; }

echo "=== 1a: a clean build, iteration 1"
dispatch build-1
printf '// retry only on 5xx\n' >>"${TREE}/app/Upload/Client.php"
write_report 1a.json
stop 1a-build-iteration-1
JOB_1A=${JOB} REPORT_1A=${REPORT} COMMIT_1A=$(ev '.body.commit')
check 'the stop goes through: no output, exit 0' sh -c '[ -z "$1" ] && [ "$2" -eq 0 ]' _ "${HOOK_OUT}" "${HOOK_RC}"
check 'build.submitted, by submission-event.sh' is "$(ev '.type + " " + .by')" 'build.submitted submission-event.sh'
check 'the body prints job, iteration, agent, report, commit, in that order' is "$(ev '.body | keys_unsorted | join(",")')" 'job,iteration,agent,report,commit'
check 'iteration 1, the job and agent stamped' is "$(ev '"\(.body.job) \(.body.iteration) \(.body.agent)"')" "${JOB} 1 af6bac0101"
check 'report {path, sha256}: reports/build/<job seq>.json and its hash' is "$(ev '.body.report | "\(.path) \(.sha256)"')" "reports/build/${JOB}.json $(sum256 "${REPORT}")"
check 'the report is pinned read-only' read_only "${REPORT}"
check 'the empty impact list was pruned before the pin' jq -e 'has("impact") | not' "${REPORT}"
check 'the commit is the tree'"'"'s new HEAD' is "$(git -C "${TREE}" rev-parse HEAD)" "${COMMIT_1A}"
check 'the working commit is unsigned' is "$(git -C "${TREE}" log -1 --format=%G?)" N
check 'the commit message: subject, the whole summary as the body, then Effort, Job, Iteration and the setup' is "$(message_of)" "crucible(build): add a retry limit to the upload client

add a retry limit to the upload client

Effort: ${effort_name}
Job: ${JOB} build-php-af6bac
Iteration: 1
Language: php
Framework: laravel
Standards: security, observability, persistence"
check 'the report is never committed' sh -c '! git -C "$1" show --stat HEAD | grep -q reports/' _ "${TREE}"
check 'the commit is on the effort'"'"'s branch' is "$(git -C "${TREE}" symbolic-ref HEAD)" "refs/heads/crucible/${effort_name}/upload"

echo "=== 1b: a second build on the same tree, iteration 2"
dispatch build-2
printf '// log each retry\n' >>"${TREE}/app/Upload/Client.php"
write_report 1b.json
stop 1b-build-iteration-2
check 'build.submitted, iteration 2' is "$(ev '"\(.type) \(.body.iteration)"')" 'build.submitted 2'
check 'Iteration: 2 in the commit' has "$(message_of)" 'Iteration: 2'
check 'its parent is the first build'"'"'s commit' is "$(git -C "${TREE}" rev-parse HEAD~1)" "${COMMIT_1A}"

echo "=== the iteration is counted once: a wrong stamp on a dispatch is refused"
jq --arg tree "$(tree_of upload)" --arg report "reports/build/$(($(events_count) + 1)).json" '.["build-2"].dispatched
	| {kind, agent_type, tree: $tree, report: $report, known_failures, iteration, setup}' "${F}/jobs.json" >"${S}/work/wrong.json"
said=$(sh "${EW}" --effort "${effort}" --type job.dispatched --by job-dispatch.sh --body-file "${S}/work/wrong.json" 2>&1); rc=$?
echo "    ${said}" | show
check 'a build stamped iteration 2 when 3 is next is refused' sh -c '[ "$1" -eq 2 ] && printf "%s" "$2" | grep -qF "iteration must be 3"' _ "${rc}" "${said}"
jq '.iteration = 3 | .report = "reports/\(.report | split("/") | last)"' "${S}/work/wrong.json" >"${S}/work/flat.json"
said=$(sh "${EW}" --effort "${effort}" --type job.dispatched --by job-dispatch.sh --body-file "${S}/work/flat.json" 2>&1); rc=$?
echo "    ${said}" | show
check 'a report path without its kind folder is refused' sh -c '[ "$1" -eq 2 ] && printf "%s" "$2" | grep -qF "report must be reports/build/"' _ "${rc}" "${said}"

echo "=== 2: a build with a known failure: no blocker needed"
dispatch build-known-failure
printf '// retry limit from UPLOAD_RETRY_LIMIT\n' >>"${TREE}/app/Upload/Client.php"
write_report 2.json
stop 2-known-failure
check 'accepted: the stop goes through' sh -c '[ -z "$1" ] && [ "$2" -eq 0 ]' _ "${HOOK_OUT}" "${HOOK_RC}"
check 'build.submitted, iteration 3, with a commit' is "$(ev '"\(.type) \(.body.iteration) \(.body | has("commit"))"')" 'build.submitted 3 true'
check 'the pinned report keeps its fail gate' jq -e '.gates[1].result == "fail"' "${REPORT}"

echo "=== 3: a blocked build: no commit, and the event has no commit field"
dispatch build-blocked
write_report 3.json
stop 3-blocked
check 'accepted: the stop goes through' sh -c '[ -z "$1" ] && [ "$2" -eq 0 ]' _ "${HOOK_OUT}" "${HOOK_RC}"
check 'build.submitted with no commit field' is "$(ev '"\(.type) \(.body | has("commit"))"')" 'build.submitted false'
check 'the body prints job, iteration, agent, report' is "$(ev '.body | keys_unsorted | join(",")')" 'job,iteration,agent,report'
check 'no commit was made' is "$(git -C "${TREE}" rev-parse HEAD)" "${HEAD_BEFORE}"
check 'commit.txt says none' is "$(cat "${E}/3-blocked/commit.txt")" none

echo "=== 4a: a refused report shows its repair lines"
dispatch build-gives-up
printf '// backoff\n' >>"${TREE}/app/Upload/Client.php"
write_report 4a.json
stop 4a-refused
check 'the stop is held: decision block' is "$(printf '%s' "${HOOK_OUT}" | jq -r '.decision')" block
reason=$(printf '%s' "${HOOK_OUT}" | jq -r '.reason')
check 'a 60-character summary is no refusal: no length is checked' sh -c '! printf "%s" "$1" | grep -q "^summary"' _ "${reason}"
check 'the repair lines: the note' has "${reason}" 'gates[0] is not_run: add a note saying why'
check 'the repair lines: the unknown key' has "${reason}" 'unknown key "verification"; the keys are summary, gates, decisions, impact, noticed, questions, blockers'
check 'job.refused try 1, by held-stop.sh, its lines the repair lines' is "$(ev '"\(.type) \(.by) \(.body.try) \(.body.lines | length)"')" 'job.refused held-stop.sh 1 2'
check 'its stamps are the job'"'"'s' is "$(ev '.body | "\(.job) \(.iteration) \(.agent)"')" "${JOB} 1 e1a8350505"
check 'no submission, no commit, no .held file' sh -c '[ "$(jq "length" "$1")" -eq 1 ] && [ "$2" = none ] && [ ! -e "$3/stops/$4.held" ]' _ "${E}/4a-refused/event.json" "$(cat "${E}/4a-refused/commit.txt")" "${effort}" "${JOB}"
check 'the refused report is not pinned' test -w "${REPORT}"

echo "=== 4b: the second refusal ends the job: job.ended (gave-up)"
write_report 4b.json
stop 4b-gave-up
check 'the stop goes through: no block' sh -c '! printf "%s" "$1" | jq -e ".decision" >/dev/null' _ "${HOOK_OUT}"
check 'the human is told it gave up' has "$(printf '%s' "${HOOK_OUT}" | jq -r '.systemMessage')" "job ${JOB} (build-php-e1a835) gave up"
check 'job.refused try 2, then job.ended, both by held-stop.sh' is "$(jq -r '[.[] | "\(.type) \(.body.try // .body.reason)"] | join(", ")' "${E}/4b-gave-up/event.json")" 'job.refused 2, job.ended gave-up'
check 'job.ended, by held-stop.sh' is "$(ev '.type + " " + .by')" 'job.ended held-stop.sh'
check 'its body: job, iteration, agent, reason gave-up' is "$(ev '.body | to_entries | map("\(.key)=\(.value)") | join(",")')" "job=${JOB},iteration=1,agent=e1a8350505,reason=gave-up"
check 'the tree is kept, with its change uncommitted' sh -c 'git -C "$1" status --porcelain | grep -q Client.php' _ "${TREE}"
check 'the job is ended' is "$(sh "${JOB_OF}" --effort "${effort}" --job "${JOB}" | jq -r '.state')" ended
aside=$(printf '%s' '{"agent_id": "e1a8350505", "agent_type": "code-builder", "session_id": "sess-ba", "hook_event_name": "SubagentStop"}' | sh "${HOOK}"); rc=$?
check 'A0 is left alone for an agent whose job is done: a later stop stands aside, no output, exit 0' sh -c '[ -z "$1" ] && [ "$2" -eq 0 ]' _ "${aside}" "${rc}"
jq --arg tree "$(tree_of retry)" --arg report "reports/build/$(($(events_count) + 1)).json" '.["build-gives-up"].dispatched
	| {kind, agent_type, tree: $tree, report: $report, known_failures, iteration, setup}' "${F}/jobs.json" >"${S}/work/replacement.json"
check 'the replacement of the build that gave up keeps iteration 1' sh "${EW}" --effort "${effort}" --type job.dispatched --by job-dispatch.sh --body-file "${S}/work/replacement.json"

echo "=== 5: a fix with done, partly and declined"
dispatch build-quote
printf 'target=$1\n' >>"${TREE}/a.sh"
write_report quote-build.json
stop 5-quote-build
check 'the build under the fix: build.submitted, iteration 1' is "$(ev '"\(.type) \(.body.iteration)"')" 'build.submitted 1'
check 'a setup with no framework: no Framework trailer' is "$(message_of)" "crucible(build): read the upload target from the first argument

read the upload target from the first argument

Effort: ${effort_name}
Job: ${JOB} build-shell-f05b2c
Iteration: 1
Language: shell
Standards: security, clean-code
Model: opus"
dispatch fix-1
printf '#!/bin/sh\n# a.sh\necho "$1"\ntarget="$1"\n' >"${TREE}/a.sh"
write_report 5.json
stop 5-fix
check 'accepted: the stop goes through' sh -c '[ -z "$1" ] && [ "$2" -eq 0 ]' _ "${HOOK_OUT}" "${HOOK_RC}"
check 'build-fix.submitted, iteration 1, fix round 1' is "$(ev '"\(.type) \(.body.iteration) \(.body.fix_round)"')" 'build-fix.submitted 1 1'
check 'a build-fix report lives at reports/build-fix/<job seq>.json' is "$(ev '.body.report.path')" "reports/build-fix/${JOB}.json"
check 'the body prints job, iteration, fix_round, agent, report, commit' is "$(ev '.body | keys_unsorted | join(",")')" 'job,iteration,fix_round,agent,report,commit'
check 'the builder reused for the fix keeps its agent id' is "$(ev '.body.agent')" f05b2c0606
check 'the trailers: Effort, Job, Iteration, Fix-Round, then the setup with Model' is "$(message_of)" "crucible(build-fix): quote variables in a.sh and b.sh

quote variables in a.sh and b.sh

Effort: ${effort_name}
Job: ${JOB} fix-shell-f05b2c
Iteration: 1
Fix-Round: 1
Language: shell
Standards: security, clean-code
Model: opus"
check 'the pinned report holds the three fixes' is "$(jq -r '[.fixes[].status] | join(",")' "${REPORT}")" 'done,partly,declined'

echo "=== 6a: a fix that declines a finding the human sent back is refused"
dispatch fix-sent-back
write_report 6a.json
stop 6a-sent-back-declined
check 'held, with the spec'"'"'s line' has "$(printf '%s' "${HOOK_OUT}" | jq -r '.reason')" "CLEAN-CODE-01 was sent back by the human: it can't be declined again; fix it, or add a cannot blocker"
check 'a refusal: job.refused try 1, no submission, no commit, no .held file' sh -c '[ "$(jq -r "[.[] | .type + \" \" + (.body.try | tostring)] | join(\",\")" "$1")" = "job.refused 1" ] && [ "$2" = none ] && [ ! -e "$3/stops/$4.held" ]' _ "${E}/6a-sent-back-declined/event.json" "$(cat "${E}/6a-sent-back-declined/commit.txt")" "${effort}" "${JOB}"

echo "=== 6b: the same fix with a cannot blocker is accepted"
write_report 6b.json
stop 6b-cannot-blocker
check 'then accepted: the stop goes through' sh -c '[ -z "$1" ] && [ "$2" -eq 0 ]' _ "${HOOK_OUT}" "${HOOK_RC}"
check 'fix.submitted, iteration 1, fix round 1 of its own loop, no commit' is "$(ev '"\(.type) \(.body.iteration) \(.body.fix_round) \(.body | has("commit"))"')" 'build-fix.submitted 1 1 false'
check 'the pinned report holds the cannot blocker' jq -e '.blockers[0].kind == "cannot"' "${REPORT}"

echo "=== 7: a report changed after submission is refused by the view"
view_before=$(sh "${VIEW}" --effort "${effort}" 2>&1); rc=$?
check 'before: the view joins each submission to its report' sh -c '[ "$1" -eq 0 ] && printf "%s" "$2" | jq -e "[.[] | select(.type | endswith(\".submitted\"))] | length > 0 and all(.[]; .report.summary | type == \"string\")"' _ "${rc}" "${view_before}"
cp -p -- "${REPORT_1A}" "${S}/work/1a.pinned"
chmod u+w "${REPORT_1A}"
jq '.summary = "a summary changed after the pin"' "${S}/work/1a.pinned" >"${REPORT_1A}"
BEFORE=$(events_count) TREE=$(tree_of upload) HEAD_BEFORE=$(git -C "$(tree_of upload)" rev-parse HEAD) REPORT=${REPORT_1A}
sh "${VIEW}" --effort "${effort}" >"${S}/work/hook.out" 2>"${S}/work/hook.err"; HOOK_RC=$?
save 7-changed-report
check 'the view refuses: exit 5, nothing printed' sh -c '[ "$1" -eq 5 ] && [ ! -s "$2" ]' _ "${HOOK_RC}" "${S}/work/hook.out"
check 'the line the human sees names the event, the report and both hashes' \
	grep -Eq "^events-view.sh: event [0-9]+ \(build.submitted\) pinned reports/build/${JOB_1A}.json at sha256 [0-9a-f]{12}, but it changed after it was submitted: it is now [0-9a-f]{12}; nothing reads it until a human looks$" "${S}/work/hook.err"
cp -p -- "${S}/work/1a.pinned" "${REPORT_1A}"
check 'restored byte for byte, the view reads again' sh "${VIEW}" --effort "${effort}" --type 'build.*'

echo "=== 8: a stalled job whose working commit was made, its event not: --finish writes it with that commit"
dispatch build-recover
printf '// at most three retries\n' >>"${TREE}/app/Upload/Client.php"
write_report 8.json
sh "${JOB_OF}" --effort "${effort}" --job "${JOB}" >"${S}/work/job.json"
# The hook's steps up to the commit; then it dies before the event, and its
# exit trap records the job stalled.
sh "${STEPS}/report-validation.sh" --effort "${effort}" --job "${S}/work/job.json"
sh "${STEPS}/report-pin.sh" --report "${REPORT}" >/dev/null
made=$(sh "${STEPS}/working-commit.sh" --effort "${effort}" --job "${S}/work/job.json")
sh "${STEPS}/fault-stalled.sh" --effort "${effort}" --job "${S}/work/job.json" --step hook --fault 'the hook ended before its event'
check 'the working commit was made, and the job is stalled' sh -c '[ -n "$1" ] && [ "$(sh "$2" --effort "$3" --job "$4" | jq -r .state)" = stalled ]' _ "${made}" "${JOB_OF}" "${effort}" "${JOB}"
BEFORE=$(events_count) HEAD_BEFORE=$(git -C "${TREE}" rev-parse HEAD~1)
sh "${RECOVER}" --effort "${effort}" --job "${JOB}" --finish >"${S}/work/hook.out" 2>"${S}/work/hook.err"; HOOK_RC=$?
save 8-recovered
check 'finished: exit 0' is "${HOOK_RC}" 0
check 'build.submitted, by recover-submission.sh' is "$(ev '.type + " " + .by')" 'build.submitted recover-submission.sh'
check 'its body is the hook'"'"'s: job, iteration 1, agent, report, the commit found by its Job trailer' is "$(ev '"\(.body | keys_unsorted | join(",")) \(.body.job) \(.body.iteration) \(.body.agent) \(.body.commit)"')" "job,iteration,agent,report,commit ${JOB} 1 a7c9e40808 ${made}"
check 'no second commit: HEAD is still the working commit' is "$(git -C "${TREE}" rev-parse HEAD)" "${made}"
check 'its report pin matches the report' is "$(ev '.body.report.sha256')" "$(sum256 "${REPORT}")"
sh "${RECOVER}" --effort "${effort}" --job "${JOB}" --finish >/dev/null 2>"${S}/work/again.err"; rc=$?
sed 's/^/    /' "${S}/work/again.err" | show
check 'a second finish has nothing to do: exit 3' is "${rc}" 3

echo "=== 9: an agent whose component lacks its submissions/<kind>.json: a fault for the human"
sketcher="${S}/extra/code-sketcher"
mkdir -p "${sketcher}/events"
printf '%s\n' '# sketch.submitted: the same job check every agent'"'"'s submission rule uses.' \
	'include "agent-jobs/scripts/lib/jobs";' 'jobs_submission_problems' >"${sketcher}/events/sketch.submitted.jq"
ln -s "${sketcher}" "${K}/code-sketcher"
dispatch build-sketch
printf '// sketched\n' >>"${TREE}/app/Upload/Client.php"
write_report 8.json
stop 9-missing-submission-file
check 'the stop goes through: no block, exit 0' sh -c '[ "$2" -eq 0 ] && ! printf "%s" "$1" | jq -e ".decision" >/dev/null' _ "${HOOK_OUT}" "${HOOK_RC}"
check 'the human is told the install fault, naming the file' has "$(printf '%s' "${HOOK_OUT}" | jq -r '.systemMessage')" 'code-sketcher has no submissions/build.json'
check 'a fault before acceptance: job.ended fault at step check, by fault-ended.sh, naming the file' is "$(ev '"\(.type) \(.by) \(.body.reason) \(.body.step)"')" 'job.ended fault-ended.sh fault check'
check 'its fault is the line the human was told' has "$(printf '%s' "${HOOK_OUT}" | jq -r '.systemMessage')" "$(ev '.body.fault')"
check 'no refusal, no submission, no commit' sh -c '[ "$(jq "length" "$1")" -eq 1 ] && [ "$2" = none ]' _ "${E}/9-missing-submission-file/event.json" "$(cat "${E}/9-missing-submission-file/commit.txt")"
check 'the report is not pinned' test -w "${REPORT}"
check 'the job is ended' is "$(sh "${JOB_OF}" --effort "${effort}" --job "${JOB}" | jq -r '.state')" ended

echo "=== 10: another component's submission rule uses agent-jobs' shared job check through the search path"
dispatch build-sketch-2
write_report 8.json
sh "${JOB_OF}" --effort "${effort}" --job "${JOB}" >"${S}/work/job.json"
jq --arg sha "$(sum256 "${REPORT}")" '{job, iteration: (.iteration + 1), agent, report: {path: .report, sha256: $sha}}' "${S}/work/job.json" >"${S}/work/wrong.json"
said=$(sh "${EW}" --effort "${effort}" --type sketch.submitted --by submission-event.sh --body-file "${S}/work/wrong.json" 2>&1); rc=$?
echo "    ${said}" | show
check 'a wrong stamp is refused with the shared check'"'"'s line' sh -c '[ "$1" -eq 2 ] && printf "%s" "$2" | grep -qF "iteration must be job $3'"'"'s, 1"' _ "${rc}" "${said}" "${JOB}"
jq --arg sha "$(sum256 "${REPORT}")" '{job, iteration, agent, report: {path: .report, sha256: $sha}}' "${S}/work/job.json" >"${S}/work/right.json"
check 'the right body is accepted' sh "${EW}" --effort "${effort}" --type sketch.submitted --by submission-event.sh --body-file "${S}/work/right.json"
check 'the job is now submitted' is "$(sh "${JOB_OF}" --effort "${effort}" --job "${JOB}" | jq -r '.state')" submitted

echo "=== 11: a submission file naming rules that aren't installed: a fault for the human"
mkdir -p "${sketcher}/submissions"
printf '{"event": "sketch.submitted", "commit": true, "rules": "code-sketcher/scripts/lib/sketch-report", "problems": "sketch_problems"}\n' \
	>"${sketcher}/submissions/build.json"
dispatch build-sketch-3
printf '// sketched again\n' >>"${TREE}/app/Upload/Client.php"
write_report 8.json
stop 11-rules-not-installed
check 'the stop goes through: no block, exit 0' sh -c '[ "$2" -eq 0 ] && ! printf "%s" "$1" | jq -e ".decision" >/dev/null' _ "${HOOK_OUT}" "${HOOK_RC}"
check 'the human is told which rules are missing' has "$(printf '%s' "${HOOK_OUT}" | jq -r '.systemMessage')" "code-sketcher/submissions/build.json names the rules code-sketcher/scripts/lib/sketch-report, which aren't installed"
check 'job.ended fault at step check, and nothing else' is "$(jq -r '[.[] | "\(.type) \(.body.reason) \(.body.step)"] | join(",")' "${E}/11-rules-not-installed/event.json")" 'job.ended fault check'
rm -- "${K}/code-sketcher"

echo "=== the stop hook's outcomes: a stand-in job agent, whose submission file each case sets"
standin="${S}/extra/code-standin"
mkdir -p "${standin}/events" "${standin}/submissions" "${standin}/scripts/lib" "${standin}/scripts/internal"
printf '%s\n' '# standin.submitted: the job check every submission rule uses.' \
	'include "agent-jobs/scripts/lib/jobs";' 'jobs_submission_problems' >"${standin}/events/standin.submitted.jq"
printf '%s\n' '# A stand-in'"'"'s stamps: one that stops, one that changes nothing.' \
	'def stamp_fail: error("the stand-in'"'"'s stamp rules stop");' 'def stamp_none: .report;' >"${standin}/scripts/lib/standin-stamps.jq"
printf '%s\n' '#!/bin/sh' '# Slow facts: long enough for a signal to arrive while they run.' 'sleep 3' "printf '{}\\n'" >"${standin}/scripts/internal/slow-facts.sh"
ln -s "${standin}" "${K}/code-standin"
# submission [JQ]: the stand-in's submissions/build.json, the builder's rules,
# changed by JQ.
submission() {
	jq -n "{event: \"standin.submitted\", commit: true, rules: \"code-builder/scripts/lib/build-report\", problems: \"build_report_problems\"} | ${1:-.}" \
		>"${standin}/submissions/build.json"
}
# standin_job TREE AGENT: a fresh tree cut, a build dispatched there for the
# stand-in and assigned; sets JOB, AGENT, TREE, REPORT. A third word "only"
# dispatches and leaves the assignment out.
standin_job() {
	sh "${K}/git-worktree/scripts/main/worktree-cut.sh" --effort "${effort}" --repo "${repo}" --name "$1" --from checkout >/dev/null || return 1
	TREE=$(tree_of "$1") AGENT=$2 JOB=$(($(events_count) + 1)) KIND=build
	REPORT="${effort}/reports/build/${JOB}.json"
	jq -n --arg tree "${TREE}" --arg report "reports/build/${JOB}.json" '{kind: "build", agent_type: "code-standin", tree: $tree,
		report: $report, known_failures: [], iteration: 1, setup: {language: "php", standards: ["security"]}}' >"${S}/work/dispatched.json"
	sh "${EW}" --effort "${effort}" --type job.dispatched --by job-dispatch.sh --body-file "${S}/work/dispatched.json" >/dev/null || return 1
	[ "${3-}" = only ] || assign
	printf '// %s\n' "$1" >>"${TREE}/app/Upload/Client.php"
}
assign() {
	jq -n --argjson job "${JOB}" --arg agent "${AGENT}" '{job: $job, agent: $agent, name: "build-php-\($agent[:6])", session: "sess-ba"}' >"${S}/work/assigned.json"
	sh "${EW}" --effort "${effort}" --type job.assigned --by assign-job.sh --body-file "${S}/work/assigned.json" >/dev/null
}
stop_as() { # stop_as TYPE CASE: the stop of AGENT, its agent_type TYPE; stop_hook_active STOP_ACTIVE, default false
	BEFORE=$(events_count)
	HEAD_BEFORE=$(git -C "${TREE}" rev-parse HEAD)
	jq -cn --arg agent "${AGENT}" --arg type "$1" --argjson active "${STOP_ACTIVE:-false}" '{session_id: "sess-ba", hook_event_name: "SubagentStop",
		stop_hook_active: $active, agent_id: $agent, agent_type: $type, last_assistant_message: "Done."}' >"${S}/work/stop.json"
	sh "${HOOK}" <"${S}/work/stop.json" >"${S}/work/hook.out" 2>"${S}/work/hook.err"
	HOOK_RC=$?
	HOOK_OUT=$(cat "${S}/work/hook.out")
	save "$2"
}
told() { printf '%s' "${HOOK_OUT}" | jq -r '.systemMessage // ""'; }
state_of() { sh "${JOB_OF}" --effort "${effort}" --job "$1" | jq -r '.state'; }
finish() { # finish JOB: --finish, FINISH_RC and FINISH_SAID; EVENT the last event
	FINISH_SAID=$(sh "${RECOVER}" --effort "${effort}" --job "$1" --finish 2>&1); FINISH_RC=$?
	EVENT=$(sh "${ER}" --effort "${effort}" | jq -c 'last')
}
# stalled STEP CASE: the stop went through, no block, job.stalled at STEP by
# fault-stalled.sh, the human told of it, and the job is stalled.
stalled() {
	check "$2: the stop goes through, the human told the report is kept" sh -c '[ "$2" -eq 0 ] && ! printf "%s" "$1" | jq -e ".decision" >/dev/null && printf "%s" "$1" | jq -r .systemMessage | grep -qF "agent-submission/scripts/main/recover-submission.sh --effort"' _ "${HOOK_OUT}" "${HOOK_RC}"
	check "$2: job.stalled at step $1, by fault-stalled.sh, and only that" is "$(jq -r '[.[] | "\(.type) \(.by) \(.body.step)"] | join(",")' "${E}/$2/event.json")" "job.stalled fault-stalled.sh $1"
	check "$2: the job is stalled" is "$(state_of "${JOB}")" stalled
}
# finished CASE: --finish wrote the submission, pinned, by recover-submission.sh.
finished() {
	printf '%s\n' "${FINISH_SAID}" | show | sed 's/^/    finish: /'
	check "$1: --finish writes standin.submitted by recover-submission.sh" sh -c '[ "$1" -eq 0 ] && printf "%s" "$2" | jq -e ".type == \"standin.submitted\" and .by == \"recover-submission.sh\"" && [ "$(sh "$3" --effort "$4" --job "$5" | jq -r .state)" = submitted ]' _ "${FINISH_RC}" "${EVENT}" "${JOB_OF}" "${effort}" "${JOB}"
	check "$1: the report is pinned, its sha256 the event's" sh -c 'read_only() { [ -n "$(find "$1" -prune -perm 0444)" ]; }; read_only "$1" && [ "$(printf "%s" "$2" | jq -r .body.report.sha256)" = "$(shasum -a 256 "$1" | cut -d " " -f 1)" ]' _ "${REPORT}" "${EVENT}"
	check "$1: its commit is the tree's HEAD, carrying the Job trailer" sh -c '[ "$(printf "%s" "$1" | jq -r .body.commit)" = "$(git -C "$2" rev-parse HEAD)" ] && git -C "$2" log -1 --format=%B | grep -qx "Job: $3 build-php-$4"' _ "${EVENT}" "${TREE}" "${JOB}" "$(printf '%.6s' "${AGENT}")"
}

echo "--- a fault before acceptance: the check can't run"
submission '.facts = "code-standin/scripts/internal/missing-facts.sh"'
standin_job f-check fc00000001 && write_report 8.json
stop_as code-standin s-check-fault
check 'the stop goes through, the human told the job ends' sh -c '[ "$2" -eq 0 ] && ! printf "%s" "$1" | jq -e ".decision" >/dev/null && printf "%s" "$1" | jq -r .systemMessage | grep -qF "the job ends, nothing handed in"' _ "${HOOK_OUT}" "${HOOK_RC}"
check 'job.ended fault at step check, by fault-ended.sh' is "$(jq -r '[.[] | "\(.type) \(.by) \(.body.reason) \(.body.step)"] | join(",")' "${E}/s-check-fault/event.json")" 'job.ended fault-ended.sh fault check'
check 'the report is not pinned, nothing committed' sh -c '[ -w "$1" ] && [ "$2" = none ]' _ "${REPORT}" "$(cat "${E}/s-check-fault/commit.txt")"

echo "--- a fault after acceptance, at each step, then the hand-in finished"
submission '.stamps = {rules: "code-standin/scripts/lib/standin-stamps", def: "stamp_fail"}'
standin_job f-stamp-a fa00000001 && write_report 8.json
stop_as code-standin s-stamp-a
stalled stamp s-stamp-a
check 'the job.stalled fault names the stamp rules'"'"' own line' has "$(ev '.body.fault')" "the stand-in's stamp rules stop"
finish "${JOB}"
check 'finishing while the stamp still fails: exit 4, still stalled' sh -c '[ "$1" -eq 4 ] && printf "%s" "$2" | grep -qF "could not be stamped" && [ "$3" = stalled ]' _ "${FINISH_RC}" "${FINISH_SAID}" "$(state_of "${JOB}")"
said=$(sh "${RECOVER}" --effort "${effort}" --job "${JOB}" --give-up 2>&1); rc=$?
EVENT=$(sh "${ER}" --effort "${effort}" | jq -c 'last')
mkdir -p "${E}/s-give-up"; printf '%s\n' "${EVENT}" | jq . | show >"${E}/s-give-up/event.json"
check 'giving up: job.ended fault at step stamp, by recover-submission.sh, its fault the stall'"'"'s' sh -c '[ "$1" -eq 0 ] && printf "%s" "$2" | jq -e ".type == \"job.ended\" and .by == \"recover-submission.sh\" and .body.reason == \"fault\" and .body.step == \"stamp\" and (.body.fault | contains(\"stamp rules stop\"))"' _ "${rc}" "${EVENT}"
check 'the job is ended' is "$(state_of "${JOB}")" ended
said=$(sh "${RECOVER}" --effort "${effort}" --job "${JOB}" --finish 2>&1); rc=$?
check 'an ended job is not finished: refused' sh -c '[ "$1" -eq 2 ] && printf "%s" "$2" | grep -qF "only a stalled job is finished or given up"' _ "${rc}" "${said}"

standin_job f-stamp-b fb00000001 && write_report 8.json
stop_as code-standin s-stamp-b
stalled stamp s-stamp-b
submission '.stamps = {rules: "code-standin/scripts/lib/standin-stamps", def: "stamp_none"}'
finish "${JOB}"
finished s-stamp-b

submission
mkdir -p "${S}/shim"
printf '%s\n' '#!/bin/sh' '# chmod, failing only to make a report read-only.' 'case $1:$2 in 444:*/reports/*) exit 1 ;; esac' 'exec /bin/chmod "$@"' >"${S}/shim/chmod"
/bin/chmod 755 "${S}/shim/chmod"
standin_job f-pin fp00000001 && write_report 8.json
plain_path=${PATH}
PATH="${S}/shim:${PATH}"
stop_as code-standin s-pin
PATH=${plain_path}
stalled pin s-pin
check 'not pinned, nothing committed' sh -c '[ -w "$1" ] && [ "$2" = none ]' _ "${REPORT}" "$(cat "${E}/s-pin/commit.txt")"
finish "${JOB}"
finished s-pin

standin_job f-commit fm00000001 && write_report 8.json
git_dir=$(git -C "${TREE}" rev-parse --absolute-git-dir)
: >"${git_dir}/index.lock"
stop_as code-standin s-commit
stalled commit s-commit
check 'the report is pinned, nothing committed' sh -c '[ ! -w "$1" ] && [ "$2" = none ]' _ "${REPORT}" "$(cat "${E}/s-commit/commit.txt")"
rm -f -- "${git_dir}/index.lock"
finish "${JOB}"
finished s-commit

submission '.event = "standin.unknown"'
standin_job f-event fe00000001 && write_report 8.json
stop_as code-standin s-event
stalled event s-event
made=$(git -C "${TREE}" rev-parse HEAD)
check 'the commit was made, and the human is told it carries the Job trailer' sh -c '[ "$1" != "$2" ] && printf "%s" "$3" | grep -qF "the working commit $1 carries its Job trailer"' _ "${made}" "${HEAD_BEFORE}" "$(told)"
submission
finish "${JOB}"
finished s-event
check 's-event: --finish found the commit by its trailer: no second commit' is "$(git -C "${TREE}" rev-parse HEAD)" "${made}"

standin_job f-lock fl00000001 && write_report 8.json
sleep 60 & holder=$!
mkdir -p "${effort}/stops/.lock" && printf '%s\n' "${holder}" >"${effort}/stops/.lock/pid"
started=$(date +%s)
export CRUCIBLE_STOP_LOCK_SECONDS=2
stop_as code-standin s-lock
unset CRUCIBLE_STOP_LOCK_SECONDS
waited=$(($(date +%s) - started))
kill "${holder}" 2>/dev/null; wait "${holder}" 2>/dev/null
rm -rf -- "${effort}/stops/.lock"
stalled lock s-lock
check 'the lock wait was the shortened one, not 120 s' sh -c '[ "$1" -lt 30 ]' _ "${waited}"
check 'the stop lock waits at most 120 seconds, whatever it is told' sh -c 'grep -qx "sl_wait_max=120" "$1"' _ "${K}/agent-submission/scripts/lib/stop-lock.sh"
check 'the report is neither stamped nor pinned' test -w "${REPORT}"
finish "${JOB}"
finished s-lock

echo "--- an unexpected exit: the exit trap writes the outcome the hook reached"
# stop_signalled TYPE CASE: the stop, sent TERM a second in, as Claude Code
# ends a hook past its timeout.
stop_signalled() {
	BEFORE=$(events_count)
	HEAD_BEFORE=$(git -C "${TREE}" rev-parse HEAD)
	jq -cn --arg agent "${AGENT}" --arg type "$1" '{session_id: "sess-ba", hook_event_name: "SubagentStop",
		stop_hook_active: false, agent_id: $agent, agent_type: $type, last_assistant_message: "Done."}' >"${S}/work/stop.json"
	sh "${HOOK}" <"${S}/work/stop.json" >"${S}/work/hook.out" 2>"${S}/work/hook.err" &
	hook_pid=$!
	sleep 1
	kill -TERM "${hook_pid}"
	wait "${hook_pid}"; HOOK_RC=$?
	HOOK_OUT=$(cat "${S}/work/hook.out")
	save "$2"
}
submission '.facts = "code-standin/scripts/internal/slow-facts.sh"'
standin_job f-hook-before fh00000001 && write_report 8.json
stop_signalled code-standin s-hook-before
check 'before acceptance: job.ended fault at step hook, by fault-ended.sh' is "$(jq -r '[.[] | "\(.type) \(.by) \(.body.reason) \(.body.step)"] | join(",")' "${E}/s-hook-before/event.json")" 'job.ended fault-ended.sh fault hook'
check 'its fault names the step the hook was at' has "$(ev '.body.fault')" 'ended unexpectedly at its check step'
check 'the human is told, and the hook still exits 0' sh -c '[ "$2" -eq 0 ] && printf "%s" "$1" | jq -r .systemMessage | grep -qF "ended unexpectedly"' _ "${HOOK_OUT}" "${HOOK_RC}"
submission '.stamps = {rules: "code-standin/scripts/lib/standin-stamps", def: "stamp_none", facts: "code-standin/scripts/internal/slow-facts.sh"}'
standin_job f-hook-after fi00000001 && write_report 8.json
stop_signalled code-standin s-hook-after
stalled hook s-hook-after
check 'its fault names the stamp step' has "$(ev '.body.fault')" 'ended unexpectedly at its stamp step'
check 'the stop lock is released' test ! -e "${effort}/stops/.lock"
submission
finish "${JOB}"
finished s-hook-after

echo "--- the working commit's message: the summary cut for the subject, whole in the body"
CM="${K}/git-commit/scripts/main/commit-message.sh"
LONG='retry uploads on 5xx responses with exponential backoff, capped at three attempts, and log each retry with status codes!'
check 'the long summary is 120 characters' is "$(printf '%s' "${LONG}" | jq -Rr 'length')" 120
# message_from JSON: commit-message.sh's message for one input; MSG, MSG_RC.
message_from() {
	printf '%s\n' "$1" >"${S}/work/cm-in.json"
	rm -f -- "${S}/work/cm-out"
	MSG_SAID=$(sh "${CM}" --input "${S}/work/cm-in.json" --out "${S}/work/cm-out" 2>&1); MSG_RC=$?
	MSG=$(cat "${S}/work/cm-out" 2>/dev/null)
}
message_from "$(jq -cn --arg s "${LONG}" '{kind: "build", summary: $s, trailers: {job: 4, iteration: 1}}')"
subject=$(printf '%s\n' "${MSG}" | sed -n 1p)
check 'a long summary: written' is "${MSG_RC}" 0
check 'its subject is within 72 characters and ends with …' sh -c '[ "$(printf "%s" "$1" | jq -Rr length)" -le 72 ] && printf "%s" "$1" | jq -Re "endswith(\"…\")"' _ "${subject}"
check 'cut at the last whole word: the subject'"'"'s text, then a space, starts the summary' sh -c 't=${1#"crucible(build): "}; t=${t%"…"}; case $2 in "$t "*) exit 0 ;; *) exit 1 ;; esac' _ "${subject}" "${LONG}"
check 'then a blank line, the whole summary, a blank line, and the trailers last' is "$(printf '%s\n' "${MSG}" | sed -n '2,6p')" "
${LONG}

Job: 4
Iteration: 1"
message_from '{"kind": "build", "summary": "retry uploads on 5xx", "trailers": {"job": 4}}'
check 'a summary that fits: the subject whole, no …, and still the body' is "${MSG}" 'crucible(build): retry uploads on 5xx

retry uploads on 5xx

Job: 4'
message_from "$(jq -cn --arg s "$(printf 'a%.0s' $(seq 1 90))" '{kind: "build", summary: $s}')"
check 'one word longer than the room is cut where the room ends, with …: 72 characters' is "$(printf '%s\n' "${MSG}" | sed -n 1p | jq -Rr length)" 72
message_from '{"kind": "build", "text": "retry uploads on 5xx", "summary": "retry uploads on 5xx"}'
check 'text and summary together are refused, exit 2' sh -c '[ "$1" -eq 2 ] && printf "%s" "$2" | grep -qF "text and summary are both given"' _ "${MSG_RC}" "${MSG_SAID}"
message_from '{"kind": "build", "summary": "two\nlines"}'
check 'a summary still must be one line' sh -c '[ "$1" -eq 2 ] && printf "%s" "$2" | grep -qF "summary holds a line break"' _ "${MSG_RC}" "${MSG_SAID}"
message_from '{"kind": "build", "text": "retry uploads on 5xx", "trailers": {"job": 4}}'
check 'main'"'"'s text path is unchanged: the subject, then the trailers, no body' is "${MSG}" 'crucible(build): retry uploads on 5xx

Job: 4'
message_from "$(jq -cn --arg s "${LONG}" '{kind: "build", text: $s}')"
check 'and text stays strict: a subject over 72 is refused' sh -c '[ "$1" -eq 2 ] && printf "%s" "$2" | grep -qF "expected at most 72"' _ "${MSG_RC}" "${MSG_SAID}"

expected_subject=$(jq -nr --arg s "${LONG}" -L "${K}/git-commit/scripts/lib" 'include "commit-message"; "crucible(build): " + ($s | commit_subject_cut("crucible(build): "))')
submission
standin_job f-long fg00000001
jq -n --arg s "${LONG}" '{summary: $s, gates: [{gate: "test", result: "pass"}]}' >"${REPORT}"; chmod 600 "${REPORT}"
stop_as code-standin s-long-summary
check 'a 120-character summary is accepted and handed in end to end' sh -c '[ -z "$1" ] && [ "$(sh "$2" --effort "$3" --job "$4" | jq -r .state)" = submitted ]' _ "${HOOK_OUT}" "${JOB_OF}" "${effort}" "${JOB}"
LONG_COMMIT=$(git -C "${TREE}" rev-parse HEAD)
check 'its commit'"'"'s subject is the cut one, within 72' sh -c '[ "$(git -C "$1" log -1 --format=%s)" = "$2" ] && [ "$(printf "%s" "$2" | jq -Rr length)" -le 72 ]' _ "${TREE}" "${expected_subject}"
check 'its body holds the whole summary' is "$(git -C "${TREE}" log -1 --format=%B | sed -n 3p)" "${LONG}"
check 'git still reads the trailers, last: Effort, Job, Iteration' is "$(git -C "${TREE}" log -1 --format=%B | git -C "${TREE}" interpret-trailers --parse | cut -d: -f1 | tr '\n' ' ')" 'Effort Job Iteration Language Standards '
check 'the submission event names that commit' is "$(ev '.body.commit')" "${LONG_COMMIT}"
check 'the kind and the job read back from the subject and trailers, as recovery reads them' sh -c '. "$1"; tr_read "$2" "$3" | jq -e --arg j "$4" ".kind == \"build\" and .job == (\$j | tonumber) and .iteration == 1"' _ "${K}/agent-submission/scripts/lib/trailers.sh" "${TREE}" "${LONG_COMMIT}" "${JOB}"

standin_job f-long-finish fh00000002
jq -n --arg s "${LONG}" '{summary: $s, gates: [{gate: "test", result: "pass"}]}' >"${REPORT}"; chmod 600 "${REPORT}"
git_dir=$(git -C "${TREE}" rev-parse --absolute-git-dir)
: >"${git_dir}/index.lock"
stop_as code-standin s-long-summary-stalled
stalled commit s-long-summary-stalled
rm -f -- "${git_dir}/index.lock"
finish "${JOB}"
finished s-long-summary-finished
check 'recover-submission.sh --finish commits it the same way: the cut subject, the whole body' sh -c '[ "$(git -C "$1" log -1 --format=%s)" = "$2" ] && [ "$(git -C "$1" log -1 --format=%B | sed -n 3p)" = "$3" ]' _ "${TREE}" "${expected_subject}" "${LONG}"


echo "--- a refusal that can't be recorded still holds the stop"
standin_job f-unrecorded fu00000001 && write_report 4a.json
sleep 60 & holder=$!
mkdir -p "${effort}/events/.lock" && printf '%s\n' "${holder}" >"${effort}/events/.lock/pid"
stop_as code-standin s-refusal-unrecorded
check 'a first stop is held: decision block with the repair lines' sh -c 'printf "%s" "$1" | jq -e ".decision == \"block\" and (.reason | contains(\"gates[0] is not_run\"))"' _ "${HOOK_OUT}"
check 'and the human is told it could not be recorded' has "$(told)" 'could not be recorded'
check 'no event was written' is "$(cat "${E}/s-refusal-unrecorded/event.json")" '"none"'
STOP_ACTIVE=true
stop_as code-standin s-refusal-unrecorded-again
STOP_ACTIVE=false
kill "${holder}" 2>/dev/null; wait "${holder}" 2>/dev/null
rm -rf -- "${effort}/events/.lock"
check 'the stop that follows that block goes through: no block' sh -c '[ "$2" -eq 0 ] && ! printf "%s" "$1" | jq -e ".decision" >/dev/null' _ "${HOOK_OUT}" "${HOOK_RC}"
check 'the human is told it went through, the job left for main'"'"'s turn end' has "$(told)" "its stop already followed a block, so it goes through, nothing handed in, and the job stays open for main's turn end"
check 'still no event, no .held file, no count: one extra hold, never a loop' sh -c '[ "$1" = "\"none\"" ] && [ ! -e "$2/stops/$3.held" ] && [ "$(sh "$4" --effort "$2" --job "$3" | jq -r .refusals)" -eq 0 ]' _ "$(cat "${E}/s-refusal-unrecorded-again/event.json")" "${effort}" "${JOB}" "${JOB_OF}"
check 'the job stays assigned' is "$(state_of "${JOB}")" assigned
write_report 4a.json
STOP_ACTIVE=true
stop_as code-standin s-refused-after-block
STOP_ACTIVE=false
check 'with the log writable, a refusal after a block is recorded and held as usual' sh -c 'printf "%s" "$1" | jq -e ".decision == \"block\"" >/dev/null && [ "$(jq -r ".[0].type + \" \" + (.[0].body.try | tostring)" "$2")" = "job.refused 1" ]' _ "${HOOK_OUT}" "${E}/s-refused-after-block/event.json"

echo "--- A0: a job-taking agent with no job is told to the human, after a second look"
AGENT=a0a0a0a0a0 TREE=${repo}
started=$(date +%s)
stop_as code-builder s-a0-no-job
waited=$(($(date +%s) - started))
check 'the human is told no effort has a job for it' has "$(told)" 'agent a0a0a0a0a0 (code-builder) stopped, and no effort has a job assigned to it'
check 'it looked again for about 5 seconds first' sh -c '[ "$1" -ge 5 ] && [ "$1" -lt 15 ]' _ "${waited}"
check 'no block, no event' sh -c '! printf "%s" "$1" | jq -e ".decision" >/dev/null && [ "$2" = "\"none\"" ]' _ "${HOOK_OUT}" "$(cat "${E}/s-a0-no-job/event.json")"
started=$(date +%s)
stop_as '' s-a0-empty-type
check 'an empty type, Claude Code'"'"'s own helper, passes silently and at once' sh -c '[ -z "$1" ] && [ "$2" -eq 0 ] && [ $(($(date +%s) - $3)) -lt 3 ]' _ "${HOOK_OUT}" "${HOOK_RC}" "${started}"
stop_as general-purpose s-a0-other-type
check 'a type with no submissions folder passes silently' sh -c '[ -z "$1" ] && [ "$2" -eq 0 ]' _ "${HOOK_OUT}" "${HOOK_RC}"
submission
standin_job f-race fr00000001 only && write_report 8.json
BEFORE=$(events_count) HEAD_BEFORE=$(git -C "${TREE}" rev-parse HEAD)
jq -cn --arg agent "${AGENT}" '{session_id: "sess-ba", hook_event_name: "SubagentStop", stop_hook_active: false,
	agent_id: $agent, agent_type: "code-standin", last_assistant_message: "Done."}' >"${S}/work/stop.json"
sh "${HOOK}" <"${S}/work/stop.json" >"${S}/work/hook.out" 2>"${S}/work/hook.err" &
hook_pid=$!
sleep 2
assign
wait "${hook_pid}"; HOOK_RC=$?
HOOK_OUT=$(cat "${S}/work/hook.out")
save s-a0-race
check 'an assignment that lands while the hook looks again is found: the report handed in' sh -c '[ -z "$1" ] && [ "$(sh "$2" --effort "$3" --job "$4" | jq -r .state)" = submitted ]' _ "${HOOK_OUT}" "${JOB_OF}" "${effort}" "${JOB}"

echo "=== the job agent's Bash hook: foreground only, and the time limit set"
BASH_HOOK="${K}/agent-submission/hooks/pre-tool-use/job-agent-tools.sh"
check 'install-entries.sh registers the wrapper job-agent-tools.sh on PreToolUse, matcher Bash|Write|Edit' jq -e 'any(.hooks[]; .event == "PreToolUse" and .matcher == "Bash|Write|Edit" and (.command_path | endswith("/agent-submission/hooks/pre-tool-use/job-agent-tools.sh")))' "${S}/entries.json"
check 'and registers no step of any hook' jq -e 'all(.hooks[]; .path | contains("/steps/") | not)' "${S}/entries.json"
out=$(sh "${BASH_HOOK}" --help 2>&1); rc=$?
check 'job-agent-tools.sh --help' sh -c '[ "$1" -eq 0 ] && printf "%s" "$2" | grep -q "^usage: " && printf "%s" "$2" | grep -q "^Exit:"' _ "${rc}" "${out}"
# bash_call JSON_FIELDS: a PreToolUse on Bash, the fields merged in.
bash_call() {
	jq -cn --argjson f "$1" '{session_id: "sess-ba", hook_event_name: "PreToolUse", tool_name: "Bash",
		tool_input: {command: "composer test", description: "run the tests"}} * $f' \
		| BASH_MAX_TIMEOUT_MS=30000 sh "${BASH_HOOK}" 2>"${S}/work/bash.err"
}
out=$(bash_call '{"agent_id": "b1", "agent_type": "code-builder", "tool_input": {"run_in_background": true}}')
mkdir -p "${E}/bash-hook"; printf '%s\n' "${out}" >"${E}/bash-hook/background.json"
check 'a background call is denied' is "$(printf '%s' "${out}" | jq -r '.hookSpecificOutput | "\(.hookEventName) \(.permissionDecision)"')" 'PreToolUse deny'
check 'its reason says to run it in the foreground' has "$(printf '%s' "${out}" | jq -r '.hookSpecificOutput.permissionDecisionReason')" 'Run this command in the foreground'
out=$(bash_call '{"agent_id": "b1", "agent_type": "code-builder"}')
printf '%s\n' "${out}" >"${E}/bash-hook/no-timeout.json"
check 'a call with no timeout is rewritten to the limit, the rest unchanged' is "$(printf '%s' "${out}" | jq -c '.hookSpecificOutput.updatedInput')" '{"command":"composer test","description":"run the tests","timeout":30000}'
check 'the rewrite allows nothing: the call keeps its normal permission checks' sh -c 'printf "%s" "$1" | jq -e ".hookSpecificOutput | has(\"permissionDecision\") | not"' _ "${out}"
check 'a tester'"'"'s call too' is "$(bash_call '{"agent_id": "t1", "agent_type": "code-tester"}' | jq -r '.hookSpecificOutput.updatedInput.timeout')" 30000
check 'a timeout the agent gave, 120000, is rewritten to the limit' is "$(bash_call '{"agent_id": "b1", "agent_type": "code-builder", "tool_input": {"timeout": 120000}}' | jq -r '.hookSpecificOutput.updatedInput.timeout')" 30000
check 'so is one above the limit, 600000' is "$(bash_call '{"agent_id": "b1", "agent_type": "code-builder", "tool_input": {"timeout": 600000}}' | jq -r '.hookSpecificOutput.updatedInput.timeout')" 30000
check 'a call already at the limit passes unchanged' is "$(bash_call '{"agent_id": "b1", "agent_type": "code-builder", "tool_input": {"timeout": 30000}}')" ''
check 'main'"'"'s own call passes, even in the background' is "$(bash_call '{"tool_input": {"run_in_background": true}}')" ''
check 'a non-job agent'"'"'s call passes' is "$(bash_call '{"agent_id": "x1", "agent_type": "Explore", "tool_input": {"run_in_background": true}}')" ''
out=$(jq -cn '{tool_name: "Bash", agent_id: "b1", agent_type: "code-builder", tool_input: {command: "ls"}}' | env -u BASH_MAX_TIMEOUT_MS sh "${BASH_HOOK}" 2>"${S}/work/bash.err"); rc=$?
check 'with BASH_MAX_TIMEOUT_MS unset the call passes unchanged, said on stderr' sh -c '[ -z "$1" ] && [ "$2" -eq 0 ] && grep -qF "BASH_MAX_TIMEOUT_MS is not set" "$3"' _ "${out}" "${rc}" "${S}/work/bash.err"
check 'input that is not JSON passes' sh -c '[ -z "$(printf "not json" | sh "$1" 2>/dev/null)" ]' _ "${BASH_HOOK}"

echo "=== the job agent's write scope: the tree and the report, or the report only"
WRITES_HOOK="${K}/agent-submission/hooks/pre-tool-use/job-agent-tools.sh"
WRITE_SCOPE="${K}/agent-submission/hooks/pre-tool-use/steps/write-scope.sh"
out=$(sh "${WRITE_SCOPE}" --help 2>&1); rc=$?
check 'write-scope.sh --help' sh -c '[ "$1" -eq 0 ] && printf "%s" "$2" | grep -q "^usage: " && printf "%s" "$2" | grep -q "^Exit:"' _ "${rc}" "${out}"
check 'every submissions file of the three agents names its writes: tree for build, build-fix, test and test-fix, report for the rest' sh -c 'for f in "$1"/code-builder/submissions/*.json "$1"/code-tester/submissions/*.json "$1"/code-reviewer/submissions/*.json; do k=${f##*/}; k=${k%.json}; case $k in build | build-fix | test | test-fix) w=tree ;; *) w=report ;; esac; [ "$(jq -r .writes "$f")" = "$w" ] || exit 1; done' _ "${K}"
# scope_job TYPE KIND TREE AGENT [EFFORT]: a job dispatched and assigned;
# sets JOB and REPORT.
scope_job() {
	in=${5:-${effort}}
	JOB=$(($(sh "${ER}" --effort "${in}" --paths | wc -l | tr -d ' ') + 1))
	REPORT="${in}/reports/$2/${JOB}.json"
	jq -n --arg type "$1" --arg kind "$2" --arg tree "$3" --arg report "reports/$2/${JOB}.json" '{kind: $kind, agent_type: $type,
		tree: $tree, report: $report, known_failures: [], iteration: 1, setup: {language: "php", standards: ["security"]}}' >"${S}/work/dispatched.json"
	sh "${EW}" --effort "${in}" --type job.dispatched --by job-dispatch.sh --body-file "${S}/work/dispatched.json" >/dev/null || return 1
	jq -n --argjson job "${JOB}" --arg agent "$4" '{job: $job, agent: $agent, name: "job-\($agent)", session: "sess-ba"}' >"${S}/work/assigned.json"
	sh "${EW}" --effort "${in}" --type job.assigned --by assign-job.sh --body-file "${S}/work/assigned.json" >/dev/null
}
# call TOOL PATH AGENT TYPE: the hook's answer to a tool call; OUT, RC.
call() {
	if [ -n "$4" ]; then fields=$(jq -cn --arg a "$3" --arg t "$4" '{agent_id: $a, agent_type: $t}'); else fields='{}'; fi
	OUT=$(jq -cn --arg tool "$1" --arg path "$2" --arg cwd "${repo}" --argjson f "${fields}" '{session_id: "sess-ba",
		hook_event_name: "PreToolUse", cwd: $cwd, tool_name: $tool, tool_input: {file_path: $path, content: "x"}} + $f' \
		| sh "${WRITES_HOOK}" 2>"${S}/work/writes.err"); RC=$?
}
decision() { printf '%s' "${OUT}" | jq -r '.hookSpecificOutput.permissionDecision // "none"'; }
because() { printf '%s' "${OUT}" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""'; }
sh "${K}/git-worktree/scripts/main/worktree-cut.sh" --effort "${effort}" --repo "${repo}" --name w-scope --from checkout >/dev/null
W_TREE=$(tree_of w-scope)
scope_job code-builder build "${W_TREE}" wb00000001; B_REPORT=${REPORT}
scope_job code-reviewer review "${W_TREE}" wr00000001; R_REPORT=${REPORT}
scope_job code-tester test-plan "${W_TREE}" wt00000001; T_REPORT=${REPORT}
mkdir -p "${E}/write-scope"
call Write "${W_TREE}/app/Upload/Client.php" wb00000001 code-builder
printf '%s\n' "${OUT}" | show >"${E}/write-scope/tree-write.json"
check 'scope tree: a Write in the tree is allowed' is "$(decision)" allow
call Edit "${W_TREE}/app/Upload/Auth.php" wb00000001 code-builder
check 'scope tree: an Edit in the tree is allowed' is "$(decision)" allow
call Write "${repo}/app/Upload/Client.php" wb00000001 code-builder
printf '%s\n' "${OUT}" | show >"${E}/write-scope/repo-write.json"
check 'the same file in main'"'"'s repo is denied' is "$(decision)" deny
check 'the reason names the tree and the report, by their real paths' is "$(because)" "Write only in ${W_TREE} and to your report ${B_REPORT}."
for pair in "wb00000001 code-builder ${B_REPORT}" "wr00000001 code-reviewer ${R_REPORT}" "wt00000001 code-tester ${T_REPORT}"; do
	set -- ${pair}
	call Write "$3" "$1" "$2"
	check "the job's own report is allowed: $2" is "$(decision)" allow
done
call Write "${W_TREE}/app/Upload/Client.php" wr00000001 code-reviewer
printf '%s\n' "${OUT}" | show >"${E}/write-scope/review-tree-write.json"
check 'scope report: a review'"'"'s Write in the tree is denied' is "$(decision)" deny
check 'its reason names only the report' is "$(because)" "Write only your report ${R_REPORT}."
call Edit "${W_TREE}/tests/Upload/UploadClientTest.php" wt00000001 code-tester
check 'scope report: a test plan'"'"'s Edit in the tree is denied' is "$(decision)" deny
call Write "${R_REPORT}" wb00000001 code-builder
check 'another job'"'"'s report is denied' is "$(decision)" deny
other_effort=$(sh "${K}/crucible-effort/scripts/main/effort-start.sh" --name 'another effort') || exit 1
mkdir -p "${other_effort}/worktrees/elsewhere"
scope_job code-builder build "${other_effort}/worktrees/elsewhere" wo00000001 "${other_effort}"
call Write "${other_effort}/worktrees/elsewhere/a.php" wb00000001 code-builder
check 'another effort'"'"'s tree is denied' is "$(decision)" deny
call Write "${W_TREE}/app/../../upload/app/Upload/Client.php" wb00000001 code-builder
check 'a path that leaves the tree through .. is denied' is "$(decision)" deny
call Write "${W_TREE}/app/new/../Upload/Retry.php" wb00000001 code-builder
check 'a .. that stays in the tree, through a folder not made yet, is allowed' is "$(decision)" allow
ln -s "${repo}" "${W_TREE}/main-repo"
call Write "${W_TREE}/main-repo/app/Upload/Client.php" wb00000001 code-builder
check 'a link in the tree to main'"'"'s repo is followed, and denied' is "$(decision)" deny
rm -- "${W_TREE}/main-repo"
case ${S} in
	/private/*)
		call Write "${W_TREE#/private}/app/Upload/Client.php" wb00000001 code-builder
		check 'the tree named without /private (the /var link) is the same tree: allowed' is "$(decision)" allow ;;
	*) check 'the scratch folder is a real path under /private, for the next case' false ;;
esac
TMP_TREE=$(mktemp -d /tmp/job-agent-writes.XXXXXX) || exit 1
scope_job code-builder build "${TMP_TREE}" wx00000001
call Write "${TMP_TREE}/a.php" wx00000001 code-builder
check 'a tree dispatched as /tmp/...: a Write as /tmp/... is allowed' is "$(decision)" allow
call Write "/private${TMP_TREE}/a.php" wx00000001 code-builder
check 'the same file as /private/tmp/... is allowed' is "$(decision)" allow
call Write "${repo}/a.php" wx00000001 code-builder
check 'its deny names the real tree, /private/tmp/...' has "$(because)" "Write only in /private${TMP_TREE} and"
rm -rf -- "${TMP_TREE}"
call Write "${repo}/app/Upload/Client.php" '' ''
check 'main'"'"'s own Write gets no decision' is "${OUT}" ''
call Write "${repo}/app/Upload/Client.php" x0000001 general-purpose
check 'a non-job agent'"'"'s Write gets no decision' is "${OUT}" ''
call Write "${repo}/app/Upload/Client.php" af6bac0101 code-builder
check 'an idle hot agent (its job submitted) gets no decision: Claude Code asks' is "${OUT}" ''
submission
standin_job w-standin ws00000001
call Write "${TREE}/app/Upload/Client.php" ws00000001 code-standin
printf '%s\n' "${OUT}" | show >"${E}/write-scope/missing-writes.json"
check 'a submissions file with no writes word: the human told of the install fault' has "$(printf '%s' "${OUT}" | jq -r '.systemMessage // ""')" "code-standin/submissions/build.json names no writes (tree or report)"
check 'and no decision, so nothing is let through by default' sh -c 'printf "%s" "$1" | jq -e "has(\"hookSpecificOutput\") | not"' _ "${OUT}"
call Read "${W_TREE}/app/Upload/Client.php" wb00000001 code-builder
check 'a Read gets no decision: it isn'"'"'t matched, and the space is a working directory' sh -c '[ -z "$1" ] && jq -e "any(.hooks[]; .matcher == \"Bash|Write|Edit\" and (.command_path | endswith(\"/job-agent-tools.sh\")))" "$2"' _ "${OUT}" "${S}/entries.json"
check 'the write scope'"'"'s help says reads need no hook' has "$(sh "${WRITE_SCOPE}" --help)" 'Reads need no hook: the installer makes the space a'
check 'input that is not JSON gets no decision' sh -c '[ -z "$(printf "not json" | sh "$1" 2>/dev/null)" ]' _ "${WRITES_HOOK}"
jq '.hooks.PreToolUse |= map(select(.matcher != "Bash|Write|Edit"))' "${S}/settings.json" >"${S}/no-writes-hook.json"
out=$(sh "${R}/framework/core/install/install-check.sh" --settings "${S}/no-writes-hook.json" 2>&1); rc=$?
check 'install-check.sh sees the hook: without it, it is missing' sh -c '[ "$1" -eq 1 ] && printf "%s" "$2" | grep -qF "missing: PreToolUse hook [Bash|Write|Edit]"' _ "${rc}" "${out}"
check 'the reviewer has Write, not Edit' sh -c 'grep -qx "tools: Read, Grep, Glob, Write, Bash, WebFetch" "$1"' _ "${K}/code-reviewer/code-reviewer.md"
check 'its line says it changes nothing but its report' grep -qF -- '- Change nothing but your report, and run no command that writes. A reviewer that edits the code is reviewing its own work.' "${K}/code-reviewer/code-reviewer.md"
check 'agent-conduct holds no denied-command line' sh -c '! grep -qF "A denied command" "$1/agent-conduct/SKILL.md"' _ "${K}"

echo "=== the permission hook: a job agent's ask on a compound command"
PERM_HOOK="${K}/agent-submission/hooks/permission-request/deny-compound-commands.sh"
check 'install-entries.sh registers it on PermissionRequest, matcher Bash' jq -e 'any(.hooks[]; .event == "PermissionRequest" and .matcher == "Bash" and (.command_path | endswith("/agent-submission/hooks/permission-request/deny-compound-commands.sh")))' "${S}/entries.json"
check 'the settings hold it under PermissionRequest' jq -e '.hooks.PermissionRequest[0].matcher == "Bash"' "${S}/settings.json"
out=$(sh "${PERM_HOOK}" --help 2>&1); rc=$?
check 'deny-compound-commands.sh --help, saying what was probed' sh -c '[ "$1" -eq 0 ] && printf "%s" "$2" | grep -q "^usage: " && printf "%s" "$2" | grep -q "^Exit:" && printf "%s" "$2" | grep -q "Probed only with main in default mode"' _ "${rc}" "${out}"
# ask COMMAND [AGENT]: a PermissionRequest on Bash, as Claude Code sends it;
# no AGENT for main's own ask. OUT holds the answer.
ask() {
	OUT=$(jq -cn --arg c "$1" --arg a "${2-}" '{session_id: "sess-ba", hook_event_name: "PermissionRequest", cwd: "/",
		permission_mode: "default", tool_name: "Bash", tool_input: {command: $c, description: "run"}, permission_suggestions: []}
		+ (if $a == "" then {} else {agent_id: $a, agent_type: "code-builder"} end)' | sh "${PERM_HOOK}" 2>/dev/null)
}
DENIED='{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Run it as plain single commands, one per call. Your other commands still run."}}}'
mkdir -p "${E}/permission-hook"
for compound in "cd ${W_TREE} && git status" "T=${W_TREE}; git -C \$T status" 'make || make clean' 'echo $(git rev-parse HEAD)' 'echo `date`' 'FOO=1 make test' 'make
make install'; do
	ask "${compound}" wb00000001
	check "a compound command is denied, exactly as worded: $(printf '%s' "${compound}" | tr '\n' '/' | cut -c1-40)" is "${OUT}" "${DENIED}"
done
printf '%s\n' "${OUT}" >"${E}/permission-hook/compound.json"
ask "git commit -m 'retry; then back off'" wb00000001
check 'a quoted ; is a plain command: no answer' is "${OUT}" ''
ask "sed -i 's|a|b|' app/Upload/Client.php" wb00000001
check 'sed with a quoted | and ; is a plain command: no answer' is "${OUT}" ''
ask 'echo "a && b"' wb00000001
check 'a double-quoted && is a plain command: no answer' is "${OUT}" ''
ask "git -C ${W_TREE} log | head -n 5" wb00000001
check 'a pipe is not compound: no answer' is "${OUT}" ''
ask "touch ${W_TREE}/x" wb00000001
check 'a plain command gets no answer' is "${OUT}" ''
ask "cd ${W_TREE} && git status" af6bac0101
check 'an agent with no open job gets no answer' is "${OUT}" ''
ask "cd ${W_TREE} && git status"
check 'main'"'"'s own ask gets no answer' is "${OUT}" ''
ask "cd ${W_TREE} && git status" helper00001
check 'a helper agent, never assigned a job, gets no answer' is "${OUT}" ''

echo "=== the PreToolUse wrapper: each step alone, the combine rule"
TOOL_STEPS="${K}/agent-submission/hooks/pre-tool-use/steps"
# tool_json TOOL INPUT_JSON [TYPE]: a PreToolUse input of a job agent (or
# of TYPE; "" for main).
tool_json() {
	jq -cn --arg tool "$1" --argjson in "$2" --arg type "${3-code-builder}" '{session_id: "sess-ba", hook_event_name: "PreToolUse",
		cwd: "/", tool_name: $tool, tool_input: $in} + (if $type == "" then {} else {agent_id: "b1", agent_type: $type} end)'
}
mkdir -p "${E}/hook-steps"
out=$(tool_json Bash '{"command": "make test", "run_in_background": true}' | sh "${TOOL_STEPS}/deny-background-bash.sh")
check 'deny-background-bash.sh alone: a background call is denied' is "$(printf '%s' "${out}" | jq -r '.hookSpecificOutput.permissionDecision')" deny
check 'deny-background-bash.sh alone: a foreground call gets nothing' is "$(tool_json Bash '{"command": "make test"}' | sh "${TOOL_STEPS}/deny-background-bash.sh")" ''
out=$(tool_json Bash '{"command": "make test"}' | BASH_MAX_TIMEOUT_MS=30000 sh "${TOOL_STEPS}/add-bash-timeout.sh")
check 'add-bash-timeout.sh alone: the limit added, nothing allowed' is "$(printf '%s' "${out}" | jq -c '.hookSpecificOutput | [.updatedInput.timeout, has("permissionDecision")]')" '[30000,false]'
check 'add-bash-timeout.sh alone: a shorter timeout is rewritten to the limit' is "$(tool_json Bash '{"command": "make test", "timeout": 5000}' | BASH_MAX_TIMEOUT_MS=30000 sh "${TOOL_STEPS}/add-bash-timeout.sh" | jq -r '.hookSpecificOutput.updatedInput.timeout')" 30000
check 'write-scope.sh alone: a Write in the job'"'"'s tree is allowed' is "$(tool_json Write "{\"file_path\": \"${W_TREE}/a.php\", \"content\": \"x\"}" | jq -c '.agent_id = "wb00000001"' | sh "${WRITE_SCOPE}" | jq -r '.hookSpecificOutput.permissionDecision')" allow
for step in deny-background-bash.sh add-bash-timeout.sh write-scope.sh; do
	check "${step} alone: input that is not JSON gets nothing, exit 0" sh -c 'out=$(printf "not json" | sh "$1" 2>/dev/null); [ $? -eq 0 ] && [ -z "${out}" ]' _ "${TOOL_STEPS}/${step}"
done

# tool_call INPUT: the installed wrapper's answer; OUT.
tool_call() { OUT=$(printf '%s' "$1" | BASH_MAX_TIMEOUT_MS=30000 sh "${BASH_HOOK}" 2>/dev/null); }
# bash_in COMMAND [TYPE]: a job agent's Bash call already at the time
# limit, so only a refusal can answer it.
bash_in() { tool_json Bash "$(jq -cn --arg c "$1" '{command: $c, timeout: 30000}')" "${2-code-builder}"; }
tool_call "$(bash_in "cd ${W_TREE} && git status")"
check 'the tool wrapper leaves a compound command alone: the permission hook answers its ask' is "${OUT}" ''
check 'no refuse-denied-forms.sh step is left' test ! -e "${TOOL_STEPS}/refuse-denied-forms.sh"
tool_call "$(tool_json Bash '{"command": "make test", "run_in_background": true}' general-purpose)"
check 'a non-job agent'"'"'s call passes untouched' is "${OUT}" ''

echo "--- the combine rule, with stand-in steps under a copy of the wrapper"
fake="${S}/fake-skills"
mkdir -p "${fake}/agent-submission/hooks/pre-tool-use/steps" "${fake}/code-builder/submissions"
cp "${R}/domains/software-development/core/agents/agent-submission/hooks/pre-tool-use/job-agent-tools.sh" "${fake}/agent-submission/hooks/pre-tool-use/"
FAKE_HOOK="${fake}/agent-submission/hooks/pre-tool-use/job-agent-tools.sh"
FAKE_STEPS="${fake}/agent-submission/hooks/pre-tool-use/steps"
# stand_in STEP ANSWER: a stand-in step that saves its input to
# <step>.in and prints ANSWER ("fail" exits 3, "junk" prints no JSON).
stand_in() {
	{
		printf '#!/bin/sh\ncat >"%s/%s.in"\n' "${FAKE_STEPS}" "$1"
		case $2 in
			fail) printf 'exit 3\n' ;;
			junk) printf 'echo not-json\n' ;;
			'') ;;
			*) printf "printf '%%s\\\\n' '%s'\n" "$2" ;;
		esac
	} >"${FAKE_STEPS}/$1"
	rm -f -- "${FAKE_STEPS:?}/${1:?}.in"
}
ALLOW='{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow", "permissionDecisionReason": "fine"}}'
DENY='{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "no"}}'
REWRITE='{"hookSpecificOutput": {"hookEventName": "PreToolUse", "updatedInput": {"command": "make test", "timeout": 30000}}}'
fake_call() { OUT=$(tool_json Bash '{"command": "make test"}' | sh "${FAKE_HOOK}"); }
stand_in deny-background-bash.sh "${DENY}"; stand_in add-bash-timeout.sh "${ALLOW}"
fake_call
check 'a deny wins, and is the answer' is "$(printf '%s' "${OUT}" | jq -c '.hookSpecificOutput | [.permissionDecision, .permissionDecisionReason]')" '["deny","no"]'
check 'and no step after the deny runs' test ! -e "${FAKE_STEPS}/add-bash-timeout.sh.in"
stand_in deny-background-bash.sh "${ALLOW}"; stand_in add-bash-timeout.sh "${DENY}"
fake_call
check 'a deny wins over an allow before it' is "$(printf '%s' "${OUT}" | jq -r '.hookSpecificOutput.permissionDecision')" deny
stand_in deny-background-bash.sh ''; stand_in add-bash-timeout.sh "${ALLOW}"
fake_call
check 'an allow with no deny is an allow' is "$(printf '%s' "${OUT}" | jq -r '.hookSpecificOutput.permissionDecision')" allow
stand_in deny-background-bash.sh "${REWRITE}"; stand_in add-bash-timeout.sh ''
stand_in write-scope.sh "${DENY}"
fake_call
check 'each step gets the input as the step before rewrote it' is "$(jq -c '.tool_input' "${FAKE_STEPS}/add-bash-timeout.sh.in")" '{"command":"make test","timeout":30000}'
check 'a rewrite alone is given as updatedInput, with no decision' is "$(printf '%s' "${OUT}" | jq -c '.hookSpecificOutput | [has("permissionDecision"), .updatedInput.timeout]')" '[false,30000]'
check 'a Bash call never runs write-scope.sh' test ! -e "${FAKE_STEPS}/write-scope.sh.in"
stand_in deny-background-bash.sh junk; stand_in add-bash-timeout.sh "${REWRITE}"
fake_call
check 'a step printing no JSON gives no answer, and the rest still run' sh -c '[ -e "$1" ] && [ "$(printf "%s" "$2" | jq -r .hookSpecificOutput.updatedInput.timeout)" = 30000 ]' _ "${FAKE_STEPS}/add-bash-timeout.sh.in" "${OUT}"
stand_in deny-background-bash.sh fail; stand_in add-bash-timeout.sh fail
fake_call
check 'every step failing: no answer, the wrapper decides nothing itself' is "${OUT}" ''
stand_in write-scope.sh "${ALLOW}"; stand_in deny-background-bash.sh fail
OUT=$(tool_json Write '{"file_path": "/x", "content": "y"}' | sh "${FAKE_HOOK}")
check 'a Write runs write-scope.sh only' sh -c '[ -e "$1" ] && [ ! -e "$2" ] && [ "$(printf "%s" "$3" | jq -r .hookSpecificOutput.permissionDecision)" = allow ]' _ "${FAKE_STEPS}/write-scope.sh.in" "${FAKE_STEPS}/deny-background-bash.sh.in" "${OUT}"
OUT=$(tool_json Write '{"file_path": "/x", "content": "y"}' code-other | sh "${FAKE_HOOK}")
check 'the agent type is checked once, before any step: another type gets nothing' is "${OUT}" ''

echo "--- crucible-events' wrapper: first deny wins, each step alone"
GUARD="${K}/crucible-events/hooks/pre-tool-use/guard-framework.sh"
check 'install-entries.sh registers guard-framework.sh on Read|Grep|Glob|Bash, and not its steps' jq -e '[.hooks[] | select(.path | contains("/crucible-events/"))] | length == 1 and .[0].matcher == "Read|Grep|Glob|Bash" and (.[0].path | endswith("/hooks/pre-tool-use/guard-framework.sh"))' "${S}/entries.json"
out=$(sh "${GUARD}" --help 2>&1); rc=$?
check 'guard-framework.sh --help' sh -c '[ "$1" -eq 0 ] && printf "%s" "$2" | grep -q "^usage: " && printf "%s" "$2" | grep -q "^Exit:"' _ "${rc}" "${out}"
out=$(jq -cn --arg c "sh ${EW} --effort x" '{tool_name: "Bash", cwd: "/", tool_input: {command: $c}}' | sh "${GUARD}")
check 'a direct event write is denied through the wrapper' is "$(printf '%s' "${out}" | jq -r '.hookSpecificOutput.permissionDecision')" deny
out=$(jq -cn --arg p "${K}/crucible-events/scripts/internal/event-write.sh" '{tool_name: "Read", cwd: "/", tool_input: {file_path: $p}}' | sh "${GUARD}")
check 'a Read of an internal script is denied through the wrapper' is "$(printf '%s' "${out}" | jq -r '.hookSpecificOutput.permissionDecision')" deny
out=$(jq -cn --arg p "${K}/crucible-events/scripts/internal/event-write.sh" '{tool_name: "Read", cwd: "/", tool_input: {file_path: $p}}' | sh "${K}/crucible-events/hooks/pre-tool-use/steps/deny-sealed-reads.sh")
check 'deny-sealed-reads.sh alone, from steps/, still finds the framework root' is "$(printf '%s' "${out}" | jq -r '.hookSpecificOutput.permissionDecision')" deny
check 'an ordinary command gets nothing' is "$(jq -cn '{tool_name: "Bash", cwd: "/", tool_input: {command: "ls"}}' | sh "${GUARD}")" ''
check 'another tool gets nothing' is "$(jq -cn '{tool_name: "Write", cwd: "/", tool_input: {file_path: "/x"}}' | sh "${GUARD}")" ''

echo "--- a step is never registered"
jq --arg step "${K}/agent-submission/hooks/pre-tool-use/steps/write-scope.sh" '.hooks.PreToolUse += [{matcher: "Write", hooks: [{type: "command", command: ("sh " + $step)}]}]' "${S}/settings.json" >"${S}/with-step.json"
out=$(sh "${R}/framework/core/install/install-check.sh" --settings "${S}/with-step.json" 2>&1); rc=$?
echo "${out}" | show | sed 's/^/    /'
check 'install-check.sh refuses a registered step: exit 1, an extra: line naming it' sh -c '[ "$1" -eq 1 ] && printf "%s" "$2" | grep -qE "^extra: PreToolUse hook step .*/pre-tool-use/steps/write-scope.sh is registered; register only its wrapper$"' _ "${rc}" "${out}"
twin_jobs="${S:?}/twin-tree/domains/software-development/core/main-thread/agent-jobs/hooks"
rm -f -- "${twin_jobs:?}/env.json"
printf '{"pre-tool-use/steps/write-scope.sh": "Write"}\n' >"${twin_jobs}/matchers.json"
twin=$(sh "${S}/twin-tree/framework/core/install/install-entries.sh" --json 2>&1); twin_rc=$?
check 'install-entries.sh refuses a matchers.json naming a step' sh -c '[ "$1" -eq 2 ] && printf "%s" "$2" | grep -qF "is not a valid matchers.json"' _ "${twin_rc}" "${twin}"
cp -- "${R}/domains/software-development/core/main-thread/agent-jobs/hooks/matchers.json" "${twin_jobs}/matchers.json"

echo "--- the component folder contract"
rm -rf -- "${S:?}/twin-tree/domains/software-development/core/agents/git-commit"
twin_builder="${S:?}/twin-tree/domains/software-development/core/agents/code-builder"
mkdir -p "${twin_builder}/notes" "${twin_builder}/scripts/tools"
sh "${S}/twin-tree/framework/core/install/install-entries.sh" | sed -n '/^# Settings/,/^$/p' | sed '1d' >"${S}/twin-contract.json"
out=$(sh "${S}/twin-tree/framework/core/install/install-check.sh" --settings "${S}/twin-contract.json" 2>&1); rc=$?
printf '%s\n' "${out}" | grep '^extra: folder' | show | sed 's/^/    /'
check 'install-check.sh refuses a stray folder in a component' sh -c '[ "$1" -eq 1 ] && printf "%s" "$2" | grep -qE "^extra: folder .*/agents/code-builder/notes is outside the component contract$"' _ "${rc}" "${out}"
check 'and a stray folder in its scripts/' sh -c 'printf "%s" "$1" | grep -qE "^extra: folder .*/code-builder/scripts/tools is outside the component contract$"' _ "${out}"
check 'every component in the tree keeps the contract: no extra: folder line installed' sh -c '! printf "%s" "$1" | grep -q "^extra: folder"' _ "$(sh "${R}/framework/core/install/install-check.sh" --settings "${S}/settings.json" 2>&1)"
check 'the contract names scripts/agent/, and no component has one' sh -c 'sh "$1" --help | grep -q "agent/ for scripts agents may run" && [ -z "$(find "$2" -path "*/scripts/agent" -type d)" ]' _ "${R}/framework/core/install/install-check.sh" "${R}"
rm -rf -- "${twin_builder:?}/notes" "${twin_builder:?}/scripts/tools"

echo "=== every hook step called alone, through its installed link, not its wrapper"
alone_ok=0
READ_GUARD="${K}/crucible-events/hooks/pre-tool-use/steps/deny-sealed-reads.sh"
# alone STEP WHAT COMMAND...: one check of a step called alone; counted.
alone() {
	alone_step=$1 alone_what=$2; shift 2
	alone_before=${pass}
	check "${alone_step} alone: ${alone_what}" "$@"
	[ "${pass}" -eq "${alone_before}" ] || alone_ok=$((alone_ok + 1))
}
SUB_STEPS="${K}/agent-submission/hooks/subagent-stop/steps"
sh "${K}/git-worktree/scripts/main/worktree-cut.sh" --effort "${effort}" --repo "${repo}" --name steps-alone --from checkout >/dev/null
A_TREE=$(tree_of steps-alone)
scope_job code-builder build "${A_TREE}" sa00000001
A_REPORT=${REPORT}
sh "${JOB_OF}" --effort "${effort}" --job "${JOB}" >"${S}/work/alone-job.json"
mkdir -p "${A_REPORT%/*}"
cp -- "${F}/reports/8.json" "${A_REPORT}"; chmod 600 "${A_REPORT}"
printf '// alone\n' >>"${A_TREE}/app/Upload/Client.php"
alone report-validation.sh 'accepts the report' sh "${SUB_STEPS}/report-validation.sh" --effort "${effort}" --job "${S}/work/alone-job.json"
alone report-stamp.sh 'a submission file with no stamps leaves the report as it is' sh "${SUB_STEPS}/report-stamp.sh" --effort "${effort}" --job "${S}/work/alone-job.json"
a_sha=$(sh "${SUB_STEPS}/report-pin.sh" --report "${A_REPORT}")
alone report-pin.sh 'pins the report and prints its sha256' sh -c '[ "$1" = "$(shasum -a 256 "$2" | cut -d " " -f 1)" ] && [ ! -w "$2" ]' _ "${a_sha}" "${A_REPORT}"
a_commit=$(sh "${SUB_STEPS}/working-commit.sh" --effort "${effort}" --job "${S}/work/alone-job.json")
alone working-commit.sh 'commits the tree, carrying the Job trailer' sh -c '[ "$1" = "$(git -C "$2" rev-parse HEAD)" ] && git -C "$2" log -1 --format=%B | grep -qx "Job: $3 job-sa00000001"' _ "${a_commit}" "${A_TREE}" "${JOB}"
a_event=$(env -u CLAUDE_CODE_SESSION_ID sh "${SUB_STEPS}/submission-event.sh" --effort "${effort}" --job "${S}/work/alone-job.json" --type build.submitted --sha256 "${a_sha}" --commit "${a_commit}")
alone submission-event.sh 'writes build.submitted, its session stamp empty with no CLAUDE_CODE_SESSION_ID' jq -e '.type == "build.submitted" and .claude_session_id == null' "${a_event}"
sh "${K}/git-worktree/scripts/main/worktree-cut.sh" --effort "${effort}" --repo "${repo}" --name steps-alone-1 --from checkout >/dev/null
scope_job code-builder build "$(tree_of steps-alone-1)" sb00000001
sh "${JOB_OF}" --effort "${effort}" --job "${JOB}" >"${S}/work/alone-job.json"
printf 'shorten the summary\n' >"${S}/work/alone-lines"
alone held-stop.sh 'records try 1 and holds' sh -c '[ "$(sh "$1" --effort "$2" --job "$3" --lines "$4")" = held ] && [ "$(sh "$5" --effort "$2" --type job.refused | jq -r "last | .body.try")" = 1 ]' _ "${SUB_STEPS}/held-stop.sh" "${effort}" "${S}/work/alone-job.json" "${S}/work/alone-lines" "${ER}"
sh "${SUB_STEPS}/fault-ended.sh" --effort "${effort}" --job "${S}/work/alone-job.json" --step check --fault 'called alone'
alone fault-ended.sh 'ends the job: fault at check' is "$(sh "${ER}" --effort "${effort}" | jq -r 'last | "\(.type) \(.body.reason) \(.body.step)"')" 'job.ended fault check'
sh "${K}/git-worktree/scripts/main/worktree-cut.sh" --effort "${effort}" --repo "${repo}" --name steps-alone-2 --from checkout >/dev/null
scope_job code-builder build "$(tree_of steps-alone-2)" sc00000001
sh "${JOB_OF}" --effort "${effort}" --job "${JOB}" >"${S}/work/alone-job.json"
sh "${SUB_STEPS}/fault-stalled.sh" --effort "${effort}" --job "${S}/work/alone-job.json" --step commit --fault 'called alone'
alone fault-stalled.sh 'stalls the job: at commit' is "$(sh "${JOB_OF}" --effort "${effort}" --job "${JOB}" | jq -r '.state')" stalled
alone deny-background-bash.sh 'denies a background call' is "$(tool_json Bash '{"command": "make", "run_in_background": true}' | sh "${TOOL_STEPS}/deny-background-bash.sh" | jq -r '.hookSpecificOutput.permissionDecision')" deny
alone add-bash-timeout.sh 'adds the limit' is "$(tool_json Bash '{"command": "make"}' | BASH_MAX_TIMEOUT_MS=30000 sh "${TOOL_STEPS}/add-bash-timeout.sh" | jq -r '.hookSpecificOutput.updatedInput.timeout')" 30000
alone write-scope.sh 'denies a write in main'"'"'s repo for a job in a tree' is "$(tool_json Write "$(jq -cn --arg p "${repo}/x.php" '{file_path: $p, content: "x"}')" | jq -c '.agent_id = "wb00000001"' | sh "${TOOL_STEPS}/write-scope.sh" | jq -r '.hookSpecificOutput.permissionDecision')" deny
EV_STEPS="${K}/crucible-events/hooks/pre-tool-use/steps"
alone deny-direct-event-write.sh 'denies running the event writer' is "$(jq -cn --arg c "sh ${EW} --effort x" '{tool_name: "Bash", cwd: "/", tool_input: {command: $c}}' | sh "${EV_STEPS}/deny-direct-event-write.sh" | jq -r '.hookSpecificOutput.permissionDecision')" deny
alone "${READ_GUARD##*/}" 'denies main a read of an internal script' is "$(jq -cn --arg p "${K}/crucible-events/scripts/internal/event-write.sh" '{tool_name: "Read", cwd: "/", tool_input: {file_path: $p}}' | sh "${READ_GUARD}" | jq -r '.hookSpecificOutput.permissionDecision')" deny
steps_installed=$(find "${R}" -path '*/hooks/*/steps/*.sh' -type f | wc -l | tr -d ' ')
echo "=== ${alone_ok} of ${steps_installed} hook steps called alone"
check 'every hook step in the tree was called alone' is "${alone_ok}" "${steps_installed}"

echo "=== the installer: the time limit from agent-submission, the stop hook's timeout"
check 'settings env.BASH_MAX_TIMEOUT_MS is "2700000"' jq -e '.env.BASH_MAX_TIMEOUT_MS == "2700000"' "${S}/settings.json"
check 'the number has one home, agent-submission'"'"'s hooks/env.json' sh -c 'jq -e ".BASH_MAX_TIMEOUT_MS == \"2700000\"" "$1/domains/software-development/core/agents/agent-submission/hooks/env.json" && [ "$(grep -rl 2700000 "$1" | wc -l | tr -d " ")" -eq 1 ]' _ "${R}"
check 'the framework installer knows no domain'"'"'s env' sh -c '! grep -rq "BASH_MAX_TIMEOUT_MS" "$1/framework"' _ "${R}"
check 'the SubagentStop hook has timeout 300' jq -e '.hooks.SubagentStop[0].hooks[0].timeout == 300' "${S}/settings.json"
for agent in code-builder code-tester; do
	check "${agent}.md asks for no endless or hours-long command, and names no minutes" sh -c 'grep -qF "Don'"'"'t start a command that never ends (a watch mode, a server in the foreground), or one you expect to run for hours: run the checks that cover your change, and report the rest as \`narrowed\`." "$1" && ! grep -qE "[0-9]+ minutes" "$1"' _ "${K}/${agent}/${agent}.md"
done
check 'install-check.sh greps no agent prose' sh -c '! grep -qE "minutes|wrong:" "$1"' _ "${R}/framework/core/install/install-check.sh"
jq 'del(.env)' "${S}/settings.json" >"${S}/no-env.json"
out=$(sh "${R}/framework/core/install/install-check.sh" --settings "${S}/no-env.json" 2>&1); rc=$?
check 'install-check.sh: settings without the env are missing it' sh -c '[ "$1" -eq 1 ] && printf "%s" "$2" | grep -qx "missing: env BASH_MAX_TIMEOUT_MS=2700000"' _ "${rc}" "${out}"
jq '.env.BASH_MAX_TIMEOUT_MS = "600000"' "${S}/settings.json" >"${S}/other-env.json"
out=$(sh "${R}/framework/core/install/install-check.sh" --settings "${S}/other-env.json" 2>&1); rc=$?
check 'install-check.sh: another value is missing the right one' sh -c '[ "$1" -eq 1 ] && printf "%s" "$2" | grep -qx "missing: env BASH_MAX_TIMEOUT_MS=2700000"' _ "${rc}" "${out}"
jq 'del(.hooks.SubagentStop[0].hooks[0].timeout)' "${S}/settings.json" >"${S}/no-timeout.json"
out=$(sh "${R}/framework/core/install/install-check.sh" --settings "${S}/no-timeout.json" 2>&1); rc=$?
check 'install-check.sh: a stop hook without its timeout is missing it' sh -c '[ "$1" -eq 1 ] && printf "%s" "$2" | grep -qF "with timeout 300"' _ "${rc}" "${out}"
rm -rf -- "${S}/twin-tree/domains/software-development/core/agents/git-commit"
mkdir -p "${S}/twin-tree/domains/software-development/core/main-thread/agent-jobs/hooks"
printf '{"BASH_MAX_TIMEOUT_MS": "600000"}\n' >"${S}/twin-tree/domains/software-development/core/main-thread/agent-jobs/hooks/env.json"
twin=$(sh "${S}/twin-tree/framework/core/install/install-entries.sh" --json 2>&1); twin_rc=$?
echo "${twin}" | show | sed 's/^/    /'
check 'two env.json giving one name different values are refused, exit 2, naming both' sh -c '[ "$1" -eq 2 ] && printf "%s" "$2" | grep -qF "two env.json give one name different values: BASH_MAX_TIMEOUT_MS (2700000 in" && printf "%s" "$2" | grep -qF "600000 in"' _ "${twin_rc}" "${twin}"
printf '{"bash_max": 1}\n' >"${S}/twin-tree/domains/software-development/core/main-thread/agent-jobs/hooks/env.json"
twin=$(sh "${S}/twin-tree/framework/core/install/install-entries.sh" --json 2>&1); twin_rc=$?
check 'an env.json that is not {NAME: "value"} is refused' sh -c '[ "$1" -eq 2 ] && printf "%s" "$2" | grep -qF "is not a valid env.json"' _ "${twin_rc}" "${twin}"

echo "=== every repair line of build-agent.md section 4 (fixtures/repair-lines.json)"
printf 'only fixture\n' >"$(tree_of lines-changed)/new-file.txt"
rows=$(jq 'length' "${F}/repair-lines.json")
: >"${E}/repair-lines.txt"
i=0
while [ "${i}" -lt "${rows}" ]; do
	jq -c --argjson i "${i}" '.[$i]' "${F}/repair-lines.json" >"${S}/work/row.json"
	rule=$(jq -r '.rule' "${S}/work/row.json")
	kind=$(jq -r '.kind' "${S}/work/row.json")
	row_job=$((9000 + i))
	row_report="${effort}/reports/${kind}/${row_job}.json"
	mkdir -p "${row_report%/*}"
	rm -f -- "${row_report}"
	if jq -e 'has("raw")' "${S}/work/row.json" >/dev/null; then jq -j '.raw' "${S}/work/row.json" >"${row_report}"
	elif jq -e 'has("report")' "${S}/work/row.json" >/dev/null; then jq '.report' "${S}/work/row.json" >"${row_report}"; fi
	jq --arg tree "$(tree_of "lines-$(jq -r '.tree' "${S}/work/row.json")")" --argjson job "${row_job}" '{job: $job, state: "assigned", kind, agent_type: "code-builder",
		tree: $tree, report: "reports/\(.kind)/\($job).json", known_failures: (.known_failures // []), iteration: 1}
		+ (if .kind == "build-fix" then {findings, fix_round: 1} + (if has("sent_back") then {sent_back} else {} end) else {} end)
		+ {setup: {language: "php", frameworks: ["laravel"], standards: ["security"]}}' "${S}/work/row.json" >"${S}/work/row-job.json"
	got=$(sh "${STEPS}/report-validation.sh" --effort "${effort}" --job "${S}/work/row-job.json" 2>&1); rc=$?
	expected=$(jq -r --arg r "${row_report}" '.expected | gsub("<REPORT>"; $r)' "${S}/work/row.json")
	want_rc=1
	[ -n "${expected}" ] || want_rc=0
	printf '%s\n  exit %s: %s\n' "${rule}" "${rc}" "${got:-(accepted)}" | show >>"${E}/repair-lines.txt"
	check "${rule}" sh -c '[ "$1" -eq "$2" ] && [ "$3" = "$4" ]' _ "${rc}" "${want_rc}" "${got}" "${expected}"
	i=$((i + 1))
done

echo
echo "=== ${pass} PASS, ${fail} FAIL"
[ "${fail}" -eq 0 ]
