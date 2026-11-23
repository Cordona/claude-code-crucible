#!/usr/bin/env sh
# Takes an entry out of the context: a pending one, or one of the latest version's.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh context-drop.sh --effort FOLDER (--path PATH | --link URL) --why LINE

Takes a path or link out of the context when the human asks: a pending one
is dropped; one in the latest version is retired (left out at the next
context-cut.sh). A docs folder (context-docs.sh) can't be dropped.

Options:
  --effort FOLDER  the effort's folder, absolute
  --path PATH      the path, exactly as given to context-add.sh
  --link URL       the link, exactly as given to context-add.sh
  --why LINE       one line: the human's reason
Requires:  the effort is open
Writes:    the context draft's pending entries; no event
Stdout:    one line: dropped | retired | retired already
Exit:
  0  done, including no change
  2  refused, nothing changed, reason on stderr
USAGE
}

cx_prog='context-drop.sh'
. "$(dirname -- "$0")/../lib/context.sh"
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
