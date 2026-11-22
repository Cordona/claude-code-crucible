#!/usr/bin/env sh
# Prints an effort's events: the one reader beside the one writer.
set -eu

usage() {
	cat <<'USAGE'
usage: sh events-read.sh --effort FOLDER [--type TYPE] [--paths]
       sh events-read.sh --help | -h

Prints the effort's events in seq order as one JSON array. Reads only.

  --effort FOLDER   the effort's folder, absolute
  --type TYPE       only events of this type, as effort.closed; a trailing
                    .* takes a family, as effort.*
  --paths           the event files' absolute paths, one per line, in
                    place of the array

stdout: the array ([] when there are none), or the paths (nothing when none)
Exit: 0 printed; 2 refused, the reason on stderr
USAGE
}

. "$(dirname -- "$0")/lib/listing.sh"
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

if [ -n "${paths}" ]; then
	ls_events "${effort}" "${type}"
else
	ls_events "${effort}" "${type}" | while IFS= read -r file; do cat -- "${file}"; done | jq -s .
fi
