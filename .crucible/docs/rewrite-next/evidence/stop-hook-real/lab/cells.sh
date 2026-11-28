# Sourced by run.sh. Step 4: one cell per run, <kind>-<n>, each its own
# effort and tree. The fixtures (earlier jobs) are real code and real reports,
# handed in through the real hook and event writer; the live job gets the
# real agent, and a prompt with only what the dispatch would give it.

SETUP='{"language": "shell", "standards": ["testing"]}'
FX="${EV}/fixtures"
PL="${R}/domains/software-development/plugins/tech/languages/shell"
ST="${R}/domains/software-development/core/plugins/standards"
KINDS='build build-fix test-plan test-plan-update test test-fix review re-review test-plan-challenge external-review foreign-review'

# The cells: CELL KIND BATCH.
cells_all() {
	for k in ${KINDS}; do
		for n in 1 2 3; do echo "${k}-${n} ${k} b-${k}"; done
	done
	echo "parked-build build b-parked"
	echo "parked-test test b-parked"
	echo "i-build build b-i"
	echo "i-review review b-i"
	echo "i-parked-build build b-i"
}

agent_type_of() {
	case $1 in
		build | build-fix) echo code-builder ;;
		test-plan | test-plan-update | test | test-fix) echo code-tester ;;
		*) echo code-reviewer ;;
	esac
}
job_kind_of() { case $1 in re-review) echo review ;; *) echo "$1" ;; esac; }

next_seq() { echo $(($(sh "${ER}" --effort "${effort}" --paths | wc -l) + 1)); }

# job KIND TREE AGENT NAME EXTRA_JSON: job.dispatched with the tree's
# iteration, and job.assigned for a fixture agent; sets seq.
job() {
	seq=$(next_seq)
	sh "${ER}" --effort "${effort}" >"${cdir}/all.json"
	jq -n --arg kind "$1" --arg type "$(agent_type_of "$1")" --arg tree "$2" --arg report "reports/$1/${seq}.json" \
		--argjson extra "$5" --argjson setup "${SETUP}" --slurpfile all "${cdir}/all.json" '
		([$all[0][] | select(.type == "job.dispatched" and .body.kind == "build" and .body.tree == $tree) | .body.iteration] | max) as $now
		| {kind: $kind, agent_type: $type, tree: $tree, report: $report} + ($extra | del(.fix_round)) + {known_failures: []}
		+ (if $kind == "build" then {iteration: (($now // 0) + 1)} elif $now == null then {} else {iteration: $now} end)
		+ ($extra | with_entries(select(.key == "fix_round"))) + {setup: $setup}' >"${cdir}/dispatched-${seq}.json"
	sh "${EW}" --effort "${effort}" --type job.dispatched --by job-dispatch.sh --body-file "${cdir}/dispatched-${seq}.json" >/dev/null
	[ -n "$3" ] || return 0
	jq -n --argjson job "${seq}" --arg agent "$3" --arg name "$4" '{job: $job, agent: $agent, name: $name, session: "sess-real-fixture"}' >"${cdir}/assigned.json"
	CLAUDE_CODE_SESSION_ID=sess-real-fixture sh "${EW}" --effort "${effort}" --type job.assigned --by assign-job.sh --body-file "${cdir}/assigned.json" >/dev/null
}

# A fixture agent's stop, hand-fed to the real hook: agent $1 hands in the
# report file $2 at the job's report path $3. The hook must accept it.
fixture_stop() {
	mkdir -p "${3%/*}"; cp "$2" "$3"
	out=$(jq -cn --arg a "$1" '{session_id: "sess-real-fixture", hook_event_name: "SubagentStop", agent_id: $a}' | sh "${HOOK}")
	[ -z "${out}" ] || { echo "fixture stop of $1 in ${cell} said: ${out}" >&2; return 1; }
}
fid() { fixn=$((fixn + 1)); a="fx$(printf '%s' "${RUN}/${cell}" | shasum | cut -c1-10)n${fixn}"; }
pinned() { printf '%s/reports/%s/%s.json' "${effort}" "$1" "$2"; }

# The fixtures, on tree $1.
fx_build() { # fx_build TREE VARIANT: a build of f-bug or f-ok; sets base, head
	fid; job build "$1" "${a}" "build-shell-${a}" '{}'
	base=$(git -C "$1" rev-parse HEAD)
	cp "${FX}/$2/bin/prune-backups.sh" "$1/bin/prune-backups.sh"
	fixture_stop "${a}" "${FX}/reports/build.json" "$(pinned build "${seq}")"
	head=$(git -C "$1" rev-parse HEAD)
}
fx_review() { # the shell review of base..head; sets review (its seq)
	fid; job review "$1" "${a}" "review-shell-${a}" "{\"lens\": \"shell\", \"base\": \"${base}\", \"head\": \"${head}\"}"
	fixture_stop "${a}" "${FX}/reports/review.json" "$(pinned review "${seq}")"
	review=${seq}
}
fx_buildfix() { # the fix of all three findings; sets fixhead, fix (its seq)
	fid; job build-fix "$1" "${a}" "build-fix-shell-${a}" '{"findings": ["SHELL-01", "SHELL-02", "SHELL-03"], "fix_round": 1}'
	cp "${FX}/bf/bin/prune-backups.sh" "$1/bin/prune-backups.sh"
	fixture_stop "${a}" "${FX}/reports/build-fix.json" "$(pinned build-fix "${seq}")"
	fixhead=$(git -C "$1" rev-parse HEAD); fix=${seq}
}
fx_plan() { # the plan, approved by the human; sets plan (its seq)
	fid; job test-plan "$1" "${a}" "test-plan-shell-${a}" '{}'
	fixture_stop "${a}" "${FX}/reports/plan.json" "$(pinned test-plan "${seq}")"
	plan=$(sh "${ER}" --effort "${effort}" --type test-plan.submitted | jq -r "last.seq")
	planjob=${seq}
	jq -n --arg seq "${plan}" '{record: "test-plan", subject: $seq, question: "Approve the test plan?",
		accept: "Approve (Recommended)", answer: "Approve (Recommended)", accepted: true}' >"${cdir}/answer.json"
	CLAUDE_CODE_SESSION_ID=sess-real-fixture sh "${EW}" --effort "${effort}" --type gate.answered --by record-gate-answer.sh --body-file "${cdir}/answer.json" >/dev/null
}
fx_challenge() { # the plan's challenge; sets challenge (its seq)
	fid; job test-plan-challenge "$1" "${a}" "test-plan-challenge-testing-${a}" "{\"lens\": \"testing\", \"plan\": ${plan}}"
	fixture_stop "${a}" "${FX}/reports/challenge.json" "$(pinned test-plan-challenge "${seq}")"
	challenge=${seq}
}
fx_tests() { # the approved plan's tests, written weak; sets testbase, testhead
	fid; job test "$1" "${a}" "test-shell-${a}" "{\"plan\": ${plan}}"
	testbase=$(git -C "$1" rev-parse HEAD)
	cp "${FX}/tests-weak/tests/test_prune.sh" "$1/tests/test_prune.sh"
	fixture_stop "${a}" "${FX}/reports/tests.json" "$(pinned test "${seq}")"
	testhead=$(git -C "$1" rev-parse HEAD)
}
fx_test_review() { # the testing review of the tests; sets treview (its seq)
	fid; job review "$1" "${a}" "review-testing-${a}" "{\"lens\": \"testing\", \"base\": \"${testbase}\", \"head\": \"${testhead}\"}"
	fixture_stop "${a}" "${FX}/reports/test-review.json" "$(pinned review "${seq}")"
	treview=${seq}
}

new_tree() {
	sh "${K}/git-worktree/scripts/main/worktree-cut.sh" --effort "${effort}" --repo "${repo}" --name "$1" --from checkout >/dev/null
	tree="${effort}/worktrees/$1"
}
# fixture_commit TREE MESSAGE: someone's commit in the tree (the project's
# own history, or a foreign MR), outside any job.
fixture_commit() {
	git -C "$1" add -A
	git -C "$1" -c user.name='Erin Example' -c user.email=erin@example.test -c commit.gpgsign=false commit -q -m "$2"
}

# body FILE: a plugin's text, its frontmatter dropped.
body() { awk 'NR == 1 && /^---$/ { fm = 1; next } fm && /^---$/ { fm = 0; next } !fm' "$1"; }
plugins() {
	printf '\n## Plugins for this job\n'
	for f in "$@"; do printf '\n'; body "${f}"; done
}
# fill TASK KEY VALUE...: the task text with each @KEY@ replaced by VALUE;
# for FINDINGS, CHALLENGES and FIXES, VALUE is a file and its contents go in.
fill() {
	tf="${FX}/tasks/$1.txt"
	shift
	out=$(cat "${tf}")
	while [ $# -gt 1 ]; do
		v=$2
		case $1 in FINDINGS | CHALLENGES | FIXES) v=$(cat "${v}") ;; *) ;; esac
		out=$(printf '%s' "${out}" | KEYN="$1" KEYV="${v}" perl -0pe 's/\@\Q$ENV{KEYN}\E\@/$ENV{KEYV}/g')
		shift 2
	done
	printf '%s\n' "${out}"
}

# make_cell CELL KIND: the cell's effort, tree, fixtures, live job and prompt.
make_cell() {
	cell=$1 kk=$2 fixn=0 base='' head=''
	cdir="${RUN}/cells/${cell}"
	mkdir -p "${cdir}"
	printf '%s %s\n' "${cell}" "${kk}" >"${cdir}/cell"
	effort=$(sh "${K}/crucible-effort/scripts/main/effort-start.sh" --name "real ${cell}")
	printf '%s\n' "${effort}" >"${cdir}/effort"
	jq -n --arg repo "${repo_main}" '{repo: $repo, name: "Real Agent", email: "real-agent@example.test",
		signing: {format: "ssh", key: "/nonexistent/fixture-key.pub"}, fingerprint: "", answer: 1}' >"${cdir}/identity.json"
	CLAUDE_CODE_SESSION_ID=sess-real-fixture sh "${EW}" --effort "${effort}" --type identity.set --by identity-set.sh --body-file "${cdir}/identity.json" >/dev/null
	new_tree j; t=${tree}
	case ${cell} in *parked-*)
		cp "${FX}/slow/tests/test_slow.sh" "${t}/tests/test_slow.sh"
		fixture_commit "${t}" 'tests: add the nightly soak test' ;;
	esac
	builder="${PL}/SKILL.md ${PL}/references/build.md"
	tester="${PL}/SKILL.md ${ST}/testing/SKILL.md"
	shell_lens="${PL}/SKILL.md ${PL}/references/review.md"
	test_lens="${ST}/testing/SKILL.md ${ST}/testing/references/review.md"
	case ${kk} in
		build)
			job build "${t}" '' '' '{}'
			fill build >"${cdir}/task.txt"; pl=${builder} ;;
		build-fix)
			fx_build "${t}" f-bug; fx_review "${t}"
			jq '[.findings[] | {id, severity, realism, at, relates_to, claim, suggestion} | with_entries(select(.value != null))]' "$(pinned review "${review}")" >"${cdir}/chosen.json"
			job build-fix "${t}" '' '' "{\"findings\": $(jq -c '[.[].id]' "${cdir}/chosen.json"), \"fix_round\": 1}"
			fill build-fix BASE "${base}" HEAD "${head}" FINDINGS "${cdir}/chosen.json" >"${cdir}/task.txt"; pl=${builder} ;;
		test-plan)
			fx_build "${t}" f-ok
			job test-plan "${t}" '' '' '{}'
			fill test-plan BASE "${base}" HEAD "${head}" >"${cdir}/task.txt"; pl=${tester} ;;
		test-plan-update)
			fx_build "${t}" f-ok; fx_plan "${t}"; fx_challenge "${t}"
			jq '[.challenges[] | {id, target, ask, title, why}]' "$(pinned test-plan-challenge "${challenge}")" >"${cdir}/challenges.json"
			job test-plan-update "${t}" '' '' "{\"plan\": ${plan}, \"challenges\": $(jq -c . "${cdir}/challenges.json")}"
			fill test-plan-update PLAN "$(pinned test-plan "${planjob}")" BASE "${base}" HEAD "${head}" CHALLENGES "${cdir}/challenges.json" >"${cdir}/task.txt"; pl=${tester} ;;
		test)
			fx_build "${t}" f-ok; fx_plan "${t}"
			job test "${t}" '' '' "{\"plan\": ${plan}}"
			fill test PLAN "$(pinned test-plan "${planjob}")" BASE "${base}" HEAD "${head}" >"${cdir}/task.txt"; pl=${tester} ;;
		test-fix)
			fx_build "${t}" f-ok; fx_plan "${t}"; fx_tests "${t}"; fx_test_review "${t}"
			jq '[.findings[] | {id, severity, realism, at, relates_to, claim, suggestion} | with_entries(select(.value != null))]' "$(pinned review "${treview}")" >"${cdir}/chosen.json"
			job test-fix "${t}" '' '' "{\"findings\": $(jq -c '[.[].id]' "${cdir}/chosen.json"), \"plan\": ${plan}, \"fix_round\": 1}"
			fill test-fix BASE "${testbase}" HEAD "${testhead}" PLAN "$(pinned test-plan "${planjob}")" FINDINGS "${cdir}/chosen.json" >"${cdir}/task.txt"; pl=${tester} ;;
		review)
			fx_build "${t}" f-bug
			job review "${t}" '' '' "{\"lens\": \"shell\", \"base\": \"${base}\", \"head\": \"${head}\"}"
			fill review BASE "${base}" HEAD "${head}" >"${cdir}/task.txt"; pl=${shell_lens} ;;
		re-review)
			fx_build "${t}" f-bug; fx_review "${t}"; fx_buildfix "${t}"
			jq '.fixes' "$(pinned build-fix "${fix}")" >"${cdir}/earlier.json"
			jq -s '.[0].findings as $f | [.[1][] | . as $x | ($f[] | select(.id == $x.id) | {id, severity, claim, at, suggestion}) + {fixer: ($x | del(.id))}]' \
				"$(pinned review "${review}")" "${cdir}/earlier.json" >"${cdir}/fixes.json"
			job review "${t}" '' '' "{\"lens\": \"shell\", \"base\": \"${head}\", \"head\": \"${fixhead}\", \"earlier\": $(jq -c . "${cdir}/earlier.json"), \"fix_round\": 1}"
			fill re-review BASE "${head}" HEAD "${fixhead}" EARLIER "$(pinned review "${review}")" FIXES "${cdir}/fixes.json" >"${cdir}/task.txt"; pl=${shell_lens} ;;
		test-plan-challenge)
			fx_build "${t}" f-ok; fx_plan "${t}"
			job test-plan-challenge "${t}" '' '' "{\"lens\": \"testing\", \"plan\": ${plan}}"
			fill test-plan-challenge PLAN "$(pinned test-plan "${planjob}")" BASE "${base}" HEAD "${head}" >"${cdir}/task.txt"; pl=${test_lens} ;;
		external-review)
			fx_build "${t}" f-bug
			# The fetched threads, in the effort, where the remote's fetch puts them.
			mkdir -p "${effort}/threads"; cp "${FX}/threads.json" "${effort}/threads/fetch-1.json"; cp "${FX}/threads.json" "${cdir}/threads.json"
			job external-review "${t}" '' '' "{\"lens\": \"shell\", \"base\": \"${base}\", \"head\": \"${head}\", \"threads\": \"${effort}/threads/fetch-1.json\"}"
			fill external-review BASE "${base}" HEAD "${head}" THREADS "${effort}/threads/fetch-1.json" >"${cdir}/task.txt"; pl=${shell_lens} ;;
		foreign-review)
			base=$(git -C "${t}" rev-parse HEAD)
			cp "${FX}/foreign/bin/restore-backup.sh" "${t}/bin/restore-backup.sh"
			fixture_commit "${t}" 'Add restore-backup.sh'
			head=$(git -C "${t}" rev-parse HEAD)
			job foreign-review "${t}" '' '' "{\"lens\": \"shell\", \"foreign\": \"acme/logkeep!42\", \"base\": \"${base}\", \"head\": \"${head}\"}"
			fill foreign-review BASE "${base}" HEAD "${head}" >"${cdir}/task.txt"; pl=${shell_lens} ;;
	esac
	printf '%s\n' "${seq}" >"${cdir}/live-seq"
	report="${effort}/$(jq -r '.report' "${cdir}/dispatched-${seq}.json")"
	{
		cat "${cdir}/task.txt"
		printf '\nTree: %s\nReport: %s\n' "${t}" "${report}"
		# shellcheck disable=SC2086 # the plugin paths hold no space
		plugins ${pl}
	} >"${cdir}/prompt.txt"
	printf '%s\n' "${pl}" | tr ' ' '\n' >"${cdir}/plugins.txt"
	printf '%s\n' "${t}" >"${cdir}/tree"
	printf '%s\n' "${batch}" >"${cdir}/batch"
}
