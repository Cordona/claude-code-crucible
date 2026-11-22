#!/usr/bin/env sh
# Takes an entry out of the context: a pending one, or one of the latest version's.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh context-drop.sh --effort FOLDER (--path ABS | --link URL) --why LINE
       sh context-drop.sh --help | -h

Takes a pending path or link out, or retires one of the latest version's,
so the next version leaves it out. A docs folder is never dropped.

  --effort FOLDER   the effort's folder, absolute; the effort must be open
  --path ABS        the path, as it was added
  --link URL        the link, as it was added
  --why LINE        one line: the human's reason

stdout: one of dropped, retired, retired already
Exit: 0 done; 2 refused, nothing written, the reason on stderr
USAGE
}

cx_prog='context-drop.sh'
. "$(dirname -- "$0")/lib/context.sh"
effort='' path='' link='' why=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--effort | --path | --link | --why)
			[ $# -ge 2 ] || cx_refuse "$1 needs a value"
			case $1 in --effort) effort=$2 ;; --path) path=$2 ;; --link) link=$2 ;; --why) why=$2 ;; esac
			shift 2 ;;
		*) cx_refuse "unknown argument $1; try --help" ;;
	esac
done
cx_set "${effort}"
if [ -n "${path}" ] && [ -n "${link}" ] || [ -z "${path}${link}" ]; then
	cx_refuse 'give exactly one of --path and --link'
fi
printf '%s' "${why}" | grep -q '[^[:space:]]' || cx_refuse '--why is empty'
if [ -n "${path}" ]; then key=path value=${path} list=paths; else key=url value=${link} list=links; fi
cx_require_open
cx_lock
mkdir -p -- "${cx_draft}"
latest=$(cx_latest)
pending='{"paths": [], "links": [], "retire": []}'
[ ! -f "${cx_entries}" ] || pending=$(cat -- "${cx_entries}")
# shellcheck disable=SC2016 # the $ names are jq's
result=$(jq -c --arg key "${key}" --arg value "${value}" --arg list "${list}" --arg why "${why}" \
	--argjson latest "$(if [ -n "${latest}" ]; then cat -- "${latest}"; else echo null; fi)" '
	if (.[$list] | map(.[$key]) | index([$value])) then {said: "dropped", pending: (.[$list] |= map(select(.[$key] != $value)))}
	elif (.retire | map(.[$key]) | index([$value])) then {said: "retired already", pending: .}
	elif $latest != null and ($latest.body[$list] // [] | map(select(has("sha256") | not) | .[$key]) | index([$value])) then
		{said: "retired", pending: (.retire += [{($key): $value, why: $why}])}
	else {said: "missing", pending: .} end' <<EOF2
${pending}
EOF2
)
[ "$(printf '%s' "${result}" | jq -r '.said')" != missing ] || cx_refuse "${value} is neither pending nor in the latest version"
printf '%s' "${result}" | jq '.pending' | aw_write "${cx_entries}"
printf '%s' "${result}" | jq -r '.said'
