#!/bin/sh
# Stop-hook assurance, step 4: the real code-builder, code-tester and
# code-reviewer definitions, unsteered, as real Claude Code sub-agents.
#   run.sh setup [CELL|KIND...]  install the links, the repo, the cells (all,
#                                or only those) and one session per cell
#   run.sh batch CELL [LIMIT]    run one cell's headless main (blocks)
#   run.sh waves [N]             every cell, N at a time (default 6)
#   run.sh collect               copy the raw evidence into logs/ and prompts/
#   run.sh all [N]               setup, waves, collect, score
#   run.sh unlink                remove the skill links from the config
# Sandbox only: CLAUDE_CONFIG_DIR is the sandbox config, the run folder is
# under /Users/Shared/crucible-sandbox/stop-hook-real/. Never commits.
set -eu
EV=$(cd "$(dirname "$0")" && pwd)
R=/Users/cordona/IdeaProjects/cordona/claude-code-crucible/new-rewrite
AG="${R}/domains/software-development/core/agents"
SB=/Users/Shared/crucible-sandbox/stop-hook-real
export CLAUDE_CONFIG_DIR=/Users/Shared/crucible-sandbox/event-jobs/cfg
K="${CLAUDE_CONFIG_DIR}/skills"
EW="${K}/crucible-events/scripts/internal/event-write.sh"
ER="${K}/crucible-events/scripts/internal/events-read.sh"
HOOK="${K}/agent-submission/hooks/subagent-stop/submit-agent-work.sh"
RUN="${SB}/run${RUN_SUFFIX:-}"
export CRUCIBLE_HOME="${RUN}/space"
. "${EV}/lab/cells.sh"

links() { sh "${R}/framework/core/install/install-entries.sh" --json | jq -r '.skills[].name'; }
unlink_skills() {
	for name in $(links); do
		[ ! -L "${K:?}/${name:?}" ] || rm -- "${K:?}/${name:?}"
	done
}

# project: the repo's .claude/ (main starts in the repo, as in real use; the
# trees and the space stay elsewhere): the real agent definitions, and the
# settings: the installer's entries, every hook wrapped by capture.sh, plus
# the lab's prompt and job.assigned hooks. Kept out of git by the repo's
# info/exclude, so no tree sees it.
project() {
	proj="${RUN}/repo"
	mkdir -p "${proj}/.claude/agents"
	for a in code-builder code-tester code-reviewer; do cp "${AG}/${a}/${a}.md" "${proj}/.claude/agents/"; done
	jq --arg lab "${SB}/lab" --arg run "${RUN}" --arg space "${CRUCIBLE_HOME}" --arg q "'" '
		def wrap($event): .command |= (capture("^sh (?<q>.)(?<p>.*)(?<r>.)$").p as $p
			| "sh \($q)\($lab)/capture.sh\($q) \($q)\($event)-\($p | split("/") | last | rtrimstr(".sh"))\($q) \($q)\($p)\($q)");
		def lab($event; $tag; $script): {type: "command", command: "sh \($q)\($lab)/capture.sh\($q) \($q)\($event)-\($tag)\($q) \($q)\($lab)/\($script)\($q)"};
		.hooks |= with_entries(.key as $ev | .value |= map(.hooks |= map(wrap($ev))))
		| .hooks.PreToolUse += [{matcher: "Agent", hooks: [lab("PreToolUse"; "inject-prompt"; "inject-prompt.sh")]}]
		| .hooks.PostToolUse += [{matcher: "Agent", hooks: [lab("PostToolUse"; "assign-job"; "assign-job.sh")]}]
		| .env = ((.env // {}) + {REAL_RUN: $run, CRUCIBLE_HOME: $space})' \
		"${RUN}/entries-settings.json" >"${proj}/.claude/settings.json"
}

# The allow-list a human would grant once for the project's own gate
# commands, passed with --settings; no Write or Edit rules: the write-scope
# hook carries the writes. Agent and ToolSearch are main's, to start agents.
ALLOW='["Agent", "ToolSearch",
	"Bash(sh tests/run.sh)", "Bash(sh */tests/run.sh)",
	"Bash(shellcheck *)", "Bash(sh -n *)",
	"Bash(git -C * diff*)", "Bash(git -C * log*)", "Bash(git -C * show*)", "Bash(git -C * status*)",
	"Bash(git -C * ls-files*)", "Bash(git -C * rev-parse*)", "Bash(git -C * blame*)", "Bash(git -C * merge-base*)"]'

# session CELL: the cell's own --settings (the allow-list, and the env this
# cell needs: its hook-capture folder, its stub log, and the parked cells'
# shortened Bash limit) and main's prompt, in sessions/CELL.
session() {
	b=$1 sdir="${RUN}/sessions/$1"
	mkdir -p "${sdir}/hooks"
	limit=2700000; case ${b} in parked-*) limit=30000 ;; *) ;; esac
	jq -n --argjson allow "${ALLOW}" --arg cap "${sdir}/hooks" --arg stub "${sdir}/stub-calls.log" --arg limit "${limit}" \
		'{permissions: {allow: $allow}, env: {BASH_MAX_TIMEOUT_MS: $limit, MATRIX_CAPTURE: $cap, STUB_LOG: $stub}}' >"${sdir}/flag-settings.json"
	main_prompt "$1" >"${sdir}/main-prompt.txt"
}

# trust: the sandbox config trusts the repo, as a human's first
# interactive run there would, so its settings' additionalDirectories (the
# Crucible space) apply. Sandbox config only; a copy is kept in the run.
trust() {
	cj="${CLAUDE_CONFIG_DIR}/.claude.json"
	cp -p "${cj}" "${RUN}/claude.json.before"
	printf '%s\n' "${RUN}/repo" | jq -R . | jq -s . >"${RUN}/trusted.json"
	jq --slurpfile dirs "${RUN}/trusted.json" 'reduce $dirs[0][] as $d (.; .projects[$d] = ((.projects[$d] // {}) + {hasTrustDialogAccepted: true}))' \
		"${cj}" >"${cj}.new" && chmod 600 "${cj}.new" && mv -- "${cj}.new" "${cj}"
}

main_prompt() {
	t=$(agent_type_of "$(cut -d' ' -f2 "${RUN}/cells/$1/cell")")
	printf 'Start this agent with the Agent tool, in the background (run_in_background: true), with exactly the subagent_type, description and prompt given:\n'
	printf -- '- subagent_type "%s", description "job %s", prompt "%s"\n' "${t}" "$1" "$1"
	printf '\nThen wait until it has finished; you will be notified when it finishes. Do nothing else: do not read, write or run anything yourself, and send it no messages. When it has finished, reply with one line: DONE.\n'
}

setup() {
	shift 2>/dev/null || true
	[ -n "${RUN_SUFFIX:-}" ] || unlink_skills
	rm -rf -- "${RUN:?}"
	mkdir -p "${RUN}/cells" "${RUN}/sessions" "${K}" "${SB}/lab"
	cp -R "${EV}/lab/capture.sh" "${EV}/lab/assign-job.sh" "${EV}/lab/inject-prompt.sh" "${EV}/lab/stub" "${SB}/lab/"
	sh "${R}/framework/core/install/install-entries.sh" | sed -n '/^# Links/,/^$/p' | sed '1d' | grep -v '/CLAUDE.md' >"${RUN}/links.sh"
	[ -n "${RUN_SUFFIX:-}" ] || sh "${RUN}/links.sh"
	sh "${R}/framework/core/install/install-entries.sh" | sed -n '/^# Settings/,/^$/p' | sed '1d' >"${RUN}/entries-settings.json"
	repo="${RUN}/repo"
	cp -R "${EV}/fixtures/repo" "${repo}"
	git init -q -b main "${repo}"
	git -C "${repo}" add -A
	printf '.claude/\n' >>"${repo}/.git/info/exclude"
	git -C "${repo}" -c user.name=Fixture -c user.email=fixture@example.test -c commit.gpgsign=false commit -q -m 'the project'
	repo_main=$(sh "${K}/dev-base/scripts/internal/repo-of.sh" --dir "${repo}" | jq -r '.repo')
	cells_all >"${RUN}/cells.txt"
	while read -r cell kk batch; do
		if [ $# -gt 0 ]; then
			keep=''; for want in "$@"; do [ "${want}" != "${kk}" ] && [ "${want}" != "${cell}" ] || keep=1; done
			[ -n "${keep}" ] || continue
		fi
		batch=${cell}
		make_cell "${cell}" "${kk}" </dev/null
		printf '%s ' "${cell}"
	done <"${RUN}/cells.txt"
	echo
	project
	for c in "${RUN}"/cells/*/; do c=${c%/}; session "${c##*/}"; done
	trust
	(cd "${RUN}/repo" && sh "${R}/framework/core/install/install-check.sh" --settings .claude/settings.json) >"${RUN}/install-check.out" 2>&1 || true
	claude --version >"${RUN}/claude-version.txt"
	ls "${RUN}/sessions"
}

# run_batch CELL LIMIT: the cell's headless main (sonnet), started in the
# repo, in permission mode default,
# the allow-list by --settings, the stub gh and glab first on PATH; killed
# by PID past LIMIT seconds.
run_batch() {
	sdir="${RUN}/sessions/$1"
	(
		cd "${RUN}/repo"
		exec env -u CLAUDECODE -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_ENTRYPOINT PATH="${SB}/lab/stub:${PATH}" \
			claude -p "$(cat "${sdir}/main-prompt.txt")" --permission-mode default --settings "${sdir}/flag-settings.json" \
			--model sonnet --output-format stream-json --verbose --debug-file "${sdir}/debug.txt" \
			</dev/null >"${sdir}/main.jsonl" 2>"${sdir}/main.err"
	) &
	pid=$!
	echo "${pid}" >"${sdir}/main.pid"
	t=0 lim=${2:-3000}
	while kill -0 "${pid}" 2>/dev/null && [ "${t}" -lt "${lim}" ]; do sleep 5; t=$((t + 5)); done
	if kill -0 "${pid}" 2>/dev/null; then echo "main killed by run.sh after ${lim}s" >>"${sdir}/main.err"; kill "${pid}"; fi
	rc=0; wait "${pid}" || rc=$?
	printf 'main exit %s after %ss\n' "${rc}" "${t}" >>"${sdir}/main.err"
	rm -f "${sdir}/main.pid"
}

waves() {
	n=${2:-6}
	set -- $(ls "${RUN}/sessions")
	while [ $# -gt 0 ]; do
		pids=''
		i=0
		while [ $# -gt 0 ] && [ "${i}" -lt "${n}" ]; do
			echo "$(date +%T) cell $1"
			run_batch "$1" 3000 &
			pids="${pids} $!"; i=$((i + 1)); shift
		done
		for p in ${pids}; do wait "${p}" || true; done
	done
}

collect() {
	out="${EV}/logs"
	mkdir -p "${out}" "${EV}/prompts"
	for c in "${RUN}"/cells/*/; do
		c=${c%/}; cell=${c##*/}
		d="${out}/${cell}"
		rm -rf -- "${d:?}"; mkdir -p "${d}/hooks" "${d}/transcripts"
		e=$(cat "${c}/effort")
		sh "${ER}" --effort "${e}" >"${d}/events.json"
		cp -Rp "${e}/reports" "${d}/reports" 2>/dev/null || mkdir -p "${d}/reports"
		printf "%s step4 %s\n" "${cell}" "$(cut -d" " -f2 "${c}/cell")" >"${d}/cell"
		cp -p "${c}/prompt.txt" "${c}/plugins.txt" "${c}/task.txt" "${c}/tree" "${c}/batch" "${c}/live-seq" "${d}/"
		cp -p "${c}"/dispatched-*.json "${c}"/chosen.json "${c}"/challenges.json "${c}"/earlier.json "${c}"/fixes.json "${c}"/threads.json "${d}/" 2>/dev/null || true
		cp -p "${c}/prompt.txt" "${EV}/prompts/${cell}.txt"
		printf 'j1 %s %s\n' "$(cat "${c}/live-seq")" "$(agent_type_of "$(cut -d' ' -f2 "${c}/cell")")" >"${d}/jobs"
		: >"${d}/git.txt"
		for t in "${e}"/worktrees/*/; do
			t=${t%/}
			[ -d "${t}" ] || continue
			{ printf '== tree %s\n' "${t}"; git -C "${t}" log --format='commit %H%n%B%n.' --name-only main..HEAD; printf '== status\n'; git -C "${t}" status --porcelain; } >>"${d}/git.txt" 2>&1
			git -C "${t}" diff HEAD >"${d}/tree-uncommitted.diff" 2>&1 || true
		done
		b=$(cat "${c}/batch")
		hk="${RUN}/sessions/${b}/hooks"
		agent=$(jq -r '.[] | select(.type == "job.assigned" and .body.session != "sess-real-fixture") | .body.agent' "${d}/events.json" | tail -n 1)
		printf '%s\n' "${agent}" >"${d}/agent"
		# The cell's agent's hook calls, the Agent tool calls that started it,
		# and main's turn ends that list it as running.
		find "${hk}" -name '*.json' -type f -exec jq -r --arg a "${agent}" --arg c "job ${cell}" '
			select(.input.agent_id == $a or .input.tool_input.description == $c
				or ((.input.background_tasks // []) | any(.id == $a))) | input_filename' {} + 2>/dev/null \
			| while read -r f; do cp -p "${f}" "${d}/hooks/"; done
		# Its transcript, from its stop's input; the models it ran on.
		for tp in $(jq -r '.input.agent_transcript_path // empty' "${d}"/hooks/*SubagentStop-submit-agent-work*.json 2>/dev/null | sort -u); do
			[ -f "${tp}" ] || continue
			cp -p "${tp}" "${d}/transcripts/"
			[ ! -f "${tp%.jsonl}.meta.json" ] || cp -p "${tp%.jsonl}.meta.json" "${d}/transcripts/"
		done
		cat "${d}"/transcripts/*.jsonl 2>/dev/null | jq -r 'select(.type == "assistant") | .message.model // empty' | sort | uniq -c >"${d}/models.txt" || true
	done
	for s in "${RUN}"/sessions/*/; do
		s=${s%/}; d="${out}/_sessions/${s##*/}${RUN_SUFFIX:-}"
		rm -rf -- "${d:?}"; mkdir -p "${d}"
		cp -p "${s}"/main.jsonl "${s}"/main.err "${s}"/main-prompt.txt "${s}"/flag-settings.json "${d}/" 2>/dev/null || true
		proj="${RUN}/repo"
		cp -p "${proj}/.claude/settings.json" "${d}/settings.json"
		: >"${d}/stub-calls.log"; [ ! -f "${s}/stub-calls.log" ] || cp -p "${s}/stub-calls.log" "${d}/stub-calls.log"
		cp -Rp "${s}/hooks" "${d}/hooks"
		jq -r 'select(.type == "assistant") | .message.model // empty' "${s}/main.jsonl" 2>/dev/null | sort | uniq -c >"${d}/main-models.txt" || true
		[ ! -f "${s}/debug.txt" ] || grep -E 'agent_completion|Reached max turns|permission|denied|timed out|Hooks:|model' "${s}/debug.txt" >"${d}/debug-excerpt.txt" || true
		for a in code-builder code-tester code-reviewer; do shasum -a 256 "${proj}/.claude/agents/${a}.md" "${AG}/${a}/${a}.md"; done >"${d}/agent-definitions.sha256"
	done
	cp -p "${RUN}/install-check.out" "${RUN}/claude-version.txt" "${RUN}/cells.txt" "${out}/" 2>/dev/null || true
	echo "collected into ${out}"
}

case ${1-} in
	setup) setup "$@" ;;
	batch) run_batch "$2" "${3:-3000}" ;;
	waves) waves "$@" ;;
	collect) collect ;;
	all) setup; waves all "${2:-6}"; collect; sh "${EV}/score.sh" | tee "${EV}/score.txt" ;;
	unlink) unlink_skills ;;
	*) sed -n '2,12p' "$0" >&2; exit 2 ;;
esac
