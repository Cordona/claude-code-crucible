#!/bin/sh
# Live run of jobs define and assign with the real builder, tester and
# reviewer, in an interactive session on the sandbox's logged-in config.
#   live.sh setup    install into the sandbox config; the repo, effort,
#                    identity fixture, grill, context cut and spec
#   live.sh plan     after the build: a test plan for the build's tree, made
#                    the old way (the plan kinds aren't moved yet)
#   live.sh start    the session in tmux (jobs-live), auto mode
#   live.sh collect  the evidence
#   live.sh unlink   remove the skill links and agent files setup made
set -eu
R=/Users/cordona/IdeaProjects/cordona/claude-code-crucible/new-rewrite
E=$(cd -- "$(dirname -- "$0")" && pwd)
L=/Users/Shared/crucible-sandbox/jobs-live
RUN="${L}/run"
export CLAUDE_CONFIG_DIR=/Users/Shared/crucible-sandbox/event-jobs/cfg
export CRUCIBLE_HOME="${RUN}/space" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
K="${CLAUDE_CONFIG_DIR}/skills"
EW="${K}/crucible-events/scripts/internal/event-write.sh"
ER="${K}/crucible-events/scripts/internal/events-read.sh"
fgit() { git -c user.name=Fixture -c user.email=fixture@example.test -c commit.gpgsign=false "$@"; }

links() { sh "${R}/framework/core/install/install-entries.sh" --json | jq -r '.skills[].name'; }
unlink_all() {
	for name in $(links); do
		[ ! -L "${K:?}/${name:?}" ] || rm -- "${K:?}/${name:?}"
	done
	for f in "${CLAUDE_CONFIG_DIR}"/agents/code-*.md; do [ -f "${f}" ] && rm -- "${f}"; done
	rm -rf -- "${CLAUDE_CONFIG_DIR:?}/cache/jobs-assign"
}
# decide RECORD SUBJECT CARD: one gate answered yes through the installed hooks.
decide() {
	t="t-$1-$(date +%s)"
	CLAUDE_CODE_SESSION_ID=sess-setup sh "${K}/crucible-gate/scripts/main/show-card.sh" --record "$1" --effort "${effort}" --subject "$2" --accept 'Approve (Recommended)' "$3" >/dev/null
	jq -cn --rawfile m "$3" '{session_id: "sess-setup", last_assistant_message: $m}' | sh "${K}/crucible-gate/hooks/stop/require-card-shown.sh" >/dev/null
	jq -cn --arg t "${t}" '{session_id: "sess-setup", tool_name: "AskUserQuestion", tool_use_id: $t, tool_input: {questions: [{question: "Decide?", header: "Gate", options: [{label: "Approve (Recommended)", description: "yes"}, {label: "No", description: "no"}]}]}}' \
		| sh "${K}/crucible-gate/hooks/pre-tool-use/hold-question-until-card-shown.sh" >/dev/null
	jq -cn --arg t "${t}" '{session_id: "sess-setup", tool_name: "AskUserQuestion", tool_use_id: $t, tool_response: {answers: {"Decide?": "Approve (Recommended)"}}}' \
		| sh "${K}/crucible-gate/hooks/post-tool-use/record-gate-answer.sh"
}

setup() {
	unlink_all
	rm -rf -- "${RUN:?}"
	mkdir -p "${RUN}" "${K}" "${CLAUDE_CONFIG_DIR}/agents"
	# Links from install-entries.sh's own output; its CLAUDE.md link is left
	# out (the config is shared): the repo carries the framework's CLAUDE.md.
	sh "${R}/framework/core/install/install-entries.sh" | sed -n '/^# Links/,/^$/p' | sed '1d' | grep -v '/CLAUDE.md' >"${RUN}/links.sh"
	sh "${RUN}/links.sh"
	repo="${RUN}/repo"
	mkdir -p "${repo}/bin" "${repo}/tests" "${repo}/.claude"
	printf '#!/bin/sh\n# Prints a greeting for the name given.\nset -eu\nname=${1:-world}\nprintf '"'"'hello %%s\\n'"'"' "${name}"\n' >"${repo}/bin/greet.sh"
	printf '#!/bin/sh\n# Runs every tests/*_test.sh; fails on the first that fails.\nset -eu\nfor t in "$(dirname "$0")"/*_test.sh; do sh "$t"; done\necho all passed\n' >"${repo}/tests/run.sh"
	printf '#!/bin/sh\nset -eu\n[ "$(sh "$(dirname "$0")/../bin/greet.sh" ada)" = "hello ada" ]\n' >"${repo}/tests/greet_test.sh"
	printf '# greet\n\nA greeting in shell. Checks: `sh tests/run.sh` and `shellcheck bin/*.sh tests/*.sh`.\n' >"${repo}/README.md"
	ln -s "${R}/framework/core/CLAUDE.md" "${repo}/CLAUDE.md"
	printf 'CLAUDE.md\n.claude/\n' >"${repo}/.gitignore"
	fgit init -q -b main "${repo}" && fgit -C "${repo}" add -A && fgit -C "${repo}" commit -q -m 'the project'
	sh "${R}/framework/core/install/install-entries.sh" | sed -n '/^# Settings/,/^$/p' | sed '1d' \
		| jq --arg space "${CRUCIBLE_HOME}" '.env = ((.env // {}) + {CRUCIBLE_HOME: $space, GIT_CONFIG_GLOBAL: "/dev/null", GIT_CONFIG_NOSYSTEM: "1"})' >"${repo}/.claude/settings.json"
	effort=$(CLAUDE_CODE_SESSION_ID=sess-setup sh "${K}/crucible-effort/scripts/main/effort-start.sh" --name 'greet shout')
	repo_main=$(sh "${K}/dev-base/scripts/internal/repo-of.sh" --dir "${repo}" | jq -r '.repo')
	jq -n --arg repo "${repo_main}" '{repo: $repo, name: "Jobs Live", email: "jobs-live@example.test",
		signing: {format: "ssh", key: "/nonexistent/fixture-key.pub"}, fingerprint: "", answer: 1}' >"${RUN}/identity.json"
	sh "${EW}" --effort "${effort}" --type identity.set --by identity-set.sh --body-file "${RUN}/identity.json" >/dev/null
	export CLAUDE_CODE_SESSION_ID=sess-setup
	D=$(sh "${K}/crucible-grill/scripts/main/grill-new.sh" --effort "${effort}" --topic 'the shout flag')
	sh "${K}/crucible-grill/scripts/main/grill-add.sh" --grill "${D}" --question 'Flag name?' --recommendation '--shout' --reason 'Plain and clear' >/dev/null
	sh "${K}/crucible-grill/scripts/main/grill-answer.sh" --grill "${D}" --id q1 --text 'Yes, --shout, before the name' >/dev/null
	GE=$(sh "${K}/crucible-grill/scripts/main/grill-end.sh" --grill "${D}")
	sh "${K}/code-context/scripts/main/context-add-commit.sh" --effort "${effort}" --repo "${repo}" --ref HEAD >/dev/null 2>&1 || :
	printf 'Context to cut\n' >"${RUN}/ctx-card.md"
	decide context-done "$(sh "${K}/crucible-context/scripts/main/context-fingerprint.sh" --effort "${effort}" | sed -n 's/FINGERPRINT: //p')" "${RUN}/ctx-card.md"
	sh "${K}/crucible-context/scripts/main/context-cut.sh" --effort "${effort}" >/dev/null
	mkdir -p "${effort}/spec"
	printf '## Goal\nbin/greet.sh takes --shout before the name and prints the greeting in capitals.\n## Done when\n`sh bin/greet.sh --shout ada` prints HELLO ADA; without --shout nothing changes; the checks pass.\n## Scope\nIn: bin/greet.sh and its tests. Out: other flags.\n## Constraints\nPOSIX sh.\n## Open points\nNone\n' >"${effort}/spec/1.md"
	decide spec-approval "$(shasum -a 256 "${effort}/spec/1.md" | cut -d ' ' -f 1)" "${effort}/spec/1.md"
	sh "${K}/crucible-spec/scripts/main/spec-approve.sh" --effort "${effort}" --draft "${effort}/spec/1.md" >/dev/null
	printf 'effort=%s\nrepo=%s\n' "${effort}" "${repo}" >"${RUN}/vars"
	(cd "${repo}" && sh "${R}/framework/core/install/install-check.sh" --settings "${repo}/.claude/settings.json") >"${RUN}/install-check.out" 2>&1 || :
	cat "${RUN}/install-check.out" "${RUN}/vars"
	sh "${ER}" --effort "${effort}" | jq -r '.[] | "\(.seq) \(.type)"'
}

# The plan, made the old way: a test-plan job dispatched, assigned and
# handed in on the build's tree, with a small real plan for the shout flag.
plan() {
	. "${RUN}/vars"
	tree=$(sh "${ER}" --effort "${effort}" --type worktree.cut | jq -r '.[-1].body.path')
	seq=$(($(sh "${ER}" --effort "${effort}" --paths | wc -l) + 1))
	jq -n --arg tree "${tree}" --arg report "reports/test-plan/${seq}.json" '{kind: "test-plan", agent_type: "code-tester", tree: $tree,
		report: $report, known_failures: [], setup: {language: "shell", standards: ["testing"]}}' >"${RUN}/plan-dispatched.json"
	sh "${EW}" --effort "${effort}" --type job.dispatched --by job-dispatch.sh --body-file "${RUN}/plan-dispatched.json" >/dev/null
	jq -n --argjson j "${seq}" '{job: $j, agent: "plan0000001", name: "test-plan-shell", session: "sess-setup"}' >"${RUN}/plan-assigned.json"
	sh "${EW}" --effort "${effort}" --type job.assigned --by assign-job.sh --body-file "${RUN}/plan-assigned.json" >/dev/null
	mkdir -p "${effort}/reports/test-plan"
	jq -n '{behaviours: [{id: "B-1", text: "--shout before the name prints the greeting in capitals", at: "bin/greet.sh"}],
		tests: [{id: "T-1", action: "add", file: "tests/shout_test.sh", name: "greet --shout ada prints HELLO ADA", level: "unit",
			why: "the flag is one branch in one script", guards: ["B-1"], breaks_on: "the flag is ignored or the case is wrong"}],
		baseline: {gate: "test", result: "pass"}, run: [{where: "the job tree", command: "sh tests/run.sh"}]}' >"${effort}/reports/test-plan/${seq}.json"
	chmod 444 "${effort}/reports/test-plan/${seq}.json"
	jq -n --argjson j "${seq}" --arg sha "$(shasum -a 256 "${effort}/reports/test-plan/${seq}.json" | cut -d ' ' -f 1)" \
		'{job: $j, agent: "plan0000001", report: {path: "reports/test-plan/\($j).json", sha256: $sha}}' >"${RUN}/plan-sub.json"
	sh "${EW}" --effort "${effort}" --type test-plan.submitted --by submission-event.sh --body-file "${RUN}/plan-sub.json"
}

start() {
	. "${RUN}/vars"
	tmux kill-session -t jobs-live 2>/dev/null || :
	tmux new-session -d -s jobs-live -x 220 -y 50 -c "${repo}" "env -u CLAUDECODE -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_ENTRYPOINT CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR} CRUCIBLE_HOME=${CRUCIBLE_HOME} GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 claude --model claude-opus-5-5 --permission-mode auto; sleep 3000"
}

collect() {
	. "${RUN}/vars"
	mkdir -p "${E}/out"
	sh "${ER}" --effort "${effort}" | jq '[.[] | {seq, type, by, body}]' | sed "s|${L}|<L>|g" >"${E}/out/events.json"
	ls "${CLAUDE_CONFIG_DIR}/agents" >"${E}/out/agent-files.txt"
}

case ${1-} in setup) setup ;; plan) plan ;; start) start ;; collect) collect ;; unlink) unlink_all ;; *) echo "usage: live.sh setup|plan|start|collect|unlink" >&2; exit 2 ;; esac
