#!/bin/sh
# Sandbox live run of the test agent's stop hook.
#   live.sh setup    install into the sandbox config; make the repo, tree,
#                    effort and identity fixture; the build and the approved
#                    plan through the real hook with hand-fed stops; then
#                    the test job's job.dispatched
#   live.sh fix      after the test: a build-fix through the hook with a
#                    hand-fed stop, then the test-fix job's job.dispatched
#   live.sh collect  gather the evidence and score the run
#   live.sh unlink   remove the skill links setup made
set -eu
R=/Users/cordona/IdeaProjects/cordona/claude-code-crucible/new-rewrite
L=/Users/Shared/crucible-sandbox/test-agent-live
LAB="${L}/lab"
RUN="${L}/run"
export CLAUDE_CONFIG_DIR=/Users/Shared/crucible-sandbox/event-jobs/cfg
export CRUCIBLE_HOME="${RUN}/space"
K="${CLAUDE_CONFIG_DIR}/skills"
EW="${K}/crucible-events/scripts/internal/event-write.sh"
ER="${K}/crucible-events/scripts/internal/events-read.sh"
HOOK="${K}/agent-submission/hooks/subagent-stop/submit-agent-work.sh"

links() { sh "${R}/framework/core/install/install-entries.sh" --json | jq -r '.skills[].name'; }
unlink_skills() {
	for name in $(links); do
		[ ! -L "${K:?}/${name:?}" ] || rm -- "${K:?}/${name:?}"
	done
}
next_seq() { echo $(($(sh "${ER}" --effort "${effort}" --paths | wc -l) + 1)); }
SETUP='{"language": "php", "standards": ["testing", "security"]}'
# job KIND AGENT_TYPE AGENT NAME EXTRA_JSON: job.dispatched and, for a
# fixture job, job.assigned; sets seq.
job() {
	seq=$(next_seq)
	jq -n --arg kind "$1" --arg type "$2" --arg tree "${tree}" --arg report "reports/$1/${seq}.json" \
		--argjson extra "$5" --argjson setup "${SETUP}" '{kind: $kind, agent_type: $type, tree: $tree, report: $report}
		+ $extra + {known_failures: [], iteration: 1, setup: $setup}' >"${RUN}/dispatched.json"
	sh "${EW}" --effort "${effort}" --type job.dispatched --by job-dispatch.sh --body-file "${RUN}/dispatched.json" >/dev/null
	[ -n "$3" ] || return 0
	jq -n --argjson job "${seq}" --arg agent "$3" --arg name "$4" '{job: $job, agent: $agent, name: $name}' >"${RUN}/assigned.json"
	sh "${EW}" --effort "${effort}" --type job.assigned --by assign-job.sh --body-file "${RUN}/assigned.json" >/dev/null
}
# The main prompt for the live job seq of kind $1; $2 is added to it.
prompt_for() {
	prompt="JOB: ${seq}. KIND: $1. TREE: ${tree}. REPORT: ${effort}/reports/$1/${seq}.json$2"
	awk -v p="${prompt}" '{ gsub("@PROMPT@", p); print }' "${LAB}/main-prompt.txt" >"${RUN}/main-prompt-$1.txt"
}

fix() {
	. "${RUN}/vars"
	# The builder's fix of the build, by a fixture agent through the real hook.
	job build-fix code-builder b0b0b0b0b0 build-fix-php-b0b0b0 '{"findings": ["REVIEW-01"], "fix_round": 1}'
	printf '// never retry a 4xx\n' >>"${tree}/app/Upload/Client.php"
	fixture_stop b0b0b0b0b0 '{"summary": "never retry a 4xx", "gates": [{"gate": "test", "result": "pass"}],
		"fixes": [{"id": "REVIEW-01", "status": "done"}]}' "${effort}/reports/build-fix/${seq}.json"
	printf 'buildfix=%s\n' "${seq}" >>"${RUN}/vars"
	# The live test-fix: its own loop, so its round is 1 too.
	job test-fix code-tester '' '' "{\"findings\": [\"TEST-01\"], \"plan\": ${plan}, \"fix_round\": 1}"
	prompt_for test-fix '. FINDING: TEST-01, the test does not assert the retry count.'
	printf 'testfix=%s\n' "${seq}" >>"${RUN}/vars"
	cat "${RUN}/vars"
	sh "${ER}" --effort "${effort}" | jq -r '.[] | "\(.seq) \(.type)"' | tail -n 4
}

# A fixture agent's stop, hand-fed to the real hook: agent $1 hands in
# report text $2 at path $3.
fixture_stop() {
	mkdir -p "${3%/*}"; printf '%s\n' "$2" >"$3"
	jq -cn --arg a "$1" '{session_id: "sess-live-fixture", hook_event_name: "SubagentStop", agent_id: $a}' | sh "${HOOK}"
}

setup() {
	unlink_skills
	rm -rf -- "${RUN:?}"
	mkdir -p "${RUN}/logs" "${K}"
	sh "${R}/framework/core/install/install-entries.sh" | sed -n '/^# Links/,/^$/p' | sed '1d' | grep -v '/CLAUDE.md' >"${RUN}/links.sh"
	sh "${RUN}/links.sh"
	repo="${RUN}/repo"
	git init -q -b main "${repo}"
	mkdir -p "${repo}/app/Upload" "${repo}/tests/Upload" "${repo}/.claude/agents"
	awk 'BEGIN { for (i = 1; i <= 88; i++) printf "// Client.php line %d\n", i }' >"${repo}/app/Upload/Client.php"
	awk 'BEGIN { for (i = 1; i <= 90; i++) printf "// UploadClientTest.php line %d\n", i }' >"${repo}/tests/Upload/UploadClientTest.php"
	cp "${LAB}/code-tester.md" "${repo}/.claude/agents/code-tester.md"
	sh "${R}/framework/core/install/install-entries.sh" | sed -n '/^# Settings/,/^$/p' | sed '1d' >"${RUN}/entries-settings.json"
	git -C "${repo}" add -A
	git -C "${repo}" -c user.name=Fixture -c user.email=fixture@example.test commit -q -m 'the project'
	effort=$(sh "${K}/crucible-effort/scripts/main/effort-start.sh" --name 'live test agent')
	repo_main=$(sh "${K}/dev-base/scripts/internal/repo-of.sh" --dir "${repo}" | jq -r '.repo')
	jq -n --arg repo "${repo_main}" '{repo: $repo, name: "Test Agent", email: "test-agent@example.test",
		signing: {format: "ssh", key: "/nonexistent/fixture-key.pub"}, fingerprint: "", answer: 1}' >"${RUN}/identity.json"
	sh "${EW}" --effort "${effort}" --type identity.set --by identity-set.sh --body-file "${RUN}/identity.json" >/dev/null
	sh "${K}/git-worktree/scripts/main/worktree-cut.sh" --effort "${effort}" --repo "${repo}" --name upload --from checkout >/dev/null
	tree="${effort}/worktrees/upload"
	# The build under test, and its approved plan: fixture agents through
	# the real hook.
	job build code-builder b0b0b0b0b0 build-php-b0b0b0 '{}'
	printf '// retry only on 5xx\n' >>"${tree}/app/Upload/Client.php"
	printf '// the retry test stub\n' >>"${tree}/tests/Upload/UploadClientTest.php"
	fixture_stop b0b0b0b0b0 '{"summary": "add a retry limit to the upload client", "gates": [{"gate": "test", "result": "pass"}]}' \
		"${effort}/reports/build/${seq}.json"
	job test-plan code-tester c0c0c0c0c0 test-plan-php-c0c0c0 '{}'
	fixture_stop c0c0c0c0c0 '{"behaviours": [{"id": "B-1", "text": "a 5xx is retried up to the limit", "at": "app/Upload/Client.php:42"}],
		"tests": [{"id": "T-1", "action": "add", "file": "tests/Upload/UploadClientTest.php", "name": "retries a 503 three times then fails",
		"level": "e2e", "guards": ["B-1"], "breaks_on": "the limit is ignored"}], "baseline": {"gate": "test", "result": "pass"},
		"run": [{"where": "repo root", "command": "./vendor/bin/phpunit --filter UploadClientTest"}]}' "${effort}/reports/test-plan/${seq}.json"
	plan=$(sh "${ER}" --effort "${effort}" --type test-plan.submitted | jq -r 'last.seq')
	jq -n --arg seq "${plan}" '{record: "test-plan", subject: $seq, question: "Approve the test plan?",
		accept: "Approve (Recommended)", answer: "Approve (Recommended)", accepted: true}' >"${RUN}/answer.json"
	sh "${EW}" --effort "${effort}" --type gate.answered --by record-gate-answer.sh --body-file "${RUN}/answer.json" >/dev/null
	# The live test job; its job.assigned comes from the sandbox hook.
	job test code-tester '' '' "{\"plan\": ${plan}}"
	jq --arg live "${RUN}" --arg effort "${effort}" --arg space "${CRUCIBLE_HOME}" --arg hook "sh '${LAB}/assign-job.sh'" '
		.env = {LIVE: $live, LIVE_EFFORT: $effort, CRUCIBLE_HOME: $space}
		| .hooks.PostToolUse += [{matcher: "Agent", hooks: [{type: "command", command: $hook}]}]' \
		"${RUN}/entries-settings.json" >"${repo}/.claude/settings.json"
	prompt_for test ''
	printf 'effort=%s\ntree=%s\ntest=%s\nrepo=%s\nplan=%s\n' "${effort}" "${tree}" "${seq}" "${repo}" "${plan}" >"${RUN}/vars"
	(cd "${repo}" && sh "${R}/framework/core/install/install-check.sh" --settings "${repo}/.claude/settings.json") >"${RUN}/install-check.out" 2>&1 || true
	cat "${RUN}/install-check.out" "${RUN}/vars"
	sh "${ER}" --effort "${effort}" | jq -r '.[] | "\(.seq) \(.type)"'
}

check() { # check WHAT COMMAND...
	what=$1; shift
	if "$@" >/dev/null 2>&1; then pass=$((pass + 1)); echo "PASS: ${what}"
	else fail=$((fail + 1)); echo "FAIL: ${what}"; fi
}

# kind_evidence KIND SEQ: one kind's report, event and commit, into
# evidence/KIND/; sets report, ev, agent, name and commit.
kind_evidence() {
	dir="${out}/$1"
	mkdir -p "${dir}"
	report="${effort}/reports/$1/$2.json"
	cp -p -- "${report}" "${dir}/report.json" 2>/dev/null || echo none >"${dir}/report.json"
	ls -l "${report}" >"${dir}/report-mode.txt" 2>&1 || true
	ev=$(jq -c --argjson j "$2" '[.[] | select((.body.report | type) == "object" and .body.job == $j)] | last // "none"' "${out}/events.json")
	printf '%s\n' "${ev}" | jq . >"${dir}/event.json"
	commit=$(printf '%s' "${ev}" | jq -r '.body.commit // empty')
	if [ -n "${commit}" ]; then
		{ git -C "${tree}" log -1 --format=%B "${commit}"; git -C "${tree}" show --stat --format='commit %H%nAuthor: %an <%ae>%nSigned: %G?' "${commit}"; } >"${dir}/commit.txt"
	else
		echo none >"${dir}/commit.txt"
	fi
	agent=$(jq -r --argjson j "$2" '[.[] | select(.type == "job.assigned" and .body.job == $j)] | last | .body.agent // ""' "${out}/events.json")
	name=$(jq -r --argjson j "$2" '[.[] | select(.type == "job.assigned" and .body.job == $j)] | last | .body.name // ""' "${out}/events.json")
	transcript=$(find "${CLAUDE_CONFIG_DIR}/projects" -name "agent-${agent}.jsonl" -newer "${RUN}/links.sh" 2>/dev/null | head -n 1)
	[ -z "${transcript}" ] || cp -- "${transcript}" "${dir}/agent-transcript.jsonl"
	: >"${dir}/first-hook-output.txt"
	[ -z "${transcript}" ] || grep -o 'Your report [^"]*was not accepted[^"]*' "${transcript}" | head -n 1 | sed 's/\\n/\n/g' >"${dir}/first-hook-output.txt" || true
}

collect() {
	. "${RUN}/vars"
	out="${L}/evidence"
	rm -rf -- "${out:?}"; mkdir -p "${out}"
	sh "${ER}" --effort "${effort}" >"${out}/events.json"
	jq '[.[] | select((.type | startswith("job.")) or (.body.report | type) == "object" or .type == "gate.answered")]' "${out}/events.json" >"${out}/job-events.json"
	cp -- "${RUN}/logs/"* "${out}/" 2>/dev/null || true
	cp -- "${RUN}/install-check.out" "${RUN}"/main-prompt-*.txt "${out}/"
	cp -- "${RUN}/repo/.claude/settings.json" "${out}/project-settings.json"
	ls "${effort}/stops" >"${out}/stops.txt" 2>&1 || true
	pass=0 fail=0
	sum() { sh "${K}/agent-jobs/scripts/internal/report-hash.sh" --report "$1"; }

	kind_evidence test "${test}"
	check 'test: job.assigned written for the agent the Agent tool started' test -n "${agent}"
	check 'test: first stop held with the mutation repair line' grep -qF 'list the mutation gate: pass with a note, fail with what survived, or not_run with why' "${out}/test/first-hook-output.txt"
	check 'test: one refusal counted' sh -c '[ "$(cat "$1/stops/$2.held")" = 1 ]' _ "${effort}" "${test}"
	check 'test: second stop accepted, test.submitted by submission-event.sh for its agent' sh -c 'printf "%s" "$1" | jq -e --arg a "$2" ".type == \"test.submitted\" and .by == \"submission-event.sh\" and .body.agent == \$a"' _ "${ev}" "${agent}"
	check 'test: report {path, sha256} at reports/test/<seq>.json matches the file' sh -c 'printf "%s" "$1" | jq -e --arg p "$2" --arg s "$3" ".body.report == {path: \$p, sha256: \$s}"' _ "${ev}" "reports/test/${test}.json" "$(sum "${report}")"
	check 'test: the report lists the mutation gate now, and is read-only' sh -c '[ -n "$(find "$1" -prune -perm 0444)" ] && jq -e "any(.gates[]; .gate == \"mutation\")" "$1"' _ "${report}"
	check 'test: the commit, crucible(test), Effort, Job, Iteration, Language, Standards; no Framework' sh -c '[ "$(git -C "$1" log -1 --format=%B "$2")" = "$3" ]' _ "${tree}" "${commit}" "crucible(test): $(jq -r .summary "${report}")

Effort: ${effort##*/}
Job: ${test} ${name}
Iteration: 1
Language: php
Standards: testing, security"

	kind_evidence build-fix "${buildfix}"
	check 'the build'"'"'s own fix: build-fix.submitted, fix round 1' sh -c 'printf "%s" "$1" | jq -e ".type == \"build-fix.submitted\" and .body.fix_round == 1"' _ "${ev}"

	kind_evidence test-fix "${testfix}"
	check 'test-fix: job.assigned written for its own agent' test -n "${agent}"
	check 'test-fix: accepted, test-fix.submitted, iteration 1, fix round 1, counted apart from the build-fix'"'"'s' sh -c 'printf "%s" "$1" | jq -e ".type == \"test-fix.submitted\" and .body.iteration == 1 and .body.fix_round == 1"' _ "${ev}"
	check 'test-fix: report {path, sha256} at reports/test-fix/<seq>.json matches the file' sh -c 'printf "%s" "$1" | jq -e --arg p "$2" --arg s "$3" ".body.report == {path: \$p, sha256: \$s}"' _ "${ev}" "reports/test-fix/${testfix}.json" "$(sum "${report}")"
	check 'test-fix: the report fixes TEST-01 and is read-only' sh -c '[ -n "$(find "$1" -prune -perm 0444)" ] && jq -e ".fixes[0].status == \"done\" and .fixes[0].id == \"TEST-01\"" "$1"' _ "${report}"
	check 'test-fix: the commit is the tree'"'"'s HEAD, crucible(test-fix), with Fix-Round 1, the test file only' sh -c '[ "$2" = "$(git -C "$1" rev-parse HEAD)" ] && git -C "$1" log -1 --format=%s "$2" | grep -q "^crucible(test-fix): " && git -C "$1" log -1 --format=%B "$2" | grep -qx "Fix-Round: 1" && [ "$(git -C "$1" show --name-only --format= "$2")" = tests/Upload/UploadClientTest.php ]' _ "${tree}" "${commit}"
	check 'no job.ended; the tree clean' sh -c '[ "$(jq "[.[] | select(.type == \"job.ended\")] | length" "$1")" -eq 0 ] && [ -z "$(git -C "$2" status --porcelain)" ]' _ "${out}/events.json" "${tree}"
	echo "${pass} PASS, ${fail} FAIL"
	[ "${fail}" -eq 0 ]
}

case ${1-} in
	setup) setup ;;
	fix) fix ;;
	collect) collect 2>&1 | tee "${L}/score.txt" ;;
	unlink) unlink_skills ;;
	*) echo 'usage: live.sh setup | fix | collect | unlink' >&2; exit 2 ;;
esac
