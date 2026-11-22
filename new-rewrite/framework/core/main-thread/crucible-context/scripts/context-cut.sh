#!/usr/bin/env sh
# Cuts a sealed context version, once the human approved sending agents with
# the fingerprint their plan pinned.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh context-cut.sh --effort FOLDER --expect HEX
       sh context-cut.sh --help | -h

Run after the human approves sending agents, seated or spun off, with the
fingerprint context-fingerprint.sh printed for that plan. When the context
still gives HEX, it moves the draft's docs to <effort>/context/v<N>/ with
their files read-only, writes the context.cut event and clears the pending
entries. With nothing new, it prints the latest version and writes nothing.

  --effort FOLDER   the effort's folder, absolute; the effort must be open
  --expect HEX      the fingerprint the approved plan pinned

stdout: CONTEXT_FILE: <the context.cut event, absolute>, then
  CONTEXT_SHA256: <its sha256>
Exit: 0 cut, or nothing new; 2 refused, nothing written, the reason on
  stderr, led by a token: CONTEXT-CHANGED (the context no longer gives HEX:
  show the plan again), NO-SPEC, NOT-APPROVED, DOCS-NAME, DOCS-SIZE,
  CONTEXT-NONE
USAGE
}

cx_prog='context-cut.sh'
. "$(dirname -- "$0")/lib/context.sh"
. "$(dirname -- "$0")/lib/path-rule.sh"
. "$(dirname -- "$0")/lib/body.sh"
effort='' expect=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--effort | --expect)
			[ $# -ge 2 ] || cx_refuse "$1 needs a value"
			case $1 in --effort) effort=$2 ;; --expect) expect=$2 ;; esac
			shift 2 ;;
		*) cx_refuse "unknown argument $1; try --help" ;;
	esac
done
cx_set "${effort}"
printf '%s' "${expect}" | grep -Eq '^[0-9a-f]{64}$' || cx_refuse '--expect must be 64 lowercase hex digits'
cx_require_open
cx_lock
body=$(bd_build)
[ "$(bd_fingerprint "${body}")" = "${expect}" ] \
	|| cx_refuse 'CONTEXT-CHANGED: the context changed since the plan pinned it; show the plan again'

latest=$(cx_latest)
show() { printf 'CONTEXT_FILE: %s\nCONTEXT_SHA256: %s\n' "$1" "$(sh_sha256 "$1")"; }
if [ -n "${latest}" ] && [ "$(jq '.body.version' "${latest}")" = "$(printf '%s' "${body}" | jq '.version')" ]; then
	show "${latest}"
	exit 0
fi

version=$(printf '%s' "${body}" | jq -r '.version')
target="${cx_dir}/v${version}"
moved=false
if printf '%s' "${body}" | jq -e --arg t "${target}" 'any(.paths[]; .path == $t)' >/dev/null; then
	[ ! -e "${target}" ] || cx_refuse "${target} already exists"
	mv -- "${cx_docs}" "${target}"
	moved=true
	find "${target}" -type f -exec chmod 0444 {} +
fi
bodyfile=$(mktemp)
printf '%s' "${body}" >"${bodyfile}"
if ! event=$(sh "${cx_writer}" --effort "${cx_effort}" --type context.cut --by "${cx_prog}" \
	--body-file "${bodyfile}"); then
	rm -f -- "${bodyfile}"
	if [ "${moved}" = true ]; then chmod -R u+w "${target}"; mv -- "${target}" "${cx_docs}"; fi
	exit 2
fi
rm -f -- "${bodyfile}" "${cx_entries}"
show "${event}"
