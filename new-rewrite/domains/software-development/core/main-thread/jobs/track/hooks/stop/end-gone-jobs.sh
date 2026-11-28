#!/usr/bin/env sh
# Claude Code Stop hook for main: ends this session's jobs whose agent is
# gone without handing in.
# shellcheck disable=SC2312 # a read inside a message only shortens the message
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077
work='' done=''
# A fault never blocks main: it is said to the human, and main goes on.
trap '[ -n "${done}" ] || jq -cn "{systemMessage: \"crucible: end-gone-jobs.sh failed; jobs whose agent is gone may still show as running\"}"; rm -rf -- ${work:+"${work}"}; exit 0' EXIT

usage() {
	cat <<'USAGE'
usage: sh end-gone-jobs.sh < STOP_HOOK_JSON

Run by Claude Code as main's Stop hook; not for main to call.
At the end of each of main's turns, in every effort: each job this session
assigned (job.assigned's session is the hook's session_id) that is still
running, whose agent is not in background_tasks, ended without a stop the
stop hook saw: its turn limit, a TaskStop, an interrupt, an API error.
  - its report is pinned (read-only): job.stalled {step: event}, so the
    accepted report is kept for its hand-in to be finished;
  - otherwise: job.ended {reason: no-stop}.
Another session's jobs are never touched: its agents aren't in this list.

Reads:     stdin, the hook JSON: session_id, background_tasks [{id}];
           CRUCIBLE_HOME, default $HOME/.crucible, whose efforts are read
Writes:    the events, through crucible-events' event-write.sh, by
           end-gone-jobs.sh
Stdout:    nothing; or {"systemMessage"} naming each event that could not
           be written, or the hook's own fault
Exit:
  0  always; it never blocks main
USAGE
}

case ${1-} in -h | --help) usage; done=1; exit 0 ;; *) ;; esac
prog='end-gone-jobs.sh'
command -v jq >/dev/null 2>&1 || { done=1; printf '%s: jq not found\n' "${prog}" >&2; exit 0; }

self=$0
case ${self} in /*) ;; *) self="$(pwd)/${self}" ;; esac
skills=${self%/*/*/*/*}
reader="${skills}/crucible-events/scripts/internal/events-read.sh"
writer="${skills}/crucible-events/scripts/internal/event-write.sh"
lib="$(dirname -- "$0")/../../scripts/lib"
. "$(dirname -- "$0")/../../scripts/lib/pinned.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/end-gone-jobs.XXXXXX")

cat >"${work}/input"
session=$(jq -r '.session_id // empty' "${work}/input")
case ${session} in '' | *[!A-Za-z0-9._-]*) done=1; exit 0 ;; *) ;; esac
jq -c '[.background_tasks // [] | .[] | .id | strings]' "${work}/input" >"${work}/running"
CLAUDE_CODE_SESSION_ID=${session}
export CLAUDE_CODE_SESSION_ID

: >"${work}/unwritten"
for effort in "${CRUCIBLE_HOME:-${HOME}/.crucible}"/efforts/*; do
	[ -d "${effort}/events" ] || continue
	grep -rlqF -- "${session}" "${effort}/events" 2>/dev/null || continue
	if ! sh "${reader}" --effort "${effort}" >"${work}/events" 2>"${work}/said"; then
		printf '%s: %s\n' "${effort##*/}" "$(head -n 1 "${work}/said")" >>"${work}/unwritten"
		continue
	fi
	jq -c -L "${lib}" --arg session "${session}" --slurpfile running "${work}/running" 'include "jobs"; . as $all
		| [.[] | select(.type == "job.assigned" and ((.body.session // .claude_session_id) == $session)) | .body]
		| .[] | .job as $job | .agent as $agent
		| select(($all | jobs_state($job)) == "assigned") | select($running[0] | any(.[]; . == $agent) | not)
		| {report: ($all | jobs_dispatch($job).body.report), stamps: ($all | jobs_stamps($job))}' \
		"${work}/events" >"${work}/gone"
	while IFS= read -r gone; do
		report="${effort}/$(printf '%s' "${gone}" | jq -r '.report')"
		# shellcheck disable=SC2310 # pn_pinned is a test, called for its status
		if pn_pinned "${report}"; then
			type=job.stalled
			printf '%s' "${gone}" | jq '.stamps + {step: "event", fault: "the agent ended after its report was pinned"}' >"${work}/body"
		else
			type=job.ended
			printf '%s' "${gone}" | jq '.stamps + {reason: "no-stop"}' >"${work}/body"
		fi
		sh "${writer}" --effort "${effort}" --type "${type}" --by "${prog}" --body-file "${work}/body" >/dev/null 2>"${work}/said" \
			|| printf '%s job %s: %s\n' "${type}" "$(jq -r '.job' "${work}/body")" "$(head -n 1 "${work}/said")" >>"${work}/unwritten"
	done <"${work}/gone"
done

done=1
[ -s "${work}/unwritten" ] || exit 0
jq -Rsc '{systemMessage: ("crucible: end-gone-jobs.sh could not record a job whose agent is gone; it still shows as running: "
	+ (rtrimstr("\n") | split("\n") | join("; ")))}' "${work}/unwritten"
