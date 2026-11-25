#!/usr/bin/env sh
# Checks an agent's report against its job by the rules of one jq module:
# reads the report, prunes its empty lists and objects, checks its locations
# against the tree, and prints the module's repair lines.
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh report-check.sh --effort FOLDER --report FILE --job FILE
                          --rules MODULE --problems DEF [--facts FILE]

Run by the stop hook's report-validation.sh step; not for main to call.
Checks a report before its pin: first every at in it, at any depth (path,
path:N, path:N-M at the tree; -path:N at the job's base; @<where>:path...
not looked up), then the agent's rules.

Options:
  --effort FOLDER  the effort's folder, absolute
  --report FILE    the report, <effort>/reports/<kind>/<job seq>.json
  --job FILE       the job, as job-of.sh prints it
  --rules MODULE   the agent's rules: <component>/scripts/lib/<module>
  --problems DEF   its def printing one repair line per problem, given
                   {report, job, tree, facts}
  --facts FILE     one JSON object given to the rules as facts; default {}
Writes:    on exit 0, the report, its empty lists and objects removed
Stdout:    on exit 1, one repair line per problem, the locations' first
Exit:
  0  accepted
  1  refused: the lines say what to repair
  2  refused, nothing changed; the reason is on stderr
USAGE
}

prog='report-check.sh'
refuse() {
	printf '%s: %s\n' "${prog}" "$1" >&2
	exit 2
}

# Every at in the report, at any depth, a location or a list of them:
# well formed, naming a file, the line within it. One repair line per
# problem, named by where the at is, as findings[1].at, ending with what to
# write; a noticed entry's at, the one an agent may leave out, also says so.
# Input {report, lines, base}: lines as below; base whether the job names one.
# shellcheck disable=SC2016 # jq's program, single-quoted on purpose
locations_jq='def name: reduce .[] as $k (""; if ($k | type) == "number" then . + "[\($k)]" elif . == "" then $k else . + "." + $k end);
	.lines as $lines | .base as $base
	| .report | paths(type != "null") as $p | select($p[-1] == "at") | ($p | name) as $w
	| ("; write it as a file and line, such as `bin/x.sh:42`, or a JSON array of them"
		+ (if ($p | length) == 3 and $p[0] == "noticed" and ($p[1] | type) == "number"
		   then ", or leave `at` out when it isn'"'"'t in a file" else "" end)) as $write
	| getpath($p) | (if type == "array" then .[] else . end) as $at
	| if ($at | type) == "string" and ($at | startswith("@")) and ($at | test("^@[^:\\s]+:[^:\\s]+")) then empty
	  else (($at | strings | capture("^(?<neg>-?)(?<file>[^:@\\s-][^:]*)(:(?<a>[1-9][0-9]*)(-(?<b>[1-9][0-9]*))?)?$")) // null) as $l
		| if $l == null then "\($w) \($at | tojson) is not a location\($write)"
		  elif $l.neg == "-" and ($base | not) then "\($w) \($at): this job has no base to read a removed line at\($write)"
		  else ($lines[$l.neg + $l.file] // -1) as $count | (($l.b // $l.a // "0") | tonumber) as $line
			| if $count < 0 then "\($w) \($at) names no file \(if $l.neg == "-" then "at the job'"'"'s base" else "in the tree" end)\($write)"
			  elif $line > $count then "\($w) \($at) is past the end of the file (\($count) lines)\($write)"
			  else empty end
		  end
	  end'

# The report's empty lists and objects removed, at any depth inside objects.
# shellcheck disable=SC2016 # jq's program, single-quoted on purpose
prune_jq='def prune: if type == "object" then with_entries(.value |= prune | select(.value != [] and .value != {}))
	elif type == "array" then map(prune) else . end; prune'

effort='' report='' job='' rules='' problems='' facts=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--effort | --report | --job | --rules | --problems | --facts)
			[ $# -ge 2 ] && [ -n "$2" ] || refuse "$1 needs a value"
			case $1 in
				--effort) effort=$2 ;; --report) report=$2 ;; --job) job=$2 ;;
				--rules) rules=$2 ;; --problems) problems=$2 ;; --facts) facts=$2 ;; *) ;;
			esac
			shift 2 ;;
		*) refuse "unknown argument $1; try --help" ;;
	esac
done
command -v jq >/dev/null 2>&1 || refuse 'jq not found'
case ${effort} in /*) ;; *) refuse '--effort must be an absolute folder' ;; esac
[ -d "${effort}/events" ] || refuse "${effort} is not an effort folder"
case ${report} in /*) ;; *) refuse '--report must be an absolute file' ;; esac
[ -n "${job}" ] && [ -f "${job}" ] || refuse '--job must be a file holding job-of.sh output'
printf '%s\n' "${rules}" | grep -Eqx '[a-z][a-z0-9-]*/scripts/lib/[a-z][a-z0-9-]*' \
	|| refuse '--rules must name a module as <component>/scripts/lib/<module>'
printf '%s\n' "${problems}" | grep -Eqx '[a-z][a-z0-9_]*' || refuse '--problems must name a jq def'
[ -z "${facts}" ] || jq -e 'type == "object"' "${facts}" >/dev/null 2>&1 || refuse '--facts must be a file holding one JSON object'

self=$0
case ${self} in /*) ;; *) self="$(pwd)/${self}" ;; esac
skills=${self%/*/*/*/*}
[ -f "${skills}/${rules}.jq" ] || refuse "no rules module ${skills}/${rules}.jq; install first"
uncommitted="${skills}/git-worktree/scripts/internal/worktree-uncommitted.sh"
[ -f "${uncommitted}" ] || refuse "git-worktree isn't beside this skill (expected ${uncommitted}); install first"

if ! jq -e -s 'length == 1 and (.[0] | type) == "object"' "${report}" >/dev/null 2>&1; then
	printf 'write your report as one JSON object to %s\n' "${report}"
	exit 1
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/report-check.XXXXXX") || refuse 'mktemp could not make a work folder'
trap 'rm -rf -- "${work}"' EXIT
jq "${prune_jq}" "${report}" >"${work}/pruned" || refuse 'jq could not read the report'

# Succeeds when path $1 is relative and stays inside the tree.
inside() {
	case $1 in
		/* | .. | ../* | */.. | */../* | *"$(printf '\t')"*) return 1 ;;
		*) return 0 ;;
	esac
}

# The tree: whether it changed, and each at's file mapped to its line
# count, -1 when it is no file inside the tree; a file read at the base is
# keyed -<path>.
tree=$(jq -r '.tree // empty' "${job}")
case ${tree} in /*) ;; *) refuse '--job names no absolute tree' ;; esac
status=$(sh "${uncommitted}" --dir "${tree}") || refuse "worktree-uncommitted.sh could not read the tree ${tree}"
changed=$(printf '%s' "${status}" | jq '.uncommitted > 0')
jq -r '[.. | objects | .at | (strings, (arrays | .[] | strings))
	| capture("^(?<file>-?[^:@-][^:]*)(:[1-9][0-9]*(-[1-9][0-9]*)?)?$").file] | unique[]' \
	"${work}/pruned" >"${work}/files"
base=$(jq -r '.base // empty' "${job}")
: >"${work}/counts"
while IFS= read -r file; do
	length=-1
	# shellcheck disable=SC2310 # inside is a case test, called for its status
	case ${file} in
		-*)
			old=${file#-}
			# shellcheck disable=SC2310 # inside is a case test, called for its status
			if [ -n "${base}" ] && inside "${old}" && git -C "${tree}" cat-file -e "${base}:${old}" 2>/dev/null; then
				length=$(git -C "${tree}" show "${base}:${old}" | awk 'END { print NR }')
			fi ;;
		*)
			if inside "${file}" && [ -f "${tree}/${file}" ] && [ ! -L "${tree}/${file}" ]; then
				length=$(awk 'END { print NR }' "${tree}/${file}")
			fi ;;
	esac
	printf '%s\t%s\n' "${file}" "${length}" >>"${work}/counts"
done <"${work}/files"
jq -R -s 'split("\n") | map(select(length > 0) | split("\t") | {(.[0]): (.[1] | tonumber)}) | add // {}' \
	"${work}/counts" >"${work}/lines"

if [ -n "${facts}" ]; then cp -- "${facts}" "${work}/facts-in"; else printf '{}\n' >"${work}/facts-in"; fi
jq -n --slurpfile report "${work}/pruned" --slurpfile job "${job}" --slurpfile lines "${work}/lines" \
	--slurpfile facts "${work}/facts-in" --argjson changed "${changed}" \
	'{report: $report[0], job: $job[0], tree: {changed: $changed, lines: $lines[0]}, facts: $facts[0]}' \
	>"${work}/facts" || refuse 'jq could not join the report, the job and the tree'
has_base=false
[ -z "${base}" ] || has_base=true
jq -n -r --slurpfile report "${work}/pruned" --slurpfile lines "${work}/lines" --argjson base "${has_base}" \
	"{report: \$report[0], lines: \$lines[0], base: \$base} | ${locations_jq}" >"${work}/located" \
	|| refuse 'jq could not check the locations'
lines=$(jq -r -L "${skills}" "include \"${rules}\"; ${problems}" "${work}/facts") \
	|| refuse "the rules in ${rules}.jq failed to run"
located=$(cat "${work}/located")
lines=$(printf '%s\n%s\n' "${located}" "${lines}" | sed '/^$/d')
if [ -n "${lines}" ]; then
	printf '%s\n' "${lines}"
	exit 1
fi

# Accepted: the report is replaced by its pruned form, through a temp file
# beside it.
temp=$(mktemp "${report%/*}/.report.XXXXXX") || refuse "could not write beside ${report}"
if ! cp -- "${work}/pruned" "${temp}" || ! mv -f -- "${temp}" "${report}"; then
	rm -f -- "${temp}"
	refuse "could not replace ${report} with its pruned form"
fi
