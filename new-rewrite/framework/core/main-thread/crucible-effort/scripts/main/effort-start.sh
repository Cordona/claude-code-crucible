#!/usr/bin/env sh
# Starts an effort: makes its folder and writes effort.opened.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh effort-start.sh --name NAME

Starts a new effort: a new folder whose first event is effort.opened. Use it
once the human says yes to an effort; every call starts a new one.

Options:
  --name NAME  what the human calls the work; 1 to 40 characters
Reads:   CRUCIBLE_HOME, where efforts live, default $HOME/.crucible;
         CLAUDE_CODE_SESSION_ID, stamped on the event
Writes:  a new folder in $CRUCIBLE_HOME/efforts/ with event effort.opened {name}
Stdout:  one path: the new effort folder, absolute; pass it on as printed
Exit:
  0  started
  2  refused or not written, nothing changed; the reason is on stderr
USAGE
}

ef_prog='effort-start.sh'
. "$(dirname -- "$0")/../lib/effort.sh"
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
