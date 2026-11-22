#!/usr/bin/env sh
# Adds an outside path or link to the context's pending entries, with its why.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh context-add.sh --effort FOLDER (--path ABS | --link URL) --why LINE
       sh context-add.sh --help | -h

Puts one outside path or link into the pending entries, for the next
version. The same entry again changes nothing; one with a pending
retirement has the retirement undone.

  --effort FOLDER   the effort's folder, absolute; the effort must be open
  --path ABS        an existing file or folder, not a symlink, outside the
                    effort's own folder, allowed by context-path-check.sh
  --link URL        an http(s) URL of shell-safe characters only
  --why LINE        one line: why the agents need it

stdout: one of added, already pending, already in v<N>, retirement undone
Exit: 0 done; 2 refused, nothing written, the reason on stderr
USAGE
}

cx_prog='context-add.sh'
. "$(dirname -- "$0")/lib/context.sh"
. "$(dirname -- "$0")/lib/path-rule.sh"
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
case ${why} in *'
'*) cx_refuse '--why must be one line' ;; esac
if [ -n "${path}" ]; then
	problem=$(pr_problem "${path}")
	[ -z "${problem}" ] || cx_refuse "--path ${path} ${problem}"
	[ ! -L "${path}" ] || cx_refuse "--path ${path} is a symlink"
	[ -e "${path}" ] && [ -r "${path}" ] || cx_refuse "--path ${path} doesn't exist or can't be read"
	case ${path}/ in "${cx_effort}"/*) cx_refuse "--path ${path} is inside the effort's own folder: its facts reach the agents through the sender, never as a reference" ;; esac
	key=path value=${path} list=paths
else
	jq -en -L "${cx_here}/lib" --arg url "${link}" 'include "link-rule"; $url | safe_link' >/dev/null 2>&1 \
		|| cx_refuse "--link ${link} is not an http(s) URL of shell-safe characters"
	key=url value=${link} list=links
fi
cx_require_open
cx_lock
mkdir -p -- "${cx_draft}"
latest=$(cx_latest)
pending='{"paths": [], "links": [], "retire": []}'
[ ! -f "${cx_entries}" ] || pending=$(cat -- "${cx_entries}")
# shellcheck disable=SC2016 # the $ names are jq's
result=$(jq -c --arg key "${key}" --arg value "${value}" --arg list "${list}" --arg why "${why}" \
	--argjson latest "$(if [ -n "${latest}" ]; then cat -- "${latest}"; else echo null; fi)" '
	if (.retire | map(.[$key]) | index([$value])) then {said: "retirement undone", pending: (.retire |= map(select(.[$key] != $value)))}
	elif (.[$list] | map(.[$key]) | index([$value])) then {said: "already pending", pending: .}
	elif $latest != null and ($latest.body[$list] // [] | map(.[$key]) | index([$value])) then {said: "already in v\($latest.body.version)", pending: .}
	else {said: "added", pending: (.[$list] += [{($key): $value, why: $why}])} end' <<EOF2
${pending}
EOF2
)
printf '%s' "${result}" | jq '.pending' | aw_write "${cx_entries}"
printf '%s' "${result}" | jq -r '.said'
