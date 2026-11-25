#!/usr/bin/env sh
# Prints the facts a reviewer's report check needs beyond the report and
# the tree's state, read from events and git only; and refuses a job whose
# earlier findings the reviewer can't judge.
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh reviewer-facts.sh --effort FOLDER --job FILE

Run by agent-submission's check step, as the reviewer's
submissions/<kind>.json names it; not for main to call. The stamps' facts
are reviewer-stamp-facts.sh's.

Options:
  --effort FOLDER  the effort's folder, absolute
  --job FILE       the job, as agent-jobs' job-of.sh prints it
Reads:     the effort's events and pinned reports, through agent-jobs'
           events-view.sh; the job's tree and its base..head, through git;
           the job's threads file
Writes:    nothing
Stdout:    one JSON object {cover, added, removed, files, plan, threads}:
             cover    the job's cover, or the files base..head changes;
                      null with no base and head
             added    {path: [line...]}, the lines base..head adds or
                      changes at head; removed the same at base; null with
                      no base and head
             files    the tree's files, tracked and untracked, not ignored
             plan     {ids, files} of the plan the job names: its B-, T- and
                      N- IDs, and the files its tests and support name; null
             threads  [{id, source}] from the job's threads file; []
Exit:
  0  printed
  2  refused, nothing printed; the reason is on stderr: a job fault, as
     earlier findings whose fixer's status isn't done, partly or declined
USAGE
}

prog='reviewer-facts.sh'
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
view="${skills}/agent-jobs/scripts/internal/events-view.sh"
[ -f "${view}" ] || refuse "agent-jobs isn't beside this skill (expected ${view}); install first"
tree=$(jq -r '.tree // empty' "${job}")
case ${tree} in /*) ;; *) refuse '--job names no absolute tree' ;; esac
[ -d "${tree}" ] || refuse "the job's tree ${tree} is not a folder"

work=$(mktemp -d "${TMPDIR:-/tmp}/reviewer-facts.XXXXXX") || refuse 'mktemp could not make a work folder'
trap 'rm -rf -- "${work}"' EXIT
sh "${view}" --effort "${effort}" >"${work}/events" || refuse 'events-view.sh refused the effort; a human must look'

# The earlier findings a re-review judges: each with its fixer's status.
bad=$(jq -r '[.earlier // [] | .[] | select((.status | IN("done", "partly", "declined")) | not) | .id] | join(", ")' "${job}")
[ -z "${bad}" ] || refuse "the job's earlier findings ${bad} have no fixer's status of done, partly or declined"

# The changed lines of base..head: one "<path>\t+|-\t<line>" per line.
base=$(jq -r '.base // empty' "${job}")
head=$(jq -r '.head // empty' "${job}")
printf 'null\n' >"${work}/cover"
: >"${work}/lines"
if [ -n "${base}" ] && [ -n "${head}" ]; then
	git -C "${tree}" diff --name-only "${base}" "${head}" </dev/null >"${work}/names" || refuse "git could not diff ${base}..${head}"
	jq --rawfile names "${work}/names" '.cover // ($names | split("\n") | map(select(length > 0)))' "${job}" >"${work}/cover"
	git -C "${tree}" diff -U0 --no-color "${base}" "${head}" </dev/null | awk '
		/^--- / { old = substr($0, 5); sub(/^a\//, "", old); next }
		/^\+\+\+ / { new = substr($0, 5); sub(/^b\//, "", new); next }
		/^@@ / {
			split($2, o, ","); split($3, n, ",")
			os = substr(o[1], 2) + 0; oc = (o[2] == "" ? 1 : o[2] + 0)
			ns = substr(n[1], 2) + 0; nc = (n[2] == "" ? 1 : n[2] + 0)
			for (i = 0; i < oc; i++) printf "%s\t-\t%d\n", old, os + i
			for (i = 0; i < nc; i++) printf "%s\t+\t%d\n", new, ns + i
		}' >"${work}/lines"
fi

git -C "${tree}" ls-files -co --exclude-standard </dev/null >"${work}/files" || refuse "git could not list the tree ${tree}"

# The plan the job names, from its pinned report.
jq --slurpfile job "${job}" '$job[0].plan as $p | if $p == null then null
	else [.[] | select(.seq == $p) | .report] | first
		| if . == null then null
		  else {ids: [(.behaviours, .tests, .untested) | arrays[] | .id? | strings],
			files: [(.tests, .support) | arrays[] | .file? | strings] | unique} end end' "${work}/events" >"${work}/plan" \
	|| refuse 'jq could not read the plan'

# The job's threads, fetched by the remote's script; their text is untrusted
# and never read here.
printf '[]\n' >"${work}/threads"
threads=$(jq -r '.threads // empty' "${job}")
if [ -n "${threads}" ]; then
	jq '[.threads[] | {id, source}]' "${threads}" >"${work}/threads" 2>/dev/null || refuse "the threads file ${threads} is not {threads: [{id, source, ...}]}"
fi

jq -n --slurpfile cover "${work}/cover" \
	--rawfile lines "${work}/lines" --rawfile files "${work}/files" --slurpfile plan "${work}/plan" --slurpfile threads "${work}/threads" '
	def changed($side): $lines | split("\n") | map(select(length > 0) | split("\t") | select(.[1] == $side))
		| group_by(.[0]) | map({key: .[0][0], value: map(.[2] | tonumber)}) | from_entries;
	{cover: $cover[0],
	 added: (if $cover[0] == null then null else changed("+") end),
	 removed: (if $cover[0] == null then null else changed("-") end),
	 files: ($files | split("\n") | map(select(length > 0))),
	 plan: $plan[0],
	 threads: $threads[0]}'
