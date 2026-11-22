#!/usr/bin/env sh
# Opens a grill: a draft with the next grill number in the effort.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh grill-new.sh --effort FOLDER --topic TEXT
       sh grill-new.sh --help | -h

Creates the draft <effort>/grills/<n>.json, <n> the next grill number in
the effort (counting open and ended grills).

  --effort FOLDER   the effort's folder, absolute; the effort must be open
  --topic TEXT      what the grill is about, one line

stdout: the draft, absolute
Exit: 0 created; 2 refused, the reason on stderr
USAGE
}

gr_prog='grill-new.sh'
. "$(dirname -- "$0")/lib/grill.sh"
effort='' topic=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--effort | --topic)
			[ $# -ge 2 ] || gr_refuse "$1 needs a value"
			case $1 in --effort) effort=$2 ;; --topic) topic=$2 ;; esac
			shift 2 ;;
		*) gr_refuse "unknown argument $1; try --help" ;;
	esac
done
gr_set_effort "${effort}"
gr_require_open
gr_lock
last=0
for draft in "${gr_dir}"/[1-9]*.json; do
	[ -f "${draft}" ] || continue
	n=${draft##*/}; n=${n%.json}
	[ "${n}" -le "${last}" ] || last=${n}
done
n=$(sh "${gr_reader}" --effort "${gr_effort}" --type grill.ended | jq '[.[].body.number] | max // 0')
[ "${n}" -le "${last}" ] || last=${n}
file="${gr_dir}/$((last + 1)).json"
jq -n --argjson number "$((last + 1))" --arg topic "${topic}" '{number: $number, topic: $topic, questions: []}' | gr_save "${file}"
printf '%s\n' "${file}"
