#!/usr/bin/env sh
# Claude Code SubagentStop hook: hands in a job agent's work. It finds the
# stopping agent's job, checks its report, pins it, makes the working commit
# and writes the submission event, holding the stop while the report is
# refused. It knows no agent kind: the agent's own component says how its
# report is checked and which event it writes.
# shellcheck disable=SC2312 # a read inside a message only shortens the message
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh submit-agent-work.sh < SUBAGENT_STOP_HOOK_JSON

Run by Claude Code as the SubagentStop hook; not for main to call.
For an agent working on a job (job.assigned, not finished), by what
<agent_type>/submissions/<kind>.json says ({event, commit, rules, problems,
facts?, stamps?}), in order: checks its report by those rules; then, under
the stop hook's own lock for the effort, stamps it by the stamps rules when
the file names them, pins it, commits the tree unsigned when it says
commit, and writes the event it names.

Every outcome is an event, or, when there is no job, a message:
  - a refused report holds the stop with its repair lines: job.refused; the
    second refusal ends the job (job.ended, gave-up) and lets the stop
    through. A refusal that can't be recorded holds a first stop; a stop
    that already follows a block (stop_hook_active) goes through, and the
    job stays assigned for main's turn end;
  - a fault before the report is accepted (a missing or wrong submission
    file, rules module or facts script, a check that can't run) ends the
    job: job.ended {fault, step check};
  - a fault after it (the lock waited out, the stamp, pin, commit or event
    failing) stalls the job, its report kept: job.stalled {step};
  - an exit with no outcome reached is step hook, ending or stalling the
    job the same way.
Each fault, and a give-up, is told to the human. An agent with no job is
let through; but one of a type with a submissions folder that was never
assigned any job, looked for again for about 5 seconds, is told to the
human too.

What this plumbing reads in a report, and nothing more; every other rule
about it is its agent's own:
  - the report is one JSON object;
  - any at in it is a location, or a list of them: path, path:N,
    path:N-M, -path:N (read at the job's base) or @<where>:path..., checked
    once, before the agent's rules: well formed, naming a file, the line
    within it;
  - a report whose job commits has a summary, the commit's subject.

Reads:     stdin, the hook JSON: session_id, agent_id, agent_type,
           stop_hook_active;
           CRUCIBLE_HOME, default $HOME/.crucible, whose efforts are searched
           for the job; CRUCIBLE_STOP_LOCK_SECONDS, a shorter wait for the
           stop lock than its 120 seconds
Writes:    the report (pruned, then read-only), the working commit, the
           submission event; job.refused, job.ended or job.stalled
Stdout:    nothing; or {"decision": "block", "reason": the repair lines,
           "systemMessage"?} to hold the stop; or {"systemMessage"} telling
           the human the job gave up, which step failed, or that a job
           agent stopped with no job
Exit:
  0  always; only a printed block holds the stop
USAGE
}

case ${1-} in -h | --help) usage; exit 0 ;; *) ;; esac
prog='submit-agent-work.sh'
command -v jq >/dev/null 2>&1 || { printf '%s: jq not found; the stop goes through unchecked\n' "${prog}" >&2; exit 0; }

# A new agent's assignment can race its stop: a job-taking agent with no job
# is looked for again, once a second, before the human is told.
relook_tries=5

here=$(dirname -- "$0")
self=$0
case ${self} in /*) ;; *) self="$(pwd)/${self}" ;; esac
skills=${self%/*/*/*/*}
. "${here}/../../scripts/lib/stop-lock.sh"

work='' lock='' effort='' job='' named='' accepted='' outcome='' step=check

# Tells the human $1, through Claude Code.
tell() { jq -cn --arg m "crucible: $1" '{systemMessage: $m}'; }

# The stop goes through with no job to record anything on; the human is
# told $1.
say() {
	printf '%s: %s\n' "${prog}" "$1" >&2
	outcome=told
	tell "$1"
	exit 0
}

# Records a fault at step $1, its line $2, on the job: it ends before the
# report is accepted, and stalls after. Then tells the human.
record_fault() {
	if [ -z "${accepted}" ]; then
		rf_writer=fault-ended.sh rf_type=job.ended rf_then='the job ends, nothing handed in'
	else
		rf_writer=fault-stalled.sh rf_type=job.stalled
		rf_then="its report is kept: sh ${skills}/agent-submission/scripts/main/recover-submission.sh --effort ${effort} --job $(jq -r '.job' "${job}") --finish hands it in, --give-up ends the job"
	fi
	outcome=fault
	if ! sh "${here}/${rf_writer}" --effort "${effort}" --job "${job}" --step "$1" --fault "$2" 2>"${work}/fault-said"; then
		rf_then="${rf_then}; ${rf_type} could not be written either: $(head -n 1 "${work}/fault-said")"
	fi
	printf '%s: %s; %s\n' "${prog}" "$2" "${rf_then}" >&2
	tell "$2; ${rf_then}"
}

# The same, then the stop goes through.
fault() {
	record_fault "$1" "$2"
	exit 0
}

# Any exit reaches here. One with no outcome noted is a fault at step hook,
# or, with no job found yet, a message. Nothing here may stop the cleanup.
on_exit() {
	trap - EXIT
	set +e
	[ -z "${lock}" ] || sl_release "${lock}"
	if [ -z "${outcome}" ]; then
		if [ -n "${job}" ]; then
			record_fault hook "${prog} ended unexpectedly at its ${step} step for ${named}"
		else
			tell "${prog} ended unexpectedly before it found the stopping agent's job; nothing was checked"
		fi
	fi
	rm -rf -- ${work:+"${work}"}
	exit 0
}
trap on_exit EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP

job_of="${skills}/agent-jobs/scripts/internal/job-of.sh"
had_job="${skills}/agent-jobs/scripts/internal/agent-had-job.sh"
for need in "${job_of}" "${had_job}"; do
	[ -f "${need}" ] || say "agent-jobs isn't beside agent-submission (expected ${need}); no agent's work is handed in until it is installed"
done

input=$(cat)
agent=$(printf '%s' "${input}" | jq -r '.agent_id // empty' 2>/dev/null) || { outcome=passed; exit 0; }
case ${agent} in '' | *[!A-Za-z0-9._-]*) outcome=passed; exit 0 ;; *) ;; esac
agent_type=$(printf '%s' "${input}" | jq -r '.agent_type // empty' 2>/dev/null) || agent_type=''
after_block=$(printf '%s' "${input}" | jq -r '.stop_hook_active == true' 2>/dev/null) || after_block=false
session=$(printf '%s' "${input}" | jq -r '.session_id // empty' 2>/dev/null) || session=''
case ${session} in '' | *[!A-Za-z0-9._-]*) ;; *) CLAUDE_CODE_SESSION_ID=${session}; export CLAUDE_CODE_SESSION_ID ;; esac

work=$(mktemp -d "${TMPDIR:-/tmp}/submit-agent-work.XXXXXX") || { outcome=passed; exit 0; }

# The effort holding the agent's job: a cheap first pass on the bare id,
# then job-of.sh. Sets effort when found; seen when the agent had a job
# that is no longer open.
seen=''
find_job() {
	for candidate in "${CRUCIBLE_HOME:-${HOME}/.crucible}"/efforts/*; do
		[ -d "${candidate}/events" ] || continue
		grep -rlqF -- "${agent}" "${candidate}/events" 2>/dev/null || continue
		fj_rc=0
		sh "${job_of}" --effort "${candidate}" --agent "${agent}" >"${work}/job.json" 2>"${work}/said" || fj_rc=$?
		case ${fj_rc} in
			0) effort=${candidate}; return 0 ;;
			5) if sh "${had_job}" --effort "${candidate}" --agent "${agent}" 2>/dev/null; then seen=1; fi ;;
			*) say "the job of agent ${agent} could not be read in ${candidate}: $(head -n 1 "${work}/said")" ;;
		esac
	done
	return 1
}

# No job found: told to the human only for an agent of a job-taking type
# (its component has a submissions folder) that was never assigned a job.
# An empty type is Claude Code's own helper; an agent that had a job is
# between jobs, answering main.
job_taking() {
	case ${agent_type} in '' | *[!a-z0-9-]*) return 1 ;; *) ;; esac
	[ -d "${skills}/${agent_type}/submissions" ]
}
# shellcheck disable=SC2310 # find_job and job_taking are tests, called for their status
if ! find_job; then
	if [ -n "${seen}" ] || ! job_taking; then outcome=passed; exit 0; fi
	tries=0
	until [ "${tries}" -ge "${relook_tries}" ]; do
		sleep 1
		tries=$((tries + 1))
		! find_job || break
	done
	[ -n "${effort}" ] || say "agent ${agent} (${agent_type}) stopped, and no effort has a job assigned to it; its report, if any, was not checked or handed in"
fi
job="${work}/job.json"
seq=$(jq -r '.job' "${job}")
kind=$(jq -r '.kind' "${job}")
agent_type=$(jq -r '.agent_type' "${job}")
report="${effort}/$(jq -r '.report' "${job}")"
tree=$(jq -r '.tree' "${job}")
named="job ${seq} ($(jq -r '.name' "${job}"))"

# The agent's submission file. A missing or wrong one is an install fault:
# the agent can't repair it, so it is never a refusal.
submission="${skills}/${agent_type}/submissions/${kind}.json"
[ -f "${submission}" ] || fault check "${agent_type} has no submissions/${kind}.json, so ${named} can't be handed in"
jq -e '(.event | type) == "string" and (.commit | type) == "boolean" and (.rules | type) == "string"
	and (.problems | type) == "string" and ((.facts // "") | type) == "string"
	and ((.stamps // {}) | type) == "object"' "${submission}" >/dev/null 2>&1 \
	|| fault check "${agent_type}/submissions/${kind}.json is not {event, commit, rules, problems, facts?, stamps?}, so ${named} can't be handed in"

# The check; its repair lines, or none. A check that can't run is an
# install fault too.
rc=0
sh "${here}/report-validation.sh" --effort "${effort}" --job "${job}" >"${work}/lines" 2>"${work}/said" || rc=$?
case ${rc} in
	0 | 1) ;;
	*) fault check "the report check of ${named} can't run: $(head -n 1 "${work}/said")" ;;
esac

if [ -s "${work}/lines" ]; then
	step=refusal
	rc=0
	held=$(sh "${here}/held-stop.sh" --effort "${effort}" --job "${job}" --lines "${work}/lines" 2>"${work}/said") || rc=$?
	unrecorded=''
	if [ "${rc}" -ne 0 ]; then
		unrecorded="the refusal of ${named} could not be recorded: $(head -n 1 "${work}/said")"
		# A stop that already follows a block goes through, so an event log
		# that can't be written holds an agent once, never in a loop.
		if [ "${after_block}" = true ]; then
			outcome=told
			unrecorded="${unrecorded}; its stop already followed a block, so it goes through, nothing handed in, and the job stays open for main's turn end"
			printf '%s: %s\n' "${prog}" "${unrecorded}" >&2
			tell "${unrecorded}"
			exit 0
		fi
		unrecorded="${unrecorded}; its stop is held all the same"
		printf '%s: %s\n' "${prog}" "${unrecorded}" >&2
	elif [ "${held}" = ended ]; then
		outcome=gave-up
		tell "${named} gave up: its report was refused twice. Its tree ${tree} is kept for the next job."
		exit 0
	fi
	jq -Rsc --arg report "${report}" --arg told "${unrecorded}" '{decision: "block",
		reason: ("Your report \($report) was not accepted. Repair each line, then stop again; a second refusal ends this job.\n" + rtrimstr("\n"))}
		+ (if $told == "" then {} else {systemMessage: ("crucible: " + $told)} end)' "${work}/lines"
	outcome=held
	exit 0
fi

# Accepted. From the stamp to the event, one stop at a time in the effort;
# a fault from here on stalls the job, its report kept.
accepted=1
step=lock
mkdir -p "${effort}/stops"
# shellcheck disable=SC2310 # sl_take is a retry loop called for its status
sl_take "${effort}/stops/.lock" || fault lock "another agent's stop held ${named}'s effort too long"
lock="${effort}/stops/.lock"
step=stamp
sh "${here}/report-stamp.sh" --effort "${effort}" --job "${job}" 2>"${work}/said" \
	|| fault stamp "${named}'s report could not be stamped: $(head -n 1 "${work}/said")"
step=pin
sha256=$(sh "${here}/report-pin.sh" --report "${report}" 2>"${work}/said") \
	|| fault pin "${named}'s report could not be pinned: $(head -n 1 "${work}/said")"
commit=''
if [ "$(jq -r '.commit' "${submission}")" = true ]; then
	step=commit
	commit=$(sh "${here}/working-commit.sh" --effort "${effort}" --job "${job}" 2>"${work}/said") \
		|| fault commit "${named}'s working commit failed: $(head -n 1 "${work}/said")"
fi
step=event
event=$(jq -r '.event' "${submission}")
sh "${here}/submission-event.sh" --effort "${effort}" --job "${job}" --type "${event}" --sha256 "${sha256}" \
	${commit:+--commit "${commit}"} >/dev/null 2>"${work}/said" \
	|| fault event "${named}'s ${event} was not written: $(head -n 1 "${work}/said")${commit:+; the working commit ${commit} carries its Job trailer}"
outcome=submitted
