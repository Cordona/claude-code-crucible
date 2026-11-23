#!/usr/bin/env sh
# Prints an effort's events: the one reader beside the one writer.
set -eu

usage() {
	cat <<'USAGE'
usage: sh events-read.sh --effort FOLDER [--type TYPE] [--paths]

Run by component scripts and hooks; not for main to call.
Prints an effort's events in seq order, as one JSON array or as file paths.
All or nothing: when any matching event can't be read or isn't valid JSON,
it prints nothing. --paths only lists, so it checks nothing.

Options:
  --effort FOLDER  the effort's folder, absolute
  --type TYPE      only this type, as effort.closed, or a family, as
                   'effort.*' (quote it against shell globbing)
  --paths          print the event files' absolute paths instead
Requires:  FOLDER holds an events/ folder (the effort was started)
Writes:    nothing
Stdout:    one JSON array of events as event-write.sh stored them, [] when
           none match; with --paths, one path per line, nothing when none
Exit:
  0  printed
  2  refused, nothing changed; the reason is on stderr
  5  an event can't be read or isn't valid JSON: the log is damaged and a
     human must look; stderr names the first such file and which it is
USAGE
}

. "$(dirname -- "$0")/../lib/listing.sh"
refuse() { printf 'events-read.sh: %s\n' "$1" >&2; exit 2; }
effort='' type='' paths=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--effort | --type)
			[ $# -ge 2 ] || refuse "$1 needs a value"
			case $1 in --effort) effort=$2 ;; --type) type=$2 ;; esac
			shift 2 ;;
		--paths) paths=1; shift ;;
		*) refuse "unknown argument $1; try --help" ;;
	esac
done
case ${effort} in /*) ;; *) refuse '--effort must be an absolute folder' ;; esac
[ -d "${effort}/events" ] || refuse "${effort} is not an effort folder"
[ -z "${type}" ] || ls_is_type "${type}" || ls_is_family "${type}" \
	|| refuse "--type ${type} is not a type: lowercase words joined by dots, as effort.closed, or a family, as effort.*"
command -v jq >/dev/null 2>&1 || refuse 'jq missing; expected jq 1.6 or later on PATH'

# Exits 5 naming the first listed event that can't be read or isn't exactly
# one JSON value; run only once the whole read has failed.
damaged() {
	for file in "$@"; do
		cat -- "${file}" >/dev/null 2>&1 \
			|| { printf 'events-read.sh: %s cannot be read\n' "${file}" >&2; exit 5; }
		jq -e -s 'length == 1' "${file}" >/dev/null 2>&1 \
			|| { printf 'events-read.sh: %s is not valid JSON\n' "${file}" >&2; exit 5; }
	done
	printf 'events-read.sh: the events changed while being read; rerun\n' >&2
	exit 5
}

if [ -n "${paths}" ]; then
	ls_events "${effort}" "${type}"
	exit 0
fi
listed=$(ls_events "${effort}" "${type}")
[ -n "${listed}" ] || { printf '[]\n'; exit 0; }
old_ifs=${IFS}; IFS='
'; set -f
# shellcheck disable=SC2086 # split on newlines only, globbing off: one path a line
set -- ${listed}
IFS=${old_ifs}; set +f
# One value per file, so a value split or doubled across files fails too.
events=$(jq -s --argjson n "$#" 'if length == $n then . else error("count") end' "$@" 2>/dev/null) \
	|| damaged "$@"
printf '%s\n' "${events}"
