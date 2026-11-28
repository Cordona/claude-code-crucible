#!/usr/bin/env sh
# Prints the facts a tester's report check needs beyond the report and the
# tree's state: the plan the job names, the files the build under test
# changed, and the files the job changed.
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh tester-facts.sh --effort FOLDER --job FILE

Run by agent-submission's report check, as the tester's <kind>-submission.json
names it; not for main to call.

Options:
  --effort FOLDER  the effort's folder, absolute
  --job FILE       the job, as jobs-track's job-of.sh prints it
Reads:     the effort's events and pinned reports, through jobs-track's
           events-view.sh; each submission's job, through job-of.sh; the
           commits and the tree, through git
Writes:    nothing
Stdout:    one JSON object {plan, challenges, build_files, changed}: plan
           the pinned report of the job's plan ref, null with none;
           challenges those of its challenge ref's pinned report, [] with none;
           build_files every file a commit of the build under test changed:
           the commits on the job's tree in its iteration of the builder's
           build and build-fix jobs; changed every path with an uncommitted
           change in the tree, untracked too
Exit:
  0  printed
  2  refused, nothing printed; the reason is on stderr: a job fault, as a
     challenge that asks for no add, change, remove or prove
USAGE
}

prog='tester-facts.sh'
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
command -v git >/dev/null 2>&1 || refuse 'git not found'
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
tree=$(jq -r '.tree // empty' "${job}")
case ${tree} in /*) ;; *) refuse '--job names no absolute tree' ;; esac
[ -d "${tree}" ] || refuse "the job's tree ${tree} is not a folder"
iteration=$(jq -r '.iteration' "${job}")

work=$(mktemp -d "${TMPDIR:-/tmp}/tester-facts.XXXXXX") || refuse 'mktemp could not make a work folder'
trap 'rm -rf -- "${work}"' EXIT
sh "${view}" --effort "${effort}" >"${work}/events" || refuse 'events-view.sh refused the effort; a human must look'

# The plan the job's plan ref names, and the challenges its challenge ref
# names: each from its event's pinned report.
jq --slurpfile job "${job}" '$job[0].refs.plan as $p | if $p == null then null
	else [.[] | select(.seq == $p) | .report] | first end' "${work}/events" >"${work}/plan" \
	|| refuse 'jq could not read the plan'
jq --slurpfile job "${job}" '$job[0].refs.challenge as $c | if $c == null then []
	else [.[] | select(.seq == $c) | .report.challenges // []] | first // [] end' "${work}/events" >"${work}/challenges" \
	|| refuse 'jq could not read the challenges'
# The challenges a rework answers: each asks to add, change, remove or prove.
bad=$(jq -r '[.[] | select((.ask | IN("add", "change", "remove", "prove")) | not) | .id] | join(", ")' "${work}/challenges")
[ -z "${bad}" ] || refuse "the job's challenges ${bad} ask nothing a rework can apply: add, change, remove or prove"

# The build under test: the commits of the submissions on the job's tree in
# its iteration by build and build-fix jobs, the builder's kinds.
jq -r '.[] | select((.body.report | type) == "object" and (.body.commit | type) == "string") | "\(.body.job) \(.body.commit)"' \
	"${work}/events" >"${work}/submissions" || refuse 'jq could not list the submissions'
: >"${work}/build-files"
while read -r seq commit; do
	sh "${job_of}" --effort "${effort}" --job "${seq}" </dev/null >"${work}/one" 2>/dev/null || continue
	jq -e --arg tree "${tree}" --argjson it "${iteration}" \
		'.tree == $tree and .iteration == $it and (.kind == "build" or .kind == "build-fix")' "${work}/one" >/dev/null || continue
	git -C "${tree}" diff-tree --no-commit-id --name-only -r "${commit}" </dev/null >>"${work}/build-files" \
		|| refuse "git could not read the commit ${commit}"
done <"${work}/submissions"

# The job's own changes, as on disk: one path per entry; a rename's second
# entry, its old path, is left out.
git -C "${tree}" -c core.fsmonitor=false status --porcelain -z --untracked-files=all >"${work}/status" \
	|| refuse "git could not read the tree ${tree}"
tr '\000' '\n' <"${work}/status" | awk 'skip { skip = 0; next } { print substr($0, 4); if ($0 ~ /^[RC]/) skip = 1 }' >"${work}/changed"

jq -n --slurpfile plan "${work}/plan" --slurpfile challenges "${work}/challenges" --rawfile build "${work}/build-files" --rawfile changed "${work}/changed" '
	def lines: split("\n") | map(select(length > 0)) | unique;
	{plan: $plan[0], challenges: $challenges[0], build_files: ($build | lines), changed: ($changed | lines)}'
