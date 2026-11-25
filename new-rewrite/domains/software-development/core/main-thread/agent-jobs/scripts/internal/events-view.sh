#!/usr/bin/env sh
# Prints an effort's events with each submission joined to the report it
# pins: the one place that opens a submitted report.
# shellcheck source-path=SCRIPTDIR
set -eu

usage() {
	cat <<'USAGE'
usage: sh events-view.sh --effort FOLDER [--type TYPE]

Run by component scripts and hooks; not for main to call.
Prints an effort's events, each submission (an event whose body holds
report {path, sha256}) with the report it pins beside its body. All or
nothing: when a pinned report changed, went or isn't JSON, it prints nothing,
so no script decides on a report that isn't the one submitted.

Options:
  --effort FOLDER  the effort's folder, absolute
  --type TYPE      only this type, or a family, as 'job.*' (quoted)
Reads:     the effort's events, through crucible-events' events-read.sh, and
           the reports they pin, relative to FOLDER
Writes:    nothing
Stdout:    one JSON array of events, each submission with report: the
           report's JSON; [] when none match
Exit:
  0  printed
  2  refused, nothing changed; the reason is on stderr
  5  a pinned report is not as submitted, or the events can't be read: a
     human must look; stderr has one line per report, for the human
USAGE
}

prog='events-view.sh'
refuse() {
	printf '%s: %s\n' "${prog}" "$1" >&2
	exit 2
}

effort='' type=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--effort | --type)
			[ $# -ge 2 ] && [ -n "$2" ] || refuse "$1 needs a value"
			case $1 in --effort) effort=$2 ;; --type) type=$2 ;; *) ;; esac
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
reader="${skills}/crucible-events/scripts/internal/events-read.sh"
[ -f "${reader}" ] || refuse "crucible-events isn't beside this skill (expected ${reader}); install first"
report_hash="$(dirname -- "$0")/report-hash.sh"
lib="$(dirname -- "$0")/../lib"

work=$(mktemp -d "${TMPDIR:-/tmp}/events-view.XXXXXX") || refuse 'mktemp could not make a work folder'
trap 'rm -rf -- "${work}"' EXIT
rc=0
if [ -n "${type}" ]; then
	sh "${reader}" --effort "${effort}" --type "${type}" >"${work}/events" || rc=$?
else
	sh "${reader}" --effort "${effort}" >"${work}/events" || rc=$?
fi
[ "${rc}" -eq 0 ] || exit "${rc}"

# Each pinned report as it is now. Its path is a job's
# reports/<kind>/<seq>.json, so it stays inside the effort.
printf '{}\n' >"${work}/reports"
jq -r -L "${lib}" 'include "pinned-report"; {events: .} | [pr_submissions | .body.report.path] | unique[]' \
	"${work}/events" >"${work}/paths" || refuse 'jq could not list the pinned reports'
while IFS= read -r path; do
	printf '%s\n' "${path}" | grep -Eqx 'reports/[a-z][a-z0-9]*(-[a-z0-9]+)*/[1-9][0-9]*\.json' \
		|| { printf '%s: an event pins %s, not a reports/<kind>/<seq>.json; a human must look\n' "${prog}" "${path}" >&2; exit 5; }
	file="${effort}/${path}"
	if [ -f "${file}" ] && [ ! -L "${file}" ] && [ -r "${file}" ]; then
		sum=$(sh "${report_hash}" --report "${file}") || refuse "report-hash.sh could not hash ${file}"
		jq --arg p "${path}" --arg s "${sum}" --rawfile t "${file}" '. + {($p): {sha256: $s, text: $t}}' "${work}/reports" >"${work}/next"
	else
		jq --arg p "${path}" '. + {($p): {sha256: "", text: ""}}' "${work}/reports" >"${work}/next"
	fi
	mv -f -- "${work}/next" "${work}/reports"
done <"${work}/paths"

problems=$(jq -r -L "${lib}" --slurpfile reports "${work}/reports" \
	'include "pinned-report"; {events: ., reports: $reports[0]} | pr_problems' "${work}/events")
if [ -n "${problems}" ]; then
	printf '%s\n' "${problems}" | sed "s/^/${prog}: /;s/\$/; nothing reads it until a human looks/" >&2
	exit 5
fi
jq -L "${lib}" --slurpfile reports "${work}/reports" \
	'include "pinned-report"; {events: ., reports: $reports[0]} | pr_joined' "${work}/events"
