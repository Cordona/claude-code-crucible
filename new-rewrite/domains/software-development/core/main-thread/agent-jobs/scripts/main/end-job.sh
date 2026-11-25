#!/usr/bin/env sh
# Ends a job whose agent is gone and never handed in, on main's word.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh end-job.sh --effort FOLDER --job SEQ --note TEXT [--other-session]

Ends a job that will never be handed in (job.ended no-stop): one only
dispatched, whose agent never started; or, with --other-session, one another
session assigned, once the human says that session is dead: its agent may
still run elsewhere, so that is the human's call, never main's. Refuses this
session's jobs (main's turn end ends them), stalled jobs and finished ones.

Options:
  --effort FOLDER  the effort's folder, absolute
  --job SEQ        the job's seq
  --note TEXT      why it ends, one line, for the human reading the log
  --other-session  only on the human's word
Reads:     CLAUDE_CODE_SESSION_ID, this session
Writes:    one job.ended event; or job.stalled at step event when the report
           is pinned, so the accepted work is kept, one line on stderr saying so
Stdout:    the event's absolute path
Exit:
  0  written
  2  refused, nothing written; the reason is on stderr
  6  the events lock stayed held: rerun
USAGE
}

prog='end-job.sh'
refuse() {
	printf '%s: %s\n' "${prog}" "$1" >&2
	exit 2
}

effort='' seq='' note='' other=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--other-session) other=1; shift ;;
		--effort | --job | --note)
			[ $# -ge 2 ] && [ -n "$2" ] || refuse "$1 needs a value"
			case $1 in --effort) effort=$2 ;; --job) seq=$2 ;; --note) note=$2 ;; *) ;; esac
			shift 2 ;;
		*) refuse "unknown argument $1; try --help" ;;
	esac
done
command -v jq >/dev/null 2>&1 || refuse 'jq not found'
case ${effort} in /*) ;; *) refuse '--effort must be an absolute folder' ;; esac
[ -d "${effort}/events" ] || refuse "${effort} is not an effort folder"
printf '%s\n' "${seq}" | grep -Eqx '[1-9][0-9]*' || refuse '--job must be a whole number from 1'
[ -n "${note}" ] || refuse '--note missing: say in one line why the job ends'
case ${note} in *'
'*) refuse '--note must be one line' ;; *) ;; esac

self=$0
case ${self} in /*) ;; *) self="$(pwd)/${self}" ;; esac
skills=${self%/*/*/*/*}
reader="${skills}/crucible-events/scripts/internal/events-read.sh"
writer="${skills}/crucible-events/scripts/internal/event-write.sh"
for need in "${reader}" "${writer}"; do
	[ -f "${need}" ] || refuse "crucible-events isn't beside this skill (expected ${need}); install first"
done
lib="$(dirname -- "$0")/../lib"
. "$(dirname -- "$0")/../lib/pinned.sh"

work=$(mktemp -d "${TMPDIR:-/tmp}/end-job.XXXXXX") || refuse 'mktemp could not make a work folder'
trap 'rm -rf -- "${work}"' EXIT
sh "${reader}" --effort "${effort}" >"${work}/events" || refuse 'the effort'"'"'s events could not be read'
jq -c -L "${lib}" --argjson job "${seq}" 'include "jobs"; . as $all
	| if jobs_dispatch($job) == null then empty
	  else {state: jobs_state($job), report: jobs_dispatch($job).body.report, session: (jobs_assigned($job).body.session // ""),
		stamps: jobs_stamps($job)} end' "${work}/events" >"${work}/job"
[ -s "${work}/job" ] || refuse "no job ${seq} in ${effort}"
state=$(jq -r '.state' "${work}/job")
assigned_by=$(jq -r '.session' "${work}/job")
case ${state} in
	dispatched) ;;
	assigned)
		[ "${assigned_by}" != "${CLAUDE_CODE_SESSION_ID:-}" ] \
			|| refuse "job ${seq} was assigned in this session; its agent may still run, and main's turn end ends it once the agent is gone"
		[ -n "${other}" ] \
			|| refuse "job ${seq} was assigned by session ${assigned_by}, whose agent may still run; ending it is the human's call: rerun with --other-session on their word" ;;
	stalled) refuse "job ${seq} is stalled: its accepted report is finished or given up with agent-submission's scripts/main/recover-submission.sh" ;;
	*) refuse "job ${seq} is ${state}; only a job that never handed in ends here" ;;
esac

report="${effort}/$(jq -r '.report' "${work}/job")"
type=job.ended
# shellcheck disable=SC2310 # pn_pinned is a test, called for its status
if [ "${state}" = assigned ] && pn_pinned "${report}"; then
	type=job.stalled
	printf '%s: job %s'"'"'s report is pinned, so it is recorded stalled, not ended: finish or give up its hand-in with agent-submission'"'"'s scripts/main/recover-submission.sh\n' "${prog}" "${seq}" >&2
	jq '.stamps + {step: "event", fault: "the agent ended after its report was pinned"}' "${work}/job" >"${work}/body"
else
	jq --arg note "${note}" '.stamps + {reason: "no-stop", note: $note}' "${work}/job" >"${work}/body"
fi
sh "${writer}" --effort "${effort}" --type "${type}" --by "${prog}" --body-file "${work}/body"
