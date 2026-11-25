#!/usr/bin/env sh
# Says whether an agent was ever assigned a job in an effort.
# shellcheck source-path=SCRIPTDIR
set -eu

usage() {
	cat <<'USAGE'
usage: sh agent-had-job.sh --effort FOLDER --agent ID

Run by component scripts and hooks; not for main to call.
Says whether agent ID was assigned any job in the effort, in any state: an
agent between jobs had one; an agent whose assignment is missing had none.

Options:
  --effort FOLDER  the effort's folder, absolute
  --agent ID       the agent's id
Reads:     the effort's events, through crucible-events' events-read.sh
Writes:    nothing
Stdout:    nothing
Exit:
  0  the agent was assigned a job here
  2  refused, nothing changed; the reason is on stderr
  5  the agent was assigned no job here
USAGE
}

prog='agent-had-job.sh'
refuse() {
	printf '%s: %s\n' "${prog}" "$1" >&2
	exit 2
}

effort='' agent=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--effort | --agent)
			[ $# -ge 2 ] && [ -n "$2" ] || refuse "$1 needs a value"
			case $1 in --effort) effort=$2 ;; --agent) agent=$2 ;; *) ;; esac
			shift 2 ;;
		*) refuse "unknown argument $1; try --help" ;;
	esac
done
command -v jq >/dev/null 2>&1 || refuse 'jq not found'
case ${effort} in /*) ;; *) refuse '--effort must be an absolute folder' ;; esac
[ -d "${effort}/events" ] || refuse "${effort} is not an effort folder"
[ -n "${agent}" ] || refuse 'give --agent'

self=$0
case ${self} in /*) ;; *) self="$(pwd)/${self}" ;; esac
reader="${self%/*/*/*/*}/crucible-events/scripts/internal/events-read.sh"
[ -f "${reader}" ] || refuse "crucible-events isn't beside this skill (expected ${reader}); install first"
events=$(sh "${reader}" --effort "${effort}" --type job.assigned) || exit 2
printf '%s\n' "${events}" | jq -e --arg agent "${agent}" 'any(.[]; .body.agent == $agent)' >/dev/null || exit 5
