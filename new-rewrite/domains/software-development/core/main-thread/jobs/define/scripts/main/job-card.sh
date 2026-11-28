#!/usr/bin/env sh
# Shows the human a resolved proposal's jobs, as a recorded jobs gate.
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh job-card.sh --effort FOLDER --proposal FILE

Prints the card for a proposal job-resolve.sh wrote, one line per job, and
records it as a jobs gate on the proposal's sha256; it shows the card itself,
so show-card.sh isn't run again: end your turn with the card as printed,
then ask once, "Approve (Recommended)" one of the options.

Options:
  --effort FOLDER   the effort's folder, absolute
  --proposal FILE   FOLDER/proposals/SHA256.json, as job-resolve.sh printed
Requires:  crucible-gate beside this skill
Reads:     CLAUDE_CODE_SESSION_ID
Writes:    FOLDER/proposals/SHA256.card.md; this session's owed card
Stdout:    the card text, verbatim; on stderr, the agent files to write
Exit:
  0  printed and recorded
  2  refused, nothing recorded; the reason is on stderr
USAGE
}

prog='job-card.sh'
refuse() {
	printf '%s: %s\n' "${prog}" "$1" >&2
	exit 2
}

effort='' proposal=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--effort | --proposal)
			[ $# -ge 2 ] && [ -n "$2" ] || refuse "$1 needs a value"
			case $1 in --effort) effort=$2 ;; --proposal) proposal=$2 ;; *) ;; esac
			shift 2 ;;
		*) refuse "unknown argument $1; try --help" ;;
	esac
done
command -v jq >/dev/null 2>&1 || refuse 'jq not found'
case ${effort} in /*) ;; *) refuse '--effort must be an absolute folder' ;; esac
[ -d "${effort}/events" ] || refuse "${effort} is not an effort folder"

self=$0
case ${self} in /*) ;; *) self="$(pwd)/${self}" ;; esac
skills=${self%/*/*/*/*}
card_script="${skills}/crucible-gate/scripts/main/show-card.sh"
[ -f "${card_script}" ] || refuse "crucible-gate isn't beside this skill (expected ${card_script}); install first"
. "${skills}/crucible-events/scripts/lib/sha256.sh"

name=${proposal##*/}
sha=${name%.json}
[ "${proposal}" = "${effort}/proposals/${sha}.json" ] && [ -f "${proposal}" ] \
	|| refuse "--proposal must be a file job-resolve.sh wrote: ${effort}/proposals/SHA256.json"
[ "$(sh_sha256 "${proposal}")" = "${sha}" ] || refuse "${proposal} changed after it was resolved: resolve again"

card="${effort}/proposals/${sha}.card.md"
reader="${skills}/crucible-events/scripts/internal/events-read.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/job-card.XXXXXX") || refuse 'mktemp could not make a work folder'
trap 'rm -rf -- "${work}"' EXIT
sh "${reader}" --effort "${effort}" >"${work}/events" || refuse 'the effort'"'"'s events could not be read'
# A ref to a gate shows the human's own words there, so the human sees what
# a job takes as theirs.
jq -r --slurpfile all "${work}/events" '.jobs | length as $n
	| "Jobs to approve (\($n))",
	  "",
	  (to_entries[] | (.key + 1) as $i | .value
	   | "\($i). \(.kind) · \(.plugins.language)\((.plugins.frameworks // []) | map(" + " + .) | join(""))"
	     + " · \(.plugins.standards | join(", "))"
	     + " · \(if .work.tree.cut then "tree cut in \(.work.tree.cut.repo) from \(.work.tree.cut.from)"
		    else "tree \(.work.tree.use)" end)"
	     + " · iteration \(.work.loop.iteration)"
	     + (.input_refs | to_entries | map(.value as $v
		| (first($all[0][] | select(.seq == $v and .type == "gate.answered")) // null) as $g
		| if $g != null then " · \(.key): \($g.body.answer | tojson)"
		  else " · \(.key) \($v | if type == "array" then map(tostring) | join(", ") else tostring end)" end) | join(""))),
	  "",
	  "Proposal: \(input_filename)"' "${proposal}" >"${card}.tmp" || refuse "could not write ${card}"
mv -f -- "${card}.tmp" "${card}" || refuse "could not write ${card}"
sh "${card_script}" --record jobs --effort "${effort}" --accept 'Approve (Recommended)' --subject "${sha}" "${card}"
printf '%s: while the human reads the card, write the jobs'"'"' agent files: sh %s --proposal %s\n' "${prog}" "${skills}/jobs-agent-init/scripts/main/agent-files.sh" "${proposal}" >&2
