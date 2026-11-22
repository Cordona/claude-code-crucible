#!/usr/bin/env sh
# Starts an effort: makes its folder and writes effort.opened.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh effort-start.sh --name NAME
       sh effort-start.sh --help | -h

Makes a new effort folder in ${CRUCIBLE_HOME:-$HOME/.crucible}/efforts/ and
writes its first event, effort.opened, with the name.

  --name NAME   what the human calls the work, up to 40 characters

Folder name: <YYYYMMDDTHHMMSS>-<4 hex>-<slug>: the start time in UTC, then
  the name in lowercase letters, digits and dashes ("effort" when the name
  has none of those).
stdout: the new effort's folder, absolute
Exit: 0 started; 2 refused or not written, the reason on stderr
USAGE
}

ef_prog='effort-start.sh'
. "$(dirname -- "$0")/lib/effort.sh"
name=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--name) [ $# -ge 2 ] || ef_refuse '--name needs a value'; name=$2; shift 2 ;;
		*) ef_refuse "unknown argument $1; try --help" ;;
	esac
done
printf '%s' "${name}" | grep -q '[^[:space:]]' || ef_refuse '--name is empty'
[ "${#name}" -le 40 ] || ef_refuse '--name is over 40 characters'

slug=$(printf '%s' "${name}" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-//' -e 's/-$//')
[ -n "${slug}" ] || slug=effort
folder="${ef_efforts}/$(date -u +%Y%m%dT%H%M%S)-$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')-${slug}"
mkdir -p -- "${ef_efforts}"
mkdir -- "${folder}" || ef_refuse "${folder} already exists; try again"
body=$(mktemp)
trap 'rm -f -- "${body}"' EXIT
jq -n --arg name "${name}" '{name: $name}' >"${body}"
ef_write effort.opened "${folder}" "${body}" >/dev/null || { rmdir -- "${folder}/events" "${folder}" 2>/dev/null; exit 2; }
printf '%s\n' "${folder}"
