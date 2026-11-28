#!/usr/bin/env sh
# Turns main's proposed jobs into full jobs, ready for the human's card.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh job-resolve.sh --effort FOLDER --jobs FILE

Makes main's proposed jobs full, from the kinds and the effort's events:
each job's refs (the latest context, spec and grills unless you name
them), its tree's form, its iteration and, for a review, its range. All
or none: any fault refuses the whole proposal, one line per fault, so you
fix them all at once.

Options:
  --effort FOLDER  the effort's folder, absolute
  --jobs FILE      {jobs: [{kind, plugins, work: {tree, known_failures?},
                   input_refs?}]}, plugins {language, frameworks?,
                   standards}, tree {use: SEQ} or {cut: {repo, from}}
Requires:  each kind as kinds/KIND.json in this skill, its agent
           installed
Writes:    FOLDER/proposals/SHA256.json, the full jobs, named by its sha256
Stdout:    "N jobs resolved: PATH, sha256 SHA256"
Exit:
  0  resolved
  2  refused, nothing written; one line per fault on stderr
USAGE
}

prog='job-resolve.sh'
refuse() {
	printf '%s: %s\n' "${prog}" "$1" >&2
	exit 2
}

effort='' jobs=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--effort | --jobs)
			[ $# -ge 2 ] && [ -n "$2" ] || refuse "$1 needs a value"
			case $1 in --effort) effort=$2 ;; --jobs) jobs=$2 ;; *) ;; esac
			shift 2 ;;
		*) refuse "unknown argument $1; try --help" ;;
	esac
done
command -v jq >/dev/null 2>&1 || refuse 'jq not found'
case ${effort} in /*) ;; *) refuse '--effort must be an absolute folder' ;; esac
[ -d "${effort}/events" ] || refuse "${effort} is not an effort folder"
[ -f "${jobs}" ] || refuse "--jobs ${jobs} is not a file"
jq -e 'type == "object"' "${jobs}" >/dev/null 2>&1 || refuse "${jobs} is not one JSON object"

self=$0
case ${self} in /*) ;; *) self="$(pwd)/${self}" ;; esac
skills=${self%/*/*/*/*}
reader="${skills}/crucible-events/scripts/internal/events-read.sh"
[ -f "${reader}" ] || refuse "crucible-events isn't beside this skill (expected ${reader}); install first"
. "${skills}/crucible-events/scripts/lib/sha256.sh"

work=$(mktemp -d "${TMPDIR:-/tmp}/job-resolve.XXXXXX") || refuse 'mktemp could not make a work folder'
trap 'rm -rf -- "${work}"' EXIT

# The kinds: every kinds/KIND.json of this skill.
printf '{}' >"${work}/kinds"
for file in "${self%/*/*/*}"/kinds/*.json; do
	[ -f "${file}" ] || continue
	kind=${file##*/}
	kind=${kind%.json}
	jq -e '(.agent | type) == "string" and (.part | type) == "string" and (.input_refs | type) == "object"
		and (.tree | type) == "array" and (.write_scope | IN("tree", "report"))
		and ((has("range") | not) or (.range | IN("tree", "change")))' "${file}" >/dev/null 2>&1 \
		|| refuse "${file} is not a kind: {agent, part, input_refs, tree, write_scope, range? (tree or change), known_failures?, one_standard?, one_of?}"
	agent=$(jq -r '.agent' "${file}")
	[ -d "${skills}/${agent}" ] || refuse "kind ${kind}'s agent ${agent} isn't installed beside this skill"
	jq --arg k "${kind}" --slurpfile j "${file}" '. + {($k): $j[0]}' "${work}/kinds" >"${work}/kinds.next"
	mv -f -- "${work}/kinds.next" "${work}/kinds"
done
[ "$(jq 'length' "${work}/kinds")" -gt 0 ] || refuse "this skill has no kind (no kinds/*.json)"

sh "${reader}" --effort "${effort}" >"${work}/events" || refuse 'the effort'"'"'s events could not be read'
jq -L "${skills}" --slurpfile kinds "${work}/kinds" --slurpfile all "${work}/events" \
	'include "jobs-define/scripts/lib/job-resolve"; jr_resolve($kinds[0]; $all[0])' "${jobs}" >"${work}/out" \
	|| refuse 'the jobs could not be resolved'
if [ "$(jq '.faults | length' "${work}/out")" -gt 0 ]; then
	jq -r '.faults[]' "${work}/out" | sed "s/^/${prog}: /" >&2
	exit 2
fi

# A kind whose range is its tree's reads between the tree's base and its
# head now; a range from a change was filled by the resolve itself.
jq '{jobs}' "${work}/out" >"${work}/proposal"
count=$(jq '.jobs | length' "${work}/proposal")
i=0
while [ "${i}" -lt "${count}" ]; do
	kind=$(jq -r --argjson i "${i}" '.jobs[$i].kind' "${work}/proposal")
	if [ "$(jq -r --arg k "${kind}" '.[$k].range // ""' "${work}/kinds")" = tree ]; then
		cut=$(jq -c --argjson i "${i}" --slurpfile all "${work}/events" \
			'.jobs[$i].work.tree.use as $t | $all[0][] | select(.seq == $t) | .body' "${work}/proposal")
		path=$(printf '%s' "${cut}" | jq -r '.path')
		head=$(git -C "${path}" rev-parse HEAD 2>/dev/null) \
			|| refuse "job $((i + 1)): its tree ${path} has no head to read up to"
		jq --argjson i "${i}" --arg base "$(printf '%s' "${cut}" | jq -r '.base')" --arg head "${head}" \
			'.jobs[$i].work.range = {base: $base, head: $head}' "${work}/proposal" >"${work}/proposal.next"
		mv -f -- "${work}/proposal.next" "${work}/proposal"
	fi
	i=$((i + 1))
done

mkdir -p "${effort}/proposals" || refuse "could not make ${effort}/proposals"
sha=$(sh_sha256 "${work}/proposal")
out="${effort}/proposals/${sha}.json"
# The same jobs resolve to the same name; a file there that was changed is
# written again.
if [ ! -f "${out}" ] || [ "$(sh_sha256 "${out}")" != "${sha}" ]; then
	cp -- "${work}/proposal" "${out}.tmp" && mv -f -- "${out}.tmp" "${out}" || refuse "could not write ${out}"
	chmod a-w "${out}" 2>/dev/null || :
fi
count=$(jq '.jobs | length' "${out}")
if [ "${count}" -eq 1 ]; then noun='job'; else noun='jobs'; fi
printf '%s %s resolved: %s, sha256 %s\n' "${count}" "${noun}" "${out}" "${sha}"
