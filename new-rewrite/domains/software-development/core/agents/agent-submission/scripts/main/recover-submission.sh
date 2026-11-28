#!/usr/bin/env sh
# Finishes the hand-in of a stalled job, or gives it up.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh recover-submission.sh --effort FOLDER --job SEQ (--finish | --give-up)

Settles a stalled job: its report was accepted, but the stop hook's hand-in
didn't finish. Run it when the stop hook's message names this job.

Options:
  --effort FOLDER  the effort's folder, absolute
  --job SEQ        the stalled job's seq
  --finish         hands it in: stamps and pins the report unless pinned,
                   makes the working commit unless one carries the job's
                   Job trailer, then writes the job's submission event
  --give-up        ends the job: job.ended fault, at the stalled step
Reads:     CRUCIBLE_STOP_LOCK_SECONDS, a shorter wait for the stop lock
Writes:    with --finish, the report, the commit and the submission event;
           with --give-up, one job.ended event
Stdout:    the event's absolute path
Exit:
  0  written
  2  refused, nothing written; the reason is on stderr
  3  the job already has its submission: nothing to finish
  4  a hand-in step failed, its reason on stderr; the steps before stay done
  6  a lock stayed held: rerun
USAGE
}

prog='recover-submission.sh'
refuse() {
	printf '%s: %s\n' "${prog}" "$1" >&2
	exit 2
}
failed() {
	printf '%s: %s\n' "${prog}" "$1" >&2
	exit 4
}

effort='' seq='' mode=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--finish | --give-up) [ -z "${mode}" ] || refuse 'give --finish or --give-up, not both'; mode=${1#--}; shift ;;
		--effort | --job)
			[ $# -ge 2 ] && [ -n "$2" ] || refuse "$1 needs a value"
			case $1 in --effort) effort=$2 ;; --job) seq=$2 ;; *) ;; esac
			shift 2 ;;
		*) refuse "unknown argument $1; try --help" ;;
	esac
done
command -v jq >/dev/null 2>&1 || refuse 'jq not found'
case ${effort} in /*) ;; *) refuse '--effort must be an absolute folder' ;; esac
[ -d "${effort}/events" ] || refuse "${effort} is not an effort folder"
printf '%s\n' "${seq}" | grep -Eqx '[1-9][0-9]*' || refuse '--job must be a whole number from 1'
[ -n "${mode}" ] || refuse 'give --finish or --give-up'

self=$0
case ${self} in /*) ;; *) self="$(pwd)/${self}" ;; esac
skills=${self%/*/*/*/*}
job_of="${skills}/jobs-track/scripts/internal/job-of.sh"
reader="${skills}/crucible-events/scripts/internal/events-read.sh"
writer="${skills}/crucible-events/scripts/internal/event-write.sh"
report_hash="${skills}/jobs-track/scripts/internal/report-hash.sh"
for need in "${job_of}" "${reader}" "${writer}" "${report_hash}"; do
	[ -f "${need}" ] || refuse "a neighbour isn't beside this skill (expected ${need}); install first"
done
lib="$(dirname -- "$0")/../lib"
# The stop hook's steps, by a path with no .., since each finds its
# neighbours from its own path.
steps=$(cd -- "$(dirname -- "$0")/../../hooks/subagent-stop/steps" && pwd) || refuse "the stop hook's steps are not beside this script"
. "$(dirname -- "$0")/../lib/stop-lock.sh"
. "$(dirname -- "$0")/../lib/trailers.sh"

work='' lock=''
trap '[ -z "${lock}" ] || sl_release "${lock}"; rm -rf -- ${work:+"${work}"}' EXIT
work=$(mktemp -d "${TMPDIR:-/tmp}/recover-submission.XXXXXX") || refuse 'mktemp could not make a work folder'

# The job, stalled.
rc=0
sh "${job_of}" --effort "${effort}" --job "${seq}" >"${work}/job" 2>"${work}/said" || rc=$?
[ "${rc}" -eq 0 ] || refuse "$(head -n 1 "${work}/said" || true)"
state=$(jq -r '.state' "${work}/job")
case ${state} in
	stalled) ;;
	submitted) printf '%s: job %s already has its submission\n' "${prog}" "${seq}" >&2; exit 3 ;;
	*) refuse "job ${seq} is ${state}; only a stalled job is finished or given up" ;;
esac

if [ "${mode}" = give-up ]; then
	sh "${reader}" --effort "${effort}" --type job.stalled >"${work}/stalled" || refuse 'the effort'"'"'s events could not be read'
	jq -L "${lib}" --slurpfile stalled "${work}/stalled" --argjson job "${seq}" 'include "stamps";
		([$stalled[0][] | select(.body.job == $job)] | first | .body) as $s
		| st_stamps + {reason: "fault", step: $s.step, fault: $s.fault}' "${work}/job" >"${work}/body" \
		|| refuse 'the job or its job.stalled could not be read'
	sh "${writer}" --effort "${effort}" --type job.ended --by "${prog}" --body-file "${work}/body"
	exit 0
fi

agent_type=$(jq -r '.agent_type' "${work}/job")
kind=$(jq -r '.kind' "${work}/job")
tree=$(jq -r '.tree' "${work}/job")
name=$(jq -r '.name' "${work}/job")
submission="${skills}/${agent_type}/submissions/${kind}.json"
event=$(jq -r '.event // empty' "${submission}" 2>/dev/null) || event=''
[ -n "${event}" ] || refuse "${agent_type} has no submissions/${kind}.json naming its event"
wants_commit=$(jq -r '.commit' "${submission}")
report="${effort}/$(jq -r '.report' "${work}/job")"
[ -f "${report}" ] && [ ! -L "${report}" ] || refuse "the report ${report} is not there"

mkdir -p "${effort}/stops"
# shellcheck disable=SC2310 # sl_take is a retry loop called for its status
sl_take "${effort}/stops/.lock" || { printf '%s: the stop lock stayed held\n' "${prog}" >&2; exit 6; }
lock="${effort}/stops/.lock"

# The stamp and the pin, unless the report is pinned already.
writable=$(find "${report}" -prune -perm -200) || refuse "${report} can't be read"
if [ -n "${writable}" ]; then
	sh "${steps}/report-stamp.sh" --effort "${effort}" --job "${work}/job" 2>"${work}/said" \
		|| failed "the report could not be stamped: $(head -n 1 "${work}/said" || true)"
	sha256=$(sh "${steps}/report-pin.sh" --report "${report}" 2>"${work}/said") \
		|| failed "the report could not be pinned: $(head -n 1 "${work}/said" || true)"
else
	sha256=$(sh "${report_hash}" --report "${report}") || refuse "report-hash.sh could not hash ${report}"
fi

# The working commit: the one carrying the job's Job trailer, or a new one.
commit=''
if [ "${wants_commit}" = true ]; then
	effort_name=$(cd -- "${effort}" && pwd -P) || refuse "${effort} can't be read"
	git -C "${tree}" log --format=%H -E --grep="^Job: ${seq} ${name}\$" HEAD -- >"${work}/candidates" 2>/dev/null \
		|| refuse "git could not read the history of ${tree}"
	while IFS= read -r candidate; do
		# shellcheck disable=SC2310 # tr_read is one git read and one jq call, whose failure skips the candidate
		tr_read "${tree}" "${candidate}" >"${work}/trailers" || continue
		jq -e --arg effort "${effort_name##*/}" --slurpfile job "${work}/job" '.effort == $effort and .job == $job[0].job
			and .kind == $job[0].kind' "${work}/trailers" >/dev/null 2>&1 || continue
		commit=${candidate}
		break
	done <"${work}/candidates"
	if [ -z "${commit}" ]; then
		commit=$(sh "${steps}/working-commit.sh" --effort "${effort}" --job "${work}/job" 2>"${work}/said") \
			|| failed "the working commit failed: $(head -n 1 "${work}/said" || true)"
	fi
fi

# The event the job's agent submits.
jq -L "${lib}" --arg sha256 "${sha256}" --arg commit "${commit}" \
	'include "stamps"; st_submission($sha256; $commit)' "${work}/job" >"${work}/body" || refuse 'the job could not be read'
sh "${writer}" --effort "${effort}" --type "${event}" --by "${prog}" --body-file "${work}/body"
