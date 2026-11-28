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
usage: sh submit-agent-work.sh < HOOK_JSON

Run by Claude Code as the SubagentStop hook, and as the PreToolUse hook on
SubagentHandback (through hand-in-at-handback.sh), the door an agent in auto
mode leaves by; not for main to call. One check at both doors: a job
already handed in at its handback passes at its stop.
Hands in a job agent's work: checks its report by the rules its
submissions/<kind>.json names, then, under the stop lock, stamps, pins,
commits when the kind commits, and writes the submission event. Every
outcome is an event:
  - refused: job.refused, the stop held (the handback denied) with the
    repair lines; the second refusal ends the job (gave-up), and a handback
    is then denied once more, to hand back only that the job ended; one not
    recorded is held only once
  - a fault before acceptance (an install fault, a check that can't run):
    job.ended fault, step check; after it: job.stalled at the step; an
    exit with no outcome: step hook, ended or stalled the same way
  - no job: let through, but a job-taking type never assigned one, looked
    for again for 5 s, is told to the human
It reads in a report only: one JSON object; every at a well-formed location
naming a real file and line; a summary, the commit's subject, when it commits.

Reads:     stdin: hook_event_name, session_id, agent_id, agent_type,
           stop_hook_active;
           CRUCIBLE_STOP_LOCK_SECONDS, a stop-lock wait shorter than 120 s
Writes:    the report (pruned, then read-only), the working commit, the events
Stdout:    nothing; or {"decision": "block", "reason", "systemMessage"?},
           holding the stop, at a handback {"hookSpecificOutput":
           {"permissionDecision": "deny", ...}} with the same reason; or
           {"systemMessage"} for the human
Exit:
  0  always; only a printed block holds the stop
USAGE
}

case ${1-} in -h | --help) usage; exit 0 ;; *) ;; esac
prog='submit-agent-work.sh'
command -v jq >/dev/null 2>&1 || { printf '%s: jq not found; the stop goes through unchecked\n' "${prog}" >&2; exit 0; }

# A new agent's assignment can race its stop: a job-taking agent with no job
# is looked for again, once a second, before the human is told.
relook_seconds=5

here=$(dirname -- "$0")
self=$0
case ${self} in /*) ;; *) self="$(pwd)/${self}" ;; esac
skills=${self%/*/*/*/*}
. "${skills}/jobs-agent-init/scripts/lib/agent-type.sh"
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
	if ! sh "${here}/steps/${rf_writer}" --effort "${effort}" --job "${job}" --step "$1" --fault "$2" 2>"${work}/fault-said"; then
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

agent_job="${skills}/jobs-track/scripts/internal/agent-job.sh"
[ -f "${agent_job}" ] || say "jobs-track isn't beside agent-submission (expected ${agent_job}); no agent's work is handed in until it is installed"

input=$(cat)
agent=$(printf '%s' "${input}" | jq -r '.agent_id // empty' 2>/dev/null) || { outcome=passed; exit 0; }
case ${agent} in '' | *[!A-Za-z0-9._-]*) outcome=passed; exit 0 ;; *) ;; esac
agent_type=$(printf '%s' "${input}" | jq -r '.agent_type // empty' 2>/dev/null) || agent_type=''
after_block=$(printf '%s' "${input}" | jq -r '.stop_hook_active == true' 2>/dev/null) || after_block=false
door=$(printf '%s' "${input}" | jq -r 'if .hook_event_name == "PreToolUse" then "handback" else "stop" end' 2>/dev/null) || door=stop

# Holds the agent with reason $1 (and the human told $2, if any): its stop
# blocked, or its handback denied, by the door it came to.
hold() {
	if [ "${door}" = handback ]; then
		jq -cn --arg r "$1" --arg told "${2-}" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}
			+ (if $told == "" then {} else {systemMessage: ("crucible: " + $told)} end)'
	else
		jq -cn --arg r "$1" --arg told "${2-}" '{decision: "block", reason: $r}
			+ (if $told == "" then {} else {systemMessage: ("crucible: " + $told)} end)'
	fi
}
session=$(printf '%s' "${input}" | jq -r '.session_id // empty' 2>/dev/null) || session=''
case ${session} in '' | *[!A-Za-z0-9._-]*) ;; *) CLAUDE_CODE_SESSION_ID=${session}; export CLAUDE_CODE_SESSION_ID ;; esac

work=$(mktemp -d "${TMPDIR:-/tmp}/submit-agent-work.XXXXXX") || { outcome=passed; exit 0; }

# The agent's open job, through jobs-track's agent-job.sh. None: told to
# the human only for an agent of a job-taking type (a base with a
# submissions folder, or an agent file named for one) that was never
# assigned a job, looked for again first,
# since its assignment can land just after it stops. An empty type is
# Claude Code's own helper; an agent that had a job is between jobs,
# answering main.
job_taking() {
	case ${agent_type} in '' | *[!a-z0-9-]*) return 1 ;; *) ;; esac
	at_base "${agent_type}" "${skills}" >/dev/null
}
wait=0
# shellcheck disable=SC2310 # job_taking is a test, called for its status
if job_taking; then wait=${relook_seconds}; fi
rc=0
sh "${agent_job}" --agent "${agent}" --wait "${wait}" >"${work}/found" 2>"${work}/said" || rc=$?
case ${rc} in
	0) ;;
	4) [ "${wait}" -gt 0 ] || { outcome=passed; exit 0; }
		say "agent ${agent} (${agent_type}) stopped, and no effort has a job assigned to it; its report, if any, was not checked or handed in" ;;
	5) outcome=passed; exit 0 ;;
	*) say "$(head -n 1 "${work}/said")" ;;
esac
effort=$(jq -r '.effort' "${work}/found")
jq '.job' "${work}/found" >"${work}/job.json"
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
sh "${here}/steps/report-validation.sh" --effort "${effort}" --job "${job}" >"${work}/lines" 2>"${work}/said" || rc=$?
case ${rc} in
	0 | 1) ;;
	*) fault check "the report check of ${named} can't run: $(head -n 1 "${work}/said")" ;;
esac

if [ -s "${work}/lines" ]; then
	step=refusal
	rc=0
	held=$(sh "${here}/steps/held-stop.sh" --effort "${effort}" --job "${job}" --lines "${work}/lines" 2>"${work}/said") || rc=$?
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
		if [ "${door}" = handback ]; then
			# The refused report must not reach main as a result.
			hold "Your report was refused twice, so this job has ended with nothing handed in. Hand back only that: one line, no findings." \
				"${named} gave up: its report was refused twice. Its tree ${tree} is kept for the next job."
		else
			tell "${named} gave up: its report was refused twice. Its tree ${tree} is kept for the next job."
		fi
		exit 0
	fi
	again='stop again'
	[ "${door}" = stop ] || again='hand back again'
	hold "$(jq -Rsr --arg report "${report}" --arg again "${again}" '"Your report \($report) was not accepted. Repair each line, then \($again); a second refusal ends this job.\n" + rtrimstr("\n")' "${work}/lines")" "${unrecorded}"
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
sh "${here}/steps/report-stamp.sh" --effort "${effort}" --job "${job}" 2>"${work}/said" \
	|| fault stamp "${named}'s report could not be stamped: $(head -n 1 "${work}/said")"
step=pin
sha256=$(sh "${here}/steps/report-pin.sh" --report "${report}" 2>"${work}/said") \
	|| fault pin "${named}'s report could not be pinned: $(head -n 1 "${work}/said")"
commit=''
if [ "$(jq -r '.commit' "${submission}")" = true ]; then
	step=commit
	commit=$(sh "${here}/steps/working-commit.sh" --effort "${effort}" --job "${job}" 2>"${work}/said") \
		|| fault commit "${named}'s working commit failed: $(head -n 1 "${work}/said")"
fi
step=event
event=$(jq -r '.event' "${submission}")
sh "${here}/steps/submission-event.sh" --effort "${effort}" --job "${job}" --type "${event}" --sha256 "${sha256}" \
	${commit:+--commit "${commit}"} >/dev/null 2>"${work}/said" \
	|| fault event "${named}'s ${event} was not written: $(head -n 1 "${work}/said")${commit:+; the working commit ${commit} carries its Job trailer}"
outcome=submitted
