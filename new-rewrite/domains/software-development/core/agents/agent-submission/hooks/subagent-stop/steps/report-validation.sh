#!/usr/bin/env sh
# A step of submit-agent-work.sh: checks the stopping agent's report by the
# rules its submissions/<kind>.json names.
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh report-validation.sh --effort FOLDER --job FILE

Run by submit-agent-work.sh; not for main to call.
Checks the job's report by the rules, problems def and facts script that
the agent's submissions/<kind>.json names.

Options:
  --effort FOLDER  the effort's folder, absolute
  --job FILE       the job, as job-of.sh prints it
Writes:    on exit 0, the report, pruned
Stdout:    on exit 1, one repair line per problem, for the agent
Exit:
  0  accepted
  1  refused: the lines say what to repair
  2  refused, nothing changed; the reason is on stderr: a missing or wrong
     submission file, rules module or facts script, an install fault
  4  the facts script or the check failed to run; the reason is on stderr
USAGE
}

prog='report-validation.sh'
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
report=$(jq -r '.report' "${job}")
submission="${skills}/${agent_type}/submissions/${kind}.json"
[ -f "${submission}" ] || refuse "${agent_type} has no submissions/${kind}.json"
rules=$(jq -r '.rules // empty' "${submission}" 2>/dev/null) || rules=''
problems=$(jq -r '.problems // empty' "${submission}" 2>/dev/null) || problems=''
facts=$(jq -r '.facts // empty' "${submission}" 2>/dev/null) || facts=''
[ -n "${rules}" ] && [ -n "${problems}" ] || refuse "${agent_type}/submissions/${kind}.json names no rules and problems"
[ -f "${skills}/${rules}.jq" ] || refuse "${agent_type}/submissions/${kind}.json names the rules ${rules}, which aren't installed"
check="${skills}/agent-submission/scripts/internal/report-check.sh"
[ -f "${check}" ] || refuse "agent-submission's report-check.sh is not installed (expected ${check})"

work=$(mktemp -d "${TMPDIR:-/tmp}/report-validation.XXXXXX") || refuse 'mktemp could not make a work folder'
trap 'rm -rf -- "${work}"' EXIT
set -- --effort "${effort}" --report "${effort}/${report}" --job "${job}" --rules "${rules}" --problems "${problems}"
if [ -n "${facts}" ]; then
	printf '%s\n' "${facts}" | grep -Eqx '[a-z][a-z0-9-]*/scripts/internal/[a-z][a-z0-9-]*\.sh' \
		|| refuse "${agent_type}/submissions/${kind}.json names facts ${facts}, not <component>/scripts/internal/<script>.sh"
	[ -f "${skills}/${facts}" ] || refuse "${agent_type}/submissions/${kind}.json names the facts script ${facts}, which isn't installed"
	sh "${skills}/${facts}" --effort "${effort}" --job "${job}" >"${work}/facts" 2>"${work}/said" \
		|| { printf '%s: %s failed: %s\n' "${prog}" "${facts##*/}" "$(head -n 1 "${work}/said" || true)" >&2; exit 4; }
	set -- "$@" --facts "${work}/facts"
fi
rc=0
sh "${check}" "$@" || rc=$?
case ${rc} in 0 | 1) exit "${rc}" ;; *) exit 4 ;; esac
