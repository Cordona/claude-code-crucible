#!/usr/bin/env sh
# Prints the facts the reviewer's stamps need: the IDs and keys taken so
# far, and each thread's source. Run under the stop hook's lock, so it reads
# only what the stamps need.
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh reviewer-stamp-facts.sh --effort FOLDER --job FILE

Run by agent-submission's stamp step, under the stop hook's lock, as the
stamps entry of the reviewer's submissions/<kind>.json names it; not for
main to call.

Options:
  --effort FOLDER  the effort's folder, absolute
  --job FILE       the job, as jobs-track's job-of.sh prints it
Reads:     the effort's events and pinned reports, through jobs-track's
           events-view.sh, each submission's job through job-of.sh
Writes:    nothing
Stdout:    one JSON object {ids, keys, threads}:
             ids      the finding IDs taken in the job's iteration on its
                      tree, by the reviewer's review and external-review
                      jobs; [] for a job with no iteration
             keys     the challenge IDs taken in the effort
             threads  [{id, source, role}] of the fetch the job's review
                      ref names, of the comment that opened each; []
Exit:
  0  printed
  2  refused, nothing printed; the reason is on stderr
USAGE
}

prog='reviewer-stamp-facts.sh'
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
[ -d "${effort}/events" ] || refuse "${effort} is not an effort folder"
[ -n "${job}" ] && [ -f "${job}" ] || refuse '--job must be a file holding job-of.sh output'

self=$0
case ${self} in /*) ;; *) self="$(pwd)/${self}" ;; esac
skills=${self%/*/*/*/*}
view="${skills}/jobs-track/scripts/internal/events-view.sh"
job_of="${skills}/jobs-track/scripts/internal/job-of.sh"
for need in "${view}" "${job_of}"; do
	[ -f "${need}" ] || refuse "jobs-track isn't beside this skill (expected ${need}); install first"
done

work=$(mktemp -d "${TMPDIR:-/tmp}/reviewer-stamp-facts.XXXXXX") || refuse 'mktemp could not make a work folder'
trap 'rm -rf -- "${work}"' EXIT
sh "${view}" --effort "${effort}" >"${work}/events" || refuse 'events-view.sh refused the effort; a human must look'

# The finding IDs taken in the job's iteration on its tree, from the pinned
# reports of the reviewer's own review and external-review jobs.
: >"${work}/ids.txt"
if jq -e 'has("iteration")' "${job}" >/dev/null; then
	jq -r '.[] | select((.report | type) == "object")
		| ([.report.findings // [] | .[] | .id? | strings] + [.report.items // [] | .[] | .finding?.id? | strings]) as $ids
		| select($ids | length > 0) | "\(.body.job)\t\($ids | join(" "))"' "${work}/events" >"${work}/taken"
	while IFS="$(printf '\t')" read -r seq ids; do
		sh "${job_of}" --effort "${effort}" --job "${seq}" </dev/null >"${work}/one" 2>/dev/null || continue
		jq -e --slurpfile me "${job}" '.tree == $me[0].tree and .iteration == $me[0].iteration
			and (.kind == "review" or .kind == "external-review")' "${work}/one" >/dev/null || continue
		printf '%s\n' "${ids}" | tr ' ' '\n' >>"${work}/ids.txt"
	done <"${work}/taken"
fi

jq -L "${skills}" --slurpfile job "${job}" 'include "code-reviewer/scripts/lib/review-threads";
	rt_threads($job[0]).threads // []' "${work}/events" >"${work}/threads" \
	|| refuse "the job's review ref names no fetched threads"

jq -n --rawfile ids "${work}/ids.txt" --slurpfile events "${work}/events" --slurpfile threads "${work}/threads" '
	{ids: ($ids | split("\n") | map(select(length > 0)) | unique),
	 keys: [$events[0][] | .report.challenges? // [] | .[] | .id? | strings] | unique,
	 threads: $threads[0]}'
