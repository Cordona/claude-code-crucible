#!/usr/bin/env sh
# Prints what a caller needs about one job: the one reader of a job's start.
# shellcheck source-path=SCRIPTDIR
set -eu

usage() {
	cat <<'USAGE'
usage: sh job-of.sh --effort FOLDER (--job SEQ | --agent ID)

Run by component scripts and hooks; not for main to call.
Prints one job of an effort: by its seq, or the job an agent is working on.

Options:
  --effort FOLDER  the effort's folder, absolute
  --job SEQ        the seq of the job's start, in any state
  --agent ID       an agent's id: the job assigned to it and not finished
Reads:     the effort's events, through crucible-events' events-read.sh
Writes:    nothing
Stdout:    one JSON line {job, state, kind, agent_type, tree, report,
           findings?, sent_back?, known_failures, iteration, fix_round?,
           setup, refs?, agent?, name?, session?, refusals}: the job's
           start, refs its input refs by name
           with its seq as job; state is dispatched, assigned, stalled,
           submitted or ended; tree and report as dispatched (report
           relative to the effort); agent, name and session once
           job.assigned is written; refusals, its job.refused count
Exit:
  0  printed
  2  refused, nothing changed; the reason is on stderr
  5  no such job, or the agent is working on none
USAGE
}

prog='job-of.sh'
refuse() {
	printf '%s: %s\n' "${prog}" "$1" >&2
	exit 2
}

effort='' job='' agent=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--effort | --job | --agent)
			[ $# -ge 2 ] && [ -n "$2" ] || refuse "$1 needs a value"
			case $1 in --effort) effort=$2 ;; --job) job=$2 ;; --agent) agent=$2 ;; *) ;; esac
			shift 2 ;;
		*) refuse "unknown argument $1; try --help" ;;
	esac
done
command -v jq >/dev/null 2>&1 || refuse 'jq not found'
case ${effort} in /*) ;; *) refuse '--effort must be an absolute folder' ;; esac
[ -d "${effort}/events" ] || refuse "${effort} is not an effort folder"
[ -n "${job}${agent}" ] || refuse 'give --job or --agent'
[ -z "${job}" ] || [ -z "${agent}" ] || refuse 'give --job or --agent, not both'
[ -z "${job}" ] || printf '%s\n' "${job}" | grep -Eqx '[1-9][0-9]*' || refuse '--job must be a whole number from 1'

self=$0
case ${self} in /*) ;; *) self="$(pwd)/${self}" ;; esac
reader="${self%/*/*/*/*}/crucible-events/scripts/internal/events-read.sh"
[ -f "${reader}" ] || refuse "crucible-events isn't beside this skill (expected ${reader}); install first"
events=$(sh "${reader}" --effort "${effort}") || exit 2

found=$(printf '%s\n' "${events}" | jq -c -L "$(dirname -- "$0")/../lib" --arg job "${job}" --arg agent "${agent}" '
	include "jobs";
	. as $all
	| (if $job != "" then $job | tonumber else ($all | jobs_open_of($agent) | last) end) as $seq
	| ($all | jobs_dispatch($seq)) as $dispatch
	| if $dispatch == null then empty
	  else {job: $seq, state: ($all | jobs_state($seq))} + $dispatch.body
		+ (($all | jobs_assignment($seq)) // {} | with_entries(select(.value != null)))
		+ {refusals: ($all | jobs_refusals($seq) | length)}
	  end')
# A job defined through jobs-define names its kind; the kind names its agent.
if [ -n "${found}" ] && [ "$(printf '%s' "${found}" | jq -r 'has("agent_type")')" = false ]; then
	kind=$(printf '%s' "${found}" | jq -r '.kind')
	base=$(jq -r '.agent // empty' "${self%/*/*/*/*}/jobs-define/kinds/${kind}.json" 2>/dev/null) || base=''
	[ -n "${base}" ] || { printf '%s: kind %s names no agent in jobs-define/kinds/%s.json\n' "${prog}" "${kind}" "${kind}" >&2; exit 2; }
	found=$(printf '%s' "${found}" | jq -c --arg b "${base}" '. + {agent_type: $b}')
fi
if [ -z "${found}" ]; then
	if [ -n "${job}" ]; then printf '%s: no job %s in %s\n' "${prog}" "${job}" "${effort}" >&2
	else printf '%s: agent %s is working on no job in %s\n' "${prog}" "${agent}" "${effort}" >&2; fi
	exit 5
fi
printf '%s\n' "${found}"
