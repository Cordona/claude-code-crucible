#!/usr/bin/env sh
# A step of submit-agent-work.sh: fills in what only a script knows, by the
# stamp rules the agent's submissions/<kind>.json names.
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh report-stamp.sh --effort FOLDER --job FILE

Run by submit-agent-work.sh and recover-submission.sh, under the stop
hook's lock; not for main to call. When the job's submissions/<kind>.json
names stamps {rules, def, facts?}, runs that jq def on {report, job, facts}
(facts from the stamps' own facts script, when it names one; {} otherwise)
and writes what it prints back as the report. A def that stops with an
error, rather than guess, is a fault for the human, its message passed on.
A submissions file with no stamps leaves the report as it is.
Stamp rules must leave a report they already stamped as it is:
recover-submission.sh --finish stamps again one stamped but not pinned.

Options:
  --effort FOLDER  the effort's folder, absolute
  --job FILE       the job, as agent-jobs' job-of.sh prints it
Writes:    the report, stamped
Stdout:    nothing
Exit:
  0  stamped, or nothing to stamp
  2  refused, nothing changed; the reason is on stderr (a wrong stamps
     entry or a missing rules module is an install fault)
  4  the facts script failed, or the stamp rules stopped; the reason is
     on stderr
USAGE
}

prog='report-stamp.sh'
refuse() {
	printf '%s: %s\n' "${prog}" "$1" >&2
	exit 2
}

effort='' job=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--effort | --job)
			[ $# -ge 2 ] && [ -n "$2" ] || refuse "$1 needs a value"
			case $1 in --effort) effort=$2 ;; --job) job=$2 ;; *) ;; esac
			shift 2 ;;
		*) refuse "unknown argument $1; try --help" ;;
	esac
done
command -v jq >/dev/null 2>&1 || refuse 'jq not found'
case ${effort} in /*) ;; *) refuse '--effort must be an absolute folder' ;; esac
[ -n "${job}" ] && [ -f "${job}" ] || refuse '--job must be a file holding job-of.sh output'

self=$0
case ${self} in /*) ;; *) self="$(pwd)/${self}" ;; esac
skills=${self%/*/*/*/*/*}
agent_type=$(jq -r '.agent_type' "${job}")
kind=$(jq -r '.kind' "${job}")
report="${effort}/$(jq -r '.report' "${job}")"
submission="${skills}/${agent_type}/submissions/${kind}.json"
[ -f "${submission}" ] || refuse "${agent_type} has no submissions/${kind}.json"
jq -e 'has("stamps")' "${submission}" >/dev/null 2>&1 || exit 0
rules=$(jq -r '.stamps.rules // empty' "${submission}")
def=$(jq -r '.stamps.def // empty' "${submission}")
shape="${agent_type}/submissions/${kind}.json's stamps is not {rules: <component>/scripts/lib/<module>, def}"
printf '%s\n' "${rules}" | grep -Eqx '[a-z][a-z0-9-]*/scripts/lib/[a-z][a-z0-9-]*' || refuse "${shape}"
printf '%s\n' "${def}" | grep -Eqx '[a-z][a-z0-9_]*' || refuse "${shape}"
[ -f "${skills}/${rules}.jq" ] || refuse "${agent_type}/submissions/${kind}.json names the stamp rules ${rules}, which aren't installed"

work=$(mktemp -d "${TMPDIR:-/tmp}/report-stamp.XXXXXX") || refuse 'mktemp could not make a work folder'
trap 'rm -rf -- "${work}"' EXIT
facts=$(jq -r '.stamps.facts // empty' "${submission}")
printf '{}\n' >"${work}/facts"
if [ -n "${facts}" ]; then
	[ -f "${skills}/${facts}" ] || refuse "${agent_type}/submissions/${kind}.json names the facts script ${facts}, which isn't installed"
	sh "${skills}/${facts}" --effort "${effort}" --job "${job}" >"${work}/facts" 2>"${work}/said" \
		|| { printf '%s: %s failed: %s\n' "${prog}" "${facts##*/}" "$(head -n 1 "${work}/said" || true)" >&2; exit 4; }
fi
jq -n -L "${skills}" --slurpfile report "${report}" --slurpfile job "${job}" --slurpfile facts "${work}/facts" \
	"include \"${rules}\"; {report: \$report[0], job: \$job[0], facts: \$facts[0]} | ${def}" >"${work}/stamped" 2>"${work}/said" \
	|| { printf '%s: %s\n' "${prog}" "$(sed -n 's/^jq: error ([^)]*): //p' "${work}/said" | head -n 1 || true)" >&2; exit 4; }
jq -e 'type == "object"' "${work}/stamped" >/dev/null 2>&1 || { printf '%s: the stamp rules printed no report\n' "${prog}" >&2; exit 4; }
temp=$(mktemp "${report%/*}/.report.XXXXXX") || refuse "could not write beside ${report}"
if ! cp -- "${work}/stamped" "${temp}" || ! mv -f -- "${temp}" "${report}"; then
	rm -f -- "${temp}"
	refuse "could not replace ${report} with its stamped form"
fi
