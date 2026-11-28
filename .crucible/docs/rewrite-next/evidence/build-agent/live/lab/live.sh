#!/bin/sh
# Sandbox live run of the build agent's stop hook: a build, then a build-fix
# on it, each run by a real sub-agent that main starts.
#   live.sh setup    install into the sandbox config; make the repo, tree,
#                    effort, identity fixture and the build's job.dispatched
#   live.sh fix      the build-fix's job.dispatched, after the build
#   live.sh collect  gather the evidence and score the run
#   live.sh unlink   remove the skill links setup made
set -eu
R=/Users/cordona/IdeaProjects/cordona/claude-code-crucible/new-rewrite
L=/Users/Shared/crucible-sandbox/build-agent-live
LAB="${L}/lab"
RUN="${L}/run"
export CLAUDE_CONFIG_DIR=/Users/Shared/crucible-sandbox/event-jobs/cfg
export CRUCIBLE_HOME="${RUN}/space"
K="${CLAUDE_CONFIG_DIR}/skills"
EW="${K}/crucible-events/scripts/internal/event-write.sh"
ER="${K}/crucible-events/scripts/internal/events-read.sh"
SETUP='{"language": "php", "standards": ["security", "observability"]}'

# Skill links that point into new-rewrite, by name.
links() { sh "${R}/framework/core/install/install-entries.sh" --json | jq -r '.skills[].name'; }

unlink_skills() {
	for name in $(links); do
		[ ! -L "${K:?}/${name:?}" ] || rm -- "${K:?}/${name:?}"
	done
}

# dispatch KIND EXTRA_JSON: the job's job.dispatched; writes the main prompt
# for it and sets seq.
dispatch() {
	seq=$(($(sh "${ER}" --effort "${effort}" --paths | wc -l) + 1))
	jq -n --arg kind "$1" --arg tree "${tree}" --arg report "reports/$1/${seq}.json" --argjson extra "$2" --argjson setup "${SETUP}" '
		{kind: $kind, agent_type: "code-builder", tree: $tree, report: $report} + ($extra | del(.fix_round))
		+ {known_failures: [], iteration: 1} + ($extra | with_entries(select(.key == "fix_round"))) + {setup: $setup}' >"${RUN}/dispatched.json"
	sh "${EW}" --effort "${effort}" --type job.dispatched --by job-dispatch.sh --body-file "${RUN}/dispatched.json" >/dev/null
	prompt="JOB: ${seq}. KIND: $1. TREE: ${tree}. REPORT: ${effort}/reports/$1/${seq}.json$3"
	awk -v p="${prompt}" '{ gsub("@PROMPT@", p); print }' "${LAB}/main-prompt.txt" >"${RUN}/main-prompt-$1.txt"
}

setup() {
	unlink_skills
	rm -rf -- "${RUN:?}"
	mkdir -p "${RUN}/logs" "${K}"
	# The skill links from install-entries.sh's own output; its CLAUDE.md
	# link is left out: this config is shared with other sandbox runs.
	sh "${R}/framework/core/install/install-entries.sh" | sed -n '/^# Links/,/^$/p' | sed '1d' | grep -v '/CLAUDE.md' >"${RUN}/links.sh"
	sh "${RUN}/links.sh"
	repo="${RUN}/repo"
	git init -q -b main "${repo}"
	mkdir -p "${repo}/app/Upload" "${repo}/.claude/agents"
	awk 'BEGIN { for (i = 1; i <= 88; i++) printf "// Client.php line %d\n", i }' >"${repo}/app/Upload/Client.php"
	cp "${LAB}/code-builder.md" "${repo}/.claude/agents/code-builder.md"
	sh "${R}/framework/core/install/install-entries.sh" | sed -n '/^# Settings/,/^$/p' | sed '1d' >"${RUN}/entries-settings.json"
	git -C "${repo}" add -A
	git -C "${repo}" -c user.name=Fixture -c user.email=fixture@example.test commit -q -m 'the project'
	effort=$(sh "${K}/crucible-effort/scripts/main/effort-start.sh" --name 'live build agent')
	repo_main=$(sh "${K}/dev-base/scripts/internal/repo-of.sh" --dir "${repo}" | jq -r '.repo')
	jq -n --arg repo "${repo_main}" '{repo: $repo, name: "Build Agent", email: "build-agent@example.test",
		signing: {format: "ssh", key: "/nonexistent/fixture-key.pub"}, fingerprint: "", answer: 1}' >"${RUN}/identity.json"
	sh "${EW}" --effort "${effort}" --type identity.set --by identity-set.sh --body-file "${RUN}/identity.json" >/dev/null
	sh "${K}/git-worktree/scripts/main/worktree-cut.sh" --effort "${effort}" --repo "${repo}" --name upload --from checkout >/dev/null
	tree="${effort}/worktrees/upload"
	dispatch build '{}' ''
	# The project settings: install-entries.sh's entries, the sandbox's
	# job.assigned hook, and the env the hooks read.
	jq --arg live "${RUN}" --arg effort "${effort}" --arg space "${CRUCIBLE_HOME}" --arg hook "sh '${LAB}/assign-job.sh'" '
		.env = {LIVE: $live, LIVE_EFFORT: $effort, CRUCIBLE_HOME: $space}
		| .hooks.PostToolUse += [{matcher: "Agent", hooks: [{type: "command", command: $hook}]}]' \
		"${RUN}/entries-settings.json" >"${repo}/.claude/settings.json"
	printf 'effort=%s\ntree=%s\nbuild=%s\nrepo=%s\n' "${effort}" "${tree}" "${seq}" "${repo}" >"${RUN}/vars"
	(cd "${repo}" && sh "${R}/framework/core/install/install-check.sh" --settings "${repo}/.claude/settings.json") >"${RUN}/install-check.out" 2>&1 || true
	cat "${RUN}/install-check.out" "${RUN}/vars"
}

fix() {
	. "${RUN}/vars"
	dispatch build-fix '{"findings": ["REVIEW-01"], "fix_round": 1}' '. FINDING: REVIEW-01, a 4xx is retried.'
	printf 'fix=%s\n' "${seq}" >>"${RUN}/vars"
	cat "${RUN}/vars"
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
	ev=$(jq -c --arg t "$1.submitted" --argjson j "$2" '[.[] | select(.type == $t and .body.job == $j)] | last // "none"' "${out}/events.json")
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
	jq '[.[] | select((.type | startswith("job.")) or (.body.report | type) == "object")]' "${out}/events.json" >"${out}/job-events.json"
	cp -- "${RUN}/logs/"* "${out}/" 2>/dev/null || true
	cp -- "${RUN}/install-check.out" "${RUN}"/main-prompt-*.txt "${out}/"
	cp -- "${RUN}/repo/.claude/settings.json" "${out}/project-settings.json"
	ls "${effort}/stops" >"${out}/stops.txt" 2>&1 || true
	pass=0 fail=0
	sum() { sh "${K}/agent-jobs/scripts/internal/report-hash.sh" --report "$1"; }

	kind_evidence build "${build}"
	check 'build: job.assigned written for the agent the Agent tool started' test -n "${agent}"
	check 'build: first stop held with the summary repair line' grep -qF 'summary is 61 characters; shorten it to 55 or fewer' "${out}/build/first-hook-output.txt"
	check 'build: one refusal counted' sh -c '[ "$(cat "$1/stops/$2.held")" = 1 ]' _ "${effort}" "${build}"
	check 'build: second stop accepted, build.submitted by submission-event.sh for its agent' sh -c 'printf "%s" "$1" | jq -e --arg a "$2" ".by == \"submission-event.sh\" and .body.agent == \$a"' _ "${ev}" "${agent}"
	check 'build: report {path, sha256} at reports/build/<seq>.json matches the file' sh -c 'printf "%s" "$1" | jq -e --arg p "$2" --arg s "$3" ".body.report == {path: \$p, sha256: \$s}"' _ "${ev}" "reports/build/${build}.json" "$(sum "${report}")"
	check 'build: the report is read-only and its summary fits' sh -c '[ -n "$(find "$1" -prune -perm 0444)" ] && [ "$(jq -r ".summary | length" "$1")" -le 55 ]' _ "${report}"
	check 'build: the commit, crucible(build), Effort, Job, Iteration, Language, Standards' sh -c '[ "$(git -C "$1" log -1 --format=%B "$2" | sed 1,2d)" = "$3" ] && git -C "$1" log -1 --format=%s "$2" | grep -q "^crucible(build): "' _ "${tree}" "${commit}" "Effort: ${effort##*/}
Job: ${build} ${name}
Iteration: 1
Language: php
Standards: security, observability"

	kind_evidence build-fix "${fix}"
	check 'build-fix: job.assigned written for its own agent' test -n "${agent}"
	check 'build-fix: accepted, build-fix.submitted with iteration 1 and fix round 1' sh -c 'printf "%s" "$1" | jq -e ".type == \"build-fix.submitted\" and .body.iteration == 1 and .body.fix_round == 1"' _ "${ev}"
	check 'build-fix: report {path, sha256} at reports/build-fix/<seq>.json matches the file' sh -c 'printf "%s" "$1" | jq -e --arg p "$2" --arg s "$3" ".body.report == {path: \$p, sha256: \$s}"' _ "${ev}" "reports/build-fix/${fix}.json" "$(sum "${report}")"
	check 'build-fix: the report fixes REVIEW-01 and is read-only' sh -c '[ -n "$(find "$1" -prune -perm 0444)" ] && jq -e ".fixes[0].status == \"done\" and .fixes[0].id == \"REVIEW-01\"" "$1"' _ "${report}"
	check 'build-fix: the commit is the tree'"'"'s HEAD, crucible(build-fix), with Fix-Round 1' sh -c '[ "$2" = "$(git -C "$1" rev-parse HEAD)" ] && git -C "$1" log -1 --format=%s "$2" | grep -q "^crucible(build-fix): " && git -C "$1" log -1 --format=%B "$2" | grep -qx "Fix-Round: 1"' _ "${tree}" "${commit}"
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
