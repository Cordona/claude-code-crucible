#!/usr/bin/env sh
# Evidence run for the job model's own events and scripts, through the
# installed layout: a scratch Claude folder linked with install-entries.sh's
# own commands, a scratch space and effort, the jobs written through the
# real event writer. It proves the job.* rules, main's Stop hook that ends
# the jobs whose agent is gone, and main's end-job.sh. Only scratch: its own
# HOME, no key. Exits 1 when any expectation fails.
# shellcheck disable=SC2016,SC2312 # single-quoted jq and sh -c are meant literally; a read inside a check is what the check compares
set -u
R=/Users/cordona/IdeaProjects/cordona/claude-code-crucible/new-rewrite
E=$(cd -- "$(dirname -- "$0")" && pwd)
S=$(mktemp -d "${TMPDIR:-/tmp}/agent-jobs.XXXXXX") || exit 2
S=$(cd -P -- "${S}" && pwd -P)
trap 'rm -rf -- "${S}"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "${S}/home" "${S}/cfg" "${S}/work"
export HOME="${S}/home" GIT_CONFIG_GLOBAL="${S}/home/.gitconfig" GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME="${S}/home/.config"
export CRUCIBLE_HOME="${S}/space" CLAUDE_CONFIG_DIR="${S}/cfg" CLAUDE_CODE_SESSION_ID=sess-main
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
GONE="${K}/agent-jobs/hooks/stop/end-gone-jobs.sh"
END_JOB="${K}/agent-jobs/scripts/main/end-job.sh"

echo "=== install: install-entries.sh's own links and settings"
sh "${R}/framework/core/install/install-entries.sh" | sed -n '/^# Links/,/^$/p' | sed '1d' >"${S}/links.sh"
sh "${R}/framework/core/install/install-entries.sh" | sed -n '/^# Settings/,/^$/p' | sed '1d' >"${S}/settings.json"
sh "${S}/links.sh"
check 'main'"'"'s Stop hook end-gone-jobs.sh is registered' jq -e 'any(.hooks.Stop[].hooks[]; .command | endswith("/skills/agent-jobs/hooks/stop/end-gone-jobs.sh'"'"'"))' "${S}/settings.json"
for script in "${JOB_OF}" "${K}/agent-jobs/scripts/internal/agent-had-job.sh" "${GONE}" "${END_JOB}"; do
	out=$(sh "${script}" --help 2>&1); rc=$?
	check "${script##*/} --help" sh -c '[ "$1" -eq 0 ] && printf "%s" "$2" | grep -q "^usage: " && printf "%s" "$2" | grep -q "^Exit:"' _ "${rc}" "${out}"
done
check 'end-job.sh'"'"'s help leaves another session'"'"'s job to the human' has "$(sh "${END_JOB}" --help)" "call, never main's"
check 'agent-jobs knows no agent kind' sh -c '! grep -rqE "code-builder|code-tester|code-reviewer" "$1"' _ "${R}/domains/software-development/core/main-thread/agent-jobs"

effort=$(sh "${K}/crucible-effort/scripts/main/effort-start.sh" --name 'job model') || { echo 'effort-start failed'; exit 1; }
other=$(sh "${K}/crucible-effort/scripts/main/effort-start.sh" --name 'another effort') || { echo 'effort-start failed'; exit 1; }
mkdir -p "${effort}/reports/build" "${other}/reports/build"

# write TYPE BY JSON [EFFORT]: one event through the real writer; SAID holds
# what it said, the exit is its exit.
write() {
	printf '%s\n' "$3" >"${S}/work/body.json"
	SAID=$(sh "${EW}" --effort "${4:-${effort}}" --type "$1" --by "$2" --body-file "${S}/work/body.json" 2>&1)
}
# job AGENT SESSION [EFFORT]: a build dispatched and assigned on its own
# tree; sets JOB. An empty AGENT only dispatches.
n=0
job() {
	n=$((n + 1))
	in=${3:-${effort}}
	JOB=$(($(sh "${ER}" --effort "${in}" --paths | wc -l | tr -d ' ') + 1))
	write job.dispatched job-dispatch.sh "{\"kind\": \"build\", \"agent_type\": \"code-builder\", \"tree\": \"/scratch/tree-${n}\",
		\"report\": \"reports/build/${JOB}.json\", \"known_failures\": [], \"iteration\": 1,
		\"setup\": {\"language\": \"shell\", \"standards\": [\"security\"]}}" "${in}" || { echo "    dispatch refused: ${SAID}"; return 1; }
	[ -n "$1" ] || return 0
	write job.assigned assign-job.sh "{\"job\": ${JOB}, \"agent\": \"$1\", \"name\": \"build-shell-$1\", \"session\": \"$2\"}" "${in}" \
		|| { echo "    assign refused: ${SAID}"; return 1; }
}
state() { sh "${JOB_OF}" --effort "${2:-${effort}}" --job "$1" | jq -r '.state'; }
last_event() { sh "${ER}" --effort "${1:-${effort}}" | jq -c 'last'; }
# pin [SEQ]: job SEQ's report (default JOB's) written and made read-only.
pin() { printf '{"summary": "done"}\n' >"${effort}/reports/build/${1:-${JOB}}.json"; chmod 444 "${effort}/reports/build/${1:-${JOB}}.json"; }

echo "=== job.assigned carries the assigning session"
job '' '' || exit 1
write job.assigned assign-job.sh "{\"job\": ${JOB}, \"agent\": \"a0000001\", \"name\": \"build-shell-a0000001\"}"; rc=$?
echo "    ${SAID}" | show
check 'an assignment with no session is refused' sh -c '[ "$1" -eq 2 ] && printf "%s" "$2" | grep -qF "session must be the assigning session'"'"'s id"' _ "${rc}" "${SAID}"
check 'with its session it is accepted' write job.assigned assign-job.sh "{\"job\": ${JOB}, \"agent\": \"a0000001\", \"name\": \"build-shell-a0000001\", \"session\": \"sess-main\"}"
check 'job-of.sh prints the session and a refusals count of 0' is "$(sh "${JOB_OF}" --effort "${effort}" --job "${JOB}" | jq -c '[.session, .refusals]')" '["sess-main",0]'

echo "=== job.refused: tries counted from the log"
REF="{\"job\": ${JOB}, \"iteration\": 1, \"agent\": \"a0000001\", \"lines\": [\"shorten the summary\"]"
write job.refused submit-agent-work.sh "${REF}, \"try\": 1}"; rc=$?
check 'only held-stop.sh writes it' sh -c '[ "$1" -eq 2 ] && printf "%s" "$2" | grep -qF "written only by held-stop.sh"' _ "${rc}" "${SAID}"
write job.refused held-stop.sh "${REF}, \"try\": 2}"; rc=$?
check 'a first refusal must be try 1' sh -c '[ "$1" -eq 2 ] && printf "%s" "$2" | grep -qF "try must be 1"' _ "${rc}" "${SAID}"
write job.refused held-stop.sh "{\"job\": ${JOB}, \"iteration\": 1, \"agent\": \"a0000001\", \"lines\": [], \"try\": 1}"; rc=$?
check 'a refusal with no repair lines is refused' sh -c '[ "$1" -eq 2 ] && printf "%s" "$2" | grep -qF "lines must be the repair lines"' _ "${rc}" "${SAID}"
check 'try 1 is accepted' write job.refused held-stop.sh "${REF}, \"try\": 1}"
write job.ended held-stop.sh "{\"job\": ${JOB}, \"iteration\": 1, \"agent\": \"a0000001\", \"reason\": \"gave-up\"}"; rc=$?
check 'gave-up after one refusal is refused' sh -c '[ "$1" -eq 2 ] && printf "%s" "$2" | grep -qF "after its second job.refused"' _ "${rc}" "${SAID}"
write job.refused held-stop.sh "${REF}, \"try\": 1}"; rc=$?
check 'try 1 again is refused: try must be 2' sh -c '[ "$1" -eq 2 ] && printf "%s" "$2" | grep -qF "try must be 2"' _ "${rc}" "${SAID}"
check 'try 2 is accepted' write job.refused held-stop.sh "${REF}, \"try\": 2}"
check 'job-of.sh counts 2 refusals' is "$(sh "${JOB_OF}" --effort "${effort}" --job "${JOB}" | jq -r '.refusals')" 2
check 'then gave-up is accepted' write job.ended held-stop.sh "{\"job\": ${JOB}, \"iteration\": 1, \"agent\": \"a0000001\", \"reason\": \"gave-up\"}"
write job.refused held-stop.sh "${REF}, \"try\": 3}"; rc=$?
check 'an ended job is refused no more' sh -c '[ "$1" -eq 2 ] && printf "%s" "$2" | grep -qF "is ended; only a running job is refused"' _ "${rc}" "${SAID}"

echo "=== job.ended: each reason has its writers and its fields"
job a0000002 sess-main || exit 1
FAULT="{\"job\": ${JOB}, \"iteration\": 1, \"agent\": \"a0000002\", \"reason\": \"fault\""
write job.ended fault-ended.sh "${FAULT}, \"step\": \"stamp\", \"fault\": \"x\"}"; rc=$?
check 'before acceptance a fault is at check or hook: stamp is refused' sh -c '[ "$1" -eq 2 ] && printf "%s" "$2" | grep -qF "a later fault stalls it"' _ "${rc}" "${SAID}"
write job.ended fault-ended.sh "${FAULT}, \"step\": \"check\"}"; rc=$?
check 'a fault without its line is refused' sh -c '[ "$1" -eq 2 ] && printf "%s" "$2" | grep -qF "fault must be the one line"' _ "${rc}" "${SAID}"
write job.ended recover-submission.sh "${FAULT}, \"step\": \"check\", \"fault\": \"x\"}"; rc=$?
check 'recover-submission.sh gives up only a stalled job' sh -c '[ "$1" -eq 2 ] && printf "%s" "$2" | grep -qF "ends only a job that is stalled"' _ "${rc}" "${SAID}"
write job.ended end-gone-jobs.sh "{\"job\": ${JOB}, \"iteration\": 1, \"agent\": \"a0000002\", \"reason\": \"no-stop\", \"note\": \"x\"}"; rc=$?
check 'a note belongs to end-job.sh only' sh -c '[ "$1" -eq 2 ] && printf "%s" "$2" | grep -qF "note belongs to end-job.sh"' _ "${rc}" "${SAID}"
write job.ended end-gone-jobs.sh "{\"job\": ${JOB}, \"iteration\": 1, \"reason\": \"no-stop\"}"; rc=$?
check 'an assigned job'"'"'s end names its agent' sh -c '[ "$1" -eq 2 ] && printf "%s" "$2" | grep -qF "agent must be a0000002"' _ "${rc}" "${SAID}"
write job.ended held-stop.sh "${FAULT}, \"step\": \"check\", \"fault\": \"x\"}"; rc=$?
check 'held-stop.sh writes no fault' sh -c '[ "$1" -eq 2 ] && printf "%s" "$2" | grep -qF "written only by fault-ended.sh or recover-submission.sh"' _ "${rc}" "${SAID}"
check 'fault at check, by fault-ended.sh, is accepted' write job.ended fault-ended.sh "${FAULT}, \"step\": \"check\", \"fault\": \"the rules aren't installed\"}"
check 'the job is ended' is "$(state "${JOB}")" ended

echo "=== job.stalled: accepted, waiting for its hand-in"
job a0000003 sess-main || exit 1
STALL="{\"job\": ${JOB}, \"iteration\": 1, \"agent\": \"a0000003\""
write job.stalled end-gone-jobs.sh "${STALL}, \"step\": \"commit\", \"fault\": \"x\"}"; rc=$?
check 'the no-stop writers stall a job only at step event' sh -c '[ "$1" -eq 2 ] && printf "%s" "$2" | grep -qF "step must be one of event"' _ "${rc}" "${SAID}"
check 'job.stalled at commit, by fault-stalled.sh' write job.stalled fault-stalled.sh "${STALL}, \"step\": \"commit\", \"fault\": \"index.lock exists\"}"
STALLED=${JOB}
check 'job-of.sh: stalled, not assigned' is "$(state "${STALLED}")" stalled
write job.stalled fault-stalled.sh "${STALL}, \"step\": \"event\", \"fault\": \"x\"}"; rc=$?
check 'a job stalls once' sh -c '[ "$1" -eq 2 ] && printf "%s" "$2" | grep -qF "is stalled; only a running job stalls"' _ "${rc}" "${SAID}"
write job.ended fault-ended.sh "${STALL}, \"reason\": \"fault\", \"step\": \"hook\", \"fault\": \"x\"}"; rc=$?
check 'a stalled job is not ended as a fault before acceptance' sh -c '[ "$1" -eq 2 ] && printf "%s" "$2" | grep -qF "is stalled; fault-ended.sh ends only a job that is assigned"' _ "${rc}" "${SAID}"
check 'its agent is free for its next job: an assignment is accepted' job a0000003 sess-main
pin "${STALLED}"
sha=$(shasum -a 256 "${effort}/reports/build/${STALLED}.json" | cut -d ' ' -f 1)
printf '%s\n' "{\"job\": ${STALLED}, \"iteration\": 1, \"agent\": \"a0000003\", \"report\": {\"path\": \"reports/build/${STALLED}.json\", \"sha256\": \"${sha}\"}}" >"${S}/work/sub.json"
check 'a stalled job can still be submitted' sh "${EW}" --effort "${effort}" --type build.submitted --by recover-submission.sh --body-file "${S}/work/sub.json"
check 'then it is submitted' is "$(state "${STALLED}")" submitted
job a0000004 sess-main || exit 1
write job.stalled fault-stalled.sh "{\"job\": ${JOB}, \"iteration\": 1, \"agent\": \"a0000004\", \"step\": \"lock\", \"fault\": \"another stop held the effort\"}" >/dev/null
check 'a stalled job can be given up: job.ended fault by recover-submission.sh' write job.ended recover-submission.sh "{\"job\": ${JOB}, \"iteration\": 1, \"agent\": \"a0000004\", \"reason\": \"fault\", \"step\": \"lock\", \"fault\": \"another stop held the effort\"}"

echo "=== an ended build that was never accepted is replaced under its own number"
write job.dispatched job-dispatch.sh "{\"kind\": \"build\", \"agent_type\": \"code-builder\", \"tree\": \"/scratch/tree-2\",
	\"report\": \"reports/build/$(($(sh "${ER}" --effort "${effort}" --paths | wc -l | tr -d ' ') + 1)).json\", \"known_failures\": [], \"iteration\": 1,
	\"setup\": {\"language\": \"shell\", \"standards\": [\"security\"]}}"; rc=$?
check 'the build ended at its check keeps iteration 1 for its replacement' is "${rc}" 0
write job.dispatched job-dispatch.sh "{\"kind\": \"build\", \"agent_type\": \"code-builder\", \"tree\": \"/scratch/tree-5\",
	\"report\": \"reports/build/$(($(sh "${ER}" --effort "${effort}" --paths | wc -l | tr -d ' ') + 1)).json\", \"known_failures\": [], \"iteration\": 1,
	\"setup\": {\"language\": \"shell\", \"standards\": [\"security\"]}}"; rc=$?
check 'a build given up after it stalled keeps its number: the next is 2' sh -c '[ "$1" -eq 2 ] && printf "%s" "$2" | grep -qF "iteration must be 2"' _ "${rc}" "${SAID}"

# stop_main SESSION RUNNING_IDS...: main's Stop hook JSON, as Claude Code
# gives it, to end-gone-jobs.sh; OUT and RC.
stop_main() {
	sess=$1; shift
	tasks=$(for id in "$@"; do jq -cn --arg id "${id}" '{id: $id, type: "subagent", status: "running", description: "a job", agent_type: "code-builder"}'; done | jq -sc .)
	jq -cn --arg s "${sess}" --argjson t "${tasks}" '{session_id: $s, hook_event_name: "Stop", stop_hook_active: false,
		last_assistant_message: "Done.", background_tasks: $t, session_crons: []}' >"${S}/work/stop.json"
	OUT=$(sh "${GONE}" <"${S}/work/stop.json" 2>"${S}/work/stop.err"); RC=$?
}

echo "=== main's Stop hook: this session's jobs whose agent is gone"
job g0000001 sess-main || exit 1; GONE_JOB=${JOB}
job g0000002 sess-main || exit 1; PINNED_JOB=${JOB}; pin
job g0000003 sess-other || exit 1; OTHER_JOB=${JOB}
job g0000004 sess-main || exit 1; RUNNING_JOB=${JOB}
job g0000005 sess-main "${other}" || exit 1; OTHER_EFFORT_JOB=${JOB}
job '' '' || exit 1; DISPATCHED_JOB=${JOB}
before=$(sh "${ER}" --effort "${effort}" --paths | wc -l | tr -d ' ')
stop_main sess-main g0000004
sh "${ER}" --effort "${effort}" | jq --argjson n "${before}" '[.[] | select(.seq > $n)]' | show >"${S}/work/gone.json"
mkdir -p "${E}/no-stop"; cp "${S}/work/gone.json" "${E}/no-stop/events.json"
check 'it prints nothing: main is never blocked' sh -c '[ -z "$1" ] && [ "$2" -eq 0 ]' _ "${OUT}" "${RC}"
check 'agent gone, report not pinned: job.ended no-stop, by end-gone-jobs.sh' is "$(jq -c --argjson j "${GONE_JOB}" '[.[] | select(.body.job == $j) | [.type, .by, .body.reason, .body.agent]]' "${S}/work/gone.json")" '[["job.ended","end-gone-jobs.sh","no-stop","g0000001"]]'
check 'agent gone, report pinned: job.stalled at step event, the report kept' is "$(jq -c --argjson j "${PINNED_JOB}" '[.[] | select(.body.job == $j) | [.type, .body.step, .body.fault]]' "${S}/work/gone.json")" '[["job.stalled","event","the agent ended after its report was pinned"]]'
check 'another session'"'"'s job is untouched' is "$(state "${OTHER_JOB}")" assigned
check 'a running agent'"'"'s job is untouched' is "$(state "${RUNNING_JOB}")" assigned
check 'a job only dispatched is untouched' is "$(state "${DISPATCHED_JOB}")" dispatched
check 'this session'"'"'s job in another effort is ended too' is "$(state "${OTHER_EFFORT_JOB}" "${other}")" ended
check 'nothing else was written: those two, and the earlier job of agent a0000003, gone too' is "$(jq -c '[.[] | .body.agent] | sort' "${S}/work/gone.json")" '["a0000003","g0000001","g0000002"]'
stop_main sess-main
check 'the next turn end has nothing more to do but the running agent'"'"'s, now gone' sh -c '[ -z "$1" ] && [ "$(sh "$2" --effort "$3" --job "$4" | jq -r .state)" = ended ]' _ "${OUT}" "${JOB_OF}" "${effort}" "${RUNNING_JOB}"
check 'a stalled job is left for main to finish' is "$(state "${PINNED_JOB}")" stalled
damaged=$(sh "${K}/crucible-effort/scripts/main/effort-start.sh" --name 'damaged log') || exit 1
job g0000006 sess-main "${damaged}" || exit 1
first_event=$(sh "${ER}" --effort "${damaged}" --paths | head -n 1)
chmod 000 "${first_event}"
stop_main sess-main
chmod 444 "${first_event}"
echo "    ${OUT}" | show
check 'a log it can'"'"'t read is told to the human, and main goes on' sh -c '[ "$2" -eq 0 ] && printf "%s" "$1" | jq -e "(.systemMessage | contains(\"could not record a job whose agent is gone\")) and (has(\"decision\") | not)"' _ "${OUT}" "${RC}"

echo "=== main's end-job.sh"
job e0000001 sess-main || exit 1
said=$(sh "${END_JOB}" --effort "${effort}" --job "${JOB}" --note 'gone' 2>&1); rc=$?
echo "    ${said}" | show
check 'a job this session assigned is refused: the Stop hook ends it' sh -c '[ "$1" -eq 2 ] && printf "%s" "$2" | grep -qF "assigned in this session"' _ "${rc}" "${said}"
job '' '' || exit 1
said=$(sh "${END_JOB}" --effort "${effort}" --job "${JOB}" 2>&1); rc=$?
check 'a note is required' sh -c '[ "$1" -eq 2 ] && printf "%s" "$2" | grep -qF -- "--note missing"' _ "${rc}" "${said}"
check 'a job only dispatched is ended' sh "${END_JOB}" --effort "${effort}" --job "${JOB}" --note 'its agent never started'
check 'job.ended no-stop by end-job.sh, with the note and no agent' is "$(last_event | jq -c '[.by, .body.reason, .body.note, (.body | has("agent"))]')" '["end-job.sh","no-stop","its agent never started",false]'
job e0000002 sess-dead || exit 1
said=$(sh "${END_JOB}" --effort "${effort}" --job "${JOB}" --note 'its session died' 2>&1); rc=$?
echo "    ${said}" | show
check 'another session'"'"'s job is refused without --other-session' sh -c '[ "$1" -eq 2 ] && printf "%s" "$2" | grep -qF "the human'"'"'s call: rerun with --other-session"' _ "${rc}" "${said}"
check 'with --other-session it is ended' sh "${END_JOB}" --effort "${effort}" --job "${JOB}" --note 'its session died' --other-session
check 'job.ended no-stop, the agent named' is "$(last_event | jq -c '[.by, .body.reason, .body.agent]')" '["end-job.sh","no-stop","e0000002"]'
job e0000003 sess-dead || exit 1; pin
sh "${END_JOB}" --effort "${effort}" --job "${JOB}" --note 'its session died' --other-session >"${S}/work/end.out" 2>"${S}/work/end.err"; rc=$?
show <"${S}/work/end.err" | sed 's/^/    /'
check 'another session'"'"'s job with its report pinned is recorded stalled, not ended' sh -c '[ "$1" -eq 0 ] && [ "$(sh "$2" --effort "$3" --job "$4" | jq -r .state)" = stalled ]' _ "${rc}" "${JOB_OF}" "${effort}" "${JOB}"
check 'main is told so in one line, naming where to finish it' sh -c '[ "$(wc -l <"$1" | tr -d " ")" -eq 1 ] && grep -qF "recorded stalled, not ended" "$1" && grep -qF "scripts/main/recover-submission.sh" "$1" && [ "$(wc -l <"$2" | tr -d " ")" -eq 1 ]' _ "${S}/work/end.err" "${S}/work/end.out"
check 'end-job.sh and end-gone-jobs.sh share one pinned test, in the agent-jobs lib' sh -c 'grep -q "lib/pinned.sh" "$1" && grep -q "lib/pinned.sh" "$2" && ! grep -q "^pinned()" "$1" && ! grep -q "^pinned()" "$2"' _ "${END_JOB}" "${GONE}"
check 'end-job.sh'"'"'s help claims no record of the human'"'"'s call' sh -c '! sh "$1" --help | grep -q "records that"' _ "${END_JOB}"
said=$(sh "${END_JOB}" --effort "${effort}" --job "${JOB}" --note 'again' --other-session 2>&1); rc=$?
check 'a stalled job is refused: it is finished or given up instead' sh -c '[ "$1" -eq 2 ] && printf "%s" "$2" | grep -qF "is stalled"' _ "${rc}" "${said}"

echo "=== agent-job.sh: one agent's open job, across the efforts"
AGENT_JOB="${K}/agent-jobs/scripts/internal/agent-job.sh"
out=$(sh "${AGENT_JOB}" --help 2>&1); rc=$?
check 'agent-job.sh --help' sh -c '[ "$1" -eq 0 ] && printf "%s" "$2" | grep -q "^usage: " && printf "%s" "$2" | grep -q "^Exit:"' _ "${rc}" "${out}"
found=$(sh "${AGENT_JOB}" --agent e0000001); rc=$?
check 'an open job is found: exit 0, its effort and job' sh -c '[ "$1" -eq 0 ] && printf "%s" "$2" | jq -e --arg e "$3" ".effort == \$e and .job.agent == \"e0000001\" and .job.state == \"assigned\""' _ "${rc}" "${found}" "${effort}"
job f0000001 sess-other "${other}" || exit 1
check 'a job in another effort is found there' sh -c '[ "$(sh "$1" --agent f0000001 | jq -r .effort)" = "$2" ]' _ "${AGENT_JOB}" "${other}"
sh "${AGENT_JOB}" --agent a0000001 >/dev/null 2>&1; rc=$?
check 'an agent whose jobs are done: exit 5, between jobs' is "${rc}" 5
started=$(date +%s)
sh "${AGENT_JOB}" --agent never00001 --wait 2 >/dev/null 2>&1; rc=$?
waited=$(($(date +%s) - started))
check 'an agent never assigned: exit 4, after looking again for 2 seconds' sh -c '[ "$1" -eq 4 ] && [ "$2" -ge 2 ] && [ "$2" -lt 10 ]' _ "${rc}" "${waited}"
sh "${AGENT_JOB}" --agent 'bad id' >/dev/null 2>&1; rc=$?
check 'a malformed id is refused: exit 2' is "${rc}" 2
check 'the stop hook and the write scope both use it, and neither searches the efforts itself' sh -c 'for f in "$1/agent-submission/hooks/subagent-stop/submit-agent-work.sh" "$1/agent-submission/hooks/pre-tool-use/steps/write-scope.sh"; do grep -q "agent-jobs/scripts/internal/agent-job.sh" "$f" && ! grep -q "efforts/\*" "$f" || exit 1; done' _ "${K}"

echo
echo "=== ${pass} PASS, ${fail} FAIL"
[ "${fail}" -eq 0 ]
