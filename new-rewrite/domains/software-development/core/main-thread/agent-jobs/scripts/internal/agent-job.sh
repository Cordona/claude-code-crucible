#!/usr/bin/env sh
# Finds an agent's open job across every effort: the one search the stop
# hook and the write scope share.
# shellcheck disable=SC2312 # a read inside a message only shortens the message
set -eu

usage() {
	cat <<'USAGE'
usage: sh agent-job.sh --agent ID [--wait SECONDS]

Run by component scripts and hooks; not for main to call.
Finds the job agent ID is working on, in any effort.

Options:
  --agent ID      the agent's id: letters, digits, ., _ or -
  --wait SECONDS  for an agent never assigned a job, look again once a
                  second up to SECONDS times; 0 to 30, default 0
Reads:     CRUCIBLE_HOME, default $HOME/.crucible
Writes:    nothing
Stdout:    on exit 0, one JSON line {effort, job}: the effort's folder,
           absolute; the job as job-of.sh prints it
Exit:
  0  found
  2  refused, or an effort's job could not be read; the reason is on stderr
  4  the agent was never assigned a job, in any effort
  5  the agent had a job, and has none open now
USAGE
}

prog='agent-job.sh'
refuse() {
	printf '%s: %s\n' "${prog}" "$1" >&2
	exit 2
}

agent='' wait=0
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--agent | --wait)
			[ $# -ge 2 ] && [ -n "$2" ] || refuse "$1 needs a value"
			case $1 in --agent) agent=$2 ;; --wait) wait=$2 ;; *) ;; esac
			shift 2 ;;
		*) refuse "unknown argument $1; try --help" ;;
	esac
done
command -v jq >/dev/null 2>&1 || refuse 'jq not found'
case ${agent} in '' | *[!A-Za-z0-9._-]*) refuse '--agent must be an agent id: letters, digits, ., _ or -' ;; *) ;; esac
printf '%s\n' "${wait}" | grep -Eqx '[0-9]|[12][0-9]|30' || refuse '--wait must be a whole number of seconds, 0 to 30'

here=$(dirname -- "$0")
job_of="${here}/job-of.sh"
had_job="${here}/agent-had-job.sh"

# One pass over the efforts: prints {effort, job} and returns 0, or returns
# 5 when the agent had a job somewhere, 4 when it had none.
look() {
	lk_seen=''
	for candidate in "${CRUCIBLE_HOME:-${HOME}/.crucible}"/efforts/*; do
		[ -d "${candidate}/events" ] || continue
		grep -rlqF -- "${agent}" "${candidate}/events" 2>/dev/null || continue
		# An assignment written between job-of.sh's read and agent-had-job.sh's
		# shows as a job had: job-of.sh is asked once more before that is
		# believed.
		for lk_pass in first again; do
			lk_rc=0
			lk_job=$(sh "${job_of}" --effort "${candidate}" --agent "${agent}" 2>"${lk_said}") || lk_rc=$?
			case ${lk_rc} in
				0) jq -cn --arg effort "${candidate}" --argjson job "${lk_job}" '{effort: $effort, job: $job}'; return 0 ;;
				5) [ "${lk_pass}" = again ] || sh "${had_job}" --effort "${candidate}" --agent "${agent}" 2>/dev/null || break
					[ "${lk_pass}" = first ] || lk_seen=1 ;;
				*) refuse "the job of agent ${agent} could not be read in ${candidate}: $(head -n 1 "${lk_said}")" ;;
			esac
		done
	done
	[ -z "${lk_seen}" ] || return 5
	return 4
}

lk_said=$(mktemp "${TMPDIR:-/tmp}/agent-job.XXXXXX") || refuse 'mktemp could not make a temp file'
trap 'rm -f -- "${lk_said}"' EXIT
tries=0
while :; do
	rc=0
	# shellcheck disable=SC2310 # look's status is its answer: found, between jobs, never assigned
	look || rc=$?
	[ "${rc}" -eq 4 ] && [ "${tries}" -lt "${wait}" ] || exit "${rc}"
	tries=$((tries + 1))
	sleep 1
done
