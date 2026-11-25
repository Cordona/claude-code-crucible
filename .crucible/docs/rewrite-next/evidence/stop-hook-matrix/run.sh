#!/bin/sh
# Stop-hook mechanism matrix (assurance plan, step 3): real Claude Code
# sub-agents, stand-ins on haiku, steered to fail as each scenario says.
#   run.sh setup MODE [SCENARIO...]  install the links, the repo, the cells
#                                    (all, or only those scenarios) and one
#                                    session folder per batch
#   run.sh batch MODE BATCH          run one batch's headless main (blocks)
#   run.sh waves MODE [N]            every batch but b-s5a, N at a time
#                                    (default 3), then b-s5a alone, then post
#   run.sh s5a MODE                  b-s5a alone, a rules file removed
#   run.sh post MODE                 S5b: clear the commit fault, then
#                                    recover-submission.sh --finish/--give-up
#   run.sh collect MODE              copy the raw evidence into logs/
#   run.sh all MODE [SCENARIO...]    setup, waves, collect, score
#   run.sh unlink                    remove the skill links from the config
# RUN_SUFFIX=-x runs a rerun beside the main run (run-MODE-x), keeping the
# links; its cells' logs replace theirs, its sessions go to _sessions/*-x.
# MODE is real (the hooks installed) or control (every framework hook
# removed; the lab's capture, observe and assign hooks stay). The layout is
# the real one: main starts in its batch's repo, the trees and reports live
# in the space, mode default, the allow-list by --settings. Sandbox only.
set -eu
EV=$(cd "$(dirname "$0")" && pwd)
R=/Users/cordona/IdeaProjects/cordona/claude-code-crucible/new-rewrite
SB=/Users/Shared/crucible-sandbox/stop-hook-matrix
export CLAUDE_CONFIG_DIR=/Users/Shared/crucible-sandbox/event-jobs/cfg
# No global or system git config, so nothing is ever signed with a real key.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
K="${CLAUDE_CONFIG_DIR}/skills"
EW="${K}/crucible-events/scripts/internal/event-write.sh"
ER="${K}/crucible-events/scripts/internal/events-read.sh"
HOOK="${K}/agent-submission/hooks/subagent-stop/submit-agent-work.sh"

mode=${2:-real}
case ${mode} in real | control) ;; *) mode=real ;; esac
RUN="${SB}/run-${mode}${RUN_SUFFIX:-}"
export CRUCIBLE_HOME="${RUN}/space"
. "${EV}/lab/cells.sh"

# One hash of every framework file, to show the framework didn't change
# during a run.
framework_hash() { find "${R}" -type f -not -path '*/.git/*' | LC_ALL=C sort | xargs shasum -a 256 | shasum -a 256 | cut -d' ' -f1; }

links() { sh "${R}/framework/core/install/install-entries.sh" --json | jq -r '.skills[].name'; }
unlink_skills() {
	for name in $(links); do
		[ ! -L "${K:?}/${name:?}" ] || rm -- "${K:?}/${name:?}"
	done
}

# session BATCH: the batch's repo is main's folder: the agents and settings
# (the installer's entries, every hook wrapped by capture.sh; in control
# every framework hook removed) in its .claude/, kept out of git status; the
# allow-list, the space as a working dir and the deny rule for --settings;
# main's prompt.
session() {
	b=$1 sdir="${RUN}/sessions/$1" rp="${RUN}/repos/$1"
	mkdir -p "${sdir}/hooks" "${rp}/.claude/agents"
	cp "${EV}"/lab/agents/*.md "${rp}/.claude/agents/"
	jq --arg lab "${SB}/lab" --arg mode "${mode}" --arg run "${RUN}" --arg cap "${sdir}/hooks" --arg space "${CRUCIBLE_HOME}" --arg q "'" '
		def wrap($event): .command |= (capture("^sh (?<q>.)(?<p>.*)(?<r>.)$").p as $p
			| "sh \($q)\($lab)/capture.sh\($q) \($q)\($event)-\($p | split("/") | last | rtrimstr(".sh"))\($q) \($q)\($p)\($q)");
		def lab($event; $tag; $script): {type: "command", command: "sh \($q)\($lab)/capture.sh\($q) \($q)\($event)-\($tag)\($q) \($q)\($lab)/\($script)\($q)"};
		.hooks |= with_entries(.key as $ev | .value |= (map(.hooks |= map(select($mode == "real") | wrap($ev)))
			| map(select(.hooks | length > 0))))
		| .hooks.PostToolUse += [{matcher: "Agent", hooks: [lab("PostToolUse"; "assign-job"; "assign-job.sh")]}]
		| .hooks.PreToolUse += [{matcher: "SendMessage", hooks: [lab("PreToolUse"; "assign-job"; "assign-job.sh")]},
			{matcher: "Bash|Write|Edit", hooks: [lab("PreToolUse"; "observe"; "observe.sh")]}]
		| .hooks.SubagentStop += [{hooks: [lab("SubagentStop"; "observe"; "observe.sh")]}]
		| .hooks.Stop += [{hooks: [lab("Stop"; "observe"; "observe.sh")]}]
		| del(.permissions)
		| .env = ((.env // {}) + {BASH_MAX_TIMEOUT_MS: "30000", MATRIX_RUN: $run, MATRIX_CAPTURE: $cap, CRUCIBLE_HOME: $space})' \
		"${RUN}/entries-settings.json" >"${rp}/.claude/settings.json"
	jq --argjson allow "${ALLOW}" '{permissions: {allow: $allow, additionalDirectories: .permissions.additionalDirectories, deny: .permissions.deny}}' \
		"${RUN}/entries-settings.json" >"${sdir}/flag-settings.json"
	main_prompt "$1" >"${sdir}/main-prompt.txt"
}

# The allow-list: the project's gate commands and read-only git -C forms
# only. No Write or Edit rule: the write-scope hook is what lets a job agent
# write.
ALLOW='["Bash(sh tests/run.sh)", "Bash(sh tests/slow.sh:*)", "Bash(sh tools/fmt.sh)", "Bash(sh tools/fmt.sh --undo)",
	"Bash(git -C * status*)", "Bash(git -C * diff*)", "Bash(git -C * log*)", "Bash(git -C * show*)",
	"Agent", "SendMessage", "TaskStop", "ToolSearch"]'

# make_repo BATCH: the batch's repo, its fixture project, committed unsigned;
# sets repo and repo_main.
make_repo() {
	repo="${RUN}/repos/$1"
	if [ ! -d "${repo}/.git" ]; then
		git init -q -b main "${repo}"
		git -C "${repo}" config commit.gpgsign false
		git -C "${repo}" config user.name Fixture
		git -C "${repo}" config user.email fixture@example.test
		printf '.claude/\n' >>"${repo}/.git/info/exclude"
		mkdir -p "${repo}/src/upload" "${repo}/tests/Upload" "${repo}/tools"
		awk 'BEGIN { for (i = 1; i <= 20; i++) printf "# a.sh line %d\n", i }' >"${repo}/a.sh"
		awk 'BEGIN { for (i = 1; i <= 40; i++) printf "# b.sh line %d\n", i }' >"${repo}/b.sh"
		awk 'BEGIN { for (i = 1; i <= 90; i++) printf "// Client.kt line %d\n", i }' >"${repo}/src/upload/Client.kt"
		awk 'BEGIN { for (i = 1; i <= 30; i++) printf "// UploadClientTest line %d\n", i }' >"${repo}/tests/Upload/UploadClientTest.php"
		printf '#!/bin/sh\n# The project'"'"'s test gate.\necho "tests ok"\n' >"${repo}/tests/run.sh"
		printf '#!/bin/sh\n# A slow test run: sleeps $1 seconds.\nperl -e "sleep ${1:-1}"\necho "slow tests ok after ${1:-1} s"\n' >"${repo}/tests/slow.sh"
		printf '#!/bin/sh\n# The project'"'"'s formatter; --undo puts a.sh back.\nif [ "${1-}" = --undo ]; then git checkout -q -- a.sh; echo "a.sh restored"; else printf "# formatted\\n" >>a.sh; echo "a.sh formatted"; fi\n' >"${repo}/tools/fmt.sh"
		printf '*.log\n' >"${repo}/.gitignore"
		git -C "${repo}" add -A
		git -C "${repo}" commit -q -m 'the project'
	fi
	repo_main=$(sh "${K}/dev-base/scripts/internal/repo-of.sh" --dir "${repo}" | jq -r '.repo')
}

# The agents of batch $1, one per line: CELL TAG TYPE PROMPT.
batch_agents() {
	for c in "${RUN}"/cells/*/; do
		c=${c%/}
		[ "$(cat "${c}/batch")" = "$1" ] || continue
		for p in "${c}"/*.prompt; do
			tag=${p##*/}; tag=${tag%.prompt}
			printf '%s %s %s %s\n' "${c##*/}" "${tag}" "$(agent_type_of "$(cut -d' ' -f3 "${c}/cell")")" "$(cat "${p}")"
		done
	done
}

main_prompt() {
	case $1 in
		b-hot)
			n=$(batch_agents "$1" | grep -c ' j1 ')
			printf 'Start these %s agents with the Agent tool, all in one message, each in the background (run_in_background: true), with description "matrix job", each with the subagent_type and exactly the prompt given (the text after "prompt:" on its line):\n' "${n}"
			batch_agents "$1" | awk '$2 == "j1" { t = $3; $1 = $2 = $3 = ""; sub(/^ +/, ""); printf "- subagent_type %s, prompt: %s\n", t, $0 }'
			printf '\nEach time one of them finishes this first task, send that same agent, with the SendMessage tool (load it with ToolSearch first if you need to), addressed to its agent id, exactly the message given below for its cell (the CELL in its prompt). Send each message once only, and only after that agent finished its first task:\n'
			batch_agents "$1" | awk '$2 == "j2" { c = $1; $1 = $2 = $3 = ""; sub(/^ +/, ""); printf "- for CELL %s: %s\n", c, $0 }'
			printf '\nThen wait until each has finished its second task; you will be notified. Do nothing else: do not read, write or run anything yourself. When all are done, reply with one line: DONE.\n' ;;
		b-s12-*)
			batch_agents "$1" >"${RUN}/agents-$1"
			pa=$(awk '$2 == "a" { $1 = $2 = $3 = ""; sub(/^ +/, ""); print }' "${RUN}/agents-$1")
			pb=$(awk '$2 == "b" { $1 = $2 = $3 = ""; sub(/^ +/, ""); print }' "${RUN}/agents-$1")
			pc=$(awk '$2 == "c1" { $1 = $2 = $3 = ""; sub(/^ +/, ""); print }' "${RUN}/agents-$1")
			pd=$(awk '$2 == "c2" { $1 = $2 = $3 = ""; sub(/^ +/, ""); print }' "${RUN}/agents-$1")
			t=$(awk '$2 == "a" { print $3 }' "${RUN}/agents-$1")
			cat <<EOF
Do exactly these steps, nothing else. Never read, write or run anything yourself.

Step 1. In one message, start three agents with the Agent tool, each in the background (run_in_background: true), each with subagent_type "${t}", description "matrix job", and exactly the prompt given:
- agent A, prompt: ${pa}
- agent B, prompt: ${pb}
- agent C, prompt: ${pc}

Step 2. As soon as all three have started, stop agent A with the TaskStop tool (load it with ToolSearch first if you need to), giving A's agent id as the task id. Then end your turn with the one line: WAITING.

Step 3. When you are notified that agent C has finished, send agent C, with the SendMessage tool (load it with ToolSearch first if you need to), addressed to C's agent id, exactly this message: ${pd}
Then end your turn with the one line: SENT.

Step 4. When agent B has finished and agent C has finished its second task, reply with the one line: DONE. Whenever you are notified of anything else, end your turn with the one line: WAITING.
EOF
			;;
		*)
			n=$(batch_agents "$1" | wc -l | tr -d ' ')
			printf 'Start these %s agents with the Agent tool, all in one message, each in the background (run_in_background: true), with description "matrix job", each with the subagent_type and exactly the prompt given (the text after "prompt:" on its line):\n' "${n}"
			batch_agents "$1" | awk '{ t = $3; $1 = $2 = $3 = ""; sub(/^ +/, ""); printf "- subagent_type %s, prompt: %s\n", t, $0 }'
			printf '\nThen wait until every one of them has finished; you will be notified as each finishes. Do nothing else: do not read, write or run anything yourself, and send them no messages. When all have finished, reply with one line: DONE.\n' ;;
	esac
}

setup() {
	shift 2 2>/dev/null || shift $#
	[ -n "${RUN_SUFFIX:-}" ] || unlink_skills
	rm -rf -- "${RUN:?}"
	mkdir -p "${RUN}/cells" "${RUN}/sessions" "${K}" "${SB}/lab"
	cp "${EV}/lab/capture.sh" "${EV}/lab/assign-job.sh" "${EV}/lab/observe.sh" "${SB}/lab/"
	sh "${R}/framework/core/install/install-entries.sh" | sed -n '/^# Links/,/^$/p' | sed '1d' | grep -v '/CLAUDE.md' >"${RUN}/links.sh"
	[ -n "${RUN_SUFFIX:-}" ] || sh "${RUN}/links.sh"
	sh "${R}/framework/core/install/install-entries.sh" | sed -n '/^# Settings/,/^$/p' | sed '1d' >"${RUN}/entries-settings.json"
	cells_all >"${RUN}/cells.txt"
	while read -r cell sc kk batch; do
		if [ $# -gt 0 ]; then
			keep=''; for want in "$@"; do [ "${want}" != "${sc}" ] && [ "${want}" != "${cell}" ] || keep=1; done
			[ -n "${keep}" ] || continue
		fi
		make_repo "${batch}"
		make_cell "${cell}" "${sc}" "${kk}" </dev/null || { echo "setup: cell ${cell} failed" >&2; exit 1; }
		printf '%s ' "${cell}"
	done <"${RUN}/cells.txt"
	echo
	# S5b: the working commit fails, a lock left in each live tree's index.
	for c in "${RUN}"/cells/S5b-*/; do
		[ -d "${c}" ] || continue
		e=$(cat "${c}/effort")
		g=$(git -C "${e}/worktrees/j" rev-parse --absolute-git-dir)
		: >"${g}/index.lock"
		printf '%s\n' "${g}/index.lock" >"${c}/lock"
	done
	for b in $(cat "${RUN}"/cells/*/batch | sort -u); do session "${b}"; done
	b1=$(ls "${RUN}/sessions" | head -n 1)
	# The check reads the project's settings and the --settings file.
	(cd "${RUN}/repos/${b1}" && sh "${R}/framework/core/install/install-check.sh" --settings .claude/settings.json --settings "${RUN}/sessions/${b1}/flag-settings.json") >"${RUN}/install-check.out" 2>&1 || true
	claude --version >"${RUN}/claude-version.txt"
	framework_hash >"${RUN}/framework-at-setup.txt"
	ls "${RUN}/sessions"
}

# run_batch BATCH LIMIT: headless main in permission mode default, the
# allow-list by --settings; killed by PID past LIMIT seconds.
run_batch() {
	sdir="${RUN}/sessions/$1"
	(
		cd "${RUN}/repos/$1"
		exec env -u CLAUDECODE -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_ENTRYPOINT \
			claude -p "$(cat "${sdir}/main-prompt.txt")" --permission-mode default --settings "${sdir}/flag-settings.json" \
			--model sonnet --output-format stream-json --verbose --debug-file "${sdir}/debug.txt" \
			</dev/null >"${sdir}/main.jsonl" 2>"${sdir}/main.err"
	) &
	pid=$!
	echo "${pid}" >"${sdir}/main.pid"
	t=0 lim=${2:-1200}
	while kill -0 "${pid}" 2>/dev/null && [ "${t}" -lt "${lim}" ]; do sleep 5; t=$((t + 5)); done
	if kill -0 "${pid}" 2>/dev/null; then echo "main killed by run.sh after ${lim}s" >>"${sdir}/main.err"; kill "${pid}"; fi
	rc=0; wait "${pid}" || rc=$?
	printf 'main exit %s after %ss\n' "${rc}" "${t}" >>"${sdir}/main.err"
	rm -f "${sdir}/main.pid"
}

waves() {
	n=${3:-3}
	set -- $(ls "${RUN}/sessions" | grep -v '^b-s5a$' || true)
	while [ $# -gt 0 ]; do
		pids=''
		i=0
		while [ $# -gt 0 ] && [ "${i}" -lt "${n}" ]; do
			echo "$(date +%T) batch $1"
			run_batch "$1" 1200 &
			pids="${pids} $!"; i=$((i + 1)); shift
		done
		for p in ${pids}; do wait "${p}" || true; done
	done
	[ ! -d "${RUN}/sessions/b-s5a" ] || s5a
	post
}

# S5a alone: each agent type's rules file removed from its installed
# component (a copy in place of the link), restored after.
s5a() {
	swap() { # swap COMPONENT FILE
		target=$(readlink "${K}/$1")
		printf '%s\n' "${target}" >"${RUN}/s5a-$1.target"
		rm -- "${K:?}/$1"; cp -RL "${target}" "${K}/$1"; rm -- "${K:?}/$1/$2"
	}
	restore() {
		[ -L "${K}/$1" ] || { [ -d "${K}/$1" ] && rm -rf -- "${K:?}/${1:?}"; ln -s "$(cat "${RUN}/s5a-$1.target")" "${K}/$1"; }
	}
	swap code-builder scripts/lib/build-report.jq
	swap code-tester scripts/lib/test-plan-report.jq
	swap code-reviewer scripts/lib/review-report.jq
	echo "$(date +%T) batch b-s5a"
	run_batch b-s5a 900 || true
	for c in code-builder code-tester code-reviewer; do restore "${c}"; done
}

post() {
	for c in "${RUN}"/cells/S5b-*/; do
		[ -d "${c}" ] || continue
		cell=${c%/}; cell=${cell##*/}
		e=$(cat "${c}/effort")
		rm -f -- "$(cat "${c}/lock")"
		j=$(awk '{ print $2 }' "${c}/jobs" | head -n 1)
		how=--finish; case ${cell} in *giveup) how=--give-up ;; esac
		rc=0
		CLAUDE_CODE_SESSION_ID=sess-matrix-recover sh "${K}/agent-submission/scripts/main/recover-submission.sh" \
			--effort "${e}" --job "${j}" "${how}" >"${c}/recover.out" 2>"${c}/recover.err" || rc=$?
		echo "exit ${rc}" >>"${c}/recover.out"
		echo "post ${cell}: recover-submission.sh ${how} exit ${rc}"
	done
}

collect() {
	out="${EV}/logs"; [ "${mode}" = real ] || out="${EV}/logs/control"
	mkdir -p "${out}"
	for c in "${RUN}"/cells/*/; do
		c=${c%/}; cell=${c##*/}
		d="${out}/${cell}"
		rm -rf -- "${d:?}"; mkdir -p "${d}/hooks"
		e=$(cat "${c}/effort")
		sh "${ER}" --effort "${e}" >"${d}/events.json"
		cp -Rp "${e}/reports" "${d}/reports" 2>/dev/null || mkdir -p "${d}/reports"
		cp -p "${c}/cell" "${c}/jobs" "${c}"/*.recipe "${c}"/*.prompt "${d}/" 2>/dev/null || true
		cp -p "${c}"/recover.* "${d}/" 2>/dev/null || true
		rp=$(cat "${c}/repo")
		{ printf '== repo %s\n' "${rp}"; git -C "${rp}" status --porcelain; } >"${d}/git.txt" 2>&1
		for t in "${e}"/worktrees/*/; do
			t=${t%/}
			[ -d "${t}" ] || continue
			{ printf '== tree %s\n' "${t}"; git -C "${t}" log --format='commit %H%n%B%n.' --name-only main..HEAD; printf '== status\n'; git -C "${t}" status --porcelain; } >>"${d}/git.txt" 2>&1
		done
		# The hook calls of this cell's agents (by job.assigned), of its
		# agents with no job (by the prompt the Agent tool was given), and
		# main's turn ends that list one of them as running.
		b=$(cat "${c}/batch")
		idx="${RUN}/sessions/${b}/hooks.idx"
		[ -f "${idx}" ] || find "${RUN}/sessions/${b}/hooks" -name '*.json' -type f -exec jq -r '[input_filename, (.input.agent_id // "-"),
			((.input.background_tasks // []) | map(.id) | join(",") | if . == "" then "-" else . end),
			(((.input.tool_input.prompt // .input.tool_input.message // "") | capture("CELL: (?<c>[A-Za-z0-9-]+)\\.").c) // "-"),
			(.input.tool_response.agentId // "-")] | @tsv' {} + >"${idx}" 2>/dev/null || true
		agents=$( { jq -r '.[] | select(.type == "job.assigned") | .body.agent' "${d}/events.json"; awk -F'\t' -v c="${cell}" '$4 == c && $5 != "-" { print $5 }' "${idx}"; } | sort -u | tr '\n' ' ')
		awk -F'\t' -v c="${cell}" -v list="${agents}" 'BEGIN { n = split(list, a, " "); for (i = 1; i <= n; i++) want[a[i]] = 1 }
			{ hit = ($4 == c) || ($2 in want); if ($2 == "-") { m = split($3, bg, ","); for (i = 1; i <= m; i++) if (bg[i] in want) hit = 1 }; if (hit) print $1 }' "${idx}" \
			| while read -r f; do cp -p "${f}" "${d}/hooks/"; done
		printf '%s\n' "${b}" >"${d}/batch"
	done
	for s in "${RUN}"/sessions/*/; do
		s=${s%/}; d="${out}/_sessions/${s##*/}${RUN_SUFFIX:-}"
		rm -rf -- "${d:?}"; mkdir -p "${d}"
		cp -p "${s}"/main.jsonl "${s}"/main.err "${s}"/main-prompt.txt "${s}"/flag-settings.json "${d}/" 2>/dev/null || true
		cp -p "${RUN}/repos/${s##*/}/.claude/settings.json" "${d}/settings.json"
		cp -Rp "${s}/hooks" "${d}/hooks"
		[ ! -f "${s}/debug.txt" ] || grep -E 'agent_completion|Reached max turns|permission|denied|timed out|Hooks:' "${s}/debug.txt" >"${d}/debug-excerpt.txt" || true
	done
	cp -p "${RUN}/install-check.out" "${RUN}/claude-version.txt" "${RUN}/cells.txt" "${out}/" 2>/dev/null || true
	{ printf 'at setup:   %s\n' "$(cat "${RUN}/framework-at-setup.txt" 2>/dev/null)"; printf 'at collect: %s\n' "$(framework_hash)"; } >"${out}/framework-hash.txt"
	echo "collected into ${out}"
}

case ${1-} in
	setup) setup "$@" ;;
	batch) run_batch "$3" "${4:-1200}" ;;
	waves) waves "$@" ;;
	s5a) s5a ;;
	post) post ;;
	collect) collect ;;
	all) setup "$@"; waves "$1" "${mode}"; collect
		if [ "${mode}" = real ]; then sh "${EV}/score.sh" real | tee "${EV}/score.txt"; else sh "${EV}/score.sh" control | tee "${EV}/control-score.txt"; fi ;;
	unlink) unlink_skills ;;
	*) sed -n '2,18p' "$0" >&2; exit 2 ;;
esac
